/// Pre-registered schema document store.
///
/// `$ref` resolution is local-only by default: external references resolve
/// against documents registered here (keyed by absolute URI, usually the
/// document's `$id`), and compilation fails for anything unknown. The bundled
/// JSON Schema 2020-12 meta-schemas are registered in every store. Callers who
/// want remote loading supply `ValidatorSettings.resolver` — the library never
/// performs network I/O on its own.
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

    private void registerBundledMetaSchemas() pure
    {
        register("https://json-schema.org/draft/2020-12/schema", import("schema.json"));
        register("https://json-schema.org/draft/2020-12/meta/core", import("meta/core.json"));
        register("https://json-schema.org/draft/2020-12/meta/applicator",
                import("meta/applicator.json"));
        register("https://json-schema.org/draft/2020-12/meta/validation",
                import("meta/validation.json"));
        register("https://json-schema.org/draft/2020-12/meta/unevaluated",
                import("meta/unevaluated.json"));
        register("https://json-schema.org/draft/2020-12/meta/format-annotation",
                import("meta/format-annotation.json"));
        register("https://json-schema.org/draft/2020-12/meta/content", import("meta/content.json"));
        register("https://json-schema.org/draft/2020-12/meta/meta-data",
                import("meta/meta-data.json"));
    }
}

unittest // a fresh store carries the bundled meta-schemas
{
    auto store = new SchemaStore;
    assert(store.contains("https://json-schema.org/draft/2020-12/schema"));
    assert(store.contains("https://json-schema.org/draft/2020-12/meta/core"));
    assert(store.contains("https://json-schema.org/draft/2020-12/meta/format-annotation"));
}

unittest // register from text and from std.json
{
    import std.json : parseJSON;

    auto store = new SchemaStore;
    store.register("https://example.com/a", `{"type":"string"}`);
    assert(store.contains("https://example.com/a"));
    store.register("https://example.com/b", parseJSON(`{"type":"integer"}`));
    assert(store.contains("https://example.com/b"));
    assert(!store.contains("https://example.com/c"));
}
