#!/usr/bin/env python3
"""Prefix relative SARIF artifact URIs with the scanned sub-directory.

vettalon writes URIs relative to the directory it scanned. GitHub code
scanning resolves relative URIs against the repository root, so when the
action scans a sub-directory (path: services/api) the URIs must become
services/api/<file> for alerts to land on the right lines.

Usage: rebase-sarif.py <sarif-file> <scanned-path> <repo-root>
Exits 0 without changes when the scanned path is the repo root or lies
outside it.
"""

import json
import os
import sys
from urllib.parse import quote, urlparse


def is_relative(uri: str) -> bool:
    return bool(uri) and not urlparse(uri).scheme and not uri.startswith("/")


def rebase_uri_holder(holder, prefix: str) -> int:
    uri = holder.get("uri")
    if isinstance(uri, str) and is_relative(uri):
        holder["uri"] = f"{prefix}/{uri}"
        return 1
    return 0


def walk(node, prefix: str) -> int:
    """Rewrite every artifactLocation found anywhere under node.

    This covers results[].locations, relatedLocations, codeFlows, stacks and
    fixes, which all reference files through an artifactLocation object.
    """
    changed = 0
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "artifactLocation" and isinstance(value, dict):
                changed += rebase_uri_holder(value, prefix)
            else:
                changed += walk(value, prefix)
    elif isinstance(node, list):
        for item in node:
            changed += walk(item, prefix)
    return changed


def rebase(doc: dict, prefix: str) -> int:
    changed = 0
    for run in doc.get("runs") or []:
        changed += walk(run.get("results") or [], prefix)
        # run.artifacts[] uses "location" (an artifactLocation) as its key.
        for artifact in run.get("artifacts") or []:
            loc = artifact.get("location") if isinstance(artifact, dict) else None
            if isinstance(loc, dict):
                changed += rebase_uri_holder(loc, prefix)
            changed += walk(artifact, prefix)
    return changed


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    sarif_file, scanned, root = sys.argv[1:]
    rel = os.path.relpath(os.path.realpath(scanned), os.path.realpath(root))
    if rel == ".":
        return 0
    if rel == ".." or rel.startswith(".." + os.sep):
        print(
            f"::warning::scanned path {scanned} is outside {root}; "
            "SARIF paths were left relative to the scanned directory",
            file=sys.stderr,
        )
        return 0
    prefix = quote(rel.replace(os.sep, "/"))
    with open(sarif_file, encoding="utf-8") as fh:
        doc = json.load(fh)
    changed = rebase(doc, prefix)
    tmp = f"{sarif_file}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=2)
    os.replace(tmp, sarif_file)
    print(f"[vettalon-action] prefixed {changed} SARIF URIs with '{prefix}/'", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
