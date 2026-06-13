/// Pre-registered schema document store.
///
/// `$ref` resolution is local-only by default: external references resolve
/// against documents registered here (keyed by absolute URI, usually the
/// document's `$id`), and compilation fails for anything unknown. The bundled
/// JSON Schema 2020-12, 2019-09, and draft-07 meta-schemas are registered in
/// every store. Callers who want remote loading supply
/// `ValidatorSettings.resolver` — the library never performs network I/O on its
/// own.
module jsonschema.store;

import jsonschema.node : JsonNode, fromStdJson, parseJson;
import std.json : JSONValue;

@safe:

final class SchemaStore
{
    /// Raw documents by absolute URI. Compilation happens lazily, per
    /// validator, when a reference first targets the document.
    package JsonNode[string] rawDocs;

    this()
    {
        registerBundledMetaSchemas();
    }

    /// Register a parsed document under `uri`.
    void register(string uri, JsonNode doc) pure nothrow
    {
        rawDocs[uri] = doc;
    }

    /// Register a document from JSON text.
    void register(string uri, string jsonText) pure
    {
        rawDocs[uri] = parseJson(jsonText);
    }

    /// Register a document from a `std.json` value.
    void register(string uri, in JSONValue doc)
    {
        rawDocs[uri] = fromStdJson(doc);
    }

    /// True when a document is registered under `uri`.
    bool contains(string uri) const pure nothrow
    {
        return (uri in rawDocs) !is null;
    }

    package const(JsonNode)* lookup(string uri) const pure nothrow
    {
        return uri in rawDocs;
    }

    private void registerBundledMetaSchemas()
    {
        // Copy references from the shared, already-parsed cache. `JsonNode` is a
        // value type backed by immutable slices, so sharing parsed nodes across
        // stores is safe: stores only read `rawDocs` via `lookup`, never mutate
        // registered documents.
        foreach (uri, doc; bundledMetaSchemas())
            rawDocs[uri] = doc;
    }
}

/// Bundled meta-schema documents, parsed once and shared across every store.
///
/// The map is built lazily on first access and cached in a `__gshared`
/// variable. Parsing is deterministic and the result is treated as immutable,
/// so a benign race during initialization at worst parses twice; subsequent
/// `new SchemaStore` calls copy `JsonNode` references instead of re-parsing.
private JsonNode[string] bundledMetaSchemas() @trusted nothrow
{
    __gshared JsonNode[string] cache;

    static JsonNode[string] build() nothrow
    {
        JsonNode[string] m;

        void add(string uri, string jsonText) nothrow
        {
            try
                m[uri] = parseJson(jsonText);
            catch (Exception)
                assert(false, "bundled meta-schema failed to parse: " ~ uri);
        }

        add("https://json-schema.org/draft/2020-12/schema", import("schema.json"));
        add("https://json-schema.org/draft/2020-12/meta/core", import("meta/core.json"));
        add("https://json-schema.org/draft/2020-12/meta/applicator", import("meta/applicator.json"));
        add("https://json-schema.org/draft/2020-12/meta/validation", import("meta/validation.json"));
        add("https://json-schema.org/draft/2020-12/meta/unevaluated",
                import("meta/unevaluated.json"));
        add("https://json-schema.org/draft/2020-12/meta/format-annotation",
                import("meta/format-annotation.json"));
        add("https://json-schema.org/draft/2020-12/meta/content", import("meta/content.json"));
        add("https://json-schema.org/draft/2020-12/meta/meta-data", import("meta/meta-data.json"));

        // Draft 2019-09 (main schema plus its six vocabulary meta-schemas).
        add("https://json-schema.org/draft/2019-09/schema", import("draft2019-09/schema.json"));
        add("https://json-schema.org/draft/2019-09/meta/core",
                import("draft2019-09/meta/core.json"));
        add("https://json-schema.org/draft/2019-09/meta/applicator",
                import("draft2019-09/meta/applicator.json"));
        add("https://json-schema.org/draft/2019-09/meta/validation",
                import("draft2019-09/meta/validation.json"));
        add("https://json-schema.org/draft/2019-09/meta/meta-data",
                import("draft2019-09/meta/meta-data.json"));
        add("https://json-schema.org/draft/2019-09/meta/format",
                import("draft2019-09/meta/format.json"));
        add("https://json-schema.org/draft/2019-09/meta/content",
                import("draft2019-09/meta/content.json"));

        // Draft-07 (a single self-contained meta-schema; no vocabularies).
        add("http://json-schema.org/draft-07/schema#", import("draft-07/schema.json"));
        add("http://json-schema.org/draft-07/schema", import("draft-07/schema.json"));

        return m;
    }

    if (cache is null)
        cache = build();
    return cache;
}

unittest  // a fresh store carries the bundled meta-schemas
{
    auto store = new SchemaStore;
    assert(store.contains("https://json-schema.org/draft/2020-12/schema"));
    assert(store.contains("https://json-schema.org/draft/2020-12/meta/core"));
    assert(store.contains("https://json-schema.org/draft/2020-12/meta/format-annotation"));
    assert(store.contains("https://json-schema.org/draft/2019-09/schema"));
    assert(store.contains("https://json-schema.org/draft/2019-09/meta/applicator"));
    assert(store.contains("http://json-schema.org/draft-07/schema#"));
}

unittest  // bundled docs are equal across independently constructed stores
{
    import jsonschema.node : jsonEquals;

    auto a = new SchemaStore;
    auto b = new SchemaStore;
    auto da = a.lookup("https://json-schema.org/draft/2020-12/schema");
    auto db = b.lookup("https://json-schema.org/draft/2020-12/schema");
    assert(da !is null && db !is null);
    assert(jsonEquals(*da, *db));
}

unittest  // register from text and from std.json
{
    import std.json : parseJSON;

    auto store = new SchemaStore;
    store.register("https://example.com/a", `{"type":"string"}`);
    assert(store.contains("https://example.com/a"));
    store.register("https://example.com/b", parseJSON(`{"type":"integer"}`));
    assert(store.contains("https://example.com/b"));
    assert(!store.contains("https://example.com/c"));
}
