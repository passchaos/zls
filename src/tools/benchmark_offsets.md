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
