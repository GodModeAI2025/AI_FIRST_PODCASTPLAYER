#!/usr/bin/env python3
"""Validate the specification packet offline; does not build or run the app."""
from __future__ import annotations
import argparse
import json
import sys
from pathlib import Path
sys.dont_write_bytecode = True
from packet_checks import validate_packet

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--report", type=Path, help="Optional JSON output path; modifying a packaged file invalidates its inventory hash.")
    parser.add_argument("--skip-manifest", action="store_true", help="For authoring only, skip file-integrity verification.")
    args = parser.parse_args()
    try:
        report = validate_packet(args.root, verify_manifest=not args.skip_manifest)
    except Exception as exc:
        report = {"status":"failed", "scope":"specification_packet_only", "error":str(exc)}
    text = json.dumps(report, indent=2, ensure_ascii=False)
    print(text)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(text+"\n", encoding="utf-8")
    return 0 if report["status"] == "passed" else 1

if __name__ == "__main__":
    raise SystemExit(main())
