//! jsonschema (Rust) adapter for the cross-language bench protocol.
//! Reads bench/workloads/manifest.json, runs every crossLanguage workload, and
//! prints one protocol JSON line per workload to stdout. Timing is in-process
//! (see bench/PROTOCOL.md).
//!
//! Setup:  (none — cargo fetches deps)
//! Run:    cargo run --release -- [path/to/manifest.json]

use serde_json::{json, Value};
use std::fs;
use std::hint::black_box;
use std::path::{Path, PathBuf};
use std::time::Instant;

/// Pinned in Cargo.toml; reported in the result so runs are attributable.
const JSONSCHEMA_VERSION: &str = "0.20";

fn read_json(path: &Path) -> Value {
    serde_json::from_str(&fs::read_to_string(path).expect("read")).expect("parse")
}

fn pick(over: Option<u64>, def: u64) -> u64 {
    over.unwrap_or(def)
}

/// Run `op` `iters` times per sample over `samples` samples; return per-op
/// (min, median) nanoseconds.
fn measure<F: FnMut()>(samples: u64, iters: u64, mut op: F) -> (f64, f64) {
    let mut times: Vec<f64> = Vec::with_capacity(samples as usize);
    for _ in 0..samples {
        let t0 = Instant::now();
        for _ in 0..iters {
            op();
        }
        let ns = t0.elapsed().as_nanos() as f64 / iters as f64;
        times.push(ns);
    }
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    (times[0], times[samples as usize / 2])
}

fn main() {
    let manifest_path = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("../../workloads/manifest.json"));
    let root = manifest_path.parent().unwrap().to_path_buf();
    let manifest: Value = read_json(&manifest_path);
    let defaults = &manifest["defaults"];
    let def = |k: &str| defaults[k].as_u64().unwrap();

    for w in manifest["workloads"].as_array().unwrap() {
        if !w["crossLanguage"].as_bool().unwrap_or(false) {
            continue;
        }
        let name = w["name"].as_str().unwrap();
        let samples = pick(w["samples"].as_u64(), def("samples"));
        let iters = pick(w["iterations"].as_u64(), def("iterations"));
        let warmup = pick(w["warmup"].as_u64(), def("warmup"));

        let schema = read_json(&root.join(w["schema"].as_str().unwrap()));
        let load = |arr: &Value| -> Vec<Value> {
            arr.as_array()
                .unwrap()
                .iter()
                .map(|p| read_json(&root.join(p.as_str().unwrap())))
                .collect()
        };
        let valid = load(&w["valid"]);
        let invalid = load(&w["invalid"]);
        let valid_bytes = fs::metadata(root.join(w["valid"][0].as_str().unwrap()))
            .unwrap()
            .len();

        // compile phase: build a reusable validator from the parsed schema.
        let (compile_min, compile_median) = measure(samples, 1, || {
            let v = jsonschema::validator_for(&schema).expect("compile");
            black_box(&v);
        });

        let validator = jsonschema::validator_for(&schema).expect("compile");
        let correct = valid.iter().all(|x| validator.is_valid(x))
            && invalid.iter().all(|x| !validator.is_valid(x));

        let time_validate = |instance: &Value| -> (f64, f64) {
            for _ in 0..warmup {
                black_box(validator.is_valid(instance));
            }
            measure(samples, iters, || {
                black_box(validator.is_valid(instance));
            })
        };
        let (v_min, v_med) = time_validate(&valid[0]);
        let (iv_min, iv_med) = time_validate(&invalid[0]);

        let mb_per_sec = if v_med > 0.0 {
            valid_bytes as f64 * 1000.0 / v_med
        } else {
            0.0
        };

        let out = json!({
            "implementation": "jsonschema-rs",
            "libraryVersion": JSONSCHEMA_VERSION,
            "workload": name,
            "compileNsMin": compile_min,
            "compileNsMedian": compile_median,
            "validateValidNsMin": v_min,
            "validateValidNsMedian": v_med,
            "validateInvalidNsMin": iv_min,
            "validateInvalidNsMedian": iv_med,
            "bytes": valid_bytes,
            "mbPerSec": mb_per_sec,
            "correctnessOk": correct,
        });
        println!("{}", out);
    }
}
