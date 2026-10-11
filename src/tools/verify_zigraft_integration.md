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
and comptime-selected method literals. It records the path, line, and selected
source text of every returned definition for reviewing the actual destinations.
A nonempty response alone does not prove that the destination is semantically
correct; the targeted Zig definition tests assert exact locations as well.

For every member, builtin, and ordinary identifier reference, it requests
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
source hash and all exclusions; any missing definition, missing candidate, or
incorrect edit causes a nonzero exit. This scanner intentionally targets the
current ASCII integration fixture, rather than attempting to parse arbitrary
Zig syntax in Python.

## Verified reference run

On Zig 0.16.0, the reference source with SHA-256
`0d81088681b49ee95e89bf3d89397159c96732e2849482572e443b8e72375b86` passed:

- 694 scanned identifiers and builtins.
- 657 definition requests with inspected source destinations.
- 538 completion positions in three states each: 1,614 edits, all restoring
  the original source with editor snippets enabled.
- 1,254 ZLS tests, including the analysis and build-runner gates.
- All 17 compiler-executed tests in zigraft's integration file.

Generated capability fields currently navigate to their concrete implementation
type, and generated binding fields to their callable type. Method-selection
literals navigate to the original contract method fields.
