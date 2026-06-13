# jsonschema performance harness

Two tiers that share one workload set and one result protocol
([PROTOCOL.md](PROTOCOL.md)):

- **Tier 1 — `bench-runner`**: an in-process D microbench over both adapters
  (std.json, vibe.data.json). Your inner loop for optimization work: fast,
  noise-resistant, with a committed baseline and a regression gate.
- **Tier 2 — `orchestrate.py`**: runs the D adapter alongside competitor
  validators in other languages and prints a normalized comparison, so you can
  see where this library stands.

Both measure the same thing the same way: the **compile** phase (schema → reusable
validator) and the **validate** phase are timed separately; valid and invalid
instances are timed separately; every adapter asserts correctness before timing
and is flagged, never silently compared, if it disagrees with the workload's
expected verdicts. All timing happens **inside** each native process — the
orchestrator never times across a process boundary, so IPC cost is excluded.

## Workloads

Defined in [`workloads/manifest.json`](workloads/manifest.json):

| workload | shape | stresses |
|---|---|---|
| `small-doc` | small object, basic keywords | per-call + dispatch overhead |
| `schema-heavy` | `$defs` + `$ref`, `allOf`/`anyOf`/`oneOf`, patterns | the compiler & combinators |
| `large-instance` | ~475 KB array of 5 000 records | traversal throughput (MB/s) |
| `format-heavy` | `format` assertions (Tier 1 only) | format checkers |

`large-instance` is generated deterministically by
`workloads/large-instance/gen.py` and committed so every language validates
identical bytes. `format-heavy` is `crossLanguage:false` because each library
configures format assertion differently — comparing there would measure config,
not engine speed.

## Tier 1 — optimization loop

```sh
ulimit -n 65536
# one-time: fetch the official suite submodule is NOT needed; workloads are local

# run the microbench (release build is what the numbers assume)
dub run :bench-runner -b release --compiler=ldc2 -- --adapter both

# capture a baseline before you start optimizing
dub run :bench-runner -b release --compiler=ldc2 -- --save-baseline bench/baseline.json

# after a change, fail if validate-valid median regressed > 5%
dub run :bench-runner -b release --compiler=ldc2 -- --baseline bench/baseline.json --check
```

Useful flags: `--only <workload>`, `--adapter std|vibe|both`,
`--iterations`, `--samples`, `--warmup`, `--json` (protocol output).

Reads **min** (cleanest signal that the hot path got faster) and **median**
(robust to GC/scheduler noise). Throughput is derived from the valid instance's
byte size and its median validate time.

### Finding *why* something is slow

```sh
dub build :bench-runner -b release --compiler=ldc2
valgrind --tool=callgrind ./bench-runner --only schema-heavy --samples 1 --iterations 2000
# or sample with perf / Instruments and focus on the validate hot path
```

## Tier 2 — cross-language comparison

```sh
# one-time competitor setup (only what you have toolchains for):
cd bench/competitors/js  && npm install        && cd -
cd bench/competitors/go  && go mod tidy         && cd -
# rust needs no setup beyond cargo

# run everything available; missing toolchains are skipped with a hint
python3 bench/orchestrate.py --out bench/xlang-results.json
```

Competitors (each an adapter speaking the protocol):

| adapter | library | language |
|---|---|---|
| `jsonschema-d-std` / `-vibe` | this library | D |
| `ajv` | [Ajv](https://ajv.js.org) (draft 2020-12) | JavaScript |
| `santhosh-tekuri` | [santhosh-tekuri/jsonschema v6](https://github.com/santhosh-tekuri/jsonschema) | Go |
| `jsonschema-rs` | [jsonschema](https://crates.io/crates/jsonschema) | Rust |

The table normalizes every row against `jsonschema-d-std` (`vs d-std` column:
>1.0 means faster than this library). Adding a library is one new adapter that
reads the manifest and prints the protocol shape — see PROTOCOL.md.

### Fairness notes

- Numbers are comparable **within one run on one machine** only. Compile
  semantics differ across libraries (Ajv code-gen's and `eval`s JS, so it
  compiles slowly but validates very fast; tree-walking validators compile fast
  and validate slower) — read compile and validate as separate stories.
- Pin the machine: single core (`taskset`/`cpuset`), disable turbo where you
  can, and close background load. The harness already separates warmup from
  measurement and reports min + median to blunt remaining noise.
- Run each draft against the same dialect; all workloads here are 2020-12.
