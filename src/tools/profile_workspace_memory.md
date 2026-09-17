# Workspace memory profile

On Linux, build a release executable with one build job, then run:

```sh
zig build -j1 -Doptimize=ReleaseFast -Duse-llvm=true --summary all
python3 src/tools/profile_workspace_memory.py zig-out/bin/zls \
  ~/Work/zig/src/Sema.zig \
  ~/Work/zig/lib/std/array_list.zig \
  ~/Work/zig/lib/std/unicode.zig > memory.json
```

The script negotiates UTF-16, opens the supplied source contents under temporary
workspace URIs, queries workspace symbols, and closes the documents. By default,
it repeats this lifecycle five times with 20 rounds of four queries per cycle.
It records RSS, its anonymous/file/shared breakdown, swap, virtual size, thread
count, the kernel's resident-memory high-water mark, and a monotonic observed
peak after each phase. The observed peak also includes samples taken while
waiting for replies. Symbol counts and sorted result checksums must remain stable
across all cycles. A successful run also requires a clean LSP shutdown and
process exit. A top-level summary reports the peak and the RSS change between
the first and final closed-document checkpoints. Captured server stderr is also
included so DebugAllocator leak reports and runtime errors are not lost. Median
phase times separate opening/parsing, querying, and closing; each phase ends in
a request/response synchronization point.

The temporary workspace avoids starting the source project's build. Diagnostics
are not advertised and build-on-save is disabled. Imports are not traversed for
workspace symbol indexing. Consequently, this measures document storage, symbol
indexes, position conversion, and query responses; it does not cover semantic
analysis, diagnostics, a full Zig workspace, or build subprocesses. Request
times include protocol transport and Python decoding. Use the position benchmark
for measuring position conversion alone.

`--cycles` and `--rounds` control repetition. Set `--rounds 0` to isolate
document open/close costs without building or querying symbol indexes.
`--extra-empty-documents N` adds N empty Zig documents to every lifecycle.
This isolates per-handle workspace-symbol filtering, list construction, lazy
index loading, and close bookkeeping without increasing symbol result size.
`--copies-per-source N` opens N uniquely named copies of every supplied source.
This measures many non-empty, cached indexes while preserving per-copy result
identity in the checksum.
`--max-rss-mib` defaults to 2048;
the script checks ZLS memory while waiting for replies and after each phase and
terminates its child on failure. This is a sampled safeguard, not an OS memory
limit. Each request has a 60-second response deadline. RSS includes allocator
retention and is not a measurement of live allocations or proof of a leak.
Compare phase trends and identical result checksums before interpreting changes.

Compile-time `MaxRSS` from `zig build --summary all` belongs to build steps;
the JSON produced by this script measures only the running ZLS process. Keep
these separate when investigating a large memory peak. LLVM ReleaseFast builds
can consume orders of magnitude more memory than the resulting server process;
use `-j1` to prevent concurrent compile steps from multiplying that peak. Disk
usage under `.zig-cache` is a third, independent measurement.

## Large handle-set scanning, 2026-09-16

The `--extra-empty-documents` mode compared baseline `bc1a42e3` with a candidate
that scans the document-store handle array under one mutex acquisition instead
of locking once per handle. Twelve fixed-CPU runs used one `Sema.zig` document,
256 empty documents, three cycles, and 100 query rounds per cycle. Median
missing-symbol request time changed from 231.7 to 211.2 microseconds (-8.8%),
the query phase from 318.7 to 312.8 milliseconds (-1.8%), and total runtime
from 1.141 to 1.103 seconds (-3.3%). Symbol counts and checksums matched.

A separate twelve-run workload used 20 cycles and `--rounds 0`. Both variants
had exactly 136 KiB median closed-RSS growth and essentially identical final
closed RSS. Median observed peaks, 15,974 and 16,494 KiB, stayed within heavily
overlapping run-to-run ranges. The change adds no allocations or persistent
state; it only coalesces the existing mutex critical sections.

## Empty trigram-store filtering, 2026-09-16

Measured against `294e13da` with one `Sema.zig` document, 256 empty documents,
three cycles, and 100 query rounds per cycle. Sixteen fixed-CPU
counterbalanced runs showed that removing already-loaded empty trigram stores
from the per-request handle list changed median missing-symbol latency from
200.8 to 185.0 microseconds (-7.9%), the query phase from 312.8 to 292.4
milliseconds (-6.5%), and total runtime from 1.132 to 1.085 seconds (-4.2%).
Result counts and checksums matched. Empty stores are removed after their first
lazy load and skipped directly on later requests; non-empty handle order is
preserved.

Twelve additional 20-cycle runs with `--rounds 0` showed identical median
closed-RSS growth of 136 KiB and effectively identical final closed RSS. The
change adds no persistent cache or allocation.

## Root-empty handle filtering, 2026-09-16

Measured against `704823b2` with one `Sema.zig` document, 256 empty documents,
three cycles, and 100 query rounds per cycle. Sixteen fixed-CPU
counterbalanced runs showed that rejecting handles whose AST has no root
declarations before lazy trigram-store loading changed median missing-symbol
latency from 202.2 to 155.3 microseconds (-23.2%), parse-miss latency from
203.7 to 179.6 microseconds (-11.8%), and the query phase from 308.7 to 297.6
milliseconds (-3.6%). Result counts and checksums matched.

Sixteen additional 20-cycle runs with `--rounds 0` changed median open time
from 33.52 to 32.95 milliseconds and total runtime from 793 to 777
milliseconds. Both variants had exactly 136 KiB median closed-RSS growth and
the same 3,560 KiB median final closed RSS. Empty/comment-only ASTs and a
minimal declaration are covered directly by unit tests.

Checking root emptiness before URI scheme/path filtering removes the remaining
per-handle URI work for empty documents. Against `0908e767`, sixteen fixed-CPU
runs with the same 256-empty-document query workload changed median missing
latency from 115.4 to 86.1 microseconds (-25%), query-phase time from 184.6 to
162.9 milliseconds (-11.8%), and total runtime from 735 to 660 milliseconds
(-10.2%). Median closed-RSS growth was unchanged at 2,080 KiB and the observed
peak decreased slightly.

## Reference run, 2026-09-16

On aarch64 Linux with Zig 0.16.0 and ZLS baseline `90469930`, a cold, single-job
LLVM ReleaseFast build reported approximately 2 GiB `MaxRSS`. The resulting ZLS
process was then exercised with the three Zig files in the example above for 100
open/query/close cycles and 20 rounds of four queries per cycle. It reached a
31,340 KiB observed RSS peak, and its closed-document RSS increased from 7,048
to 21,068 KiB. The UTF-16 long-span candidate reached 32,560 KiB, increasing from
5,448 to 22,880 KiB. Neither process used swap, and result counts and checksums
matched throughout.

The gradual anonymous-RSS growth occurred in both revisions. A 20-cycle Debug
build using DebugAllocator exited without a leak report; its closed-document RSS
increased by only 1,052 KiB. This points to ReleaseFast's `smp_allocator` retaining
freed pages in thread-local caches rather than live document objects leaking. The
small difference between revisions is not treated as a memory optimization or a
regression; the useful conclusion is that the position optimization adds no
allocations and does not materially change resident memory.

An orthogonal run on `5b60bf2f` used 100 cycles with `--rounds 0`. It reached a
20,304 KiB peak and closed-document RSS increased from 3,396 to 10,388 KiB. A
single cycle with 2,000 rounds (8,000 queries) reached only 13,008 KiB and had no
cross-cycle growth. This isolates the gradual RSS retention to repeated document
parse/open/close lifecycles rather than workspace-symbol query arenas.

At 1,000 zero-query cycles, RSS was still increasing: the observed peak was
54,076 KiB and closed-document RSS rose from 5,056 to 39,128 KiB, with no swap.
In contrast, repeating the same test with a 77-byte Zig file changed closed RSS
by only 8 KiB and stabilized in the first 100 cycles. The retention therefore
depends on document parse/storage allocation sizes, not just message count.

## Reclaimable document analysis arenas, 2026-09-16

In ordinary multithreaded Release builds using `SmpAllocator`, sources of at
least `max(page_size_max, 64 KiB)` keep each document's AST, scope, and trigram
index in a page-backed arena and return the arena when the document is refreshed
or closed. Smaller files and diagnostic allocator modes retain the existing
path. Three runs per executable in counterbalanced order used the 100-cycle,
20-round workload above to compare runtime baseline `9e159ba1` with the candidate
based on `7067e301`; the intervening commit changed only this profiling tool and
its documentation. Median results were:

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Observed peak RSS | 28,800 KiB | 21,668 KiB | -24.8% |
| Final closed RSS | 19,340 KiB | 9,644 KiB | -50.1% |
| Closed RSS growth | 12,176 KiB | 2,576 KiB | -78.8% |
| Median open phase | 67.370 ms | 68.168 ms | +1.2% |
| Median query phase | 66.504 ms | 68.401 ms | +2.9% |
| Median close phase | 2.040 ms | 1.903 ms | -6.7% |
| Total runtime | 13.353 s | 13.871 s | +3.9% |

All result counts and checksums matched. The small open/query regressions are
the measured cost of bulk-owned arenas. A
1,000-cycle zero-query candidate run stabilized after cycle 300: closed RSS rose
1,556 KiB (3,232 to 4,788 KiB) and the observed peak was 17,912 KiB. The last
700 cycles had no further growth. The baseline did not stabilize over 1,000
cycles and rose by 34,072 KiB, reaching a 54,076 KiB peak. A separate
32-document resident-set comparison exposed the arena's transient index-build
capacity: median peak RSS increased from 23,888 to 26,328 KiB (+10.2%), while
RSS after closing fell from 14,544 to 11,864 KiB (-18.4%) and total runtime rose
from 145 to 158 ms (+9.0%). This peak/latency tradeoff is separate from the
repeated lifecycle stress result.

## Arena-backed trigram declaration capacity, 2026-09-16

The ordinary allocator path keeps its existing adaptive declaration estimate.
When a document already owns a page-backed analysis arena, TrigramStore now
uses the AST root-declaration count as an additional capacity lower bound. Old
growth allocations cannot be individually reclaimed from an arena, so avoiding
them improves both construction time and transient memory without affecting the
final compacted index.

Twelve fixed-CPU counterbalanced runs compared baseline `fffd817b` with the
candidate over 20 open/close cycles and `--rounds 0`, using `Sema.zig`,
`array_list.zig`, and `unicode.zig`. Median open time changed from 60.21 to
49.47 ms (-17.8%) and total runtime from 1,194 to 1,025 ms (-14.1%). Median
observed peak changed from 15,720 to 15,624 KiB, while both variants had exactly
44 KiB closed-RSS growth.

## Lazy workspace-symbol declaration lines, 2026-09-17

Measured against `91dd1006` with one and sixteen copies of `Sema.zig`. The
candidate reuses the existing four-byte declaration metadata slot: before a
declaration is returned it stores the token byte length and ASCII flag; after
the first result it atomically replaces the length with the immutable source
line while preserving the ASCII flag. Later requests scan only the token's
current line instead of rescanning from the beginning of the file.

Twelve fixed-CPU counterbalanced runs used three lifecycle cycles and 60 rounds
per cycle. Median request times were:

| Workload | Metric | Baseline | Candidate | Change |
| --- | --- | ---: | ---: | ---: |
| 16 copies | `type` request | 8,010 us | 3,406 us | -57.5% |
| 16 copies | query phase | 1,177,216 us | 865,592 us | -26.5% |
| 1 copy | `type` request | 431 us | 217 us | -49.7% |
| 1 copy | query phase | 81,428 us | 67,036 us | -17.7% |

All result counts and checksums matched and stderr stayed empty. A separate
64-run real-file index-build comparison kept initialization within -0.08% to
-0.39% across `Sema.zig`, `Ast.zig`, `array_list.zig`, and `unicode.zig`;
allocation counts, requested bytes, peak live bytes, and index shapes were
identical. Cold-cache requests with one round per lifecycle had paired median
changes within 0.4% for `type` and `allocator`; noisier sixteen-copy runs kept
the complete query phase within +0.2%. Twelve ten-cycle, zero-query runs had
identical 2,732 KiB first/final closed RSS and zero closed-RSS growth.

## Compact workspace-symbol result records, 2026-09-17

ZLS does not currently attach resolve data to workspace symbols and always
returns complete locations. The handler therefore uses the protocol-equivalent
`SymbolInformation` result variant rather than `WorkspaceSymbol`. With null
optional fields omitted, a unit test verifies that both representations produce
identical JSON. On AArch64, the in-memory result record decreases from 152 to
88 bytes, saving 64 bytes per result in the request arena; a 1,904-result query
therefore saves approximately 119 KiB before serialization.

Eight fixed-CPU ABBA runs used the four documented Zig sources, three cycles,
60 query rounds, and 16 copies per source. Result counts and sorted JSON-derived
checksums matched. The paired median `type` request changed by approximately
-1.1%, and the complete query phase by approximately -0.5%. A second eight-run
comparison used one copy and 100 rounds; the `type` request improved about 0.3%
and the complete query phase about 0.2%. These small timing changes are treated
as confirmation that the deterministic arena-memory reduction has no material
latency cost, not as a primary speed claim.
