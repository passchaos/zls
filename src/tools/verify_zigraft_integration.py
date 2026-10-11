#!/usr/bin/env python3
"""Check completion edits and definition targets throughout zigraft's integration.zig."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlparse

sys.dont_write_bytecode = True
from benchmark_lsp_references import Client

# Zig keywords and primitive values/types have no source definition to visit.
KEYWORDS = set("""addrspace align allowzero and anyframe anytype asm async await
break callconv catch comptime const continue defer else enum errdefer error export
extern fn for if inline linksection noalias noinline nosuspend opaque or orelse
packed pub resume return section struct suspend switch test threadlocal try union
unreachable usingnamespace var volatile while true false null undefined type void
bool noreturn anyerror anyopaque usize isize comptime_int comptime_float c_char
c_short c_ushort c_int c_uint c_long c_ulong c_longlong c_ulonglong c_longdouble _""".split())
MASK = re.compile(r'//[^\n]*|"(?:\\.|[^"\\])*"')
IDENTIFIER = re.compile(r'[A-Za-z_]\w*')
TARGETS = Path(__file__).with_suffix(".targets.tsv")


def target_path(path, root):
    path = Path(path)
    if path.is_relative_to(root):
        return path.relative_to(root).as_posix()
    parts = path.parts
    for index in range(len(parts) - 2):
        if parts[index:index + 2] == ("lib", "std"):
            return "/".join(("std", *parts[index + 2:]))
    raise AssertionError(f"definition outside zigraft and Zig standard library: {path}")


def expected_targets(source):
    lines = TARGETS.read_text().splitlines()
    expected_hash = lines[0].removeprefix("# source_sha256=")
    if hashlib.sha256(source.encode()).hexdigest() != expected_hash:
        raise AssertionError("integration.zig changed; review and update the definition target manifest")
    expected = {}
    for row in lines[2:]:
        name, queries, path, line, column, text = row.split("\t")
        for query in queries.split(","):
            key = (*map(int, query.split(":")), name)
            if key in expected:
                raise AssertionError(f"duplicate definition expectation: {key}")
            expected[key] = [dict(path=path, line=int(line), column=int(column), text=text)]
    return expected


def positions(source):
    offset = 0
    for row, line in enumerate(source.splitlines(keepends=True)):
        masked = MASK.sub(lambda match: " " * len(match[0]), line)
        for match in IDENTIFIER.finditer(masked):
            name = match[0]
            if name in KEYWORDS or re.fullmatch(r'[uif]\d+', name):
                continue
            member = match.start() > 0 and line[match.start() - 1] == "."
            builtin = match.start() > 0 and line[match.start() - 1] == "@"
            # These are the four field declarations of the untyped capability
            # arguments in this fixture. Their names are chosen by the caller.
            declaration = member and re.fullmatch(
                r'\s*\.(reader|seekable) = (Reader|BroadReader|Seekable),\s*', line
            ) is not None
            yield dict(line=row, character=match.start(), start=offset + match.start(),
                       end=offset + match.end(), name=name, member=member,
                       declaration=declaration, builtin=builtin)
        imported = re.search(r'@import\("(std|zigraft)"\)', line)
        if imported:
            yield dict(line=row, character=imported.start(1), start=offset + imported.start(1),
                       end=offset + imported.end(1), name=imported[1], member=False,
                       declaration=False, builtin=False, import_path=True)
        member_name = re.search(r'@hasDecl\([^,]+, "([A-Za-z_]\w*)"\)', line)
        if member_name:
            yield dict(line=row, character=member_name.start(1), start=offset + member_name.start(1),
                       end=offset + member_name.end(1), name=member_name[1], member=True,
                       declaration=False, builtin=False, member_name_string=True)
        offset += len(line)


def at(source, position):
    lines = source.splitlines(keepends=True)
    line = lines[position["line"]]
    units = position["character"] * 2
    prefix = line.encode("utf-16-le")[:units].decode("utf-16-le")
    return sum(map(len, lines[:position["line"]])) + len(prefix)


def targets(result):
    if not result:
        return []
    if isinstance(result, dict):
        result = [result]
    locations = []
    for link in result:
        path = Path(unquote(urlparse(link.get("targetUri", link.get("uri"))).path))
        target_range = link.get("targetSelectionRange", link.get("range"))
        source = path.read_text()
        start, end = at(source, target_range["start"]), at(source, target_range["end"])
        if not 0 <= start <= end <= len(source):
            raise AssertionError(f"invalid definition range: {link}")
        locations.append(dict(path=str(path), line=target_range["start"]["line"] + 1,
                              column=target_range["start"]["character"] + 1,
                              text=source[start:end]))
    return locations


def check_completion(client, uri, source, token, mode, version):
    if mode == "original":
        edited, column = source, token["character"] + len(token["name"])
    else:
        prefix = token["name"][:1] if mode == "prefix" else ""
        edited = source[:token["start"]] + prefix + source[token["end"]:]
        column = token["character"] + len(prefix)
    client.notify("textDocument/didChange", dict(
        textDocument=dict(uri=uri, version=version), contentChanges=[dict(text=edited)]))
    result = client.request("textDocument/completion", dict(
        textDocument=dict(uri=uri), position=dict(line=token["line"], character=column)))
    items = result.get("items", []) if isinstance(result, dict) else result or []
    matching = [item for item in items
                if token["name"] in (item["label"], item.get("filterText"))]
    if not matching:
        return dict(mode=mode, error="missing completion", labels=[i["label"] for i in items])
    edit = matching[0].get("textEdit")
    if not edit:
        return dict(mode=mode, error="missing completion edit")
    location = edit.get("replace", edit.get("range"))
    start, end = at(edited, location["start"]), at(edited, location["end"])
    completed = edited[:start] + edit["newText"] + edited[end:]
    if completed != source:
        return dict(mode=mode, error="completion changed surrounding source", edit=edit,
                    actual_line=completed.splitlines()[token["line"]])
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("project", type=Path, help="zigraft checkout with tests/integration.zig")
    parser.add_argument("--output", type=Path, required=True, help="JSON report including definition targets")
    parser.add_argument("--modes", nargs="+", choices=("original", "empty", "prefix"),
                        default=["original", "empty", "prefix"])
    parser.add_argument("--lines", help="Optional comma-separated one-based source lines")
    parser.add_argument("--snippets", action="store_true", help="Advertise editor snippet support")
    args = parser.parse_args()
    root = args.project.resolve()
    document = root / "tests/integration.zig"
    source = document.read_text()
    expected = expected_targets(source)
    # All identifiers in this reference file are ASCII; LSP still negotiates
    # UTF-16 explicitly, and edit/target ranges are decoded in that encoding.
    if not source.isascii():
        parser.error("this fixture scanner currently requires ASCII integration source")
    uri = document.as_uri()
    tokens = list(positions(source))
    required = {(token["line"] + 1, token["character"] + 1, token["name"])
                for token in tokens if not token["declaration"]
                and not (token["builtin"] and token["name"] != "This")
                and not (token["member"] and token["name"] == "len")}
    if required != set(expected):
        raise AssertionError(f"definition manifest coverage mismatch: missing={required - set(expected)}, "
                             f"extra={set(expected) - required}")
    if args.lines:
        lines = set(map(int, args.lines.split(",")))
        tokens = [t for t in tokens if t["line"] + 1 in lines]
    report = dict(document=str(document), sha256=hashlib.sha256(source.encode()).hexdigest(),
                  binary=str(args.binary.resolve()),
                  binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                  modes=args.modes, snippets=args.snippets, checks=[], exclusions=[])
    failures = []
    with tempfile.TemporaryDirectory(prefix="zls-integration-") as temporary:
        config = Path(temporary) / "zls.json"
        config.write_text(json.dumps(dict(enable_build_on_save=False)))
        with (Path(temporary) / "stderr.log").open("w+") as stderr:
            process = subprocess.Popen([str(args.binary.resolve()), "--config-path", str(config)],
                                       cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr)
            client = Client(process)
            try:
                client.request("initialize", dict(
                    processId=os.getpid(), rootUri=root.as_uri(),
                    workspaceFolders=[dict(uri=root.as_uri(), name=root.name)],
                    capabilities=dict(general=dict(positionEncodings=["utf-16"]),
                                      textDocument=dict(definition=dict(linkSupport=True),
                                                        completion=dict(completionItem=dict(
                                                            snippetSupport=args.snippets, insertReplaceSupport=True))))))
                client.notify("initialized", {})
                client.notify("textDocument/didOpen", dict(textDocument=dict(
                    uri=uri, languageId="zig", version=1, text=source)))
                version = 1
                for index, token in enumerate(tokens):
                    entry = dict(line=token["line"] + 1, column=token["character"] + 1,
                                 name=token["name"], completions=[])
                    if token["declaration"]:
                        report["exclusions"].append(dict(**entry, reason="caller-defined anonymous field"))
                        continue
                    if token["builtin"] and token["name"] != "This":
                        report["exclusions"].append(dict(**entry, reason="compiler builtin has no source definition"))
                    elif token["member"] and token["name"] == "len":
                        report["exclusions"].append(dict(**entry, reason="builtin length has no source definition"))
                    else:
                        response = client.request("textDocument/definition", dict(
                            textDocument=dict(uri=uri), position=dict(line=token["line"], character=token["character"])))
                        entry["targets"] = targets(response)
                        if not entry["targets"]:
                            failures.append(dict(**entry, error="missing definition"))
                        else:
                            key = (entry["line"], entry["column"], entry["name"])
                            wanted = expected.get(key)
                            actual = [dict(target, path=target_path(target["path"], root))
                                      for target in entry["targets"]]
                            entry["exact_target_passed"] = actual == wanted
                            if actual != wanted:
                                failures.append(dict(**entry, error="incorrect definition target", expected=wanted))
                    complete = token["member"] or token["builtin"] or token.get("import_path", False)
                    if not complete:
                        declarations = client.request("textDocument/declaration", dict(
                            textDocument=dict(uri=uri), position=dict(line=token["line"], character=token["character"]))) or []
                        if isinstance(declarations, dict):
                            declarations = [declarations]
                        complete = not any(
                            d.get("targetUri", d.get("uri")) == uri and
                            d.get("targetSelectionRange", d.get("range"))["start"] ==
                            dict(line=token["line"], character=token["character"])
                            for d in declarations)
                    if complete:
                        for mode in args.modes:
                            version += 1
                            failure = check_completion(client, uri, source, token, mode, version)
                            entry["completions"].append(dict(mode=mode, passed=failure is None))
                            if failure:
                                failures.append(dict(line=entry["line"], column=entry["column"],
                                                     name=entry["name"], **failure))
                        version += 1
                        client.notify("textDocument/didChange", dict(textDocument=dict(uri=uri, version=version),
                                                                    contentChanges=[dict(text=source)]))
                    report["checks"].append(entry)
                    if index % 50 == 0:
                        print(f"Checked {index + 1}/{len(tokens)} identifiers", file=sys.stderr, flush=True)
                client.request("shutdown", None)
                client.notify("exit", None)
                process.wait(timeout=10)
                if process.returncode != 0:
                    raise RuntimeError(f"ZLS exited with {process.returncode}")
            except BaseException:
                stderr.seek(0)
                print(stderr.read(), file=sys.stderr)
                raise
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                process.stdin.close()
                process.stdout.close()
                report["failures"] = failures
                args.output.write_text(json.dumps(report, indent=2) + "\n")
    summary = dict(identifiers=len(tokens), definitions=sum("targets" in c for c in report["checks"]),
                   exact_targets=sum(c.get("exact_target_passed", False) for c in report["checks"]),
                   completions=sum(len(c["completions"]) for c in report["checks"]), failures=len(failures))
    print(json.dumps(summary, indent=2))
    for failure in failures:
        print(json.dumps(failure), file=sys.stderr)
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
