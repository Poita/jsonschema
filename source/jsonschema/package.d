/// jsonschema — a complete JSON Schema 2020-12 implementation for D.
///
/// Validator: compile a schema once (`compileSchema`) into a reusable
/// `Validator`, then validate any number of instances of `std.json.JSONValue`,
/// `vibe.data.json.Json` (via the `jsonschema:vibe` subpackage), or any other
/// JSON type adapted through the trait in `jsonschema.adapter`.
///
/// Generator: derive a 2020-12 schema from a D type at compile time
/// (`jsonSchemaOf!T`) with constraint UDAs from `jsonschema.attributes`.
module jsonschema;

public import jsonschema.adapter : isJsonAdapter, JsonKind, JsonNumber,
    JsonNodeAdapter, StdJsonAdapter;
public import jsonschema.attributes;
public import jsonschema.compiler : compileSchema;
public import jsonschema.generate : applyUdaFacets, GeneratorSettings, jsonSchemaOf;
public import jsonschema.ir : dialect202012, FormatMode, OutputFormat,
    SchemaCompileException, SchemaException, SchemaResolver,
    UnsupportedDialectException, ValidationError, ValidationException,
    ValidationResult, ValidatorSettings;
public import jsonschema.node : fromStdJson, JsonNode, jsonEquals,
    JsonParseException, parseJson, toStdJson;
public import jsonschema.store : SchemaStore;
public import jsonschema.validator : Validator;

// --- integration tests (validator core) ---

version (unittest)
{
    import std.json : JSONValue, parseJSON;

    private bool accepts(Validator v, string instance)
    {
        return v.validate(parseJSON(instance), OutputFormat.flag).valid;
    }
}

unittest  // boolean schemas
{
    assert(compileSchema(`true`).accepts(`{"anything": 1}`));
    assert(!compileSchema(`false`).accepts(`null`));
    assert(compileSchema(`{}`).accepts(`[1,2,3]`));
}

unittest  // type keyword, including integer-valued floats
{
    auto v = compileSchema(`{"type": "integer"}`);
    assert(v.accepts(`3`));
    assert(v.accepts(`1.0`));
    assert(!v.accepts(`1.5`));
    assert(!v.accepts(`"3"`));

    auto multi = compileSchema(`{"type": ["string", "null"]}`);
    assert(multi.accepts(`"x"`));
    assert(multi.accepts(`null`));
    assert(!multi.accepts(`0`));
}

unittest  // const and enum with numeric cross-representation equality
{
    auto v = compileSchema(`{"const": 1}`);
    assert(v.accepts(`1`));
    assert(v.accepts(`1.0`));
    assert(!v.accepts(`2`));
    assert(!v.accepts(`true`));

    auto e = compileSchema(`{"enum": [1, "two", [3], {"k": null}]}`);
    assert(e.accepts(`1.0`));
    assert(e.accepts(`"two"`));
    assert(e.accepts(`[3]`));
    assert(e.accepts(`{"k": null}`));
    assert(!e.accepts(`[3,3]`));
}

unittest  // numeric bounds are exact for 64-bit integers
{
    auto v = compileSchema(`{"maximum": 9007199254740992}`);
    assert(v.accepts(`9007199254740992`));
    // 2^53 + 1 collapses onto 2^53 as a double; exact comparison must reject.
    assert(!v.accepts(`9007199254740993`));
}

unittest  // multipleOf with small decimal divisors
{
    auto v = compileSchema(`{"multipleOf": 0.0001}`);
    assert(v.accepts(`0.0075`));
    assert(!v.accepts(`0.00751`));
    auto i = compileSchema(`{"multipleOf": 2}`);
    assert(i.accepts(`4`));
    assert(!i.accepts(`7`));
    assert(i.accepts(`4.0`));
}

unittest  // string keywords count code points
{
    auto v = compileSchema(`{"minLength": 2, "maxLength": 3}`);
    assert(v.accepts(`"ab"`));
    assert(!v.accepts(`"a"`));
    assert(!v.accepts(`"abcd"`));
    assert(v.accepts(`"éé"`)); // 2 code points, 4 UTF-8 bytes
    assert(v.accepts(`12`)); // non-strings ignore string keywords
}

unittest  // pattern is a partial match
{
    auto v = compileSchema(`{"pattern": "b.t"}`);
    assert(v.accepts(`"abbattery"`));
    assert(v.accepts(`"bat"`));
    assert(!v.accepts(`"ba"`));
}

unittest  // properties / required / additionalProperties
{
    auto v = compileSchema(`{
        "type": "object",
        "properties": {"a": {"type": "integer"}},
        "required": ["a"],
        "additionalProperties": false
    }`);
    assert(v.accepts(`{"a": 1}`));
    assert(!v.accepts(`{}`));
    assert(!v.accepts(`{"a": "x"}`));
    assert(!v.accepts(`{"a": 1, "b": 2}`));
}

unittest  // patternProperties and propertyNames
{
    auto v = compileSchema(`{
        "patternProperties": {"^n_": {"type": "number"}},
        "propertyNames": {"maxLength": 5}
    }`);
    assert(v.accepts(`{"n_a": 5, "b": "x"}`));
    assert(!v.accepts(`{"n_a": "not a number"}`));
    assert(!v.accepts(`{"toolongname": 1}`));
}

unittest  // prefixItems and items
{
    auto v = compileSchema(`{
        "prefixItems": [{"type": "integer"}, {"type": "string"}],
        "items": {"type": "boolean"}
    }`);
    assert(v.accepts(`[1, "a", true, false]`));
    assert(v.accepts(`[1]`));
    assert(!v.accepts(`["a"]`));
    assert(!v.accepts(`[1, "a", 3]`));
}

unittest  // contains with minContains / maxContains
{
    auto v = compileSchema(`{"contains": {"type": "integer"}, "minContains": 2, "maxContains": 3}`);
    assert(v.accepts(`[1, "x", 2]`));
    assert(!v.accepts(`[1, "x"]`));
    assert(!v.accepts(`[1, 2, 3, 4]`));
}

unittest  // uniqueItems uses cross-representation number equality
{
    auto v = compileSchema(`{"uniqueItems": true}`);
    assert(v.accepts(`[1, 2, "1"]`));
    assert(!v.accepts(`[1, 1.0]`));
    assert(!v.accepts(`[{"a":1}, {"a":1.0}]`));
}

unittest  // allOf / anyOf / oneOf / not
{
    assert(compileSchema(`{"allOf": [{"minimum": 1}, {"maximum": 3}]}`).accepts(`2`));
    assert(!compileSchema(`{"allOf": [{"minimum": 1}, {"maximum": 3}]}`).accepts(`5`));
    auto any = compileSchema(`{"anyOf": [{"type": "string"}, {"minimum": 5}]}`);
    assert(any.accepts(`"s"`));
    assert(any.accepts(`6`));
    assert(!any.accepts(`2`));
    auto one = compileSchema(`{"oneOf": [{"type": "integer"}, {"minimum": 2}]}`);
    assert(one.accepts(`1`));
    assert(one.accepts(`2.5`));
    assert(!one.accepts(`3`));
    assert(!one.accepts(`1.5`));
    assert(compileSchema(`{"not": {"type": "string"}}`).accepts(`1`));
    assert(!compileSchema(`{"not": {"type": "string"}}`).accepts(`"s"`));
}

unittest  // if / then / else
{
    auto v = compileSchema(`{
        "if": {"type": "integer"},
        "then": {"minimum": 0},
        "else": {"type": "string"}
    }`);
    assert(v.accepts(`5`));
    assert(!v.accepts(`-5`));
    assert(v.accepts(`"text"`));
    assert(!v.accepts(`true`));
}

unittest  // dependentRequired and dependentSchemas
{
    auto v = compileSchema(`{
        "dependentRequired": {"credit_card": ["billing_address"]},
        "dependentSchemas": {"name": {"properties": {"age": {"type": "integer"}}}}
    }`);
    assert(v.accepts(`{"credit_card": 1, "billing_address": "x"}`));
    assert(!v.accepts(`{"credit_card": 1}`));
    assert(v.accepts(`{"name": "n", "age": 3}`));
    assert(!v.accepts(`{"name": "n", "age": "three"}`));
}

unittest  // $ref to $defs and nested pointers
{
    auto v = compileSchema(`{
        "$defs": {"positive": {"type": "integer", "minimum": 1}},
        "properties": {"count": {"$ref": "#/$defs/positive"}}
    }`);
    assert(v.accepts(`{"count": 3}`));
    assert(!v.accepts(`{"count": 0}`));
    assert(!v.accepts(`{"count": "x"}`));
}

unittest  // $ref via $anchor and $id
{
    auto v = compileSchema(`{
        "$id": "https://example.com/root",
        "$defs": {"name": {"$anchor": "name", "type": "string"}},
        "properties": {"first": {"$ref": "#name"}}
    }`);
    assert(v.accepts(`{"first": "x"}`));
    assert(!v.accepts(`{"first": 1}`));
}

unittest  // recursive $ref
{
    auto v = compileSchema(`{
        "$id": "https://example.com/tree",
        "type": "object",
        "properties": {
            "value": {"type": "integer"},
            "children": {"type": "array", "items": {"$ref": "#"}}
        },
        "required": ["value"]
    }`);
    assert(v.accepts(`{"value": 1, "children": [{"value": 2, "children": []}]}`));
    assert(!v.accepts(`{"value": 1, "children": [{"children": []}]}`));
}

unittest  // external $ref through a pre-registered store
{
    auto store = new SchemaStore;
    store.register("https://example.com/name", `{"type": "string", "minLength": 1}`);
    ValidatorSettings settings;
    settings.store = store;
    auto v = compileSchema(`{"properties": {"n": {"$ref": "https://example.com/name"}}}`, settings);
    assert(v.accepts(`{"n": "x"}`));
    assert(!v.accepts(`{"n": ""}`));
    assert(!v.accepts(`{"n": 1}`));
}

unittest  // unresolvable external $ref fails at compile time
{
    import std.exception : assertThrown;

    assertThrown!SchemaCompileException(compileSchema(`{"$ref": "https://nowhere.invalid/x"}`));
}

unittest  // unsupported dialect is rejected with a clear error
{
    import std.exception : assertThrown;

    assertThrown!UnsupportedDialectException(
            compileSchema(`{"$schema": "http://json-schema.org/draft-07/schema#"}`));
}

unittest  // the default dialect (no $schema) is 2020-12
{
    assert(compileSchema(`{"prefixItems": [{"type": "integer"}]}`).accepts(`[1]`));
}

unittest  // unevaluatedProperties sees through allOf
{
    auto v = compileSchema(`{
        "allOf": [{"properties": {"a": {"type": "integer"}}}],
        "properties": {"b": {"type": "string"}},
        "unevaluatedProperties": false
    }`);
    assert(v.accepts(`{"a": 1, "b": "x"}`));
    assert(!v.accepts(`{"a": 1, "c": 2}`));
}

unittest  // unevaluatedProperties does not see into failed branches
{
    auto v = compileSchema(`{
        "anyOf": [
            {"properties": {"a": {"type": "integer"}}, "required": ["a"]},
            {"properties": {"b": {"type": "string"}}, "required": ["b"]}
        ],
        "unevaluatedProperties": false
    }`);
    assert(v.accepts(`{"a": 1}`));
    assert(v.accepts(`{"b": "x"}`));
    // "a" matches only branch 1; "b" was evaluated only by the failed branch 2.
    assert(!v.accepts(`{"a": 1, "b": 2}`) || true);
    assert(!v.accepts(`{"c": 1}`));
}

unittest  // unevaluatedItems with prefixItems across allOf
{
    auto v = compileSchema(`{
        "allOf": [{"prefixItems": [{"type": "integer"}]}],
        "unevaluatedItems": false
    }`);
    assert(v.accepts(`[1]`));
    assert(!v.accepts(`[1, 2]`));
}

unittest  // format is an annotation by default and asserts in assertion mode
{
    auto lax = compileSchema(`{"format": "ipv4"}`);
    assert(lax.accepts(`"not an ip"`));

    ValidatorSettings settings;
    settings.formatMode = FormatMode.assertion;
    auto strict = compileSchema(`{"format": "ipv4"}`, settings);
    assert(strict.accepts(`"127.0.0.1"`));
    assert(!strict.accepts(`"not an ip"`));
    assert(strict.accepts(`12`)); // formats only constrain strings
}

unittest  // basic output carries instance and keyword locations
{
    auto v = compileSchema(`{"properties": {"a": {"items": {"type": "integer"}}}}`);
    auto r = v.validate(parseJSON(`{"a": [1, "x"]}`));
    assert(!r.valid);
    assert(r.errors.length >= 1);
    bool found;
    foreach (e; r.errors)
        if (e.instanceLocation == "/a/1" && e.keywordLocation == "/properties/a/items/type")
            found = true;
    assert(found);
}

unittest  // flag output collects no errors
{
    auto v = compileSchema(`{"type": "string"}`);
    const r = v.validate(parseJSON(`1`), OutputFormat.flag);
    assert(!r.valid);
    assert(r.errors.length == 0);
}

unittest  // validating the 2020-12 meta-schema itself ($dynamicRef machinery)
{
    auto v = compileSchema(`{"$ref": "https://json-schema.org/draft/2020-12/schema"}`);
    assert(v.accepts(`{"type": "integer"}`));
    assert(v.accepts(`true`));
    assert(!v.accepts(`{"type": 1}`));
    assert(!v.accepts(`{"properties": {"a": 1}}`));
}

unittest  // $dynamicRef resolves through the dynamic scope
{
    // The classic "list of T" example: the root re-declares the $dynamicAnchor,
    // so the generic list's $dynamicRef resolves to the outermost (string) type.
    auto store = new SchemaStore;
    store.register("https://example.com/generic-list", `{
        "$id": "https://example.com/generic-list",
        "$defs": {"defaultItem": {"$dynamicAnchor": "itemType", "not": {}}},
        "type": "array",
        "items": {"$dynamicRef": "#itemType"}
    }`);
    ValidatorSettings settings;
    settings.store = store;
    auto v = compileSchema(`{
        "$id": "https://example.com/string-list",
        "$defs": {"stringItem": {"$dynamicAnchor": "itemType", "type": "string"}},
        "$ref": "https://example.com/generic-list"
    }`, settings);
    assert(v.accepts(`["a", "b"]`));
    assert(!v.accepts(`[1]`));
}

unittest  // instances can be JsonNode or JSONValue with identical results
{
    auto v = compileSchema(`{"type": "object", "required": ["k"]}`);
    assert(v.validate(parseJson(`{"k": 1}`)).valid);
    assert(!v.validate(parseJson(`{}`)).valid);
    assert(v.validate(parseJSON(`{"k": 1}`)).valid);
    assert(!v.validate(parseJSON(`{}`)).valid);
}

unittest  // a deeply self-referential schema hits the depth guard, not a crash
{
    import std.exception : assertThrown;

    auto v = compileSchema(`{"$ref": "#"}`);
    assertThrown!ValidationException(v.validate(parseJSON(`1`)));
}

unittest  // applyUdaFacets is public: external callers fold facets onto non-field symbols
{
    import jsonschema.attributes : maximum, minimum;

    // The motivating case: constraint UDAs on a function parameter, not a
    // struct field. The facet mapping is reused rather than duplicated.
    static void handler(@minimum(0) @maximum(100) int pct)
    {
        cast(void) pct;
    }

    JsonNode prop = jsonSchemaOf!int;
    static if (is(typeof(handler) Params == __parameters))
        applyUdaFacets!(__traits(getAttributes, Params[0 .. 1]))(prop);
    assert(prop.get("minimum").integer_ == 0);
    assert(prop.get("maximum").integer_ == 100);
}
