/// Internal JSON document representation.
///
/// Every schema document, whatever JSON type it arrives as (`std.json.JSONValue`,
/// `vibe.data.json.Json`, or raw text), is normalized into `JsonNode` before
/// compilation. `JsonNode` preserves object member order, distinguishes signed,
/// unsigned and floating-point numbers (so 64-bit integers never round-trip
/// through a double), and is fully self-contained — no dependency beyond phobos.
module jsonschema.node;

import std.conv : to;

@safe:

/// A JSON value: null, boolean, number (signed / unsigned / floating), string,
/// array, or object with preserved member order.
struct JsonNode
{
    enum Kind
    {
        null_,
        boolean,
        integer, /// signed 64-bit
        uinteger, /// unsigned 64-bit beyond long.max
        floating,
        string_,
        array,
        object
    }

    /// One ordered object member.
    static struct Member
    {
        string key;
        JsonNode value;
    }

    Kind kind = Kind.null_;
    bool boolean_;
    long integer_;
    ulong uinteger_;
    double floating_;
    string string_;
    JsonNode[] array_;
    Member[] members_;

    this(typeof(null)) pure nothrow
    {
        kind = Kind.null_;
    }

    this(bool v) pure nothrow
    {
        kind = Kind.boolean;
        boolean_ = v;
    }

    this(long v) pure nothrow
    {
        kind = Kind.integer;
        integer_ = v;
    }

    this(int v) pure nothrow
    {
        this(cast(long) v);
    }

    this(ulong v) pure nothrow
    {
        if (v <= long.max)
        {
            kind = Kind.integer;
            integer_ = cast(long) v;
        }
        else
        {
            kind = Kind.uinteger;
            uinteger_ = v;
        }
    }

    this(double v) pure nothrow
    {
        kind = Kind.floating;
        floating_ = v;
    }

    this(string v) pure nothrow
    {
        kind = Kind.string_;
        string_ = v;
    }

    this(JsonNode[] v) pure nothrow
    {
        kind = Kind.array;
        array_ = v;
    }

    this(Member[] v) pure nothrow
    {
        kind = Kind.object;
        members_ = v;
    }

    static JsonNode emptyObject() pure nothrow
    {
        JsonNode n;
        n.kind = Kind.object;
        return n;
    }

    static JsonNode emptyArray() pure nothrow
    {
        JsonNode n;
        n.kind = Kind.array;
        return n;
    }

    bool isObject() const pure nothrow
    {
        return kind == Kind.object;
    }

    bool isArray() const pure nothrow
    {
        return kind == Kind.array;
    }

    bool isString() const pure nothrow
    {
        return kind == Kind.string_;
    }

    bool isNumber() const pure nothrow
    {
        return kind == Kind.integer || kind == Kind.uinteger || kind == Kind.floating;
    }

    bool isBoolean() const pure nothrow
    {
        return kind == Kind.boolean;
    }

    bool isNull() const pure nothrow
    {
        return kind == Kind.null_;
    }

    /// Object member lookup; null when absent or not an object.
    inout(JsonNode)* get(string key) inout pure nothrow return
    {
        if (kind != Kind.object)
            return null;
        foreach (ref m; members_)
            if (m.key == key)
                return &m.value;
        return null;
    }

    /// Set (or replace) an object member, preserving first-insertion order.
    void set(string key, JsonNode value) pure nothrow
    {
        assert(kind == Kind.object, "set() on non-object JsonNode");
        foreach (ref m; members_)
            if (m.key == key)
            {
                m.value = value;
                return;
            }
        members_ ~= Member(key, value);
    }

    /// Append to an array node.
    void append(JsonNode value) pure nothrow
    {
        assert(kind == Kind.array, "append() on non-array JsonNode");
        array_ ~= value;
    }

    /// Numeric value as a double (lossy for large integers; use the kind-specific
    /// fields for exact comparisons).
    double asDouble() const pure nothrow
    {
        final switch (kind)
        {
        case Kind.integer:
            return cast(double) integer_;
        case Kind.uinteger:
            return cast(double) uinteger_;
        case Kind.floating:
            return floating_;
        case Kind.null_:
        case Kind.boolean:
        case Kind.string_:
        case Kind.array:
        case Kind.object:
            assert(false, "asDouble() on non-number JsonNode");
        }
    }

    string toString() const pure
    {
        auto app = appender();
        return app;
    }

    private string appender() const pure
    {
        import std.array : Appender;

        Appender!string sink;
        writeJson(this, sink);
        return sink.data;
    }
}

/// Deep structural equality with JSON Schema number semantics: numbers compare
/// by mathematical value across representations (1, 1u, and 1.0 are all equal),
/// objects compare without regard to member order, arrays element-wise.
bool jsonEquals(in JsonNode a, in JsonNode b) pure nothrow
{
    alias K = JsonNode.Kind;
    if (a.isNumber && b.isNumber)
        return numbersEqual(a, b);
    if (a.kind != b.kind)
        return false;
    final switch (a.kind)
    {
    case K.null_:
        return true;
    case K.boolean:
        return a.boolean_ == b.boolean_;
    case K.string_:
        return a.string_ == b.string_;
    case K.array:
        if (a.array_.length != b.array_.length)
            return false;
        foreach (i; 0 .. a.array_.length)
            if (!jsonEquals(a.array_[i], b.array_[i]))
                return false;
        return true;
    case K.object:
        if (a.members_.length != b.members_.length)
            return false;
        foreach (ref m; a.members_)
        {
            auto other = b.get(m.key);
            if (other is null || !jsonEquals(m.value, *other))
                return false;
        }
        return true;
    case K.integer:
    case K.uinteger:
    case K.floating:
        assert(false); // handled by the isNumber branch above
    }
}

private bool numbersEqual(in JsonNode a, in JsonNode b) pure nothrow
{
    alias K = JsonNode.Kind;
    // Exact integer-to-integer comparison.
    if (a.kind == K.integer && b.kind == K.integer)
        return a.integer_ == b.integer_;
    if (a.kind == K.uinteger && b.kind == K.uinteger)
        return a.uinteger_ == b.uinteger_;
    if (a.kind == K.integer && b.kind == K.uinteger)
        return a.integer_ >= 0 && cast(ulong) a.integer_ == b.uinteger_;
    if (a.kind == K.uinteger && b.kind == K.integer)
        return b.integer_ >= 0 && cast(ulong) b.integer_ == a.uinteger_;
    // A float is involved: compare exactly against the integral side.
    if (a.kind == K.floating && b.kind == K.floating)
        return a.floating_ == b.floating_;
    const f = a.kind == K.floating ? a.floating_ : b.floating_;
    const other = a.kind == K.floating ? b : a;
    import std.math : floor, isFinite;

    if (!isFinite(f) || f != floor(f))
        return false;
    if (other.kind == K.integer)
        // long.max + 1 as a double is exactly 2^63, so the boundary test is exact.
        return f >= -9223372036854775808.0 && f < 9223372036854775808.0
            && cast(long) f == other.integer_;
    return f >= 0.0 && f < 18446744073709551616.0 && cast(ulong) f == other.uinteger_;
}

/// Thrown when JSON text cannot be parsed.
class JsonParseException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, file, line);
    }
}

/// Parse JSON text into a `JsonNode`. Object member order is preserved
/// (duplicate keys: the last value wins, matching std.json and vibe.data.json).
/// Integer literals that fit a long parse as `integer`, those that fit only a
/// ulong as `uinteger`, anything larger (or with fraction/exponent) as `floating`.
JsonNode parseJson(string text) pure
{
    size_t pos = 0;
    auto root = parseValue(text, pos);
    skipWs(text, pos);
    if (pos != text.length)
        throw new JsonParseException("trailing content at offset " ~ pos.to!string);
    return root;
}

private void skipWs(string s, ref size_t p) pure nothrow
{
    while (p < s.length && (s[p] == ' ' || s[p] == '\t' || s[p] == '\n' || s[p] == '\r'))
        p++;
}

private void expect(string s, ref size_t p, char c) pure
{
    if (p >= s.length || s[p] != c)
        throw new JsonParseException("expected '" ~ c ~ "' at offset " ~ p.to!string);
    p++;
}

private JsonNode parseValue(string s, ref size_t p) pure
{
    skipWs(s, p);
    if (p >= s.length)
        throw new JsonParseException("unexpected end of input");
    switch (s[p])
    {
    case '{':
        return parseObject(s, p);
    case '[':
        return parseArray(s, p);
    case '"':
        return JsonNode(parseString(s, p));
    case 't':
        parseLiteral(s, p, "true");
        return JsonNode(true);
    case 'f':
        parseLiteral(s, p, "false");
        return JsonNode(false);
    case 'n':
        parseLiteral(s, p, "null");
        return JsonNode(null);
    default:
        return parseNumber(s, p);
    }
}

private void parseLiteral(string s, ref size_t p, string lit) pure
{
    if (p + lit.length > s.length || s[p .. p + lit.length] != lit)
        throw new JsonParseException("invalid literal at offset " ~ p.to!string);
    p += lit.length;
}

private JsonNode parseObject(string s, ref size_t p) pure
{
    p++; // '{'
    auto node = JsonNode.emptyObject();
    skipWs(s, p);
    if (p < s.length && s[p] == '}')
    {
        p++;
        return node;
    }
    while (true)
    {
        skipWs(s, p);
        if (p >= s.length || s[p] != '"')
            throw new JsonParseException("expected object key at offset " ~ p.to!string);
        const key = parseString(s, p);
        skipWs(s, p);
        expect(s, p, ':');
        node.set(key, parseValue(s, p));
        skipWs(s, p);
        if (p >= s.length)
            throw new JsonParseException("unterminated object");
        if (s[p] == ',')
        {
            p++;
            continue;
        }
        expect(s, p, '}');
        return node;
    }
}

private JsonNode parseArray(string s, ref size_t p) pure
{
    p++; // '['
    auto node = JsonNode.emptyArray();
    skipWs(s, p);
    if (p < s.length && s[p] == ']')
    {
        p++;
        return node;
    }
    while (true)
    {
        node.append(parseValue(s, p));
        skipWs(s, p);
        if (p >= s.length)
            throw new JsonParseException("unterminated array");
        if (s[p] == ',')
        {
            p++;
            continue;
        }
        expect(s, p, ']');
        return node;
    }
}

private string parseString(string s, ref size_t p) pure
{
    import std.array : Appender;
    import std.utf : encode;

    p++; // opening quote
    Appender!string sink;
    while (true)
    {
        if (p >= s.length)
            throw new JsonParseException("unterminated string");
        const c = s[p];
        if (c == '"')
        {
            p++;
            return sink.data;
        }
        if (c == '\\')
        {
            p++;
            if (p >= s.length)
                throw new JsonParseException("unterminated escape");
            switch (s[p])
            {
            case '"':
                sink.put('"');
                break;
            case '\\':
                sink.put('\\');
                break;
            case '/':
                sink.put('/');
                break;
            case 'b':
                sink.put('\b');
                break;
            case 'f':
                sink.put('\f');
                break;
            case 'n':
                sink.put('\n');
                break;
            case 'r':
                sink.put('\r');
                break;
            case 't':
                sink.put('\t');
                break;
            case 'u':
                p++;
                uint cp = parseHex4(s, p);
                // Combine a surrogate pair into one code point.
                if (cp >= 0xD800 && cp <= 0xDBFF && p + 1 < s.length
                        && s[p] == '\\' && s[p + 1] == 'u')
                {
                    size_t save = p;
                    p += 2;
                    const lo = parseHex4(s, p);
                    if (lo >= 0xDC00 && lo <= 0xDFFF)
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    else
                        p = save; // not a low surrogate; leave for next iteration
                }
                if (cp >= 0xD800 && cp <= 0xDFFF)
                    cp = 0xFFFD; // unpaired surrogate
                char[4] buf;
                const len = encode(buf, cast(dchar) cp);
                sink.put(buf[0 .. len]);
                continue; // p already advanced past the hex digits
            default:
                throw new JsonParseException("invalid escape at offset " ~ p.to!string);
            }
            p++;
            continue;
        }
        if (c < 0x20)
            throw new JsonParseException("unescaped control character at offset " ~ p.to!string);
        sink.put(c);
        p++;
    }
}

private uint parseHex4(string s, ref size_t p) pure
{
    if (p + 4 > s.length)
        throw new JsonParseException("truncated \\u escape");
    uint v = 0;
    foreach (i; 0 .. 4)
    {
        const c = s[p + i];
        uint d;
        if (c >= '0' && c <= '9')
            d = c - '0';
        else if (c >= 'a' && c <= 'f')
            d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F')
            d = c - 'A' + 10;
        else
            throw new JsonParseException("invalid \\u escape at offset " ~ p.to!string);
        v = (v << 4) | d;
    }
    p += 4;
    return v;
}

private JsonNode parseNumber(string s, ref size_t p) pure
{
    const start = p;
    if (p < s.length && s[p] == '-')
        p++;
    bool isFloat = false;
    while (p < s.length)
    {
        const c = s[p];
        if (c >= '0' && c <= '9')
            p++;
        else if (c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-')
        {
            isFloat = isFloat || c == '.' || c == 'e' || c == 'E';
            p++;
        }
        else
            break;
    }
    const tok = s[start .. p];
    if (tok.length == 0 || tok == "-")
        throw new JsonParseException("invalid number at offset " ~ start.to!string);
    if (!isFloat)
    {
        import std.conv : ConvException, ConvOverflowException;

        try
            return JsonNode(tok.to!long);
        catch (ConvOverflowException)
        {
            try
                return JsonNode(tok.to!ulong);
            catch (ConvException)
            {
            }
        }
        catch (ConvException e)
            throw new JsonParseException("invalid number '" ~ tok ~ "'");
    }
    import std.conv : ConvException;

    try
        return JsonNode(tok.to!double);
    catch (ConvException e)
        throw new JsonParseException("invalid number '" ~ tok ~ "'");
}

/// Serialize a `JsonNode` to compact JSON text (object member order preserved).
void writeJson(Sink)(in JsonNode n, ref Sink sink) pure
{
    alias K = JsonNode.Kind;
    final switch (n.kind)
    {
    case K.null_:
        sink.put("null");
        break;
    case K.boolean:
        sink.put(n.boolean_ ? "true" : "false");
        break;
    case K.integer:
        sink.put(n.integer_.to!string);
        break;
    case K.uinteger:
        sink.put(n.uinteger_.to!string);
        break;
    case K.floating:
        writeDouble(n.floating_, sink);
        break;
    case K.string_:
        writeJsonString(n.string_, sink);
        break;
    case K.array:
        sink.put('[');
        foreach (i, ref e; n.array_)
        {
            if (i)
                sink.put(',');
            writeJson(e, sink);
        }
        sink.put(']');
        break;
    case K.object:
        sink.put('{');
        foreach (i, ref m; n.members_)
        {
            if (i)
                sink.put(',');
            writeJsonString(m.key, sink);
            sink.put(':');
            writeJson(m.value, sink);
        }
        sink.put('}');
        break;
    }
}

private void writeDouble(Sink)(double v, ref Sink sink) pure
{
    import std.math : floor, isFinite;
    import std.format : formattedWrite;

    if (isFinite(v) && v == floor(v) && v >= -9.0e15 && v <= 9.0e15)
    {
        // An integral double serializes with a trailing ".0"-free integer form
        // plus no exponent, but must stay distinguishable as a number; emit the
        // shortest integer text (JSON has no int/float distinction on the wire).
        sink.formattedWrite("%d", cast(long) v);
        return;
    }
    sink.formattedWrite("%.17g", v);
}

private void writeJsonString(Sink)(string s, ref Sink sink) pure
{
    sink.put('"');
    foreach (char c; s)
    {
        switch (c)
        {
        case '"':
            sink.put(`\"`);
            break;
        case '\\':
            sink.put(`\\`);
            break;
        case '\b':
            sink.put(`\b`);
            break;
        case '\f':
            sink.put(`\f`);
            break;
        case '\n':
            sink.put(`\n`);
            break;
        case '\r':
            sink.put(`\r`);
            break;
        case '\t':
            sink.put(`\t`);
            break;
        default:
            if (c < 0x20)
            {
                import std.format : formattedWrite;

                sink.formattedWrite("\\u%04x", cast(uint) c);
            }
            else
                sink.put(c);
        }
    }
    sink.put('"');
}

// --- std.json conversion (the built-in adapter's JSON type) ---

import std.json : JSONValue, JSONType;

/// Convert a `std.json.JSONValue` into the internal representation.
JsonNode fromStdJson(in JSONValue v)
{
    final switch (v.type)
    {
    case JSONType.null_:
        return JsonNode(null);
    case JSONType.true_:
        return JsonNode(true);
    case JSONType.false_:
        return JsonNode(false);
    case JSONType.integer:
        return JsonNode(v.integer);
    case JSONType.uinteger:
        return JsonNode(v.uinteger);
    case JSONType.float_:
        return JsonNode(v.floating);
    case JSONType.string:
        return JsonNode(v.str);
    case JSONType.array:
        auto n = JsonNode.emptyArray();
        foreach (ref e; v.arrayNoRef)
            n.append(fromStdJson(e));
        return n;
    case JSONType.object:
        // std.json objects are hash-ordered; schema semantics never depend on
        // member order, so the AA iteration order is acceptable here.
        auto n = JsonNode.emptyObject();
        foreach (key, ref val; v.objectNoRef)
            n.set(key, fromStdJson(val));
        return n;
    }
}

/// Render the internal representation as a `std.json.JSONValue`.
JSONValue toStdJson(in JsonNode n)
{
    alias K = JsonNode.Kind;
    final switch (n.kind)
    {
    case K.null_:
        return JSONValue(null);
    case K.boolean:
        return JSONValue(n.boolean_);
    case K.integer:
        return JSONValue(n.integer_);
    case K.uinteger:
        return JSONValue(n.uinteger_);
    case K.floating:
        return JSONValue(n.floating_);
    case K.string_:
        return JSONValue(n.string_);
    case K.array:
        JSONValue[] arr;
        arr.reserve(n.array_.length);
        foreach (ref e; n.array_)
            arr ~= toStdJson(e);
        return JSONValue(arr);
    case K.object:
        JSONValue[string] obj;
        foreach (ref m; n.members_)
            obj[m.key] = toStdJson(m.value);
        return JSONValue(obj);
    }
}

unittest // parse scalars
{
    assert(parseJson("null").isNull);
    assert(parseJson("true").boolean_ == true);
    assert(parseJson("false").boolean_ == false);
    assert(parseJson(`"hi"`).string_ == "hi");
}

unittest // parse integers stay exact (no double round-trip)
{
    auto n = parseJson("9223372036854775807");
    assert(n.kind == JsonNode.Kind.integer);
    assert(n.integer_ == long.max);
}

unittest // parse a ulong-range integer
{
    auto n = parseJson("18446744073709551615");
    assert(n.kind == JsonNode.Kind.uinteger);
    assert(n.uinteger_ == ulong.max);
}

unittest // an integer beyond ulong falls back to floating
{
    auto n = parseJson("98249283749234923498293171823948729348710298301928331");
    assert(n.kind == JsonNode.Kind.floating);
}

unittest // parse floats
{
    auto n = parseJson("1.5e2");
    assert(n.kind == JsonNode.Kind.floating);
    assert(n.floating_ == 150.0);
}

unittest // parse negative numbers
{
    assert(parseJson("-42").integer_ == -42);
    assert(parseJson("-1.5").floating_ == -1.5);
}

unittest // object member order is preserved
{
    auto n = parseJson(`{"z":1,"a":2,"m":3}`);
    assert(n.members_.length == 3);
    assert(n.members_[0].key == "z");
    assert(n.members_[1].key == "a");
    assert(n.members_[2].key == "m");
}

unittest // duplicate object keys: last wins
{
    auto n = parseJson(`{"a":1,"a":2}`);
    assert(n.members_.length == 1);
    assert(n.members_[0].value.integer_ == 2);
}

unittest // nested arrays and objects
{
    auto n = parseJson(`{"a":[1,{"b":null}],"c":{}}`);
    assert(n.get("a").array_.length == 2);
    assert(n.get("a").array_[1].get("b").isNull);
    assert(n.get("c").isObject);
}

unittest // string escapes
{
    assert(parseJson(`"a\nb"`).string_ == "a\nb");
    assert(parseJson(`"A"`).string_ == "A");
    assert(parseJson(`"\""`).string_ == `"`);
}

unittest // surrogate pair escape decodes to one code point
{
    assert(parseJson(`"😀"`).string_ == "\U0001F600");
}

unittest // parse errors throw
{
    import std.exception : assertThrown;

    assertThrown!JsonParseException(parseJson(""));
    assertThrown!JsonParseException(parseJson("{"));
    assertThrown!JsonParseException(parseJson("[1,]2"));
    assertThrown!JsonParseException(parseJson("tru"));
}

unittest // trailing content rejected
{
    import std.exception : assertThrown;

    assertThrown!JsonParseException(parseJson("1 2"));
}

unittest // jsonEquals: numbers compare across representations
{
    assert(jsonEquals(JsonNode(1L), JsonNode(1.0)));
    assert(jsonEquals(JsonNode(1.0), JsonNode(1L)));
    assert(!jsonEquals(JsonNode(1L), JsonNode(1.5)));
}

unittest // jsonEquals: large integers compare exactly, not via double
{
    // 2^53 and 2^53+1 collapse onto the same double; exact comparison must differ.
    assert(!jsonEquals(JsonNode(9007199254740993L), JsonNode(9007199254740992L)));
    assert(jsonEquals(JsonNode(9007199254740993L), JsonNode(9007199254740993L)));
}

unittest // jsonEquals: integral double equals the matching long beyond int range
{
    assert(jsonEquals(JsonNode(1.0e15), JsonNode(1_000_000_000_000_000L)));
}

unittest // jsonEquals: objects ignore member order
{
    auto a = parseJson(`{"x":1,"y":2}`);
    auto b = parseJson(`{"y":2,"x":1}`);
    assert(jsonEquals(a, b));
}

unittest // jsonEquals: arrays are order-sensitive
{
    assert(!jsonEquals(parseJson("[1,2]"), parseJson("[2,1]")));
    assert(jsonEquals(parseJson("[1,2]"), parseJson("[1,2]")));
}

unittest // jsonEquals: distinct kinds are unequal
{
    assert(!jsonEquals(JsonNode(null), JsonNode(false)));
    assert(!jsonEquals(JsonNode("1"), JsonNode(1L)));
    assert(!jsonEquals(parseJson("[]"), parseJson("{}")));
}

unittest // round-trip through serialization
{
    const src = `{"a":[1,2.5,"x",null,true],"b":{"c":-7}}`;
    auto n = parseJson(src);
    assert(jsonEquals(parseJson(n.toString), n));
}

unittest // std.json round-trip preserves values
{
    import std.json : parseJSON;

    auto sj = parseJSON(`{"a":[1,"two",3.5,null,true],"b":{"c":18446744073709551615}}`);
    auto n = fromStdJson(sj);
    assert(n.get("b").get("c").kind == JsonNode.Kind.uinteger);
    auto back = toStdJson(n);
    assert(fromStdJson(back).jsonEquals(n));
}

unittest // set replaces in place, preserving order
{
    auto n = parseJson(`{"a":1,"b":2}`);
    n.set("a", JsonNode(9L));
    assert(n.members_[0].key == "a");
    assert(n.members_[0].value.integer_ == 9);
}
