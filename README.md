# jsonschema

A complete **JSON Schema 2020-12** implementation for D, in two halves:

1. **Validator** — compile arbitrary JSON Schema 2020-12 documents into a
   reusable validator and validate JSON instances of multiple JSON types
   (`std.json.JSONValue`, `vibe.data.json.Json`, or your own via a small
   adapter trait). Full dialect support: `$ref`/`$dynamicRef`/`$anchor`/
   `$dynamicAnchor`/`$vocabulary`, all applicators,
   `unevaluatedProperties`/`unevaluatedItems` with proper annotation
   collection, and opt-in format assertion.
2. **Generator** — derive a 2020-12 schema from a D type at compile time
   (`jsonSchemaOf!T`), with constraint UDAs, and `$defs`/`$ref` emission for
   shared and recursive structs.

Verified against the official
[JSON-Schema-Test-Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite):
**100% of required tests (1299/1299)** and **100% of non-skipped optional
tests (645/645)**, run through *both* JSON adapters with identical outcomes
(see [Test suite](#test-suite) for the deliberate skips).

## Packages

| Package | Dependency | Provides |
|---|---|---|
| `jsonschema` | phobos only | validator core, `std.json` adapter, generator |
| `jsonschema:vibe` | `vibe-d:data` | `vibe.data.json` adapter and conversions |

The base package never pulls in vibe-d; `jsonschema:vibe` is the only place it
appears.

```sh
dub add jsonschema          # std.json only
dub add jsonschema:vibe    # adds the vibe.data.json adapter
```

## Quick start — validation

### std.json

```d
import jsonschema;
import std.json : parseJSON;

auto validator = compileSchema(`{
    "type": "object",
    "properties": {
        "name": {"type": "string", "minLength": 1},
        "age":  {"type": "integer", "minimum": 0}
    },
    "required": ["name"]
}`);

auto ok = validator.validate(parseJSON(`{"name": "Ada", "age": 36}`));
assert(ok.valid);

auto bad = validator.validate(parseJSON(`{"age": -1}`));
assert(!bad.valid);
foreach (e; bad.errors)
    writeln(e.instanceLocation, " ", e.keywordLocation, ": ", e.message);
// /age /properties/age/minimum: instance is below the minimum
//      /required: missing required property 'name'
```

A schema is compiled once into an internal representation (keyword tables,
compiled regexes, resolved references) and can then validate any number of
instances.

### vibe.data.json

```d
import jsonschema;
import jsonschema.vibejson;          // jsonschema:vibe
import vibe.data.json : parseJsonString;

// Schema documents may come from either JSON type (or text) — they are
// normalized at compile time, so the same validator serves both worlds.
auto validator = compileSchema(parseJsonString(`{"type": "integer"}`));

assert(validator.validateJson(parseJsonString("42")).valid);          // vibe Json
assert(validator.validate(std.json.parseJSON("42")).valid);           // std.json
```

### Settings

```d
ValidatorSettings settings;
settings.formatMode = FormatMode.assertion;  // make `format` assert (default: annotation)
settings.store = new SchemaStore;            // pre-registered documents for $ref
settings.store.register("https://example.com/defs", `{"$defs": {...}}`);
settings.resolver = uri => loadMySchema(uri); // optional remote loader
auto v = compileSchema(schemaText, settings);
```

- Reference resolution is **local-only by default**: external `$ref` targets
  must be registered in the `SchemaStore` (keyed by absolute URI, usually the
  document's `$id`). The 2020-12 meta-schemas are bundled and pre-registered.
  The library performs no network I/O; supply `settings.resolver` if you want
  to load schemas yourself.
- Dialects: `$schema` is honored; absent means 2020-12. Any other dialect
  throws `UnsupportedDialectException`. Custom meta-schemas with `$vocabulary`
  are supported, including vocabulary-gated keyword sets and the
  format-assertion vocabulary.
- Output formats: `OutputFormat.flag` (validity only) and `OutputFormat.basic`
  (flat error list with `instanceLocation` / `keywordLocation`).

## Quick start — generation

```d
import jsonschema;

struct Point
{
    @fieldDescription("X coordinate") int x;
    int y;
    @schemaDefault(1.0) @minimum(0) double scale;
    Nullable!string label;       // optional, accepts null
}

JsonNode schema = jsonSchemaOf!Point;
writeln(schema);            // compact JSON text
auto std = toStdJson(schema);             // std.json.JSONValue
// import jsonschema.vibejson : nodeToVibeJson;  (jsonschema:vibe)
// auto vib = nodeToVibeJson(schema);             // vibe.data.json.Json

// Generated schemas can be compiled and used to validate immediately:
auto v = compileSchema(jsonSchemaOf!Point);
```

Type mapping:

| D type | Schema |
|---|---|
| `bool`, integral, floating, `string` | matching primitive (`uint` etc. also emit `minimum: 0`) |
| `enum` | string with `enum` |
| arrays | `items` |
| string-keyed associative arrays | `additionalProperties` |
| `Nullable!T` | `anyOf: [T, null]` |
| `SumType!(…)` | `anyOf` |
| `std.datetime` types | formatted strings |
| structs | objects with `properties`/`required` |

Struct types used more than once or recursively are emitted into `$defs` and
referenced via `$ref`; everything else is inlined. Unsupported types
(pointers, classes, delegates, non-string AA keys) fail with a clear
`static assert`.

### Inline subschemas (no `$ref`)

By default a schema uses `$defs`/`$ref` for shared and recursive struct types.
Some consumers don't follow `$ref` inside an embedded schema. For them, set
`inlineSubschemas` to expand every subschema in place, producing a fully
self-contained document with no `$defs` and no `$ref` — a type used N times is
expanded N times:

```d
GeneratorSettings settings;
settings.inlineSubschemas = true;
auto schema = jsonSchemaOf!Point(settings);   // no $defs/$ref anywhere
```

A directly or mutually recursive type cannot be inlined (the expansion would
never terminate). Such a type is rejected naming the offending type — at
compile time via the compile-time-settings form
`jsonSchemaOf!(T, settings)`, or by throwing at runtime via
`jsonSchemaOf!T(settings)`. Recursive types are fine in the default
(`$defs`/`$ref`) mode.

Constraint UDAs (`jsonschema.attributes`):

- `@minimum`, `@maximum` — numeric bounds
- `@minLength`, `@maxLength` — string length bounds
- `@pattern` — string regex
- `@minItems`, `@maxItems` — array length bounds
- `@format` — string format annotation
- `@title`, `@fieldDescription` — documentation
- `@schemaDefault` — default value (also omits the field from `required`)

A field with `@schemaDefault` or a declared initializer is omitted from
`required`.

Every generated schema is verified against the official 2020-12 meta-schema
(using this library's own validator) in the test suite.

## Adapting another JSON type

Validation is templated over a small adapter trait — `StdJsonAdapter`,
`VibeJsonAdapter`, and `JsonNodeAdapter` (the library's own document type) are
the built-ins. To adapt another library (asdf, mir-ion, …) implement the
static interface documented in `jsonschema/adapter.d` (kind query, scalar
extraction with 64-bit integer fidelity, array/object access) and call:

```d
auto result = validator.validateWith!MyAdapter(myValue);
```

Validation outcomes are independent of the JSON type: the CI suite runs every
official test through both built-in adapters and fails on any divergence.

## Test suite

```sh
git submodule update --init
dub run jsonschema:suite-runner
```

The harness runs every draft2020-12 case — required and optional, including
format assertions — through both adapters and prints pass/fail counts; its
exit status fails CI on any required failure or adapter divergence.

Current results:

| section | passed |
|---|---|
| required | 1299/1299 (100%) |
| optional (non-skipped) | 645/645 (100%) |
| deliberately skipped | 153 |

Deliberate skips (all in optional sections):

- `optional/format/idn-hostname.json`, `optional/format/idn-email.json` —
  IDNA / RFC 5891 internationalized hostnames and addresses (would require
  full Unicode IDNA mapping tables).
- `optional/format/hostname.json`, group "validation of A-label (punycode)
  host names" — punycode-decoding label semantics, same territory.
- `optional/format/iri.json`, `optional/format/iri-reference.json` —
  internationalized resource identifiers.
- `optional/cross-draft.json` — references into draft-07 schemas (draft-07
  support is a possible future addition; the dialect detection and
  per-resource vocabulary machinery already accommodate it).

Unknown `format` names always pass (they are annotations for some other
consumer), matching the spec.

## License

Apache-2.0. See [LICENSE](LICENSE).
