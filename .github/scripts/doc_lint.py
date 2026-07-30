#!/usr/bin/env python3
"""Audit a repository's documentation against a doc-standard manifest.

Python 3.9+, standard library only, no network — so it runs unchanged on
GitHub-hosted, self-hosted, and air-gapped runners. `git` is used for the
freshness check only, and that check is skipped when git is unavailable.

Usage:
    python3 doc_lint.py [--root .] [--manifest doc-standard.json]
                        [--format text|github] [--json] [--strict]
                        [--baseline .doclint-baseline.json]
                        [--write-baseline .doclint-baseline.json]

Waivers, for the rare finding that is wrong rather than unfixed:
    <!-- doclint:ignore DOC003 -->            same line, or the line above
    <!-- doclint:ignore-file DOC007, DOC003 --> anywhere in the file

Exit codes: 0 clean, 1 findings that fail the build, 2 bad invocation.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from datetime import date
from pathlib import Path
from typing import Optional

HEADING = re.compile(r"^(#{1,6})\s+(.+?)\s*$")
FENCE = re.compile(r"^\s*(```|~~~)\s*(\S*)")
LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)")
ENV_KEY = re.compile(r"^\s*#?\s*([A-Z][A-Z0-9_]{1,63})\s*=")
ADD_ARG = re.compile(r"""add_argument\(\s*(["'])(--[^"']+)\1""")
TABLE_FLAG = re.compile(r"^\s*\|\s*`?(--[a-zA-Z0-9][a-zA-Z0-9-]*)`?")
# Rule IDs first, then any free-text reason: "<!-- doclint:ignore DOC014 -- why -->".
IGNORE_LINE = re.compile(r"<!--\s*doclint:ignore\s+((?:DOC\d{3}[,\s]*)+)")
IGNORE_FILE = re.compile(r"<!--\s*doclint:ignore-file\s+((?:DOC\d{3}[,\s]*)+)")
STAMP = re.compile(r"Last validated:\s*(\d{4})-(\d{2})")

RULES = {
    "DOC001": "required document missing",
    "DOC002": "required section missing",
    "DOC003": "placeholder text left in a tracked document",
    "DOC004": "relative link points at a file that does not exist",
    "DOC005": "required document class is empty",
    "DOC006": "README exceeds the length cap",
    "DOC007": "code fence has no language",
    "DOC008": "configuration key is not documented",
    "DOC009": "entry-point script is not documented",
    "DOC010": "command-line flag drifted from its documentation",
    "DOC011": "link anchor does not match any heading in the target",
    "DOC012": "validation stamp missing or stale",
    "DOC013": "document is older than the code it documents",
    "DOC014": "procedural section contains no command block",
}


@dataclass
class Finding:
    rule: str
    severity: str
    path: str
    line: int
    message: str
    waived: bool = field(default=False)
    baselined: bool = field(default=False)

    def fingerprint(self) -> str:
        # Line numbers shift as docs are edited; the triple below is stable.
        return f"{self.rule}|{self.path}|{self.message}"


# --------------------------------------------------------------------------- #
# parsing helpers
# --------------------------------------------------------------------------- #

def normalize(text: str) -> str:
    text = text.replace("`", "").strip().rstrip(":.")
    return re.sub(r"\s+", " ", text).lower()


def slugify(text: str) -> str:
    """GitHub's heading-anchor rules: lowercase, drop punctuation, each space
    becomes one hyphen (so a double space yields a double hyphen)."""
    slug = text.strip().lower().replace("`", "").replace("*", "")
    slug = re.sub(r"[^a-z0-9 _\-]", "", slug)
    return re.sub(r"\s", "-", slug).strip("-")


def parse_markdown(path: Path) -> dict:
    """One pass: headings, links and fences outside fences, plus raw lines."""
    headings: list[tuple[int, str, int]] = []  # (level, text, line)
    links: list[tuple[int, str]] = []
    fences: list[tuple[int, str]] = []
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    in_fence = False
    for number, raw in enumerate(lines, start=1):
        fence = FENCE.match(raw)
        if fence:
            if not in_fence:
                fences.append((number, fence.group(2)))
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        head = HEADING.match(raw)
        if head:
            headings.append((len(head.group(1)), head.group(2), number))
        for target in LINK.findall(raw):
            links.append((number, target))
    slugs: dict[str, int] = {}
    anchors: set[str] = set()
    for _, text, _ in headings:
        base = slugify(text)
        count = slugs.get(base, 0)
        anchors.add(base if count == 0 else f"{base}-{count}")
        slugs[base] = count + 1
    return {"headings": headings, "links": links, "fences": fences,
            "lines": lines, "anchors": anchors}


def section_range(doc: dict, index: int) -> tuple[int, int]:
    """Line span of the heading at `index`, up to the next same-or-higher one."""
    level, _, start = doc["headings"][index]
    for other_level, _, other_start in doc["headings"][index + 1:]:
        if other_level <= level:
            return start, other_start - 1
        continue
    return start, len(doc["lines"])


def section_text(doc: dict, index: int) -> str:
    start, end = section_range(doc, index)
    return "\n".join(doc["lines"][start - 1:end])


def check_sections(doc: dict, required, path: str, severity: str) -> list[Finding]:
    present = [normalize(t) for lvl, t, _ in doc["headings"] if lvl == 2]
    out = []
    for want in required:
        needle = normalize(want)
        if not any(needle in h for h in present):
            out.append(Finding("DOC002", severity, path, 1,
                               f"missing required section '## {want}'"))
    return out


def iter_docs(root: Path, scan: dict) -> list[Path]:
    excluded = set(scan.get("exclude_dirs", []))
    found: list[Path] = []
    for pattern in scan.get("doc_globs", []):
        for match in root.glob(pattern):
            if match.is_file() and not (excluded & set(match.relative_to(root).parts)):
                found.append(match)
    return sorted(set(found))


def rel(root: Path, path: Path) -> str:
    try:
        return str(path.relative_to(root))
    except ValueError:
        return str(path)


def is_entrypoint(path: Path) -> bool:
    """A script someone runs, not an importable library. A shebang alone is not
    enough for Python — shared helper modules routinely carry one."""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")[:262144]
    except OSError:
        return False
    has_main = "__main__" in text or "argparse" in text
    if path.suffix == ".py":
        return has_main
    return text.startswith("#!") or has_main


def find_entrypoints(root: Path, spec: dict, scan: dict) -> list[Path]:
    excluded = set(scan.get("exclude_dirs", [])) | set(spec.get("exclude_dirs", []))
    names = set(spec.get("exclude", []))
    out: list[Path] = []
    for pattern in spec.get("entrypoint_globs", []):
        for match in root.glob(pattern):
            if not match.is_file() or match.name in names:
                continue
            if excluded & set(match.relative_to(root).parts):
                continue
            if is_entrypoint(match):
                out.append(match)
    return sorted(set(out))


def git_timestamp(root: Path, path: str) -> Optional[int]:
    try:
        done = subprocess.run(["git", "-C", str(root), "log", "-1", "--format=%ct",
                               "--", path], capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return None
    value = done.stdout.strip()
    return int(value) if done.returncode == 0 and value.isdigit() else None


# --------------------------------------------------------------------------- #
# checks
# --------------------------------------------------------------------------- #

def check_required_files(root: Path, manifest: dict) -> list[Finding]:
    out = []
    for entry in manifest.get("required_files", []):
        severity = entry.get("severity", "error")
        target = root / entry["path"]
        if not target.is_file():
            out.append(Finding("DOC001", severity, entry["path"], 1,
                               "required document is missing"))
            continue
        out += check_sections(parse_markdown(target), entry.get("sections", []),
                              entry["path"], severity)
    return out


def check_required_globs(root: Path, manifest: dict) -> list[Finding]:
    out = []
    for entry in manifest.get("required_globs", []):
        severity = entry.get("severity", "error")
        matches = sorted(p for p in root.glob(entry["glob"]) if p.is_file())
        if len(matches) < entry.get("min_count", 1):
            out.append(Finding("DOC005", severity, entry["glob"], 1,
                               f"no {entry['label']} found matching {entry['glob']}"))
            continue
        for match in matches:
            out += check_sections(parse_markdown(match), entry.get("sections", []),
                                  rel(root, match), severity)
    return out


def check_documents(root: Path, manifest: dict, docs: list[Path],
                    parsed: dict) -> list[Finding]:
    out: list[Finding] = []
    ph = manifest.get("placeholders", {})
    patterns = ph.get("patterns", [])
    ph_sev = ph.get("severity", "error")
    link_sev = manifest.get("links", {}).get("severity", "error")
    anchor_sev = manifest.get("links", {}).get("anchor_severity", link_sev)
    fence_sev = manifest.get("code_fence_language", {}).get("severity", "warn")
    cap = manifest.get("readme_max_lines")
    cap_sev = manifest.get("readme_max_lines_severity", "warn")
    cmd = manifest.get("require_command_block", {})
    cmd_sections = [normalize(s) for s in cmd.get("sections", [])]
    cmd_sev = cmd.get("severity", "warn")

    for path in docs:
        name = rel(root, path)
        doc = parsed[name]

        for number, raw in enumerate(doc["lines"], start=1):
            lowered = raw.lower()
            for pattern in patterns:
                token = pattern.lower()
                hit = (re.search(rf"\b{re.escape(token)}\b", lowered)
                       if token.isalpha() else token in lowered)
                if hit:
                    out.append(Finding("DOC003", ph_sev, name, number,
                                       f"placeholder '{pattern}' — fill it in from the "
                                       f"code or delete the section and open an issue"))
                    break

        for number, target in doc["links"]:
            if re.match(r"^(https?:|mailto:|tel:)", target):
                continue
            filepart, _, fragment = target.partition("#")
            if filepart:
                resolved = (path.parent / filepart).resolve()
                if not resolved.exists():
                    out.append(Finding("DOC004", link_sev, name, number,
                                       f"link target '{filepart}' does not exist"))
                    continue
            else:
                resolved = path
            if not fragment or resolved.suffix != ".md" or not resolved.is_file():
                continue
            target_name = rel(root, resolved)
            target_doc = parsed.get(target_name) or parse_markdown(resolved)
            parsed.setdefault(target_name, target_doc)
            if fragment.lower() not in target_doc["anchors"]:
                out.append(Finding("DOC011", anchor_sev, name, number,
                                   f"anchor '#{fragment}' matches no heading in "
                                   f"{target_name}"))

        for number, language in doc["fences"]:
            if not language:
                out.append(Finding("DOC007", fence_sev, name, number,
                                   "code fence has no language (bash, tcl, python, "
                                   "yaml, json, text)"))

        if cap and name == "README.md" and len(doc["lines"]) > cap:
            out.append(Finding("DOC006", cap_sev, name, 1,
                               f"README is {len(doc['lines'])} lines (cap {cap}); "
                               f"relocate depth into docs/ and link to it — do not "
                               f"delete it"))

        for index, (_, title, line) in enumerate(doc["headings"]):
            if normalize(title) not in cmd_sections:
                continue
            start, end = section_range(doc, index)
            if not any(start <= fl <= end for fl, _ in doc["fences"]):
                out.append(Finding("DOC014", cmd_sev, name, line,
                                   f"section '{title}' has no command block — a "
                                   f"procedure a reader cannot run is a description"))
    return out


def check_config_drift(root: Path, manifest: dict) -> list[Finding]:
    spec = manifest.get("drift", {}).get("configuration")
    if not spec:
        return []
    doc_path = root / spec["doc"]
    if not doc_path.is_file():
        return []
    documented = doc_path.read_text(encoding="utf-8", errors="replace")
    out, seen = [], set()
    for pattern in spec.get("env_globs", []):
        for env_file in sorted(root.glob(pattern)):
            if not env_file.is_file():
                continue
            for number, raw in enumerate(env_file.read_text(
                    encoding="utf-8", errors="replace").splitlines(), start=1):
                match = ENV_KEY.match(raw)
                if not match or match.group(1) in seen:
                    continue
                key = match.group(1)
                seen.add(key)
                # Word-boundary: documenting LDAP_START_TLS_RENAMED must not
                # satisfy LDAP_START_TLS, which a substring check would allow.
                if not re.search(rf"\b{re.escape(key)}\b", documented):
                    out.append(Finding("DOC008", spec.get("severity", "error"),
                                       rel(root, env_file), number,
                                       f"'{key}' is not documented in {spec['doc']} "
                                       f"(type, default, required, effect)"))
    return out


def check_cli_drift(root: Path, manifest: dict, scan: dict) -> list[Finding]:
    spec = manifest.get("drift", {}).get("cli")
    if not spec:
        return []
    doc_path = root / spec["doc"]
    if not doc_path.is_file():
        return []
    documented = doc_path.read_text(encoding="utf-8", errors="replace")
    out = []
    for script in find_entrypoints(root, spec, scan):
        if script.name not in documented:
            out.append(Finding("DOC009", spec.get("severity", "error"),
                               rel(root, script), 1,
                               f"entry point '{script.name}' is not documented in "
                               f"{spec['doc']} (purpose, synopsis, flags, example, "
                               f"exit codes)"))
    return out


def check_flag_drift(root: Path, manifest: dict, scan: dict) -> list[Finding]:
    """Both directions: flags the code defines but the docs omit, and flags the
    docs list in a flag table that the code no longer defines."""
    spec = manifest.get("drift", {}).get("flags")
    if not spec:
        return []
    doc_path = root / spec["doc"]
    if not doc_path.is_file():
        return []
    severity = spec.get("severity", "error")
    doc = parse_markdown(doc_path)
    doc_name = rel(root, doc_path)
    cli_spec = dict(manifest.get("drift", {}).get("cli", {}))
    cli_spec.setdefault("entrypoint_globs", spec.get("entrypoint_globs", []))
    out = []

    for script in find_entrypoints(root, cli_spec, scan):
        if script.suffix != ".py":
            continue  # shell flag parsing is unreliable; documented as a gap
        source = script.read_text(encoding="utf-8", errors="replace")
        defined = {m.group(2) for m in ADD_ARG.finditer(source)}
        if not defined:
            continue
        index = next((i for i, (_, title, _) in enumerate(doc["headings"])
                      if script.name in title), None)
        if index is None:
            continue  # DOC009 already reports the missing section
        body = section_text(doc, index)
        line = doc["headings"][index][2]
        for flag in sorted(defined):
            if not re.search(rf"(?<![\w-]){re.escape(flag)}(?![\w-])", body):
                out.append(Finding("DOC010", severity, doc_name, line,
                                   f"{script.name} defines '{flag}' but its section "
                                   f"does not mention it"))
        start, end = section_range(doc, index)
        for number in range(start, min(end, len(doc["lines"])) + 1):
            row = TABLE_FLAG.match(doc["lines"][number - 1])
            if row and row.group(1) not in defined:
                out.append(Finding("DOC010", severity, doc_name, number,
                                   f"flag table lists '{row.group(1)}' but "
                                   f"{script.name} no longer defines it"))
    return out


def check_validation_stamps(root: Path, manifest: dict) -> list[Finding]:
    spec = manifest.get("validation_stamp")
    if not spec:
        return []
    severity = spec.get("severity", "warn")
    max_age = spec.get("max_age_months", 12)
    targets: list[Path] = [root / p for p in spec.get("required_in", [])]
    for pattern in spec.get("required_globs", []):
        targets += [p for p in root.glob(pattern) if p.is_file()]
    today = date.today()
    out = []
    for path in sorted(set(targets)):
        if not path.is_file():
            continue  # DOC001 covers absence
        name = rel(root, path)
        text = path.read_text(encoding="utf-8", errors="replace")
        match = STAMP.search(text)
        if not match:
            out.append(Finding("DOC012", severity, name, 1,
                               "no 'Last validated: YYYY-MM' line — an undated "
                               "procedure decays invisibly"))
            continue
        year, month = int(match.group(1)), int(match.group(2))
        age = (today.year - year) * 12 + (today.month - month)
        if age > max_age:
            out.append(Finding("DOC012", severity, name, 1,
                               f"validated {year:04d}-{month:02d}, {age} months ago "
                               f"(limit {max_age}) — recheck or restate it"))
    return out


def check_freshness(root: Path, manifest: dict) -> list[Finding]:
    """A doc whose subject changed after the doc did is the actual rot mechanism."""
    spec = manifest.get("freshness")
    if not spec or not spec.get("pairs"):
        return []
    if git_timestamp(root, ".") is None and not (root / ".git").exists():
        return []
    severity = spec.get("severity", "warn")
    out = []
    for pair in spec["pairs"]:
        doc_rel = pair["doc"]
        if not (root / doc_rel).is_file():
            continue
        doc_ts = git_timestamp(root, doc_rel)
        if doc_ts is None:
            continue  # untracked or brand new: nothing to compare against
        for pattern in pair.get("code", []):
            for code in sorted(root.glob(pattern)):
                if not code.is_file():
                    continue
                code_rel = rel(root, code)
                code_ts = git_timestamp(root, code_rel)
                if code_ts is None or code_ts <= doc_ts:
                    continue
                days = (code_ts - doc_ts) // 86400
                out.append(Finding("DOC013", severity, doc_rel, 1,
                                   f"'{code_rel}' was last changed {days} day(s) after "
                                   f"this document — confirm the document still matches"))
    return out


# --------------------------------------------------------------------------- #
# waivers, baseline, reporting
# --------------------------------------------------------------------------- #

def collect_waivers(root: Path, docs: list[Path], parsed: dict) -> dict:
    per_file: dict[str, set[str]] = {}
    per_line: dict[tuple[str, int], set[str]] = {}
    for path in docs:
        name = rel(root, path)
        for number, raw in enumerate(parsed[name]["lines"], start=1):
            whole = IGNORE_FILE.search(raw)
            if whole:
                per_file.setdefault(name, set()).update(
                    r.strip() for r in whole.group(1).replace(",", " ").split())
                continue
            one = IGNORE_LINE.search(raw)
            if one:
                rules = {r.strip() for r in one.group(1).replace(",", " ").split()}
                per_line.setdefault((name, number), set()).update(rules)
    return {"file": per_file, "line": per_line}


def apply_waivers(findings: list[Finding], waivers: dict) -> None:
    for f in findings:
        if f.rule in waivers["file"].get(f.path, set()):
            f.waived = True
            continue
        for line in (f.line, f.line - 1):
            if f.rule in waivers["line"].get((f.path, line), set()):
                f.waived = True
                break


def apply_baseline(findings: list[Finding], path: Path) -> int:
    known = set(json.loads(path.read_text(encoding="utf-8")).get("fingerprints", []))
    for f in findings:
        if f.fingerprint() in known:
            f.baselined = True
    return len(known)


def failing(findings: list[Finding], strict: bool) -> list[Finding]:
    live = [f for f in findings if not f.waived and not f.baselined]
    if strict:
        return live
    return [f for f in live if f.severity == "error"]


def report_text(findings: list[Finding], strict: bool) -> None:
    live = [f for f in findings if not f.waived and not f.baselined]
    if not live:
        print("docs lint: clean")
    for severity in ("error", "warn"):
        group = [f for f in live if f.severity == severity]
        if not group:
            continue
        print(f"\n{'ERROR' if severity == 'error' else 'WARN '} ({len(group)})")
        for f in sorted(group, key=lambda x: (x.path, x.line, x.rule)):
            print(f"  {f.path}:{f.line}  {f.rule}  {f.message}")
    errors = sum(1 for f in live if f.severity == "error")
    suppressed = sum(1 for f in findings if f.baselined)
    waived = sum(1 for f in findings if f.waived)
    tail = []
    if suppressed:
        tail.append(f"{suppressed} pre-existing (baseline)")
    if waived:
        tail.append(f"{waived} waived")
    print(f"\n{errors} error(s), {len(live) - errors} warning(s)"
          f"{' — strict: warnings fail' if strict else ''}"
          f"{'; ' + ', '.join(tail) if tail else ''}")
    if live:
        print("Rule reference: references/audit-rules.md")


def report_github(findings: list[Finding]) -> None:
    for f in findings:
        if f.waived or f.baselined:
            continue
        level = "error" if f.severity == "error" else "warning"
        print(f"::{level} file={f.path},line={f.line},title={f.rule}::{f.message}")


# --------------------------------------------------------------------------- #

def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Audit docs against a doc-standard manifest")
    parser.add_argument("--root", default=".")
    parser.add_argument("--manifest", default=None,
                        help="default: <root>/doc-standard.json")
    parser.add_argument("--format", choices=("text", "github"), default="text")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--strict", action="store_true", help="warnings also fail")
    parser.add_argument("--baseline", default=None,
                        help="suppress findings recorded in this file")
    parser.add_argument("--write-baseline", default=None,
                        help="record current findings and exit 0")
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    manifest_path = Path(args.manifest) if args.manifest else root / "doc-standard.json"
    if not manifest_path.is_file():
        print(f"doc_lint: manifest not found: {manifest_path}", file=sys.stderr)
        return 2
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"doc_lint: manifest is not valid JSON: {exc}", file=sys.stderr)
        return 2

    scan = manifest.get("scan", {})
    docs = iter_docs(root, scan)
    parsed = {rel(root, p): parse_markdown(p) for p in docs}

    findings: list[Finding] = []
    findings += check_required_files(root, manifest)
    findings += check_required_globs(root, manifest)
    findings += check_documents(root, manifest, docs, parsed)
    findings += check_config_drift(root, manifest)
    findings += check_cli_drift(root, manifest, scan)
    findings += check_flag_drift(root, manifest, scan)
    findings += check_validation_stamps(root, manifest)
    findings += check_freshness(root, manifest)

    apply_waivers(findings, collect_waivers(root, docs, parsed))

    if args.write_baseline:
        payload = {
            "standard_version": manifest.get("standard_version"),
            "created": date.today().isoformat(),
            "note": "Pre-existing findings, suppressed by --baseline. Shrink this file; "
                    "never add to it.",
            "fingerprints": sorted({f.fingerprint() for f in findings if not f.waived}),
        }
        Path(args.write_baseline).write_text(json.dumps(payload, indent=2) + "\n",
                                            encoding="utf-8")
        print(f"doc_lint: wrote {len(payload['fingerprints'])} fingerprint(s) to "
              f"{args.write_baseline}")
        return 0

    if args.baseline:
        baseline_path = Path(args.baseline)
        if not baseline_path.is_file():
            print(f"doc_lint: baseline not found: {baseline_path}", file=sys.stderr)
            return 2
        apply_baseline(findings, baseline_path)

    if args.json:
        print(json.dumps({
            "standard_version": manifest.get("standard_version"),
            "documents_scanned": len(docs),
            "findings": [asdict(f) for f in findings],
            "rules": RULES,
        }, indent=2))
    elif args.format == "github":
        report_github(findings)
    else:
        report_text(findings, args.strict)

    return 1 if failing(findings, args.strict) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
