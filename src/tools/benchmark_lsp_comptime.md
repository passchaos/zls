# Comptime array initialization benchmark

`benchmark_lsp_comptime.py` measures `textDocument/completion` on a type function
that initializes a fixed-size array and uses its last element as a generated
field's array length. Every response is checked against the expected field type
before its latency is accepted.

```sh
zig build -Doptimize=ReleaseSafe
python3 src/tools/benchmark_lsp_comptime.py zig-out/bin/zls --element-count 2048
python3 src/tools/benchmark_lsp_comptime.py /path/to/baseline/zls --element-count 2048
python3 src/tools/benchmark_lsp_comptime.py zig-out/bin/zls --element-count 2048 --initializer dependent
python3 src/tools/benchmark_lsp_comptime.py zig-out/bin/zls --element-count 2048 --initializer loop
python3 src/tools/benchmark_lsp_comptime.py zig-out/bin/zls --element-count 2048 --initializer loop --layout struct
```

The script reports microseconds, excludes five warmup requests by default, and
records twenty measured requests. `--warmup` and `--rounds` configure these
counts. The supported element count is 1 through 4096. The generated function
requests an evaluation quota of 100000 so that the more expensive expressions
also produce concrete results. The interpreter's production default is unchanged.

`--initializer` selects literal elements (the default), `@as` casts (`cast`),
reads of the preceding element (`dependent`), calls to an identity function
(`call`), or a loop reading and incrementing the preceding element (`loop`).
The script also reports the child process's peak resident memory in bytes.

`--layout` selects a standalone array (the default), a struct field (`struct`),
a row of a two-dimensional array (`matrix`), an optional payload (`optional`),
or an error-union payload accessed through a pointer (`error_union`). Nested
layouts start with zero-filled storage so both old and new builds can be timed
independently of support for filling nested `undefined` values.

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

## Array storage reuse

2026-10-09, Apple M1 Pro, macOS, Zig 0.16.0, ReleaseSafe. The baseline is
`fdf98e65`. Each size and initializer used baseline/candidate/candidate/baseline
order after all compilation and tests had finished, with five warmups and twenty
measured completion requests per process. Latencies below are the mean of each
build's two run medians. Memory is the mean of the two process peaks.

| Elements | Initializer | Baseline (us) | Storage reuse (us) | Speedup | Peak memory baseline / candidate (MiB) |
| --- | --- | ---: | ---: | ---: | ---: |
| 512 | literal | 850.31 | 827.43 | 1.03x | 29.57 / 29.59 |
| 512 | cast | 12279.15 | 1290.35 | 9.52x | 38.11 / 29.63 |
| 512 | dependent | 12375.71 | 1399.90 | 8.84x | 38.16 / 29.55 |
| 512 | call | 13534.20 | 2620.56 | 5.16x | 36.34 / 29.60 |
| 512 | loop | 12986.83 | 1844.66 | 7.04x | 37.16 / 29.56 |
| 2048 | literal | 3255.70 | 3143.96 | 1.04x | 29.56 / 29.62 |
| 2048 | cast | 176406.88 | 4895.57 | 36.03x | 458.57 / 29.61 |
| 2048 | dependent | 175713.97 | 5406.22 | 32.50x | 458.93 / 29.58 |
| 2048 | call | 179490.72 | 10160.12 | 17.67x | 460.62 / 29.60 |
| 2048 | loop | 180441.96 | 7588.78 | 23.78x | 458.91 / 29.60 |

Mutable array cells now reuse owned backing storage across element writes.
Publishing a whole-array value freezes that storage, so the next write makes a
copy. Reading an element does not publish the parent array. These workloads
therefore avoid copying the complete array for every initializer or loop step.
The literal case already constructs arrays together; its small timing change
should be interpreted as noise rather than evidence of a separate improvement.

This measures synthetic scalar array workloads, not all comptime programs.
Writing inside nested aggregates still copies their immutable child values,
and whole-array snapshots still require copying on a subsequent write.
The fixtures in `tests/fixtures/comptime_storage.zig` are evaluated by Zig 0.16
and sent to LSP completion tests to verify snapshots, aliases, nested values,
function arguments, local type captures, and index-expression side effects.
The final build passed all 1206 tests plus analysis and build-runner checks;
its 20 storage scenarios also passed an independent JSON-RPC completion probe.

## Nested aggregate storage reuse

2026-10-09, Apple M1 Pro, macOS, Zig 0.16.0, ReleaseSafe. Baseline `0fd579db`
already includes standalone array storage reuse. This comparison uses loop
initialization for all layouts. Each case runs baseline/candidate/candidate/baseline
with five warmups and twenty timed requests per process, after all compilation
and tests have finished. The table reports the mean of two run medians and the
mean of two process memory peaks.

| Elements | Layout | Baseline (us) | Nested storage reuse (us) | Speedup | Peak memory baseline / candidate (MiB) |
| --- | --- | ---: | ---: | ---: | ---: |
| 512 | array | 2257.66 | 2265.16 | 1.00x | 29.65 / 29.63 |
| 512 | struct | 16451.52 | 3844.14 | 4.28x | 40.34 / 29.59 |
| 512 | matrix | 16207.50 | 3009.57 | 5.39x | 40.66 / 29.61 |
| 512 | optional | 15620.73 | 2776.44 | 5.63x | 40.06 / 29.59 |
| 512 | error_union | 16380.49 | 3101.27 | 5.28x | 40.12 / 29.62 |
| 2048 | array | 8330.96 | 8487.81 | 0.98x | 29.62 / 29.62 |
| 2048 | struct | 210222.15 | 13932.49 | 15.09x | 461.16 / 29.57 |
| 2048 | matrix | 207365.86 | 11529.59 | 17.99x | 461.22 / 29.57 |
| 2048 | optional | 206738.32 | 10608.25 | 19.49x | 461.09 / 29.62 |
| 2048 | error_union | 208042.12 | 12222.45 | 17.02x | 460.07 / 29.57 |

At 2048 elements, the four nested layouts improve by 15.1–19.5x. Standalone
array latency increases by 0.3% at 512 elements and 1.9% at 2048 elements in this
comparison; those small differences are near run-to-run variation and are not
claimed as an improvement.

Ownership is now tracked along each aggregate path, including arrays, structs,
optional payloads, and error-union payloads. An escaping subaggregate freezes
only its own subtree; a whole-value snapshot freezes the entire cell. Writing
later copies the frozen path while retaining ownership of unaffected siblings.
Repeated rows initially sharing backing storage become independent on write.
This extends the previous optimization to nested storage without mutating saved
values. Snapshots followed by writes still require copies, and field lookup
within a struct remains linear in its field count.

`tests/fixtures/comptime_nested_storage.zig` adds 14 compiler/LSP scenarios for
subaggregate snapshots, repeated rows, sibling copies, wrapper changes, pointer
aliases, and filling nested undefined arrays/structs. These exposed and now cover
aggregate runtime-type extraction and tagged-union void-field initialization.
The final build passes all 1207 tests, analysis and build-runner checks, plus
34 independent JSON-RPC storage completion probes.
All five layouts and five initializer modes also return the expected field
type at both supported element-count boundaries (1 and 4096; 50 checks).
