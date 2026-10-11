# zigraft integration request performance

`benchmark_lsp_integration.py` measures completion and definition requests on the
real `tests/integration.zig`, using zigraft's build-runner package mapping. It
starts two ZLS processes, warms each request, and alternates which process
receives the next request first. Every response must equal the initial response
across both processes and all rounds. Completion also requires the expected
member name; definition requires a destination.

```sh
python3 src/tools/benchmark_lsp_integration.py \
  /path/to/baseline/zls /path/to/candidate/zls /path/to/zigraft \
  --warmup 5 --rounds 24 > /tmp/integration-ab.json
python3 src/tools/benchmark_lsp_integration.py \
  /path/to/candidate/zls /path/to/baseline/zls /path/to/zigraft \
  --warmup 5 --rounds 24 > /tmp/integration-ab-reversed.json
```

`--requests completion` or `--requests definition` restricts the methods. The
JSON output includes binary and source hashes, response hashes, and every timing
sample. Use the same build options and version string for both executables;
completion details include the version in builtin documentation. Finish builds
and tests before collecting measurements.

The exhaustive correctness check is separate:

```sh
python3 src/tools/verify_zigraft_integration.py \
  /path/to/candidate/zls /path/to/zigraft --snippets \
  --output /tmp/integration-audit.json
```

## Recorded comparison

2026-10-11, Apple M1 Pro, macOS, Zig 0.16.0, ReleaseSafe. Baseline `0be0b4f7`.
Both binaries used `-Dversion-string=0.16.0-dev.1216+4aa292db`. Reference source
SHA-256: `0d81088681b49ee95e89bf3d89397159c96732e2849482572e443b8e72375b86`.
Baseline binary SHA-256: `06aac3a05320610c049b540ea0b704466581c1fb81cb7e7da3cb9ff22cc1e857`.
Candidate binary SHA-256: `27086d6ee70cb2a5cc656f3e3ba7e9b04f261d9686c85e1d773c08a60b2f7beb`.

The candidate combines the valid-document AST traversal path with conservative
callsite name filtering. While inferring an `anytype` argument, the previous
callsite search resolved every method call's receiver, including unrelated
generated and standard-library types. Sampling the comptime method request
identified that receiver resolution as the dominant path. The filter collects
the target name and names of syntactic const aliases, traversing alias chains
with a queue. Only possible names reach the existing declaration and receiver
resolution; that resolution still distinguishes unrelated same-name methods
and shadowing.

Two independent runs reverse process startup and request order. Each process
excludes five warmups per request and records 24 measured requests. The table
uses the median of each binary's 48 combined samples. All response hashes match
between binaries and runs.

| Request | Case | Baseline (us) | Candidate (us) | Speedup |
| --- | --- | ---: | ---: | ---: |
| completion | comptime_method | 42604.87 | 5442.02 | 7.83x |
| definition | comptime_method | 42130.37 | 5441.40 | 7.74x |
| completion | generated_binding | 1055.44 | 850.40 | 1.24x |
| definition | generated_binding | 829.85 | 854.73 | 0.97x |
| completion | generic_return_method | 4266.29 | 4459.19 | 0.96x |
| definition | generic_return_method | 469.31 | 461.33 | 1.02x |
| completion | generated_capability | 1469.56 | 1477.17 | 0.99x |
| definition | generated_capability | 1445.10 | 1434.27 | 1.01x |
| completion | dynamic_initializer | 9111.56 | 6651.69 | 1.37x |
| definition | dynamic_initializer | 7849.15 | 863.06 | 9.09x |
| completion | standard_library | 1579857.25 | 5970.98 | 264.59x |
| definition | standard_library | 39.75 | 40.29 | 0.99x |
| completion | reflection_member | 116.79 | 70.21 | 1.66x |
| definition | reflection_member | 122.48 | 76.04 | 1.61x |
| completion | package_import | 299.65 | 289.08 | 1.04x |
| definition | package_import | 29.71 | 29.88 | 0.99x |

The large improvements are in comptime method selection, dynamic initializer
navigation, and completion of the `std.testing` namespace. Small differences
in other requests remain close to process and scheduling variation; they do
not establish a separate performance improvement or regression. These are
complete-document requests; typing states are covered by the exhaustive edit
audit, rather than the timing comparison.

The candidate passed all 1,259 ZLS tests, including callsite inference through
forward-declared alias chains, renamed cross-file aliases, escaped identifiers,
and branching method receivers. The complete integration audit passed 661 exact
definition destinations and 1,626 completion edits across 698 scanned elements.

## AST query microbenchmark

```sh
zig build bench-ast -Doptimize=ReleaseSafe -- \
  /path/to/zigraft/tests/integration.zig /path/to/zigraft/src/impl.zig
```

The executable compares a retained full-scan implementation with traversal of
the enclosing AST branch. It checks identical node sequences at sampled
identifier centers before timing, alternates measurement order, and reports
the median of nine batches after warmup.

| Source | Full scan (ns/query) | Enclosing branch (ns/query) | Speedup |
| --- | ---: | ---: | ---: |
| integration.zig | 34,177 | 3,337 | 10.24x |
| impl.zig | 24,178 | 1,937 | 12.48x |
| dynamic.zig | 37,818 | 2,362 | 16.01x |
| std/meta.zig | 130,002 | 4,764 | 27.28x |

This isolates the AST query cost. Production retains full scanning when parsing
reports errors, because error recovery can detach nodes needed at the cursor.
