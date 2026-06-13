/// The compiled internal representation of a JSON Schema document.
///
/// Schema documents are compiled once into this IR — keyword tables, compiled
/// regexes, resolved `$ref` targets, and anchor maps all live here, never in
/// the source JSON type. Instances of any JSON type are then validated against
/// the IR via the adapter trait (see `jsonschema.adapter`).
module jsonschema.ir;

import jsonschema.adapter : JsonNumber;
import jsonschema.node : JsonNode;
import std.regex : Regex;

@safe:

/// URI of the JSON Schema 2020-12 dialect (the default and currently the only
/// fully supported dialect).
enum dialect202012 = "https://json-schema.org/draft/2020-12/schema";

/// Base class for all schema compilation problems.
class SchemaException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, file, line);
    }
}

/// Malformed schema document, invalid keyword value, or unresolvable `$ref`.
class SchemaCompileException : SchemaException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, file, line);
    }
}

/// The schema declares (via `$schema`) a dialect this library does not
/// implement. Callers required to reject unknown dialects (e.g. MCP servers)
/// can catch this specifically.
class UnsupportedDialectException : SchemaException
{
    /// The offending `$schema` value.
    string dialectUri;

    this(string dialectUri, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        this.dialectUri = dialectUri;
        super("unsupported JSON Schema dialect: " ~ dialectUri, file, line);
    }
}

/// Validation could not run to completion (currently: the evaluation depth
/// limit was hit, which indicates an unboundedly recursive schema).
class ValidationException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, file, line);
    }
}

/// How the `format` keyword behaves.
enum FormatMode
{
    /// Per 2020-12 default: `format` is an annotation, never a constraint.
    annotation,
    /// `format` asserts: instances not matching the named format fail
    /// validation. (Also activated per-resource when a schema's dialect
    /// declares the format-assertion vocabulary.)
    assertion
}

/// Spec output formats supported by `validate`.
enum OutputFormat
{
    flag, /// validity only; no error list is built
    basic /// flat list of errors with instance/keyword locations
}

/// One output unit of the `basic` output format.
struct ValidationError
{
    /// JSON Pointer into the instance.
    string instanceLocation;
    /// Evaluation path through the schema, including `$ref` segments.
    string keywordLocation;
    /// Human-readable description of the failure.
    string message;
}

/// Result of validating one instance.
struct ValidationResult
{
    bool valid;
    ValidationError[] errors;

    /// Render the errors as a single string, one per line, each formatted as
    /// `instanceLocation ~ " " ~ keywordLocation ~ ": " ~ message`. Returns the
    /// empty string when the instance is valid.
    string toString() const @safe pure
    {
        if (valid)
            return "";
        import std.algorithm : map;
        import std.array : join;

        return errors.map!(e => e.instanceLocation ~ " " ~ e.keywordLocation ~ ": " ~ e.message)
            .join("\n");
    }
}

/// The set of 2020-12 vocabularies in effect for a schema resource. Keywords
/// whose vocabulary is disabled by a custom meta-schema's `$vocabulary` are
/// not compiled (they behave as unknown keywords).
struct Vocabularies
{
    bool core = true;
    bool applicator = true;
    bool validation = true;
    bool unevaluated = true;
    bool formatAnnotation = true;
    bool formatAssertion = false;
    bool content = true;
    bool metaData = true;
}

/// Resolver callback for loading schema documents this library has no local
/// copy of. Never invoked unless the caller supplies one — reference
/// resolution is local-only by default and the library itself performs no I/O.
alias SchemaResolver = JsonNode delegate(string uri) @safe;

/// Compilation / validation settings. Pass to `compileSchema`.
struct ValidatorSettings
{
    import jsonschema.store : SchemaStore;

    /// `format` behavior; see `FormatMode`.
    FormatMode formatMode = FormatMode.annotation;

    /// Pre-registered schema store consulted for `$ref` targets. When null a
    /// fresh store (containing only the bundled 2020-12 meta-schemas) is used.
    SchemaStore store;

    /// Optional loader for unknown remote schema URIs. Null (the default)
    /// means unresolvable external references fail compilation.
    SchemaResolver resolver;

    /// Retrieval URI of the schema being compiled; the base against which a
    /// root `$id` (or, absent one, every relative reference) is resolved.
    string baseUri;

    /// Dialect assumed when the document carries no `$schema`.
    string defaultDialect = dialect202012;

    /// Evaluation recursion limit; exceeding it throws `ValidationException`
    /// (guards against unboundedly self-referential schemas).
    size_t maxDepth = 512;
}

/// A schema resource: a document root or an embedded subschema carrying `$id`.
final class SchemaResource
{
    /// Canonical absolute URI (no fragment); "" for an anonymous root.
    string uri;
    /// Root schema of the resource.
    CompiledSchema root;
    /// `$anchor` (and `$dynamicAnchor`) plain-name fragments.
    CompiledSchema[string] anchors;
    /// `$dynamicAnchor` names only, for `$dynamicRef` scope search.
    CompiledSchema[string] dynamicAnchors;
    /// Every schema location in this resource keyed by canonical JSON Pointer
    /// (including locations inside embedded child resources).
    CompiledSchema[string] byPointer;
    /// Dialect in effect for this resource.
    string dialectUri;
    Vocabularies vocab;
    /// The raw document node this resource was compiled from; kept so `$ref`
    /// pointer fragments can target locations outside known keyword positions.
    JsonNode rawRoot;
}

/// A `$ref` / `$dynamicRef` edge in the IR.
final class SchemaRef
{
    /// Absolute target URI (after base-URI resolution).
    string targetUri;
    /// Statically resolved target.
    CompiledSchema target;
    /// True for `$dynamicRef`.
    bool dynamic;
    /// Plain-name fragment of a `$dynamicRef`, when present.
    string anchorName;
    /// True when the initially resolved target is a matching `$dynamicAnchor`,
    /// i.e. the reference participates in dynamic-scope resolution.
    bool dynamicCandidate;
}

/// `patternProperties` entry: source text, compiled regex, value schema.
struct PatternProperty
{
    string source;
    Regex!char regex;
    CompiledSchema schema;
}

/// Bit flags for the `type` keyword.
enum TypeBit : ubyte
{
    null_ = 1 << 0,
    boolean = 1 << 1,
    object = 1 << 2,
    array = 1 << 3,
    number = 1 << 4,
    string_ = 1 << 5,
    integer = 1 << 6
}

/// Sentinel meaning "keyword absent" for the non-negative integer keywords.
enum long absent = -1;

/// One compiled subschema. All keyword storage is pre-parsed; absent keywords
/// are null references, `absent` sentinels, or cleared `has*` flags.
final class CompiledSchema
{
    /// Owning resource (never null for object schemas; boolean schemas share
    /// the enclosing resource).
    SchemaResource resource;
    /// JSON Pointer of this schema within `resource`.
    string pointer;

    bool isBoolean;
    bool boolValue;

    // --- core ---
    SchemaRef refInfo; /// `$ref`, or null
    SchemaRef dynRefInfo; /// `$dynamicRef`, or null
    bool hasDynamicAnchor;
    string dynamicAnchorName;

    // --- validation: any type ---
    bool hasType;
    ubyte typeMask;
    bool hasEnum;
    JsonNode[] enumValues;
    bool hasConst;
    JsonNode constValue;

    // --- validation: numbers ---
    bool hasMultipleOf;
    JsonNumber multipleOf;
    bool hasMaximum;
    JsonNumber maximum;
    bool hasExclusiveMaximum;
    JsonNumber exclusiveMaximum;
    bool hasMinimum;
    JsonNumber minimum;
    bool hasExclusiveMinimum;
    JsonNumber exclusiveMinimum;

    // --- validation: strings ---
    long maxLength = absent;
    long minLength = absent;
    bool hasPattern;
    string patternSource;
    Regex!char pattern;

    // --- validation: arrays ---
    long maxItems = absent;
    long minItems = absent;
    bool uniqueItems;
    long maxContains = absent;
    long minContains = absent;

    // --- validation: objects ---
    long maxProperties = absent;
    long minProperties = absent;
    string[] required;
    string[][string] dependentRequired;

    // --- applicators: in place ---
    CompiledSchema[] allOf;
    CompiledSchema[] anyOf;
    CompiledSchema[] oneOf;
    CompiledSchema notSchema;
    CompiledSchema ifSchema;
    CompiledSchema thenSchema;
    CompiledSchema elseSchema;
    CompiledSchema[string] dependentSchemas;

    // --- applicators: children ---
    CompiledSchema[string] properties;
    PatternProperty[] patternProperties;
    CompiledSchema additionalProperties;
    CompiledSchema propertyNames;
    bool hasPrefixItems;
    CompiledSchema[] prefixItems;
    CompiledSchema itemsSchema;
    CompiledSchema containsSchema;

    // --- unevaluated ---
    CompiledSchema unevaluatedProperties;
    CompiledSchema unevaluatedItems;

    // --- format / content (annotations unless asserting) ---
    bool hasFormat;
    string format;
    string contentEncoding;
    string contentMediaType;
    CompiledSchema contentSchema;
}

// --- tests ---

unittest  // ValidationResult.toString: empty when valid
{
    const ok = ValidationResult(true, null);
    assert(ok.toString == "");
}

unittest  // ValidationResult.toString: one line per error
{
    const r = ValidationResult(false, [
        ValidationError("/age", "/properties/age/minimum", "instance is below the minimum"),
        ValidationError("", "/required", "missing required property 'name'"),
    ]);
    const text = r.toString;
    assert(text == "/age /properties/age/minimum: instance is below the minimum\n"
            ~ " /required: missing required property 'name'");
    import std.string : splitLines;

    assert(text.splitLines.length == 2);
}
