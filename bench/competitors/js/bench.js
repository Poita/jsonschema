// Ajv (draft 2020-12) adapter for the cross-language bench protocol.
// Reads bench/workloads/manifest.json, runs every crossLanguage workload, and
// prints one protocol JSON line per workload to stdout. All timing is in-process
// (see bench/PROTOCOL.md); the orchestrator never times across the boundary.
//
// Setup:  cd bench/competitors/js && npm install
// Run:    node bench.js [path/to/manifest.json]

const fs = require("fs");
const path = require("path");
const Ajv = require("ajv/dist/2020");
const addFormats = require("ajv-formats");

const pkgVersion = require("ajv/package.json").version;

let sink = 0; // defeat dead-code elimination of the validate call

function measure(samples, iters, op) {
  const times = [];
  for (let s = 0; s < samples; s++) {
    const t0 = process.hrtime.bigint();
    for (let i = 0; i < iters; i++) op();
    const dt = process.hrtime.bigint() - t0;
    times.push(Number(dt) / iters);
  }
  times.sort((a, b) => a - b);
  return { min: times[0], median: times[Math.floor(samples / 2)] };
}

function newAjv() {
  const ajv = new Ajv({ strict: false, allErrors: false });
  addFormats(ajv);
  return ajv;
}

function run(manifestPath) {
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  const root = path.dirname(manifestPath);
  const d = manifest.defaults;

  for (const w of manifest.workloads) {
    if (!w.crossLanguage) continue;
    const samples = w.samples ?? d.samples;
    const iters = w.iterations ?? d.iterations;
    const warmup = w.warmup ?? d.warmup;

    const schema = JSON.parse(fs.readFileSync(path.join(root, w.schema), "utf8"));
    const validRaw = fs.readFileSync(path.join(root, w.valid[0]), "utf8");
    const valid = w.valid.map((p) => JSON.parse(fs.readFileSync(path.join(root, p), "utf8")));
    const invalid = w.invalid.map((p) => JSON.parse(fs.readFileSync(path.join(root, p), "utf8")));

    // compile phase: build a reusable validator from the parsed schema.
    const compile = measure(samples, 1, () => {
      const v = newAjv().compile(schema);
      sink += v === undefined ? 1 : 0;
    });

    const validator = newAjv().compile(schema);
    const correctnessOk =
      valid.every((x) => validator(x) === true) &&
      invalid.every((x) => validator(x) === false);

    const timeValidate = (instance) => {
      for (let i = 0; i < warmup; i++) sink += validator(instance) ? 1 : 0;
      return measure(samples, iters, () => {
        sink += validator(instance) ? 1 : 0;
      });
    };
    const v = timeValidate(valid[0]);
    const iv = timeValidate(invalid[0]);

    const bytes = Buffer.byteLength(validRaw, "utf8");
    process.stdout.write(
      JSON.stringify({
        implementation: "ajv",
        libraryVersion: pkgVersion,
        workload: w.name,
        compileNsMin: compile.min,
        compileNsMedian: compile.median,
        validateValidNsMin: v.min,
        validateValidNsMedian: v.median,
        validateInvalidNsMin: iv.min,
        validateInvalidNsMedian: iv.median,
        bytes,
        mbPerSec: v.median > 0 ? (bytes * 1000) / v.median : 0,
        correctnessOk,
      }) + "\n",
    );
  }
  if (sink === -1) console.error(sink); // keep sink observably live
}

const manifestArg = process.argv[2] || path.join(__dirname, "../../workloads/manifest.json");
run(manifestArg);
