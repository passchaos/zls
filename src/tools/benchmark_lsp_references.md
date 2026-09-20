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
URI fields are excluded from the canonical hash so independently launched
processes using different temporary directories remain directly comparable.

Use separate binaries and alternate their process order when comparing
revisions. Keep method, reference count, warmup, compiler options, host load,
and response checksum identical. The measurement includes symbol analysis,
range conversion, JSON serialization, protocol transport, and Python decoding.

## Reference target lookup fast paths, 2026-09-20

The reference collector now resolves the target name once, bypasses alias
resolution when a candidate already equals the final target, and caches the
result for consecutive identifiers in the same leaf lexical block. The cache
is reset between files and re-resolved across nested scopes so shadowing remains
correct. A dedicated nested-shadowing test guards the transition from an outer
symbol into an inner same-name declaration and back.

Four alternating pairs compared the previous position-cursor revision
`d21d20c5` with the candidate on AArch64 macOS, Zig 0.16.0, LLVM, 4,096
references, eight warmups, and 64 timed requests. The median of per-process
medians changed from 6.12 ms to 5.42 ms (-11.4%). Every response contained
4,097 locations with the same canonical SHA-256.
