#!/usr/bin/env python3
"""Measure wide comptime struct access through checked LSP completions."""

import argparse
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
from benchmark_lsp_comptime import measure_completion


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--field-count", type=int, default=512)
    parser.add_argument("--iterations", type=int, default=4)
    parser.add_argument("--access", choices=("read", "write", "builtin", "assign", "builtin-assign"), default="write")
    parser.add_argument("--warmup", type=int, default=5)
    parser.add_argument("--rounds", type=int, default=20)
    args = parser.parse_args()
    if not 1 <= args.field_count <= 4096 or not 1 <= args.iterations <= 8:
        parser.error("field-count must be 1..4096 and iterations 1..8")
    if args.warmup < 0 or args.rounds < 1:
        parser.error("warmup must be non-negative and rounds positive")

    names = [f"field_{index}" for index in range(args.field_count)]
    declaration = "const Record = struct { " + ", ".join(f"{name}: usize" for name in names) + " };"
    values = ", ".join(f".{name} = 1" for name in names)
    if args.access == "read":
        storage = f"const state: Record = .{{ {values} }}; var sum: usize = 0;"
        statements = " ".join(f"sum += state.{name};" for name in names)
        length, expected = "sum", args.field_count * args.iterations
    else:
        storage = f"var state: Record = .{{ {values} }};"
        statements = " ".join(
            f'@field(state, "{name}") = @field(state, "{name}") + 1;' if args.access == "builtin-assign" else
            f"state.{name} = state.{name} + 1;" if args.access == "assign" else
            f'@field(state, "{name}") += 1;' if args.access == "builtin" else
            f"state.{name} += 1;"
            for name in names
        )
        length, expected = f"state.{names[-1]}", args.iterations + 1
    source = "\n".join((
        declaration,
        "fn Select() type {",
        "    @setEvalBranchQuota(1000000);",
        "    " + storage,
        f"    for (0..{args.iterations}) |_| {{ {statements} }}",
        f"    const length = {length};",
        "    return struct { items: [length]u8 };",
        "}",
        "const selected: Select() = undefined;",
        "const field = selected.",
        "",
    ))
    metrics = measure_completion(args.binary, source, {"items": f"[{expected}]u8"}, args.warmup, args.rounds)
    print(json.dumps(dict(metrics, field_count=args.field_count, iterations=args.iterations, access=args.access), indent=2))


if __name__ == "__main__":
    main()
