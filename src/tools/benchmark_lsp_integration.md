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

## Generic binding cache refinement

2026-10-11, same machine, Zig version, build options, and integration source.
Baseline `71a00af5` already includes callsite name filtering and the valid-AST
query path. The candidate avoids cloning an overlay when every binding has the
same exact representation as the existing binding, and computes each generated
container cache key's hash once for insertion, recursive result updates, and
hash-map growth. Keys and binding comparisons live in
`src/analyser/specialization_cache.zig`.

Container type equality already compares binding maps independent of insertion
order. Its hash now uses the same order-independent rule. A regression test
requires a cache hit between types built with reversed binding insertion order.
Additional checks require cache separation when parameter values or display
bindings change, and require overlays to preserve changed navigation metadata
even when semantic values compare equal.

Two independent runs reverse startup order and alternate request order, with
five warmups and 24 measured requests per case per process. The table combines
48 samples per binary and reports their median. Builds and tests finished
before the measurements; all 16 response hashes match across binaries and runs.

| Request | Case | Baseline (us) | Candidate (us) | Speedup |
| --- | --- | ---: | ---: | ---: |
| completion | comptime_method | 5306.56 | 4479.94 | 1.18x |
| definition | comptime_method | 5313.83 | 4602.25 | 1.15x |
| completion | generated_binding | 851.23 | 784.73 | 1.08x |
| definition | generated_binding | 871.35 | 750.06 | 1.16x |
| completion | generic_return_method | 4362.48 | 3678.62 | 1.19x |
| definition | generic_return_method | 419.81 | 389.40 | 1.08x |
| completion | generated_capability | 1370.79 | 1330.88 | 1.03x |
| definition | generated_capability | 1409.17 | 1361.56 | 1.03x |
| completion | dynamic_initializer | 6656.08 | 5665.13 | 1.17x |
| definition | dynamic_initializer | 723.94 | 669.69 | 1.08x |
| completion | standard_library | 5884.67 | 5759.88 | 1.02x |
| definition | standard_library | 40.25 | 40.15 | 1.00x |
| completion | reflection_member | 71.04 | 70.85 | 1.00x |
| definition | reflection_member | 61.52 | 60.73 | 1.01x |
| completion | package_import | 265.17 | 251.90 | 1.05x |
| definition | package_import | 26.90 | 27.75 | 0.97x |

The repeated reductions are concentrated in comptime method selection, generic
return method completion, generated binding lookup, and dynamic initialization.
Small differences in the remaining requests do not establish separate gains or
regressions. The geometric mean speedup across all 16 requests is
1.075x. This measures complete-document requests, with
typing-state correctness covered separately by the full edit audit.

The final candidate passed all 1,261 tests, including the two new cache invariant
tests, and all 661 exact navigation destinations / 1,626 edits in integration.
Baseline binary SHA-256: `27086d6ee70cb2a5cc656f3e3ba7e9b04f261d9686c85e1d773c08a60b2f7beb`.
Candidate binary SHA-256: `bcc2f6454599db93c6e3abc0345cdf28703da95b346dd6aa3a7e5a868f3aba01`.
