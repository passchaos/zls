#!/usr/bin/env python3
"""Compare checked completion and definition requests in real zigraft integration source."""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
from benchmark_lsp_references import Client

CASES = (
    ("comptime_method", "const n = try impl.call", ".read"),
    ("generated_binding", ".bindings = .{ .read = emptyRead", ".read"),
    ("generic_return_method", "const result = zigraft.auto(Reader, *Missing)", ".check"),
    ("generated_capability", "const count = try capabilities.reader.call", ".reader"),
    ("dynamic_initializer", "const erased = AnyNamed.init(&value", ".init"),
    ("standard_library", "expectEqual(@as(usize, 6)", ".expectEqual"),
)

STRING_CASES = (
    ("reflection_member", '@hasDecl(Base, "ReaderError")', '"ReaderError"'),
    ("package_import", 'const zigraft = @import("zigraft")', '"zigraft"'),
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("project", type=Path)
    parser.add_argument("--warmup", type=int, default=4)
    parser.add_argument("--rounds", type=int, default=20)
    parser.add_argument("--requests", nargs="+", choices=("completion", "definition"),
                        default=("completion", "definition"))
    args = parser.parse_args()
    if args.warmup < 0 or args.rounds < 1:
        parser.error("warmup must be nonnegative and rounds positive")
    root = args.project.resolve()
    document = root / "tests/integration.zig"
    source = document.read_text()
    uri = document.as_uri()
    cases = []
    for name, anchor, member in CASES:
        matching = [(index, line) for index, line in enumerate(source.splitlines()) if anchor in line]
        if len(matching) != 1:
            raise ValueError(f"expected one source anchor for {name}, found {len(matching)}")
        row, line = matching[0]
        cases.append((name, member[1:], row, line.index(member) + 1))
    for name, anchor, marker in STRING_CASES:
        matching = [(index, line) for index, line in enumerate(source.splitlines()) if anchor in line]
        if len(matching) != 1:
            raise ValueError(f"expected one source anchor for {name}, found {len(matching)}")
        row, line = matching[0]
        cases.append((name, marker[1:-1], row, line.index(marker) + 1))
    report = dict(source_sha256=hashlib.sha256(source.encode()).hexdigest(), warmup=args.warmup,
                  rounds=args.rounds, binaries=[], cases=[])
    processes, clients, logs = [], [], []
    with tempfile.TemporaryDirectory(prefix="zls-integration-ab-") as temporary:
        config = Path(temporary) / "zls.json"
        config.write_text(json.dumps(dict(enable_build_on_save=False)))
        try:
            for index, binary in enumerate((args.baseline, args.candidate)):
                report["binaries"].append(dict(path=str(binary.resolve()), sha256=hashlib.sha256(binary.read_bytes()).hexdigest()))
                stderr = (Path(temporary) / f"stderr-{index}.log").open("w+")
                logs.append(stderr)
                process = subprocess.Popen([str(binary.resolve()), "--config-path", str(config)], cwd=root,
                                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr)
                processes.append(process)
                client = Client(process)
                clients.append(client)
                client.request("initialize", dict(
                    processId=os.getpid(), rootUri=root.as_uri(),
                    workspaceFolders=[dict(uri=root.as_uri(), name=root.name)],
                    capabilities=dict(textDocument=dict(definition=dict(linkSupport=True),
                                                        completion=dict(completionItem=dict(snippetSupport=True))))))
                client.notify("initialized", {})
                client.notify("textDocument/didOpen", dict(textDocument=dict(
                    uri=uri, languageId="zig", version=1, text=source)))
            for name, expected_label, row, column in cases:
                for request in args.requests:
                    params = dict(textDocument=dict(uri=uri), position=dict(line=row, character=column +
                                  (len(expected_label) if request == "completion" else len(expected_label) // 2)))
                    samples = [[], []]
                    expected = None
                    for round_index in range(args.warmup + args.rounds):
                        for index in (round_index % 2, 1 - round_index % 2):
                            before = time.perf_counter_ns()
                            result = clients[index].request("textDocument/" + request, params)
                            elapsed = (time.perf_counter_ns() - before) / 1000
                            if request == "completion":
                                items = result.get("items", []) if isinstance(result, dict) else result or []
                                if not any(item["label"] == expected_label for item in items):
                                    raise AssertionError(f"{name}: missing {expected_label}")
                            elif not result:
                                raise AssertionError(f"{name}: missing definition")
                            canonical = json.dumps(result, sort_keys=True, separators=(",", ":"))
                            if expected is None:
                                expected = canonical
                            elif canonical != expected:
                                raise AssertionError(f"{name}: response changed between requests/binaries")
                            if round_index >= args.warmup:
                                samples[index].append(elapsed)
                    medians = list(map(statistics.median, samples))
                    report["cases"].append(dict(name=name, request=request, baseline_us=medians[0], candidate_us=medians[1],
                                                 speedup=medians[0] / medians[1],
                                                 response_sha256=hashlib.sha256(expected.encode()).hexdigest(),
                                                 samples_us=samples))
                    print(f"{request} {name}: {medians[0]:.1f} -> {medians[1]:.1f} us", file=sys.stderr, flush=True)
            for client, process in zip(clients, processes):
                client.request("shutdown", None)
                client.notify("exit", None)
                process.wait(timeout=10)
                if process.returncode != 0:
                    raise RuntimeError(f"ZLS exited with {process.returncode}")
        except BaseException:
            for stderr in logs:
                stderr.seek(0)
                print(stderr.read(), file=sys.stderr)
            raise
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                process.stdin.close()
                process.stdout.close()
            for stderr in logs:
                stderr.close()
    report["geomean_speedup"] = math.exp(statistics.mean(math.log(case["speedup"]) for case in report["cases"]))
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
