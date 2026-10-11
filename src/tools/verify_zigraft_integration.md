# zigraft integration LSP audit

This checks the real `tests/integration.zig` in a zigraft checkout, including its
`@import("zigraft")` build-runner mapping. The source file is never changed on disk.

```sh
zig build -Doptimize=ReleaseSafe
python3 src/tools/verify_zigraft_integration.py \
  zig-out/bin/zls /path/to/zigraft \
  --snippets --output /tmp/zls-zigraft-integration.json
```

The script checks definitions of named identifiers, including parameters, local
variables, imported functions, generic types, associated types, generated fields,
and comptime-selected method literals. It also checks both import strings and
the `ReaderError` / `RunError` member names passed to `@hasDecl`. Every returned
definition must match its exact path, line, column, and selected text in
[`verify_zigraft_integration.targets.tsv`](verify_zigraft_integration.targets.tsv).
The manifest binds these expectations to the reference source hash; changes to
the fixture require reviewing and updating the expectations. Paths under the
Zig standard library are normalized so the manifest does not depend on the
installation directory.

For every member, builtin, import string, member name string, and ordinary identifier reference, it requests
completion in three states: the original complete name, the name deleted, and
only the first letter typed. It applies the completion's replacement edit and
requires the entire document to equal the original source, catching extra
parentheses, duplicated assignments, and edits that consume a following access.
Declaration sites do not require identifier completion.

The report explicitly excludes source definitions for compiler builtins other
than `@This`, and for builtin `.len` properties. The four anonymous capability
field declarations in `Requirements` arguments also have no prior definition or
predefined set of names to complete. Their subsequent uses in generated
capability structs are checked. Primitive types and language keywords are not
identifier references in this scanner.

`--lines 17,132,193,277` restricts requests to selected one-based lines.
`--modes empty prefix` restricts the completion states. `--snippets` advertises
editor snippet support and checks that existing calls/assignments are preserved. The report includes a
source hash and all exclusions; any incorrect definition target, missing candidate, or
incorrect edit causes a nonzero exit. This scanner intentionally targets the
current ASCII integration fixture, rather than attempting to parse arbitrary
Zig syntax in Python.

## Verified reference run

On Zig 0.16.0, the reference source with SHA-256
`0d81088681b49ee95e89bf3d89397159c96732e2849482572e443b8e72375b86` passed:

- 698 scanned identifiers, builtins, and semantic strings.
- 661 definition requests with exact source destination assertions.
- 542 completion positions in three states each: 1,626 edits, all restoring
  the original source with editor snippets enabled.
- 1,259 ZLS tests, including the analysis and build-runner gates.
- All 17 compiler-executed tests in zigraft's integration file.

Generated capability fields navigate to the caller's named capability arguments.
Generated binding fields and method-selection literals navigate to the original
contract method fields. Type-definition requests retain the concrete field type.
The targeted Zig tests also cover direct `std.meta.fieldNames` input to `@Struct`,
names forwarded through comptime helper functions, and ordinary strings that
must not be treated as member accesses.
