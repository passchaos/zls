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
or cache disk usage. The final cases separately measure applying parsed
full-document, single-edit, forward-edit, reverse-edit, and zigzag-edit
changes; those counters cover only `applyContentChanges`.

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
method probe now recognizes `textDocument/didOpen` and
`textDocument/didChange`. It preheats the existing message arena, immediately
releases that temporary allocation inside the arena, and then retains the
existing `alloc_always` parsing semantics. The full frame length is used: a
four-fifths experiment worked for escape-heavy `Sema.zig` but caused a second
large arena node and a large peak-memory regression for an equally sized plain
ASCII source. Smaller messages, larger messages, unrecognized methods, unusual
field ordering, and failed probes retain the old behavior.

Repeated 16-round runs over the complete `Sema.zig` payload, including the
bounded method probe, measured:

| message | baseline | preheated | backing allocations | peak live bytes |
| --- | ---: | ---: | ---: | ---: |
| `didOpen` (1,535,201 B) | 4.50–4.77 ms | 4.22–4.32 ms | 9 → 1 | 4,446,272 → 2,302,864 |
| full `didChange` prototype (1,535,205 B) | 5.28–6.02 ms | 4.73–5.06 ms | 10 → 2 | 11,383,854 → 8,002,748 |

A separate 4,096-edit `didChange` case exercises arrays whose decoded storage
is large relative to the frame. Although preheating changed backing allocations
from 18 to 5 and peak live bytes from 9,354,838 to 9,126,766, a final run
regressed from 7.24 to 7.66 milliseconds. Preheating the generated `didChange`
parser was therefore rejected on its own. The 64 KiB lower threshold leaves all
measured small messages on the original path, avoiding their preheat overhead.
The 16 MiB upper bound caps speculative allocation for unusually large or
invalid frames. The later streaming parser removes the dynamic JSON tree that
caused this regression, allowing the combined streaming-plus-preheat path to
pass both full-change and many-edit gates.

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
The general ArrayList path remains in use when multiple partial changes follow.
Tests cover each combination and verify that fast-path results are independently
owned.

With the complete 1,497,031-byte `Sema.zig`, the precise path changed one
allocation plus one successful shrink remap into one exact allocation. Peak
live bytes fell from 2,245,674 to 1,497,032 (-33.3%). Five 32-round paired
microbenchmarks placed the standard path at 430–450 microseconds and the exact
path at 433–452 microseconds, an overlapping range. Eight fixed-CPU ABBA server
runs applied 40 full-document changes each; median synchronized change latency
was 29.68 ms for the baseline and 29.55 ms for the candidate, with identical
successful protocol results. Sampled process-RSS ranges overlapped, so the
accepted benefit is the deterministic transient allocation reduction.

## Bidirectional position cursor and exact edit paths

Applying every partial change previously converted its range by scanning from
the beginning of the current document. A batch of edits ordered from the start
of the document toward the end therefore repeatedly traversed the same prefix.
`applyContentChanges` now retains the byte index and LSP position reached by the
previous edit and scans in either direction from the nearer known point. After
a replacement, the cursor advances across the inserted text, including Unicode
code units and newlines. Differential tests compare the cursor with
`rangeToLoc` for UTF-8, UTF-16, and UTF-32, forward and backward ranges, CRLF
text, out-of-range positions, and 128 deterministic mixed replacements.

Two copying paths avoid unnecessary ArrayList work. Equal-byte-length edits
overwrite their target slice directly because no tail movement is required. A
single partial change constructs its final sentinel slice at the exact size,
copying the prefix, replacement, and suffix once. Tests cover equal, growing,
shrinking, Unicode, newline, independent ownership, and allocation failures.

With 4,096 valid single-character edits over the complete `Sema.zig`, repeated
paired microbenchmarks measured forward application at 355.6–364.2 ms for the
frozen baseline and 141.0–145.8 ms for the cursor path, about 60% faster. The
reverse-order guard case measured 353.0–371.9 ms versus 287.7–291.4 ms, a
19–22% improvement even though every edit forces a reset. Four repeated
single-edit measurements had overlapping ranges of 483–503 microseconds for
the baseline and 483–502 microseconds for the cursor path, with the paired
difference ranging from -0.7% to +0.15%; there is no stable common-path
regression. Output lengths, checksums, allocation counts, and peak live bytes
matched in every partial-edit comparison.

Four end-to-end ABBA pairs sent the 4,096-edit notification to baseline and
candidate ZLS binaries. Per-pair candidate medians were 146.3–150.5 ms versus
373.8–378.7 ms for the baseline; the aggregate median changed from about 376.0
to 150.2 ms (-60%). Every run synchronized successfully, shut down cleanly, and
returned status zero.

The follow-up bidirectional cursor reduced reverse-order application to
140.8–147.1 ms and a pairwise zigzag order to 140.8–146.0 ms before copy-path
changes. The equal-length overwrite then reduced forward, reverse, and zigzag
application to 13.4–14.8 ms in repeated runs. This is about 96% below the
frozen 360–386 ms baseline while preserving its output checksum and its one
allocation, one shrink remap, and 2,245,674-byte peak live allocation profile.

The exact single-partial path changed one allocation plus one shrink remap into
one exact allocation. On the 1,497,031-byte source, peak live bytes fell from
2,245,674 to 1,497,032 (-33.3%), while three paired runs improved from
474–496 to 429–450 microseconds.

Four fixed-CPU ABBA pairs exercised the complete server path with one 4,096
reverse-order edit notification. The previous production binary had a 281.0 ms
median and the final candidate a 27.7 ms median (-90.1%). Every process
initialized, synchronized the open document, applied the change, returned a
successful shutdown response, exited cleanly, and returned status zero.
A final rebuild containing the exact single-partial path repeated two ABBA
pairs at 315.7 ms versus 32.6 ms (-89.7%), confirming the same result.

## Streaming document-change parser

The generated `ContentChangeEvent` union parser first constructs a full
`std.json.Value` tree for every change and then converts that tree to the typed
union. ZLS now parses the three content-change fields directly from the token
stream while retaining the generated `Range`, `Position`, and string parsers.
The public handler still receives the standard LSP `DidChangeParams`; the
internal wrapper converts to it with a slice view and no allocation. Tests cover
whole and partial changes, null ranges, unknown fields, malformed and duplicate
fields, both top-level `method`/`params` orders, and every allocator failure
point.

Five 16-round runs over the complete `Sema.zig` payload measured full-change
parsing at 5.39–5.82 ms and 11,383,854 peak live bytes on the generated parser,
versus 4.20–4.49 ms and 2,302,870 bytes with streaming parsing plus the bounded
arena preheat. Backing allocations fell from 10 to 1. A separate 4,096-edit
message changed from 6.97–8.49 ms and 9,354,838 bytes to 2.31–2.33 ms and
685,080 bytes, with backing allocations falling from 18 to 1.
For small messages, a 224-byte whole-document change improved from 1,061–1,073
to 867–875 nanoseconds, and a 253-byte single partial edit improved from
1,951–1,982 to 1,199–1,208 nanoseconds. Their peak arena allocations fell from
2,734 and 2,950 bytes respectively to 864 bytes, so the optimization does not
trade large-message gains for a small-edit regression.

Eight fixed-CPU ABBA server runs applied 40 full-document changes each. Median
synchronized change latency changed from 26.4 to 25.7 milliseconds (-2.7%), and
median observed peak RSS from about 25.7 to 21.2 MiB (-17.5%). Another eight
runs applied 4,096 valid partial edits ten times; median change latency changed
from 383.9 to 369.6 milliseconds (-3.7%). All runs completed request
synchronization and clean shutdown successfully.
