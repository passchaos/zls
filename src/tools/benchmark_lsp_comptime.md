# Comptime array initialization benchmark

`benchmark_lsp_comptime.py` measures `textDocument/completion` on a type function
that initializes a fixed-size array from an anonymous literal and uses its last
element as a generated field's array length. Every response is checked against
the expected field type before its latency is accepted.

```sh
zig build -Doptimize=ReleaseSafe
python3 src/tools/benchmark_lsp_comptime.py zig-out/bin/zls --element-count 2048
python3 src/tools/benchmark_lsp_comptime.py /path/to/baseline/zls --element-count 2048
```

The script reports microseconds, excludes five warmup requests by default, and
records twenty measured requests. `--warmup` and `--rounds` configure these
counts. The supported element count is 1 through 4096, keeping the fixture
within the interpreter's default evaluation budget.

Run baseline and candidate builds alternately, after compilation has finished.
This case checks that handling result pointers does not turn a literal array
initializer into repeated copies of its entire backing storage. Literals have
no reads or side effects that could observe intermediate stores, so they can
be constructed together.

## Recorded comparison

2026-10-08, Apple Silicon macOS, Zig 0.16.0, ReleaseSafe. The baseline is
`6f747382`. Runs used baseline/candidate/candidate/baseline order for each size;
the table reports the mean of each build's two run medians.

| Elements | Baseline | Aggregate result location implementation | Change |
| --- | ---: | ---: | ---: |
| 512 | 825.27 us | 828.55 us | +0.4% |
| 2048 | 3138.64 us | 3212.19 us | +2.3% |

At these input sizes, request latency scales approximately linearly with the
element count. These small timing differences should be interpreted alongside
run-to-run noise. Evaluation semantics are checked separately by the shared
compiler/LSP fixtures in `tests/fixtures/comptime_result_locations.zig`.
