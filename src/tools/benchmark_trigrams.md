# Trigram query benchmark

Run from the repository root with Zig 0.16.0:

```sh
zig build bench-trigrams -Doptimize=ReleaseFast -Duse-llvm=true -- 8192 256
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
