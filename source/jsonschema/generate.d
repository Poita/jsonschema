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
import std.meta : staticIndexOf;
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

    /// Inline every subschema instead of emitting shared/repeated struct types
    /// into `$defs` and referencing them with `$ref`. Default false (refs).
    /// Modeled on Rust schemars' `inline_subschemas`.
    bool inlineSubschemas = false;
}

/// Generate the JSON Schema for `T` with runtime-known settings.
///
/// Returns a `JsonNode` (the vibe-free base representation). Rendering to a
/// `std.json.JSONValue` is a separate, explicit step via `toStdJson`; in the
/// `jsonschema:vibe` subpackage use `nodeToVibeJson` for `vibe.data.json.Json`.
/// `JsonNode.toString` yields compact JSON text directly.
///
/// With `settings.inlineSubschemas` set, struct types are expanded inline at
/// every use site and the document contains no `$defs`/`$ref` — for consumers
/// that don't follow `$ref` inside an embedded schema. A directly or mutually
/// recursive type cannot be inlined; requesting it throws.
///
/// Use this overload only when `settings` is not known until runtime. When the
/// settings are compile-time constants, prefer the compile-time-settings
/// overload `jsonSchemaOf!(T, settings)()`: it is otherwise identical but
/// rejects the recursive-inline case with a `static assert` at compile time
/// rather than throwing at runtime.
JsonNode jsonSchemaOf(T)(GeneratorSettings settings = GeneratorSettings.init)
{
    enum recName = inlineRecursionName!T;

    GenContext ctx;
    JsonNode root;
    if (settings.inlineSubschemas)
    {
        // The inline walk is only instantiated for types that can actually be
        // inlined; a recursive type takes the runtime branch below instead, so
        // it never reaches `emitTypeInline` and `jsonSchemaOf!T` still compiles
        // in the default mode.
        static if (recName.length == 0)
            root = emitTypeInline!T();
        else
            assert(false, "jsonSchemaOf: cannot inline recursive type " ~ recName
                    ~ " with inlineSubschemas=true; use $defs mode (the default)");
    }
    else
    {
        countType!T(ctx, null);
        root = emitType!T(ctx);
    }

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

/// Generate the JSON Schema for `T` with compile-time-known settings.
///
/// Identical to the runtime overload, except that requesting
/// `inlineSubschemas` for a recursive type is rejected with a `static assert`
/// naming the offending type, rather than throwing at runtime.
///
/// Prefer this overload whenever the settings are compile-time constants: the
/// recursive-inline rejection then surfaces as a build error instead of a
/// runtime exception. For example, `jsonSchemaOf!(T, GeneratorSettings(false,
/// true))()`.
JsonNode jsonSchemaOf(T, GeneratorSettings settings)()
{
    static if (settings.inlineSubschemas)
        static assert(inlineRecursionName!T.length == 0,
                "jsonSchemaOf: cannot inline recursive type " ~ inlineRecursionName!T
                ~ " with inlineSubschemas=true; use $defs mode (the default)");
    return jsonSchemaOf!T(settings);
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

private JsonNode typeSchema(string typeName) pure
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

// --- inline mode ($defs/$ref-free) ---

/// Compile-time recursion probe for inline emission. Returns the `.stringof` of
/// the first struct type that reappears in its own ancestry when fully inlined,
/// or `""` if `T` can be inlined without recursion. `Ancestors` is the chain of
/// struct types currently being expanded.
private template inlineRecursionName(T, Ancestors...)
{
    static if (isInstanceOf!(Nullable, T))
        enum inlineRecursionName = inlineRecursionName!(TemplateArgsOf!T[0], Ancestors);
    else static if (is(T == enum) || is(T == bool) || isStdDateTime!T
            || isIntegral!T || isFloatingPoint!T || isSomeString!T)
        enum inlineRecursionName = "";
    else static if (isSumType!T)
    {
        enum inlineRecursionName = () {
            static foreach (V; TemplateArgsOf!T)
            {
                {
                    enum r = inlineRecursionName!(V, Ancestors);
                    if (r.length)
                        return r;
                }
            }
            return "";
        }();
    }
    else static if (isAssociativeArray!T)
        enum inlineRecursionName = inlineRecursionName!(ValueType!T, Ancestors);
    else static if (isArray!T)
        enum inlineRecursionName = inlineRecursionName!(typeof(T.init[0]), Ancestors);
    else static if (is(T == struct))
    {
        static if (staticIndexOf!(T, Ancestors) >= 0)
            enum inlineRecursionName = T.stringof;
        else
        {
            enum inlineRecursionName = () {
                static foreach (field; FieldNameTuple!T)
                {
                    {
                        enum r = inlineRecursionName!(typeof(__traits(getMember,
                                    T, field)), Ancestors, T);
                        if (r.length)
                            return r;
                    }
                }
                return "";
            }();
        }
    }
    else
        enum inlineRecursionName = "";
}

/// Emit `T` with every subschema inlined: no `$defs`, no `$ref`. A struct type
/// found in its own `Ancestors` is recursive and rejected at compile time.
private JsonNode emitTypeInline(T, Ancestors...)()
{
    static if (isInstanceOf!(Nullable, T))
    {
        auto nullSchema = JsonNode.emptyObject();
        nullSchema.set("type", JsonNode("null"));
        auto variants = JsonNode.emptyArray();
        variants.append(emitTypeInline!(TemplateArgsOf!T[0], Ancestors)());
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
            variants.append(emitTypeInline!(V, Ancestors)());
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
        s.set("additionalProperties", emitTypeInline!(ValueType!T, Ancestors)());
        return s;
    }
    else static if (isArray!T)
    {
        auto s = typeSchema("array");
        s.set("items", emitTypeInline!(typeof(T.init[0]), Ancestors)());
        return s;
    }
    else static if (is(T == struct))
    {
        static assert(staticIndexOf!(T, Ancestors) < 0,
                "jsonSchemaOf: cannot inline recursive type " ~ T.stringof
                ~ " with inlineSubschemas=true; use $defs mode (the default)");
        auto s = typeSchema("object");
        auto props = JsonNode.emptyObject();
        auto required = JsonNode.emptyArray();
        static foreach (i, field; FieldNameTuple!T)
        {
            {
                alias FT = typeof(__traits(getMember, T, field));
                auto prop = emitTypeInline!(FT, Ancestors, T)();
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
    else
        static assert(false, "jsonSchemaOf: unsupported type " ~ T.stringof);
}

/// Fold the constraint-facet UDAs from a compile-time sequence (e.g.
/// `__traits(getAttributes, someSymbol)`) onto an existing schema node:
/// `@minimum`, `@maximum`, `@pattern`, `@minLength`, `@maxLength`, `@minItems`,
/// `@maxItems`, `@format`, `@title`, and `@schemaDefault` map to the matching
/// keyword; any other UDA is ignored.
///
/// `jsonSchemaOf` uses this for struct fields, but it is public so external
/// code can apply the same facets to symbols that are not struct fields — e.g.
/// function parameters — without duplicating the mapping:
///
/// ---
/// JsonNode prop = jsonSchemaOf!int;
/// applyUdaFacets!(__traits(getAttributes, someSymbol))(prop); // folds @minimum etc. onto prop
/// ---
public void applyUdaFacets(udas...)(ref JsonNode prop)
{
    import jsonschema.attributes;

    static foreach (uda; udas)
    {
        static if (isInstanceOf!(Minimum, typeof(uda)))
            prop.set("minimum", boundNode(uda.value));
        else static if (isInstanceOf!(Maximum, typeof(uda)))
            prop.set("maximum", boundNode(uda.value));
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

/// Serialize a `@minimum`/`@maximum` bound. Integral bounds round-trip
/// exactly (even beyond 2^53) by going straight to an integer `JsonNode`;
/// fractional bounds fall back to `numberNode`.
private JsonNode boundNode(V)(V v) pure nothrow
{
    static if (isIntegral!V)
        return JsonNode(v);
    else
        return numberNode(v);
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
    import jsonschema.node : jsonEquals, parseJson;
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

unittest  // an enum maps to a string schema with the member names as an enum
{
    enum Color
    {
        red,
        green,
        blue
    }

    auto s = jsonSchemaOf!Color;
    assert(s.get("type").string_ == "string");
    auto e = s.get("enum");
    assert(e !is null && e.array_.length == 3);
    assert(e.array_[0].string_ == "red");
    assert(e.array_[2].string_ == "blue");
}

unittest  // inline mode emits enum, datetime and sumtype schemas directly
{
    import std.datetime.date : Date;
    import std.sumtype : SumType;

    enum Suit
    {
        spades,
        hearts
    }

    auto inline = GeneratorSettings(false, true);

    auto en = jsonSchemaOf!Suit(inline);
    assert(en.get("type").string_ == "string");
    assert(en.get("enum").array_.length == 2);

    auto dt = jsonSchemaOf!Date(inline);
    assert(dt.get("format").string_ == "date");

    auto sum = jsonSchemaOf!(SumType!(int, string))(inline);
    assert(sum.get("anyOf").array_.length == 2);
}

unittest  // a fractional numeric facet serializes as a floating-point number
{
    import jsonschema.attributes : minimum, maximum;

    static struct Measure
    {
        @minimum(1.5) @maximum(9.25) double value;
    }

    auto s = jsonSchemaOf!Measure;
    auto v = s.get("properties").get("value");
    assert(v.get("minimum").floating_ == 1.5);
    assert(v.get("maximum").floating_ == 9.25);
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

unittest  // integral bounds above 2^53 round-trip exactly (no double rounding)
{
    import jsonschema.attributes;
    import std.algorithm.searching : canFind;

    static struct Big
    {
        @minimum(9007199254740993L) @maximum(9223372036854775807L) long n;
    }

    auto s = jsonSchemaOf!Big;
    auto n = s.get("properties").get("n");
    assert(n.get("minimum").integer_ == 9007199254740993L);
    assert(n.get("maximum").integer_ == 9223372036854775807L);
    assert(n.toString.canFind("9007199254740993"));
    assert(n.toString.canFind("9223372036854775807"));
}

unittest  // unsigned bounds beyond long.max round-trip exactly
{
    import jsonschema.attributes;
    import std.algorithm.searching : canFind;

    static struct BigU
    {
        @maximum(18446744073709551615UL) ulong n;
    }

    auto s = jsonSchemaOf!BigU;
    auto n = s.get("properties").get("n");
    assert(n.get("maximum").uinteger_ == 18446744073709551615UL);
    assert(n.toString.canFind("18446744073709551615"));
}

unittest  // fractional bounds still emit as floating-point numbers
{
    import jsonschema.attributes;

    static struct Frac
    {
        @minimum(0.5) @maximum(99.5) double x;
    }

    auto s = jsonSchemaOf!Frac;
    auto x = s.get("properties").get("x");
    assert(x.get("minimum").floating_ == 0.5);
    assert(x.get("maximum").floating_ == 99.5);
}

unittest  // @description alias emits the description keyword
{
    import jsonschema.attributes : description;

    static struct Doc
    {
        @description("a documented field") int x;
    }

    auto s = jsonSchemaOf!Doc;
    assert(s.get("properties").get("x").get("description").string_ == "a documented field");
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

unittest  // inlineSubschemas expands a shared struct at every use site
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

    // Default mode: one $defs entry plus two $refs.
    auto def = jsonSchemaOf!Pair;
    assert(def.get("$defs").get("Leaf").get("type").string_ == "object");
    assert(def.get("properties").get("left").get("$ref").string_ == "#/$defs/Leaf");
    assert(def.get("properties").get("right").get("$ref").string_ == "#/$defs/Leaf");

    // Inline mode: the full object schema appears in both places, and there is
    // no $defs or $ref anywhere in the document.
    auto inl = jsonSchemaOf!Pair(GeneratorSettings(false, true));
    assert(inl.get("$defs") is null);
    auto left = inl.get("properties").get("left");
    auto right = inl.get("properties").get("right");
    assert(left.get("type").string_ == "object");
    assert(left.get("properties").get("v").get("type").string_ == "integer");
    assert(right.get("type").string_ == "object");
    assert(right.get("properties").get("v").get("type").string_ == "integer");
    assert(left.get("$ref") is null && right.get("$ref") is null);

    import std.string : indexOf;

    assert(inl.toString.indexOf("$ref") == -1);
    assert(inl.toString.indexOf("$defs") == -1);

    // The compile-time-settings overload accepts inline for a non-recursive type.
    static assert(__traits(compiles, jsonSchemaOf!(Pair, GeneratorSettings(false, true))()));
}

unittest  // recursive structs compile in default mode but not under inline
{
    static struct Node
    {
        int value;
        Node[] children;
    }

    // Default ($defs/$ref) mode compiles and uses a $ref to itself.
    static assert(__traits(compiles, jsonSchemaOf!Node));
    auto s = jsonSchemaOf!Node;
    assert(s.get("$ref").string_ == "#/$defs/Node");

    // Inlining a recursive type cannot terminate: rejected at compile time.
    static assert(!__traits(compiles, jsonSchemaOf!(Node, GeneratorSettings(false, true))()));
}

unittest  // inline-mode output validates against the 2020-12 meta-schema
{
    static struct Leaf
    {
        int v;
    }

    static struct Pair
    {
        Leaf a;
        Leaf b;
    }

    auto meta = compileSchema(`{"$ref": "https://json-schema.org/draft/2020-12/schema"}`);

    auto inl = jsonSchemaOf!Pair(GeneratorSettings(false, true));
    assert(meta.validate(inl).valid, inl.toString);

    auto withDialect = jsonSchemaOf!Pair(GeneratorSettings(true, true));
    assert(meta.validate(withDialect).valid);
}

unittest  // inline and default agree for a non-shared, non-recursive type
{
    static struct Inner
    {
        int v;
        string s;
    }

    static struct Outer
    {
        Inner one;
        int n;
    }

    // A single-use struct is inlined in both modes, so the only difference would
    // be the $defs wrapper — and there is none here. The schemas are identical.
    auto def = jsonSchemaOf!Outer;
    auto inl = jsonSchemaOf!Outer(GeneratorSettings(false, true));
    assert(def.get("$defs") is null);
    assert(inl.get("$defs") is null);
    assert(jsonEquals(def, inl));
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
            const r = meta.validate(generated);
            assert(r.valid, T.stringof ~ " schema fails meta-validation: " ~ generated.toString);
            // And with the explicit $schema keyword at the root.
            auto withDialect = jsonSchemaOf!T(GeneratorSettings(true));
            assert(meta.validate(withDialect).valid);
            // Inline mode (where the type is not recursive) must also conform.
            static if (inlineRecursionName!T.length == 0)
            {
                auto inlined = jsonSchemaOf!T(GeneratorSettings(false, true));
                assert(meta.validate(inlined).valid,
                        T.stringof ~ " inline schema fails meta-validation: " ~ inlined.toString);
            }
        }
    }
}
