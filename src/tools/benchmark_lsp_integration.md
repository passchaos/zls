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
