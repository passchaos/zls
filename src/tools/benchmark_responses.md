# JSON-RPC response serialization benchmark

Run the benchmark with an optimized build:

```sh
zig build bench-responses -j1 -Doptimize=ReleaseFast -Duse-llvm=true -- 128 2048 512
```

The benchmark serializes representative empty, small, and result-heavy
`workspace/symbol` JSON-RPC responses, reference locations, document
highlights, workspace edits, and `textDocument/publishDiagnostics`
notifications. It directly compares the standard library allocation path, a
4 KiB stack-backed prefix, and capacity hints for large payloads. It reports the
median time from nine samples along with serialized size, a checksum, and
allocation activity for one message. Serialization includes allocation and
returning an exactly sized owned slice; it does not include transport I/O.
The large diagnostic case includes tags and related information on one quarter
of its diagnostics.

## Reference-family response capacity, 2026-09-20

Large reference, document-highlight, and rename responses now reserve a cheap
upper-bound estimate before JSON serialization. The estimate depends only on
item counts and already-owned URI or replacement text lengths. Small responses
continue through the 4 KiB stack prefix.

On AArch64 macOS, Zig 0.16.0, `ReleaseFast`, LLVM, and 4,096 result items, the
capacity hint reduced allocator remap attempts from 12--13 to one. Location
response peak live bytes fell from 685,626 to 557,120 (-18.7%), highlights from
401,127 to 393,280 (-2.0%), and a single-file workspace edit from 603,042 to
446,600 (-25.9%). Response sizes and checksums matched. Serialization medians
stayed within 1%, so no latency improvement is claimed.

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

## Diagnostic notifications

The benchmark also compares the standard allocator path and the 4 KiB stack
prefix for `textDocument/publishDiagnostics`. The representative large case has
512 diagnostics, with tags and related information on one quarter of them. Five
consecutive 128-round runs measured:

| case | standard ns | stack-prefix ns | allocations | peak live bytes |
| --- | ---: | ---: | ---: | ---: |
| empty, 137 B | 258–262 | 211–215 | 3 → 1 | 467 → 137 |
| 8 diagnostics, 2,216 B | 3,288–3,308 | 3,165–3,183 | 5 → 1 | 4,657 → 2,216 |
| 512 diagnostics, 135,084 B | 241,108–246,429 | 236,476–238,471 | 9 → 4 | 186,153 → 186,153 |

A diagnostic-count-only capacity hint was rejected. Diagnostic messages, codes,
tags, related locations, and arbitrary `data` make a cheap estimate unreliable;
an underestimated large hint raised peak live memory from 186,153 bytes. The
stack prefix is retained as the bounded candidate because it improves all three
timings and allocation counts without increasing peak live memory.
