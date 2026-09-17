# JSON-RPC response serialization benchmark

Run the benchmark with an optimized build:

```sh
zig build bench-responses -j1 -Doptimize=ReleaseFast -Duse-llvm=true -- 128 2048
```

The benchmark serializes representative empty, small, and result-heavy
`workspace/symbol` JSON-RPC responses. It reports the median time from nine
samples along with the serialized size, a checksum, and allocation activity for
one response. Serialization includes allocation and returning an exactly sized
owned slice; it does not include transport I/O.

Compare identical round counts, large-result counts, response byte sizes, and
checksums across revisions. The allocation counters describe allocator requests
made by serialization, not process RSS, compiler memory, or cache disk usage.

## Initial baseline

On AArch64 Linux with Zig 0.16.0, `ReleaseFast`, LLVM, 128 rounds, and
2,048 large-response symbols, five consecutive runs at `b08eef04` measured:

| case | response bytes | median ns/response range | allocations | remap attempts | peak live bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| empty | 36 | 188–353 | 2 | 1 | 168 |
| small (8) | 1,555 | 3,697–3,751 | 4 | 5 | 1,910 |
| large (2,048) | 395,587 | 700,541–746,384 | 9 | 18 | 438,900 |

The transport writes the header and JSON slice directly with vectored I/O, so
these allocations and remap attempts belong to the JSON output buffer rather
than a second transport-side payload copy.

## Stack prefix and workspace-symbol capacity hint

The response serializer now grows through a 4 KiB stack-backed prefix. A
workspace-symbol response additionally reserves `64 + 128 * symbol count` plus
the exact name and URI byte lengths when that estimate exceeds the prefix. The
estimate deliberately leaves normal JSON escaping and numeric-width variation
to the growable writer; underestimation is safe.

Five consecutive runs with the baseline command above gave the following stable
allocation results. The final executable reports its hinted and unhinted large
cases in the same process:

| case | baseline allocations | candidate allocations | baseline peak live | candidate peak live |
| --- | ---: | ---: | ---: | ---: |
| empty | 2 | 1 | 168 B | 36 B |
| small (8) | 4 | 1 | 1,910 B | 1,555 B |
| large (2,048), stack prefix only | 9 | 4 | 438,900 B | 438,900 B |
| large (2,048), capacity hint | 9 | 1 | 438,900 B | 407,616 B |

For the final candidate, empty responses took about 100–104 ns, small responses
2,291–2,373 ns, and large hinted responses 660,070–689,970 ns. The original
baseline ranges were 188–353 ns, 3,697–3,751 ns, and 700,541–746,384 ns. The
large hinted and unhinted candidate timings overlap, so the hint is accepted for
its deterministic allocation-count and peak-live reduction, while the generic
stack prefix accounts for most of the serialization latency improvement.

An eight-run fixed-CPU ABBA end-to-end comparison used the four documented Zig
sources, 16 copies per source, three cycles, and 60 query rounds per cycle. The
candidate and baseline returned identical result counts and checksums. Median
`type` latency changed from 6,471 to 6,328 microseconds (-2.2%), and the median
query phase changed from 1,446 to 1,433 milliseconds (-0.9%). One-copy runs
showed no stable regression for small, empty, or missing-result responses. RSS
varied within the same overlapping range; the allocator counters above, rather
than sampled process RSS, are the evidence for reduced transient response memory.
