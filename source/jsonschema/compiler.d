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
    auto validator = new Validator(root.root, settings);
    validator.usesUnevaluated = sess.usesUnevaluated;
    validator.usesDynamicScope = sess.usesDynamicScope;
    return validator;
}

/// Compile a schema from JSON text.
Validator compileSchema(string jsonText, ValidatorSettings settings = ValidatorSettings.init)
{
    return compileSchema(parseJson(jsonText), settings);
}

/// Compile a schema given as a `std.json` value.
Validator compileSchema(in std.json.JSONValue doc,
        ValidatorSettings settings = ValidatorSettings.init)
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
    /// Set when any compiled schema in this validator declares
    /// `unevaluatedProperties` or `unevaluatedItems`. When false, the evaluator
    /// can skip all `Evaluated` annotation bookkeeping.
    bool usesUnevaluated;
    /// Set when any `$dynamicRef`/`$recursiveRef` resolves through the dynamic
    /// scope. When false, the evaluator never consults the dynamic-scope stack,
    /// so it can skip maintaining it entirely (avoiding a per-validation
    /// allocation for the root push).
    bool usesDynamicScope;

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

// 2020-12 vocabulary URIs.
private enum vocabCore = "https://json-schema.org/draft/2020-12/vocab/core";
private enum vocabApplicator = "https://json-schema.org/draft/2020-12/vocab/applicator";
private enum vocabUnevaluated = "https://json-schema.org/draft/2020-12/vocab/unevaluated";
private enum vocabValidation = "https://json-schema.org/draft/2020-12/vocab/validation";
private enum vocabMetaData = "https://json-schema.org/draft/2020-12/vocab/meta-data";
private enum vocabFormatAnnotation = "https://json-schema.org/draft/2020-12/vocab/format-annotation";
private enum vocabFormatAssertion = "https://json-schema.org/draft/2020-12/vocab/format-assertion";
private enum vocabContent = "https://json-schema.org/draft/2020-12/vocab/content";

// 2019-09 vocabulary URIs. 2019-09 has no separate "unevaluated" vocabulary —
// `unevaluatedItems`/`unevaluatedProperties` live in the applicator vocabulary —
// and a single "format" vocabulary (annotation only).
private enum vocab19Core = "https://json-schema.org/draft/2019-09/vocab/core";
private enum vocab19Applicator = "https://json-schema.org/draft/2019-09/vocab/applicator";
private enum vocab19Validation = "https://json-schema.org/draft/2019-09/vocab/validation";
private enum vocab19MetaData = "https://json-schema.org/draft/2019-09/vocab/meta-data";
private enum vocab19Format = "https://json-schema.org/draft/2019-09/vocab/format";
private enum vocab19Content = "https://json-schema.org/draft/2019-09/vocab/content";

/// A dialect resolved to the draft it belongs to and the vocabulary set in
/// effect for resources declaring it.
package struct DialectInfo
{
    Draft draft;
    Vocabularies vocab;
}

/// Map a well-known dialect URI to its draft, or 2020-12 for an unknown URI.
package Draft draftOf(string dialectUri) pure nothrow
{
    switch (dialectUri)
    {
    case dialect201909:
        return Draft.draft2019_09;
    case dialect07:
    case "http://json-schema.org/draft-07/schema":
        return Draft.draft07;
    default:
        return Draft.draft2020_12;
    }
}

/// The default vocabulary set for a draft, used for the standard dialects and
/// for custom meta-schemas that omit `$vocabulary`.
private Vocabularies defaultVocabularies(Draft draft) pure nothrow
{
    Vocabularies v; // init: every capability on except format-assertion
    if (draft == Draft.draft07)
        v.unevaluated = false; // draft-07 has no unevaluated* keywords
    return v;
}

/// Determine the draft and vocabulary set for a dialect URI. The standard
/// 2020-12 / 2019-09 / draft-07 URIs map directly; any other URI must name a
/// registered meta-schema document, whose `$schema` fixes the draft family and
/// whose `$vocabulary` (when present) is honored. Unknown dialects are refused.
package DialectInfo dialectInfoFor(Session sess, string dialectUri)
{
    if (dialectUri == dialect202012 || dialectUri == "")
        return DialectInfo(Draft.draft2020_12, defaultVocabularies(Draft.draft2020_12));
    if (dialectUri == dialect201909)
        return DialectInfo(Draft.draft2019_09, defaultVocabularies(Draft.draft2019_09));
    if (dialectUri == dialect07 || dialectUri == "http://json-schema.org/draft-07/schema")
        return DialectInfo(Draft.draft07, defaultVocabularies(Draft.draft07));

    string base, frag;
    splitFragment(dialectUri, base, frag);
    auto doc = sess.store.lookup(base);
    if (doc is null)
        throw new UnsupportedDialectException(dialectUri);

    // The meta-schema's own `$schema` fixes which draft (and thus which
    // vocabulary keywords behave as) the dialect belongs to.
    Draft metaDraft = Draft.draft2020_12;
    if (auto s = doc.get("$schema"))
        if (s.isString)
            metaDraft = draftOf(s.string_);

    auto vocabNode = doc.get("$vocabulary");
    if (vocabNode is null || !vocabNode.isObject)
        return DialectInfo(metaDraft, defaultVocabularies(metaDraft));

    Vocabularies v = Vocabularies(false, false, false, false, false, false, false, false);
    foreach (ref m; vocabNode.members_)
    {
        const required = m.value.isBoolean && m.value.boolean_;
        switch (m.key)
        {
        case vocabCore:
        case vocab19Core:
            v.core = true;
            break;
        case vocabApplicator:
            v.applicator = true;
            break;
        case vocab19Applicator:
            // 2019-09 folds the unevaluated* keywords into the applicator vocab.
            v.applicator = true;
            v.unevaluated = true;
            break;
        case vocabUnevaluated:
            v.unevaluated = true;
            break;
        case vocabValidation:
        case vocab19Validation:
            v.validation = true;
            break;
        case vocabMetaData:
        case vocab19MetaData:
            v.metaData = true;
            break;
        case vocabFormatAnnotation:
        case vocab19Format:
            v.formatAnnotation = true;
            break;
        case vocabFormatAssertion:
            v.formatAssertion = true;
            break;
        case vocabContent:
        case vocab19Content:
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
    return DialectInfo(metaDraft, v);
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
        {
            const di = dialectInfoFor(sess, sess.settings.defaultDialect);
            frames = [
                Frame(newResource(sess, rootBase, sess.settings.defaultDialect,
                        di.draft, di.vocab, n), "")
            ];
        }
        auto s = new CompiledSchema;
        s.isBoolean = true;
        s.boolValue = n.boolean_;
        registerSchema(frames, s);
        return s;
    }
    if (!n.isObject)
        throw new SchemaCompileException("schema must be an object or boolean" ~ (
                frames.length ? " at " ~ frames[$ - 1].ptr : ""));

    // The draft in scope for this node (its own `$schema` at the root, else the
    // parent resource's) determines how `$id` and a sibling `$ref` interact.
    const enclosingDraft = frames.length == 0
        ? draftOf(dialectOf(n, sess.settings.defaultDialect)) : frames[$ - 1].res.draft;

    // Up to draft-07 a sibling `$ref` suppresses `$id` entirely (no base change
    // and no anchor): the `$ref` resolves against the enclosing base URI.
    const idNode = (enclosingDraft <= Draft.draft07 && n.get("$ref") !is null)
        ? null : n.get("$id");

    // In drafts up to draft-07 a plain-fragment `$id` ("#name") is a
    // location-independent identifier (the predecessor of `$anchor`); it names
    // the current schema without opening a new resource / base URI.
    string anchorFromId;
    bool idIsAnchorOnly;
    if (idNode !is null && idNode.isString && enclosingDraft <= Draft.draft07
            && idNode.string_.length && idNode.string_[0] == '#')
    {
        anchorFromId = idNode.string_[1 .. $];
        idIsAnchorOnly = true;
    }

    // Resource boundary: document root, or an object with a base-changing `$id`.
    if (frames.length == 0 || (idNode !is null && !idIsAnchorOnly))
    {
        string dialect = dialectOf(n, frames.length == 0
                ? sess.settings.defaultDialect : frames[$ - 1].res.dialectUri);
        auto di = dialectInfoFor(sess, dialect);

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
            {
                // draft-07 tolerates a fragment on a base-changing `$id`; it
                // doubles as a plain-name anchor. Later drafts forbid it.
                if (di.draft <= Draft.draft07)
                    anchorFromId = f;
                else
                    throw new SchemaCompileException(
                            "$id must not contain a fragment: " ~ uri);
            }
            uri = b;
        }
        auto res = newResource(sess, uri, dialect, di.draft, di.vocab, n);
        frames ~= Frame(res, "");
    }

    auto s = new CompiledSchema;
    registerSchema(frames, s);
    if (anchorFromId.length)
        frames[$ - 1].res.anchors[anchorFromId] = s;
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

    s.hasInPlaceApplicators = s.allOf.length > 0 || s.anyOf.length > 0
        || s.oneOf.length > 0 || s.notSchema !is null || s.ifSchema !is null;

    s.isSimpleScalar = !s.isBoolean && s.refInfo is null && s.dynRefInfo is null
        && !s.hasInPlaceApplicators && !s.hasFormat
        && s.properties.length == 0 && s.patternProperties.length == 0
        && s.additionalProperties is null && s.propertyNames is null
        && s.required.length == 0 && s.dependentRequired.length == 0
        && s.dependentSchemas.length == 0
        && s.maxProperties == absent && s.minProperties == absent
        && !s.hasPrefixItems && s.itemsSchema is null
        && s.additionalItemsSchema is null && s.containsSchema is null
        && s.maxItems == absent && s.minItems == absent && !s.uniqueItems
        && s.unevaluatedProperties is null && s.unevaluatedItems is null
        && s.contentSchema is null;

    // Partition `required` against `properties`: a name that is also a property
    // gets its `PropEntry.required` bit set (so the property scan counts it),
    // the rest go to `requiredExtra` for an explicit instance lookup.
    foreach (name; s.required)
    {
        if (auto p = name in s.properties)
        {
            p.required = true;
            s.requiredInProps++;
        }
        else
            s.requiredExtra ~= name;
    }

    // Flatten `properties` into parallel arrays sorted by key for the hot
    // binary-search lookup in `checkObject`. The `required` bits set above are
    // already in place, so the copied `PropEntry`s carry them.
    if (s.properties.length)
    {
        import std.algorithm : sort;

        s.propKeys = s.properties.keys;
        sort(s.propKeys);
        s.propVals.length = s.propKeys.length;
        foreach (i, k; s.propKeys)
            s.propVals[i] = s.properties[k];
    }
    return s;
}

private SchemaResource newResource(Session sess, string uri, string dialect,
        Draft draft, Vocabularies vocab, in JsonNode rawRoot) pure nothrow
{
    auto res = new SchemaResource;
    res.uri = uri;
    res.dialectUri = dialect;
    res.draft = draft;
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

private bool compileCoreKeyword(Session sess, CompiledSchema s,
        SchemaResource res, string key, in JsonNode val, Frame[] frames)
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
        // Up to draft-07, `$ref` suppresses every sibling keyword.
        if (res.draft <= Draft.draft07)
            s.refIsExclusive = true;
        return true;
    case "$dynamicRef":
        requireString(val, "$dynamicRef");
        s.dynRefInfo = makeRef(sess, res, val.string_, true);
        return true;
    case "$recursiveRef":
        // 2019-09 predecessor of `$dynamicRef`: always "#", resolved against
        // the outermost in-scope `$recursiveAnchor`.
        requireString(val, "$recursiveRef");
        s.dynRefInfo = makeRef(sess, res, val.string_, true);
        s.dynRefInfo.recursive = true;
        return true;
    case "$recursiveAnchor":
        // 2019-09: a boolean marker (not a name) on a resource root. Modelled
        // as a dynamic anchor under the implicit empty name.
        if (!val.isBoolean)
            throw new SchemaCompileException("$recursiveAnchor must be a boolean");
        if (val.boolean_)
        {
            res.dynamicAnchors[""] = s;
            s.hasDynamicAnchor = true;
            s.dynamicAnchorName = "";
        }
        return true;
    case "$defs":
        requireObject(val, "$defs");
        foreach (ref dm; val.members_)
            walk(sess, dm.value, frames.extend("/$defs/" ~ escapeToken(dm.key)), null);
        return true;
    case "definitions":
        // The pre-2019 name for `$defs`, retained in 2019-09 for compatibility.
        // Walked so embedded `$id`/`$anchor`/`$ref` targets register; in 2020-12
        // it is not a keyword (left to compile lazily on reference).
        if (res.draft == Draft.draft2020_12)
            return false;
        requireObject(val, "definitions");
        foreach (ref dm; val.members_)
            walk(sess, dm.value, frames.extend("/definitions/" ~ escapeToken(dm.key)), null);
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
        // Introduced in 2019-09; ignored as an unknown keyword in draft-07.
        if (frames[$ - 1].res.draft <= Draft.draft07)
            return false;
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
            s.properties[m.key] = PropEntry(walk(sess, m.value,
                    frames.extend("/properties/" ~ escapeToken(m.key)), null));
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
        // A 2020-12 keyword only; ignored (an unknown keyword) in older drafts,
        // which is exactly what cross-draft references rely on.
        if (frames[$ - 1].res.draft != Draft.draft2020_12)
            return false;
        s.prefixItems = walkArray(sess, val, frames, key);
        s.hasPrefixItems = true;
        return true;
    case "items":
        // Pre-2020-12, an array `items` is a tuple (the role `prefixItems` took
        // over in 2020-12); a single schema applies to every item.
        if (frames[$ - 1].res.draft != Draft.draft2020_12 && val.isArray)
        {
            s.prefixItems = walkArray(sess, val, frames, key);
            s.hasPrefixItems = true;
        }
        else
            s.itemsSchema = walk(sess, val, frames.extend("/items"), null);
        return true;
    case "additionalItems":
        // Pre-2020-12 companion to a tuple `items`; applies to items beyond the
        // tuple. Not a keyword in 2020-12 (left for `items` to cover the rest).
        if (frames[$ - 1].res.draft == Draft.draft2020_12)
            return false;
        s.additionalItemsSchema = walk(sess, val, frames.extend("/additionalItems"), null);
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
        sess.usesUnevaluated = true;
        s.unevaluatedItems = walk(sess, val, frames.extend("/unevaluatedItems"), null);
        return true;
    case "unevaluatedProperties":
        sess.usesUnevaluated = true;
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
        // Introduced in 2019-09; in draft-07 it is an unknown keyword (the
        // combined `dependencies` covered this), so leave it to be ignored.
        if (s.resource.draft <= Draft.draft07)
            return false;
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
        throw new SchemaCompileException(
                "invalid " ~ keyword ~ " regular expression '" ~ source ~ "': " ~ e.msg);
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
            throw new SchemaCompileException("invalid JSON Pointer fragment in $ref: " ~ r
                    .targetUri);
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
    if (r.recursive)
    {
        // `$recursiveRef` redirects to the dynamic scope only when its target
        // resource itself carries `$recursiveAnchor: true` (the empty-name
        // dynamic anchor); otherwise it behaves as a plain `$ref`.
        r.anchorName = "";
        r.dynamicCandidate = ("" in res.dynamicAnchors) !is null;
        if (r.dynamicCandidate)
            sess.usesDynamicScope = true;
    }
    else if (r.dynamic && anchorName.length)
    {
        r.anchorName = anchorName;
        auto dyn = anchorName in res.dynamicAnchors;
        r.dynamicCandidate = dyn !is null && *dyn is target;
        if (r.dynamicCandidate)
            sess.usesDynamicScope = true;
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
    throw new SchemaCompileException("unresolvable reference to '" ~ base
            ~ "' (schema not registered; " ~ "register it in the SchemaStore or supply a resolver)");
}

// --- tests ---

version (unittest)
{
    import std.exception : assertThrown;

    private bool ok(Validator v, string instance)
    {
        return v.validate(parseJson(instance)).valid;
    }
}

unittest  // compileSchema accepts a std.json value directly
{
    import std.json : parseJSON;

    auto v = compileSchema(parseJSON(`{"type": "integer"}`));
    assert(ok(v, "3"));
    assert(!ok(v, `"x"`));
}

unittest  // a custom 2020-12 meta-schema's $vocabulary is honored
{
    auto store = new SchemaStore;
    store.register("https://example.com/meta-all", `{
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://example.com/meta-all",
        "$vocabulary": {
            "https://json-schema.org/draft/2020-12/vocab/core": true,
            "https://json-schema.org/draft/2020-12/vocab/applicator": true,
            "https://json-schema.org/draft/2020-12/vocab/unevaluated": true,
            "https://json-schema.org/draft/2020-12/vocab/validation": true,
            "https://json-schema.org/draft/2020-12/vocab/meta-data": true,
            "https://json-schema.org/draft/2020-12/vocab/format-assertion": true,
            "https://json-schema.org/draft/2020-12/vocab/content": true
        }
    }`);
    ValidatorSettings settings;
    settings.store = store;
    auto v = compileSchema(`{
        "$schema": "https://example.com/meta-all",
        "type": "integer",
        "format": "ipv4"
    }`, settings);
    assert(ok(v, "3"));
    assert(!ok(v, `"x"`));
    // format-assertion vocabulary makes format constrain strings.
    auto sv = compileSchema(`{"$schema": "https://example.com/meta-all", "format": "ipv4"}`,
            settings);
    assert(!ok(sv, `"not-an-ip"`));
    assert(ok(sv, `"127.0.0.1"`));
}

unittest  // a 2019-09 meta-schema's vocabulary URIs map to the right capabilities
{
    auto store = new SchemaStore;
    store.register("https://example.com/meta-2019", `{
        "$schema": "https://json-schema.org/draft/2019-09/schema",
        "$id": "https://example.com/meta-2019",
        "$vocabulary": {
            "https://json-schema.org/draft/2019-09/vocab/core": true,
            "https://json-schema.org/draft/2019-09/vocab/applicator": true,
            "https://json-schema.org/draft/2019-09/vocab/validation": true,
            "https://json-schema.org/draft/2019-09/vocab/meta-data": true,
            "https://json-schema.org/draft/2019-09/vocab/format": true,
            "https://json-schema.org/draft/2019-09/vocab/content": true
        }
    }`);
    ValidatorSettings settings;
    settings.store = store;
    auto v = compileSchema(`{
        "$schema": "https://example.com/meta-2019",
        "type": "object",
        "properties": {"a": {"type": "integer"}},
        "unevaluatedProperties": false
    }`, settings);
    assert(ok(v, `{"a": 1}`));
    assert(!ok(v, `{"b": 2}`));
}

unittest  // a custom meta-schema without $vocabulary falls back to its draft defaults
{
    auto store = new SchemaStore;
    store.register("https://example.com/meta-bare", `{
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://example.com/meta-bare"
    }`);
    ValidatorSettings settings;
    settings.store = store;
    auto v = compileSchema(`{"$schema": "https://example.com/meta-bare", "type": "string"}`,
            settings);
    assert(ok(v, `"x"`));
    assert(!ok(v, "1"));
}

unittest  // a required vocabulary we do not implement is refused
{
    auto store = new SchemaStore;
    store.register("https://example.com/meta-unknown", `{
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://example.com/meta-unknown",
        "$vocabulary": {
            "https://json-schema.org/draft/2020-12/vocab/core": true,
            "https://example.com/vocab/custom": true
        }
    }`);
    ValidatorSettings settings;
    settings.store = store;
    assertThrown!UnsupportedDialectException(
            compileSchema(`{"$schema": "https://example.com/meta-unknown"}`, settings));
}

unittest  // an optional unknown vocabulary is tolerated
{
    auto store = new SchemaStore;
    store.register("https://example.com/meta-opt", `{
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://example.com/meta-opt",
        "$vocabulary": {
            "https://json-schema.org/draft/2020-12/vocab/core": true,
            "https://example.com/vocab/custom": false
        }
    }`);
    ValidatorSettings settings;
    settings.store = store;
    auto v = compileSchema(`{"$schema": "https://example.com/meta-opt"}`, settings);
    assert(ok(v, "1"));
}

unittest  // a meta-schema lacking the core vocabulary is refused
{
    auto store = new SchemaStore;
    store.register("https://example.com/meta-nocore", `{
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://example.com/meta-nocore",
        "$vocabulary": {
            "https://json-schema.org/draft/2020-12/vocab/validation": true
        }
    }`);
    ValidatorSettings settings;
    settings.store = store;
    assertThrown!UnsupportedDialectException(
            compileSchema(`{"$schema": "https://example.com/meta-nocore"}`, settings));
}

unittest  // draft-07 definitions are walked so embedded $ref targets resolve
{
    auto v = compileSchema(`{
        "$schema": "http://json-schema.org/draft-07/schema#",
        "definitions": {"pos": {"type": "integer", "minimum": 1}},
        "properties": {"n": {"$ref": "#/definitions/pos"}}
    }`);
    assert(ok(v, `{"n": 3}`));
    assert(!ok(v, `{"n": 0}`));
}

unittest  // draft-07 dependencies: array form and schema form
{
    auto v = compileSchema(`{
        "$schema": "http://json-schema.org/draft-07/schema#",
        "dependencies": {
            "credit_card": ["billing_address"],
            "name": {"properties": {"age": {"type": "integer"}}}
        }
    }`);
    assert(ok(v, `{"credit_card": 1, "billing_address": "x"}`));
    assert(!ok(v, `{"credit_card": 1}`));
    assert(ok(v, `{"name": "n", "age": 3}`));
    assert(!ok(v, `{"name": "n", "age": "three"}`));
}

unittest  // draft-07 tuple items with additionalItems
{
    auto v = compileSchema(`{
        "$schema": "http://json-schema.org/draft-07/schema#",
        "items": [{"type": "integer"}, {"type": "string"}],
        "additionalItems": {"type": "boolean"}
    }`);
    assert(ok(v, `[1, "x"]`));
    assert(ok(v, `[1, "x", true, false]`));
    assert(!ok(v, `[1, "x", 3]`));
}

unittest  // content keywords compile (annotations; always pass)
{
    auto v = compileSchema(`{
        "type": "string",
        "contentEncoding": "base64",
        "contentMediaType": "application/json",
        "contentSchema": {"type": "object"}
    }`);
    assert(ok(v, `"anything"`));
}

unittest  // exclusiveMaximum / exclusiveMinimum bounds
{
    auto v = compileSchema(`{"exclusiveMaximum": 5, "exclusiveMinimum": 1}`);
    assert(ok(v, "3"));
    assert(!ok(v, "5"));
    assert(!ok(v, "1"));
}

unittest  // object and array size bounds compile and apply
{
    auto v = compileSchema(`{"maxProperties": 2, "minProperties": 1}`);
    assert(ok(v, `{"a": 1}`));
    assert(!ok(v, `{}`));
    assert(!ok(v, `{"a": 1, "b": 2, "c": 3}`));

    auto a = compileSchema(`{"maxItems": 2, "minItems": 1}`);
    assert(ok(a, "[1]"));
    assert(!ok(a, "[]"));
    assert(!ok(a, "[1,2,3]"));
}

unittest  // a ulong-range numeric bound compiles via the unsigned path
{
    auto v = compileSchema(`{"maximum": 18446744073709551615}`);
    assert(ok(v, "1"));
}

unittest  // a non-negative integer keyword accepts an integral float and a huge uint
{
    assert(ok(compileSchema(`{"minLength": 2.0}`), `"abc"`));
    assert(!ok(compileSchema(`{"minLength": 2.0}`), `"a"`));
    // A ulong-range length clamps; nothing realistic exceeds it.
    auto v = compileSchema(`{"minItems": 18446744073709551615}`);
    assert(!ok(v, "[1,2,3]"));
}

unittest  // draft-07 ignores 2019-09+ keywords (dependentRequired, dependentSchemas)
{
    auto v = compileSchema(`{
        "$schema": "http://json-schema.org/draft-07/schema#",
        "dependentRequired": {"a": ["b"]},
        "dependentSchemas": {"a": {"required": ["c"]}}
    }`);
    // Both are unknown keywords in draft-07, hence ignored.
    assert(ok(v, `{"a": 1}`));
}

unittest  // schema-shape compile errors are reported
{
    assertThrown!SchemaCompileException(compileSchema(`{"$schema": 1}`));
    assertThrown!SchemaCompileException(compileSchema(`{"properties": {"a": 1}}`));
    assertThrown!SchemaCompileException(compileSchema(`{"$id": 1}`));
    assertThrown!SchemaCompileException(compileSchema(`{"$ref": 1}`));
    assertThrown!SchemaCompileException(compileSchema(`{"properties": 1}`));
    assertThrown!SchemaCompileException(compileSchema(`{"allOf": 1}`));
}

unittest  // validation-keyword compile errors are reported
{
    assertThrown!SchemaCompileException(compileSchema(`{"type": 1}`));
    assertThrown!SchemaCompileException(compileSchema(`{"type": "bogus"}`));
    assertThrown!SchemaCompileException(compileSchema(`{"enum": 1}`));
    assertThrown!SchemaCompileException(compileSchema(`{"maximum": "x"}`));
    assertThrown!SchemaCompileException(compileSchema(`{"minLength": 1.5}`));
    assertThrown!SchemaCompileException(compileSchema(`{"minLength": "x"}`));
    assertThrown!SchemaCompileException(compileSchema(`{"minLength": -1}`));
    assertThrown!SchemaCompileException(compileSchema(`{"uniqueItems": "x"}`));
    assertThrown!SchemaCompileException(compileSchema(`{"required": "x"}`));
    assertThrown!SchemaCompileException(compileSchema(`{"dependentRequired": {"a": "notarray"}}`));
}

unittest  // a type array combines several type bits
{
    auto v = compileSchema(`{"type": ["integer", "boolean", "null"]}`);
    assert(ok(v, "1"));
    assert(ok(v, "true"));
    assert(ok(v, "null"));
    assert(!ok(v, `"x"`));
}

unittest  // $recursiveAnchor must be a boolean
{
    assertThrown!SchemaCompileException(compileSchema(`{
        "$schema": "https://json-schema.org/draft/2019-09/schema",
        "$recursiveAnchor": "yes"
    }`));
}

unittest  // 2020-12 forbids a fragment on a base-changing $id
{
    assertThrown!SchemaCompileException(
            compileSchema(`{"$id": "https://example.com/x#frag"}`));
}

unittest  // draft-07 tolerates a fragment on $id as a plain-name anchor
{
    auto v = compileSchema(`{
        "$schema": "http://json-schema.org/draft-07/schema#",
        "$id": "https://example.com/root#thing",
        "definitions": {"t": {"$id": "#named", "type": "string"}},
        "properties": {"p": {"$ref": "#named"}}
    }`);
    assert(ok(v, `{"p": "x"}`));
    assert(!ok(v, `{"p": 1}`));
}

unittest  // $ref resolution failures throw with a clear message
{
    assertThrown!SchemaCompileException(compileSchema(`{"$ref": "#/does/not/exist"}`));
    assertThrown!SchemaCompileException(compileSchema(`{"$ref": "#nosuchanchor"}`));
}

unittest  // a $ref into an unknown keyword is compiled on the fly
{
    auto v = compileSchema(`{
        "$ref": "#/custom/inner",
        "custom": {"inner": {"type": "integer"}}
    }`);
    assert(ok(v, "3"));
    assert(!ok(v, `"x"`));
}

unittest  // an external reference is loaded through a resolver callback
{
    ValidatorSettings settings;
    settings.resolver = (string uri) {
        assert(uri == "https://example.com/remote");
        return parseJson(`{"type": "string", "minLength": 1}`);
    };
    auto v = compileSchema(`{"$ref": "https://example.com/remote"}`, settings);
    assert(ok(v, `"x"`));
    assert(!ok(v, `""`));
    assert(!ok(v, "1"));
}

unittest  // draftOf maps the well-known dialect URIs
{
    assert(draftOf(dialect201909) == Draft.draft2019_09);
    assert(draftOf(dialect07) == Draft.draft07);
    assert(draftOf("http://json-schema.org/draft-07/schema") == Draft.draft07);
    assert(draftOf("https://json-schema.org/draft/2020-12/schema") == Draft.draft2020_12);
    assert(draftOf("urn:unknown") == Draft.draft2020_12);
}

unittest  // ecmaShorthand rewrites ECMA classes outside a character class
{
    assert(ecmaShorthand(`\d`) == "[0-9]");
    assert(ecmaShorthand(`\w`) == "[A-Za-z0-9_]");
    assert(ecmaShorthand(`\D`) == "[^0-9]");
    assert(ecmaShorthand(`\W`) == "[^A-Za-z0-9_]");
    assert(ecmaShorthand(`\p{digit}`) == `\p{Nd}`);
    // \a is an identity escape for 'a' in ECMA-262, not a control escape.
    assert(ecmaShorthand(`\a`) == "a");
    // An unrecognized escape is passed through unchanged.
    assert(ecmaShorthand(`\q`) == `\q`);
    // \s expands to the ECMA whitespace set.
    assert(ecmaShorthand(`\s`).length > 2);
}

unittest  // ecmaShorthand keeps shorthands inside a character class compact
{
    // Inside [...] the expansion omits the surrounding brackets.
    assert(ecmaShorthand(`[\d]`) == "[0-9]");
    assert(ecmaShorthand(`[\w]`) == "[A-Za-z0-9_]");
    assert(ecmaShorthand(`[\D]`) == `[\D]`);
    assert(ecmaShorthand(`[\W]`) == `[\W]`);
    assert(ecmaShorthand(`[\S]`) == `[\S]`);
    assert(ecmaShorthand(`[\s]`).length > 2);
}

unittest  // patterns using ECMA shorthands compile and match
{
    auto v = compileSchema(`{"pattern": "^\\d+$"}`);
    assert(ok(v, `"123"`));
    assert(!ok(v, `"12a"`));
}

unittest  // \S outside a character class expands to a negated whitespace set
{
    const r = ecmaShorthand(`\S`);
    assert(r.length > 3 && r[0 .. 2] == "[^");
}

unittest  // a meta-schema declaring the format-annotation vocabulary compiles
{
    auto store = new SchemaStore;
    store.register("https://example.com/meta-fmt", `{
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://example.com/meta-fmt",
        "$vocabulary": {
            "https://json-schema.org/draft/2020-12/vocab/core": true,
            "https://json-schema.org/draft/2020-12/vocab/format-annotation": true
        }
    }`);
    ValidatorSettings settings;
    settings.store = store;
    // format-annotation only: format is an annotation, so any string passes.
    auto v = compileSchema(`{"$schema": "https://example.com/meta-fmt", "format": "ipv4"}`,
            settings);
    assert(ok(v, `"not-an-ip"`));
}

unittest  // 2020-12 treats definitions / additionalItems as unknown keywords
{
    // Neither is a 2020-12 keyword: both are ignored, so any instance validates.
    auto v = compileSchema(`{
        "definitions": {"x": {"type": "integer"}},
        "additionalItems": {"type": "string"}
    }`);
    assert(ok(v, "true"));
    assert(ok(v, `["anything", 1]`));
}

unittest  // an invalid regex in a pattern is a compile error
{
    assertThrown!SchemaCompileException(compileSchema(`{"pattern": "("}`));
}

unittest  // a $ref with a malformed JSON Pointer fragment is rejected
{
    assertThrown!SchemaCompileException(compileSchema(`{"$ref": "#/a~2b"}`));
}

unittest  // a resolved document registered under a distinct $id keeps its retrieval URI
{
    ValidatorSettings settings;
    settings.resolver = (string uri) {
        // The returned document declares a different canonical $id.
        return parseJson(`{"$id": "https://example.com/canonical", "type": "string"}`);
    };
    auto v = compileSchema(`{"$ref": "https://example.com/retrieved"}`, settings);
    assert(ok(v, `"x"`));
    assert(!ok(v, "1"));
}
