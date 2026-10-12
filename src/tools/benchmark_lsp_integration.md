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

## Comptime error-integer round trips

2026-10-11, Zig 0.16.0. The comptime interpreter now represents
`@intFromError` results symbolically instead of guessing Zig's compilation-global
error number assignment. This permits same/different error-code comparisons and
lossless `@errorFromInt(@intFromError(error.Name))` round trips while keeping a
bare integer passed to `@errorFromInt` unknown.

All 1,271 ZLS tests and all 17 zigraft tests passed. The new LSP regressions
cover generated-type completion, exact definition selection, symbolic equality,
symbolic inequality, and the unknown bare-integer boundary. The complete
integration audit passed all 661 exact definition destinations and 1,626
completion edits across 698 scanned elements.

The follow-up shares the conversion helpers with ordinary comptime resolution,
so symbolic codes also survive top-level `const` aliases used by array lengths
and other value-required contexts. It intentionally does not force direct
conditional type declarations to one branch: the existing editor behavior of
retaining all branch candidates remains unchanged.

The follow-up used the previous commit as its baseline. Two runs reversed the
process and request order, with 5 warmups and 24 measured rounds per run. Across
the 16 existing request cases, the combined 48-sample medians had a geometric
mean speedup of `1.0049x`; the per-case differences were small and mixed, so
this is treated as no material performance change. All response hashes matched.
Baseline binary SHA-256: `2a2161e3083e63b8557a9e9428bad2bc0eda9bac14017f26539a39e868ebcbff`.
Candidate binary SHA-256: `de051c679b436bf58ae95a0920977058270137bbef4526f43a5cbda01eefc2b6`.

## Read-only pointer reinterpretation

2026-10-11, same machine, Zig version, and build options. A `@ptrCast` between
read-only sequence pointers now keeps elements readable when every element can
be bit-cast to the destination element type. This covers equal-width integer
reinterpretation, including signed values and a cast back to the original type.
Size-changing casts and mutable reinterpreted views remain unknown because they
require byte-level addressing or write-through alias semantics.

All 1,272 ZLS tests and all 17 zigraft tests passed. The complete integration
audit passed all 661 exact definition destinations and 1,626 completion edits
across 698 scanned elements. Two runs reversed process and request order, with
20 warmups and 500 measured rounds per run. The combined 1,000-sample medians
across the 16 existing cases had a geometric mean speedup of `0.9951x`; the
multi-millisecond requests remained within 1.1%, while the largest relative
change was 14.6 us on package-import completion. This is treated as no material
performance change. All response hashes matched. Baseline binary SHA-256:
`de051c679b436bf58ae95a0920977058270137bbef4526f43a5cbda01eefc2b6`.
Candidate binary SHA-256: `429924a9e118b5e5ed24d193faf619d126315f19534a1c727ee7a63de7b96915`.

## Scalar floating-point bit casts

2026-10-11, same machine, Zig version, and build options. Comptime `@bitCast`
now preserves raw bit patterns between integers and `f16`, `f32`, `f64`, `f80`,
or `f128`, and same-shaped vector casts reuse that scalar path. The conversion
does not pass through `f128`, so NaN payloads and negative zero survive an
integer-to-float-to-integer round trip. Runtime-unknown operands remain unknown.

All 1,274 ZLS tests and all 17 zigraft tests passed. The complete integration
audit passed all 661 exact definition destinations and 1,626 completion edits
across 698 scanned elements. Two runs reversed process and request order, with
20 warmups and 500 measured rounds per run. The combined 1,000-sample medians
across the 16 existing cases had a geometric mean speedup of `0.9973x`; the
multi-millisecond requests remained within 0.6%, and the larger relative change
was 10.8 us on package-import completion. This is treated as no material
performance change. All response hashes matched. Baseline binary SHA-256:
`429924a9e118b5e5ed24d193faf619d126315f19534a1c727ee7a63de7b96915`.
Candidate binary SHA-256: `45d381f4d483269013eed70ff4b160a6f0a32514bb1602cb2d712f4232cfb6fb`.

## Boolean bit casts

2026-10-11, same machine, Zig version, and build options. The scalar bit-cast
path now preserves exact values between `bool` and one-bit signed or unsigned
integers. Same-shaped vectors inherit the scalar conversion, including the
`i1(-1)` representation of `true`. Runtime-unknown operands remain unknown.

All 1,276 ZLS tests and all 17 zigraft tests passed. The complete integration
audit passed all 661 exact definition destinations and 1,626 completion edits
across 698 scanned elements. Two runs reversed process and request order, with
20 warmups and 500 measured rounds per run. The combined 1,000-sample medians
across the 16 existing cases had a geometric mean speedup of `1.0003x`, with no
material performance change. All response hashes matched. Baseline binary
SHA-256: `45d381f4d483269013eed70ff4b160a6f0a32514bb1602cb2d712f4232cfb6fb`.
Candidate binary SHA-256: `1f511de7f62d5a122b658b237db054232b82fe4f9dc91bdf1b3047704c512f35`.

## Array-vector bit casts

2026-10-11, same machine, Zig version, and build options. Comptime `@bitCast`
now preserves aggregate values between arrays and vectors when their runtime
lane count and element type match. A known array sentinel is materialized as the
final vector lane. Shape changes, destination sentinel constraints, element
reinterpretation, and runtime-unknown elements remain conservative.

All 1,278 ZLS tests and all 17 zigraft tests passed. The complete integration
audit passed all 661 exact definition destinations and 1,626 completion edits
across 698 scanned elements. Two runs reversed process and request order, with
20 warmups and 500 measured rounds per run. The combined 1,000-sample medians
across the 16 existing cases had a geometric mean speedup of `0.9968x`; the
multi-millisecond requests remained within 0.8%, and the larger relative change
was 8.9 us on package-import completion. This is treated as no material
performance change. All response hashes matched. Baseline binary SHA-256:
`1f511de7f62d5a122b658b237db054232b82fe4f9dc91bdf1b3047704c512f35`.
Candidate binary SHA-256: `e431d94625a19345e0e97b4e6bea39b301c93479d7ab9d05ae4d1af33bd08146`.

The follow-up handles both remaining lane-preserving directions. Compatible
scalar element types are converted lane by lane, so `[3]u8` and
`@Vector(3, i8)` retain exact values in either direction. A vector converted to
a sentinel array keeps only the explicit array elements; indexing the boundary
continues to use the destination type's declared sentinel, matching Zig 0.16.
Cross-lane conversions that require target-endian byte redistribution remain
unknown.

All 1,278 ZLS tests and all 17 zigraft tests passed. The complete integration
audit passed all 661 exact definition destinations and 1,626 completion edits
across 698 scanned elements. Two reversed runs with 20 warmups and 500 measured
rounds per order produced a `0.9978x` geometric mean across the 16 existing
request cases; multi-millisecond requests remained within 0.9%. The largest
relative difference was 7.6 us on package-import completion, so this is treated
as no material performance change. All response hashes matched. Baseline binary
SHA-256: `e431d94625a19345e0e97b4e6bea39b301c93479d7ab9d05ae4d1af33bd08146`.
Candidate binary SHA-256: `68cd54a6709de0fe4b4c044cc63b5c47ab127a2ad04922f5cfe7db0eecd7b50c`.

The follow-up applies the scalar bit-cast rules independently to each lane, so
equal-lane array/vector conversions may also change between compatible scalar
element types, such as `[3]u8` and `@Vector(3, i8)`. Conversions that change the
lane count and therefore require target-endian byte redistribution remain
unknown.

The lane-preserving path now also applies each existing scalar bit-cast rule to
the corresponding destination lane. This preserves values for conversions such
as `[3]u8` to `@Vector(3, i8)` and back, including signed bit patterns and known
sentinels, without enabling target-endian scalar-to-multiple-lane casts.

All 1,278 ZLS tests and all 17 zigraft tests passed. The complete integration
audit passed all 661 exact definition destinations and 1,626 completion edits
across 698 scanned elements. Two reversed runs with 20 warmups and 500 measured
rounds per order produced a `0.9978x` geometric mean across the 16 existing
request cases; multi-millisecond requests remained within 0.9%. The largest
relative difference was 7.6 us on package-import completion, so this is treated
as no material performance change. All response hashes matched. Baseline binary
SHA-256: `e431d94625a19345e0e97b4e6bea39b301c93479d7ab9d05ae4d1af33bd08146`.
Candidate binary SHA-256: `68cd54a6709de0fe4b4c044cc63b5c47ab127a2ad04922f5cfe7db0eecd7b50c`.

## Runtime struct layouts for size builtins

2026-10-11, same machine, Zig version, and build options. Comptime `@sizeOf`,
`@bitSizeOf`, and `@alignOf` now resolve runtime layouts for AST and generated
struct types. Extern structs use declaration-order padding and tail alignment.
Auto-layout structs are intentionally limited to runtime fields with identical
size and alignment, which is order-independent and covers zigraft's two-pointer
`DynRef` and `DynMut` wrappers without guessing Zig's backend-dependent field
reordering. Comptime fields are excluded, and heterogeneous auto structs remain
unknown. A bounded recursion guard keeps invalid by-value recursive structs from
overflowing the analysis stack while the user is still editing them.

All 1,280 ZLS tests and all 17 zigraft tests passed. The complete integration
audit passed all 661 exact definition destinations and 1,626 completion edits
across 698 scanned elements. A real-document overlay on `tests/integration.zig`
also selected only the `DynMut` two-pointer success branch for completion and
resolved its field definition to the exact declaration.

Two reversed runs with 20 warmups and 500 measured rounds per order produced a
`0.9990x` geometric mean across the 16 existing request cases. The
multi-millisecond requests remained within 0.9%, so this is treated as no
material performance change. All response hashes matched. Baseline binary
SHA-256: `c94555a7028847adc4ca7738c74e5371ad72451de17fceae0db2ffa0f5d0853b`.
Candidate binary SHA-256:
`1ad502d9f7edaf416ef6fb4fa27d4730a1323458f964cd6c0386034a6a2e7dc4`.

## Comptime instance method evaluation

2026-10-11, same machine, Zig version, and build options. The comptime
interpreter now recognizes Zig method-call syntax, captures the evaluated base
once, and supplies it as the implicit first argument. This preserves side
effects for temporary receivers and supports value and comptime receivers with
explicit literal or comptime arguments. Void-returning validation methods and
calls with ordinary runtime arguments remain on the normal type-inference path,
which avoids disturbing incomplete calls while they are being edited.

All 1,284 ZLS tests and all 17 zigraft tests passed. The complete integration
audit passed all 661 exact definition destinations and 1,626 completion edits
across 698 scanned elements. A real-document overlay on `tests/integration.zig`
also used the actual imported `zigraft.Check.isOk` method to select one
completion branch and resolved its definition exactly to `src/contract.zig`.

Two reversed runs with 20 warmups and 500 measured rounds per order produced a
`0.9972x` geometric mean across the 16 existing request cases. The
multi-millisecond requests remained within 1.1%, so this is treated as no
material performance change. All response hashes matched. Baseline binary
SHA-256: `bdffab11ab6c4bb1564a6818b430f203384d702cda4c60be97f9266c44f77c2a`.
Candidate binary SHA-256:
`b39e4ee68d1e21fc8a59e3caa4211d8722a45f8f0ad7506e065c4cef384a5269`.

## Nested aggregate comptime values through type calls

2026-10-12, same machine, Zig version, and build options. Later comptime
parameter types are now resolved in argument order when an aggregate-producing
call is evaluated by the comptime interpreter. Struct and union results keep
their field values through nested type-function return calls, and instance
methods use the concrete receiver specialization. This lets the real
`zigraft.auto(Reader, *Buffer)` value preserve the `ReaderError` selected by
`associatedFor`, so `BufferReader.associated().Error` resolves without also
retaining the `anyerror` fallback. The incremental binding map is treated as
mutable while resolving dependent parameter types so specialization cache keys
own stable snapshots.

All 1,286 ZLS tests and all 17 zigraft tests passed. The complete integration
audit passed all 661 exact definition destinations and 1,626 completion edits
across 698 scanned elements. A real-document overlay also selected only the
concrete associated-error branch and resolved `associated` exactly to
`src/impl.zig`.

Two reversed runs with 20 warmups and 500 measured rounds per order produced a
`1.0031x` geometric mean across the 16 existing integration request cases. The
multi-millisecond requests remained within 2.7%; their largest absolute
difference was 29.2 us, so this is treated as no material performance change.
All response hashes matched. Baseline binary
SHA-256: `956c7a4f66a7559ffc32eb1d78836df300d5204d38b648c4d1338daa7baad2b3`.
Candidate binary SHA-256:
`901593dd6eba5b9a0d453b6caa20f56a2f4b70896804641e078f7093e86dc05f`.

## Generated defaults and structured comptime checks

2026-10-12, same machine, Zig version, and build options. Generated `@Struct`
field metadata now retains `default_value_ptr` values in the analysis fallback,
including `null` coerced to non-interned optional function types. Nested dynamic
`@field` reads use the pointee's already-selected value instead of applying its
path twice. Interpreter calls also resolve parameter types in declaration order,
so later parameters such as `b: @TypeOf(a)` see the earlier argument value.
`@inComptime`, common `std.mem.eql` string calls, and payloadless tagged-union
comparison through `std.meta.eql` remain concrete during these checks.

All 1,288 ZLS tests and all 17 zigraft tests passed. The complete integration
audit passed all 661 exact definition destinations and 1,626 completion edits
across 698 scanned elements. A real-document overlay selected only the expected
branches for `zigraft.auto(Reader, *struct {}).check().kind`,
`BufferReader.satisfies()`, mutable `isObjectSafe`, and the rejected read-only
case; the independent narrowing rejection remains a later comptime target.

Two reversed runs with 20 warmups and 500 measured rounds per order produced a
`0.9996x` geometric mean across the 16 existing integration request cases. The
multi-millisecond requests remained within 0.9%; the largest relative change
was 6.6 us on package-import completion, so this is treated as no material
performance change. All response hashes matched. Baseline binary SHA-256:
`844f8ea631ea0d787d414b5fd93e97ec0104b38fcdd7ab99df058fb9bae06d4d`.
Candidate binary SHA-256:
`45c78103451b5d3e8aaefc247fc9de6fcef6f13a315a692fa7639599997a115b`.

## Generated adapter binding propagation

2026-10-12, same machine, Zig version, and build options. `@typeInfo` field
descriptors for generated structs now prefer the full type stored in
`generated_struct_fields` when the InternPool entry cannot represent it. This
preserves optional function types used by zigraft's generated binding table.
Comptime void instance methods are executed only for known local comptime
receivers in non-type functions, allowing `adaptWith` validation to gate its
binding assignments without evaluating validation calls inside type
construction or broad receiver expressions.

All 1,290 ZLS tests and all 17 zigraft tests passed. The complete integration
audit passed all 661 exact definition destinations and 1,626 completion edits
across 698 scanned elements. A real-document overlay selected only the expected
branches for associated errors, missing methods, satisfaction, mutable and
read-only object safety, and rejection of an invalid associated-parameter
narrowing through `ForeignReader`.

Two reversed runs with 20 warmups and 500 measured rounds per order produced a
`0.9988x` geometric mean across the 16 existing integration request cases. The
multi-millisecond requests remained within 0.5%; the largest relative change
was 2.9 us on package-import completion, so this is treated as no material
performance change. All response hashes matched. Baseline binary SHA-256:
`6446a81fe63b0fadf61aec8938900efd76ed38beb133cb7feda08460b7654e13`.
Candidate binary SHA-256:
`a8a0a847102e49f773d13f4737f9575bef872f9bc2ace1fde5719abb69fc37db`.

## Exact declared types from comptime call chains

2026-10-12, same machine, Zig version, and build options. Struct field type
expressions now fall back to comptime interpretation when ordinary resolution
remains unknown and the field-access chain contains a call. Explicit variable
types use the same resolver, but only when the direct result is unknown, the
expression ends in field access, and no generic binding or interpreter context
is active. This avoids re-evaluating direct type functions or generated types
that only contain nested unknown fields. Known types retain the existing fast
path. Declarations such as `value: BufferReader.associated().Error` and
`const value: BufferReader.associated().Error = error.OutOfBounds` therefore
keep the concrete associated error set instead of displaying `(unknown type)`.

All 1,292 ZLS tests and all 17 zigraft tests passed. The complete integration
audit passed all 661 exact definition destinations and 1,626 completion edits
across 698 scanned elements. A real-document overlay reports
`error{OutOfBounds}` for both field completion and explicit-variable hover,
and resolves `associated` exactly to `src/impl.zig`.

Two reversed runs with 20 warmups and 500 measured rounds per order produced a
`1.0007x` geometric mean across the 16 existing integration request cases. The
multi-millisecond requests remained within 0.2%, so this is treated as no
material performance change. All response hashes matched. Baseline binary
SHA-256: `4264f61863233ace5e4f01131333a622d608df3b6789179618e3963cccf0228c`.
Candidate binary SHA-256:
`d1f0457e30f8e94203aa0ea6e6ba0045a4f9c806ce3984c3d18271fc86ce67ec`.

## Dependent comptime parameter return types

2026-10-12, same machine, Zig version, and build options. Function-call
specialization now re-resolves a later comptime parameter when its source type
expression references an earlier parameter but the cached prototype appears
fully resolved. The concrete argument's generated-container type supplies that
refinement without re-evaluating the aggregate, and the refined type is retained
in the displayed signature. A single-expression method that returns a captured
comptime parameter reads the value directly from its container bindings, so
ordinary field access can resolve the dependent error-union return type.

This covers functions such as `Reader.readAll`, where binding `reader` changes
`Impl(@TypeOf(reader))`, whose associated value in turn determines
`impl.associated().Error!usize`. The real call hover at `integration.zig:100`
changed from `ImplWith(Reader,*Buffer,.{})` and `(unknown type)!usize` to
`ImplWith(Reader,*Buffer,.{ .Error = error{OutOfBounds} })` and
`error{OutOfBounds}!usize`.

The dependency check scans only the later parameter's type expression and
requires a reference to an earlier parameter. It also skips types that are
already unresolved, because the existing final specialization pass handles
those. This removed an initial 4-8% regression on comptime method, generic
return, and dynamic initializer requests.

All 1,293 ZLS tests and all 17 zigraft tests passed. The complete integration
audit passed all 661 exact definition destinations and 1,626 completion edits
across 698 scanned elements. Two reversed runs with 20 warmups and 500 measured
rounds per order produced a `0.9991x` geometric mean across the 16 integration
request cases. Multi-millisecond requests remained within 0.9%; the largest
absolute difference was 25.4 us, so this is treated as no material performance
change. All response hashes matched. A separate reversed measurement of the
changed `readAll` hover combined 1,000 samples per binary: the baseline response
remained stable at 641.65 us, while the more precise candidate response remained
stable at 608.58 us (`1.054x`). Baseline binary SHA-256:
`072a5b303596275a5adb47f20bfb34c03f757b5d42a05960b40092f071233ad9`.
Candidate binary SHA-256:
`e15100a8098ac9a1282a7b7dda15ca11a94015d1a4351f2d568a799b83cdc0df`.

## Comptime instance method arguments and void effects

2026-10-12, Apple M5 Pro, macOS, Zig 0.16.0, ReleaseSafe, version string
`0.16.0-dev`. Baseline `b2b053f9`. Instance calls inside interpreted functions
now accept local variables and expressions as ordinary parameters and execute
void methods that update storage used by later expressions. Local aggregate
initializers trigger interpretation when that local is used as a method
receiver. Instance detection uses the captured receiver value instead of
resolving its source again. Unknown runtime arguments still retain both branches.

For example, `check.matches(expected)` with a known local `expected` previously
returned both branch containers. It now selects the same branch as Zig. The
fixture `tests/fixtures/comptime_methods.zig` compares eight cases directly with
compiler-generated field types, including nested receivers, temporary receivers,
void methods, and exactly-once argument and receiver effects.

The interpreter also uses the existing `std.meta.FieldEnum` implementation
with its evaluated type argument, including calls through `@call`. This retains
field navigation metadata and union tag identity. Executing the standard-library
body without that shortcut produced unresolved method enums in generated
capability types; increasing the evaluation quota did not fix that failure.

The complete LSP audit passed all 661 exact definition destinations and 1,626
completion edits across 698 scanned elements. All 1,295 ZLS tests and all 17 zigraft tests passed. The targeted
method, unknown-argument, adapter, and type-identity regressions also passed in
Debug mode. Two alternating, reversed comparisons
exclude five warmups and combine 48 measured samples per binary for each request.
Every response hash matches between binaries and runs.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1742.12 | 1719.19 |
| definition | comptime_method | 1691.60 | 1668.79 |
| completion | generated_binding | 328.19 | 326.21 |
| definition | generated_binding | 296.81 | 293.42 |
| completion | generic_return_method | 1388.31 | 1378.83 |
| definition | generic_return_method | 207.12 | 202.81 |
| completion | generated_capability | 719.79 | 1477.85 |
| definition | generated_capability | 707.90 | 1477.15 |
| completion | dynamic_initializer | 2201.48 | 2179.44 |
| definition | dynamic_initializer | 315.58 | 314.62 |
| completion | standard_library | 3812.94 | 3807.04 |
| definition | standard_library | 31.02 | 31.27 |
| completion | reflection_member | 51.27 | 52.42 |
| definition | reflection_member | 46.73 | 45.23 |
| completion | package_import | 146.71 | 160.75 |
| definition | package_import | 24.06 | 23.67 |

In this initial feature version, generated-capability requests are about twice
as expensive because the
interpreter now executes validation methods previously skipped while generating
the implementation types. The follow-up measurement below addresses that cost. The other main requests
remain close to the baseline; these samples do not establish independent gains.
Baseline binary SHA-256:
`cc8208ab2c978e41ac2b19c135e95fd4e3312bdb998520eba97c23b9e45ea60f`.
Candidate binary SHA-256:
`169e2325398dc559e55df8fb741c003dcf71d5fd0cfbccd1cba8caa692edc615`.

## Defer type function bodies until arguments are bound

2026-10-12, same Apple M5 Pro, Zig 0.16.0, ReleaseSafe options, version string,
and integration source. The baseline is the instance-method feature version
above, binary SHA-256 `169e2325398dc559e55df8fb741c003dcf71d5fd0cfbccd1cba8caa692edc615`.

While the interpreter prepared a call to a type function, prototype resolution
analyzed the function body with the caller's bindings. The actual invocation
then bound the arguments and executed the body again. Type prototypes now
retain an unknown type value while the interpreter is active, so invocation
performs the body evaluation with the actual arguments. Ordinary analysis
continues resolving return types as before.

Runtime member bindings reuse the method prototype already resolved to check
its receiver. Instance-call detection checks the captured receiver and field
category without resolving the method again. Empty interpreter cell maps return
immediately. An experimental lexical-declaration cache was removed after its
allocation overhead outweighed the saved lookups in this final combination.

The fixture now includes ten compiler-computed cases. The added cases exercise
changing local arguments at the same loop callsite, equal names in distinct
scopes, and recursive type functions with pointer side effects. The final
candidate passed all 1,295 tests, the targeted Debug checks, and the complete
661 exact definition destinations / 1,626 completion edits. The actual LSP
responses match across every binary and request in the comparisons below.

Two alternating, reversed comparisons each exclude ten warmups and record 100
measured requests per case per binary. The table combines 200 samples per binary.

| Request | Case | Feature baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1737.31 | 1681.48 |
| definition | comptime_method | 1829.71 | 1797.48 |
| completion | generated_binding | 331.17 | 326.73 |
| definition | generated_binding | 311.40 | 307.73 |
| completion | generic_return_method | 1526.75 | 1499.90 |
| definition | generic_return_method | 211.04 | 208.25 |
| completion | generated_capability | 1558.88 | 779.54 |
| definition | generated_capability | 1576.83 | 780.04 |
| completion | dynamic_initializer | 2405.52 | 2308.54 |
| definition | dynamic_initializer | 342.85 | 336.42 |
| completion | standard_library | 4020.29 | 3938.44 |
| definition | standard_library | 34.60 | 34.69 |
| completion | reflection_member | 53.79 | 53.81 |
| definition | reflection_member | 51.15 | 52.04 |
| completion | package_import | 129.50 | 139.73 |
| definition | package_import | 23.69 | 23.92 |

Generated-capability completion improves 2.000x and definition improves 2.021x.
The short package-import completion remains about 10 us slower in these samples;
other changes are small and do not establish separate gains or regressions.
A second reversed comparison against the original `b2b053f9` binary combines
200 samples per binary: generated-capability completion is 726.69 -> 749.67 us,
and definition is 686.69 -> 711.65 us. Thus the full feature retains roughly
3-4% additional cost compared with the version that skipped the validation
methods, while removing most of the earlier twofold cost.

The recursive type fixture also returned the compiler's `[4]u8`, `[1]u8`,
`[0]u8` fields in both versions. Ten measured requests after three warmups gave
430.85 -> 118.60 us; reversing startup order gave 520.71 -> 121.83 us. Those
smaller samples support a reduction in repeated evaluation, but are separate
from the integration measurement above.

Final candidate binary SHA-256:
`17e5da9818a24978528cd6c49908518cd42f9e667d2590d0c15594886bc409c0`.

## Comptime pointer method receivers

2026-10-12, same Apple M5 Pro, Zig 0.16.0, ReleaseSafe options, version string,
and integration source. Baseline is the final type-prototype version above,
SHA-256 `17e5da9818a24978528cd6c49908518cd42f9e667d2590d0c15594886bc409c0`.

A method declared with `self: *Counter` previously received the counter's value
without Zig's implicit address conversion. Mutations therefore failed and the
resulting array lengths were unknown. Callee evaluation now captures the
receiver's value and storage target once. Argument binding performs the implicit
address or dereference conversion, preserving pointer aliases and by-value
snapshots. Indexing a referenced array retains the selected element's target.

For `var counter = Counter{ .count = 2 }; counter.add(3);`, followed by reading
`counter.count`, Zig and ZLS now both compute 5. The fixture includes fourteen
additional compiler-computed cases for mutable, constant, nested, optional,
indexed, and dynamically selected receivers; returned pointers; argument effects
that redirect pointer variables; by-value snapshots; and returned field aliases.
The fixture now has 24 cases total. Unknown runtime pointer receivers still
retain both conditional branches in a separate regression.

Capturing literal type namespaces preserves their declaration specialization and
already bound type values instead of rebuilding them with caller-local state.
Full-suite validation found the relevant failures in static pointer identity and
captured local type bindings; both regressions pass with the final conversion.
The final version passed all 1,296 ZLS tests and the targeted Debug checks.
The complete LSP audit again passed all 661 exact definition destinations and
1,626 completion edits across 698 scanned elements.

Two alternating, reversed comparisons each exclude ten warmups and record 100
measured requests per case per binary. The table combines 200 samples per binary;
every response hash matches between builds and runs.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1645.02 | 1639.90 |
| definition | comptime_method | 1661.83 | 1664.40 |
| completion | generated_binding | 301.54 | 302.56 |
| definition | generated_binding | 289.08 | 289.15 |
| completion | generic_return_method | 1405.40 | 1424.98 |
| definition | generic_return_method | 201.35 | 202.10 |
| completion | generated_capability | 726.21 | 745.21 |
| definition | generated_capability | 710.54 | 728.50 |
| completion | dynamic_initializer | 2086.81 | 2083.40 |
| definition | dynamic_initializer | 300.94 | 302.25 |
| completion | standard_library | 3610.92 | 3612.19 |
| definition | standard_library | 25.31 | 25.38 |
| completion | reflection_member | 45.08 | 45.27 |
| definition | reflection_member | 40.54 | 40.71 |
| completion | package_import | 132.21 | 146.00 |
| definition | package_import | 22.52 | 22.54 |

The additional receiver capture costs about 18-19 us in generated-capability
requests (roughly 2.5%). The package-import completion samples are about 14 us
slower. Other main requests remain close to the baseline; this feature change
does not establish a performance improvement. The new minimal pointer-method
fixture resolves `[5]u8` through an actual completion request, whereas the
baseline returns `[?]u8`.

Candidate binary SHA-256:
`07aaef5808b76c6bdc02027a5303123944896b8f7d0d4abd6dcf43cb9894267d`.

## Generic function reflection and dependent array returns

2026-10-12, same Apple M5 Pro, Zig 0.16.0, ReleaseSafe build options, version
string `0.16.0-dev`, and integration source. Baseline is the pointer-method
receiver version above, SHA-256
`07aaef5808b76c6bdc02027a5303123944896b8f7d0d4abd6dcf43cb9894267d`.

Function reflection previously reported a present return type for declarations
such as `fn identity(value: anytype) @TypeOf(value)`. Zig reports `null` because
the return expression depends on the function's own parameter. This also applies
to `fn typed(value: u8) @TypeOf(value)` and parameter-dependent expressions whose
branches happen to return the same type. Fixed return types of generic functions
and types captured from an enclosing specialization remain present.

The analyser now records source-level dependencies of parameter type expressions
and the return expression. Identifier dependencies use lexical declarations and
decoded identifier names, separating the function's own parameters from captured
outer parameters and fields with matching names. The metadata is cached within
the request by source node and document handle, so later callsite specialization
cannot erase the original signature dependencies. `return_type` is null for a
dependent expression, dependent parameter descriptors have `is_generic = true`
and `type = null`, and a dependent return expression marks the reflected function
as generic even when its parameters have concrete types.

Interpreter calls reuse the return dependency information after binding arguments.
This also fixes unresolved lengths in `[count]u8`, `?[count]u8`,
`[1][count]u8`, and `error{Missing}![count]u8`: the source return expression is
resolved using the actual bound count even when the previous representation
appeared resolved. Reflection remains generic before and after those calls.

`tests/fixtures/comptime_function_reflection.zig` compares eleven cases directly
with compiler-computed field types, including fixed and dependent returns,
parameter descriptors, escaped identifiers, outer captured types, nested function
returns, array return calls, differing successive arguments, and function pointers.
The original identity reflection and wrapped-array call reproductions changed
from `[0]u8` to the compiler's `[1]u8` through actual LSP completion requests.
All 1,297 ZLS tests and all 17 zigraft tests passed, along with targeted Debug
checks. The exhaustive audit passed all 661 exact definition destinations and
1,626 completion edits across 698 scanned elements.

Two alternating, reversed comparisons exclude ten warmups and record 200 measured
requests per case per binary in each run. The table combines 400 samples per
binary, with identical response hashes across both versions and both runs.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1681.38 | 1688.19 |
| definition | comptime_method | 1683.69 | 1687.73 |
| completion | generated_binding | 289.31 | 290.98 |
| definition | generated_binding | 280.60 | 282.65 |
| completion | generic_return_method | 1294.42 | 1294.83 |
| definition | generic_return_method | 191.75 | 193.10 |
| completion | generated_capability | 695.65 | 699.31 |
| definition | generated_capability | 690.54 | 694.88 |
| completion | dynamic_initializer | 1960.75 | 1959.35 |
| definition | dynamic_initializer | 291.65 | 292.92 |
| completion | standard_library | 3436.58 | 3447.71 |
| definition | standard_library | 26.27 | 26.42 |
| completion | reflection_member | 46.92 | 46.83 |
| definition | reflection_member | 43.75 | 43.85 |
| completion | package_import | 110.58 | 115.60 |
| definition | package_import | 23.46 | 23.33 |

The geometric mean speedup is 0.9944x. The main requests differ by less than
0.8%, with about 5 us additional cost in package-import completion. This is a
correctness change with a small measured cost, without evidence of a separate
performance improvement.
Candidate binary SHA-256:
`2c481b1a561a9e6043862f7ec53add4c975a1333abe5827c1a88b8f22a6380d4`.

## Evaluate signature effects and reuse completed type calls

2026-10-12, same Apple M5 Pro, Zig 0.16.0, ReleaseSafe build options, version
string `0.16.0-dev`, and integration source. Baseline is the generic-reflection
version above, SHA-256
`2c481b1a561a9e6043862f7ec53add4c975a1333abe5827c1a88b8f22a6380d4`.

Parameter and return type expressions may execute comptime functions with pointer
side effects. The previous interpreter resolved these expressions through ordinary
type inference and lost their effects: a call whose parameter and return types
both incremented a counter produced 0 instead of Zig's 2. Prototype construction
now defers parameter-dependent expressions that may execute calls or blocks.
Invocation evaluates them with the actual bindings, before the corresponding
argument and before the body, then coerces the return value using that result.
Simple type references continue using the existing generic substitution path.

Compiler-computed order checks distinguish direct calls from `@call`: direct
calls produce trace 214356 (parameter type, argument, parameter type, argument,
return type, body), while `@call` produces 132456 because its argument tuple is
constructed first. The fixture `tests/fixtures/comptime_signature_effects.zig`
compares sixteen cases with Zig, covering parameter and return effects, repeated
and recursive calls, instance methods, return casts, inferred errors, ArgsTuple,
argument effects, and pointers nested in aggregates and optionals. The original
combined-effect completion changed from `[0]u8` to the compiler's `[2]u8`.

The interpreter also uses the existing `std.meta.ArgsTuple` resolver after its
type argument has been evaluated. Completed type calls with fully known immutable
inputs can reuse results within the request. Arguments and parameter type
expressions execute before lookup. Mutable pointers, unknown inputs, anonymous
function types, display-bound containers, and strings carrying reflected source
provenance are excluded. Results reached through an inference fallback are not
stored. Changing the evaluation quota excludes the call and enclosing calls from
reuse, including quota requests that do not increase the current quota.

Cache keys snapshot bindings before running the body: growth of the local binding
map must not invalidate a key retained across evaluation. Debug validation caught
that lifetime error in an initial implementation; the final version preserves
stable snapshots. Direct cache checks require reuse for matching immutable calls,
separation for different arguments, and exclusion for quota effects. A definition
regression requires reflected fields with matching names from different source
containers to navigate to the correct container. Pointer effects remain covered
by the compiler-computed aggregate and optional cases.

The initial signature-evaluation change added roughly 150-175 us to generated
capability requests because repeated type constructors executed again. Completed
call reuse removes that cost while retaining actual signature effects. The final
candidate passed all 1,301 ZLS tests, targeted Debug checks, and all 17 zigraft
tests. The full LSP audit passed 661 exact definition targets and 1,626 completion
edits across 698 scanned elements.

Two alternating, reversed comparisons each exclude ten warmups and record 200
measured requests per case per binary. The table combines 400 samples per binary;
all response hashes match across binaries and runs.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1692.67 | 1686.83 |
| definition | comptime_method | 1746.23 | 1730.27 |
| completion | generated_binding | 300.69 | 303.10 |
| definition | generated_binding | 290.42 | 291.52 |
| completion | generic_return_method | 1385.50 | 1387.90 |
| definition | generic_return_method | 197.94 | 199.54 |
| completion | generated_capability | 730.44 | 690.19 |
| definition | generated_capability | 726.48 | 683.10 |
| completion | dynamic_initializer | 2099.46 | 2083.88 |
| definition | dynamic_initializer | 306.04 | 307.60 |
| completion | standard_library | 3765.00 | 3745.52 |
| definition | standard_library | 26.75 | 26.71 |
| completion | reflection_member | 46.42 | 46.29 |
| definition | reflection_member | 42.83 | 42.73 |
| completion | package_import | 118.81 | 119.85 |
| definition | package_import | 22.81 | 22.83 |

Generated-capability completion improves 1.058x and definition improves 1.064x.
The geometric mean speedup across sixteen requests is 1.0071x. Small differences
in other requests do not establish independent gains or regressions.
Candidate binary SHA-256:
`b2e004caa1049857497f1b1c56bb6f69e0f150c95bbda645580f0fb6f696c94e`.

## Explicit comptime operands in TypeOf

2026-10-12, same Apple M5 Pro, Zig 0.16.0, ReleaseSafe build options, version
string `0.16.0-dev`, and integration source. Baseline is the signature-effects
version above, SHA-256
`b2e004caa1049857497f1b1c56bb6f69e0f150c95bbda645580f0fb6f696c94e`.

`@TypeOf` normally analyzes operand types, but an explicitly wrapped `comptime`
operand still executes. The previous analysis lost those effects in expressions
such as `@TypeOf(comptime effect(&executions))`, including parameter and return
signatures. A function with both signatures wrapped that way produced 0 instead
of the compiler's 2 updates. The final completion now reports `[2]u8`.

Type queries now share the results of explicit comptime operands between the
initial operand scan, ordinary analysis, and interpreter result coercion. Each
independent query owns its context, and contexts are restored around actual
execution and nested queries. A known selected branch is recorded before its
explicit operand runs, so a mutation of the condition does not change the type
chosen afterward. Operands are analyzed sequentially: a later operand's effect
cannot change the type already selected for an earlier operand. `@as` supplies
the result type for nested comptime casts. Short-circuit Boolean operations,
optional fallback, and error fallback execute explicit operands only on the
selected path. Unknown runtime conditional branches retain type inference and
do not execute mutually exclusive effects.

Signature effect detection now recognizes explicit comptime expressions inside
`@TypeOf`. Parameter type resolution uses the same type-query path instead of
evaluating an entire TypeOf operand to obtain its type. The original ordinary
TypeOf behavior is retained for operands without an explicit comptime expression.

`tests/fixtures/comptime_typeof.zig` compares 21 cases with compiler-computed field
types: explicit and multiple operands, nested arithmetic, typed casts, blocks,
selected branches and switches, ordinary calls with explicit arguments, signature
effects, independent loop queries, nested queries, context restoration, condition
mutations, operand ordering, and short-circuit/fallback paths. A separate editor
regression covers effects behind unknown runtime conditions. All 1,303 ZLS tests,
targeted Debug checks, and all 17 zigraft tests passed. The exhaustive LSP audit
passed all 661 exact definition destinations and 1,626 completion edits across
698 scanned elements.

Two alternating, reversed comparisons exclude ten warmups and record 200 measured
requests per case per binary in each run. The table combines 400 samples per
binary. Response hashes match across both versions and both runs. The final
candidate was copied to a stable path before the reversed run; its SHA-256
matches the candidate from the first run and the exhaustive LSP audit.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1818.17 | 1797.85 |
| definition | comptime_method | 1825.48 | 1802.08 |
| completion | generated_binding | 339.40 | 339.52 |
| definition | generated_binding | 317.52 | 316.31 |
| completion | generic_return_method | 1585.52 | 1562.75 |
| definition | generic_return_method | 215.52 | 215.58 |
| completion | generated_capability | 772.38 | 776.19 |
| definition | generated_capability | 732.85 | 740.60 |
| completion | dynamic_initializer | 2312.52 | 2288.04 |
| definition | dynamic_initializer | 311.92 | 311.29 |
| completion | standard_library | 3838.04 | 3817.60 |
| definition | standard_library | 28.04 | 28.06 |
| completion | reflection_member | 47.23 | 47.38 |
| definition | reflection_member | 43.94 | 44.31 |
| completion | package_import | 110.60 | 114.02 |
| definition | package_import | 23.25 | 23.29 |

The geometric mean speedup is 0.99998x, treated as no material overall performance
change. Generated-capability definition has about 8 us additional cost; some
longer requests show small reductions. These samples do not establish separate
performance gains or regressions.
Final candidate binary SHA-256:
`ce2ec31f0927de0df305c842b37ae90d2b3f801c8e49180fd75c24b926bff723`.

## TypeOf control-flow input snapshots and payload captures

2026-10-12, same Apple M5 Pro, Zig 0.16.0, ReleaseSafe build options and version
string. Baseline is the explicit-TypeOf version above, SHA-256
`ce2ec31f0927de0df305c842b37ae90d2b3f801c8e49180fd75c24b926bff723`.

TypeOf operand scanning saved the selected branch, but nested Boolean, optional,
and error fallback expressions reread their left operands after explicit
comptime effects had changed the live state. A condition such as `enabled and
comptime block: { enabled = false; break :block true; }` therefore changed its
result during the subsequent type analysis. Optional payload captures also lacked
the original bound value before a selected explicit comptime block executed.

The query now retains snapshots of control-flow inputs alongside the explicit
operand results. Both analyser fallback and interpreter expression/result paths
read those snapshots within the query. Actual explicit comptime execution clears
the query context temporarily and continues reading and updating live storage.
The existing interpreter condition logic binds payloads before the selected
branch runs, preserving by-value captures and by-reference mutations.

Nine added compiler-computed fixture cases cover Boolean and fallback snapshots,
optional type and value captures, optional reference captures, error payload and
error captures, and nested optional pointer aliases. The TypeOf fixture now
checks 30 cases in one LSP regression. Debug and ReleaseSafe validation used only
`comptime TypeOf operands agree with Zig` and the unknown-runtime-condition
regression: the two selected LSP tests plus the source-test root passed (3/3).
Compilation checks also passed. No full test suite or whole-file LSP audit was
run for this iteration. Nine actual completion cases separately required exact
field details, including the original four failures changing `[0]u8` to `[1]u8`.

Performance verification was limited to comptime method and generated-capability
completion/definition requests. Two alternating reversed runs exclude five
warmups and record 40 samples per binary and request in each run, combining 80
samples per binary. All four response hashes match between versions and runs.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1704.50 | 1697.44 |
| definition | comptime_method | 1721.92 | 1698.25 |
| completion | generated_capability | 717.44 | 715.04 |
| definition | generated_capability | 680.81 | 687.92 |

These targeted samples remain close to the baseline and do not establish a
separate performance gain or regression. The completion case report and both
performance reports recorded the same candidate binary SHA-256:
`6b646e4cf9f31e2466bad50d86d847077d00a1b903cf062213795a25d1fce649`.

## TypeOf call argument and receiver snapshots

2026-10-12, same Apple M5 Pro, Zig 0.16.0, ReleaseSafe build options and version
string. Baseline is the control-flow snapshot version above, SHA-256
`6b646e4cf9f31e2466bad50d86d847077d00a1b903cf062213795a25d1fce649`.

The TypeOf operand scan executed explicit comptime arguments before resolving
the complete call, but it did not retain preceding argument values. In
`@TypeOf(chosen(T, comptime block: { T = u16; break :block 0; }))`, with an
initial `T = u8`, ZLS used the later value and inferred `u16`. Zig uses the
original `u8` argument. Calls whose result type depends on a comptime receiver's
fields also lacked the bound receiver, or dereferenced a pointer receiver only
after subsequent arguments changed the pointed-to value.

The query scan now records the callee, receiver expression, and arguments in
call order. Each explicit argument receives the expected parameter type resolved
using only previously captured arguments. A method with a comptime receiver
also records the converted receiver value before later argument effects, and
call specialization binds that snapshot. This supports `self.Item` return and
parameter types for both direct values and pointers invoking by-value methods.
Actual explicit comptime execution continues using live storage and restores
the query's snapshot context afterward.

Eleven compiler-computed cases were added to `tests/fixtures/comptime_typeof.zig`:
plain and conditional type arguments, a selected callee, array length and enum
arguments, repeated queries, by-value and pointer-to-value method receivers,
expected argument casts, receiver-dependent parameter casts, and nested calls.
The fixture now covers 41 TypeOf cases. All eleven actual completion requests
required exact field details and matched Zig. The original plain type argument
reproduction changed `[0]u8` to `[1]u8`.

Validation used only `comptime TypeOf operands agree with Zig` and the existing
unknown-runtime-condition regression, in Debug and ReleaseSafe. Both selected
LSP tests and the source-test root passed (3/3), and the compilation check passed.
No full test suite or whole-file LSP audit was run in this iteration.

Performance checks covered only comptime method and generated-capability
completion/definition requests. Two alternating reversed comparisons each
exclude five warmups and record 40 measured samples per binary and request,
combining 80 samples per binary. All four response hashes match between versions
and runs. The copied candidate used for both comparisons has the same SHA-256
as the candidate in the eleven completion checks.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1661.92 | 1660.00 |
| definition | comptime_method | 1679.75 | 1650.00 |
| completion | generated_capability | 701.48 | 694.96 |
| definition | generated_capability | 734.06 | 734.92 |

These targeted samples remain near the baseline and do not establish separate
performance gains or regressions.
Candidate binary SHA-256:
`3952a13cb154267b67a02ba512b021eb8b3567d8fad537b1f4a27d46ddb7559b`.

## TypeOf casts and aggregate initialization

2026-10-13, same Apple M5 Pro, Zig 0.16.0, ReleaseSafe build options and version
string. Baseline is the call argument snapshot version above, SHA-256
`3952a13cb154267b67a02ba512b021eb8b3567d8fad537b1f4a27d46ddb7559b`.

The TypeOf scan resolved an `@as` destination before its explicit comptime
operand, but did not retain that destination for subsequent analysis. With
`T = u8`, `@TypeOf(@as(T, comptime block: { T = u16; break :block 3; }))`
therefore incorrectly inferred `u16`. Explicit array and struct initializers
also reread their type expression after initializer effects. An initial
`count = 1` in `[count]u8{...}` was incorrectly reported with length two after
the initializer changed `count` to two. Aggregate children were scanned without
their expected field or element type, so explicit `@intCast` expressions could
fail before executing their effects.

The scan now captures cast destinations and explicit aggregate type expressions
before scanning values. It passes expected types to array, tuple, struct, and
union children using the interpreter's existing assignment type lookup. Nested
dot literals receive the optional or error-union payload's aggregate type,
and grouped expressions preserve the expected type. `@unionInit` also captures
its type and field name before scanning its typed payload.

Fifteen compiler-computed cases were added under the focused
`comptime TypeOf aggregate operands agree with Zig` test: casts, element type and
array length snapshots, structs, inferred-length arrays, tuples, nested and
grouped literals, optional/error-union wrappers, union literals, `@unionInit`,
and successive queries. All fifteen failed against the baseline and passed
exact actual LSP completion checks against the final candidate. The fixture now
contains 56 TypeOf cases.

Validation used only the affected TypeOf tests and the existing regression for
unknown runtime conditions. Debug passed both TypeOf tests, the condition
regression, and the source-test root (4/4). The first ReleaseSafe run passed the
same selected tests with eight new cases (4/4); after adding the seven remaining
cases, only the new aggregate test and source-test root were rerun (2/2), with
the compilation check and ReleaseSafe binary build passing. No full suite or
whole-file LSP audit was run.

Performance checks covered only comptime method and generated-capability
completion/definition requests. Two comparisons reverse binary order, exclude
five warmups, and record twenty measured samples per binary and request in each
run, combining forty samples per binary. All four response hashes match between
versions and runs. These measurements and the fifteen exact completion checks
use the same final candidate binary.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1648.98 | 1623.04 |
| definition | comptime_method | 1620.52 | 1625.19 |
| completion | generated_capability | 672.25 | 675.60 |
| definition | generated_capability | 674.46 | 677.17 |

These targeted samples remain near the baseline and do not establish separate
performance gains or regressions.
Candidate binary SHA-256:
`f439a2cbbd8aec2f1eb99f92e9c5fd537f145c0ed51908813464005141cf5a49`.

## TypeOf anonymous aggregate values and array type order

2026-10-13, same Apple M5 Pro, Zig 0.16.0, ReleaseSafe build options and version
string. Baseline is the cast and aggregate initialization version above, SHA-256
`f439a2cbbd8aec2f1eb99f92e9c5fd537f145c0ed51908813464005141cf5a49`.

An anonymous TypeOf tuple or struct reread earlier elements after later explicit
comptime effects. For `value = 1`, the type of
`.{ value, comptime block: { value = 2; break :block 0; } }` retained two as its
first element; Zig retains one. Anonymous struct field metadata also omitted
known comptime default values, so an undefined instance of the resulting type
could not expose a preserved type-valued field. Array type expressions similarly
reread their length after an explicit nested TypeOf effect in the element type.

The query scan now captures each aggregate child before scanning the next one.
It also captures array length, then element type, then sentinel, matching Zig's
order. A compiler oracle confirms that an element-type effect changing both
length and sentinel preserves the old length while using the new sentinel.
Anonymous struct types retain known field defaults and mark those fields
comptime; field lookup can recover the default from an undefined instance.
Tuple reflection derives comptime/default presence from its stored values.

Nine compiler-computed cases were added under the focused
`comptime TypeOf anonymous operands agree with Zig` test. Seven fail against the
baseline: scalar and type-valued tuple snapshots, an anonymous type-valued field,
array length and sentinel order, and known/runtime field metadata for structs
and tuples. Two guard cases confirm that ordinary calls inside anonymous and
typed aggregates remain unexecuted. All nine exact actual completion requests
match Zig against the final candidate. The fixture now contains 65 TypeOf cases.

Validation used the affected TypeOf tests and the runtime-condition guard,
then only the new test for its final nine cases. Final Debug and ReleaseSafe
runs each passed the new test and source-test root (2/2), and compilation/build
checks passed. Four neighboring tests were selected because field metadata
changes also affect ordinary aggregates: comptime tuple values, nominal tuple
type info, type-info field attributes, and generated struct initializer values.
Those four and the initial new test passed together in Debug (6/6 including the
source-test root). No full suite or whole-file LSP audit was run.

Performance checks covered only comptime method and generated-capability
completion/definition requests. Two comparisons reverse binary order, exclude
five warmups, and record twenty measured samples per binary and request in each
run, combining forty samples per binary. All four response hashes match between
versions and runs. These measurements and the nine exact completion checks use
the same final candidate binary.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1665.67 | 1661.77 |
| definition | comptime_method | 1638.90 | 1624.02 |
| completion | generated_capability | 674.88 | 677.02 |
| definition | generated_capability | 668.71 | 671.42 |

These targeted samples remain near the baseline and do not establish separate
performance gains or regressions.
Candidate binary SHA-256:
`99983043a5ad2f56432680423de5f370be66add83f186b14e37c294251684822`.

## TypeOf pointer syntax and vector constructors

2026-10-13, same Apple M5 Pro, Zig 0.16.0, ReleaseSafe build options and version
string. Baseline is the anonymous aggregate snapshot version above, SHA-256
`99983043a5ad2f56432680423de5f370be66add83f186b14e37c294251684822`.

The TypeOf scan followed pointer attributes in source order, then resolved the
child type. Zig evaluates the child first, followed by sentinel, address space,
alignment, and bit range. A mutable child type changed by an alignment or
sentinel expression was therefore inferred using its new value. Explicit
effects in sentinel, alignment, and child expressions produced trace `123`
instead of Zig's `312`; adding address space produced `1243` instead of `3142`.
The vector constructor also reread its length after child-type effects, turning
an initial two-element vector into four elements.

The query scan now follows the interpreter's pointer evaluation order and
captures each operand before later effects. Address-space blocks receive the
AddressSpace expected type before their value is captured, preserving enum
literal results. Vector construction captures its length before its child.
The address-space oracle additionally exposed an AST bug: pointer modifier
scanning entered address-space expressions and mistook a local `const` for a
pointer qualifier. The AST helper now skips that subexpression, matching its
existing treatment of alignment and sentinel expressions.

Ten compiler-computed cases were added under
`comptime TypeOf type constructors agree with Zig`: vector length, child-first
alignment and sentinel reads, child-type snapshots, qualifier order, bit-range
reads, address-space order, sentinel/alignment snapshots, and successive
queries. Seven failed against the baseline; three guard existing correct
behavior. All ten exact actual completion requests match Zig against the final
candidate. The fixture now contains 75 TypeOf cases. Four direct AST cases
verify that qualifiers inside address-space blocks do not become outer pointer
modifiers and that actual outer modifiers remain visible.

Validation remained focused. Debug passed the new TypeOf test, AST modifier
test, existing pointer attribute mutation and vector mutation tests, and the
source-test root (5/5). Final ReleaseSafe passed the two new tests, the existing
unknown-runtime-condition guard, and source-test root (4/4); compilation and
binary build checks passed. No full suite or whole-file LSP audit was run.

Performance checks covered only comptime method and generated-capability
completion/definition requests. Two comparisons reverse binary order, exclude
five warmups, and record twenty measured samples per binary and request in each
run, combining forty samples per binary. All four response hashes match between
versions and runs. These measurements and the ten exact completion checks use
the same final candidate binary.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1682.73 | 1648.50 |
| definition | comptime_method | 1699.27 | 1685.04 |
| completion | generated_capability | 675.77 | 693.92 |
| definition | generated_capability | 657.65 | 654.85 |

These targeted samples remain near the baseline and do not establish separate
performance gains or regressions.
Candidate binary SHA-256:
`f789340cea6b7a7d268c845b251d8b7d5e509cf947d66d70e66de281d4a75902`.

## TypeOf comptime builtin constructor arguments

2026-10-13, same Apple M5 Pro, Zig 0.16.0, ReleaseSafe build options and version
string. Baseline is the pointer syntax and vector snapshot version above,
SHA-256 `f789340cea6b7a7d268c845b251d8b7d5e509cf947d66d70e66de281d4a75902`.

TypeOf scanned nested explicit effects before resolving Int, Pointer, and Fn
constructors, causing preceding signedness, size, attributes, child type, and
return type operands to be reread after those effects. A signedness initially
unsigned became signed before Int construction; mutable pointer attributes and
Fn return types became unknown or used their later values. The interpreter also
lacked expected types for Int's bit count and Pointer's sentinel, so contextual
intCast expressions could fail even in ordinary comptime constructor calls.

Zig requires all arguments of these constructors at comptime. The TypeOf query
now evaluates the constructor once using the interpreter and captures its type
result. The shared query execution helper temporarily clears outer snapshots,
then restores them after actual execution, as explicit comptime operands already
do. This retains by-value snapshots, executes implicit and explicit effects in
order, and preserves mutable pointer aliases. Int bit counts receive u16 and
Pointer sentinels receive the optional child type before assignment coercion.

The Fn parameter-array oracle confirmed that its pointer remains an alias:
later attribute effects modifying that array must affect the constructed
parameter list. Tuple type extraction now reads interned array or tuple values
after dereferencing mutable storage, enabling this alias and ordinary Tuple
construction from type arrays. Direct Tuple calls before and after array
mutation retain independent constructed types.

Thirteen compiler-computed cases were added under
`comptime TypeOf builtin constructors agree with Zig`: Int signedness snapshots
and contextual bits; Pointer size, attributes, child and contextual alignment
or sentinel; Fn return snapshots and parameter-array aliases; single execution
of all arguments; successive queries; direct contextual constructor calls; and
Tuple construction from a mutable type array. All thirteen fail against the
baseline and match Zig in exact actual completion checks against the final
candidate. The fixture now contains 88 TypeOf and adjacent constructor cases.

Validation remained focused. Debug passed the new test, four neighboring Int,
Pointer, Fn, and Tuple mutation tests, and source-test root (6/6). ReleaseSafe
passed the initial eleven-case test and the unknown-runtime-condition guard
(3/3 including the source-test root); after strengthening the Fn alias assertion
and adding two direct-constructor cases, only the final new test and source-test
root were rerun (2/2). Compilation and binary build checks passed. No full suite
or whole-file LSP audit was run.

Performance checks covered only comptime method and generated-capability
completion/definition requests. Two comparisons reverse binary order, exclude
five warmups, and record twenty measured samples per binary and request in each
run, combining forty samples per binary. All four response hashes match between
versions and runs. These measurements and the thirteen exact completion checks
use the same final candidate binary.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1562.50 | 1589.21 |
| definition | comptime_method | 1565.29 | 1561.17 |
| completion | generated_capability | 676.27 | 671.67 |
| definition | generated_capability | 668.35 | 665.52 |

These targeted samples remain near the baseline and do not establish separate
performance gains or regressions.
Candidate binary SHA-256:
`c9d404d10e64ce4cc663003cabd055d1d03d822ddb68e378b93d6840a995b778`.

## TypeOf aggregate constructors and typed temporary pointers

2026-10-13, same Apple M5 Pro, Zig 0.16.0, ReleaseSafe build options and version
string. Baseline is the comptime builtin constructor version above, SHA-256
`c9d404d10e64ce4cc663003cabd055d1d03d822ddb68e378b93d6840a995b778`.

The TypeOf scan reread Struct, Union, and Enum layout, backing or tag operands
after later explicit effects. Attribute casts also lacked their expected type.
These constructors now use the same single comptime execution path as Int,
Pointer, and Fn, preserving scalar/type snapshots and live name/type array
aliases until construction consumes them.

The compiler comparison exposed a separate interpreter issue: a typed address
of an anonymous array first evaluated its untyped elements, then reevaluated
them during pointer coercion. An alignment initializer therefore executed its
effect twice. Typed address evaluation now constructs the pointee using the
expected type once, then materializes a temporary pointer. This also allows
contextual casts to see their element or field type before execution.

Union construction previously required an interned enum tag, so a source enum
could not retain its identity through generated union reflection or conversion.
The constructor now materializes the source enum's integer values for internal
union layout and retains its original type in request-local generated union
tag metadata. Tag reflection and union-to-enum conversion use that original
type. The oracle checks explicit enum values as well as implicit tags.

Twenty compiler-computed cases were added under
`comptime TypeOf container constructors agree with Zig`: layout/backing/tag/mode
snapshots; name and field-type array aliases; struct/union alignment and enum
value result types; single execution and successive queries; typed temporary
array, struct and optional pointers; and source enum identity through generated
union reflection and conversion. Fourteen fail against the baseline and six
guard existing behavior. All twenty exact actual completion requests match Zig
against the final candidate. The fixture now contains 108 TypeOf and adjacent
constructor cases.

Validation remained focused. Debug passed the new test, existing Struct/Union/
Enum mutation tests, aggregate call argument and nested as evaluation tests,
and source-test root (7/7). ReleaseSafe passed the initial fifteen-case test and
the preceding builtin constructor test (3/3 including the source-test root);
after adding five temporary/tag identity cases, only the final new test and
source-test root were rerun (2/2). Compilation and binary build checks passed.
No full suite or whole-file LSP audit was run.

Performance checks covered only comptime method and generated-capability
completion/definition requests. Two comparisons reverse binary order, exclude
five warmups, and record twenty measured samples per binary and request in each
run, combining forty samples per binary. All four response hashes match between
versions and runs. These measurements and the twenty exact completion checks
use the same final candidate binary.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1712.29 | 1730.77 |
| definition | comptime_method | 1666.10 | 1670.08 |
| completion | generated_capability | 742.10 | 753.04 |
| definition | generated_capability | 720.21 | 710.65 |

These targeted samples remain near the baseline and do not establish separate
performance gains or regressions.
Candidate binary SHA-256:
`e50b40448dfe4c797c8d43df08ae5758253ec12972c6c523c494825aa24ebeda`.

## Generated union source and automatic tags

2026-10-13, same Apple M5 Pro, Zig 0.16.0, ReleaseSafe build options and version
string. Baseline is the aggregate constructor version above, SHA-256
`e50b40448dfe4c797c8d43df08ae5758253ec12972c6c523c494825aa24ebeda`.

Ordinary tagged Union construction did not reach the interpreter when its type
function had no explicit effects, leaving source enum tags and initialized
payloads unknown. Automatic enum tags obtained from a source union also lacked
the source container needed for internal enum materialization. Tagged Union
calls now trigger interpreter evaluation in type functions and during direct
analysis, while literal-null tag calls retain their previous fast path. Source
union tags use their original container's field names and ordinal values for
materialization and retain their original type through generated tag metadata.
Zig compiler checks confirmed that union fields must match tag enum field order;
the existing order validation remains in place.

Generated tagged unions now accept enum literals for void payloads. Analysis
and interpretation share union-to-enum conversion, checking the exact tag type
and recovering the active field's enum value. Global typed enum declarations
use this conversion after ordinary coercion, with typed interpreter fallback
only for a matching union whose active value remains unknown. This covers
values returned by calls, blocks, and field expressions.

An initial implementation caused a repeatable 7-9 percent regression in the
comptime method requests. A request trace located repeated analysis of
`if (from < 0) .signed else .unsigned` in std/math.zig during enum conversion
fallback. Conversion now runs after ordinary coercion and skips expressions
whose possible results are all enum literals. Final reversed comparisons
returned those requests to the baseline range while preserving all new union
conversion cases.

Fifteen compiler-computed cases were added in
`tests/fixtures/comptime_union_tags.zig` under
`comptime generated union tags agree with Zig`: explicit source/generated tags,
sparse and signed values, switch tag captures, independent enum identities,
automatic tags from typeInfo and std.meta.Tag, captured automatic tags, void
payload literals, repeated cached constructors, global source tags, and
call/block/field conversions. All fifteen fail against the baseline and match
Zig in exact actual completion checks against the final candidate.

Validation remained focused. Final Debug passed the new test, ordinary Int
constructor and unknown-runtime enumFromInt regressions, and source-test root
(4/4). Final ReleaseSafe passed the new fifteen-case test and source-test root
(2/2), with compilation and binary build checks passing. Before the enum
fallback refinements, the thirteen-case test, ordinary Union constructor,
generated union initializer, invalid union payload, and preceding container
constructor tests passed in ReleaseSafe (6/6 including the source-test root).
No full suite or whole-file LSP audit was run.

Performance checks covered only comptime method and generated-capability
completion/definition requests. Two comparisons reverse binary order, exclude
five warmups, and record twenty measured samples per binary and request in each
run, combining forty samples per binary. All four response hashes match between
versions and runs. These measurements and the fifteen exact completion checks
use the same final candidate binary.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1662.25 | 1657.56 |
| definition | comptime_method | 1669.21 | 1676.21 |
| completion | generated_capability | 692.02 | 689.33 |
| definition | generated_capability | 698.77 | 700.00 |

These targeted medians differ by less than 0.5 percent and do not establish
separate performance gains or regressions.
Candidate binary SHA-256:
`dfa01c212d9f26ea7e1e4080210e82359e148b07c3b405d56cf67dca1000040f`.

## Generated union source payload types and field provenance

2026-10-13, same Apple M5 Pro, Zig 0.16.0, ReleaseSafe build options and version
string. Baseline is the generated union tag version above, SHA-256
`dfa01c212d9f26ea7e1e4080210e82359e148b07c3b405d56cf67dca1000040f`.

Union construction required every payload type to have an InternPool index.
Source structs, enums, unions, and wrappers around them lost their concrete
type or prevented construction. This affected FieldType, typeInfo, initializer
result types, switch payload captures, and field completion. The constructor
now retains complete field Types in request-local generated union metadata,
alongside alignment and reflected name provenance. Its interned representation
uses unknown_type only where the source type cannot be interned; field lookup,
reflection, initialization, completion, and navigation use the retained type.
The ordinary constructor also accepts tuples containing source types and
packed union validation uses the complete source payload type's bit size.

Generated struct and union fields share a metadata lookup for completions and
source navigation. Reflected names preserve their original field token, while
computed names can navigate to the payload type definition. Global typed union
literals and unionInit calls whose payload type cannot be interned use typed
interpreter evaluation, retaining initialized payload values.

Fifteen compiler-computed cases were added in
`tests/fixtures/comptime_union_payloads.zig` under
`comptime generated union payloads agree with Zig`: source struct/enum/union
payloads, optional/array/error wrappers, untagged construction, switch capture,
unionInit, generic payloads, field-type array aliases, packed source payloads,
nested generated unions, and global literals/unionInit. All fifteen fail against
the baseline and match Zig in exact actual completion checks against the final
candidate. Two focused completion checks cover runtime union field details and
nested source payload members. Two definition checks cover payload type
navigation and reflected source field provenance.

Validation remained focused. Debug passed the compiler-computed payload test
and the focused completion/definition checks during development, then reran only
the payload test for the two final global cases. Final ReleaseSafe passed all
three new tests, ordinary Union construction, non-IP source union payload
validation, generated Struct provenance navigation, and source-test root (7/7).
Compilation and binary build checks passed. No full suite or whole-file LSP
audit was run.

Performance checks covered only comptime method and generated-capability
completion/definition requests. Two comparisons reverse binary order, exclude
five warmups, and record twenty measured samples per binary and request in each
run, combining forty samples per binary. All four response hashes match between
versions and runs. These measurements and the fifteen exact completion checks
use the same final candidate binary.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1713.67 | 1680.98 |
| definition | comptime_method | 1637.75 | 1655.52 |
| completion | generated_capability | 685.44 | 694.81 |
| definition | generated_capability | 700.56 | 699.67 |

These targeted samples remain near the baseline and do not establish separate
performance gains or regressions.
Candidate binary SHA-256:
`8f1fe42255e269818d4a7e3f71135ae631d0a10b7dbcc8d9947271dc59bc0b20`.

## Generated union payload identity at call boundaries

2026-10-13, same Apple M5 Pro, Zig 0.16.0, ReleaseSafe build options and version
string. Baseline is the source payload metadata version above, SHA-256
`8f1fe42255e269818d4a7e3f71135ae631d0a10b7dbcc8d9947271dc59bc0b20`.

The interpreter accepted values of a different named source type when the
destination had no InternPool index. For two distinct structs A and B with
the same fields, passing B as the A payload of a generated union incorrectly
selected the successful branch and exposed its value. Zig rejects this
conversion. The same permissive fallback affected optional, array, pointer,
error-union, enum, and union payloads.

Non-interned coercion now rejects conflicting source type identities and checks
wrapped payload types recursively. Literal syntax still receives its expected
type before coercion. A stored anonymous struct has its own type and is rejected
when assigned to a different named struct, matching the compiler. Automatic
union tag identities and tuple element types receive the same checks. Null
remains valid for an optional source payload and is materialized with the
destination optional type, preserving type queries after the call boundary.

The focused invalid-payload test covers twelve input categories in both
parameter and return positions (24 requests): distinct structs, optional
structs, arrays, pointers, enums, optional enums, unions, error-union structs,
scalar-to-struct input, stored anonymous structs, automatic union tags, and
nominal tuples. All 24 examples were independently rejected by Zig with an
expected-type mismatch. Exact actual completion requests against the final
candidate retain both possible branches and unknown payload values instead of
claiming successful evaluation.

Fourteen compiler-computed valid cases were added in
`tests/fixtures/comptime_union_boundaries.zig`: source payload arguments and
returns, forwarding calls, optional/error payloads, by-value and comptime
snapshots, pointer aliases, return control flow, TypeOf calls, null optionals,
same-type values across scopes, pointer qualifier coercion, and wrapped same
types. All fourteen exact actual completions match Zig. The original ten valid
boundary cases already matched the baseline and guard their behavior during
the stricter conversion change.

Validation remained focused. Debug passed the new invalid and valid boundary
tests together with source payload and dependent parameter regressions (5/5
including the source-test root). The final automatic-tag/tuple/null assertions
passed in a narrower Debug run (3/3), followed by an invalid-test-only rerun
after correcting an unused error-union value in its source (2/2). ReleaseSafe
passed the new invalid and valid boundary tests, dependent parameter and invalid
union payload regressions, and source-test root (5/5). Compilation and binary
build checks passed. No full suite or whole-file LSP audit was run.

Performance checks covered only comptime method and generated-capability
completion/definition requests. Two comparisons reverse binary order, exclude
five warmups, and record twenty measured samples per binary and request in each
run, combining forty samples per binary. All four response hashes match between
versions and runs. These measurements and the 38 exact valid/invalid completion
checks use the same final candidate binary.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1745.15 | 1766.65 |
| definition | comptime_method | 1776.58 | 1801.58 |
| completion | generated_capability | 734.31 | 743.25 |
| definition | generated_capability | 709.48 | 718.83 |

These targeted samples remain near the baseline and do not establish separate
performance gains or regressions.
Candidate binary SHA-256:
`d3a241fe37c6e29a13b482b6423b1b65662694ebf38a0ebd1fcd40b292490732`.

## Generated container nominal identity and coercion

2026-10-13, same Apple M5 Pro, Zig 0.16.0, ReleaseSafe build options and version
string. Baseline is the call-boundary source payload version above, SHA-256
`d3a241fe37c6e29a13b482b6423b1b65662694ebf38a0ebd1fcd40b292490732`.

Interned generated enum, struct, and union destinations bypassed the source
identity checks used for non-interned types. They therefore accepted values of
distinct source or generated types and exposed those invalid payload values.
Coercion now checks nominal identity for both representations, including
optional, array, pointer, and error-union wrappers. Twenty-two parameter/return
examples were independently rejected by Zig with expected-type mismatches;
twenty incorrectly produced known values against the baseline, while two
pointer examples already remained unknown. All twenty-two exact completion
checks against the final candidate keep the values unknown.

Strict identity validation also revealed that repeated analysis of one
constructor expression could allocate different InternPool identities. A
request-local identity map now keys Struct, Union, and Enum results by source
position and their evaluated construction arguments: layout/backing/tag,
names, complete field types, alignments, defaults, or enum values. Arguments
still execute before lookup, preserving effects. Reflected field provenance is
included so result reuse keeps the correct navigation metadata. The compiler
confirms that unrelated generic arguments do not split identity when one
constructor position receives the same concrete operands; different positions
or construction operands remain distinct.

Fourteen compiler-computed cases in
`tests/fixtures/comptime_container_identity.zig` check repeated generic struct,
enum, and union construction; effect counts; changed fields, attributes, enum
values, tags, names, and defaults; independent source positions; same-type call
boundaries; and pointer qualifier coercion. Six fail against the baseline and
eight guard existing behavior. All fourteen exact completions match Zig against
the final candidate. A default-value case also showed that a type function
containing ptrCast must use the interpreter to materialize its default pointer;
the interpreter eligibility scan now recognizes that builtin.

Validation remained focused. Debug passed the new identity and invalid-type
tests and the preceding union boundary test (4/4 including the source-test
root). During development, reflected field provenance and quota-effect cache
regressions also passed, and the final default-value/identity tests passed in a
narrower Debug run (3/3). Final ReleaseSafe passed both new tests, union
boundaries, reflected field provenance, quota effects, pointer cast address
identity, and source-test root (7/7). Compilation and binary build checks passed.
No full suite or whole-file LSP audit was run.

Performance checks covered only comptime method and generated-capability
completion/definition requests. Two comparisons reverse binary order, exclude
five warmups, and record twenty measured samples per binary and request in each
run, combining forty samples per binary. All four response hashes match between
versions and runs. These measurements and the 36 exact valid/invalid completion
checks use the same final candidate binary.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1763.40 | 1745.06 |
| definition | comptime_method | 1714.19 | 1714.69 |
| completion | generated_capability | 684.44 | 694.65 |
| definition | generated_capability | 710.71 | 708.27 |

These targeted samples remain near the baseline and do not establish separate
performance gains or regressions.
Candidate binary SHA-256:
`65ca88c1e8f600d84f5aebf3dd7dff846db7f7f9bf30224095f05b7ee5628dff`.

## Generated Struct comptime fields

2026-10-13, same host, Zig 0.16.0, ReleaseSafe build options and version string.
Baseline is the generated container nominal identity version above, SHA-256
`65ca88c1e8f600d84f5aebf3dd7dff846db7f7f9bf30224095f05b7ee5628dff`.

Struct construction previously rejected field attributes with `comptime = true`.
Both evaluated and literal attribute paths now preserve that flag, include it
in generated type identity, and store it in InternPool and generated field
metadata. Comptime fields require a default and auto layout. Undefined defaults
remain legal; missing defaults and extern or packed comptime fields are rejected.
Runtime size and alignment omit comptime fields, and a sole runtime field in an
auto struct has offset zero. Multiple auto-layout runtime field offsets remain
unknown because the compiler can reorder them.

Reads preserve scalar, source aggregate, and type-valued defaults, including
reads from undefined aggregate instances. Materialization now accepts pointers
to type values. Initializers coerce explicit values to the declared field type
and compare them with the default. Assignment uses the same rule: storing the
default again is legal and executes the right-hand expression once. Nested
subfield assignments must leave the entire comptime default unchanged. A
successful equal write leaves storage unchanged; a different value stops known
evaluation. Field assignment types come from declaration metadata, so a field
whose default is `u16` and whose declaration type is `type` retains `type` as its
expected assignment type.

Seventeen compiler-computed cases in
`tests/fixtures/comptime_generated_fields.zig` cover scalar and undefined-instance
reads, explicit initializers and their effects, source and type-valued defaults,
same-value scalar/source/type writes, nested writes, result locations, explicit
alignment, comptime-only layout, undefined defaults, and type identity. Fifteen
exact completion checks fail against the baseline and two guard existing
behavior; all seventeen match Zig against the candidate.

Seven separate initializer/write examples are rejected by Zig because their
values differ from the comptime default. The baseline incorrectly exposes known
runtime field values for two typed initializer examples; the candidate keeps
all seven results unknown. Three additional compiler examples establish the
missing-default, extern, and packed construction rules, and the candidate
exposes no fields for these invalid generated types. New request regressions
check dot and initializer completion details, source methods through a default
type, and declaration/definition/type-definition selection ranges.

Validation remained scoped to these changes. Debug passed the new value,
mismatched-value, completion, and navigation regressions. Final ReleaseSafe
passed all five new tests plus the adjacent generated container identity,
source field defaults, explicit struct initializer result locations, reflected
field navigation, and source-test root (10/10). Compilation and binary build
checks passed, as did formatting and diff whitespace checks. Thirty-six exact
LSP requests against the final binary passed: seventeen valid value checks,
seven mismatched-value checks, three completion detail checks, six navigation
range checks, and three invalid-construction checks. No full suite was run.

Performance checks covered only comptime method and generated-capability
completion/definition requests in the existing zigraft integration document.
Two comparisons reverse binary order, exclude five warmups, and record twenty
measured samples per binary and request in each run, combining forty samples
per binary. All four response hashes match between versions and runs. These
measurements and all thirty-six exact requests use the same final candidate.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1745.94 | 1739.04 |
| definition | comptime_method | 1744.29 | 1741.21 |
| completion | generated_capability | 708.06 | 709.56 |
| definition | generated_capability | 705.00 | 701.71 |

These targeted samples remain near the baseline and do not establish separate
performance gains or regressions.
Candidate binary SHA-256:
`214a55b575bbf443cfd88b28214781fac89a6170d1e8e8c62b378ff84a994a22`.

## Complex comptime defaults and union tag comparisons

2026-10-13, same host, Zig 0.16.0, ReleaseSafe build options and version string.
Baseline is the generated Struct comptime field version above, SHA-256
`214a55b575bbf443cfd88b28214781fac89a6170d1e8e8c62b378ff84a994a22`.

A pointer to a slice could not materialize the slice itself because pointer
child handling tried to dereference that slice again. This lost generated
Struct defaults and stopped otherwise legal same-value writes. Single pointers
now accept slice children in both source and InternPool representations.
Unknown field attributes are also rejected instead of interpreting unavailable
members as empty attributes and producing ordinary runtime fields.

Static array slice defaults exposed a second discrepancy. Capturing a namespace
constant through a field access used the access expression as its storage
origin, while another read used the constant declaration. The two sequences
therefore compared unequal despite sharing the same storage, offset, and
length. Namespace field capture now resolves the known declaration value and
records the declaration as its origin. Type declarations retain their existing
namespace behavior. Slice equality remains unchanged: a different declaration,
offset, or length still differs from the comptime default.

Tagged union values with active payloads also failed equality and inequality
against tag literals or explicit tag enum values. Comparison now converts a
known active union field to the original tag enum before comparing, in either
operand order. An AST-only const initializer path can recover the active field
without evaluating its payload. Untagged unions, unknown active fields, and
different enum identities remain unknown. Twelve independent compiler examples
confirm the runtime-value, untagged-union, and wrong-enum failures for both
operand orders and both comparison operators.

Thirty-four compiler-computed examples in
`tests/fixtures/comptime_generated_defaults.zig` cover array and vector defaults,
optional payloads and nulls, error-union payloads and failures, enum and union
values, source and generated union tag comparisons, type arrays, source type
specializations, nested aggregates, undefined array elements, and slice/pointer
initializers and writes. Eight exact completion checks fail against the
baseline; twenty-six guard existing behavior. All thirty-four match Zig against
the candidate. Extra slice checks confirm same-value writes, default copies,
self-assignment, one-time expression effects, and preserved backing identity.

Three compiler examples reject changes to slice storage, offset, or length.
The focused LSP regression keeps the affected results unknown. Another compiler
example rejects runtime-unknown Struct field attributes. The boundary test
checks that invalid or unknown union comparisons do not expose definite boolean
results. All forty-six final binary requests pass: thirty-four compiler-computed
cases, eight additional valid/invalid slice checks, three union boundary checks,
and one unknown-attribute check.

Debug passed the new focused regressions. Final ReleaseSafe passed all four new
tests, the preceding generated comptime field test, generated union tag test,
static pointer alias sequence reads, slice comparison boundary, and source-test
root (9/9). Compilation, binary build, formatting, and diff whitespace checks
passed. No full suite was run.

Performance checks use only the existing zigraft comptime method and
generated-capability completion/definition requests. Two comparisons reverse
binary order, exclude five warmups, and combine forty measured samples per
binary and request. All four response hashes match between binaries and runs.
These measurements and all forty-six exact requests use the same candidate.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1747.79 | 1773.75 |
| definition | comptime_method | 1763.85 | 1771.60 |
| completion | generated_capability | 744.06 | 748.23 |
| definition | generated_capability | 722.69 | 726.67 |

These small targeted differences do not establish a separate performance gain
or regression.
Candidate binary SHA-256:
`45054ac3064e02bf136acd427f9e9ce5d10d1df17e69661e823d9587065256f7`.

## Source Struct comptime fields

2026-10-13, same host, Zig 0.16.0, ReleaseSafe build options and version string.
Baseline is the complex-default and union-tag comparison version above,
SHA-256 `45054ac3064e02bf136acd427f9e9ce5d10d1df17e69661e823d9587065256f7`.

Source struct comptime fields still used ordinary field assignment rules, while
the preceding implementation validated only generated fields. The default
lookup now handles source declarations and retains their specialization when
evaluating the declared default. Explicit initializers, field assignments,
subfield assignments, and pointer writes use that same default comparison.
Equal writes succeed without changing storage; different values stop known
evaluation. Declaration types remain separate from defaults, so a type-valued
field keeps `type` as its assignment type and exposes its default type on reads.

Reading defaults from a source instance also required materialized fields, which
excluded undefined instances. Source comptime field reads now recover their
defaults from the declaration even when the instance itself is unknown. This
shares the existing source default lookup instead of performing another field
lookup for materialized aggregates. Ordinary runtime defaults continue to apply
only to materialized aggregates with omitted fields.

The interpreter eligibility scan now recognizes direct comptime fields in local
container declarations. It also materializes local aggregate initializers used
in field reads, extending the existing method-receiver scan. This preserves
ordinary member values when a source comptime type is reached through a generic
factory or global declaration. Unused aggregate initializers retain the existing
eligibility behavior.

Twenty-one compiler-computed examples in
`tests/fixtures/comptime_source_fields.zig` cover scalar, source aggregate,
type-valued, array, optional, and slice fields; undefined instances and defaults;
explicit initializers; same-value whole-field, nested, and pointer writes;
one-time initializer/assignment effects; generic and global declarations;
repeated specializations; and comptime-only layout. Twelve exact completion
checks fail against the baseline and nine guard existing behavior. All
twenty-one match Zig against the candidate.

Eight independent compiler examples reject scalar, source aggregate, and type
initializer/write mismatches. Four write examples incorrectly expose known
ordinary member values against the baseline; the candidate keeps all eight
results unknown. New feature regressions also check completion through a
type-valued default on an undefined instance and precise declaration,
definition, and type-definition navigation to the source field.

Debug passed the new value, mismatch, completion, and navigation tests and the
adjacent nested field default test. Final ReleaseSafe passed all four new tests,
generated comptime fields, nested and specialized source defaults, evaluation
quota cache effects, TypeOf aggregate operands, and source-test root (10/10).
Compilation, binary build, formatting, and diff whitespace checks passed.
Thirty-three exact requests against the final binary passed: twenty-one valid
value checks, eight mismatched-value checks, one completion check, and three
navigation range checks. No full suite was run.

Performance checks use only the existing zigraft comptime method and
generated-capability completion/definition requests. Two comparisons reverse
binary order, exclude five warmups, and combine forty measured samples per
binary and request. All four response hashes match between binaries and runs.
These measurements and all thirty-three exact requests use the same candidate.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1715.33 | 1751.48 |
| definition | comptime_method | 1661.81 | 1628.27 |
| completion | generated_capability | 687.77 | 688.65 |
| definition | generated_capability | 674.85 | 666.46 |

These targeted samples remain near the baseline and do not establish a separate
performance gain or regression.
Candidate binary SHA-256:
`54273bcb1b9b27d8afb57aedc0567e62aee954324de6b3110a63009e75f95bd9`.

## Reflected Struct default pointers

2026-10-13, same host, Zig 0.16.0, ReleaseSafe build options and version string.
Baseline is the source Struct comptime field version above, SHA-256
`54273bcb1b9b27d8afb57aedc0567e62aee954324de6b3110a63009e75f95bd9`.

Struct field reflection previously represented a present default pointer as an
unknown pointer. Presence tests worked, but casting and dereferencing it lost
the actual default. A small lazy descriptor now records the reflected type and
field index; pointer use materializes the default from source declarations,
generated field metadata, or InternPool fields. Null/presence checks avoid
evaluating the default. The standard StructField.defaultValue method also
resolves its reflected receiver outside interpreter execution, supporting
completion and navigation through a type-valued default.

Independent Zig pointer identity examples establish that equal defaults of the
same type share a temporary identity, even across different source fields or
struct types. Generated reflection has this same identity and differs from the
original named default pointer supplied to Struct construction. The
implementation reuses the existing temporary value identity; field position or
the original constructor pointer does not define the reflected address. Copies
and repeated reflection retain identity, while different types or values differ.

Nested ptrCast/alignCast evaluation now supplies the outer destination's
alignment to the inner cast while retaining its source child type and identity.
Type-valued and optional pointees are supported. Pointer dereference validates
the stored pointee type: same-type reads retain their value, same-size supported
reinterpretations use bitCast, and unsupported or oversized reads retain an
unknown value of the destination type. Zig independently rejects reading a u8
default through a u16 pointer; a u8-to-i8 reinterpretation is legal and matches
the compiler. Struct construction restores the declared field pointer type
before reading an erased default pointer.

The defaultValue type case also exposed existing type values acquiring extra
bindings when returned or passed through a break. Newly evaluated container
expressions continue to capture their environment at creation; returning an
existing type preserves its identity. Source instances retain the existing
binding capture. Direct address-of-as expressions materialize temporary values
and trigger interpreter eligibility. Other address expressions retain their
existing eligibility and subobject capture behavior.

Twenty-nine compiler-computed examples in
`tests/fixtures/comptime_reflected_defaults.zig` cover source and generated
defaults, scalar/array/slice/aggregate/optional/type/void values, missing defaults,
repeated and copied reflection, equal and different temporary identities,
generic specialization, reconstructed field defaults, StructField.defaultValue,
optional pointers, one-time operand effects, type identity through return/break,
and signed reinterpretation. Twenty-six exact completion checks fail against
the baseline and three guard existing behavior. All twenty-nine match Zig
against the final candidate. New feature tests check completion and precise
declaration/definition/type-definition selection through a reflected type
default; an oversized-read regression remains unknown.

Final ReleaseSafe passed all four new tests, pointer cast identity, temporary
switch pointer capture, function reflection, generated container identity,
complex generated defaults, and source-test root (10/10). Adjacent Debug checks
also covered source comptime fields, static capture aliases, and explicit struct
initializer result locations. Compilation, binary build, formatting, and diff
whitespace checks passed. Thirty-four exact final binary requests passed:
twenty-nine compiler-computed values, one completion, three navigation ranges,
and one oversized read. No full suite was run.

Performance checks use only the existing zigraft comptime method and
generated-capability completion/definition requests. An initial broad
address-expression eligibility change caused extra type function interpretation
and a substantial method-request slowdown. Native sampling and isolated
comparisons identified the eligibility trigger; restricting the new trigger to
direct address-of-as expressions restored method timings while retaining the
default pointer behavior. The final comparisons reverse binary order, exclude
five warmups, and combine forty measured samples per binary and request. All
four response hashes match between binaries and runs. These measurements and
all thirty-four exact requests use the same final candidate.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1661.50 | 1657.85 |
| definition | comptime_method | 1600.29 | 1618.75 |
| completion | generated_capability | 686.81 | 647.46 |
| definition | generated_capability | 675.60 | 640.19 |

Method timings remain near the baseline. Generated-capability requests are
about five percent faster in these targeted samples; this does not establish a
project-wide performance change.
Candidate binary SHA-256:
`594744327a4749276d433582321c92950593b13f9c95e76ffe88d7cc95dc504a`.

## Reflected pointer and array sentinels

2026-10-13, same host, Zig 0.16.0, ReleaseSafe build options and version string.
Baseline is the reflected Struct default pointer version above, SHA-256
`594744327a4749276d433582321c92950593b13f9c95e76ffe88d7cc95dc504a`.

Pointer and array reflection represented a present sentinel pointer as an
unknown pointer, preserving presence tests while losing its pointee. The lazy
reflection descriptor now distinguishes a Struct field default from an interned
sentinel value. Both use the existing pointer materialization and temporary
value identity rules, so reflected sentinel pointers can be cast, dereferenced,
compared, and used by Pointer.sentinel, Array.sentinel, and std.meta.sentinel.
Presence tests retain the existing path without materializing a pointee.

Twenty-one compiler-computed examples in
`tests/fixtures/comptime_reflected_sentinels.zig` cover many pointers, slices,
arrays, wide integers, booleans, signed and zero sentinels, absent sentinels,
generic specialization, repeated reflection, shared identity across pointer
and array types and Struct defaults, and one-time cast operand effects. They
also exercise the builtin sentinel methods and std.meta.sentinel, including
single pointers to sentinel arrays. Eighteen exact completion checks fail
against the baseline; three absent-sentinel examples guard existing behavior.
All twenty-one match Zig against the final candidate.

New request tests cover four top-level sentinel method expressions, an
oversized read, and source declaration/definition/type-definition navigation
selected by a sentinel result. Zig independently rejects reading a u8 sentinel
through a u16 pointer; the LSP result remains unknown. All twenty-nine final
binary requests pass: twenty-one compiler-computed values, four top-level
method completions, one oversized-read completion, and three navigation ranges.

Debug passed all four new tests and the preceding reflected default pointer
test. Final ReleaseSafe passed all four new tests, reflected Struct defaults,
sentinel presence, sentinel boundary pointer identity, evaluation quota cache
effects, and source-test root (9/9). Compilation, binary build, formatting, and
diff whitespace checks passed. No full suite was run.

Performance checks use only the existing zigraft comptime method and
generated-capability completion/definition requests. Two comparisons reverse
binary order, exclude five warmups, and combine forty measured samples per
binary and request. All four response hashes match between binaries and runs.
These measurements and all twenty-nine exact requests use the same candidate.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1826.73 | 1833.90 |
| definition | comptime_method | 1845.52 | 1852.71 |
| completion | generated_capability | 732.63 | 714.88 |
| definition | generated_capability | 719.52 | 719.38 |

These targeted samples remain near the baseline and do not establish a separate
performance gain or regression.
Candidate binary SHA-256:
`5de09add8ed8f32dd895ffea693d9f7fcec94a98df8f6b29d55195cdbab3b1a2`.

## Source and generated union layouts

2026-10-13, same host, Zig 0.16.0, ReleaseSafe build options and version string.
Baseline is the reflected sentinel version above, SHA-256
`5de09add8ed8f32dd895ffea693d9f7fcec94a98df8f6b29d55195cdbab3b1a2`.

Source unions and generated auto/extern unions did not provide comptime size or
alignment values. A shared union accumulator now resolves payload size,
explicit and natural alignment, tag storage and final padding. Packed unions
retain their bit width while using their integer backing for ABI size and
alignment. Field validation rejects incompatible packed and extern payloads.
The three size builtins preserve distinct legal results: empty or wholly
uninhabited auto unions have zero bits, while comptime-only union fields allow
alignment and bit-size queries without supplying a runtime byte size.

Auto untagged union safety tags use the declaration context and the mode from
the document's resolved builtin import. Interpreted settings execute once and
are scoped to their executable block. Source and generated types retain their
creation-time safety, so later settings cannot alter existing layouts. Function
and container declarations start separate safety scopes. Source union capture
filters direct dependencies while retaining conservative fallback for indirect
calls or incomplete scans; changing only a safety parameter preserves nominal
identity and the first concrete creation's layout.

Sixty-six compiler-computed examples in
`tests/fixtures/comptime_union_layout.zig` cover source and generated layouts,
tag and payload padding, explicit alignment, zero-size and noreturn fields,
packed booleans/enums/floats and nested types, optional pointers and vectors,
generic payloads, identity, declaration order, scope boundaries and one-time
safety effects. Sixty-three exact completion checks fail against the baseline;
all sixty-six match Zig against the final candidate. Twenty-five additional
requests check rejected, recursive and unresolved layouts plus the distinct
legal alignment and bit-size results. Four actual mode requests cover Debug,
ReleaseSafe, ReleaseFast and ReleaseSmall with source/generated and explicit
safety overrides. All ninety-five final binary requests pass.

Debug and ReleaseSafe passed the new layout tests and the related generated
union tags/payloads/boundaries, generated container identity, struct layout and
quota-effect regressions (10/10 each). The final scope-scan refinement then
passed only the three affected union-layout tests and source-test root (4/4 in
each mode). Final binary compilation, formatting and diff whitespace checks
passed. No full suite was run.

The resolved builtin mode depends on the existing project/global builtin
configuration; the build runner does not currently expose effective per-module
optimization settings. Existing scalar ABI calculations continue to use the
target that compiled ZLS. Unknown mode or unsupported layouts retain unknown
results.

Performance checks use only the existing zigraft comptime method and
generated-capability completion/definition requests. Two comparisons reverse
binary order, exclude five warmups and combine forty measured samples per
binary and request. All four response hashes match between binaries and runs.
These comparisons and all ninety-five exact requests use the same final
candidate. The targeted timings remain near the baseline and do not establish
a project-wide performance change.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1600.73 | 1606.73 |
| definition | comptime_method | 1567.40 | 1549.06 |
| completion | generated_capability | 614.96 | 613.52 |
| definition | generated_capability | 611.27 | 610.37 |

Candidate binary SHA-256:
`d263da57633f3509f7f8113797e7f4442cdcde6802564e45dfc94a78b2a7afdd`.

## Optional and error-union layouts

2026-10-13, same host, Zig 0.16.0, ReleaseSafe build options and version string.
Baseline is the union layout version above, SHA-256
`d263da57633f3509f7f8113797e7f4442cdcde6802564e45dfc94a78b2a7afdd`.

Optional, error-union and error-set size builtins returned unknown values.
Source and InternPool representations now share wrapper layout rules. Ordinary
optionals add a presence byte and alignment padding; ordinary pointers, slices
and error sets reuse their null encoding. C and allowzero pointers retain a
separate presence byte. Error unions retain the error code even for an empty
error set and pad its payload and final size to the required alignment.

Internal payload layout is distinct from public size availability. The wrapper
path tracks comptime-only fields, uninstantiable source containers and retained
runtime payloads so alignment and bit-size queries can succeed while size stays
unknown. This includes pure comptime optionals nested in error unions, zero-size
payloads with large alignment, and the zero-size optional of noreturn or an
uninstantiable source container. Alignment recursion is separate from size
recursion and shares the existing depth guard. Union fields use the general
optional layout path rather than a special optional-pointer size calculation.

Fifty-seven compiler-computed examples in
`tests/fixtures/comptime_wrapped_layout.zig` cover primitive and source payloads,
generated containers, pointer/slice null representation, C and allowzero
pointers, error sets, zero-size and uninstantiable payloads, comptime-only
containers, nested wrappers, 24 nested optionals, changing payload snapshots
and one-time builtin operand effects. A generated union/optional alternating
chain exercises fourteen layers. All fifty-seven exact completion checks fail
against the baseline and match Zig against the final candidate. Eleven further
requests cover invalid, recursive and unresolved types plus partially available
comptime-only metrics. All sixty-eight final binary requests pass.

Debug passed the two new wrapper tests and directly related union, scalar-size,
struct-layout and nested-size-effect tests plus source-test root (9/9).
ReleaseSafe passed those tests and the two reflected-pointer oversized-read
boundaries (11/11). Final binary compilation, formatting and diff whitespace
checks passed. The direct alternating-chain refinement then reran only the
affected wrapper and union tests plus source-test root: Debug 5/5 and
ReleaseSafe 6/6 passed. No full suite was run.

Unknown inferred error sets and unsupported layouts retain unknown results.
The wrapper path keeps the existing conservative limitation for heterogeneous
auto struct ordering and checked arithmetic for extreme layout overflow. ABI
calculations continue to use the target that compiled ZLS.

Performance checks use only the existing zigraft comptime method and
generated-capability completion/definition requests. Two comparisons reverse
binary order, exclude five warmups and combine forty measured samples per
binary and request. All four response hashes match between binaries and runs.
These comparisons and all sixty-eight exact requests use the same final
candidate; the targeted samples remain near the baseline.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1669.42 | 1677.38 |
| definition | comptime_method | 1672.83 | 1674.73 |
| completion | generated_capability | 662.33 | 664.42 |
| definition | generated_capability | 651.58 | 648.75 |

The fourteen-layer alternating union/optional completion exposed repeated
alignment and size walks through each payload. Union accumulation now obtains
a direct optional or error-union field's size and alignment in one payload
walk. With three warmups and ten measured samples, this request's median fell
from 7422.19 us before the refinement to 675.25 us against the final candidate,
with the same exact output. This fixes the direct alternating chain; arrays or
structs that hide nested containers can still cause repeated layout walks.

Candidate binary SHA-256:
`72a7f9cc663228057e7dc099cb65b55c8af5edb340fa3176ded000d94e2664b8`.

## Nested aggregate layout traversal and source captures

2026-10-13, same host, Zig 0.16.0, ReleaseSafe build options and version string.
Baseline is the optional/error-union version above, SHA-256
`72a7f9cc663228057e7dc099cb65b55c8af5edb340fa3176ded000d94e2664b8`.

Struct and union fields resolved size and alignment through separate recursive
walks. Arrays and direct nested containers hid the repeated work from the prior
wrapper-only refinement. A shared runtime layout result now obtains byte size,
alignment and bit size together for source and generated structs/unions,
arrays, optionals and error unions. Array bit size preserves the existing ABI
stride and final-element bit-width rule. A missing bit-size result does not
discard known size or alignment.

Repeated child layouts are memoized only within the synchronous traversal.
Keys include semantic type and current depth; only completed successful results
are retained, and the map is released when its owner returns. Types with
display bindings, mutable/reference captures, effectful layout expressions or
uncertain capture dependencies bypass reuse. An unsafe child traversal also
prevents its enclosing result from being cached. Packed source backing layout
now observes the shared recursion bound.

Native sampling of a source struct chain also found recursive Type hashing
through bindings that the container never referenced. Source structs now use
the existing conservative capture filter, retaining direct field, declaration
and method dependencies and falling back for indirect calls. Ordinary source
container resolution applies the same filter to semantic and presentation
bindings. Empty binding environments take a fast path. An initial broad scan
caused a six-to-nine-percent hotspot regression; the empty-environment fast
path restored the targeted request timings.

Seventeen compiler-computed examples in
`tests/fixtures/comptime_aggregate_layout.zig` cover source/generated struct and
union chains, arrays around wrappers, mixed nesting, repeated child fields,
explicit alignment, sentinels, packed payloads, unused and real captures,
changing payload types and field-type comptime effects. Source field type
blocks run in a child interpreter with the container bindings and suspend
layout memoization. Two requests check depth-sensitive reuse and recursive
packed source. All seventeen values, those two boundaries, the preceding
fifty-seven wrapper values and eleven wrapper boundaries match the final
candidate (87/87 actual requests).

Debug passed the directly affected aggregate/wrapper/union, source field,
storage snapshot, method and identity tests plus source-test root (11/11).
Final ReleaseSafe passed those tests, wrapper boundaries, reflected-field
provenance and existing struct layout tests (15/15). Subsequent eligibility
refinements ran only the two affected aggregate tests and source-test root;
Debug and ReleaseSafe both passed 3/3. Binary compilation, formatting and diff
whitespace checks passed. No full suite was run.

Targeted chain requests use three warmups and ten measured samples. The source
struct baseline and duplicate-child baseline exceeded the request client's
60-second limit. Other chain outputs match between baseline and candidate.

| Completion case | Baseline (us) | Candidate (us) |
| --- | ---: | ---: |
| source_union_chain | 17459.63 | 492.98 |
| source_struct_chain | timeout over 60 s | 457.00 |
| generated_union_chain | 3280.21 | 1064.67 |
| generated_struct_chain | 2631.69 | 957.50 |
| array_union_chain | 10630.31 | 1191.54 |
| array_struct_chain | 1001.42 | 1003.90 |
| mixed_chain | 275587.46 | 1409.04 |
| duplicated_child_bindings | timeout over 60 s | 354.33 |

The duplicate-child case also isolates traversal reuse after capture filtering:
the intermediate candidate without reuse took 29543.17 us. These numbers are
for the specific fixtures, not a project-wide speedup claim. Shared source
dependencies that need conservative capture fallback can still incur repeated
type hashing.

Existing zigraft comptime method and generated-capability completion/definition
requests use two comparisons with binary order reversed, five warmups and
forty combined measured samples per binary/request. All four response hashes
match. These comparisons and all 87 exact requests use the same final candidate.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1616.25 | 1634.40 |
| definition | comptime_method | 1607.85 | 1613.92 |
| completion | generated_capability | 638.71 | 643.54 |
| definition | generated_capability | 634.69 | 639.10 |

These targeted hotspot medians differ by 0.38 to 1.12 percent. They remain near
the baseline and do not establish a broad performance regression or gain.
Candidate binary SHA-256:
`1af7b2773ae713db44f3205c5b010bb8eb2f6b6ba293e042d15c1e4cad54b7ac`.

## Auto struct field order, layout and offsets

2026-10-13, same host, Zig 0.16.0, ReleaseSafe build options and version string.
Baseline is the nested aggregate version above, SHA-256
`1af7b2773ae713db44f3205c5b010bb8eb2f6b6ba293e042d15c1e4cad54b7ac`.

Auto structs with fields of different sizes or alignments returned unknown
layout values, and multiple auto-layout fields had unknown offsets. Source and
generated structs now group fields by effective alignment, process groups in
descending order and preserve source order within each group. Groups track
their byte extent and the requested field's prefix without allocating a sort
buffer. Zero-size fields participate in the group order and affect alignment;
their offsets are not universally zero. Size, alignment, bit size and auto
field offsets use the same accumulator.

The common layout result retains comptime-only and uninstantiable properties.
Comptime-only structs keep known alignment, bit size and implicit-field
offsets while public size stays unknown. Uninstantiable structs have zero bits
and queryable field offsets but no public size or alignment. Explicit comptime
fields have no offset. Wrapper payloads reuse this common struct result, which
removes their duplicate struct layout implementation while preserving bounded
traversal memoization.

Thirty-four compiler-computed examples in
`tests/fixtures/comptime_auto_struct_layout.zig` cover heterogeneous source and
generated fields, equal-alignment order, explicit alignment increases and
reductions, void and zero-array fields, nested containers and wrappers, packed
payloads, generic types, comptime fields and uninstantiable containers. All
thirty-four exact completion checks fail against the baseline and match Zig
against the final candidate. Forty independently compiled field permutations
also verify the alignment-group size and offset formula.

Five additional final binary requests cover unknown field types, invalid
alignment, recursive containers, missing/explicit-comptime fields and partial
comptime-only metrics. The preceding seventeen aggregate values, fifty-seven
wrapper values and eleven wrapper boundaries also pass against this candidate:
124/124 actual completion requests in total.

Debug passed the new value test and directly related struct layout, field
offset, union, wrapper and aggregate tests plus source-test root (10/10).
The final new value/boundary tests also passed in Debug (3/3). ReleaseSafe passed
both new tests and the related tests above plus wrapper boundaries and
source-test root (12/12). Compilation, formatting and diff whitespace checks
passed. No full suite was run.

Existing zigraft comptime method and generated-capability completion/definition
requests use two comparisons with binary order reversed, five warmups and
forty combined measured samples per binary/request. All four response hashes
match. These comparisons and all 124 exact requests use the same candidate.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1677.40 | 1669.08 |
| definition | comptime_method | 1620.83 | 1617.60 |
| completion | generated_capability | 643.56 | 644.79 |
| definition | generated_capability | 636.88 | 638.40 |

The targeted hotspot medians differ by -0.50 to +0.24 percent. These samples
remain near the baseline. ABI and field ordering results are verified against
Zig 0.16.0 on the target that compiled ZLS; cross-target project settings retain
the existing limitation.
Candidate binary SHA-256:
`4359ac04e0c4b89734b587b35a332c3ad60a948dd89f3fb7b2ac74315c91c53c`.

## Tuple layouts and comptime field defaults

2026-10-13, same host, Zig 0.16.0, ReleaseSafe build options and version string.
Baseline is the auto struct layout version above, SHA-256
`4359ac04e0c4b89734b587b35a332c3ad60a948dd89f3fb7b2ac74315c91c53c`.

Size and alignment queries on InternPool tuple types entered the ordinary
Struct branch and accessed an inactive union payload, crashing ZLS. Tuple
representations now have explicit layout dispatch. Source and generated tuples
use declaration order rather than auto-struct field reordering. Runtime fields
add alignment padding, zero-size fields keep offset zero and contribute
alignment, and comptime fields occupy no runtime storage and have no offset.
Tuple payloads work in arrays, structs, unions, optionals and error unions.

Non-interned tuple metadata now retains optional comptime defaults beside its
field types. Semantic equality and hashing include default presence and value;
generic substitution, completion, reflection and element lookup preserve the
metadata. Pure nominal struct literals can become comptime tuple fields, and
reflected default pointers retain the original value. Typed undefined fields
keep their default presence without supplying a readable value. Source tuple
reflection uses numeric field names and recognizes explicit comptime fields.

TypeOf keeps ordinary calls unevaluated. A nominal literal containing a runtime
call or runtime field remains a runtime tuple field, while its neighboring
known fields retain their defaults. Peer resolution for non-interned tuples
merges field types and keeps only defaults that are equal on both sides; a
different nominal field value becomes a runtime field.

Thirty-eight compiler-computed examples in
`tests/fixtures/comptime_tuple_layout.zig` cover source/generated and nominal
payloads, empty tuples, runtime/comptime/undefined fields, numeric offsets,
ArgsTuple, wrappers, reflected defaults, identity, peer types, runtime TypeOf
calls and one-time operand effects. The initial twenty-six baseline requests
all fail: nineteen crash and seven return unknown. All thirty-eight values and
five invalid/partial layout requests pass against the final candidate. The
preceding thirty-four auto-struct and seventeen aggregate values also match:
94/94 actual completion requests in total.

Debug passed the new values and related tuple values, reflection, mutation,
pointer identity, initializer and TypeOf tests plus source-test root (9/9).
Later TypeOf/peer refinements reran only the two affected tuple tests, anonymous
and aggregate TypeOf tests plus source-test root (5/5). Final ReleaseSafe passed
the two new tests, the related tuple/TypeOf tests and quota-effect regression
plus source-test root (11/11). Binary compilation, formatting and diff
whitespace checks passed. No full suite was run.

Existing zigraft comptime method and generated-capability completion/definition
requests use two comparisons with binary order reversed, five warmups and
forty combined measured samples per binary/request. All four response hashes
match. These comparisons and all 94 exact requests use the same final candidate.

| Request | Case | Baseline (us) | Candidate (us) |
| --- | --- | ---: | ---: |
| completion | comptime_method | 1675.52 | 1686.85 |
| definition | comptime_method | 1669.96 | 1678.56 |
| completion | generated_capability | 661.67 | 663.56 |
| definition | generated_capability | 661.60 | 655.50 |

The targeted hotspot medians differ by -0.92 to +0.68 percent and remain near
the baseline. ABI results use the target that compiled ZLS and the existing
bounded layout traversal.
Candidate binary SHA-256:
`38228f4833a34cfcc5c8903c7d3547ef0984e1c0af7a44b8f99b58db5f610f6a`.
