/// Schema-constraint UDAs for the compile-time generator (`jsonSchemaOf`).
/// Attach these to struct fields to emit the matching JSON Schema keywords
/// onto the field's property schema.
module jsonschema.attributes;

@safe:

/// Emits the JSON Schema `description` keyword. Named `fieldDescription`
/// to stay unambiguous at the call site (and clear of std.traits names).
struct fieldDescription
{
    string value;
}

/// Emits the JSON Schema `title` keyword.
struct title
{
    string value;
}

/// Emits the JSON Schema `minimum` keyword (inclusive numeric lower bound).
struct minimum
{
    double value;
}

/// Emits the JSON Schema `maximum` keyword (inclusive numeric upper bound).
struct maximum
{
    double value;
}

/// Emits the JSON Schema `format` keyword (e.g. "email", "uri", "date-time").
struct format
{
    string value;
}

/// Emits the JSON Schema `minLength` keyword (minimum string length).
struct minLength
{
    size_t value;
}

/// Emits the JSON Schema `maxLength` keyword (maximum string length).
struct maxLength
{
    size_t value;
}

/// Emits the JSON Schema `pattern` keyword (ECMA-262 regular expression).
struct pattern
{
    string value;
}

/// Emits the JSON Schema `minItems` keyword (minimum array length).
struct minItems
{
    size_t value;
}

/// Emits the JSON Schema `maxItems` keyword (maximum array length).
struct maxItems
{
    size_t value;
}

/// The payload struct carrying a `@schemaDefault` value. Construct it via the
/// `schemaDefault(value)` factory so the value type is inferred; the generator
/// detects it with `isInstanceOf!(SchemaDefault, UDA)`.
///
/// A field carrying `@schemaDefault` is treated as optional (omitted from
/// `required`) even when its value equals the type's `.init`.
struct SchemaDefault(T)
{
    T value;
}

/// Factory producing the `@schemaDefault` UDA: `@schemaDefault(10) int limit;`
SchemaDefault!T schemaDefault(T)(T value) pure nothrow
{
    return SchemaDefault!T(value);
}

unittest  // schemaDefault infers the value type
{
    auto d = schemaDefault(10);
    static assert(is(typeof(d) == SchemaDefault!int));
    assert(d.value == 10);

    auto sd = schemaDefault("hi");
    assert(sd.value == "hi");
}
