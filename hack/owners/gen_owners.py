#!/usr/bin/env python3
"""Render OWNERS files and the ownership table from hyperfleet/docs/owners.yaml.

Usage:
  gen_owners.py render [--out DIR]   write OWNERS_ALIASES and OWNERS per repository
                                     (default hack/owners/out) and refresh the table
                                     in hyperfleet/docs/owners.md
  gen_owners.py check                fail if the table in owners.md is stale or the
                                     YAML is inconsistent
  gen_owners.py table                print the area table

Rules applied at render time are documented at the top of owners.yaml.
"""
import argparse
import os
import sys

import yaml

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SOURCE = os.path.join(ROOT, "hyperfleet", "docs", "owners.yaml")
DOC = os.path.join(ROOT, "hyperfleet", "docs", "owners.md")
DEFAULT_OUT = os.path.join(ROOT, "hack", "owners", "out")
TABLE_START = "<!-- owners-table:start -->"
TABLE_END = "<!-- owners-table:end -->"

# Fallback approver sets that are never auto-requested as reviewers.
FALLBACK_ALIASES = {"tech-leads", "architecture-approvers"}


def load():
    with open(SOURCE) as f:
        return yaml.safe_load(f)


def dedupe(items):
    seen, out = set(), []
    for x in items:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out


def expand(data, names):
    aliases = data["aliases"]
    out = []
    for n in names:
        out.extend(aliases[n] if n in aliases else [n])
    return dedupe(out)


def reviewers_for(spec):
    """Reviewers plus the path's approvers, minus the fallback aliases."""
    approvers = [a for a in spec.get("approvers", []) if a not in FALLBACK_ALIASES]
    return dedupe(list(spec.get("reviewers", [])) + approvers)


def owners_doc(spec):
    doc = {}
    if spec.get("approvers"):
        doc["approvers"] = list(spec["approvers"])
    reviewers = reviewers_for(spec)
    if reviewers:
        doc["reviewers"] = reviewers
    if spec.get("labels"):
        doc["labels"] = list(spec["labels"])
    return doc


def used_aliases(data, spec_map):
    used = set()
    for spec in spec_map.values():
        for n in list(spec.get("approvers", [])) + reviewers_for(spec):
            if n in data["aliases"]:
                used.add(n)
    return sorted(used)


def dump(obj):
    return yaml.safe_dump(obj, sort_keys=False, default_flow_style=False)


def validate(data):
    errors = []
    people = set(data["people"])
    for alias, members in data["aliases"].items():
        for m in members:
            if m not in people:
                errors.append(f"alias {alias}: unknown login {m}")
    for repo, spec_map in data["repos"].items():
        for path, spec in spec_map.items():
            for key in ("approvers", "reviewers"):
                for n in spec.get(key, []):
                    if n not in data["aliases"] and n not in people:
                        errors.append(f"{repo}/{path or '(root)'} {key}: unknown name {n}")
            for label in spec.get("labels", []):
                if label not in data["labels"]:
                    errors.append(f"{repo}/{path or '(root)'}: label {label} not in labels")
            if path == "" and not spec.get("approvers"):
                errors.append(f"{repo}: root OWNERS has no approvers")
    for area in data["areas"]:
        for key in ("approvers", "reviewers"):
            for n in area.get(key, []):
                if n not in data["aliases"] and n not in people:
                    errors.append(f"area {area['name']} {key}: unknown name {n}")
        if area["label"] not in data["labels"]:
            errors.append(f"area {area['name']}: label {area['label']} not in labels")
    return errors


def names(data, logins):
    return ", ".join(f"{data['people'][l]} ({l})" for l in logins)


def table(data):
    rows = ["| Area | Paths | Approvers | Reviewers |", "|---|---|---|---|"]
    for area in data["areas"]:
        if area.get("inherits"):
            approvers = f"inherits {area['inherits']}"
        else:
            approvers = names(data, expand(data, area["approvers"]))
        reviewers = names(data, expand(data, area["reviewers"]))
        rows.append(f"| {area['name']} | {area['paths']} | {approvers} | {reviewers} |")
    return "\n".join(rows)


def splice_table(text, new_table):
    start = text.find(TABLE_START)
    end = text.find(TABLE_END)
    if start < 0 or end < 0 or end < start:
        raise SystemExit(f"{DOC}: table markers missing")
    start += len(TABLE_START)
    return text[:start] + "\n" + new_table + "\n" + text[end:]


def render(data, out_dir):
    count = 0
    for repo, spec_map in data["repos"].items():
        base = os.path.join(out_dir, repo)
        os.makedirs(base, exist_ok=True)
        aliases = used_aliases(data, spec_map)
        if aliases:
            with open(os.path.join(base, "OWNERS_ALIASES"), "w") as f:
                f.write(dump({"aliases": {a: list(data["aliases"][a]) for a in aliases}}))
        for path, spec in spec_map.items():
            d = os.path.join(base, path) if path else base
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, "OWNERS"), "w") as f:
                f.write(dump(owners_doc(spec)))
            count += 1
    with open(DOC) as f:
        text = f.read()
    new_text = splice_table(text, table(data))
    if new_text != text:
        with open(DOC, "w") as f:
            f.write(new_text)
    return count


def check(data):
    errors = validate(data)
    with open(DOC) as f:
        text = f.read()
    if splice_table(text, table(data)) != text:
        errors.append(f"{os.path.relpath(DOC, ROOT)}: area table is stale, run gen_owners.py render")
    for e in errors:
        print(f"error: {e}", file=sys.stderr)
    return not errors


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("render")
    r.add_argument("--out", default=DEFAULT_OUT)
    sub.add_parser("check")
    sub.add_parser("table")
    args = parser.parse_args()

    data = load()
    if args.cmd == "table":
        print(table(data))
        return
    if args.cmd == "check":
        sys.exit(0 if check(data) else 1)
    errors = validate(data)
    if errors:
        for e in errors:
            print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
    n = render(data, args.out)
    print(f"wrote {n} OWNERS files across {len(data['repos'])} repositories to {os.path.relpath(args.out, ROOT)}")


if __name__ == "__main__":
    main()
