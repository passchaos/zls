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
