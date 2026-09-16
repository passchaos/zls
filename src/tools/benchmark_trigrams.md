# Trigram query benchmark

Run from the repository root with Zig 0.16.0:

```sh
zig build bench-trigrams -Doptimize=ReleaseFast -Duse-llvm=true -- 8192 256
zig build bench-trigrams -Doptimize=ReleaseFast -Duse-llvm=true -- --files file.zig ...
```

The optional arguments select the number of generated common-prefix
declarations and the number of queries in each sample. The benchmark reports
the median of nine samples for raw queries, reusable prepared queries, and
transient prepared queries whose construction and destruction are timed on
every iteration. It covers common, rare, near-miss, repeated, and periodic
patterns. Before timing, raw and prepared result slices must have the expected
count and identical declaration indexes. Timed checksums must also remain
identical across all modes, implementations, and revisions.

Use the same compiler options, declaration count, round count, and checksum
when comparing revisions. This is a synthetic TrigramStore microbenchmark, not
an end-to-end LSP latency measurement.

The transient column models a single-store caller deciding whether to prepare
one query just for that lookup. Measurements on 128, 1,024, and 4,096
declarations show no general replacement for the raw path: preparation pays
for repeated and periodic hits but regresses selective and missing queries.
Workspace-symbol therefore keeps raw lookup for a single store.

The `--files` mode separately reports median AST parse and TrigramStore init
time for each real Zig source, followed by declaration, trigram, posting-list,
filter, and maximum-list-size statistics. It does not run query cases. This
prevents parse time from masking changes to index construction. For example, a
proposed per-name adjacent-trigram shortcut improved the synthetic workload by
3.5%, but changed TrigramStore init by only -0.02% on `Sema.zig`, -0.32% on
`array_list.zig`, and -0.19% on `unicode.zig` across 20 counterbalanced runs,
so the production change was rejected.

## Shared posting-builder nodes, 2026-09-16

Measured on aarch64 Linux with Zig 0.16.0, LLVM, and ReleaseFast. The baseline
was `2d124343`; both executables were pinned to the same CPU for 24
counterbalanced runs. The candidate replaces each trigram's 32-byte builder
value and private tail allocation with a 12-byte value and one shared array of
8-byte linked nodes. Final posting slices remain unchanged. Values below are
median TrigramStore init times.

| Source | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| `Sema.zig` | 5,319,063 ns | 5,249,109 ns | -1.3% |
| `array_list.zig` | 375,058 ns | 362,692 ns | -3.3% |
| `unicode.zig` | 356,507 ns | 343,424 ns | -3.7% |
| `Ast.zig` | 567,693 ns | 531,040 ns | -6.5% |

Declaration counts, unique trigram counts, posting counts, singleton and pair
counts, filter counts, longest-list sizes, and filter bytes matched for every
run. The shared pool removes per-posting-list tail allocations without a
second name scan or a second hash-map lookup.

## Direct posting-map construction, 2026-09-16

Measured on aarch64 Linux with Zig 0.16.0, LLVM, and ReleaseFast. The baseline
was `54b6a0d5`; both executables were pinned to the same CPU for 24
counterbalanced runs. The candidate reuses the final posting map while
collecting `{entry, declaration}` occurrences, then fills each posting range
backwards in one pass. Values below are median TrigramStore init times.

| Source | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| `Sema.zig` | 5,278,744 ns | 5,200,596 ns | -1.5% |
| `array_list.zig` | 362,637 ns | 359,400 ns | -0.9% |
| `unicode.zig` | 344,525 ns | 340,270 ns | -1.2% |
| `Ast.zig` | 530,744 ns | 518,027 ns | -2.4% |

All reported index statistics matched. This removes the temporary builder map,
the second map insertion pass, and linked-node traversal while preserving the
final posting map and posting-array layout.

## Bounded raw-trigram deduplication, 2026-09-16

Measured on aarch64 Linux with Zig 0.16.0, LLVM, ReleaseFast, 4,096
declarations per generated symbol family, and 512 rounds per sample. The
baseline was `e34a2b38`; both executables were pinned to the same CPU for 12
counterbalanced runs. The periodic query has 21 characters so the raw path
enters the existing long-query slow path. Values below are median nanoseconds
per query; prepared and transient columns are included to detect collateral
code-layout effects.

| Case | Baseline raw | Candidate raw | Baseline prepared | Candidate prepared |
| --- | ---: | ---: | ---: | ---: |
| common | 12,559 | 11,053 | 12,106 | 10,523 |
| late-selective | 855 | 815 | 674 | 665 |
| early-selective | 500 | 499 | 408 | 406 |
| equal near-miss | 18,733 | 16,820 | 18,497 | 16,755 |
| repeated hit | 17,909 | 1,838 | 1,582 | 1,582 |
| periodic hit | 117,493 | 19,849 | 18,976 | 17,044 |
| repeated miss | 128 | 128 | 82 | 82 |
| missing suffix | 127 | 128 | 82 | 82 |

All result counts and checksums matched. The bounded unique-posting scan
improved raw repeated and periodic hits by 90% and 83%, respectively. It falls
back to the prior replay algorithm after 32 unique trigrams. Other raw and
reusable-prepared cases did not regress.

## Short raw repeated-prefix queries, 2026-09-16

Measured on aarch64 Linux with Zig 0.16.0, LLVM, ReleaseFast, 4,096
declarations per generated symbol family, and 1,024 rounds per sample. The
baseline was `b40d9053`; both executables were pinned to the same CPU for 16
counterbalanced runs. The benchmark adds an eight-character repeated-trigram
hit, which is too short for the long-query rare-posting path.

| Case | Baseline raw | Candidate raw | Baseline prepared | Candidate prepared |
| --- | ---: | ---: | ---: | ---: |
| common | 10,594 | 10,605 | 10,511 | 10,517 |
| late-selective | 816 | 814 | 672 | 674 |
| early-selective | 493 | 499 | 405 | 406 |
| equal near-miss | 16,795 | 16,815 | 16,737 | 16,746 |
| short repeated hit | 7,660 | 1,692 | 1,582 | 1,582 |
| repeated hit | 1,839 | 1,841 | 1,582 | 1,582 |
| periodic hit | 19,958 | 20,024 | 16,959 | 17,061 |
| repeated miss | 128 | 129 | 82 | 82 |
| missing suffix | 128 | 129 | 82 | 82 |

All result counts and checksums matched. A non-inlined path that recognizes an
equal first trigram and skips its later repetitions improved the short raw hit
by 78%. Other changes stayed within 1.2%.

## Adaptive skewed intersection, 2026-09-16

Measured on aarch64 Linux with Zig 0.16.0, LLVM, ReleaseFast, 4,096 generated
common declarations, and 256 rounds per sample. The baseline was `436e3d44`;
the candidate uses monotonic binary searches when one sorted posting list is at
least 64 times longer than the other. Three runs per executable were
counterbalanced. Values below are median nanoseconds per query.

| Case | Baseline raw | Candidate raw | Baseline prepared | Candidate prepared |
| --- | ---: | ---: | ---: | ---: |
| common | 42,945 | 31,095 | 30,216 | 30,192 |
| late-selective | 53,004 | 28,912 | 40,270 | 28,816 |
| early-selective | 114,865 | 503 | 115,245 | 413 |
| repeated miss | 128 | 128 | 83 | 83 |
| missing suffix | 128 | 128 | 83 | 83 |

All result counts and checksums matched. The largest gain is the intended case:
a tiny intermediate candidate set no longer scans a later 4,098-entry posting
list linearly. Similar-sized inputs retain the linear merge path.

## Rare-posting seed selection, 2026-09-16

Measured on aarch64 Linux with Zig 0.16.0, LLVM, ReleaseFast, 4,096 generated
common declarations, and 256 rounds per sample. The baseline was `c8d48c0e`;
the candidate scans long queries whose first two posting lists are large and
starts intersection from the two shortest distinct lists when the shortest is
at least 64 times smaller. The scan and replay live in non-inlined slow paths.
Ten runs per executable were counterbalanced. Values below are median
nanoseconds per query.

| Case | Baseline raw | Candidate raw | Baseline prepared | Candidate prepared |
| --- | ---: | ---: | ---: | ---: |
| common | 31,590 | 31,016 | 30,177 | 30,196 |
| late-selective | 28,912 | 868 | 28,810 | 682 |
| early-selective | 500 | 506 | 414 | 416 |
| repeated miss | 128 | 128 | 83 | 83 |
| missing suffix | 128 | 128 | 83 | 83 |

All result counts and checksums matched across every run. Late-selective
queries improved by about 33 times raw and 42 times prepared. The common
prepared path changed by +0.06%; the raw path improved by 1.82%. Other changes
were within 1.3%.

## Equal-length posting prefixes, 2026-09-16

Measured on aarch64 Linux with Zig 0.16.0, LLVM, ReleaseFast, 4,096
declarations per generated symbol family, and 256 rounds per sample. The
baseline was `3569929b`. The benchmark adds an equal-length near-miss whose
posting lists differ only at the end. Ten runs per executable were
counterbalanced. Values below are median nanoseconds per query.

| Case | Baseline raw | Candidate raw | Baseline prepared | Candidate prepared |
| --- | ---: | ---: | ---: | ---: |
| common | 30,724 | 20,208 | 30,268 | 17,743 |
| late-selective | 851 | 846 | 663 | 660 |
| early-selective | 489 | 489 | 408 | 407 |
| equal near-miss | 7,988 | 6,438 | 7,942 | 6,382 |
| repeated miss | 128 | 128 | 83 | 83 |
| missing suffix | 128 | 128 | 83 | 83 |

All result counts and checksums matched across every run. Common queries
improved by 34% raw and 41% prepared, while the near-miss improved by about
19%. Other changes stayed within 0.6%. At the 160-entry activation boundary,
the common query improved by 34%; inputs below the threshold were unchanged.

## Vectorized posting-prefix scan, 2026-09-16

Measured with the same 4,096-declaration setup and ten counterbalanced runs.
The baseline was `69d0ec02`. The candidate compares posting prefixes in native
SIMD blocks before resuming the scalar merge at the first differing block.

| Case | Baseline raw | Candidate raw | Baseline prepared | Candidate prepared |
| --- | ---: | ---: | ---: | ---: |
| common | 19,065 | 12,096 | 17,758 | 10,526 |
| late-selective | 844 | 850 | 660 | 663 |
| early-selective | 487 | 490 | 407 | 402 |
| equal near-miss | 6,432 | 5,534 | 6,385 | 5,488 |
| repeated miss | 128 | 128 | 83 | 83 |
| missing suffix | 128 | 128 | 83 | 83 |

Counts and checksums remained identical. Common queries improved by 37% raw
and 41% prepared; the equal-length near-miss improved by 14%. Other changes
stayed within 1.1%. At the 160-entry activation boundary, common queries
improved by 31--33%; inputs below the threshold were unchanged within 1%.

## Adjacent prepared-trigram deduplication, 2026-09-16

Measured on aarch64 Linux with Zig 0.16.0, LLVM, ReleaseFast, 4,096
declarations per generated symbol family, and 1,024 rounds per sample. The
baseline was `c5aa7978`; both executables were pinned to the same CPU for 16
counterbalanced runs. The benchmark adds a 20-character repeated-trigram hit.
Values below are median nanoseconds per query.

| Case | Baseline raw | Candidate raw | Baseline prepared | Candidate prepared |
| --- | ---: | ---: | ---: | ---: |
| common | 10,604 | 10,582 | 10,553 | 10,496 |
| late-selective | 868 | 861 | 681 | 679 |
| early-selective | 500 | 501 | 412 | 411 |
| equal near-miss | 5,543 | 5,519 | 5,481 | 5,473 |
| repeated hit | 16,328 | 16,309 | 16,147 | 1,581 |
| repeated miss | 128 | 127 | 82 | 82 |
| missing suffix | 128 | 126 | 82 | 82 |

All result counts and checksums matched. Removing adjacent duplicate trigrams
while preparing a reusable query improved the repeated hit by 90%, avoided its
otherwise unnecessary heap allocation, and left all other cases within 1.6%.

## Bounded prepared-trigram deduplication, 2026-09-16

Measured on aarch64 Linux with Zig 0.16.0, LLVM, ReleaseFast, 4,096
declarations per generated symbol family, and 1,024 rounds per sample. The
baseline was `42231aab`; both executables were pinned to the same CPU for 16
counterbalanced runs. The benchmark adds an 18-character periodic-trigram hit.
Values below are median nanoseconds per query.

| Case | Baseline raw | Candidate raw | Baseline prepared | Candidate prepared |
| --- | ---: | ---: | ---: | ---: |
| common | 10,600 | 10,615 | 10,521 | 10,539 |
| late-selective | 855 | 856 | 673 | 674 |
| early-selective | 497 | 500 | 406 | 409 |
| equal near-miss | 16,781 | 16,795 | 16,759 | 16,758 |
| repeated hit | 16,300 | 16,321 | 1,581 | 1,582 |
| periodic hit | 97,024 | 97,772 | 96,921 | 17,125 |
| repeated miss | 128 | 127 | 82 | 82 |
| missing suffix | 128 | 127 | 82 | 82 |

All result counts and checksums matched. Scanning at most the first 32 retained
trigrams for duplicates improved the periodic hit by 82%. Adjacent duplicates
are still removed at any query length. Other changes stayed within 0.8%.
