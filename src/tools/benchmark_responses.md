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
