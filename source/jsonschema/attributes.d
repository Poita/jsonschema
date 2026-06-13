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

/// The payload struct carrying a `@minimum` value. Construct it via the
/// `minimum(value)` factory so the value type is inferred; the generator
/// detects it with `isInstanceOf!(Minimum, UDA)`.
///
/// Templating on the value type lets integral bounds beyond 2^53 round-trip
/// exactly (e.g. `@minimum(9007199254740993L)`), since a `double` payload
/// could not represent them.
struct Minimum(T)
{
    T value;
}

/// Factory producing the `@minimum` UDA (inclusive numeric lower bound):
/// `@minimum(1) int count;` or `@minimum(9007199254740993L) long big;`.
Minimum!T minimum(T)(T value) pure nothrow
{
    return Minimum!T(value);
}

/// The payload struct carrying a `@maximum` value. Construct it via the
/// `maximum(value)` factory so the value type is inferred; the generator
/// detects it with `isInstanceOf!(Maximum, UDA)`.
///
/// Templating on the value type lets integral bounds beyond 2^53 round-trip
/// exactly (e.g. `@maximum(9007199254740993L)`), since a `double` payload
/// could not represent them.
struct Maximum(T)
{
    T value;
}

/// Factory producing the `@maximum` UDA (inclusive numeric upper bound):
/// `@maximum(100) int count;` or `@maximum(9007199254740993L) long big;`.
Maximum!T maximum(T)(T value) pure nothrow
{
    return Maximum!T(value);
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
