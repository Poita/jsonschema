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

    package this(CompiledSchema root, ValidatorSettings settings) pure nothrow
    {
        this.root = root;
        this.settings = settings;
    }

    /// Validate a `std.json.JSONValue` instance.
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
    size_t depth;
    size_t maxDepth;
}

/// Annotation collector for one (schema, instance-location) evaluation: which
/// object properties and array items have been successfully evaluated. This is
/// what `unevaluatedProperties` / `unevaluatedItems` consult, after merging
/// the collectors of all successful in-place applicator branches.
package struct Evaluated
{
    bool allProps;
    bool[string] props;
    size_t itemsPrefix; // indices below this are evaluated
    bool[size_t] extraItems;

    void markProp(string key) pure nothrow
    {
        if (!allProps)
            props[key] = true;
    }

    bool hasProp(string key) const pure nothrow
    {
        return allProps || (key in props) !is null;
    }

    void markItem(size_t i) pure nothrow
    {
        if (i == itemsPrefix)
            itemsPrefix++;
        else if (i > itemsPrefix)
            extraItems[i] = true;
    }

    void markItemsThrough(size_t n) pure nothrow
    {
        if (n > itemsPrefix)
            itemsPrefix = n;
    }

    bool hasItem(size_t i) const pure nothrow
    {
        return i < itemsPrefix || (i in extraItems) !is null;
    }

    void merge(ref const Evaluated o) pure
    {
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

// --- the evaluator ---

package bool evalSchema(A)(const CompiledSchema s, in A.Value v, string ip,
        string kp, ref EvalState!A st, ref Evaluated ev)
{
    if (++st.depth > st.maxDepth)
        throw new ValidationException(
                "schema evaluation exceeded the depth limit (unboundedly recursive schema?)");
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
    if (s.resource !is null && (st.dynStack.length == 0 || st.dynStack[$ - 1]!is s.resource))
    {
        st.dynStack ~= s.resource;
        pushed = true;
    }
    scope (exit)
        if (pushed)
            st.dynStack.length--;

    bool ok = true;
    const kind = A.kindOf(v);

    // --- core: references (in-place applicators) ---
    if (s.refIsExclusive)
    {
        // Up to draft-07, a `$ref` suppresses every sibling keyword: evaluate
        // only the reference and adopt its annotations.
        Evaluated sub;
        const r = evalSchema!A(s.refInfo.target, v, ip, kp ~ "/$ref", st, sub);
        if (r)
            ev.merge(sub);
        return r;
    }
    if (s.refInfo !is null)
    {
        Evaluated sub;
        if (evalSchema!A(s.refInfo.target, v, ip, kp ~ "/$ref", st, sub))
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
        if (evalSchema!A(target, v, ip, kp ~ "/$dynamicRef", st, sub))
            ev.merge(sub);
        else
            ok = false;
    }

    // --- validation: any instance type ---
    if (s.hasType && !typeMatches!A(s.typeMask, v, kind))
    {
        fail(st, ip, kp ~ "/type", "instance type does not match");
        ok = false;
    }
    if (s.hasConst && !valueEqualsNode!A(v, s.constValue, kind))
    {
        fail(st, ip, kp ~ "/const", "instance does not equal the const value");
        ok = false;
    }
    if (s.hasEnum)
    {
        bool found;
        foreach (ref e; s.enumValues)
            if (valueEqualsNode!A(v, e, kind))
            {
                found = true;
                break;
            }
        if (!found)
        {
            fail(st, ip, kp ~ "/enum", "instance is not one of the enum values");
            ok = false;
        }
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
        fail(st, ip, kp ~ "/format", "instance does not match format '" ~ s.format ~ "'");
        ok = false;
    }

    // --- in-place applicators ---
    foreach (i, sub; s.allOf)
    {
        Evaluated se;
        if (evalSchema!A(sub, v, ip, kp ~ "/allOf/" ~ i.to!string, st, se))
            ev.merge(se);
        else
            ok = false;
    }
    if (s.anyOf.length)
    {
        const mark = st.errors.length;
        bool any;
        foreach (i, sub; s.anyOf)
        {
            Evaluated se;
            if (evalSchema!A(sub, v, ip, kp ~ "/anyOf/" ~ i.to!string, st, se))
            {
                any = true;
                ev.merge(se);
            }
        }
        if (any)
            shrinkErrors(st, mark);
        else
        {
            fail(st, ip, kp ~ "/anyOf", "instance does not match any anyOf branch");
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
            if (evalSchema!A(sub, v, ip, kp ~ "/oneOf/" ~ i.to!string, st, se))
            {
                matches++;
                ev.merge(se);
            }
        }
        if (matches == 1)
            shrinkErrors(st, mark);
        else
        {
            if (matches > 1)
                shrinkErrors(st, mark);
            fail(st, ip, kp ~ "/oneOf", matches == 0
                    ? "instance does not match any oneOf branch"
                    : "instance matches more than one oneOf branch");
            ok = false;
        }
    }
    if (s.notSchema !is null)
    {
        const mark = st.errors.length;
        Evaluated se; // annotations inside "not" are never retained
        const r = evalSchema!A(s.notSchema, v, ip, kp ~ "/not", st, se);
        shrinkErrors(st, mark);
        if (r)
        {
            fail(st, ip, kp ~ "/not", "instance must not match the 'not' schema");
            ok = false;
        }
    }
    if (s.ifSchema !is null)
    {
        const mark = st.errors.length;
        Evaluated condEv;
        const condOk = evalSchema!A(s.ifSchema, v, ip, kp ~ "/if", st, condEv);
        shrinkErrors(st, mark); // "if" outcomes are not failures
        if (condOk)
        {
            ev.merge(condEv);
            if (s.thenSchema !is null)
            {
                Evaluated se;
                if (evalSchema!A(s.thenSchema, v, ip, kp ~ "/then", st, se))
                    ev.merge(se);
                else
                    ok = false;
            }
        }
        else if (s.elseSchema !is null)
        {
            Evaluated se;
            if (evalSchema!A(s.elseSchema, v, ip, kp ~ "/else", st, se))
                ev.merge(se);
            else
                ok = false;
        }
    }

    // --- objects ---
    if (kind == JsonKind.object)
        ok &= checkObject!A(s, v, ip, kp, st, ev);

    // --- arrays ---
    if (kind == JsonKind.array)
        ok &= checkArray!A(s, v, ip, kp, st, ev);

    // --- unevaluated*, after everything else at this location ---
    if (s.unevaluatedProperties !is null && kind == JsonKind.object)
    {
        bool failed;
        A.objectEach(v, (string key, in A.Value member) {
            if (ev.hasProp(key))
                return 0;
            Evaluated se;
            if (evalSchema!A(s.unevaluatedProperties, member,
                ip ~ "/" ~ escapeToken(key), kp ~ "/unevaluatedProperties", st, se))
                ev.markProp(key);
            else
                failed = true;
            return 0;
        });
        if (failed)
        {
            fail(st, ip, kp ~ "/unevaluatedProperties", "unevaluated properties do not validate");
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
            if (evalSchema!A(s.unevaluatedItems, elem, ip ~ "/" ~ i.to!string,
                    kp ~ "/unevaluatedItems", st, se))
                ev.markItem(i);
            else
                failed = true;
        }
        if (failed)
        {
            fail(st, ip, kp ~ "/unevaluatedItems", "unevaluated items do not validate");
            ok = false;
        }
    }

    return ok;
}

private void shrinkErrors(A)(ref EvalState!A st, size_t mark) pure nothrow @trusted
{
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
        fail(st, ip, kp ~ "/multipleOf", "instance is not a multiple of the divisor");
        ok = false;
    }
    if (s.hasMaximum && cmpNumbers(n, s.maximum) > 0)
    {
        fail(st, ip, kp ~ "/maximum", "instance exceeds the maximum");
        ok = false;
    }
    if (s.hasExclusiveMaximum && cmpNumbers(n, s.exclusiveMaximum) >= 0)
    {
        fail(st, ip, kp ~ "/exclusiveMaximum", "instance is not below the exclusive maximum");
        ok = false;
    }
    if (s.hasMinimum && cmpNumbers(n, s.minimum) < 0)
    {
        fail(st, ip, kp ~ "/minimum", "instance is below the minimum");
        ok = false;
    }
    if (s.hasExclusiveMinimum && cmpNumbers(n, s.exclusiveMinimum) <= 0)
    {
        fail(st, ip, kp ~ "/exclusiveMinimum", "instance is not above the exclusive minimum");
        ok = false;
    }
    return ok;
}

private bool checkString(A)(const CompiledSchema s, string str, string ip,
        string kp, ref EvalState!A st)
{
    bool ok = true;
    if (s.maxLength != absent || s.minLength != absent)
    {
        import std.utf : count;

        const len = () @trusted { return str.count; }();
        if (s.maxLength != absent && len > s.maxLength)
        {
            fail(st, ip, kp ~ "/maxLength", "string is longer than maxLength");
            ok = false;
        }
        if (s.minLength != absent && len < s.minLength)
        {
            fail(st, ip, kp ~ "/minLength", "string is shorter than minLength");
            ok = false;
        }
    }
    if (s.hasPattern)
    {
        import std.regex : matchFirst;

        if (matchFirst(str, s.pattern).empty)
        {
            fail(st, ip, kp ~ "/pattern", "string does not match pattern '" ~ s.patternSource ~ "'");
            ok = false;
        }
    }
    return ok;
}

private bool checkObject(A)(const CompiledSchema s, in A.Value v, string ip,
        string kp, ref EvalState!A st, ref Evaluated ev)
{
    bool ok = true;
    const len = A.objectLength(v);

    if (s.maxProperties != absent && len > s.maxProperties)
    {
        fail(st, ip, kp ~ "/maxProperties", "object has more than maxProperties members");
        ok = false;
    }
    if (s.minProperties != absent && len < s.minProperties)
    {
        fail(st, ip, kp ~ "/minProperties", "object has fewer than minProperties members");
        ok = false;
    }
    foreach (name; s.required)
        if (A.objectGet(v, name) is null)
        {
            fail(st, ip, kp ~ "/required", "missing required property '" ~ name ~ "'");
            ok = false;
        }
    foreach (trigger, names; s.dependentRequired)
        if (A.objectGet(v, trigger) !is null)
            foreach (name; names)
                if (A.objectGet(v, name) is null)
                {
                    fail(st, ip, kp ~ "/dependentRequired",
                            "property '" ~ trigger ~ "' requires property '" ~ name ~ "'");
                    ok = false;
                }
    foreach (trigger, sub; s.dependentSchemas)
        if (A.objectGet(v, trigger) !is null)
        {
            Evaluated se;
            if (evalSchema!A(sub, v, ip, kp ~ "/dependentSchemas/" ~ escapeToken(trigger), st, se))
                ev.merge(se);
            else
                ok = false;
        }

    if (s.properties.length || s.patternProperties.length
            || s.additionalProperties !is null || s.propertyNames !is null)
    {
        import std.regex : matchFirst;

        bool failed;
        A.objectEach(v, (string key, in A.Value member) {
            const mp = ip ~ "/" ~ escapeToken(key);
            bool matched;
            if (auto p = key in s.properties)
            {
                Evaluated se;
                if (evalSchema!A(*p, member, mp, kp ~ "/properties/" ~ escapeToken(key), st, se))
                    ev.markProp(key);
                else
                    failed = true;
                matched = true;
            }
            foreach (ref pp; s.patternProperties)
                if (!matchFirst(key, pp.regex).empty)
                {
                    Evaluated se;
                    if (evalSchema!A(pp.schema, member, mp,
                        kp ~ "/patternProperties/" ~ escapeToken(pp.source), st, se))
                        ev.markProp(key);
                    else
                        failed = true;
                    matched = true;
                }
            if (!matched && s.additionalProperties !is null)
            {
                Evaluated se;
                if (evalSchema!A(s.additionalProperties, member, mp,
                    kp ~ "/additionalProperties", st, se))
                    ev.markProp(key);
                else
                    failed = true;
            }
            if (s.propertyNames !is null)
            {
                const nameValue = A.ofString(key);
                Evaluated se;
                if (!evalSchema!A(s.propertyNames, nameValue, mp, kp ~ "/propertyNames", st, se))
                    failed = true;
            }
            return 0;
        });
        if (failed)
            ok = false;
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
        fail(st, ip, kp ~ "/maxItems", "array has more than maxItems items");
        ok = false;
    }
    if (s.minItems != absent && len < s.minItems)
    {
        fail(st, ip, kp ~ "/minItems", "array has fewer than minItems items");
        ok = false;
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
                    fail(st, ip, kp ~ "/uniqueItems", "array items are not unique");
                    ok = false;
                    break outer;
                }
            }
        }
    }

    if (s.hasPrefixItems)
    {
        bool failed;
        const n = s.prefixItems.length < len ? s.prefixItems.length : len;
        foreach (i; 0 .. n)
        {
            const elem = A.arrayAt(v, i);
            Evaluated se;
            if (evalSchema!A(s.prefixItems[i], elem, ip ~ "/" ~ i.to!string,
                    kp ~ "/prefixItems/" ~ i.to!string, st, se))
                ev.markItem(i);
            else
                failed = true;
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
            if (evalSchema!A(s.itemsSchema, elem, ip ~ "/" ~ i.to!string, kp ~ "/items", st, se))
                ev.markItem(i);
            else
                failed = true;
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
            if (evalSchema!A(s.additionalItemsSchema, elem,
                    ip ~ "/" ~ i.to!string, kp ~ "/additionalItems", st, se))
                ev.markItem(i);
            else
                failed = true;
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
            if (evalSchema!A(s.containsSchema, elem, ip ~ "/" ~ i.to!string,
                    kp ~ "/contains", st, se))
                matchedIdx ~= i;
        }
        const minC = s.minContains != absent ? s.minContains : 1;
        bool groupOk = true;
        if (cast(long) matchedIdx.length < minC)
        {
            shrinkErrors(st, mark); // keep only the summary below
            fail(st, ip, kp ~ "/contains", minC == 1
                    ? "array contains no matching item"
                    : "array contains fewer matching items than minContains");
            groupOk = false;
        }
        else
            shrinkErrors(st, mark); // non-matching items are not failures
        if (s.maxContains != absent && cast(long) matchedIdx.length > s.maxContains)
        {
            fail(st, ip, kp ~ "/maxContains",
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
