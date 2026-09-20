#!/usr/bin/env python3
"""Benchmark reference-family requests against a ZLS executable."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import statistics
import subprocess
import sys
import tempfile
import time


class Client:
    def __init__(self, process):
        self.process = process
        self.buffer = bytearray()
        self.sequence = 0

    def send(self, message):
        data = json.dumps(dict(jsonrpc="2.0", **message), ensure_ascii=False).encode()
        self.process.stdin.write(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)
        self.process.stdin.flush()

    def notify(self, method, params):
        self.send(dict(method=method, params=params))

    def receive(self, deadline):
        while time.monotonic() < deadline:
            boundary = self.buffer.find(b"\r\n\r\n")
            if boundary >= 0:
                headers = dict(line.split(b":", 1) for line in bytes(self.buffer[:boundary]).split(b"\r\n"))
                size = int(headers[b"Content-Length"])
                end = boundary + 4 + size
                if len(self.buffer) >= end:
                    message = json.loads(self.buffer[boundary + 4:end])
                    del self.buffer[:end]
                    return message
            ready, _, _ = select.select([self.process.stdout], [], [], 0.1)
            if ready:
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError("ZLS closed stdout before replying")
                self.buffer.extend(chunk)
        raise TimeoutError("LSP request exceeded 60 seconds")

    def request(self, method, params):
        self.sequence += 1
        sequence = self.sequence
        self.send(dict(id=sequence, method=method, params=params))
        deadline = time.monotonic() + 60
        while True:
            response = self.receive(deadline)
            if "method" in response:
                if "id" in response:
                    self.send(dict(id=response["id"], result=None))
                continue
            if response.get("id") != sequence:
                raise RuntimeError(f"unexpected response: {response}")
            if "error" in response:
                raise RuntimeError(response["error"])
            return response.get("result")


def make_source(reference_count):
    lines = [
        "const target_value: usize = 1;",
        "pub fn accumulate() usize {",
        "    var total: usize = 0;",
    ]
    lines.extend("    total +%= target_value;" for _ in range(reference_count))
    lines.extend(("    return total;", "}", ""))
    return "\n".join(lines)


def request_params(method, uri):
    base = dict(textDocument=dict(uri=uri), position=dict(line=0, character=6))
    if method == "textDocument/references":
        return dict(**base, context=dict(includeDeclaration=True))
    if method == "textDocument/rename":
        return dict(**base, newName="renamed_value")
    return base


def canonical_result(method, result):
    if method == "textDocument/rename":
        changes = result.get("changes", {}) if result else {}
        items = [dict(range=edit["range"], newText=edit["newText"])
                 for edits in changes.values() for edit in edits]
    elif method == "textDocument/references":
        items = [item["range"] for item in (result or [])]
    else:
        items = result or []
    encoded = json.dumps(items, sort_keys=True, separators=(",", ":")).encode()
    return len(items), hashlib.sha256(encoded).hexdigest()


def percentile(sorted_values, fraction):
    return sorted_values[min(len(sorted_values) - 1, int((len(sorted_values) - 1) * fraction))]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--method", choices=("references", "highlight", "rename"), default="references")
    parser.add_argument("--reference-count", type=int, default=4096)
    parser.add_argument("--warmup", type=int, default=4)
    parser.add_argument("--rounds", type=int, default=24)
    args = parser.parse_args()
    if args.reference_count < 1 or args.warmup < 0 or args.rounds < 1:
        parser.error("reference-count and rounds must be positive; warmup must be non-negative")

    method = {
        "references": "textDocument/references",
        "highlight": "textDocument/documentHighlight",
        "rename": "textDocument/rename",
    }[args.method]
    source = make_source(args.reference_count)

    with tempfile.TemporaryDirectory(prefix="zls-reference-bench-") as directory:
        root = Path(directory)
        config = root / "zls.json"
        config.write_text(json.dumps(dict(enable_build_on_save=False)))
        uri = (root / "references.zig").as_uri()
        with (root / "stderr.log").open("w+") as stderr:
            process = subprocess.Popen(
                [str(args.binary.resolve()), "--config-path", str(config)],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr,
            )
            client = Client(process)
            samples_ns = []
            expected = None
            try:
                result = client.request("initialize", dict(
                    processId=os.getpid(),
                    rootUri=root.as_uri(),
                    workspaceFolders=[dict(uri=root.as_uri(), name="reference-benchmark")],
                    capabilities=dict(general=dict(positionEncodings=["utf-16"])),
                ))
                if result["capabilities"]["positionEncoding"] != "utf-16":
                    raise RuntimeError("UTF-16 negotiation failed")
                client.notify("initialized", {})
                client.notify("textDocument/didOpen", dict(textDocument=dict(
                    uri=uri, languageId="zig", version=1, text=source,
                )))
                params = request_params(method, uri)
                for round_index in range(args.warmup + args.rounds):
                    before = time.monotonic_ns()
                    response = client.request(method, params)
                    elapsed = time.monotonic_ns() - before
                    actual = canonical_result(method, response)
                    if actual[0] != args.reference_count + 1:
                        raise RuntimeError(f"expected {args.reference_count + 1} results, got {actual[0]}")
                    if expected is not None and actual != expected:
                        raise RuntimeError(f"unstable response: expected {expected}, got {actual}")
                    expected = actual
                    if round_index >= args.warmup:
                        samples_ns.append(elapsed)
                client.notify("textDocument/didClose", dict(textDocument=dict(uri=uri)))
                client.request("shutdown", None)
                client.notify("exit", None)
                process.wait(timeout=10)
                if process.returncode != 0:
                    raise RuntimeError(f"ZLS exited with {process.returncode}")
            except BaseException:
                stderr.seek(0)
                print(stderr.read(), file=sys.stderr)
                raise
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                process.stdin.close()
                process.stdout.close()

            samples_us = sorted(value / 1000 for value in samples_ns)
            print(json.dumps(dict(
                binary=str(args.binary.resolve()),
                method=method,
                reference_count=args.reference_count,
                source_bytes=len(source.encode()),
                warmup=args.warmup,
                rounds=args.rounds,
                response_count=expected[0],
                response_sha256=expected[1],
                median_us=statistics.median(samples_us),
                minimum_us=samples_us[0],
                p90_us=percentile(samples_us, 0.90),
                maximum_us=samples_us[-1],
                samples_us=samples_us,
            ), indent=2))


if __name__ == "__main__":
    main()
