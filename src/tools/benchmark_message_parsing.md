# Inbound LSP message parsing benchmark

Run the benchmark with a real Zig source file:

```sh
zig build bench-message-parsing -j1 -Doptimize=ReleaseFast -Duse-llvm=true -- \
  ~/Work/zig/src/Sema.zig 16
```

The benchmark constructs a `textDocument/didOpen` notification containing the
source and a representative `workspace/symbol` request, then parses them through
the same generated `lsp.Message` parser used by the server. It compares always
copying JSON strings with borrowing unescaped strings when possible. Reported
allocations belong to the parser arena's backing allocator; they are not process
RSS, compiler memory, or cache disk usage.

Checksums must match across modes. The borrowed-field count establishes whether
a result retains pointers into the input JSON and therefore constrains the
input buffer's required lifetime. Source text containing JSON escapes still
requires a decoded allocation even in `alloc_if_needed` mode.

## Initial allocation-mode results

On AArch64 Linux with Zig 0.16.0, `ReleaseFast`, LLVM, and real prefixes of
`Sema.zig`, five consecutive 16-round runs showed:

| message | input bytes | `alloc_always` | `alloc_if_needed` | arena peak (`always` → `if needed`) |
| --- | ---: | ---: | ---: | ---: |
| `workspace/symbol` | 130 | 637–817 ns | 492–527 ns | 864 → 256 B |
| `didOpen`, 64 source bytes | 220 | 865–881 ns | 729–744 ns | 864 → 952 B |
| `didOpen`, 1,024 source bytes | 1,223 | 2,269–2,279 ns | 2,125–2,143 ns | 3,078 → 3,298 B |
| `didOpen`, 64 KiB source | 67,201 | 139,847–150,358 ns | 151,363–163,634 ns | 112,846 → 163,076 B |
| `didOpen`, full 1.50 MB source | 1,535,201 | 4.23–4.90 ms | 4.37–4.74 ms | 4,446,272 → 6,650,140 B |

The real source is escaped when placed in JSON, so `alloc_if_needed` must still
allocate its decoded text. It only borrows the unescaped URI. Arena growth then
becomes less favorable, increasing large-message peak allocation by about 50%.
A global switch to `alloc_if_needed` is therefore rejected. Retaining the input
frame for asynchronously processed borrowed fields would also add its size to
the live set; the parser-only figures above do not count that extra lifetime.
