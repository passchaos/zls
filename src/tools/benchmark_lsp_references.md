# Reference-family LSP benchmark

Build an optimized server and benchmark a generated document with many
references to one declaration:

```sh
zig build -Doptimize=ReleaseFast -Duse-llvm=true -j1
python3 src/tools/benchmark_lsp_references.py zig-out/bin/zls \
  --method references --reference-count 4096 --warmup 4 --rounds 24
```

The tool runs a real stdio LSP session, negotiates UTF-16 positions, opens one
generated Zig document, and times `textDocument/references`,
`textDocument/documentHighlight`, or `textDocument/rename`. Every timed response
must have the expected item count and the same SHA-256. The output includes all
samples plus median, minimum, p90, and maximum latency.

Use separate binaries and alternate their process order when comparing
revisions. Keep method, reference count, warmup, compiler options, host load,
and response checksum identical. The measurement includes symbol analysis,
range conversion, JSON serialization, protocol transport, and Python decoding.
