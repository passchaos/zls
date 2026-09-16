# Trigram query benchmark

Run from the repository root with Zig 0.16.0:

```sh
zig build bench-trigrams -Doptimize=ReleaseFast -Duse-llvm=true -- 8192 256
```

The optional arguments select the number of generated common-prefix
declarations and the number of queries in each sample. The benchmark reports
the median of nine samples for raw and prepared queries. It covers a common
query, rare suffix and prefix hits, a repeated-pattern miss, and a missing
suffix. Before timing, raw and prepared result slices must have the expected
count and identical declaration indexes. Timed checksums must also remain
identical across implementations and revisions.

Use the same compiler options, declaration count, round count, and checksum
when comparing revisions. This is a synthetic TrigramStore microbenchmark, not
an end-to-end LSP latency measurement.

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
