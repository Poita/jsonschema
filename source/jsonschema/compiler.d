/// Schema compilation: JSON document → IR.
///
/// `compileSchema` normalizes the input, detects the dialect via `$schema`,
/// walks every schema location building `CompiledSchema` nodes, registers
/// resources / anchors / pointer maps, and resolves all `$ref` edges eagerly.
module jsonschema.compiler;

import jsonschema.adapter : JsonNumber;
import jsonschema.ir;
import jsonschema.node;
import jsonschema.pointer : escapeToken, parsePointer, evaluatePointer;
import jsonschema.store : SchemaStore;
import jsonschema.uri : percentDecode, resolveUri, splitFragment;
import jsonschema.validator : Validator;

import std.conv : to;

@safe:

/// Compile a schema document (already normalized) into a reusable validator.
Validator compileSchema(JsonNode doc, ValidatorSettings settings = ValidatorSettings.init)
{
    auto store = settings.store !is null ? settings.store : new SchemaStore;
    settings.store = store;
    auto sess = new Session(store, settings);
    auto root = compileDocument(sess, doc, settings.baseUri);
    resolvePendingRefs(sess);
    return new Validator(root.root, settings);
}

/// Compile a schema from JSON text.
Validator compileSchema(string jsonText, ValidatorSettings settings = ValidatorSettings.init)
{
    return compileSchema(parseJson(jsonText), settings);
}

/// Compile a schema given as a `std.json` value.
Validator compileSchema(in std.json.JSONValue doc, ValidatorSettings settings = ValidatorSettings.init)
{
    return compileSchema(fromStdJson(doc), settings);
}

import std.json;

// --- compilation session ---

package final class Session
{
    SchemaStore store;
    ValidatorSettings settings;
    /// Compiled resources for this validator, by URI (includes "" for an
    /// anonymous root). Per-session: a shared store only holds raw documents,
    /// so re-registering a different document under a previously seen `$id`
    /// in another compile never collides.
    SchemaResource[string] resources;
    /// `$ref` edges awaiting resolution.
    SchemaRef[] pending;
    /// Documents currently being walked (cycle guard).
    bool[string] docsInProgress;

    this(SchemaStore store, ValidatorSettings settings) pure nothrow
    {
        this.store = store;
        this.settings = settings;
    }
}

/// (resource, pointer-of-current-node-within-it) pair; the walk keeps one
/// frame per enclosing resource so every schema location is addressable by
/// pointer from any of them.
private struct Frame
{
    SchemaResource res;
    string ptr;
}

private Frame[] extend(Frame[] frames, string segment) pure nothrow
{
    auto r = frames.dup;
    foreach (ref f; r)
        f.ptr ~= segment;
    return r;
}

// --- dialect / vocabulary handling ---

private enum vocabCore = "https://json-schema.org/draft/2020-12/vocab/core";
private enum vocabApplicator = "https://json-schema.org/draft/2020-12/vocab/applicator";
private enum vocabUnevaluated = "https://json-schema.org/draft/2020-12/vocab/unevaluated";
private enum vocabValidation = "https://json-schema.org/draft/2020-12/vocab/validation";
private enum vocabMetaData = "https://json-schema.org/draft/2020-12/vocab/meta-data";
private enum vocabFormatAnnotation = "https://json-schema.org/draft/2020-12/vocab/format-annotation";
private enum vocabFormatAssertion = "https://json-schema.org/draft/2020-12/vocab/format-assertion";
private enum vocabContent = "https://json-schema.org/draft/2020-12/vocab/content";

/// Determine the vocabulary set for a dialect URI. The standard 2020-12 URI
/// maps directly; any other URI must name a registered meta-schema document,
/// whose `$vocabulary` is honored. Unknown dialects are refused.
package Vocabularies vocabulariesFor(Session sess, string dialectUri)
{
    if (dialectUri == dialect202012 || dialectUri == "")
        return Vocabularies.init;

    string base, frag;
    splitFragment(dialectUri, base, frag);
    auto doc = sess.store.lookup(base);
    if (doc is null)
        throw new UnsupportedDialectException(dialectUri);
    auto vocabNode = doc.get("$vocabulary");
    if (vocabNode is null || !vocabNode.isObject)
        return Vocabularies.init; // custom meta-schema without $vocabulary: full 2020-12 set

    Vocabularies v;
    v = Vocabularies(false, false, false, false, false, false, false, false);
    foreach (ref m; vocabNode.members_)
    {
        const required = m.value.isBoolean && m.value.boolean_;
        switch (m.key)
        {
        case vocabCore:
            v.core = true;
            break;
        case vocabApplicator:
            v.applicator = true;
            break;
        case vocabUnevaluated:
            v.unevaluated = true;
            break;
        case vocabValidation:
            v.validation = true;
            break;
        case vocabMetaData:
            v.metaData = true;
            break;
        case vocabFormatAnnotation:
            v.formatAnnotation = true;
            break;
        case vocabFormatAssertion:
            v.formatAssertion = true;
            break;
        case vocabContent:
            v.content = true;
            break;
        default:
            // A required vocabulary we do not implement: refuse the dialect.
            if (required)
                throw new UnsupportedDialectException(dialectUri);
        }
    }
    if (!v.core)
        throw new UnsupportedDialectException(dialectUri);
    return v;
}

private string dialectOf(in JsonNode doc, string fallback) pure
{
    if (doc.isObject)
        if (auto s = doc.get("$schema"))
        {
            if (!s.isString)
                throw new SchemaCompileException("$schema must be a string");
            return s.string_;
        }
    return fallback;
}

// --- document compilation ---

/// Compile one document; returns its root resource. The root resource is
/// registered under both its `$id` (when present) and the retrieval URI.
package SchemaResource compileDocument(Session sess, in JsonNode doc, string retrievalUri)
{
    if (retrievalUri in sess.docsInProgress)
        throw new SchemaCompileException("circular document compilation via " ~ retrievalUri);
    sess.docsInProgress[retrievalUri] = true;
    scope (exit)
        sess.docsInProgress.remove(retrievalUri);

    auto rootSchema = walk(sess, doc, null, retrievalUri);
    auto res = rootSchema.resource;
    if (retrievalUri.length && res.uri != retrievalUri && retrievalUri !in sess.resources)
        sess.resources[retrievalUri] = res;
    return res;
}

/// Walk one schema location. `frames` is null only at a document root.
private CompiledSchema walk(Session sess, in JsonNode n, Frame[] frames, string rootBase)
{
    if (n.isBoolean)
    {
        if (frames.length == 0)
            frames = [Frame(newResource(sess, rootBase, dialect202012,
                    vocabulariesFor(sess, sess.settings.defaultDialect), n), "")];
        auto s = new CompiledSchema;
        s.isBoolean = true;
        s.boolValue = n.boolean_;
        registerSchema(frames, s);
        return s;
    }
    if (!n.isObject)
        throw new SchemaCompileException("schema must be an object or boolean"
                ~ (frames.length ? " at " ~ frames[$ - 1].ptr : ""));

    // Resource boundary: document root, or an object with `$id`.
    const idNode = n.get("$id");
    if (frames.length == 0 || idNode !is null)
    {
        string dialect = dialectOf(n, frames.length == 0
                ? sess.settings.defaultDialect : frames[$ - 1].res.dialectUri);
        auto vocab = vocabulariesFor(sess, dialect);

        string baseUri = frames.length == 0 ? rootBase : frames[$ - 1].res.uri;
        string uri = baseUri;
        if (idNode !is null)
        {
            if (!idNode.isString)
                throw new SchemaCompileException("$id must be a string");
            uri = resolveUri(baseUri, idNode.string_);
            string b, f;
            splitFragment(uri, b, f);
            if (f.length)
                throw new SchemaCompileException("$id must not contain a fragment: " ~ uri);
            uri = b;
        }
        auto res = newResource(sess, uri, dialect, vocab, n);
        frames ~= Frame(res, "");
    }

    auto s = new CompiledSchema;
    registerSchema(frames, s);
    const vocab = frames[$ - 1].res.vocab;
    auto res = frames[$ - 1].res;

    foreach (ref m; n.members_)
    {
        const key = m.key;
        const(JsonNode)* val = () @trusted { return &m.value; }();
        if (vocab.core && compileCoreKeyword(sess, s, res, key, *val, frames))
            continue;
        if (vocab.applicator && compileApplicatorKeyword(sess, s, key, *val, frames))
            continue;
        if (vocab.unevaluated && compileUnevaluatedKeyword(sess, s, key, *val, frames))
            continue;
        if (vocab.validation && compileValidationKeyword(s, key, *val))
            continue;
        if ((vocab.formatAnnotation || vocab.formatAssertion) && key == "format")
        {
            requireString(*val, "format");
            s.hasFormat = true;
            s.format = val.string_;
            continue;
        }
        if (vocab.content && compileContentKeyword(sess, s, key, *val, frames))
            continue;
        // Unknown keyword (or disabled vocabulary): an annotation; ignored.
    }
    return s;
}

private SchemaResource newResource(Session sess, string uri, string dialect,
        Vocabularies vocab, in JsonNode rawRoot) pure nothrow
{
    auto res = new SchemaResource;
    res.uri = uri;
    res.dialectUri = dialect;
    res.vocab = vocab;
    res.rawRoot = rawRoot.clone;
    if (uri !in sess.resources)
        sess.resources[uri] = res;
    return res;
}

private void registerSchema(Frame[] frames, CompiledSchema s) pure nothrow
{
    s.resource = frames[$ - 1].res;
    s.pointer = frames[$ - 1].ptr;
    foreach (ref f; frames)
        f.res.byPointer[f.ptr] = s;
    if (s.pointer.length == 0)
        s.resource.root = s;
}

// --- keyword compilers (each returns true when it consumed the keyword) ---

private bool compileCoreKeyword(Session sess, CompiledSchema s, SchemaResource res,
        string key, in JsonNode val, Frame[] frames)
{
    switch (key)
    {
    case "$id":
    case "$schema":
    case "$vocabulary":
    case "$comment":
        return true; // handled at resource creation / no runtime effect
    case "$anchor":
        requireString(val, "$anchor");
        res.anchors[val.string_] = s;
        return true;
    case "$dynamicAnchor":
        requireString(val, "$dynamicAnchor");
        res.anchors[val.string_] = s;
        res.dynamicAnchors[val.string_] = s;
        s.hasDynamicAnchor = true;
        s.dynamicAnchorName = val.string_;
        return true;
    case "$ref":
        requireString(val, "$ref");
        s.refInfo = makeRef(sess, res, val.string_, false);
        return true;
    case "$dynamicRef":
        requireString(val, "$dynamicRef");
        s.dynRefInfo = makeRef(sess, res, val.string_, true);
        return true;
    case "$defs":
        requireObject(val, "$defs");
        foreach (ref dm; val.members_)
            walk(sess, dm.value, frames.extend("/$defs/" ~ escapeToken(dm.key)), null);
        return true;
    default:
        return false;
    }
}

private SchemaRef makeRef(Session sess, SchemaResource res, string target, bool dynamic) pure nothrow
{
    auto r = new SchemaRef;
    r.targetUri = resolveUri(res.uri, target);
    r.dynamic = dynamic;
    sess.pending ~= r;
    return r;
}

private bool compileApplicatorKeyword(Session sess, CompiledSchema s, string key,
        in JsonNode val, Frame[] frames)
{
    switch (key)
    {
    case "allOf":
        s.allOf = walkArray(sess, val, frames, key);
        return true;
    case "anyOf":
        s.anyOf = walkArray(sess, val, frames, key);
        return true;
    case "oneOf":
        s.oneOf = walkArray(sess, val, frames, key);
        return true;
    case "not":
        s.notSchema = walk(sess, val, frames.extend("/not"), null);
        return true;
    case "if":
        s.ifSchema = walk(sess, val, frames.extend("/if"), null);
        return true;
    case "then":
        s.thenSchema = walk(sess, val, frames.extend("/then"), null);
        return true;
    case "else":
        s.elseSchema = walk(sess, val, frames.extend("/else"), null);
        return true;
    case "dependentSchemas":
        requireObject(val, key);
        foreach (ref m; val.members_)
            s.dependentSchemas[m.key] = walk(sess, m.value,
                    frames.extend("/dependentSchemas/" ~ escapeToken(m.key)), null);
        return true;
    case "dependencies":
        // Pre-2019 compatibility keyword: an array value behaves like
        // dependentRequired, a schema value like dependentSchemas.
        requireObject(val, key);
        foreach (ref m; val.members_)
        {
            if (m.value.isArray)
            {
                string[] names;
                foreach (ref e; m.value.array_)
                {
                    requireString(e, "dependencies entries");
                    names ~= e.string_;
                }
                s.dependentRequired[m.key] = names;
            }
            else
                s.dependentSchemas[m.key] = walk(sess, m.value,
                        frames.extend("/dependencies/" ~ escapeToken(m.key)), null);
        }
        return true;
    case "properties":
        requireObject(val, key);
        foreach (ref m; val.members_)
            s.properties[m.key] = walk(sess, m.value,
                    frames.extend("/properties/" ~ escapeToken(m.key)), null);
        return true;
    case "patternProperties":
        requireObject(val, key);
        foreach (ref m; val.members_)
        {
            PatternProperty pp;
            pp.source = m.key;
            pp.regex = compileRegex(m.key, "patternProperties");
            pp.schema = walk(sess, m.value,
                    frames.extend("/patternProperties/" ~ escapeToken(m.key)), null);
            s.patternProperties ~= pp;
        }
        return true;
    case "additionalProperties":
        s.additionalProperties = walk(sess, val, frames.extend("/additionalProperties"), null);
        return true;
    case "propertyNames":
        s.propertyNames = walk(sess, val, frames.extend("/propertyNames"), null);
        return true;
    case "prefixItems":
        s.prefixItems = walkArray(sess, val, frames, key);
        s.hasPrefixItems = true;
        return true;
    case "items":
        s.itemsSchema = walk(sess, val, frames.extend("/items"), null);
        return true;
    case "contains":
        s.containsSchema = walk(sess, val, frames.extend("/contains"), null);
        return true;
    default:
        return false;
    }
}

private CompiledSchema[] walkArray(Session sess, in JsonNode val, Frame[] frames, string key)
{
    if (!val.isArray)
        throw new SchemaCompileException(key ~ " must be an array of schemas");
    CompiledSchema[] r;
    r.reserve(val.array_.length);
    foreach (i, ref child; val.array_)
        r ~= walk(sess, child, frames.extend("/" ~ key ~ "/" ~ i.to!string), null);
    return r;
}

private bool compileUnevaluatedKeyword(Session sess, CompiledSchema s, string key,
        in JsonNode val, Frame[] frames)
{
    switch (key)
    {
    case "unevaluatedItems":
        s.unevaluatedItems = walk(sess, val, frames.extend("/unevaluatedItems"), null);
        return true;
    case "unevaluatedProperties":
        s.unevaluatedProperties = walk(sess, val, frames.extend("/unevaluatedProperties"), null);
        return true;
    default:
        return false;
    }
}

private bool compileContentKeyword(Session sess, CompiledSchema s, string key,
        in JsonNode val, Frame[] frames)
{
    switch (key)
    {
    case "contentEncoding":
        requireString(val, key);
        s.contentEncoding = val.string_;
        return true;
    case "contentMediaType":
        requireString(val, key);
        s.contentMediaType = val.string_;
        return true;
    case "contentSchema":
        s.contentSchema = walk(sess, val, frames.extend("/contentSchema"), null);
        return true;
    default:
        return false;
    }
}

private bool compileValidationKeyword(CompiledSchema s, string key, in JsonNode val)
{
    switch (key)
    {
    case "type":
        s.hasType = true;
        s.typeMask = parseTypeMask(val);
        return true;
    case "enum":
        if (!val.isArray)
            throw new SchemaCompileException("enum must be an array");
        s.hasEnum = true;
        foreach (ref e; val.array_)
            s.enumValues ~= e.clone;
        return true;
    case "const":
        s.hasConst = true;
        s.constValue = val.clone;
        return true;
    case "multipleOf":
        s.hasMultipleOf = true;
        s.multipleOf = numberOf(val, key);
        return true;
    case "maximum":
        s.hasMaximum = true;
        s.maximum = numberOf(val, key);
        return true;
    case "exclusiveMaximum":
        s.hasExclusiveMaximum = true;
        s.exclusiveMaximum = numberOf(val, key);
        return true;
    case "minimum":
        s.hasMinimum = true;
        s.minimum = numberOf(val, key);
        return true;
    case "exclusiveMinimum":
        s.hasExclusiveMinimum = true;
        s.exclusiveMinimum = numberOf(val, key);
        return true;
    case "maxLength":
        s.maxLength = nonNegativeIntegerOf(val, key);
        return true;
    case "minLength":
        s.minLength = nonNegativeIntegerOf(val, key);
        return true;
    case "pattern":
        requireString(val, key);
        s.hasPattern = true;
        s.patternSource = val.string_;
        s.pattern = compileRegex(val.string_, "pattern");
        return true;
    case "maxItems":
        s.maxItems = nonNegativeIntegerOf(val, key);
        return true;
    case "minItems":
        s.minItems = nonNegativeIntegerOf(val, key);
        return true;
    case "uniqueItems":
        if (!val.isBoolean)
            throw new SchemaCompileException("uniqueItems must be a boolean");
        s.uniqueItems = val.boolean_;
        return true;
    case "maxContains":
        s.maxContains = nonNegativeIntegerOf(val, key);
        return true;
    case "minContains":
        s.minContains = nonNegativeIntegerOf(val, key);
        return true;
    case "maxProperties":
        s.maxProperties = nonNegativeIntegerOf(val, key);
        return true;
    case "minProperties":
        s.minProperties = nonNegativeIntegerOf(val, key);
        return true;
    case "required":
        if (!val.isArray)
            throw new SchemaCompileException("required must be an array of strings");
        foreach (ref e; val.array_)
        {
            requireString(e, "required entries");
            s.required ~= e.string_;
        }
        return true;
    case "dependentRequired":
        requireObject(val, key);
        foreach (ref m; val.members_)
        {
            if (!m.value.isArray)
                throw new SchemaCompileException("dependentRequired values must be arrays");
            string[] names;
            foreach (ref e; m.value.array_)
            {
                requireString(e, "dependentRequired entries");
                names ~= e.string_;
            }
            s.dependentRequired[m.key] = names;
        }
        return true;
    default:
        return false;
    }
}

private ubyte parseTypeMask(in JsonNode val) pure
{
    static ubyte one(in JsonNode v)
    {
        if (!v.isString)
            throw new SchemaCompileException("type must be a string or array of strings");
        switch (v.string_)
        {
        case "null":
            return TypeBit.null_;
        case "boolean":
            return TypeBit.boolean;
        case "object":
            return TypeBit.object;
        case "array":
            return TypeBit.array;
        case "number":
            return TypeBit.number;
        case "string":
            return TypeBit.string_;
        case "integer":
            return TypeBit.integer;
        default:
            throw new SchemaCompileException("unknown type name: " ~ v.string_);
        }
    }

    if (val.isArray)
    {
        ubyte mask;
        foreach (ref e; val.array_)
            mask |= one(e);
        return mask;
    }
    return one(val);
}

private JsonNumber numberOf(in JsonNode val, string keyword) pure
{
    alias K = JsonNode.Kind;
    switch (val.kind)
    {
    case K.integer:
        return JsonNumber.ofLong(val.integer_);
    case K.uinteger:
        return JsonNumber.ofULong(val.uinteger_);
    case K.floating:
        return JsonNumber.ofDouble(val.floating_);
    default:
        throw new SchemaCompileException(keyword ~ " must be a number");
    }
}

private long nonNegativeIntegerOf(in JsonNode val, string keyword) pure
{
    alias K = JsonNode.Kind;
    long v;
    switch (val.kind)
    {
    case K.integer:
        v = val.integer_;
        break;
    case K.uinteger:
        v = long.max; // beyond any practical length; clamp
        break;
    case K.floating:
        import std.math : floor, isFinite;

        if (!isFinite(val.floating_) || val.floating_ != floor(val.floating_))
            throw new SchemaCompileException(keyword ~ " must be a non-negative integer");
        v = cast(long) val.floating_;
        break;
    default:
        throw new SchemaCompileException(keyword ~ " must be a non-negative integer");
    }
    if (v < 0)
        throw new SchemaCompileException(keyword ~ " must be a non-negative integer");
    return v;
}

private void requireString(in JsonNode val, string what) pure
{
    if (!val.isString)
        throw new SchemaCompileException(what ~ " must be a string");
}

private void requireObject(in JsonNode val, string what) pure
{
    if (!val.isObject)
        throw new SchemaCompileException(what ~ " must be an object");
}

package auto compileRegex(string source, string keyword)
{
    import std.regex : regex, RegexException;

    try
        return regex(ecmaShorthand(source));
    catch (RegexException e)
        throw new SchemaCompileException("invalid " ~ keyword ~ " regular expression '"
                ~ source ~ "': " ~ e.msg);
}

// ECMA-262 whitespace: TAB-CR, SP, NBSP, ZWNBSP, and the Unicode Zs / line
// separator characters (as D \u escapes, literal characters in the class).
private enum ecmaSpace = "\\t-\\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff";

/// Translate the ECMA-262 shorthand classes \d \w \s (and negations) into
/// their ASCII-only / ECMA-exact equivalents. std.regex interprets them as
/// Unicode-aware classes, but JSON Schema patterns use ECMA-262 semantics
/// where \d is exactly [0-9] and \w is [A-Za-z0-9_].
package string ecmaShorthand(string src) pure
{
    string r;
    r.reserve(src.length);
    bool inClass = false;
    size_t i = 0;
    while (i < src.length)
    {
        const c = src[i];
        if (c == '\\' && i + 1 < src.length)
        {
            // UTS#18-style property names ECMA allows but std.regex does not.
            if (src.length >= i + 9 && src[i + 1] == 'p' && src[i + 2 .. i + 9] == "{digit}")
            {
                r ~= "\\p{Nd}";
                i += 9;
                continue;
            }
            const e = src[i + 1];
            string outOpen = inClass ? "" : "[";
            string outClose = inClass ? "" : "]";
            switch (e)
            {
            case 'd':
                r ~= outOpen ~ "0-9" ~ outClose;
                break;
            case 'w':
                r ~= outOpen ~ "A-Za-z0-9_" ~ outClose;
                break;
            case 's':
                r ~= outOpen ~ ecmaSpace ~ outClose;
                break;
            case 'D':
                if (inClass)
                    r ~= `\D`; // not expressible inside a class; keep as-is
                else
                    r ~= "[^0-9]";
                break;
            case 'W':
                if (inClass)
                    r ~= `\W`;
                else
                    r ~= "[^A-Za-z0-9_]";
                break;
            case 'S':
                if (inClass)
                    r ~= `\S`;
                else
                    r ~= "[^" ~ ecmaSpace ~ "]";
                break;
            case 'a':
                // ECMA-262 has no \a control escape; it is an identity
                // escape for the letter 'a' (std.regex would read BEL).
                r ~= 'a';
                break;
            default:
                r ~= src[i .. i + 2];
            }
            i += 2;
            continue;
        }
        if (c == '[' && !inClass)
            inClass = true;
        else if (c == ']' && inClass)
            inClass = false;
        r ~= c;
        i++;
    }
    return r;
}

// --- reference resolution ---

private void resolvePendingRefs(Session sess)
{
    while (sess.pending.length)
    {
        auto r = sess.pending[0];
        sess.pending = sess.pending[1 .. $];
        resolveRef(sess, r);
    }
}

private void resolveRef(Session sess, SchemaRef r)
{
    string base, frag;
    splitFragment(r.targetUri, base, frag);
    auto res = findResource(sess, base);

    CompiledSchema target;
    string anchorName;
    if (frag.length == 0)
        target = res.root;
    else if (frag[0] == '/')
    {
        const decoded = percentDecode(frag);
        string[] tokens;
        if (!parsePointer(decoded, tokens))
            throw new SchemaCompileException("invalid JSON Pointer fragment in $ref: " ~ r.targetUri);
        target = lookupPointer(sess, res, tokens);
        if (target is null)
            throw new SchemaCompileException("$ref target not found: " ~ r.targetUri);
    }
    else
    {
        anchorName = percentDecode(frag);
        if (auto p = anchorName in res.anchors)
            target = *p;
        else
            throw new SchemaCompileException("$ref anchor not found: " ~ r.targetUri);
    }

    r.target = target;
    if (r.dynamic && anchorName.length)
    {
        r.anchorName = anchorName;
        auto dyn = anchorName in res.dynamicAnchors;
        r.dynamicCandidate = dyn !is null && *dyn is target;
    }
}

private CompiledSchema lookupPointer(Session sess, SchemaResource res, string[] tokens)
{
    string canonical;
    foreach (tok; tokens)
        canonical ~= "/" ~ escapeToken(tok);
    if (auto p = canonical in res.byPointer)
        return *p;

    // The pointer may address a location that is not a known schema position
    // (e.g. inside an unknown keyword). Per spec such a location is still a
    // valid reference target: compile it on the fly against this resource's
    // base URI ($id/$anchor inside it were never identifiers).
    auto raw = evaluatePointer(() @trusted { return &res.rawRoot; }(), tokens);
    if (raw is null)
        return null;
    auto s = walk(sess, *raw, [Frame(res, canonical)], null);
    return s;
}

private SchemaResource findResource(Session sess, string base)
{
    if (auto p = base in sess.resources)
        return *p;
    if (auto doc = sess.store.lookup(base))
        return compileDocument(sess, *doc, base);
    if (sess.settings.resolver !is null)
    {
        auto doc = sess.settings.resolver(base);
        sess.store.register(base, doc);
        return compileDocument(sess, doc, base);
    }
    throw new SchemaCompileException(
            "unresolvable reference to '" ~ base ~ "' (schema not registered; "
            ~ "register it in the SchemaStore or supply a resolver)");
}
