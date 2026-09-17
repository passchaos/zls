# Inbound LSP message parsing benchmark

Run the benchmark with a real Zig source file:

```sh
zig build bench-message-parsing -j1 -Doptimize=ReleaseFast -Duse-llvm=true -- \
  ~/Work/zig/src/Sema.zig 16
```

The benchmark constructs `textDocument/didOpen` and `didChange` notifications
containing the source, plus a representative `workspace/symbol` request, then
parses them through the same generated `lsp.Message` parser used by the server.
It compares always copying JSON strings, the production arena-preheat policy,
and borrowing unescaped strings when possible. Reported allocations belong to
the parser arena's backing allocator; they are not process RSS, compiler memory,
or cache disk usage. The final case separately measures applying a parsed
full-document change; those counters cover only `applyContentChanges`.

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

## Large document-sync arena preheating

For JSON frames from 64 KiB through 16 MiB, a bounded, non-allocating top-level
method probe now recognizes `textDocument/didOpen`. It preheats the existing
message arena with the frame length, immediately releases that temporary
allocation inside the arena, and then retains the existing `alloc_always`
parsing semantics. Smaller messages, larger messages, unrecognized methods,
unusual field ordering, and failed probes retain the old behavior.

Repeated 16-round runs over the complete `Sema.zig` payload, including the
bounded method probe, measured:

| message | baseline | preheated | backing allocations | peak live bytes |
| --- | ---: | ---: | ---: | ---: |
| `didOpen` (1,535,201 B) | 4.50–4.77 ms | 4.22–4.32 ms | 9 → 1 | 4,446,272 → 2,302,864 |
| full `didChange` prototype (1,535,205 B) | 5.28–6.02 ms | 4.73–5.06 ms | 10 → 2 | 11,383,854 → 8,002,748 |

A separate 4,096-edit `didChange` case exercises arrays whose decoded storage
is large relative to the frame. Although preheating changed backing allocations
from 18 to 5 and peak live bytes from 9,354,838 to 9,126,766, a final run
regressed from 7.24 to 7.66 milliseconds. The `didChange` production path is
therefore excluded from preheating. The 64 KiB lower threshold leaves all
measured small messages on the original path, avoiding their preheat overhead.
The 16 MiB upper bound caps speculative allocation for unusually large or
invalid frames.

The complete server path was checked separately with fixed CPU affinity. Eight
ABBA runs repeatedly opened and closed one `Sema.zig` document for 50 cycles.
The median open phase changed from 27.09 to 26.14 milliseconds (-3.5%), and the
median observed process peak changed from 15,980 to 13,792 KiB (-13.7%); both
variants had zero closed-RSS growth. A full-document `didChange` prototype also
improved, but it was not accepted because the many-edit guard case above did not
meet the regression gate. Response validation and clean shutdown succeeded in
every end-to-end run.

## Exact full-document change copy

When the last content change replaces the complete document, earlier changes are
irrelevant and no later partial edit needs spare capacity. `applyContentChanges`
therefore copies that final text directly into an exactly sized sentinel slice.
The general ArrayList path remains in use for partial-only changes and for a full
replacement followed by partial changes. Tests cover all three cases and verify
that the fast-path result is independently owned.

With the complete 1,497,031-byte `Sema.zig`, the precise path changed one
allocation plus one successful shrink remap into one exact allocation. Peak
live bytes fell from 2,245,674 to 1,497,032 (-33.3%). Five 32-round paired
microbenchmarks placed the standard path at 430–450 microseconds and the exact
path at 433–452 microseconds, an overlapping range. Eight fixed-CPU ABBA server
runs applied 40 full-document changes each; median synchronized change latency
was 29.68 ms for the baseline and 29.55 ms for the candidate, with identical
successful protocol results. Sampled process-RSS ranges overlapped, so the
accepted benefit is the deterministic transient allocation reduction.
