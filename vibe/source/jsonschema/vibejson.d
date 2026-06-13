/// vibe.data.json adapter for jsonschema (subpackage `jsonschema:vibe`).
///
/// This module is the only place vibe-d appears as a dependency. It provides:
/// `VibeJsonAdapter` (validate `vibe.data.json.Json` instances),
/// `compileSchema` for `Json` schema documents, `validateJson` /
/// `isValidJson` convenience,
/// and `nodeToVibeJson` / `vibeJsonToNode` conversions (including rendering
/// generated schemas as `Json`).
module jsonschema.vibejson;

import jsonschema.adapter : JsonKind, JsonNumber, isJsonAdapter;
import jsonschema.compiler : compileSchema_ = compileSchema;
import jsonschema.ir : OutputFormat, ValidationResult, ValidatorSettings;
import jsonschema.node : JsonNode;
import jsonschema.store : SchemaStore;
import jsonschema.validator : Validator;

import vibe.data.json : Json;
import std.bigint : BigInt, toDecimalString;
import std.conv : to;

@safe:

/// Adapter for `vibe.data.json.Json`.
struct VibeJsonAdapter
{
    alias Value = Json;

    static Value ofString(string s)
    {
        return Json(s);
    }

    static JsonKind kindOf(in Value v)
    {
        final switch (v.type)
        {
        case Json.Type.undefined:
        case Json.Type.null_:
            return JsonKind.null_;
        case Json.Type.bool_:
            return JsonKind.boolean;
        case Json.Type.int_:
        case Json.Type.bigInt:
            return JsonKind.integer;
        case Json.Type.float_:
            return JsonKind.floating;
        case Json.Type.string:
            return JsonKind.string_;
        case Json.Type.array:
            return JsonKind.array;
        case Json.Type.object:
            return JsonKind.object;
        }
    }

    static bool getBoolean(in Value v)
    {
        return v.get!bool;
    }

    static JsonNumber getNumber(in Value v)
    {
        if (v.type == Json.Type.int_)
            return JsonNumber.ofLong(v.get!long);
        if (v.type == Json.Type.bigInt)
        {
            auto b = v.get!BigInt;
            if (b >= BigInt(long.min) && b <= BigInt(long.max))
                return JsonNumber.ofLong(b.toLong);
            if (b > BigInt(0) && b <= BigInt(ulong.max))
                return JsonNumber.ofULong(toDecimalString(b).to!ulong);
            // Beyond 64-bit range: the floating view is the best available.
            return JsonNumber.ofDouble(toDecimalString(b).to!double);
        }
        return JsonNumber.ofDouble(v.get!double);
    }

    static string getString(in Value v)
    {
        return v.get!string;
    }

    static size_t arrayLength(in Value v)
    {
        return v.length;
    }

    static const(Value) arrayAt(in Value v, size_t index)
    {
        return v[index];
    }

    static size_t objectLength(in Value v)
    {
        return v.length;
    }

    static const(Value)* objectGet(in Value v, string key) @trusted
    {
        // The object payload is heap-allocated and refcounted by Json itself;
        // the member pointer outlives the by-value parameter copy.
        return key in v;
    }

    static int objectEach(in Value v, scope int delegate(string key, in Value val) @safe dg)
    {
        foreach (string key, ref const(Json) val; v.byKeyValue)
            if (auto r = dg(key, val))
                return r;
        return 0;
    }
}

static assert(isJsonAdapter!VibeJsonAdapter);

/// Convert a `vibe.data.json.Json` document into the internal representation.
/// BigInt values keep 64-bit fidelity (signed or unsigned) and fall back to
/// floating point only beyond the 64-bit range.
JsonNode vibeJsonToNode(in Json v)
{
    final switch (v.type)
    {
    case Json.Type.undefined:
    case Json.Type.null_:
        return JsonNode(null);
    case Json.Type.bool_:
        return JsonNode(v.get!bool);
    case Json.Type.int_:
        return JsonNode(v.get!long);
    case Json.Type.bigInt:
        auto b = v.get!BigInt;
        if (b >= BigInt(long.min) && b <= BigInt(long.max))
            return JsonNode(b.toLong);
        if (b > BigInt(0) && b <= BigInt(ulong.max))
            return JsonNode(toDecimalString(b).to!ulong);
        return JsonNode(toDecimalString(b).to!double);
    case Json.Type.float_:
        return JsonNode(v.get!double);
    case Json.Type.string:
        return JsonNode(v.get!string);
    case Json.Type.array:
        auto n = JsonNode.emptyArray();
        foreach (size_t i, ref const(Json) e; v.byIndexValue)
            n.append(vibeJsonToNode(e));
        return n;
    case Json.Type.object:
        auto n = JsonNode.emptyObject();
        foreach (string key, ref const(Json) val; v.byKeyValue)
            n.set(key, vibeJsonToNode(val));
        return n;
    }
}

/// Render the internal representation as a `vibe.data.json.Json` value.
Json nodeToVibeJson(in JsonNode n)
{
    alias K = JsonNode.Kind;
    final switch (n.kind)
    {
    case K.null_:
        return Json(null);
    case K.boolean:
        return Json(n.boolean_);
    case K.integer:
        return Json(n.integer_);
    case K.uinteger:
        return Json(BigInt(n.uinteger_));
    case K.floating:
        return Json(n.floating_);
    case K.string_:
        return Json(n.string_);
    case K.array:
        auto a = Json.emptyArray;
        foreach (ref e; n.array_)
            a.appendArrayElement(nodeToVibeJson(e));
        return a;
    case K.object:
        auto o = Json.emptyObject;
        foreach (ref m; n.members_)
            o[m.key] = nodeToVibeJson(m.value);
        return o;
    }
}

/// Compile a schema document given as `vibe.data.json.Json`.
Validator compileSchema(in Json doc, ValidatorSettings settings = ValidatorSettings.init)
{
    return compileSchema_(vibeJsonToNode(doc), settings);
}

/// Validate a `vibe.data.json.Json` instance against a compiled validator.
/// (Free function because `Validator` lives in the base package; equivalent to
/// `v.validateWith!VibeJsonAdapter(instance, format)`.)
ValidationResult validateJson(Validator v, in Json instance, OutputFormat format = OutputFormat
        .basic)
{
    return v.validateWith!VibeJsonAdapter(instance, format);
}

/// Convenience: flag-format validity check for a `vibe.data.json.Json`
/// instance. Mirrors `Validator.isValid` for vibe parity.
bool isValidJson(Validator v, in Json instance)
{
    return v.validateWith!VibeJsonAdapter(instance, OutputFormat.flag).valid;
}

/// Register a `Json` schema document in a store.
void registerJson(SchemaStore store, string uri, in Json doc)
{
    store.register(uri, vibeJsonToNode(doc));
}

version (unittest)
{
    import vibe.data.json : parseJsonString;
}

unittest  // basic validation through the vibe adapter
{
    auto v = compileSchema(parseJsonString(
            `{"type": "object", "properties": {"a": {"type": "integer"}}, "required": ["a"]}`));
    assert(v.validateJson(parseJsonString(`{"a": 1}`)).valid);
    assert(!v.validateJson(parseJsonString(`{}`)).valid);
    assert(!v.validateJson(parseJsonString(`{"a": "x"}`)).valid);
}

unittest  // calling Validator.validate/isValid on a vibe Json fails with a directed message
{
    auto v = compileSchema(parseJsonString(`{"type": "integer"}`));
    auto j = parseJsonString("1");
    // The base-package member overloads must not accept vibe `Json`; callers
    // are steered to `validateJson` instead of hitting a generic resolution
    // error.
    static assert(!__traits(compiles, v.validate(j)));
    static assert(!__traits(compiles, v.isValid(j)));
    // The supported path compiles and works.
    assert(v.validateJson(j).valid);
}

unittest  // isValidJson mirrors validateJson(...).valid for valid instances
{
    auto v = compileSchema(parseJsonString(
            `{"type": "object", "properties": {"a": {"type": "integer"}}, "required": ["a"]}`));
    assert(v.isValidJson(parseJsonString(`{"a": 1}`)));
}

unittest  // isValidJson reports invalid instances
{
    auto v = compileSchema(parseJsonString(
            `{"type": "object", "properties": {"a": {"type": "integer"}}, "required": ["a"]}`));
    assert(!v.isValidJson(parseJsonString(`{}`)));
    assert(!v.isValidJson(parseJsonString(`{"a": "x"}`)));
}

unittest  // vibe bigInt keeps 64-bit fidelity (no double round-trip)
{
    // 2^53 + 1 vs maximum 2^53: a double comparison would wrongly accept.
    auto v = compileSchema(parseJsonString(`{"maximum": 9007199254740992}`));
    auto big = parseJsonString("9007199254740993");
    assert(!v.validateJson(big).valid);
    assert(v.validateJson(parseJsonString("9007199254740992")).valid);
}

unittest  // ulong-range bigInt values compare exactly
{
    auto v = compileSchema(parseJsonString(`{"minimum": 18446744073709551615}`));
    assert(v.validateJson(parseJsonString("18446744073709551615")).valid);
    assert(!v.validateJson(parseJsonString("18446744073709551614")).valid);
}

unittest  // integer/float distinction across the vibe representation
{
    auto v = compileSchema(parseJsonString(`{"type": "integer"}`));
    assert(v.validateJson(parseJsonString("3")).valid);
    assert(v.validateJson(parseJsonString("1.0")).valid); // integral float
    assert(!v.validateJson(parseJsonString("1.5")).valid);
    auto m = compileSchema(parseJsonString(`{"multipleOf": 2}`));
    assert(m.validateJson(parseJsonString("4.0")).valid);
    assert(!m.validateJson(parseJsonString("7")).valid);
}

unittest  // const/enum equality across int_, bigInt and float_ representations
{
    auto v = compileSchema(parseJsonString(`{"const": 9007199254740993}`));
    assert(v.validateJson(parseJsonString("9007199254740993")).valid);
    assert(!v.validateJson(parseJsonString("9007199254740992")).valid);
}

unittest  // round-trip vibe Json -> JsonNode -> vibe Json
{
    import jsonschema.node : jsonEquals;

    auto j = parseJsonString(`{"a": [1, 2.5, "x", null, true], "big": 18446744073709551615}`);
    auto n = vibeJsonToNode(j);
    assert(n.get("big").kind == JsonNode.Kind.uinteger);
    auto back = nodeToVibeJson(n);
    assert(jsonEquals(vibeJsonToNode(back), n));
}

unittest  // schema documents may be supplied as vibe Json (compile-time normalize)
{
    import jsonschema.ir : UnsupportedDialectException;
    import std.exception : assertThrown;

    assertThrown!UnsupportedDialectException(compileSchema(
            parseJsonString(`{"$schema": "http://json-schema.org/draft-04/schema#"}`)));
}

unittest  // object key iteration order does not affect outcomes
{
    auto v = compileSchema(parseJsonString(
            `{"properties": {"a": {"type": "integer"}, "b": {"type": "string"}}, "additionalProperties": false}`));
    assert(v.validateJson(parseJsonString(`{"b": "s", "a": 1}`)).valid);
    assert(v.validateJson(parseJsonString(`{"a": 1, "b": "s"}`)).valid);
    assert(!v.validateJson(parseJsonString(`{"a": 1, "c": 2}`)).valid);
}
