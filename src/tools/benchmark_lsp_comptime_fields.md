# Comptime struct field benchmark

`benchmark_lsp_comptime_fields.py` measures actual `textDocument/completion`
requests on a comptime type function using a struct with many named fields.
Every response must contain the expected generated array length before its
latency is accepted. It shares the JSON-RPC measurement helper with the comptime
array benchmark.

```sh
zig build -Doptimize=ReleaseSafe
python3 src/tools/benchmark_lsp_comptime_fields.py zig-out/bin/zls --field-count 512 --access write
python3 src/tools/benchmark_lsp_comptime_fields.py /path/to/baseline/zls --field-count 512 --access write
```

`--access read` sums all fields, `write` increments all fields with `+=` via
dot syntax, and `builtin` does the same with `@field`. `assign` and
`builtin-assign` rewrite each field as `x = x + 1` (dot or `@field`) to
exercise full read-modify-write paths. The generated function initializes
every field and repeats its accesses four times by default (`--iterations`,
1 through 8). `--field-count` accepts 1 through 4096. The function requests an
evaluation quota of one million to keep the largest cases evaluable; the
production default quota is unchanged.

Each invocation starts a fresh process, performs five warmup requests, and
measures twenty further requests. `--warmup` and `--rounds` configure these
counts. Output includes latency samples in microseconds and child-process peak
resident memory in bytes. Run baseline and candidate builds alternately after
all compilation and tests have finished.

The benchmark measures initialization as well as accesses. It therefore covers
both looking up values by field name and matching initializer fields to their
source nodes during coercion. Small and wide structs should both be measured
when changing the indexing threshold.

Values with at least 16 materialized fields build a name-to-position index.
The index is shared by storage clones because writes change field values while
preserving field names and order. It is rebuilt when the field layout changes,
and is excluded from equality and hashing. Small values keep linear lookup.

Initializer coercion pairs fields with their source positions when their names
match. Reordered wide values construct a source-name index on demand. Field
names are decoded consistently for initialization, dot access, and `@field`,
including quoted identifiers containing escape sequences.

## Recorded comparison

2026-10-09, Apple M1 Pro, macOS, Zig 0.16.0, ReleaseSafe. Baseline `e7b17f64`.
Each size/access pair used baseline/candidate/candidate/baseline order after
compilation and tests finished, with four access iterations per request, five
warmup requests, and twenty measured requests per process. Each latency is the
mean of the two process medians.

| Fields | Access | Baseline (us) | Indexed fields (us) | Speedup |
| --- | --- | ---: | ---: | ---: |
| 8 | read | 143.73 | 140.75 | 1.02x |
| 8 | write | 152.47 | 156.22 | 0.98x |
| 8 | builtin | 159.31 | 160.54 | 0.99x |
| 16 | read | 213.45 | 213.61 | 1.00x |
| 16 | write | 248.47 | 243.35 | 1.02x |
| 16 | builtin | 264.95 | 261.08 | 1.01x |
| 128 | read | 1557.62 | 1316.08 | 1.18x |
| 128 | write | 1991.83 | 1541.73 | 1.29x |
| 128 | builtin | 2139.57 | 1677.84 | 1.28x |
| 512 | read | 9296.46 | 5033.88 | 1.85x |
| 512 | write | 14383.06 | 5960.48 | 2.41x |
| 512 | builtin | 14902.98 | 6533.53 | 2.28x |
| 2048 | read | 90468.66 | 20261.65 | 4.47x |
| 2048 | write | 153017.95 | 23991.79 | 6.38x |
| 2048 | builtin | 152252.16 | 26116.67 | 5.83x |

The geometric mean speedup for the three 2048-field cases is 5.50x. The 8- and
16-field cases differ by at most 2.5% in either direction; those small differences
are near run-to-run variation. Process peak resident memory remains about
29.6 MiB for these workloads.

The same ABBA procedure checked the existing 2048-element array benchmark:

| Initializer | Baseline (us) | Candidate (us) | Change |
| --- | ---: | ---: | ---: |
| literal | 3065.84 | 3111.51 | +1.5% |
| loop | 6899.42 | 6853.56 | -0.7% |

These results cover structs of `usize` fields. Generated type construction,
large nested field values, and other comptime patterns require separate
measurements. Source pairing and value lookup are improved together, so these
numbers should not be attributed to the hash lookup alone.

Validation: 1210 tests, analysis/build-runner checks, and 46 independent JSON-RPC
storage/field probes pass. The new shared compiler/LSP fixture covers twelve
cases including field reordering, default/partial values, crossing the indexing
threshold, pointer snapshots, generated struct fields, escaped names, and
array-expression pointers. The source test entry also runs the comptime quota
test and a field equality/hash test with different field orders and index
metadata. Fifteen boundary probes cover 1, 15, 16, 17, and 4096 fields with eight
iterations in each access mode; the five existing array initializer modes also
pass through the shared measurement helper.

## Dynamic `@field` read-modify-write

2026-10-10, Apple M1 Pro, macOS, Zig 0.16.0, ReleaseSafe. Baseline `efea2e7b`.
The `builtin-assign` workload uses explicit
`@field(state, name) = @field(state, name) + 1` expressions. Each size used
baseline/candidate/candidate/baseline order with the standard five warmups and
twenty measured requests per process. Latencies are the mean of the two process
medians.

| Fields | Baseline (us) | Borrow field base (us) | Speedup |
| --- | ---: | ---: | ---: |
| 8 | 222.45 | 187.88 | 1.18x |
| 512 | 57691.56 | 8425.07 | 6.85x |
| 2048 | 797482.51 | 35333.14 | 22.57x |

Previously, evaluating the base of every `@field` read published the whole
local struct value. The next field write therefore cloned all fields even
though only the selected scalar had escaped. Local bases are now borrowed until
the field name has been evaluated; only the selected field path is frozen when
its value escapes. At 2048 fields, peak process RSS dropped from about
2068.0 MiB to 29.6 MiB. A read-only `@field` control differed by 1.0%, within
run-to-run variation.

The compiler/LSP fixture includes explicit wide `@field` assignments in
addition to dynamic names, pointer bases, temporary bases, nested fields,
aggregate snapshots, and name expressions with side effects. This protects the
evaluation-order and copy-on-write boundary that enables the speedup.
