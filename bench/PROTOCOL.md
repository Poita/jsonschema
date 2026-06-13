# Bench protocol

A single contract lets the in-process D microbench (Tier 1) and every
cross-language adapter (Tier 2) be compared apples-to-apples. The rule that
makes the numbers fair: **all timing happens inside the native process** — the
orchestrator never times across a process boundary, so IPC cost is excluded by
construction. Each adapter is handed a workload, does its own warmup + timed
loop, and prints one JSON result object per phase to stdout.

## Workload manifest

`bench/workloads/manifest.json` is the single source of truth for what runs.

```jsonc
{
  "defaults": { "warmup": 2000, "iterations": 20000, "samples": 15 },
  "workloads": [
    {
      "name": "small-doc",            // unique id, used as the result key
      "schema": "small-doc/schema.json",        // path relative to workloads/
      "valid":   ["small-doc/valid/record.json"],   // must validate true
      "invalid": ["small-doc/invalid/record.json"], // must validate false
      "iterations": 20000,            // optional per-workload override
      "samples": 15,                  // optional override
      "formatAssertion": true,        // run `format` as assertions, not annotations
      "crossLanguage": true           // include in Tier 2 comparison
    }
  ]
}
```

`crossLanguage: false` keeps a workload in Tier 1 only — used for `format-heavy`,
because each library configures format assertion differently and a cross-library
race there measures config choices, not engine speed.

## Measurement method (every adapter implements this)

1. Parse the schema and **all** instances into the library's native value type
   *before* timing — the loop measures validation, never JSON parsing.
2. **compile phase:** `samples` repetitions; each times building a reusable
   validator from the schema. Report min and median ns.
3. **validate phase, valid and invalid separately:** for each, run `warmup`
   untimed validations, then `samples` repetitions of an inner loop of
   `iterations` validations; per-call ns = batch_ns / iterations. Report min and
   median ns across samples. Accumulate the boolean result into a sink so the
   call can't be optimized away.
4. Before timing, assert every valid instance validates true and every invalid
   one false; emit `correctnessOk` accordingly. A failing adapter is still
   timed but flagged, never silently compared.

Report **min** (cleanest signal for "did my change speed the hot path") and
**median** (robust to scheduler/GC noise). Throughput `mbPerSec` is derived from
the valid-instance byte size and its median ns.

## Result object (one per workload, printed as a JSON line to stdout)

```jsonc
{
  "implementation": "jsonschema-d-std",   // adapter id (lib + adapter)
  "libraryVersion": "0.x",
  "workload": "small-doc",
  "compileNsMin": 41230, "compileNsMedian": 43900,
  "validateValidNsMin": 210,  "validateValidNsMedian": 224,
  "validateInvalidNsMin": 95, "validateInvalidNsMedian": 101,
  "bytes": 142,
  "mbPerSec": 604.0,
  "correctnessOk": true
}
```

The orchestrator (`bench/orchestrate.py`) collects these lines from each
adapter, groups by workload, and renders the comparison table. Adding a library
to Tier 2 means writing one adapter that reads the manifest and prints this
shape — nothing else changes.
