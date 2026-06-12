/// Compile-time D-type → JSON Schema generator.
///
/// `jsonSchemaOf!T` derives a JSON Schema 2020-12 document (as a `JsonNode`)
/// from a D type. The mapping is complete and fully recursive:
///
/// - `bool` → `{type: "boolean"}`
/// - integral → `{type: "integer"}` (unsigned types additionally get `minimum: 0`)
/// - floating point → `{type: "number"}`
/// - `string` → `{type: "string"}`
/// - `enum` → `{type: "string", enum: [members…]}`
/// - arrays/slices → `{type: "array", items: …}`
/// - string-keyed associative arrays → `{type: "object", additionalProperties: …}`
/// - `struct` → `{type: "object", properties: …, required: […]}`
/// - `Nullable!T` → `{anyOf: [schema(T), {type: "null"}]}`
/// - `SumType!(A, B, …)` → `{anyOf: [schema(A), schema(B), …]}`
/// - `std.datetime`: `SysTime`/`DateTime` → string + format "date-time",
///   `Date` → "date", `TimeOfDay` → "time"
///
/// Struct types that are referenced from more than one place, or recursively,
/// are emitted once into `$defs` and referenced via `$ref`; everything else is
/// inlined. Any other type (pointers, classes, delegates, non-string AA keys)
/// is rejected with a clear `static assert`.
///
/// Render the result with `toStdJson` (std.json), `nodeToVibeJson`
/// (`jsonschema:vibe`), or `.toString` — or compile it directly with
/// `compileSchema` to validate instances against it.
module jsonschema.generate;

import jsonschema.node : JsonNode;

import std.conv : to;
import std.sumtype : isSumType;
import std.traits;
import std.typecons : Nullable;

@safe:

/// True when `T` is one of the `std.datetime` value types.
private template isStdDateTime(T)
{
    import std.datetime.date : Date, DateTime, TimeOfDay;
    import std.datetime.systime : SysTime;

    enum isStdDateTime = is(T == SysTime) || is(T == DateTime) || is(T == Date) || is(T == TimeOfDay);
}

private template stdDateTimeFormat(T)
{
    import std.datetime.date : Date, TimeOfDay;

    static if (is(T == Date))
        enum stdDateTimeFormat = "date";
    else static if (is(T == TimeOfDay))
        enum stdDateTimeFormat = "time";
    else
        enum stdDateTimeFormat = "date-time";
}

/// Generation options.
struct GeneratorSettings
{
    /// Emit `"$schema": "https://json-schema.org/draft/2020-12/schema"` at the
    /// root. Off by default: generated schemas are usually embedded (e.g. as a
    /// tool inputSchema) where the dialect is implied.
    bool emitSchemaKeyword = false;
}

/// Generate the JSON Schema for `T`.
JsonNode jsonSchemaOf(T)(GeneratorSettings settings = GeneratorSettings.init)
{
    GenContext ctx;
    countType!T(ctx, null);
    auto root = emitType!T(ctx);

    if (settings.emitSchemaKeyword)
    {
        auto doc = JsonNode.emptyObject();
        doc.set("$schema", JsonNode("https://json-schema.org/draft/2020-12/schema"));
        foreach (ref m; root.members_)
            doc.set(m.key, m.value);
        root = doc;
    }
    if (ctx.defs.members_.length)
        root.set("$defs", ctx.defs);
    return root;
}

private struct GenContext
{
    int[string] counts; // fully-qualified type name → occurrences
    bool[string] recursive;
    string[string] defNames; // fully-qualified name → $defs key
    bool[string] nameTaken;
    JsonNode defs = JsonNode.emptyObject();
    bool[string] emitting;
}

// --- pass 1: count struct occurrences and detect recursion ---

private void countType(T)(ref GenContext ctx, string[] stack)
{
    static if (isInstanceOf!(Nullable, T))
        countType!(TemplateArgsOf!T[0])(ctx, stack);
    else static if (is(T == enum) || is(T == bool) || isStdDateTime!T
            || isIntegral!T || isFloatingPoint!T || isSomeString!T)
    {
    }
    else static if (isSumType!T)
    {
        static foreach (V; TemplateArgsOf!T)
            countType!V(ctx, stack);
    }
    else static if (isAssociativeArray!T)
        countType!(ValueType!T)(ctx, stack);
    else static if (isArray!T)
        countType!(typeof(T.init[0]))(ctx, stack);
    else static if (is(T == struct))
    {
        enum fqn = fullyQualifiedName!T;
        ctx.counts[fqn] = ctx.counts.get(fqn, 0) + 1;
        foreach (frame; stack)
            if (frame == fqn)
            {
                ctx.recursive[fqn] = true;
                return;
            }
        if (ctx.counts[fqn] > 1)
            return; // fields were already counted on first encounter
        static foreach (i, field; FieldNameTuple!T)
            countType!(typeof(__traits(getMember, T, field)))(ctx, stack ~ fqn);
    }
    else
        static assert(false, "jsonSchemaOf: unsupported type " ~ T.stringof
                ~ " (only scalars, enums, std.datetime, strings, arrays,"
                ~ " string-keyed associative arrays, structs, Nullable, and"
                ~ " SumType are supported)");
}

// --- pass 2: emit ---

private JsonNode emitType(T)(ref GenContext ctx)
{
    static if (isInstanceOf!(Nullable, T))
    {
        // Accepts the inner type or an explicit JSON null; optionality of the
        // enclosing object member is handled via `required`.
        auto nullSchema = JsonNode.emptyObject();
        nullSchema.set("type", JsonNode("null"));
        auto variants = JsonNode.emptyArray();
        variants.append(emitType!(TemplateArgsOf!T[0])(ctx));
        variants.append(nullSchema);
        auto s = JsonNode.emptyObject();
        s.set("anyOf", variants);
        return s;
    }
    else static if (is(T == bool))
        return typeSchema("boolean");
    else static if (is(T == enum))
    {
        auto s = typeSchema("string");
        auto e = JsonNode.emptyArray();
        static foreach (m; EnumMembers!T)
            e.append(JsonNode(to!string(m)));
        s.set("enum", e);
        return s;
    }
    else static if (isStdDateTime!T)
    {
        auto s = typeSchema("string");
        s.set("format", JsonNode(stdDateTimeFormat!T));
        return s;
    }
    else static if (isIntegral!T)
    {
        auto s = typeSchema("integer");
        static if (isUnsigned!T)
            s.set("minimum", JsonNode(0L));
        return s;
    }
    else static if (isFloatingPoint!T)
        return typeSchema("number");
    else static if (isSomeString!T)
        return typeSchema("string");
    else static if (isSumType!T)
    {
        auto variants = JsonNode.emptyArray();
        static foreach (V; TemplateArgsOf!T)
            variants.append(emitType!V(ctx));
        auto s = JsonNode.emptyObject();
        s.set("anyOf", variants);
        return s;
    }
    else static if (isAssociativeArray!T)
    {
        static assert(isSomeString!(KeyType!T),
                "jsonSchemaOf: unsupported associative-array key type "
                ~ KeyType!T.stringof ~ " in " ~ T.stringof ~ " (JSON object keys must be strings)");
        auto s = typeSchema("object");
        s.set("additionalProperties", emitType!(ValueType!T)(ctx));
        return s;
    }
    else static if (isArray!T)
    {
        auto s = typeSchema("array");
        s.set("items", emitType!(typeof(T.init[0]))(ctx));
        return s;
    }
    else static if (is(T == struct))
    {
        enum fqn = fullyQualifiedName!T;
        const needsDef = ctx.counts.get(fqn, 0) > 1 || ctx.recursive.get(fqn, false);
        if (!needsDef)
            return emitStructBody!T(ctx);

        string name;
        if (auto p = fqn in ctx.defNames)
            name = *p;
        else
        {
            // Prefer the bare type name; disambiguate identically-named types
            // from different scopes with a numeric suffix.
            name = __traits(identifier, T);
            int n = 1;
            while (name in ctx.nameTaken)
                name = __traits(identifier, T) ~ (++n).to!string;
            ctx.nameTaken[name] = true;
            ctx.defNames[fqn] = name;
        }
        if (ctx.defs.get(name) is null && fqn !in ctx.emitting)
        {
            ctx.emitting[fqn] = true;
            // Reserve the slot first so mutual recursion terminates, then
            // fill it with the real body.
            ctx.defs.set(name, JsonNode.emptyObject());
            auto body_ = emitStructBody!T(ctx);
            ctx.defs.set(name, body_);
            ctx.emitting.remove(fqn);
        }
        auto s = JsonNode.emptyObject();
        s.set("$ref", JsonNode("#/$defs/" ~ name));
        return s;
    }
    else
        static assert(false, "jsonSchemaOf: unsupported type " ~ T.stringof);
}

private JsonNode typeSchema(string typeName) pure nothrow
{
    auto s = JsonNode.emptyObject();
    s.set("type", JsonNode(typeName));
    return s;
}

private JsonNode emitStructBody(T)(ref GenContext ctx)
{
    auto s = typeSchema("object");
    auto props = JsonNode.emptyObject();
    auto required = JsonNode.emptyArray();
    static foreach (i, field; FieldNameTuple!T)
    {
        {
            alias FT = typeof(__traits(getMember, T, field));
            auto prop = emitType!FT(ctx);
            applyFieldFacets!(T, field)(prop);
            props.set(field, prop);
            static if (!isInstanceOf!(Nullable, FT) && !hasFieldDefault!(T, i))
                required.append(JsonNode(field));
        }
    }
    s.set("properties", props);
    if (required.array_.length)
        s.set("required", required);
    return s;
}

/// Emit facet UDAs from a compile-time sequence (e.g. `__traits(getAttributes, …)`)
/// onto a property schema. Unrecognized UDA types are ignored.
package void applyUdaFacets(udas...)(ref JsonNode prop)
{
    import jsonschema.attributes;

    static foreach (uda; udas)
    {
        static if (is(typeof(uda) == minimum))
            prop.set("minimum", numberNode(uda.value));
        else static if (is(typeof(uda) == maximum))
            prop.set("maximum", numberNode(uda.value));
        else static if (is(typeof(uda) == title))
            prop.set("title", JsonNode(uda.value));
        else static if (is(typeof(uda) == format))
            prop.set("format", JsonNode(uda.value));
        else static if (is(typeof(uda) == minLength))
            prop.set("minLength", JsonNode(cast(long) uda.value));
        else static if (is(typeof(uda) == maxLength))
            prop.set("maxLength", JsonNode(cast(long) uda.value));
        else static if (is(typeof(uda) == pattern))
            prop.set("pattern", JsonNode(uda.value));
        else static if (is(typeof(uda) == minItems))
            prop.set("minItems", JsonNode(cast(long) uda.value));
        else static if (is(typeof(uda) == maxItems))
            prop.set("maxItems", JsonNode(cast(long) uda.value));
        else static if (isInstanceOf!(SchemaDefault, typeof(uda)))
            prop.set("default", schemaDefaultNode(uda.value));
    }
}

/// A numeric facet value serializes as an integer when it is whole, so
/// `@minimum(1)` emits `1` rather than `1.0`.
private JsonNode numberNode(double v) pure nothrow
{
    import std.math : floor, isFinite;

    if (isFinite(v) && v == floor(v) && v >= -9.0e15 && v <= 9.0e15)
        return JsonNode(cast(long) v);
    return JsonNode(v);
}

private void applyFieldFacets(T, string field)(ref JsonNode prop)
{
    import jsonschema.attributes : fieldDescription;

    alias member = __traits(getMember, T, field);

    static if (hasUDA!(member, fieldDescription))
        prop.set("description", JsonNode(getUDAs!(member, fieldDescription)[0].value));
    applyUdaFacets!(__traits(getAttributes, __traits(getMember, T, field)))(prop);
}

/// Serialize a `@schemaDefault` value into its JSON form. An enum value
/// becomes its member name, matching the enum's string schema.
private JsonNode schemaDefaultNode(V)(V value)
{
    static if (is(V == enum))
        return JsonNode(to!string(value));
    else static if (is(V == bool))
        return JsonNode(value);
    else static if (isIntegral!V)
        return JsonNode(cast(long) value);
    else static if (isFloatingPoint!V)
        return JsonNode(cast(double) value);
    else static if (isSomeString!V)
        return JsonNode(value);
    else
        static assert(false,
                "schemaDefaultNode: unsupported @schemaDefault value type " ~ V.stringof);
}

/// True when field `i` of struct `T` has a declared default, making it
/// optional. A `@schemaDefault` UDA always counts; otherwise the declared
/// initializer must differ from the type's `.init` (D exposes no trait
/// distinguishing `int x = 0;` from `int x;`, so `@schemaDefault` is the
/// unambiguous way to mark such a field optional).
private template hasFieldDefault(T, size_t i)
{
    import jsonschema.attributes : SchemaDefault;

    alias FT = typeof(T.tupleof[i]);
    static if (hasUDA!(T.tupleof[i], SchemaDefault))
        enum hasFieldDefault = true;
    else
    {
        enum readableAtCompileTime = __traits(compiles, {
                enum d = T.init.tupleof[i];
            });
        static if (readableAtCompileTime)
            enum hasFieldDefault = T.init.tupleof[i] != FT.init;
        else
            enum hasFieldDefault = false;
    }
}

// --- tests ---

version (unittest)
{
    import jsonschema.compiler : compileSchema;
    import jsonschema.ir : OutputFormat;
    import jsonschema.node : parseJson;
    import std.meta : AliasSeq;
}

unittest  // scalar schemas
{
    assert(jsonSchemaOf!int.get("type").string_ == "integer");
    assert(jsonSchemaOf!double.get("type").string_ == "number");
    assert(jsonSchemaOf!bool.get("type").string_ == "boolean");
    assert(jsonSchemaOf!string.get("type").string_ == "string");
}

unittest  // unsigned integers carry minimum 0
{
    auto s = jsonSchemaOf!uint;
    assert(s.get("type").string_ == "integer");
    assert(s.get("minimum").integer_ == 0);
    assert(jsonSchemaOf!int.get("minimum") is null);
}

unittest  // enum becomes a string with members
{
    enum Color
    {
        red,
        green,
        blue
    }

    auto s = jsonSchemaOf!Color;
    assert(s.get("type").string_ == "string");
    assert(s.get("enum").array_.length == 3);
    assert(s.get("enum").array_[0].string_ == "red");
}

unittest  // arrays carry an items schema
{
    auto s = jsonSchemaOf!(int[]);
    assert(s.get("type").string_ == "array");
    assert(s.get("items").get("type").string_ == "integer");
}

unittest  // structs become objects with properties and required
{
    struct Point
    {
        int x;
        int y;
        Nullable!string label;
    }

    auto s = jsonSchemaOf!Point;
    assert(s.get("type").string_ == "object");
    assert(s.get("properties").get("x").get("type").string_ == "integer");
    auto label = s.get("properties").get("label");
    assert(label.get("anyOf") !is null);
    assert(label.get("anyOf").array_[0].get("type").string_ == "string");
    assert(label.get("anyOf").array_[1].get("type").string_ == "null");
    assert(s.get("required").array_.length == 2);
}

unittest  // Nullable emits anyOf with the inner schema and null
{
    auto s = jsonSchemaOf!(Nullable!int);
    assert(s.get("anyOf").array_.length == 2);
    assert(s.get("anyOf").array_[0].get("type").string_ == "integer");
    assert(s.get("anyOf").array_[1].get("type").string_ == "null");
}

unittest  // SumType maps to anyOf over the variant schemas
{
    import std.sumtype : SumType;

    struct Box
    {
        int n;
    }

    auto s = jsonSchemaOf!(SumType!(int, string, Box));
    assert(s.get("anyOf").array_.length == 3);
    assert(s.get("anyOf").array_[2].get("type").string_ == "object");
}

unittest  // associative arrays map to additionalProperties
{
    auto s = jsonSchemaOf!(int[string]);
    assert(s.get("type").string_ == "object");
    assert(s.get("additionalProperties").get("type").string_ == "integer");
}

unittest  // std.datetime types map to formatted strings
{
    import std.datetime.date : Date, DateTime, TimeOfDay;
    import std.datetime.systime : SysTime;

    assert(jsonSchemaOf!SysTime.get("format").string_ == "date-time");
    assert(jsonSchemaOf!DateTime.get("format").string_ == "date-time");
    assert(jsonSchemaOf!Date.get("format").string_ == "date");
    assert(jsonSchemaOf!TimeOfDay.get("format").string_ == "time");
}

unittest  // a recursive struct goes to $defs with a $ref
{
    static struct Tree
    {
        int value;
        Tree[] children;
    }

    auto s = jsonSchemaOf!Tree;
    assert(s.get("$ref") !is null);
    assert(s.get("$ref").string_ == "#/$defs/Tree");
    auto def = s.get("$defs").get("Tree");
    assert(def !is null);
    assert(def.get("properties").get("children").get("items").get("$ref").string_ == "#/$defs/Tree");
}

unittest  // a struct used in two places is shared via $defs
{
    static struct Leaf
    {
        int v;
    }

    static struct Pair
    {
        Leaf left;
        Leaf right;
    }

    auto s = jsonSchemaOf!Pair;
    assert(s.get("properties").get("left").get("$ref").string_ == "#/$defs/Leaf");
    assert(s.get("properties").get("right").get("$ref").string_ == "#/$defs/Leaf");
    assert(s.get("$defs").get("Leaf").get("type").string_ == "object");
}

unittest  // a single-use struct stays inline (no $defs)
{
    static struct Inner
    {
        int v;
    }

    static struct Outer
    {
        Inner one;
    }

    auto s = jsonSchemaOf!Outer;
    assert(s.get("$defs") is null);
    assert(s.get("properties").get("one").get("type").string_ == "object");
}

unittest  // facet UDAs are emitted onto property schemas
{
    import jsonschema.attributes;

    static struct Form
    {
        @minimum(1) @maximum(100) @title("Count") @fieldDescription("how many") int count;
        @format("email") @minLength(3) @maxLength(64) @pattern("^.+@.+$") string addr;
        @minItems(1) @maxItems(5) int[] picks;
        @schemaDefault(10) int limit;
    }

    auto s = jsonSchemaOf!Form;
    auto count = s.get("properties").get("count");
    assert(count.get("minimum").integer_ == 1);
    assert(count.get("maximum").integer_ == 100);
    assert(count.get("title").string_ == "Count");
    assert(count.get("description").string_ == "how many");
    auto addr = s.get("properties").get("addr");
    assert(addr.get("format").string_ == "email");
    assert(addr.get("minLength").integer_ == 3);
    assert(addr.get("maxLength").integer_ == 64);
    assert(addr.get("pattern").string_ == "^.+@.+$");
    auto picks = s.get("properties").get("picks");
    assert(picks.get("minItems").integer_ == 1);
    assert(picks.get("maxItems").integer_ == 5);
    assert(s.get("properties").get("limit").get("default").integer_ == 10);
    // limit carries @schemaDefault, so only count/addr/picks are required.
    assert(s.get("required").array_.length == 3);
}

unittest  // fields with declared defaults are optional
{
    static struct Options
    {
        int required_;
        int limit = 10;
        string mode = "fast";
    }

    auto s = jsonSchemaOf!Options;
    assert(s.get("required").array_.length == 1);
    assert(s.get("required").array_[0].string_ == "required_");
}

unittest  // @schemaDefault marks a field optional even at .init value
{
    import jsonschema.attributes : schemaDefault;

    static struct Form
    {
        @schemaDefault(0) int limit = 0;
        @schemaDefault(false) bool flag;
    }

    auto s = jsonSchemaOf!Form;
    assert(s.get("required") is null);
}

unittest  // @schemaDefault on an enum field emits the member name
{
    import jsonschema.attributes : schemaDefault;

    enum Mode
    {
        fast,
        slow
    }

    static struct Form
    {
        @schemaDefault(Mode.slow) Mode mode;
    }

    auto s = jsonSchemaOf!Form;
    assert(s.get("properties").get("mode").get("default").string_ == "slow");
}

unittest  // unsupported types are rejected at compile time
{
    assert(!__traits(compiles, jsonSchemaOf!(int*)));
    assert(!__traits(compiles, jsonSchemaOf!(void delegate())));
    assert(!__traits(compiles, jsonSchemaOf!(string[int])));
}

unittest  // generated schemas validate instances via the validator
{
    static struct Item
    {
        string name;
        int qty;
    }

    auto v = compileSchema(jsonSchemaOf!(Item[string]));
    assert(v.validate(parseJson(`{"a": {"name": "x", "qty": 1}}`)).valid);
    assert(!v.validate(parseJson(`{"a": {"name": "x"}}`)).valid);
    assert(!v.validate(parseJson(`{"a": {"name": "x", "qty": "no"}}`)).valid);
}

unittest  // recursive generated schemas validate recursive instances
{
    static struct Tree
    {
        int value;
        Tree[] children;
    }

    auto v = compileSchema(jsonSchemaOf!Tree);
    assert(v.validate(parseJson(`{"value": 1, "children": [{"value": 2, "children": []}]}`)).valid);
    assert(!v.validate(parseJson(`{"value": 1, "children": [{"children": []}]}`)).valid);
}

unittest  // every generated schema conforms to the 2020-12 meta-schema
{
    import std.sumtype : SumType;
    import std.datetime.systime : SysTime;
    import jsonschema.attributes;

    static struct Leaf
    {
        double v;
    }

    static struct Tree
    {
        int value;
        @minItems(0) Tree[] children;
        Leaf[string] leaves;
        Nullable!Leaf annotation;
    }

    static struct Big
    {
        Tree root;
        SumType!(int, string, Leaf) mixed;
        SysTime when;
        @schemaDefault(5) @minimum(0) @maximum(10) int level;
    }

    auto meta = compileSchema(`{"$ref": "https://json-schema.org/draft/2020-12/schema"}`);
    static foreach (T; AliasSeq!(int, uint, double, bool, string, int[],
            int[string], Nullable!int, Leaf, Tree, Big))
    {
        {
            auto generated = jsonSchemaOf!T;
            auto r = meta.validate(generated);
            assert(r.valid, T.stringof ~ " schema fails meta-validation: " ~ generated.toString);
            // And with the explicit $schema keyword at the root.
            auto withDialect = jsonSchemaOf!T(GeneratorSettings(true));
            assert(meta.validate(withDialect).valid);
        }
    }
}
