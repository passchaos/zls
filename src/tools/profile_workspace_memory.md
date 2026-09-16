# Workspace memory profile

On Linux, build a release executable with one build job, then run:

```sh
zig build -j1 -Doptimize=ReleaseFast -Duse-llvm=true --summary all
python3 src/tools/profile_workspace_memory.py zig-out/bin/zls \
  ~/Work/zig/src/Sema.zig \
  ~/Work/zig/lib/std/array_list.zig \
  ~/Work/zig/lib/std/unicode.zig > memory.json
```

The script negotiates UTF-16, opens the supplied source contents under temporary
workspace URIs, queries workspace symbols, and closes the documents. By default,
it repeats this lifecycle five times with 20 rounds of four queries per cycle.
It records RSS, its anonymous/file/shared breakdown, swap, virtual size, thread
count, the kernel's resident-memory high-water mark, and a monotonic observed
peak after each phase. The observed peak also includes samples taken while
waiting for replies. Symbol counts and sorted result checksums must remain stable
across all cycles. A successful run also requires a clean LSP shutdown and
process exit. A top-level summary reports the peak and the RSS change between
the first and final closed-document checkpoints. Captured server stderr is also
included so DebugAllocator leak reports and runtime errors are not lost.

The temporary workspace avoids starting the source project's build. Diagnostics
are not advertised and build-on-save is disabled. Imports are not traversed for
workspace symbol indexing. Consequently, this measures document storage, symbol
indexes, position conversion, and query responses; it does not cover semantic
analysis, diagnostics, a full Zig workspace, or build subprocesses. Request
times include protocol transport and Python decoding. Use the position benchmark
for measuring position conversion alone.

`--cycles` and `--rounds` control repetition. Set `--rounds 0` to isolate
document open/close costs without building or querying symbol indexes.
`--max-rss-mib` defaults to 2048;
the script checks ZLS memory while waiting for replies and after each phase and
terminates its child on failure. This is a sampled safeguard, not an OS memory
limit. Each request has a 60-second response deadline. RSS includes allocator
retention and is not a measurement of live allocations or proof of a leak.
Compare phase trends and identical result checksums before interpreting changes.

Compile-time `MaxRSS` from `zig build --summary all` belongs to build steps;
the JSON produced by this script measures only the running ZLS process. Keep
these separate when investigating a large memory peak. LLVM ReleaseFast builds
can consume orders of magnitude more memory than the resulting server process;
use `-j1` to prevent concurrent compile steps from multiplying that peak. Disk
usage under `.zig-cache` is a third, independent measurement.

## Reference run, 2026-09-16

On aarch64 Linux with Zig 0.16.0 and ZLS baseline `90469930`, a cold, single-job
LLVM ReleaseFast build reported approximately 2 GiB `MaxRSS`. The resulting ZLS
process was then exercised with the three Zig files in the example above for 100
open/query/close cycles and 20 rounds of four queries per cycle. It reached a
31,340 KiB observed RSS peak, and its closed-document RSS increased from 7,048
to 21,068 KiB. The UTF-16 long-span candidate reached 32,560 KiB, increasing from
5,448 to 22,880 KiB. Neither process used swap, and result counts and checksums
matched throughout.

The gradual anonymous-RSS growth occurred in both revisions. A 20-cycle Debug
build using DebugAllocator exited without a leak report; its closed-document RSS
increased by only 1,052 KiB. This points to ReleaseFast's `smp_allocator` retaining
freed pages in thread-local caches rather than live document objects leaking. The
small difference between revisions is not treated as a memory optimization or a
regression; the useful conclusion is that the position optimization adds no
allocations and does not materially change resident memory.

An orthogonal run on `5b60bf2f` used 100 cycles with `--rounds 0`. It reached a
20,304 KiB peak and closed-document RSS increased from 3,396 to 10,388 KiB. A
single cycle with 2,000 rounds (8,000 queries) reached only 13,008 KiB and had no
cross-cycle growth. This isolates the gradual RSS retention to repeated document
parse/open/close lifecycles rather than workspace-symbol query arenas.

At 1,000 zero-query cycles, RSS was still increasing: the observed peak was
54,076 KiB and closed-document RSS rose from 5,056 to 39,128 KiB, with no swap.
In contrast, repeating the same test with a 77-byte Zig file changed closed RSS
by only 8 KiB and stabilized in the first 100 cycles. The retention therefore
depends on document parse/storage allocation sizes, not just message count.
