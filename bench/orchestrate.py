#!/usr/bin/env python3
"""Cross-language jsonschema benchmark orchestrator (Tier 2).

Runs the in-repo D adapter plus every competitor adapter whose toolchain is
installed, each timing in-process and emitting protocol JSON lines (see
PROTOCOL.md). Collects the lines, groups by workload, and prints a comparison
table normalized against this library's std.json adapter.

Adapters whose toolchain is missing are skipped with a hint, never silently
dropped. Run from anywhere:

    python3 bench/orchestrate.py [--out results.json] [--only WORKLOAD]
"""
import argparse
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
MANIFEST = os.path.join(HERE, "workloads", "manifest.json")
DC = os.environ.get("BENCH_DC", "ldc2")

# Each adapter: a detector binary, the working dir, the command, and a hint
# shown when the toolchain or its deps are absent. `baseline` marks the row all
# others are normalized against.
ADAPTERS = [
    {
        "name": "jsonschema-d",
        "detect": "dub",
        "cwd": REPO,
        "cmd": ["dub", "run", ":bench-runner", "-b", "release", "-q",
                f"--compiler={DC}", "--", "--json", "--adapter", "both"],
        "hint": "install dub + ldc2 (set BENCH_DC to override the compiler)",
        "baseline": True,
    },
    {
        "name": "ajv",
        "detect": "node",
        "cwd": os.path.join(HERE, "competitors", "js"),
        "cmd": ["node", "bench.js", MANIFEST],
        "hint": "cd bench/competitors/js && npm install",
    },
    {
        "name": "santhosh-tekuri",
        "detect": "go",
        "cwd": os.path.join(HERE, "competitors", "go"),
        "cmd": ["go", "run", ".", MANIFEST],
        "hint": "cd bench/competitors/go && go mod tidy",
    },
    {
        "name": "jsonschema-rs",
        "detect": "cargo",
        "cwd": os.path.join(HERE, "competitors", "rust"),
        "cmd": ["cargo", "run", "--release", "--quiet", "--", MANIFEST],
        "hint": "install Rust (https://rustup.rs)",
    },
]

BASELINE_IMPL = "jsonschema-d-std"


def run_adapter(a):
    """Run one adapter, returning its parsed result objects (or [] on skip)."""
    if shutil.which(a["detect"]) is None:
        print(f"  skip {a['name']:16s} ({a['detect']} not found — {a['hint']})", file=sys.stderr)
        return []
    print(f"  run  {a['name']}", file=sys.stderr)
    try:
        proc = subprocess.run(a["cmd"], cwd=a["cwd"], capture_output=True, text=True, timeout=900)
    except subprocess.TimeoutExpired:
        print(f"  warn {a['name']}: timed out", file=sys.stderr)
        return []
    if proc.returncode != 0:
        tail = "\n".join(proc.stderr.strip().splitlines()[-4:])
        print(f"  warn {a['name']}: exit {proc.returncode}\n{tail}", file=sys.stderr)
        # the program may still have emitted valid lines before failing
    results = []
    for line in proc.stdout.splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                results.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return results


def fmt(x):
    return f"{x:,.1f}"


def print_workload(name, rows):
    rows = sorted(rows, key=lambda r: r["validateValidNsMedian"])
    base = next((r for r in rows if r["implementation"] == BASELINE_IMPL), None)
    base_valid = base["validateValidNsMedian"] if base else None

    print(f"\n### {name}  ({rows[0]['bytes']:,} bytes)")
    header = f"{'implementation':22s} {'compile µs':>12s} {'valid ns':>12s} {'invalid ns':>12s} {'MB/s':>9s} {'vs d-std':>9s}  ok"
    print(header)
    print("-" * len(header))
    for r in rows:
        ratio = ""
        if base_valid:
            ratio = f"{base_valid / r['validateValidNsMedian']:.2f}x"
        ok = "yes" if r.get("correctnessOk") else "FAIL"
        print(f"{r['implementation']:22s} {fmt(r['compileNsMedian']/1000):>12s} "
              f"{fmt(r['validateValidNsMedian']):>12s} {fmt(r['validateInvalidNsMedian']):>12s} "
              f"{r['mbPerSec']:>9.0f} {ratio:>9s}  {ok}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", help="write aggregated results JSON to this path")
    ap.add_argument("--only", help="restrict the report to one workload")
    args = ap.parse_args()

    print("collecting adapters:", file=sys.stderr)
    all_results = []
    for a in ADAPTERS:
        all_results.extend(run_adapter(a))

    if not all_results:
        print("no adapter produced results", file=sys.stderr)
        return 1

    by_workload = {}
    for r in all_results:
        if args.only and r["workload"] != args.only:
            continue
        by_workload.setdefault(r["workload"], []).append(r)

    print("\n=== cross-language validation benchmark ===")
    print("(higher vs-d-std = faster than this library's std.json adapter)")
    for name in by_workload:
        print_workload(name, by_workload[name])

    if args.out:
        with open(args.out, "w") as f:
            json.dump(all_results, f, indent=2)
        print(f"\nwrote {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
