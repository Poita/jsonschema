/// jsonschema performance harness.
///
/// Tier 1: an in-process microbench over the workloads in
/// `bench/workloads/manifest.json`, run through both JSON adapters (std.json
/// and vibe.data.json). It splits the compile phase from the validate phase,
/// measures valid and invalid instances separately, and reports min/median
/// ns-per-op plus validation throughput. A committed baseline lets `--check`
/// fail CI on a regression while iterating on optimizations.
///
/// Tier 2: `--json` prints one machine-readable result line per adapter in the
/// shared bench protocol (see bench/PROTOCOL.md), so the cross-language
/// orchestrator can compare this library against others.
module runner;

import jsonschema;
import jsonschema.vibejson : VibeJsonAdapter;

import core.time : MonoTime;

import std.algorithm : map, sort;
import std.array : array;
import std.conv : to;
import std.file : readText;
import std.format : format;
import std.getopt : defaultGetoptPrinter, getopt;
import std.json : JSONValue, parseJSON;
import std.path : buildPath, dirName;
import std.stdio : stderr, stdout, writefln, writeln;

import vibe.data.json : parseJsonString, VibeJson = Json;

enum libraryVersion = "dev";

/// Keeps validation calls from being optimized away.
private ulong sink;

/// One workload as described by the manifest.
struct Workload
{
    string name;
    string schemaPath;
    string[] validPaths;
    string[] invalidPaths;
    size_t warmup;
    size_t iterations;
    size_t samples;
    bool formatAssertion;
    bool crossLanguage;
}

/// min/median nanoseconds per operation across samples.
struct Stat
{
    double nsMin = 0;
    double nsMedian = 0;
}

/// A full result for one (adapter, workload) pair.
struct Result
{
    string implementation;
    string workload;
    Stat compile;
    Stat validValidate;
    Stat invalidValidate;
    size_t bytes;
    bool correctnessOk;

    double mbPerSec() const
    {
        return validValidate.nsMedian > 0 ? bytes * 1000.0 / validValidate.nsMedian : 0;
    }
}

struct Options
{
    string manifest = "bench/workloads/manifest.json";
    string only; // run a single workload by name
    string adapter = "both"; // std | vibe | both
    bool json; // emit protocol JSON instead of a table
    string baseline; // compare against this baseline file
    string saveBaseline; // write current results here
    bool check; // exit nonzero on regression past --threshold
    double threshold = 5.0; // regression budget, percent
    long warmup = -1; // CLI overrides (>=0 wins over manifest)
    long iterations = -1;
    long samples = -1;
}

int main(string[] args)
{
    Options o;
    auto help = getopt(args,
        "manifest", "Workload manifest (default bench/workloads/manifest.json)", &o.manifest,
        "only", "Run only the named workload", &o.only,
        "adapter", "std | vibe | both (default both)", &o.adapter,
        "json", "Emit protocol JSON lines instead of a table", &o.json,
        "baseline", "Compare medians against this baseline JSON file", &o.baseline,
        "save-baseline", "Write current medians to this file", &o.saveBaseline,
        "check", "Exit nonzero if a median regresses past --threshold", &o.check,
        "threshold", "Regression budget in percent (default 5)", &o.threshold,
        "warmup", "Override warmup iterations", &o.warmup,
        "iterations", "Override timed iterations per sample", &o.iterations,
        "samples", "Override sample count", &o.samples);

    if (help.helpWanted)
    {
        defaultGetoptPrinter("jsonschema performance harness", help.options);
        return 0;
    }

    const root = manifestRoot(o.manifest);
    auto workloads = loadManifest(o.manifest, o);

    Result[] results;
    foreach (w; workloads)
    {
        if (o.only.length && w.name != o.only)
            continue;
        if (o.adapter == "std" || o.adapter == "both")
            results ~= runWorkload!StdAdapter(root, w);
        if (o.adapter == "vibe" || o.adapter == "both")
            results ~= runWorkload!VibeAdapter(root, w);
    }

    if (o.json)
        foreach (r; results)
            writeln(toProtocolJson(r));
    else
        printTable(results);

    if (o.saveBaseline.length)
        saveBaseline(o.saveBaseline, results);

    int rc;
    if (o.baseline.length)
        rc = compareBaseline(o.baseline, results, o.threshold, o.check);
    return rc;
}

// --- adapters: each maps the workload's pre-parsed instances to a native
//     value type and exposes a single validate call -------------------------

/// std.json adapter (the default `validate` path).
struct StdAdapter
{
    enum id = "jsonschema-d-std";
    alias Value = JSONValue;
    static Value parse(string text)
    {
        return parseJSON(text);
    }

    static bool validate(Validator v, ref Value data)
    {
        return v.validate(data, OutputFormat.flag).valid;
    }
}

/// vibe.data.json adapter (exercises vibe's own number handling).
struct VibeAdapter
{
    enum id = "jsonschema-d-vibe";
    alias Value = VibeJson;
    static Value parse(string text)
    {
        return parseJsonString(text);
    }

    static bool validate(Validator v, ref Value data)
    {
        return v.validateWith!VibeJsonAdapter(data, OutputFormat.flag).valid;
    }
}

Result runWorkload(A)(string root, in Workload w)
{
    Result r;
    r.implementation = A.id;
    r.workload = w.name;

    const schemaText = readText(buildPath(root, w.schemaPath));
    auto schemaTemplate = parseJson(schemaText);

    ValidatorSettings settings;
    if (w.formatAssertion)
        settings.formatMode = FormatMode.assertion;

    auto valid = w.validPaths.map!(p => A.parse(readText(buildPath(root, p)))).array;
    auto invalid = w.invalidPaths.map!(p => A.parse(readText(buildPath(root, p)))).array;
    r.bytes = w.validPaths.length ? cast(size_t) readText(buildPath(root, w.validPaths[0])).length : 0;

    auto validator = compileSchema(schemaTemplate.clone, settings);
    r.correctnessOk = correct!A(validator, valid, true) && correct!A(validator, invalid, false);

    // compile phase: build a validator from the in-memory schema (excludes JSON
    // text parsing; the clone matches how the schema is consumed per compile).
    r.compile = measure(w.samples, 1, () {
        auto v = compileSchema(schemaTemplate.clone, settings);
        sink += (cast(size_t) cast(void*) v) & 1; // touch the result so it survives
    });

    r.validValidate = timeValidate!A(validator, valid[0], w);
    r.invalidValidate = timeValidate!A(validator, invalid[0], w);
    return r;
}

bool correct(A)(Validator v, A.Value[] instances, bool expect)
{
    foreach (ref inst; instances)
        if (A.validate(v, inst) != expect)
            return false;
    return true;
}

Stat timeValidate(A)(Validator v, A.Value instance, in Workload w)
{
    foreach (_; 0 .. w.warmup)
        sink += A.validate(v, instance);
    return measure(w.samples, w.iterations, () { sink += A.validate(v, instance); });
}

/// Run `op` `iters` times per sample, across `samples` samples; return the
/// per-op nanosecond min and median.
Stat measure(size_t samples, size_t iters, scope void delegate() op)
{
    auto times = new double[samples];
    foreach (s; 0 .. samples)
    {
        const t0 = MonoTime.currTime;
        foreach (_; 0 .. iters)
            op();
        const dt = MonoTime.currTime - t0;
        times[s] = cast(double) dt.total!"nsecs" / iters;
    }
    sort(times);
    return Stat(times[0], times[samples / 2]);
}

// --- manifest -------------------------------------------------------------

string manifestRoot(string manifestPath)
{
    return dirName(manifestPath);
}

Workload[] loadManifest(string path, in Options o)
{
    auto doc = parseJSON(readText(path));
    const defaults = doc["defaults"];
    size_t pick(string key, in JSONValue node, long override_)
    {
        if (override_ >= 0)
            return cast(size_t) override_;
        if (key in node)
            return cast(size_t) node[key].integer;
        return cast(size_t) defaults[key].integer;
    }

    Workload[] out_;
    foreach (n; doc["workloads"].array)
    {
        Workload w;
        w.name = n["name"].str;
        w.schemaPath = n["schema"].str;
        w.validPaths = n["valid"].array.map!(v => v.str).array;
        w.invalidPaths = n["invalid"].array.map!(v => v.str).array;
        w.warmup = pick("warmup", n, o.warmup);
        w.iterations = pick("iterations", n, o.iterations);
        w.samples = pick("samples", n, o.samples);
        w.formatAssertion = ("formatAssertion" in n) && n["formatAssertion"].boolean;
        w.crossLanguage = ("crossLanguage" in n) && n["crossLanguage"].boolean;
        out_ ~= w;
    }
    return out_;
}

// --- output ---------------------------------------------------------------

string toProtocolJson(in Result r)
{
    JSONValue j;
    j["implementation"] = r.implementation;
    j["libraryVersion"] = libraryVersion;
    j["workload"] = r.workload;
    j["compileNsMin"] = r.compile.nsMin;
    j["compileNsMedian"] = r.compile.nsMedian;
    j["validateValidNsMin"] = r.validValidate.nsMin;
    j["validateValidNsMedian"] = r.validValidate.nsMedian;
    j["validateInvalidNsMin"] = r.invalidValidate.nsMin;
    j["validateInvalidNsMedian"] = r.invalidValidate.nsMedian;
    j["bytes"] = r.bytes;
    j["mbPerSec"] = r.mbPerSec;
    j["correctnessOk"] = r.correctnessOk;
    return j.toString;
}

void printTable(in Result[] results)
{
    writefln("%-22s %-14s %12s %12s %12s %10s  %s",
        "workload", "adapter", "compile µs", "valid ns", "invalid ns", "MB/s", "ok");
    writeln(repeat('-', 96));
    foreach (r; results)
    {
        writefln("%-22s %-14s %12.1f %12.1f %12.1f %10.0f  %s",
            r.workload, adapterShort(r.implementation),
            r.compile.nsMedian / 1000.0, r.validValidate.nsMedian,
            r.invalidValidate.nsMedian, r.mbPerSec, r.correctnessOk ? "yes" : "FAIL");
    }
}

string adapterShort(string impl)
{
    import std.string : replace;

    return impl.replace("jsonschema-d-", "");
}

string repeat(char c, size_t n)
{
    auto s = new char[n];
    s[] = c;
    return s.idup;
}

// --- baseline -------------------------------------------------------------

string baselineKey(in Result r)
{
    return r.implementation ~ "/" ~ r.workload;
}

void saveBaseline(string path, in Result[] results)
{
    JSONValue root;
    foreach (r; results)
    {
        JSONValue e;
        e["compileNsMedian"] = r.compile.nsMedian;
        e["validateValidNsMedian"] = r.validValidate.nsMedian;
        e["validateInvalidNsMedian"] = r.invalidValidate.nsMedian;
        root[baselineKey(r)] = e;
    }
    import std.file : write;

    write(path, root.toString);
    stderr.writefln("baseline written to %s", path);
}

int compareBaseline(string path, in Result[] results, double threshold, bool check)
{
    import std.file : exists;

    if (!exists(path))
    {
        stderr.writefln("baseline %s not found; run with --save-baseline first", path);
        return check ? 1 : 0;
    }
    auto base = parseJSON(readText(path));
    bool regressed;
    writeln("\nvs baseline (validate-valid median, +worse / -better):");
    foreach (r; results)
    {
        const key = baselineKey(r);
        if (key !in base)
            continue;
        const was = base[key]["validateValidNsMedian"].floating;
        const now = r.validValidate.nsMedian;
        const delta = (now - was) / was * 100.0;
        const flag = delta > threshold ? "  REGRESSION" : "";
        writefln("  %-34s %10.1f -> %10.1f ns  (%+.1f%%)%s", key, was, now, delta, flag);
        if (delta > threshold)
            regressed = true;
    }
    return (check && regressed) ? 1 : 0;
}
