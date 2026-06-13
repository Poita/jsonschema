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
enum remotesDir = suiteRoot ~ "/remotes";
enum remoteBase = "http://localhost:1234/";

/// One draft to run: its test directory and the dialect assumed for schemas
/// that carry no `$schema` of their own.
struct DraftRun
{
    string name;
    string dir;
    string defaultDialect;
}

immutable DraftRun[] drafts = [
    DraftRun("draft2020-12", suiteRoot ~ "/tests/draft2020-12",
        "https://json-schema.org/draft/2020-12/schema"),
    DraftRun("draft2019-09", suiteRoot ~ "/tests/draft2019-09",
        "https://json-schema.org/draft/2019-09/schema"),
    DraftRun("draft7", suiteRoot ~ "/tests/draft7",
        "http://json-schema.org/draft-07/schema#"),
];

struct CaseResult
{
    string draft; // draft directory name
    string file; // relative to the draft directory
    string group; // schema description
    string test; // test description
    bool expected;
    bool stdGot;
    bool vibeGot;
    string error; // exception text, if compilation/validation threw
}

/// Running per-draft tallies, printed as a summary at the end.
struct Stats
{
    size_t reqPass, reqFail, optPass, optFail, skipped;
}

int main()
{
    auto store = makeRemoteStore();

    size_t reqPass, reqFail, optPass, optFail, skipped, divergences;
    Stats[string] perDraft;
    CaseResult[] failures;

    foreach (draft; drafts)
    {
        perDraft[draft.name] = Stats.init;
        if (!exists(draft.dir))
        {
            writeln("test suite not found at ", draft.dir, " — run: git submodule update --init");
            return 2;
        }

        auto files = dirEntries(draft.dir, "*.json", SpanMode.depth).array;
        sort!((a, b) => a.name < b.name)(files);

        foreach (entry; files)
        {
            const rel = entry.name[draft.dir.length + 1 .. $];
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
                    r.draft = draft.name;
                    r.file = rel;
                    r.group = groupDesc;
                    r.test = testDesc;
                    r.expected = expected;

                    if (isDeliberateSkip(draft.name, rel, groupDesc))
                    {
                        skipped++;
                        perDraft[draft.name].skipped++;
                        continue;
                    }
                    runCase(draft, rel, schemaNode, dataNode, store, r);

                    const pass = r.stdGot == expected && r.vibeGot == expected
                        && r.error.length == 0;
                    if (r.stdGot != r.vibeGot)
                        divergences++;
                    if (optional)
                    {
                        if (pass)
                        {
                            optPass++;
                            perDraft[draft.name].optPass++;
                        }
                        else
                        {
                            optFail++;
                            perDraft[draft.name].optFail++;
                            failures ~= r;
                        }
                    }
                    else
                    {
                        if (pass)
                        {
                            reqPass++;
                            perDraft[draft.name].reqPass++;
                        }
                        else
                        {
                            reqFail++;
                            perDraft[draft.name].reqFail++;
                            failures ~= r;
                        }
                    }
                }
            }
        }
    }

    if (failures.length)
    {
        writeln("--- failures ---");
        foreach (f; failures)
            writefln("%s/%s | %s | %s | expected=%s std=%s vibe=%s%s", f.draft, f.file,
                    f.group, f.test, f.expected, f.stdGot, f.vibeGot,
                    f.error.length ? " | " ~ f.error : "");
        writeln();
    }

    foreach (draft; drafts)
    {
        const s = perDraft[draft.name];
        writefln("[%s] required %d/%d, optional %d/%d, skipped %d", draft.name,
                s.reqPass, s.reqPass + s.reqFail, s.optPass, s.optPass + s.optFail, s.skipped);
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

/// Deliberately unsupported territory, documented in the README.
///
/// Applied to every draft: IDNA / punycode-aware hostname semantics and
/// internationalized resource identifiers (would require Unicode IDNA tables).
/// Draft-07-only: its optional `content` tests expect `contentEncoding` /
/// `contentMediaType` to assert; this library treats `content` keywords as
/// annotations in every draft (the 2019-09 / 2020-12 position), so the
/// invalid-content cases are skipped rather than mis-reported.
bool isDeliberateSkip(string draftName, string rel, string group)
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
    case "optional/content.json":
        return draftName == "draft7";
    default:
        return false;
    }
}

/// Decide settings per file: format tests under optional/format/ run with
/// assertion enabled; everything else uses the spec default (annotation). The
/// draft directory fixes the dialect for schemas that omit `$schema`.
void runCase(in DraftRun draft, string rel, in JsonNode schemaNode,
        in JsonNode dataNode, SchemaStore store, ref CaseResult r)
{
    ValidatorSettings settings;
    settings.store = store;
    settings.defaultDialect = draft.defaultDialect;
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
