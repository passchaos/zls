#!/usr/bin/env python3
"""Measure comptime array initialization through actual LSP completion requests."""

import argparse
import json
import os
import resource
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
from benchmark_lsp_references import Client


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--element-count", type=int, default=2048)
    parser.add_argument("--warmup", type=int, default=5)
    parser.add_argument("--rounds", type=int, default=20)
    parser.add_argument("--initializer", choices=("literal", "cast", "dependent", "call", "loop"), default="literal")
    parser.add_argument("--layout", choices=("array", "struct", "matrix", "optional", "error_union"), default="array")
    args = parser.parse_args()
    if not 1 <= args.element_count <= 4096 or args.warmup < 0 or args.rounds < 1:
        parser.error("element-count must be 1..4096, warmup non-negative, and rounds positive")

    count = args.element_count
    array_type = f"[{count}]usize"
    zeros = f"([_]usize{{0}} ** {count})"
    declaration, array = {
        "array": (f"var values: {array_type} = undefined;", "values"),
        "struct": (f"var state: struct {{ values: {array_type} }} = .{{ .values = {zeros} }};", "state.values"),
        "matrix": (f"var state: [1]{array_type} = .{{{zeros}}};", "state[0]"),
        "optional": (f"var state: ?{array_type} = @as({array_type}, {zeros});", "state.?"),
        "error_union": (f"var state: error{{Missing}}!{array_type} = @as({array_type}, {zeros}); const payload = if (state) |*value| value else |_| unreachable;", "payload.*"),
    }[args.layout]
    elements = {
        "literal": lambda index: str(index),
        "cast": lambda index: f"@as(usize, {index})",
        "dependent": lambda index: f"{array}[{index - 1}] + 1" if index else "0",
        "call": lambda index: f"identity({index})",
    }.get(args.initializer)
    initializer = (
        f"    {array}[0] = 0; for (1..{count}) |index| {array}[index] = {array}[index - 1] + 1;"
        if args.initializer == "loop" else
        f"    {array} = .{{ " + ", ".join(elements(index) for index in range(count)) + " };"
    )
    source = "\n".join((
        "fn identity(value: usize) usize { return value; }",
        "fn Select() type {",
        "    @setEvalBranchQuota(100000);",
        "    " + declaration,
        initializer,
        f"    const length = {array}[{count - 1}];",
        "    return struct { items: [length]u8 };",
        "}",
        "const selected: Select() = undefined;",
        "const field = selected.",
        "",
    ))
    samples = []
    with tempfile.TemporaryDirectory(prefix="zls-comptime-bench-") as directory:
        root = Path(directory)
        config = root / "zls.json"
        config.write_text(json.dumps(dict(enable_build_on_save=False)))
        uri = (root / "comptime.zig").as_uri()
        with (root / "stderr.log").open("w+") as stderr:
            process = subprocess.Popen(
                [str(args.binary.resolve()), "--config-path", str(config)],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr,
            )
            client = Client(process)
            try:
                client.request("initialize", dict(
                    processId=os.getpid(), rootUri=root.as_uri(), capabilities={},
                ))
                client.notify("initialized", {})
                client.notify("textDocument/didOpen", dict(textDocument=dict(
                    uri=uri, languageId="zig", version=1, text=source,
                )))
                for iteration in range(args.warmup + args.rounds):
                    start = time.perf_counter_ns()
                    response = client.request("textDocument/completion", dict(
                        textDocument=dict(uri=uri),
                        position=dict(line=9, character=len("const field = selected.")),
                    ))
                    elapsed_us = (time.perf_counter_ns() - start) / 1000
                    actual = {item["label"]: item.get("detail") for item in (response or {}).get("items", [])}
                    expected = {"items": f"[{count - 1}]u8"}
                    if actual != expected:
                        raise RuntimeError(f"incorrect comptime result: {actual}, expected {expected}")
                    if iteration >= args.warmup:
                        samples.append(elapsed_us)
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

    samples.sort()
    peak_rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    print(json.dumps(dict(
        binary=str(args.binary.resolve()), element_count=count,
        initializer=args.initializer,
        layout=args.layout,
        max_rss_bytes=peak_rss * (1 if sys.platform == "darwin" else 1024),
        source_bytes=len(source.encode()), warmup=args.warmup, rounds=args.rounds,
        median_us=statistics.median(samples), minimum_us=samples[0],
        p90_us=samples[int((len(samples) - 1) * 0.9)], maximum_us=samples[-1],
        samples_us=samples,
    ), indent=2))


if __name__ == "__main__":
    main()
