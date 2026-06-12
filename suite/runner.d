/// Official JSON-Schema-Test-Suite harness.
///
/// Runs every draft2020-12 case (required and optional, including format
/// assertions) through BOTH JSON adapters — std.json and vibe.data.json — and
/// reports pass/fail counts. Any difference in outcome between the two
/// adapters for the same case is itself a failure (the differential check).
///
/// Exit status is non-zero when any required-section case fails or any
/// adapter divergence is found.
module runner;

import jsonschema;
import jsonschema.vibejson : VibeJsonAdapter;

import std.algorithm : endsWith, sort, startsWith;
import std.array : array;
import std.file : dirEntries, exists, readText, SpanMode;
import std.format : format;
import std.path : baseName;
import std.stdio : writefln, writeln;

import vibe.data.json : parseJsonString, VibeJson = Json;

enum suiteRoot = "tests/JSON-Schema-Test-Suite";
enum testsDir = suiteRoot ~ "/tests/draft2020-12";
enum remotesDir = suiteRoot ~ "/remotes";
enum remoteBase = "http://localhost:1234/";

struct CaseResult
{
    string file; // relative to the draft directory
    string group; // schema description
    string test; // test description
    bool expected;
    bool stdGot;
    bool vibeGot;
    string error; // exception text, if compilation/validation threw
}

int main()
{
    if (!exists(testsDir))
    {
        writeln("test suite not found at ", testsDir, " — run: git submodule update --init");
        return 2;
    }

    auto store = makeRemoteStore();

    size_t reqPass, reqFail, optPass, optFail, skipped, divergences;
    CaseResult[] failures;

    auto files = dirEntries(testsDir, "*.json", SpanMode.depth).array;
    sort!((a, b) => a.name < b.name)(files);

    foreach (entry; files)
    {
        const rel = entry.name[testsDir.length + 1 .. $];
        const optional = rel.startsWith("optional");
        const text = readText(entry.name);
        auto groups = parseJson(text);

        foreach (ref g; groups.array_)
        {
            const groupDesc = g.get("description").string_;
            auto schemaNode = *g.get("schema");
            foreach (ref t; g.get("tests").array_)
            {
                const testDesc = t.get("description").string_;
                const expected = t.get("valid").boolean_;
                auto dataNode = *t.get("data");

                CaseResult r;
                r.file = rel;
                r.group = groupDesc;
                r.test = testDesc;
                r.expected = expected;

                if (isDeliberateSkip(rel, groupDesc))
                {
                    skipped++;
                    continue;
                }
                runCase(rel, text, schemaNode, dataNode, store, r);

                const pass = r.stdGot == expected && r.vibeGot == expected && r.error.length == 0;
                if (r.stdGot != r.vibeGot)
                    divergences++;
                if (optional)
                {
                    if (pass)
                        optPass++;
                    else
                    {
                        optFail++;
                        failures ~= r;
                    }
                }
                else
                {
                    if (pass)
                        reqPass++;
                    else
                    {
                        reqFail++;
                        failures ~= r;
                    }
                }
            }
        }
    }

    if (failures.length)
    {
        writeln("--- failures ---");
        foreach (f; failures)
            writefln("%s | %s | %s | expected=%s std=%s vibe=%s%s", f.file,
                    f.group, f.test, f.expected, f.stdGot, f.vibeGot,
                    f.error.length ? " | " ~ f.error : "");
        writeln();
    }

    const reqTotal = reqPass + reqFail;
    const optTotal = optPass + optFail;
    writefln("required: %d/%d passed (%.2f%%)", reqPass, reqTotal, reqTotal
            ? 100.0 * reqPass / reqTotal : 0);
    writefln("optional: %d/%d passed (%.2f%%)", optPass, optTotal, optTotal
            ? 100.0 * optPass / optTotal : 0);
    writefln("skipped: %d (deliberate, see README)", skipped);
    writefln("adapter divergences: %d", divergences);

    return (reqFail || divergences) ? 1 : 0;
}

/// Deliberately unsupported territory, documented in the README: IDNA /
/// punycode-aware hostname semantics, internationalized resource identifiers,
/// and historic-draft cross-references.
bool isDeliberateSkip(string rel, string group)
{
    switch (rel)
    {
    case "optional/format/idn-hostname.json":
    case "optional/format/idn-email.json":
    case "optional/format/iri.json":
    case "optional/format/iri-reference.json":
        return true;
    case "optional/format/hostname.json":
        return group == "validation of A-label (punycode) host names";
    case "optional/cross-draft.json":
        return true;
    default:
        return false;
    }
}

/// Decide settings per file: format tests under optional/format/ run with
/// assertion enabled; everything else uses the spec default (annotation).
void runCase(string rel, string fileText, in JsonNode schemaNode,
        in JsonNode dataNode, SchemaStore store, ref CaseResult r)
{
    ValidatorSettings settings;
    settings.store = store;
    if (rel.startsWith("optional/format/"))
        settings.formatMode = FormatMode.assertion;

    try
    {
        auto validator = compileSchema(schemaNode.clone, settings);

        // std.json path
        const stdData = toStdJson(dataNode);
        r.stdGot = validator.validate(stdData, OutputFormat.flag).valid;

        // vibe.data.json path: re-parse the raw data through vibe's parser via
        // serialization of the node, exercising vibe's own number handling.
        const vibeData = toVibeJson(dataNode);
        r.vibeGot = validator.validateWith!VibeJsonAdapter(vibeData, OutputFormat.flag).valid;
    }
    catch (Exception e)
    {
        r.error = e.classinfo.name ~ ": " ~ e.msg;
        r.stdGot = !r.expected; // count as failed
        r.vibeGot = !r.expected;
    }
}

VibeJson toVibeJson(in JsonNode n)
{
    import jsonschema.vibejson : nodeToVibeJson;

    return nodeToVibeJson(n);
}

/// Register every file under remotes/ at its http://localhost:1234/ URI.
SchemaStore makeRemoteStore()
{
    auto store = new SchemaStore;
    foreach (entry; dirEntries(remotesDir, "*.json", SpanMode.depth))
    {
        const rel = entry.name[remotesDir.length + 1 .. $];
        // URI paths always use forward slashes.
        string uriPath;
        foreach (c; rel)
            uriPath ~= c == '\\' ? '/' : c;
        try
            store.register(remoteBase ~ uriPath, readText(entry.name));
        catch (JsonParseException)
        {
            // some remotes intentionally hold non-schema content; skip
        }
    }
    return store;
}
