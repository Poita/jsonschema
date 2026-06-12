/// The JSON-type adapter trait.
///
/// Instance validation is templated over a small adapter so any JSON document
/// type can be validated without conversion. An adapter is a struct with the
/// following compile-time interface (all functions static):
///
/// ---
/// struct MyAdapter
/// {
///     alias Value = <your JSON type>;
///
///     // Classify a value. `integer` is for integral representations only;
///     // a float that happens to hold a whole number reports `floating`
///     // (the validator itself implements JSON Schema's "integer means
///     // zero fractional part" rule).
///     static JsonKind kindOf(in Value v);
///
///     // Scalar extraction; only called when kindOf reports the matching kind.
///     static bool getBoolean(in Value v);
///     static JsonNumber getNumber(in Value v);    // for integer and floating
///     static string getString(in Value v);
///
///     // Arrays; only called when kindOf reports array.
///     static size_t arrayLength(in Value v);
///     static const(Value) arrayAt(in Value v, size_t index);
///
///     // Objects; only called when kindOf reports object. Iteration order may
///     // be arbitrary — validation outcomes never depend on it.
///     static size_t objectLength(in Value v);
///     static const(Value)* objectGet(in Value v, string key); // null if absent
///     static int objectEach(in Value v, scope int delegate(string key, in Value val) @safe dg);
/// }
/// ---
///
/// Two adapters ship with the library: `StdJsonAdapter` here (std.json,
/// dependency-free) and `VibeJsonAdapter` in the `jsonschema:vibe` subpackage
/// (vibe.data.json). `JsonNodeAdapter` adapts the library's own internal
/// representation, which is how generated schemas are meta-validated. To adapt
/// another JSON library (asdf, mir-ion, …), implement the interface above and
/// pass the adapter to `Validator.validateWith!MyAdapter(value)`.
module jsonschema.adapter;

import jsonschema.node : JsonNode;
import std.json : JSONValue, JSONType;

@safe:

/// Classification of a JSON value as seen by the validator.
enum JsonKind
{
    null_,
    boolean,
    integer, /// integral representation (signed or unsigned)
    floating,
    string_,
    array,
    object
}

/// A JSON number in its exact source representation. Integral values keep full
/// 64-bit fidelity; `asDouble` is the (possibly lossy) numeric view.
struct JsonNumber
{
    enum Rep
    {
        signed_,
        unsigned_,
        floating_
    }

    Rep rep;
    long s;
    ulong u;
    double f;

    static JsonNumber ofLong(long v) pure nothrow
    {
        JsonNumber n;
        n.rep = Rep.signed_;
        n.s = v;
        return n;
    }

    static JsonNumber ofULong(ulong v) pure nothrow
    {
        if (v <= long.max)
            return ofLong(cast(long) v);
        JsonNumber n;
        n.rep = Rep.unsigned_;
        n.u = v;
        return n;
    }

    static JsonNumber ofDouble(double v) pure nothrow
    {
        JsonNumber n;
        n.rep = Rep.floating_;
        n.f = v;
        return n;
    }

    bool isIntegral() const pure nothrow
    {
        return rep != Rep.floating_;
    }

    double asDouble() const pure nothrow
    {
        final switch (rep)
        {
        case Rep.signed_:
            return cast(double) s;
        case Rep.unsigned_:
            return cast(double) u;
        case Rep.floating_:
            return f;
        }
    }
}

/// True when `A` satisfies the adapter interface documented at module level.
template isJsonAdapter(A)
{
    enum isJsonAdapter = is(A.Value) && __traits(compiles, (in A.Value v) {
            JsonKind k = A.kindOf(v);
            bool b = A.getBoolean(v);
            JsonNumber n = A.getNumber(v);
            string s = A.getString(v);
            size_t al = A.arrayLength(v);
            const(A.Value) e = A.arrayAt(v, 0);
            size_t ol = A.objectLength(v);
            const(A.Value)* m = A.objectGet(v, "key");
            int r = A.objectEach(v, (string key, in A.Value val) @safe => 0);
        });
}

/// Adapter for `std.json.JSONValue`.
struct StdJsonAdapter
{
    alias Value = JSONValue;

    static JsonKind kindOf(in Value v)
    {
        final switch (v.type)
        {
        case JSONType.null_:
            return JsonKind.null_;
        case JSONType.true_:
        case JSONType.false_:
            return JsonKind.boolean;
        case JSONType.integer:
        case JSONType.uinteger:
            return JsonKind.integer;
        case JSONType.float_:
            return JsonKind.floating;
        case JSONType.string:
            return JsonKind.string_;
        case JSONType.array:
            return JsonKind.array;
        case JSONType.object:
            return JsonKind.object;
        }
    }

    static bool getBoolean(in Value v)
    {
        return v.type == JSONType.true_;
    }

    static JsonNumber getNumber(in Value v)
    {
        switch (v.type)
        {
        case JSONType.integer:
            return JsonNumber.ofLong(v.integer);
        case JSONType.uinteger:
            return JsonNumber.ofULong(v.uinteger);
        default:
            return JsonNumber.ofDouble(v.floating);
        }
    }

    static string getString(in Value v)
    {
        return v.str;
    }

    static size_t arrayLength(in Value v)
    {
        return v.arrayNoRef.length;
    }

    static const(Value) arrayAt(in Value v, size_t index)
    {
        return v.arrayNoRef[index];
    }

    static size_t objectLength(in Value v)
    {
        return v.objectNoRef.length;
    }

    static const(Value)* objectGet(in Value v, string key) @trusted
    {
        // The AA returned by objectNoRef is a heap handle; a member pointer
        // stays valid after the parameter copy goes out of scope.
        return key in v.objectNoRef;
    }

    static int objectEach(in Value v, scope int delegate(string key, in Value val) @safe dg)
    {
        foreach (key, ref val; v.objectNoRef)
            if (auto r = dg(key, val))
                return r;
        return 0;
    }
}

static assert(isJsonAdapter!StdJsonAdapter);

/// Adapter for the library's own `JsonNode` (used internally for meta-schema
/// validation of generated schemas, and available to callers).
struct JsonNodeAdapter
{
    alias Value = JsonNode;

    static JsonKind kindOf(in Value v) pure nothrow
    {
        alias K = JsonNode.Kind;
        final switch (v.kind)
        {
        case K.null_:
            return JsonKind.null_;
        case K.boolean:
            return JsonKind.boolean;
        case K.integer:
        case K.uinteger:
            return JsonKind.integer;
        case K.floating:
            return JsonKind.floating;
        case K.string_:
            return JsonKind.string_;
        case K.array:
            return JsonKind.array;
        case K.object:
            return JsonKind.object;
        }
    }

    static bool getBoolean(in Value v) pure nothrow
    {
        return v.boolean_;
    }

    static JsonNumber getNumber(in Value v) pure nothrow
    {
        alias K = JsonNode.Kind;
        switch (v.kind)
        {
        case K.integer:
            return JsonNumber.ofLong(v.integer_);
        case K.uinteger:
            return JsonNumber.ofULong(v.uinteger_);
        default:
            return JsonNumber.ofDouble(v.floating_);
        }
    }

    static string getString(in Value v) pure nothrow
    {
        return v.string_;
    }

    static size_t arrayLength(in Value v) pure nothrow
    {
        return v.array_.length;
    }

    static const(Value) arrayAt(in Value v, size_t index) pure nothrow
    {
        return v.array_[index];
    }

    static size_t objectLength(in Value v) pure nothrow
    {
        return v.members_.length;
    }

    static const(Value)* objectGet(in Value v, string key) pure nothrow @trusted
    {
        // members_ is a heap slice, so the member pointer outlives the
        // by-value parameter copy.
        foreach (ref m; v.members_)
            if (m.key == key)
                return &m.value;
        return null;
    }

    static int objectEach(in Value v, scope int delegate(string key, in Value val) @safe dg)
    {
        foreach (ref m; v.members_)
            if (auto r = dg(m.key, m.value))
                return r;
        return 0;
    }
}

static assert(isJsonAdapter!JsonNodeAdapter);

unittest // StdJsonAdapter classifies every JSON kind
{
    import std.json : parseJSON;

    alias A = StdJsonAdapter;
    assert(A.kindOf(parseJSON("null")) == JsonKind.null_);
    assert(A.kindOf(parseJSON("true")) == JsonKind.boolean);
    assert(A.kindOf(parseJSON("1")) == JsonKind.integer);
    assert(A.kindOf(parseJSON("1.5")) == JsonKind.floating);
    assert(A.kindOf(parseJSON(`"s"`)) == JsonKind.string_);
    assert(A.kindOf(parseJSON("[]")) == JsonKind.array);
    assert(A.kindOf(parseJSON("{}")) == JsonKind.object);
}

unittest // StdJsonAdapter keeps 64-bit integer fidelity
{
    import std.json : parseJSON;

    auto big = parseJSON("9223372036854775807");
    auto n = StdJsonAdapter.getNumber(big);
    assert(n.rep == JsonNumber.Rep.signed_);
    assert(n.s == long.max);

    auto ubig = parseJSON("18446744073709551615");
    auto un = StdJsonAdapter.getNumber(ubig);
    assert(un.rep == JsonNumber.Rep.unsigned_);
    assert(un.u == ulong.max);
}

unittest // a ulong that fits in long normalizes to the signed representation
{
    import std.json : JSONValue;

    auto n = StdJsonAdapter.getNumber(JSONValue(42UL));
    assert(n.rep == JsonNumber.Rep.signed_);
    assert(n.s == 42);
}

unittest // StdJsonAdapter object access
{
    import std.json : parseJSON;

    auto v = parseJSON(`{"a":1,"b":2}`);
    assert(StdJsonAdapter.objectLength(v) == 2);
    assert(StdJsonAdapter.objectGet(v, "a") !is null);
    assert(StdJsonAdapter.objectGet(v, "zz") is null);
    int count;
    StdJsonAdapter.objectEach(v, (string k, in JSONValue val) { count++; return 0; });
    assert(count == 2);
}

unittest // StdJsonAdapter array access
{
    import std.json : parseJSON;

    auto v = parseJSON("[10,20]");
    assert(StdJsonAdapter.arrayLength(v) == 2);
    assert(StdJsonAdapter.arrayAt(v, 1).integer == 20);
}

unittest // JsonNodeAdapter mirrors the node values
{
    import jsonschema.node : parseJson;

    auto v = parseJson(`{"a":[1,2.5],"b":"x"}`);
    alias A = JsonNodeAdapter;
    assert(A.kindOf(v) == JsonKind.object);
    auto a = A.objectGet(v, "a");
    assert(a !is null && A.kindOf(*a) == JsonKind.array);
    assert(A.arrayLength(*a) == 2);
    assert(A.getNumber(A.arrayAt(*a, 0)).s == 1);
    assert(A.getNumber(A.arrayAt(*a, 1)).f == 2.5);
    assert(A.getString(*A.objectGet(v, "b")) == "x");
}
