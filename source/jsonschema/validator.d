/// Instance validation: evaluating a compiled schema against a JSON value of
/// any adapted type. Implements full 2020-12 evaluation semantics including
/// annotation collection for `unevaluatedProperties` / `unevaluatedItems` and
/// dynamic-scope resolution for `$dynamicRef`.
module jsonschema.validator;

import jsonschema.adapter;
import jsonschema.formats : checkFormat;
import jsonschema.ir;
import jsonschema.node : JsonNode;
import jsonschema.pointer : escapeToken;

import std.conv : to;
import std.traits : fullyQualifiedName;

@safe:

/// True when `V` is `vibe.data.json.Json`, matched by fully-qualified name so
/// the base package never imports vibe-d. Used to give callers a directed
/// error pointing at `validateJson` instead of a generic resolution failure.
private enum isVibeJson(V) = V.stringof == "Json" && __traits(compiles, {
        enum n = fullyQualifiedName!V;
    }) && fullyQualifiedName!V == "vibe.data.json.Json";

/// A compiled, reusable schema validator. Create via `compileSchema`; then
/// validate any number of instances of either built-in JSON type (or any
/// custom-adapted type via `validateWith`).
final class Validator
{
    package CompiledSchema root;
    package ValidatorSettings settings;
    /// True when the compiled schema tree uses `unevaluatedProperties` or
    /// `unevaluatedItems` anywhere. When false, the evaluator skips all
    /// `Evaluated` annotation bookkeeping since nothing consults it.
    package bool usesUnevaluated;
    package bool usesDynamicScope;

    package this(CompiledSchema root, ValidatorSettings settings) pure nothrow
    {
        this.root = root;
        this.settings = settings;
    }

    /// Validate a `std.json.JSONValue` instance.
    ///
    /// Total: never throws. If evaluation exceeds `ValidatorSettings.maxDepth`
    /// (an unboundedly recursive schema), it returns an invalid result rather
    /// than throwing — callers need only inspect `ValidationResult.valid`.
    ///
    /// `const`: a compiled `Validator` holds no mutable state, so one instance
    /// is safe to share across threads/fibers for concurrent read-only
    /// validation. All per-call state lives in `EvalState` / `Evaluated`.
    ///
    /// Note for vibe users: `vibe.data.json.Json` is not a member overload of
    /// `validate` because `Validator` lives in the vibe-free base package. Use
    /// the free function `validateJson` (or `validateWith!VibeJsonAdapter`)
    /// from the `jsonschema:vibe` subpackage instead.
    ValidationResult validate(in std.json.JSONValue instance,
            OutputFormat format = OutputFormat.basic) const
    {
        return validateWith!StdJsonAdapter(instance, format);
    }

    /// Validate an instance held in the library's internal representation.
    ValidationResult validate(in JsonNode instance, OutputFormat format = OutputFormat.basic) const
    {
        return validateWith!JsonNodeAdapter(instance, format);
    }

    /// Directed failure for `validate(vibe.data.json.Json)`. Matches only the
    /// vibe `Json` type (detected by name, so the base package keeps its
    /// vibe-free guarantee) and emits a message naming `validateJson`, rather
    /// than a generic overload-resolution error.
    ValidationResult validate(V)(in V instance, OutputFormat format = OutputFormat.basic) const
            if (isVibeJson!V)
    {
        static assert(false, "vibe `Json` instances must be validated with the "
                ~ "`validateJson` free function (or `validateWith!VibeJsonAdapter`) "
                ~ "from the `jsonschema:vibe` subpackage, not `Validator.validate`. "
                ~ "`Validator` lives in the vibe-free base package, so it has no "
                ~ "`Json` member overload.");
    }

    /// Validate an instance of any adapted JSON type.
    ValidationResult validateWith(A)(in A.Value instance, OutputFormat format = OutputFormat.basic) const
            if (isJsonAdapter!A)
    {
        EvalState!A st;
        st.collect = format != OutputFormat.flag;
        st.maxDepth = settings.maxDepth;
        st.assertFormats = settings.formatMode == FormatMode.assertion;
        st.tracksAnnotations = usesUnevaluated;
        st.tracksDynamicScope = usesDynamicScope;
        Evaluated ev;
        const ok = evalSchema!A(root, instance, "", "", st, ev);
        return ValidationResult(ok, st.errors);
    }

    /// Convenience: flag-format validity check.
    ///
    /// Note for vibe users: check `vibe.data.json.Json` validity via
    /// `validateJson(...).valid` (or `validateWith!VibeJsonAdapter`) from the
    /// `jsonschema:vibe` subpackage; the base package's `isValid` cannot accept
    /// it (see `validate`).
    bool isValid(V)(in V instance) const
    {
        static if (isVibeJson!V)
            static assert(false, "vibe `Json` instances cannot use "
                    ~ "`Validator.isValid`; check validity with " ~ "`validateJson(instance).valid` (or "
                    ~ "`validateWith!VibeJsonAdapter`) from the `jsonschema:vibe` " ~ "subpackage.");
        else static if (is(V == JsonNode))
            return validateWith!JsonNodeAdapter(instance, OutputFormat.flag).valid;
        else
            return validate(instance, OutputFormat.flag).valid;
    }
}

import std.json;

// --- evaluation state ---

private struct EvalState(A)
{
    const(SchemaResource)[] dynStack;
    ValidationError[] errors;
    bool collect;
    bool assertFormats;
    bool depthExceeded;
    bool tracksAnnotations;
    bool tracksDynamicScope;
    size_t depth;
    size_t maxDepth;
}

/// Annotation collector for one (schema, instance-location) evaluation: which
/// object properties and array items have been successfully evaluated. This is
/// what `unevaluatedProperties` / `unevaluatedItems` consult, after merging
/// the collectors of all successful in-place applicator branches.
package struct Evaluated
{
    /// When false, the schema tree has no `unevaluated*` keyword to consult
    /// these annotations, so all mutators below are no-ops and the AAs stay
    /// untouched. `evalSchema` sets this from `EvalState.tracksAnnotations`.
    bool track;
    bool allProps;
    bool[string] props;
    size_t itemsPrefix; // indices below this are evaluated
    bool[size_t] extraItems;

    void markProp(string key) pure nothrow
    {
        if (!track)
            return;
        if (!allProps)
            props[key] = true;
    }

    bool hasProp(string key) const pure nothrow
    {
        return allProps || (key in props) !is null;
    }

    void markItem(size_t i) pure nothrow
    {
        if (!track)
            return;
        if (i == itemsPrefix)
            itemsPrefix++;
        else if (i > itemsPrefix)
            extraItems[i] = true;
    }

    bool hasItem(size_t i) const pure nothrow
    {
        return i < itemsPrefix || (i in extraItems) !is null;
    }

    void merge(ref const Evaluated o) pure
    {
        if (!track)
            return;
        allProps |= o.allProps;
        if (allProps)
            props = null;
        else
            foreach (k, _; o.props)
                props[k] = true;
        if (o.itemsPrefix > itemsPrefix)
            itemsPrefix = o.itemsPrefix;
        foreach (i, _; o.extraItems)
            if (i >= itemsPrefix)
                extraItems[i] = true;
    }
}

private void fail(A)(ref EvalState!A st, string ip, string kp, lazy string msg) pure
{
    if (st.collect)
        st.errors ~= ValidationError(ip, kp, msg);
}

/// Append `suffix` to a location `base`, but only when error collection is
/// active. In flag mode the resulting string is never read, so the
/// concatenation (and any cost of computing `suffix`) is skipped entirely.
private string loc(A)(ref EvalState!A st, string base, lazy string suffix)
{
    return st.collect ? base ~ suffix : base;
}

// --- the evaluator ---

package bool evalSchema(A)(const CompiledSchema s, in A.Value v, string ip,
        string kp, ref EvalState!A st, ref Evaluated ev)
{
    ev.track = st.tracksAnnotations;
    if (++st.depth > st.maxDepth)
    {
        // Treat exceeding the depth limit (an unboundedly recursive schema) as
        // an invalid result rather than throwing, so callers only ever inspect
        // `ValidationResult.valid`. The flag is recorded once and suppresses
        // deeper recursion as the stack unwinds.
        st.depth--;
        if (!st.depthExceeded)
        {
            st.depthExceeded = true;
            fail(st, ip, kp,
                    "schema evaluation exceeded the depth limit (unboundedly recursive schema?)");
        }
        return false;
    }
    scope (exit)
        st.depth--;

    if (s.isBoolean)
    {
        if (!s.boolValue)
        {
            fail(st, ip, kp, "instance not permitted (schema is false)");
            return false;
        }
        return true;
    }

    bool pushed;
    if (st.tracksDynamicScope && s.resource !is null
            && (st.dynStack.length == 0 || st.dynStack[$ - 1]!is s.resource))
    {
        st.dynStack ~= s.resource;
        pushed = true;
    }
    scope (exit)
        if (pushed)
            st.dynStack = st.dynStack[0 .. $ - 1];

    bool ok = true;
    const kind = A.kindOf(v);

    // --- core: references (in-place applicators) ---
    if (s.refIsExclusive)
    {
        // Up to draft-07, a `$ref` suppresses every sibling keyword: evaluate
        // only the reference and adopt its annotations.
        Evaluated sub;
        const r = evalSchema!A(s.refInfo.target, v, ip, loc(st, kp, "/$ref"), st, sub);
        if (r)
            ev.merge(sub);
        return r;
    }
    if (s.refInfo !is null)
    {
        Evaluated sub;
        if (evalSchema!A(s.refInfo.target, v, ip, loc(st, kp, "/$ref"), st, sub))
            ev.merge(sub);
        else
            ok = false;
    }
    if (s.dynRefInfo !is null)
    {
        import std.typecons : rebindable;

        auto target = rebindable(s.dynRefInfo.target);
        if (s.dynRefInfo.dynamicCandidate)
            foreach (res; st.dynStack)
                if (auto p = s.dynRefInfo.anchorName in res.dynamicAnchors)
                {
                    target = *p;
                    break;
                }
        Evaluated sub;
        if (evalSchema!A(target, v, ip, loc(st, kp, "/$dynamicRef"), st, sub))
            ev.merge(sub);
        else
            ok = false;
    }

    // Flag mode discards annotations, so once invalid the boolean outcome is
    // fixed: short-circuit between keyword groups when not collecting errors.
    if (!st.collect && !ok)
        return false;

    // --- validation: any instance type ---
    if (s.hasType && !typeMatches!A(s.typeMask, v, kind))
    {
        fail(st, ip, loc(st, kp, "/type"), "instance type does not match");
        ok = false;
    }
    if (s.hasConst && !valueEqualsNode!A(v, s.constValue, kind))
    {
        fail(st, ip, loc(st, kp, "/const"), "instance does not equal the const value");
        ok = false;
    }
    if (s.hasEnum && !enumContains!A(v, kind, s.enumValues))
    {
        fail(st, ip, loc(st, kp, "/enum"), "instance is not one of the enum values");
        ok = false;
    }

    // --- validation: numbers ---
    if (kind == JsonKind.integer || kind == JsonKind.floating)
        ok &= checkNumber!A(s, A.getNumber(v), ip, kp, st);

    // --- validation + format: strings ---
    if (kind == JsonKind.string_)
        ok &= checkString!A(s, A.getString(v), ip, kp, st);
    if (s.hasFormat && (st.assertFormats || s.resource.vocab.formatAssertion)
            && kind == JsonKind.string_ && !checkFormat(s.format, A.getString(v)))
    {
        fail(st, ip, loc(st, kp, "/format"), "instance does not match format '" ~ s.format ~ "'");
        ok = false;
    }

    if (!st.collect && !ok)
        return false;

    // --- in-place applicators ---
    if (s.hasInPlaceApplicators && !evalInPlace!A(s, v, ip, kp, st, ev))
    {
        ok = false;
        if (!st.collect)
            return false;
    }

    if (!st.collect && !ok)
        return false;

    // --- objects ---
    if (kind == JsonKind.object)
        ok &= checkObject!A(s, v, ip, kp, st, ev);

    if (!st.collect && !ok)
        return false;

    // --- arrays ---
    if (kind == JsonKind.array)
        ok &= checkArray!A(s, v, ip, kp, st, ev);

    if (!st.collect && !ok)
        return false;

    // --- unevaluated*, after everything else at this location ---
    if (s.unevaluatedProperties !is null && kind == JsonKind.object)
    {
        bool failed;
        A.objectEach(v, (string key, in A.Value member) {
            if (ev.hasProp(key))
                return 0;
            Evaluated se;
            if (evalChild!A(s.unevaluatedProperties, member,
                loc(st, ip, "/" ~ escapeToken(key)), loc(st, kp, "/unevaluatedProperties"), st, se))
                ev.markProp(key);
            else
                failed = true;
            return 0;
        });
        if (failed)
        {
            fail(st, ip, loc(st, kp, "/unevaluatedProperties"), "unevaluated properties do not validate");
            ok = false;
        }
    }
    if (s.unevaluatedItems !is null && kind == JsonKind.array)
    {
        bool failed;
        const len = A.arrayLength(v);
        foreach (i; 0 .. len)
        {
            if (ev.hasItem(i))
                continue;
            const elem = A.arrayAt(v, i);
            Evaluated se;
            if (evalChild!A(s.unevaluatedItems, elem, loc(st, ip, "/" ~ i.to!string),
                    loc(st, kp, "/unevaluatedItems"), st, se))
                ev.markItem(i);
            else
                failed = true;
        }
        if (failed)
        {
            fail(st, ip, loc(st, kp, "/unevaluatedItems"), "unevaluated items do not validate");
            ok = false;
        }
    }

    return ok;
}

/// Evaluate a child schema. A `isSimpleScalar` node cannot recurse, so it skips
/// `evalSchema`'s depth guard, dynamic-scope stack, and reference/applicator
/// cascade — the per-node frame setup that dominates leaf-heavy instances —
/// and validates inline. Everything else goes through the full evaluator.
private bool evalChild(A)(const CompiledSchema s, in A.Value v, string ip,
        string kp, ref EvalState!A st, ref Evaluated ev)
{
    import std.typecons : rebindable;

    auto t = rebindable(s);
    // Follow a chain of pure `$ref` nodes without a frame per hop. Restricted to
    // flag mode (the keyword location is not built) and to schemas with no
    // dynamic scope (no resource push to preserve); a small hop cap leaves any
    // pathological static-ref cycle to the depth-guarded evaluator.
    if (!st.collect && !st.tracksDynamicScope)
        for (int hops = 0; t.isPureRef && hops < 16; hops++)
            t = t.refInfo.target;
    if (t.isSimpleScalar)
        return evalSimple!A(t, v, ip, kp, st);
    return evalSchema!A(t, v, ip, kp, st, ev);
}

/// Fast path for `isSimpleScalar` schemas: only `type`/`const`/`enum` plus the
/// numeric and string bound keywords can apply, so there is no recursion,
/// annotation collection, or dynamic scope to manage.
private bool evalSimple(A)(const CompiledSchema s, in A.Value v, string ip,
        string kp, ref EvalState!A st)
{
    const kind = A.kindOf(v);
    bool ok = true;
    if (s.hasType && !typeMatches!A(s.typeMask, v, kind))
    {
        fail(st, ip, loc(st, kp, "/type"), "instance type does not match");
        ok = false;
        if (!st.collect)
            return false;
    }
    if (s.hasConst && !valueEqualsNode!A(v, s.constValue, kind))
    {
        fail(st, ip, loc(st, kp, "/const"), "instance does not equal the const value");
        ok = false;
        if (!st.collect)
            return false;
    }
    if (s.hasEnum && !enumContains!A(v, kind, s.enumValues))
    {
        fail(st, ip, loc(st, kp, "/enum"), "instance is not one of the enum values");
        ok = false;
        if (!st.collect)
            return false;
    }
    if (kind == JsonKind.integer || kind == JsonKind.floating)
        ok &= checkNumber!A(s, A.getNumber(v), ip, kp, st);
    else if (kind == JsonKind.string_)
        ok &= checkString!A(s, A.getString(v), ip, kp, st);
    return ok;
}

// The in-place applicators (`allOf`/`anyOf`/`oneOf`/`not`/`if`) each need their
// own `Evaluated` collector. Kept out of `evalSchema` and not inlined so that
// `evalSchema`'s stack frame — set up and torn down on every node of the
// recursion — stays small; this cold-ish branch carries the heavy locals.
pragma(inline, false)
private bool evalInPlace(A)(const CompiledSchema s, in A.Value v, string ip,
        string kp, ref EvalState!A st, ref Evaluated ev)
{
    bool ok = true;
    foreach (i, sub; s.allOf)
    {
        Evaluated se;
        if (evalSchema!A(sub, v, ip, loc(st, kp, "/allOf/" ~ i.to!string), st, se))
            ev.merge(se);
        else
        {
            ok = false;
            if (!st.collect)
                return false;
        }
    }
    if (s.anyOf.length)
    {
        const mark = st.errors.length;
        bool any;
        foreach (i, sub; s.anyOf)
        {
            Evaluated se;
            if (evalSchema!A(sub, v, ip, loc(st, kp, "/anyOf/" ~ i.to!string), st, se))
            {
                any = true;
                ev.merge(se);
                // Validity needs only one match; remaining branches matter only
                // to collect annotations for a `unevaluated*` keyword in scope.
                if (!st.tracksAnnotations)
                    break;
            }
        }
        if (any)
            shrinkErrors(st, mark);
        else
        {
            fail(st, ip, loc(st, kp, "/anyOf"), "instance does not match any anyOf branch");
            ok = false;
        }
    }
    if (s.oneOf.length)
    {
        const mark = st.errors.length;
        size_t matches;
        foreach (i, sub; s.oneOf)
        {
            Evaluated se;
            if (evalSchema!A(sub, v, ip, loc(st, kp, "/oneOf/" ~ i.to!string), st, se))
            {
                matches++;
                ev.merge(se);
                // Two matches already violate oneOf; stop unless errors are
                // being collected for a report.
                if (matches > 1 && !st.collect)
                    break;
            }
        }
        if (matches == 1)
            shrinkErrors(st, mark);
        else
        {
            if (matches > 1)
                shrinkErrors(st, mark);
            fail(st, ip, loc(st, kp, "/oneOf"), matches == 0
                    ? "instance does not match any oneOf branch"
                    : "instance matches more than one oneOf branch");
            ok = false;
        }
    }
    if (s.notSchema !is null)
    {
        const mark = st.errors.length;
        Evaluated se; // annotations inside "not" are never retained
        const r = evalSchema!A(s.notSchema, v, ip, loc(st, kp, "/not"), st, se);
        shrinkErrors(st, mark);
        if (r)
        {
            fail(st, ip, loc(st, kp, "/not"), "instance must not match the 'not' schema");
            ok = false;
        }
    }
    if (s.ifSchema !is null)
    {
        const mark = st.errors.length;
        Evaluated condEv;
        const condOk = evalSchema!A(s.ifSchema, v, ip, loc(st, kp, "/if"), st, condEv);
        shrinkErrors(st, mark); // "if" outcomes are not failures
        if (condOk)
        {
            ev.merge(condEv);
            if (s.thenSchema !is null)
            {
                Evaluated se;
                if (evalSchema!A(s.thenSchema, v, ip, loc(st, kp, "/then"), st, se))
                    ev.merge(se);
                else
                    ok = false;
            }
        }
        else if (s.elseSchema !is null)
        {
            Evaluated se;
            if (evalSchema!A(s.elseSchema, v, ip, loc(st, kp, "/else"), st, se))
                ev.merge(se);
            else
                ok = false;
        }
    }
    return ok;
}

private void shrinkErrors(A)(ref EvalState!A st, size_t mark) pure nothrow @trusted
{
    // Once the depth limit is hit, keep the synthetic depth error: it must
    // survive the error-pruning that anyOf / not / if / contains otherwise do.
    if (st.depthExceeded)
        return;
    // Shrinking to a previous length only ever drops tail entries.
    st.errors.length = mark;
}

// --- per-kind keyword groups ---

private bool typeMatches(A)(ubyte mask, in A.Value v, JsonKind kind)
{
    final switch (kind)
    {
    case JsonKind.null_:
        return (mask & TypeBit.null_) != 0;
    case JsonKind.boolean:
        return (mask & TypeBit.boolean) != 0;
    case JsonKind.string_:
        return (mask & TypeBit.string_) != 0;
    case JsonKind.array:
        return (mask & TypeBit.array) != 0;
    case JsonKind.object:
        return (mask & TypeBit.object) != 0;
    case JsonKind.integer:
        return (mask & (TypeBit.number | TypeBit.integer)) != 0;
    case JsonKind.floating:
        if (mask & TypeBit.number)
            return true;
        if (mask & TypeBit.integer)
        {
            import std.math : floor, isFinite;

            const f = A.getNumber(v).f;
            return isFinite(f) && f == floor(f);
        }
        return false;
    }
}

private bool checkNumber(A)(const CompiledSchema s, in JsonNumber n, string ip,
        string kp, ref EvalState!A st)
{
    bool ok = true;
    if (s.hasMultipleOf && !isMultipleOf(n, s.multipleOf))
    {
        fail(st, ip, loc(st, kp, "/multipleOf"), "instance is not a multiple of the divisor");
        ok = false;
        if (!st.collect)
            return false;
    }
    if (s.hasMaximum && cmpNumbers(n, s.maximum) > 0)
    {
        fail(st, ip, loc(st, kp, "/maximum"), "instance exceeds the maximum");
        ok = false;
        if (!st.collect)
            return false;
    }
    if (s.hasExclusiveMaximum && cmpNumbers(n, s.exclusiveMaximum) >= 0)
    {
        fail(st, ip, loc(st, kp, "/exclusiveMaximum"), "instance is not below the exclusive maximum");
        ok = false;
        if (!st.collect)
            return false;
    }
    if (s.hasMinimum && cmpNumbers(n, s.minimum) < 0)
    {
        fail(st, ip, loc(st, kp, "/minimum"), "instance is below the minimum");
        ok = false;
        if (!st.collect)
            return false;
    }
    if (s.hasExclusiveMinimum && cmpNumbers(n, s.exclusiveMinimum) <= 0)
    {
        fail(st, ip, loc(st, kp, "/exclusiveMinimum"), "instance is not above the exclusive minimum");
        ok = false;
        if (!st.collect)
            return false;
    }
    return ok;
}

/// Number of Unicode code points in valid UTF-8: every byte that is not a
/// continuation byte (`10xxxxxx`) starts one code point. Cheaper than
/// `std.utf.count`, which fully decodes (and validates) each code point.
private size_t countCodePoints(string s) @trusted @nogc nothrow pure
{
    size_t n;
    foreach (immutable ubyte b; cast(const(ubyte)[]) s)
        if ((b & 0xC0) != 0x80)
            n++;
    return n;
}

private bool checkString(A)(const CompiledSchema s, string str, string ip,
        string kp, ref EvalState!A st)
{
    bool ok = true;
    if (s.maxLength != absent || s.minLength != absent)
    {
        // `minLength`/`maxLength` count Unicode code points, but code points are
        // bounded by byte length: blen/4 <= codePoints <= blen. Those bounds
        // resolve most cases from the O(1) byte length alone; only when they are
        // inconclusive do we count code points (cheaply, without decoding).
        const blen = str.length;
        long cp = -1;
        if (s.maxLength != absent)
        {
            if (blen > cast(size_t) s.maxLength)
            {
                cp = countCodePoints(str);
                if (cp > s.maxLength)
                {
                    fail(st, ip, loc(st, kp, "/maxLength"), "string is longer than maxLength");
                    ok = false;
                    if (!st.collect)
                        return false;
                }
            }
        }
        if (s.minLength != absent)
        {
            if (blen < cast(size_t) s.minLength)
            {
                fail(st, ip, loc(st, kp, "/minLength"), "string is shorter than minLength");
                ok = false;
                if (!st.collect)
                    return false;
            }
            else if ((blen + 3) / 4 < cast(size_t) s.minLength)
            {
                if (cp < 0)
                    cp = countCodePoints(str);
                if (cp < s.minLength)
                {
                    fail(st, ip, loc(st, kp, "/minLength"), "string is shorter than minLength");
                    ok = false;
                    if (!st.collect)
                        return false;
                }
            }
        }
    }
    if (s.hasPattern)
    {
        import std.regex : matchFirst;

        if (matchFirst(str, s.pattern).empty)
        {
            fail(st, ip, loc(st, kp, "/pattern"), "string does not match pattern '" ~ s.patternSource ~ "'");
            ok = false;
        }
    }
    return ok;
}

/// Binary search for `key` in the sorted `propKeys`, returning its `PropEntry`
/// (or null). Inlined byte comparison, so no out-of-line druntime call — unlike
/// an `in` on the `properties` associative array.
private const(PropEntry)* findProp(const string[] keys, const PropEntry[] vals, string key)
        @trusted @nogc nothrow pure
{
    size_t lo = 0, hi = keys.length;
    while (lo < hi)
    {
        const mid = (lo + hi) >> 1;
        const k = keys[mid];
        // Lexicographic compare, shortest-first on a shared prefix.
        const n = key.length < k.length ? key.length : k.length;
        int c = 0;
        foreach (i; 0 .. n)
            if (key[i] != k[i])
            {
                c = cast(ubyte) key[i] < cast(ubyte) k[i] ? -1 : 1;
                break;
            }
        if (c == 0)
        {
            if (key.length == k.length)
                return &vals[mid];
            c = key.length < k.length ? -1 : 1;
        }
        if (c < 0)
            hi = mid;
        else
            lo = mid + 1;
    }
    return null;
}

private bool checkObject(A)(const CompiledSchema s, in A.Value v, string ip,
        string kp, ref EvalState!A st, ref Evaluated ev)
{
    bool ok = true;
    const len = A.objectLength(v);

    if (s.maxProperties != absent && len > s.maxProperties)
    {
        fail(st, ip, loc(st, kp, "/maxProperties"), "object has more than maxProperties members");
        ok = false;
        if (!st.collect)
            return false;
    }
    if (s.minProperties != absent && len < s.minProperties)
    {
        fail(st, ip, loc(st, kp, "/minProperties"), "object has fewer than minProperties members");
        ok = false;
        if (!st.collect)
            return false;
    }
    foreach (trigger, names; s.dependentRequired)
        if (A.objectGet(v, trigger) !is null)
            foreach (name; names)
                if (A.objectGet(v, name) is null)
                {
                    fail(st, ip, loc(st, kp, "/dependentRequired"),
                            "property '" ~ trigger ~ "' requires property '" ~ name ~ "'");
                    ok = false;
                    if (!st.collect)
                        return false;
                }
    foreach (trigger, sub; s.dependentSchemas)
        if (A.objectGet(v, trigger) !is null)
        {
            Evaluated se;
            if (evalSchema!A(sub, v, ip, loc(st, kp, "/dependentSchemas/" ~ escapeToken(trigger)), st, se))
                ev.merge(se);
            else
            {
                ok = false;
                if (!st.collect)
                    return false;
            }
        }

    size_t seenRequired;
    if (s.properties.length || s.patternProperties.length
            || s.additionalProperties !is null || s.propertyNames !is null)
    {
        import std.regex : matchFirst;

        bool failed;
        A.objectEach(v, (string key, in A.Value member) {
            const mp = loc(st, ip, "/" ~ escapeToken(key));
            bool matched;
            if (auto p = findProp(s.propKeys, s.propVals, key))
            {
                if (p.required)
                    seenRequired++;
                Evaluated se;
                if (evalChild!A(p.schema, member, mp, loc(st, kp, "/properties/" ~ escapeToken(key)), st, se))
                    ev.markProp(key);
                else
                    failed = true;
                matched = true;
            }
            foreach (ref pp; s.patternProperties)
                if (!matchFirst(key, pp.regex).empty)
                {
                    Evaluated se;
                    if (evalChild!A(pp.schema, member, mp,
                        loc(st, kp, "/patternProperties/" ~ escapeToken(pp.source)), st, se))
                        ev.markProp(key);
                    else
                        failed = true;
                    matched = true;
                }
            if (!matched && s.additionalProperties !is null)
            {
                Evaluated se;
                if (evalChild!A(s.additionalProperties, member, mp,
                    loc(st, kp, "/additionalProperties"), st, se))
                    ev.markProp(key);
                else
                    failed = true;
            }
            if (s.propertyNames !is null)
            {
                const nameValue = A.ofString(key);
                Evaluated se;
                if (!evalChild!A(s.propertyNames, nameValue, mp, loc(st, kp, "/propertyNames"), st, se))
                    failed = true;
            }
            // Flag mode: stop visiting members once one has failed.
            return (failed && !st.collect) ? 1 : 0;
        });
        if (failed)
            ok = false;
    }

    // required. In collect mode, report each missing name precisely. In flag
    // mode, the property scan above already counted the required properties it
    // saw (`seenRequired`), so a shortfall means one is absent; names that are
    // not properties (`requiredExtra`) still need an explicit lookup.
    if (st.collect)
    {
        foreach (name; s.required)
            if (A.objectGet(v, name) is null)
            {
                fail(st, ip, loc(st, kp, "/required"), "missing required property '" ~ name ~ "'");
                ok = false;
            }
    }
    else
    {
        if (!ok || seenRequired < s.requiredInProps)
            return false;
        foreach (name; s.requiredExtra)
            if (A.objectGet(v, name) is null)
                return false;
    }
    return ok;
}

private bool checkArray(A)(const CompiledSchema s, in A.Value v, string ip,
        string kp, ref EvalState!A st, ref Evaluated ev)
{
    bool ok = true;
    const len = A.arrayLength(v);

    if (s.maxItems != absent && len > s.maxItems)
    {
        fail(st, ip, loc(st, kp, "/maxItems"), "array has more than maxItems items");
        ok = false;
        if (!st.collect)
            return false;
    }
    if (s.minItems != absent && len < s.minItems)
    {
        fail(st, ip, loc(st, kp, "/minItems"), "array has fewer than minItems items");
        ok = false;
        if (!st.collect)
            return false;
    }
    if (s.uniqueItems && len > 1)
    {
        outer: foreach (i; 0 .. len)
        {
            const a = A.arrayAt(v, i);
            foreach (j; i + 1 .. len)
            {
                const b = A.arrayAt(v, j);
                if (deepEqualValues!A(a, b))
                {
                    fail(st, ip, loc(st, kp, "/uniqueItems"), "array items are not unique");
                    ok = false;
                    break outer;
                }
            }
        }
        if (!ok && !st.collect)
            return false;
    }

    if (s.hasPrefixItems)
    {
        bool failed;
        const n = s.prefixItems.length < len ? s.prefixItems.length : len;
        foreach (i; 0 .. n)
        {
            const elem = A.arrayAt(v, i);
            Evaluated se;
            if (evalChild!A(s.prefixItems[i], elem, loc(st, ip, "/" ~ i.to!string),
                    loc(st, kp, "/prefixItems/" ~ i.to!string), st, se))
                ev.markItem(i);
            else
            {
                failed = true;
                if (!st.collect)
                    return false;
            }
        }
        if (failed)
            ok = false;
    }
    if (s.itemsSchema !is null)
    {
        bool failed;
        const start = s.prefixItems.length;
        foreach (i; start .. len)
        {
            const elem = A.arrayAt(v, i);
            Evaluated se;
            if (evalChild!A(s.itemsSchema, elem, loc(st, ip, "/" ~ i.to!string), loc(st, kp, "/items"), st, se))
                ev.markItem(i);
            else
            {
                failed = true;
                if (!st.collect)
                    return false;
            }
        }
        if (failed)
            ok = false;
    }
    // Pre-2020-12 `additionalItems`: only meaningful alongside a tuple `items`.
    if (s.additionalItemsSchema !is null && s.hasPrefixItems)
    {
        bool failed;
        const start = s.prefixItems.length;
        foreach (i; start .. len)
        {
            const elem = A.arrayAt(v, i);
            Evaluated se;
            if (evalChild!A(s.additionalItemsSchema, elem, loc(st, ip, "/" ~ i.to!string),
                    loc(st, kp, "/additionalItems"), st, se))
                ev.markItem(i);
            else
            {
                failed = true;
                if (!st.collect)
                    return false;
            }
        }
        if (failed)
            ok = false;
    }
    if (s.containsSchema !is null)
    {
        const mark = st.errors.length;
        size_t[] matchedIdx;
        foreach (i; 0 .. len)
        {
            const elem = A.arrayAt(v, i);
            Evaluated se;
            if (evalChild!A(s.containsSchema, elem, loc(st, ip, "/" ~ i.to!string),
                    loc(st, kp, "/contains"), st, se))
                matchedIdx ~= i;
        }
        const minC = s.minContains != absent ? s.minContains : 1;
        bool groupOk = true;
        if (cast(long) matchedIdx.length < minC)
        {
            shrinkErrors(st, mark); // keep only the summary below
            fail(st, ip, loc(st, kp, "/contains"), minC == 1
                    ? "array contains no matching item"
                    : "array contains fewer matching items than minContains");
            groupOk = false;
        }
        else
            shrinkErrors(st, mark); // non-matching items are not failures
        if (s.maxContains != absent && cast(long) matchedIdx.length > s.maxContains)
        {
            fail(st, ip, loc(st, kp, "/maxContains"),
                    "array contains more matching items than maxContains");
            groupOk = false;
        }
        if (groupOk)
            foreach (i; matchedIdx)
                ev.markItem(i);
        else
            ok = false;
    }
    return ok;
}

// --- value comparisons ---

/// Compare two JSON numbers exactly: integer representations never round-trip
/// through a double; an integral/floating comparison is decided via floor().
package int cmpNumbers(in JsonNumber a, in JsonNumber b) pure nothrow
{
    alias R = JsonNumber.Rep;
    if (a.isIntegral && b.isIntegral)
    {
        // ofULong normalizes anything <= long.max to signed, so an unsigned_
        // representation is always > long.max and hence > any signed value.
        if (a.rep == R.signed_ && b.rep == R.signed_)
            return a.s < b.s ? -1 : a.s > b.s ? 1 : 0;
        if (a.rep == R.unsigned_ && b.rep == R.unsigned_)
            return a.u < b.u ? -1 : a.u > b.u ? 1 : 0;
        return a.rep == R.unsigned_ ? 1 : -1;
    }
    if (a.rep == R.floating_ && b.rep == R.floating_)
        return a.f < b.f ? -1 : a.f > b.f ? 1 : 0;
    if (a.rep == R.floating_)
        return -cmpIntFloat(b, a.f);
    return cmpIntFloat(a, b.f);
}

private int cmpIntFloat(in JsonNumber i, double f) pure nothrow
{
    import std.math : floor;

    if (f != f) // NaN: never produced by JSON parsing; order it below everything
        return 1;
    if (i.rep == JsonNumber.Rep.signed_)
    {
        if (f >= 9223372036854775808.0)
            return -1;
        if (f < -9223372036854775808.0)
            return 1;
        const fl = cast(long) floor(f);
        if (i.s != fl)
            return i.s < fl ? -1 : 1;
        return f > floor(f) ? -1 : 0;
    }
    // unsigned: value > long.max
    if (f >= 18446744073709551616.0)
        return -1;
    if (f < 9223372036854775808.0)
        return 1;
    const fl = cast(ulong) floor(f);
    if (i.u != fl)
        return i.u < fl ? -1 : 1;
    return f > floor(f) ? -1 : 0;
}

/// JSON Schema multipleOf. Exact integer arithmetic when both operands are
/// integral; otherwise a quotient-rounding check with a small relative
/// tolerance (so 0.0075 is a multiple of 0.0001 despite binary representation).
package bool isMultipleOf(in JsonNumber v, in JsonNumber m) nothrow @trusted
{
    alias R = JsonNumber.Rep;
    if (v.isIntegral && m.isIntegral)
    {
        const mu = m.rep == R.unsigned_ ? m.u : absU(m.s);
        if (mu == 0)
            return false;
        const vu = v.rep == R.unsigned_ ? v.u : absU(v.s);
        return vu % mu == 0;
    }
    import std.math : fabs, isFinite, nearbyint;

    const dv = v.asDouble;
    const dm = m.asDouble;
    if (dm == 0)
        return false;
    const q = dv / dm;
    if (!isFinite(q))
    {
        // The quotient overflowed (huge value, tiny divisor): fall back to
        // fmod, which cannot overflow.
        import core.stdc.math : fmod;

        return fmod(dv, dm) == 0;
    }
    const r = nearbyint(q);
    const eps = fabs(dv) * 1e-12 + double.min_normal;
    return fabs(r * dm - dv) <= eps;
}

private ulong absU(long v) pure nothrow
{
    return v < 0 ? cast(ulong)(-(v + 1)) + 1 : cast(ulong) v;
}

private JsonNumber numberOfNode(in JsonNode n) pure nothrow
{
    alias K = JsonNode.Kind;
    switch (n.kind)
    {
    case K.integer:
        return JsonNumber.ofLong(n.integer_);
    case K.uinteger:
        return JsonNumber.ofULong(n.uinteger_);
    default:
        return JsonNumber.ofDouble(n.floating_);
    }
}

/// Membership test for `enum`. Extracts the instance's scalar once and
/// compares it against each candidate, rather than re-dispatching and
/// re-extracting per value as a `valueEqualsNode` loop would. Composite
/// instances (array/object) fall back to the general deep comparison.
package bool enumContains(A)(in A.Value v, JsonKind kind, const JsonNode[] values)
{
    alias K = JsonNode.Kind;
    final switch (kind)
    {
    case JsonKind.null_:
        foreach (ref e; values)
            if (e.kind == K.null_)
                return true;
        return false;
    case JsonKind.boolean:
        const b = A.getBoolean(v);
        foreach (ref e; values)
            if (e.kind == K.boolean && e.boolean_ == b)
                return true;
        return false;
    case JsonKind.string_:
        const str = A.getString(v);
        foreach (ref e; values)
            if (e.kind == K.string_ && e.string_ == str)
                return true;
        return false;
    case JsonKind.integer:
    case JsonKind.floating:
        const n = A.getNumber(v);
        foreach (ref e; values)
            if (e.isNumber && cmpNumbers(n, numberOfNode(e)) == 0)
                return true;
        return false;
    case JsonKind.array:
    case JsonKind.object:
        foreach (ref e; values)
            if (valueEqualsNode!A(v, e, kind))
                return true;
        return false;
    }
}

/// Deep equality between an instance value (any adapter) and a schema-side
/// `JsonNode` (for const / enum), with cross-representation number equality.
package bool valueEqualsNode(A)(in A.Value v, in JsonNode n, JsonKind kind)
{
    alias K = JsonNode.Kind;
    final switch (kind)
    {
    case JsonKind.null_:
        return n.kind == K.null_;
    case JsonKind.boolean:
        return n.kind == K.boolean && A.getBoolean(v) == n.boolean_;
    case JsonKind.integer:
    case JsonKind.floating:
        return n.isNumber
            && cmpNumbers(A.getNumber(v), numberOfNode(n)) == 0;
    case JsonKind.string_:
        return n.kind == K.string_ && A.getString(v) == n.string_;
    case JsonKind.array:
        if (n.kind != K.array || A.arrayLength(v) != n.array_.length)
            return false;
        foreach (i; 0 .. n.array_.length)
        {
            const elem = A.arrayAt(v, i);
            if (!valueEqualsNode!A(elem, n.array_[i], A.kindOf(elem)))
                return false;
        }
        return true;
    case JsonKind.object:
        if (n.kind != K.object || A.objectLength(v) != n.members_.length)
            return false;
        foreach (ref m; n.members_)
        {
            auto p = A.objectGet(v, m.key);
            if (p is null || !valueEqualsNode!A(*p, m.value, A.kindOf(*p)))
                return false;
        }
        return true;
    }
}

/// Deep equality between two instance values of the same adapted type
/// (uniqueItems), with cross-representation number equality.
package bool deepEqualValues(A)(in A.Value a, in A.Value b)
{
    const ka = A.kindOf(a);
    const kb = A.kindOf(b);
    const aNum = ka == JsonKind.integer || ka == JsonKind.floating;
    const bNum = kb == JsonKind.integer || kb == JsonKind.floating;
    if (aNum && bNum)
        return cmpNumbers(A.getNumber(a), A.getNumber(b)) == 0;
    if (ka != kb)
        return false;
    final switch (ka)
    {
    case JsonKind.null_:
        return true;
    case JsonKind.boolean:
        return A.getBoolean(a) == A.getBoolean(b);
    case JsonKind.string_:
        return A.getString(a) == A.getString(b);
    case JsonKind.array:
        const la = A.arrayLength(a);
        if (la != A.arrayLength(b))
            return false;
        foreach (i; 0 .. la)
        {
            const ea = A.arrayAt(a, i);
            const eb = A.arrayAt(b, i);
            if (!deepEqualValues!A(ea, eb))
                return false;
        }
        return true;
    case JsonKind.object:
        if (A.objectLength(a) != A.objectLength(b))
            return false;
        bool equal = true;
        A.objectEach(a, (string key, in A.Value va) {
            auto pb = A.objectGet(b, key);
            if (pb is null || !deepEqualValues!A(va, *pb))
            {
                equal = false;
                return 1;
            }
            return 0;
        });
        return equal;
    case JsonKind.integer:
    case JsonKind.floating:
        assert(false); // handled by the numeric branch above
    }
}

// --- tests ---

unittest  // cmpNumbers: unsigned/unsigned and unsigned/signed ordering
{
    alias N = JsonNumber;
    const big = N.ofULong(ulong.max);
    const bigger = big; // ulong.max compared to itself
    assert(cmpNumbers(big, bigger) == 0);
    assert(cmpNumbers(N.ofULong(18446744073709551614UL), big) < 0);
    assert(cmpNumbers(big, N.ofULong(18446744073709551614UL)) > 0);
    // An unsigned beyond long.max is always greater than any signed value.
    assert(cmpNumbers(big, N.ofLong(5)) > 0);
    assert(cmpNumbers(N.ofLong(5), big) < 0);
}

unittest  // cmpNumbers: float/float ordering
{
    alias N = JsonNumber;
    assert(cmpNumbers(N.ofDouble(1.5), N.ofDouble(2.5)) < 0);
    assert(cmpNumbers(N.ofDouble(2.5), N.ofDouble(1.5)) > 0);
    assert(cmpNumbers(N.ofDouble(2.5), N.ofDouble(2.5)) == 0);
}

unittest  // cmpNumbers: a NaN orders below everything
{
    alias N = JsonNumber;
    const q = N.ofDouble(double.nan);
    // cmpIntFloat returns 1 for NaN (ordered below the integer side).
    assert(cmpNumbers(N.ofLong(0), q) != 0);
    assert(cmpNumbers(q, N.ofLong(0)) != 0);
}

unittest  // cmpNumbers: signed integer against out-of-range and fractional floats
{
    alias N = JsonNumber;
    // Float far above long range: the integer is smaller.
    assert(cmpNumbers(N.ofLong(1), N.ofDouble(1e19)) < 0);
    // Float far below long range: the integer is larger.
    assert(cmpNumbers(N.ofLong(1), N.ofDouble(-1e19)) > 0);
    // Equal integral value: equal.
    assert(cmpNumbers(N.ofLong(3), N.ofDouble(3.0)) == 0);
    // Same whole part but a positive fraction makes the float larger.
    assert(cmpNumbers(N.ofLong(3), N.ofDouble(3.5)) < 0);
    assert(cmpNumbers(N.ofLong(4), N.ofDouble(3.5)) > 0);
}

unittest  // cmpNumbers: unsigned integer against floats across its range
{
    alias N = JsonNumber;
    const u = N.ofULong(ulong.max); // > long.max, so unsigned representation
    // Float beyond 2^64: the unsigned is smaller.
    assert(cmpNumbers(u, N.ofDouble(1e20)) < 0);
    // Float below 2^63: the unsigned is larger.
    assert(cmpNumbers(u, N.ofDouble(1.0)) > 0);
    // A representable unsigned compared with its exact double.
    const w = N.ofULong(9223372036854775808UL); // 2^63
    assert(cmpNumbers(w, N.ofDouble(9223372036854775808.0)) == 0);
    // A larger unsigned whose floor matches the float but differs in value.
    assert(cmpNumbers(N.ofULong(9223372036854775809UL), N.ofDouble(9223372036854775808.0)) > 0);
}

unittest  // isMultipleOf: zero divisors never divide
{
    alias N = JsonNumber;
    assert(!isMultipleOf(N.ofLong(4), N.ofLong(0)));
    assert(!isMultipleOf(N.ofDouble(4.0), N.ofDouble(0.0)));
}

unittest  // isMultipleOf: integer and float divisors
{
    alias N = JsonNumber;
    assert(isMultipleOf(N.ofLong(6), N.ofLong(3)));
    assert(!isMultipleOf(N.ofLong(7), N.ofLong(3)));
    // A negative divisor: magnitude is what matters.
    assert(isMultipleOf(N.ofLong(6), N.ofLong(-3)));
    assert(isMultipleOf(N.ofDouble(0.0075), N.ofDouble(0.0001)));
    assert(!isMultipleOf(N.ofDouble(0.00751), N.ofDouble(0.0001)));
}

unittest  // isMultipleOf: a huge dividend over a tiny divisor uses the fmod fallback
{
    alias N = JsonNumber;
    // 2^1000 / 2^-1000 overflows to infinity, forcing the fmod path; both are
    // exact powers of two, so 2^1000 is an exact multiple of 2^-1000.
    const huge = 2.0 ^^ 1000;
    const tiny = 2.0 ^^ -1000;
    assert(isMultipleOf(N.ofDouble(huge), N.ofDouble(tiny)));
}
