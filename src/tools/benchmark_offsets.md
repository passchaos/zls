# Source position benchmark

Run from the repository root with Zig 0.16.0:

```sh
zig build bench-offsets -Doptimize=ReleaseFast -Duse-llvm=true -- \
  ~/Work/zig/src/Sema.zig \
  ~/Work/zig/lib/std/array_list.zig \
  ~/Work/zig/lib/std/unicode.zig
```

The benchmark parses each file outside the timed region and advances positions
to every token, every 64th token, or every 1024th token, then to EOF. It covers
UTF-8, UTF-16, and UTF-32. Before timing, an independent UTF-8 decoder checks every
endpoint. Each measurement reports the median of seven batches, each scanning
approximately 16 MiB, with a minimum of one file scan. Input memory barriers
prevent the compiler from reusing a previous scan's result. The printed checksum
must match when comparing the same inputs and benchmark harness across revisions.

The same executable also measures 256 byte-uniform `(line, character)` to byte
index queries and short range conversions against the frozen lsp-kit
implementation. It includes one long ASCII line and a dense-newline synthetic
input as regression guards.

It also compares batched index and location conversions against allocation-based
copies of the previous implementations. Batch sizes straddle the stack-buffer
cutoffs, and checksums must match between baseline and production.

## Small batch allocation removal, 2026-09-18

The batched `indexToPosition` and `locToRange` helpers now keep up to 64 mapping
records on the stack. This covers up to 64 indices or 32 locations without a
temporary allocator call; larger batches retain the prior heap path. Tests use a
failing allocator to prove the small paths do not allocate, exercise both sides
of each cutoff, and compare UTF-8, UTF-16, and UTF-32 results with the single-item
conversions.

On AArch64 Linux, Zig 0.16.0, `ReleaseFast`, LLVM, the `build.zig` benchmark
measured the one-item allocation-dominated cases as follows:

| operation | allocation baseline | stack production | change |
| --- | ---: | ---: | ---: |
| batch index to position | 26 ns | 6 ns | -77% |
| batch location to range | 39 ns | 22 ns | -44% |

For batches of 8 through 128, source scanning and sorting dominate: production
was within 1% of baseline in this run. Checksums matched at every measured batch
size. In the arena-backed feature call sites, the fast path also avoids retaining
up to 1 KiB of temporary mapping storage until the request arena is released.

## Ordered batch fast path, 2026-09-18

Mapping batches are now checked for source order before invoking the stable sort.
This is an O(n) pass that returns immediately on the first inversion. It avoids
sorting entirely for callers that naturally emit mappings in source order, while
retaining the original stable sort for arbitrary input.

On the same AArch64 setup, ordered batches of 8 through 128 improved by 1% to 7%
for both batch helpers. At 128 items, location-to-range fell from 9,628 ns to
8,962 ns (-6.9%), and index-to-position fell from 7,414 ns to 7,096 ns (-4.3%).
Reversed and interleaved controls remained within 1% of the baseline. Checksums
matched for every order and batch size.

The public batch helpers additionally bypass mapping construction when their
native inputs are ordered: nondecreasing indices for `indexToPosition`, or
non-overlapping locations for `locToRange`. This makes ordered batches of any
size allocation-free. Tests exercise 65 indices and 33 locations with a failing
allocator under all three encodings. On `build.zig`, the 128-item mapping
baseline versus direct production path measured 7,068 versus 7,027 ns for
indices and 9,001 versus 8,818 ns for locations. Reversed, interleaved, and
last-pair-swapped inputs preserve the mapping fallback and remained within 2%.

## Inlay hint output conversion, 2026-09-18

Inlay hint conversion now sorts its internal records only when necessary and
writes positions directly into the final protocol response. This removes the
temporary source-index and position arrays, reducing the conversion stage from
three allocations to one. A failing-allocator test enforces the single-allocation
bound and checks stable duplicate ordering and Unicode positions.

A fixed-CPU LSP benchmark generated 4,096 two-argument calls and requested the
resulting 8,192 hints. Across eight alternating baseline/candidate processes,
each timed over 40 warmed requests, the median request time changed from 27.65 ms
to 27.10 ms (-2.0%). Every run returned the same hint count and response SHA-256.

## Folding range output conversion, 2026-09-18

Folding range conversion now writes positions into the final protocol objects
and compacts single-line ranges in place. Compact integer mapping slots preserve
the original output order without keeping a parallel `Range` array. This reduces
the conversion from three allocations to one for up to 32 candidate ranges and
to two for larger batches. Failing-allocator tests enforce both bounds.

A fixed-CPU LSP benchmark generated 4,096 functions with nested blocks and
requested 8,192 folding ranges. Across eight alternating baseline/candidate
processes, each timed over 80 warmed requests, median request time was 7.96 ms
versus 7.91 ms. Every run returned the same range count and response SHA-256.

## Document symbol mapping compaction, 2026-09-18

Document symbol conversion now stores each position target as two `u32` values:
the source index and an output slot. This halves mapping storage from 16 to 8
bytes, or from 64 to 32 bytes per symbol, while preserving the hierarchical
output layout. Mapping storage for up to 16 symbols stays on the stack; a
failing-allocator test enforces that small-document behavior.

A fixed-CPU LSP benchmark generated 8,192 declarations and requested their
hierarchical document symbols. Across eight alternating baseline/candidate
processes, each timed over 50 warmed requests, median request time changed from
44.94 ms to 44.20 ms (-1.6%). Every run returned the same root symbol count and
full response SHA-256.

## SIMD position-to-index scanning, 2026-09-17

LSP requests supply `(line, character)` positions, while ZLS analysis uses byte
indices. The lsp-kit baseline examines every byte before the target line. ZLS
now counts newlines one SIMD block at a time, skipping blocks whose newline
count is below the remaining target, then resolves the target character with
the existing UTF-8/16/32 conversion. Non-LLVM builds retain the scalar path.

On AArch64 Linux, Zig 0.16.0, `ReleaseFast`, LLVM, one paired run measured:

| source / operation | baseline | SIMD production | change |
| --- | ---: | ---: | ---: |
| `Sema.zig`, position | 440–442 µs/query | 95–96 µs/query | about -78% |
| `Sema.zig`, short range | 441–442 µs/query | 95–97 µs/query | about -78% |
| `x86_64/CodeGen.zig`, position | 3.218–3.223 ms/query | 0.703–0.709 ms/query | about -78% |
| `x86_64/CodeGen.zig`, short range | 3.215–3.228 ms/query | 0.705–0.710 ms/query | about -78% |
| 2 MiB of newlines, range | 616 µs/query | 134 µs/query | about -78% |
| one 256 KiB ASCII line, range | 35 µs/query | 35 µs/query | unchanged |

Checksums matched for UTF-8, UTF-16, and UTF-32 in every case. The dense
newline input guards against an earlier per-newline `findScalarPos` prototype
that was roughly 24 times slower than the baseline and was rejected.

Eight fixed-CPU ABBA pairs opened the complete `Sema.zig`, synchronized the
document, and issued 200 `textDocument/hover` requests for a local variable near
the end of the 34,840-line file. Median request-batch time changed from 239.67
to 95.72 ms (-60.1%). Every response was non-null; all pairs returned the same
hover-result hash and completed clean LSP shutdown with status zero.

Another eight ABBA pairs issued 200 `textDocument/semanticTokens/range`
requests over the final 20 lines. Median request-batch time changed from
1,021.12 to 882.66 ms (-13.6%). Token data was non-empty, response hashes
matched across variants, and every process shut down cleanly.

## UTF-32 long-span optimization, 2026-09-16

Measured on aarch64 Linux with Zig 0.16.0, LLVM, and ReleaseFast. Source inputs
were from Zig revision `7056ba9a5c`. The baseline was ZLS `833b8116` with only the
benchmark harness added; the candidate added the UTF-32 position optimization.
Three runs per executable alternated their order. Values below are medians of
the three reported times, in microseconds per file scan.

| Input | Token stride | Baseline (µs) | Optimized (µs) | Speedup |
| --- | ---: | ---: | ---: | ---: |
| Sema.zig | 1 | 2506.951 | 2465.378 | 1.02× |
| Sema.zig | 64 | 1181.822 | 372.989 | 3.17× |
| Sema.zig | 1024 | 1155.393 | 183.657 | 6.29× |
| array_list.zig | 1 | 109.531 | 100.452 | 1.09× |
| array_list.zig | 64 | 76.094 | 19.144 | 3.97× |
| array_list.zig | 1024 | 75.052 | 11.776 | 6.37× |
| unicode.zig | 1 | 99.432 | 99.143 | 1.00× |
| unicode.zig | 64 | 66.366 | 17.542 | 3.78× |
| unicode.zig | 1024 | 65.422 | 10.307 | 6.35× |
| Long ASCII line | 1 | 50.524 | 32.774 | 1.54× |
| Long Unicode line | 1 | 56.826 | 37.131 | 1.53× |

The long-line cases use a file containing `const text = "` followed by either
65,536 ASCII `a` characters or 8,192 repetitions of `¶↉🠁`, then `";`, with no
newline. They check that an extra newline-counting pass does not penalize long
spans without line breaks. All 45 input/stride/encoding configurations had
matching checksums across all six runs.

These are position-conversion measurements on one host, not end-to-end LSP
latencies. Short, dense spans change little. Workloads with long UTF-32 spans
benefit most; the UTF-8 and UTF-16 implementations are unchanged.

## UTF-16 long-span optimization, 2026-09-16

Measured on aarch64 Linux with Zig 0.16.0, LLVM, and ReleaseFast. The input was
Zig revision `7056ba9a5c`'s 1,497,031-byte `src/Sema.zig`. The baseline was ZLS
`90469930`; the candidate vectorizes UTF-16 code-unit counting after the last
newline in long spans. Three runs per executable alternated their order. Values
below are medians of the three reported times.

| Token stride | Baseline (µs) | Optimized (µs) | Speedup |
| ---: | ---: | ---: | ---: |
| 1 | 2438.708 | 2399.600 | 1.02× |
| 64 | 403.949 | 361.206 | 1.12× |
| 1024 | 187.011 | 183.052 | 1.02× |

Checksums matched for every encoding and stride. UTF-8 and UTF-32 were measured
in the same runs as controls; their variation was small enough that no change
is claimed. The optimization allocates no memory.
