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

## Smaller specialization hash tables and reflection reuse

2026-10-11, same machine, Zig version, build options, and source. Baseline
`d82e84e0` includes the previous generic binding refinement. Sampling dynamic
initializer completion identified allocation/free memory fills, especially when
growing the hash table of full specialization keys, as a substantial remaining
cost. The candidate stores pointers in that table and keeps full key snapshots
in stable request-arena storage. Only occupied entries need key storage, while
table growth and release operate on smaller buckets. Lookups still compare the
complete semantic key and its display bindings; a pending null result remains
distinct from a missing entry.

The candidate also reads already bound identifiers directly after lexical
declaration lookup, avoiding another complete environment key. Standard builtin
reflection types are cached within the request and initially resolved outside
the caller's generic and interpreter environment. Earlier isolated measurements
of these two changes showed only small latency changes; the gains below apply
to the combined implementation, with the pointer table providing the larger
observed improvement.

As above, two independent runs reverse process startup order, alternate request
order, exclude five warmups, and combine 48 timing samples per binary per case.
All builds and tests completed first. Every response hash matches between builds
and runs.

| Request | Case | Baseline (us) | Candidate (us) | Speedup |
| --- | --- | ---: | ---: | ---: |
| completion | comptime_method | 4685.42 | 3852.56 | 1.22x |
| definition | comptime_method | 4510.69 | 3687.60 | 1.22x |
| completion | generated_binding | 745.40 | 648.00 | 1.15x |
| definition | generated_binding | 749.02 | 598.21 | 1.25x |
| completion | generic_return_method | 3695.92 | 3135.44 | 1.18x |
| definition | generic_return_method | 393.71 | 357.27 | 1.10x |
| completion | generated_capability | 1352.98 | 1213.52 | 1.11x |
| definition | generated_capability | 1396.31 | 1211.21 | 1.15x |
| completion | dynamic_initializer | 5690.85 | 4351.94 | 1.31x |
| definition | dynamic_initializer | 713.98 | 586.90 | 1.22x |
| completion | standard_library | 5839.10 | 5577.00 | 1.05x |
| definition | standard_library | 42.44 | 40.98 | 1.04x |
| completion | reflection_member | 69.81 | 70.35 | 0.99x |
| definition | reflection_member | 63.15 | 64.06 | 0.99x |
| completion | package_import | 273.42 | 278.40 | 0.98x |
| definition | package_import | 26.67 | 27.38 | 0.97x |

The geometric mean speedup across all 16 requests is 1.116x.
The consistent improvements are in generated/comptime type requests; the small
changes in short import and reflection requests are near scheduling variation.
These results cover complete-document requests, with edit recovery validated
by the exhaustive integration audit.

All 1,264 tests passed. Added checks cover stable binding snapshots, hash-table
growth while a null result is pending, updating/removing those entries, bound
identifier updates and lexical shadowing, escaped identifiers, and restoration
of caller bindings after builtin reflection lookup. The actual LSP integration
audit passed all 661 exact destinations and 1,626 completion edits.
Baseline binary SHA-256: `bcc2f6454599db93c6e3abc0345cdf28703da95b346dd6aa3a7e5a868f3aba01`.
Candidate binary SHA-256: `926896420a6dbc75bca54985f2e4b59af439501de353a7ffa75bef0f92f39ed6`.

## Cached normalized URI hashes

2026-10-11, same machine, Zig version, build options, and source. Baseline
`2a6b6208` includes the smaller specialization tables above. Sampling the full
integration workload still showed repeated Wyhash work in node, token, type,
comptime-value, and specialization keys. All of those keys refer to normalized
URIs, so the candidate computes the URI hash once when the URI is created and
reuses it when composing higher-level hashes. Equality continues to compare the
complete normalized URI, and directly constructed URIs fall back to computing
the same hash on demand.

Two runs reverse process startup and request order. Each process excludes ten
warmups per request and records 100 measured requests; the table reports the
median of each binary's 200 combined samples. All response hashes match between
binaries and runs.

| Request | Case | Baseline (us) | Candidate (us) | Speedup |
| --- | --- | ---: | ---: | ---: |
| completion | comptime_method | 3772.94 | 3522.90 | 1.071x |
| definition | comptime_method | 3746.77 | 3585.33 | 1.045x |
| completion | generated_binding | 620.17 | 599.92 | 1.034x |
| definition | generated_binding | 602.60 | 570.83 | 1.056x |
| completion | generic_return_method | 3074.96 | 2899.98 | 1.060x |
| definition | generic_return_method | 349.19 | 332.46 | 1.050x |
| completion | generated_capability | 1207.83 | 1164.75 | 1.037x |
| definition | generated_capability | 1209.62 | 1171.15 | 1.033x |
| completion | dynamic_initializer | 4312.31 | 4158.50 | 1.037x |
| definition | dynamic_initializer | 564.92 | 544.00 | 1.038x |
| completion | standard_library | 5552.42 | 5551.35 | 1.000x |
| definition | standard_library | 39.69 | 37.98 | 1.045x |
| completion | reflection_member | 63.56 | 63.38 | 1.003x |
| definition | reflection_member | 61.23 | 60.81 | 1.007x |
| completion | package_import | 230.08 | 237.92 | 0.967x |
| definition | package_import | 27.46 | 27.81 | 0.987x |

The geometric mean speedup across all 16 requests is `1.029x`. The comptime
method and generic-return paths improve by 4.5-7.1%; the two sub-250 us package
import requests remain small and noisy, with the completion median 3.3% slower.

All 1,265 ZLS tests and all 17 zigraft tests passed. The complete integration
audit passed all 661 exact definition destinations and 1,626 completion edits.
Baseline binary SHA-256: `a3b47a2fb42a9b5f200ce030f10889fb0d87c8fdd14e0ebf351bfcbebafc2d1a`.
Candidate binary SHA-256: `569b538860d7400ee00db844de28141208dbd532fe5828fde4f78cc75e479c03`.

## Single-probe specialization cache insertion

2026-10-11, same machine, Zig version, build options, and source. Baseline
`439640e9` includes cached normalized URI hashes. On a specialization-cache
miss, the baseline first probed with the temporary full key, allocated its
stable snapshot, and then performed a second hash-table lookup to insert it.
The candidate uses one adapted get-or-put operation and fills the pointer key
only on a miss. If snapshot allocation fails after reserving the slot, the slot
is removed by pointer before returning the error.

Two runs reverse process startup and request order. Each process excludes ten
warmups per request and records 100 measured requests; the table reports the
median of each binary's 200 combined samples. All response hashes match between
binaries and runs.

| Request | Case | Baseline (us) | Candidate (us) | Speedup |
| --- | --- | ---: | ---: | ---: |
| completion | comptime_method | 3533.06 | 3492.50 | 1.012x |
| definition | comptime_method | 3642.77 | 3593.73 | 1.014x |
| completion | generated_binding | 606.79 | 598.21 | 1.014x |
| definition | generated_binding | 576.44 | 574.35 | 1.004x |
| completion | generic_return_method | 2929.69 | 2896.29 | 1.012x |
| definition | generic_return_method | 341.56 | 341.56 | 1.000x |
| completion | generated_capability | 1209.29 | 1198.10 | 1.009x |
| definition | generated_capability | 1182.88 | 1181.46 | 1.001x |
| completion | dynamic_initializer | 4240.25 | 4219.90 | 1.005x |
| definition | dynamic_initializer | 553.69 | 551.79 | 1.003x |
| completion | standard_library | 5579.96 | 5566.77 | 1.002x |
| definition | standard_library | 40.50 | 40.31 | 1.005x |
| completion | reflection_member | 67.83 | 68.52 | 0.990x |
| definition | reflection_member | 62.48 | 63.23 | 0.988x |
| completion | package_import | 197.98 | 201.46 | 0.983x |
| definition | package_import | 28.17 | 27.92 | 1.009x |

The geometric mean speedup across all 16 requests is `1.003x`. The three
multi-millisecond comptime-heavy completions improve by 0.5-1.2%, while the
sub-250 us reflection/import variations remain within a few microseconds.

All 1,266 ZLS tests passed, including a new failure-path check that verifies an
uninitialized entry is removed when the stable-key snapshot cannot be allocated.
The complete integration audit passed all 661 exact definition destinations and
1,626 completion edits.
Baseline binary SHA-256: `569b538860d7400ee00db844de28141208dbd532fe5828fde4f78cc75e479c03`.
Candidate binary SHA-256: `60d34f6f09cf7fab09ba6c077e136dff580ade9530050392cf5aeb176fbb5f88`.

## Active binding digest reuse

2026-10-11, same machine, Zig version, build options, and source. Baseline
`7d21af97` includes single-probe specialization insertion. A specialization key
uses order-independent digests of its active generic and display bindings. The
candidate caches those digests while the same immutable map storage remains
active, instead of recursively hashing every bound type for each resolved AST
node. Interpreter-owned mutable maps deliberately bypass this cache, and the
one ordinary path that overwrites an active map explicitly invalidates it.

Two runs reverse process startup and request order. Each process excludes 20
warmups per request and records 500 measured requests; the table reports the
median of each binary's 1,000 combined samples. All response hashes match
between binaries and runs.

| Request | Case | Baseline (us) | Candidate (us) | Speedup |
| --- | --- | ---: | ---: | ---: |
| completion | comptime_method | 3525.08 | 3279.58 | 1.075x |
| definition | comptime_method | 3568.65 | 3327.48 | 1.072x |
| completion | generated_binding | 612.98 | 591.79 | 1.036x |
| definition | generated_binding | 565.73 | 547.79 | 1.033x |
| completion | generic_return_method | 2846.44 | 2690.42 | 1.058x |
| definition | generic_return_method | 338.73 | 330.71 | 1.024x |
| completion | generated_capability | 1178.06 | 1171.23 | 1.006x |
| definition | generated_capability | 1181.40 | 1172.25 | 1.008x |
| completion | dynamic_initializer | 4221.60 | 4024.19 | 1.049x |
| definition | dynamic_initializer | 552.19 | 544.40 | 1.014x |
| completion | standard_library | 5564.48 | 5542.50 | 1.004x |
| definition | standard_library | 37.75 | 37.92 | 0.996x |
| completion | reflection_member | 64.92 | 65.35 | 0.993x |
| definition | reflection_member | 59.54 | 59.62 | 0.999x |
| completion | package_import | 168.65 | 180.29 | 0.935x |
| definition | package_import | 27.88 | 27.56 | 1.011x |

The geometric mean speedup across all 16 requests is `1.019x`. The expensive
comptime method and generic-return paths improve by 5.8-7.5%, and dynamic
initializer completion improves by 4.9%. The package-import completion change
is twelve microseconds on a sub-200 us request.

All 1,267 ZLS tests and all 17 zigraft tests passed. The complete integration
audit passed all 661 exact definition destinations and 1,626 completion edits.
A separate 1,000-sample experiment that only bypassed equality work for maps
sharing storage measured a `1.000x` overall geometric mean and was not retained.
Baseline binary SHA-256: `00c6460fe4da9e8bc6d6065b2e3fd9bea81b586e65fa0f8c12c07a9dced34b0f`.
Candidate binary SHA-256: `ef2310b5550d7b0303a9d90a84ce2a16b219473be60bfe4119933408123e3526`.

## Stack-based specialization recursion guard

2026-10-11, same machine, Zig version, build options, and source. Baseline
`c317d08d` includes active binding digest reuse. Specialized resolutions are
synchronous and strictly nested, but the baseline tracked their active source
nodes in a hash set. The candidate uses a short LIFO stack: it scans only the
currently active recursion depth, appends before uncached resolution, and
asserts that the same node is popped on every exit path. This removes hash-table
allocation, growth, and URI hashing from the recursion guard.

Two runs reverse process startup and request order. Each process excludes 20
warmups per request and records 500 measured requests; the table reports the
median of each binary's 1,000 combined samples. All response hashes match
between binaries and runs.

| Request | Case | Baseline (us) | Candidate (us) | Speedup |
| --- | --- | ---: | ---: | ---: |
| completion | comptime_method | 3271.85 | 3168.71 | 1.033x |
| definition | comptime_method | 3374.73 | 3268.35 | 1.033x |
| completion | generated_binding | 582.44 | 574.15 | 1.014x |
| definition | generated_binding | 542.42 | 540.04 | 1.004x |
| completion | generic_return_method | 2709.04 | 2619.15 | 1.034x |
| definition | generic_return_method | 327.46 | 324.38 | 1.010x |
| completion | generated_capability | 1156.19 | 1150.19 | 1.005x |
| definition | generated_capability | 1159.02 | 1156.98 | 1.002x |
| completion | dynamic_initializer | 3931.08 | 3782.71 | 1.039x |
| definition | dynamic_initializer | 519.90 | 518.94 | 1.002x |
| completion | standard_library | 5550.29 | 5542.44 | 1.001x |
| definition | standard_library | 38.46 | 38.19 | 1.007x |
| completion | reflection_member | 65.06 | 65.25 | 0.997x |
| definition | reflection_member | 60.21 | 60.17 | 1.001x |
| completion | package_import | 168.10 | 177.94 | 0.945x |
| definition | package_import | 27.81 | 28.08 | 0.990x |

The geometric mean speedup across all 16 requests is `1.007x`. The expensive
comptime/generic completions improve by 3.3-3.9%. The package-import completion
change is ten microseconds on a sub-180 us request.

All 1,267 ZLS tests and all 17 zigraft tests passed. Recursive generic tests
exercise the guard directly, and the complete integration audit passed all 661
exact definition destinations and 1,626 completion edits.
Baseline binary SHA-256: `ef2310b5550d7b0303a9d90a84ce2a16b219473be60bfe4119933408123e3526`.
Candidate binary SHA-256: `69970cab0a051709f24239b0ac2269a4f0acec39730e7d3b6cf8f0fffa24b7dc`.

## Skip impossible lexical field lookups

2026-10-11, same machine, Zig version, build options, and source. Baseline
`26b7bda4` includes the stack-based specialization recursion guard. Global
symbol lookup used to query both field and ordinary declaration indexes at
every enclosing scope. `DocumentScope` only registers fields in container
scopes, so the candidate skips the field-index lookup for function, block, and
other scopes while preserving field-definition lookup inside containers.

Two runs reverse process startup and request order. Each process excludes 20
warmups per request and records 500 measured requests; the table reports the
median of each binary's 1,000 combined samples. All response hashes match
between binaries and runs.

| Request | Case | Baseline (us) | Candidate (us) | Speedup |
| --- | --- | ---: | ---: | ---: |
| completion | comptime_method | 3184.48 | 3151.23 | 1.011x |
| definition | comptime_method | 3256.35 | 3201.92 | 1.017x |
| completion | generated_binding | 561.40 | 553.73 | 1.014x |
| definition | generated_binding | 556.10 | 547.96 | 1.015x |
| completion | generic_return_method | 2614.48 | 2581.10 | 1.013x |
| definition | generic_return_method | 330.25 | 325.90 | 1.013x |
| completion | generated_capability | 1169.19 | 1133.52 | 1.031x |
| definition | generated_capability | 1155.62 | 1124.71 | 1.027x |
| completion | dynamic_initializer | 3828.35 | 3763.04 | 1.017x |
| definition | dynamic_initializer | 525.96 | 519.96 | 1.012x |
| completion | standard_library | 5559.98 | 5537.25 | 1.004x |
| definition | standard_library | 37.21 | 36.90 | 1.008x |
| completion | reflection_member | 66.52 | 67.00 | 0.993x |
| definition | reflection_member | 60.54 | 60.48 | 1.001x |
| completion | package_import | 178.58 | 188.56 | 0.947x |
| definition | package_import | 28.46 | 28.71 | 0.991x |

The geometric mean speedup across all 16 requests is `1.007x`. The comptime,
generic-return, generated-binding, generated-capability, and dynamic-initializer
paths all improve; the largest gains are 3.1% for generated-capability
completion and 2.7% for its definition.

All 1,267 ZLS tests and all 17 zigraft tests passed. The complete integration
audit passed all 661 exact definition destinations and 1,626 completion edits.
Baseline binary SHA-256: `69970cab0a051709f24239b0ac2269a4f0acec39730e7d3b6cf8f0fffa24b7dc`.
Candidate binary SHA-256: `7a35be9be02f578fdb0805de21c9e0bb7d7db0f4f05c9cbae0fcf0bd33213c7c`.

Several adjacent ideas were rejected after bidirectional measurements: caching
container-type hashes (`0.9955x` overall), adding an inline buffer in front of
the recursion stack (`0.9956x`), using linear search for small child-scope lists
(`0.9902x`), and a direct-mapped innermost-scope cache (`0.9966x`). None of
these changes are present in the final candidate.

## Borrow stable specialization bindings

2026-10-11, same machine, Zig version, build options, and source. Baseline
`49efa126` includes the lexical field-lookup pruning above. Specialization keys
must remain valid for the request lifetime. The baseline therefore cloned both
binding maps for every new node key, even when the maps already lived for the
request or document lifetime and were immutable. The candidate marks keys created from the
ordinary cached-analysis path as stable and borrows those maps. Interpreter
bindings and the display-materialization path remain explicitly mutable and
continue to receive independent snapshots. Same-storage equality then avoids
deep comparison on cache hits without weakening collision checks.

Two runs reverse process startup and request order. Each process excludes 20
warmups per request and records 500 measured requests; the table reports the
median of each binary's 1,000 combined samples. All response hashes match
between binaries and runs.

| Request | Case | Baseline (us) | Candidate (us) | Speedup |
| --- | --- | ---: | ---: | ---: |
| completion | comptime_method | 3106.50 | 2520.88 | 1.232x |
| definition | comptime_method | 3094.50 | 2536.35 | 1.220x |
| completion | generated_binding | 553.98 | 515.56 | 1.075x |
| definition | generated_binding | 542.23 | 498.77 | 1.087x |
| completion | generic_return_method | 2591.88 | 2177.65 | 1.190x |
| definition | generic_return_method | 325.58 | 302.56 | 1.076x |
| completion | generated_capability | 1143.33 | 1106.92 | 1.033x |
| definition | generated_capability | 1112.54 | 1080.42 | 1.030x |
| completion | dynamic_initializer | 3727.69 | 3093.12 | 1.205x |
| definition | dynamic_initializer | 509.54 | 471.23 | 1.081x |
| completion | standard_library | 5502.17 | 5440.37 | 1.011x |
| definition | standard_library | 37.94 | 38.08 | 0.996x |
| completion | reflection_member | 64.56 | 64.90 | 0.995x |
| definition | reflection_member | 61.94 | 61.88 | 1.001x |
| completion | package_import | 172.46 | 185.56 | 0.929x |
| definition | package_import | 27.81 | 27.71 | 1.004x |

The geometric mean speedup across all 16 requests is `1.069x`. The expensive
comptime method, generic-return, and dynamic-initializer completions improve by
19.0-23.2%; their definition requests improve by 7.6-22.0%.

All 1,268 ZLS tests and all 17 zigraft tests passed. New tests prove that stable
keys borrow their backing maps while ordinary keys still snapshot mutable maps.
The complete integration audit passed all 661 exact definition destinations and
1,626 completion edits. Prehashing declaration names (`0.9926x` overall) and
caching complete global-symbol lookups (`0.9892x`) were separately measured and
rejected.
Baseline binary SHA-256: `7a35be9be02f578fdb0805de21c9e0bb7d7db0f4f05c9cbae0fcf0bd33213c7c`.
Candidate binary SHA-256: `75f9abaa2728cc2c9a6e764aa0fec41611191c8e42fc33ea11b322f4895e0c50`.

## Rejected post-borrow micro-optimizations

After stable specialization bindings removed the dominant clone cost, several
smaller caches and allocation strategies were tested bidirectionally against
`fa347359`. Each result below combines 200 measured samples per request. None
was retained:

| Experiment | Geomean | Reason rejected |
| --- | ---: | --- |
| Hash-map cache for bound-identifier declarations | 0.9997x | Lookup/allocation cost offset the repeated lexical lookup wins. |
| Four-slot direct cache for bound-identifier declarations | 0.9970x | Avoided allocation but did not have enough locality. |
| Last-handle `DocumentScope` cache | 0.9978x | The existing lazy lock path was cheaper than extra analyser state. |
| Reserve 64 specialization entries on first use | 0.9997x | Avoided growth but over-allocated for smaller requests. |
| Reserve 16 specialization entries on first use | 0.9966x | Smaller reservation still lost to demand-driven growth. |
| Pre-scan for unresolved parameters before `fullFnProto` | 0.9951x | The extra type scan cost more than the avoided parsing. |
| Persist parameter `type_expr` nodes in function types | 0.9984x | Larger parameter metadata offset removal of the AST iterator. |
| Reuse the caller's parsed `FnProto` for initial return resolution | 0.9918x | Reduced parsing but worsened code layout and hot completion paths. |
| Cache stable `FnProto` values and parameter slices per request | 0.9950x | Hash-map and slice-copy costs exceeded reuse across specializations. |
| Defer `value_params` construction through a difference overlay | 0.9952x | Final cloning plus overlay replay cost more than paired small-map writes. |
| Skip the first field-enum method selection before restoring a concrete container | 0.9936x | The supposedly duplicate selection affected later specialization locality. |
| Short-circuit stable container equality by storage identity | 0.9984x | Existing shared-binding checks had already removed most deep-comparison cost. |

The experiments also confirmed that their response hashes matched the baseline,
so the rejection is performance-based rather than caused by semantic drift.

## Comptime address-space cast values

2026-10-11, same machine, Zig version, build options, and source. Baseline
`fa347359`. The candidate preserves reference, sequence, optional, and numeric
pointer identity through Zig 0.16 `@addrSpaceCast` when the destination type is
supplied by the result location. Pointer compatibility still checks size,
element type, qualifiers, alignment, packed offsets, and requires the address
space to change. Calls without a result type continue through ordinary type
analysis because Zig cannot infer their destination address space.

Two runs reverse process startup and request order. Each process excludes 20
warmups and records 500 requests per case, for 1,000 combined samples. All
response hashes match. The geometric mean across the 16 existing integration
requests is `0.9956x`; multi-millisecond requests remain within 0.4%, while the
largest absolute change is 7.5 us on package-import completion. This small code
layout cost is accepted for the newly supported comptime value semantics.

All 1,269 ZLS tests and all 17 zigraft tests passed. The new regression covers
numeric pointers, optional pointer payloads, null preservation, round trips,
and `@intFromPtr` after an address-space change. The complete integration audit
passed all 661 exact definition destinations and 1,626 completion edits.
Baseline binary SHA-256: `75f9abaa2728cc2c9a6e764aa0fec41611191c8e42fc33ea11b322f4895e0c50`.
Candidate binary SHA-256: `dec5e68bbb3c681752b3fa3795fbbb3416f3652ef4fa09ada08fee77ee107edd`.
