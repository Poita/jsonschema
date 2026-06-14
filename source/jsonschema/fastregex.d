/// A tiny matcher for the common, ASCII-only subset of ECMA-262 patterns that
/// dominate real-world JSON Schemas (structured identifiers like
/// `^[A-Z]{2,4}-[0-9]{3,6}$`). `std.regex`'s general engine is correct but slow;
/// for patterns that compile into this subset the matcher below is a tight
/// backtracking loop that is byte-equivalent to `std.regex` on UTF-8 input.
///
/// Safety of byte-wise matching: the subset admits only ASCII literals and
/// positive ASCII character classes. In valid UTF-8 an ASCII byte never appears
/// inside a multi-byte sequence, so matching such tokens byte-by-byte yields the
/// same result as code-point matching. Anything outside the subset — `.`, the
/// `\d`/`\w`/`\s` shorthands (whose Unicode semantics are subtle), negated
/// classes, groups, alternation, anchors other than `^`/`$` — makes `compile`
/// return `false`, and the caller keeps using `std.regex`.
module jsonschema.fastregex;

@safe:

/// One pattern atom plus its greedy quantifier bounds.
private struct Tok
{
    bool isClass;
    char lit; /// literal byte when `!isClass`
    bool[128] cls; /// ASCII membership when `isClass`
    size_t min = 1;
    size_t max = 1;
}

/// A compiled simple pattern. Default-constructed / `!compiled` means the source
/// was outside the supported subset and the caller must fall back to std.regex.
struct FastRegex
{
    private Tok[] toks;
    private bool anchoredStart;
    private bool anchoredEnd;
    bool compiled;

    /// Partial-match semantics matching JSON Schema `pattern`: true if the
    /// pattern matches anywhere in `s` (subject to its `^`/`$` anchors).
    bool matches(scope const(char)[] s) const @trusted @nogc nothrow pure
    {
        if (anchoredStart)
            return matchFrom(0, 0, s);
        foreach (start; 0 .. s.length + 1)
            if (matchFrom(0, start, s))
                return true;
        return false;
    }

    private bool matchFrom(size_t ti, size_t si, scope const(char)[] s) const @trusted @nogc nothrow pure
    {
        if (ti == toks.length)
            return anchoredEnd ? si == s.length : true;
        const t = &toks[ti];
        // Greedily consume up to `max` matching bytes, then backtrack toward
        // `min`, trying the rest of the program at each length.
        size_t n;
        while (n < t.max && si + n < s.length && tokMatch(t, s[si + n]))
            n++;
        while (n + 1 > t.min) // n down to t.min, inclusive, guarding unsigned
        {
            if (matchFrom(ti + 1, si + n, s))
                return true;
            if (n == 0)
                break;
            n--;
        }
        return false;
    }

    private static bool tokMatch(const(Tok)* t, char c) @trusted @nogc nothrow pure
    {
        if (cast(ubyte) c >= 128)
            return false; // only ASCII tokens are admitted into the subset
        return t.isClass ? t.cls[cast(ubyte) c] : c == t.lit;
    }
}

/// Try to compile `src` into the supported subset. Returns a `FastRegex` with
/// `compiled == false` when the pattern uses any unsupported feature.
FastRegex compile(string src) nothrow pure
{
    FastRegex r;
    size_t i;
    const n = src.length;
    if (n && src[0] == '^')
    {
        r.anchoredStart = true;
        i = 1;
    }
    bool sawEnd;
    while (i < n)
    {
        const c = src[i];
        if (cast(ubyte) c >= 128)
            return r; // non-ASCII: bail
        if (c == '$')
        {
            // `$` is only an end anchor as the final character.
            if (i + 1 != n)
                return r;
            sawEnd = true;
            i++;
            break;
        }
        // Forbid features whose semantics we do not replicate.
        if (c == '.' || c == '(' || c == ')' || c == '|' || c == '[' && i + 1 < n && src[i + 1] == '^')
        {
            if (c == '[')
            { /* fall through to class parse which rejects negation below */ }
            else
                return r;
        }

        Tok t;
        if (c == '[')
        {
            size_t j = i + 1;
            if (j < n && src[j] == '^')
                return r; // negated class: byte-wise negation is unsafe on UTF-8
            bool[128] set;
            bool any;
            while (j < n && src[j] != ']')
            {
                if (cast(ubyte) src[j] >= 128 || src[j] == '\\')
                    return r; // non-ASCII or escapes inside classes: bail
                if (j + 2 < n && src[j + 1] == '-' && src[j + 2] != ']')
                {
                    const lo = cast(ubyte) src[j];
                    const hi = cast(ubyte) src[j + 2];
                    if (lo >= 128 || hi >= 128 || lo > hi)
                        return r;
                    foreach (k; lo .. hi + 1)
                        set[k] = true;
                    j += 3;
                }
                else
                {
                    set[cast(ubyte) src[j]] = true;
                    j++;
                }
                any = true;
            }
            if (j >= n || !any)
                return r; // unterminated or empty class
            t.isClass = true;
            t.cls = set;
            i = j + 1;
        }
        else if (c == '\\')
        {
            // Only escaped literals of ASCII punctuation are supported.
            if (i + 1 >= n)
                return r;
            const e = src[i + 1];
            if (cast(ubyte) e >= 128 || (e >= 'a' && e <= 'z') || (e >= 'A'
                    && e <= 'Z') || (e >= '0' && e <= '9'))
                return r; // \d \w \s \b … and unknown escapes: bail
            t.lit = e;
            i += 2;
        }
        else
        {
            t.lit = c;
            i++;
        }

        // Optional quantifier on this atom.
        if (i < n)
        {
            const q = src[i];
            if (q == '*')
            {
                t.min = 0;
                t.max = size_t.max;
                i++;
            }
            else if (q == '+')
            {
                t.min = 1;
                t.max = size_t.max;
                i++;
            }
            else if (q == '?')
            {
                t.min = 0;
                t.max = 1;
                i++;
            }
            else if (q == '{')
            {
                size_t j = i + 1, lo, hi;
                bool gotLo;
                while (j < n && src[j] >= '0' && src[j] <= '9')
                {
                    lo = lo * 10 + (src[j] - '0');
                    j++;
                    gotLo = true;
                }
                if (!gotLo)
                    return r;
                if (j < n && src[j] == '}')
                {
                    hi = lo;
                    j++;
                }
                else if (j < n && src[j] == ',')
                {
                    j++;
                    if (j < n && src[j] == '}')
                    {
                        hi = size_t.max;
                        j++;
                    }
                    else
                    {
                        bool gotHi;
                        while (j < n && src[j] >= '0' && src[j] <= '9')
                        {
                            hi = hi * 10 + (src[j] - '0');
                            j++;
                            gotHi = true;
                        }
                        if (!gotHi || j >= n || src[j] != '}')
                            return r;
                        j++;
                    }
                }
                else
                    return r;
                // A lazy `?` after the quantifier changes semantics: bail.
                if (j < n && src[j] == '?')
                    return r;
                t.min = lo;
                t.max = hi;
                i = j;
            }
            else if (q == '?' )
                return r;
        }
        r.toks ~= t;
    }
    r.anchoredEnd = sawEnd;
    r.compiled = true;
    return r;
}

// --- tests ---

private bool m(string pat, string s)
{
    auto r = compile(pat);
    assert(r.compiled, "pattern should be in the supported subset: " ~ pat);
    return r.matches(s);
}

unittest // anchored structured-id patterns
{
    assert(m(`^ORD-[0-9]{8}$`, "ORD-12345678"));
    assert(!m(`^ORD-[0-9]{8}$`, "ORD-1234567"));
    assert(!m(`^ORD-[0-9]{8}$`, "ORD-123456789"));
    assert(!m(`^ORD-[0-9]{8}$`, "xORD-12345678"));
}

unittest // ranged quantifiers and multiple classes
{
    assert(m(`^[A-Z]{2,4}-[0-9]{3,6}$`, "AB-123"));
    assert(m(`^[A-Z]{2,4}-[0-9]{3,6}$`, "ABCD-123456"));
    assert(!m(`^[A-Z]{2,4}-[0-9]{3,6}$`, "A-123")); // too few letters
    assert(!m(`^[A-Z]{2,4}-[0-9]{3,6}$`, "ABCDE-123")); // too many letters
    assert(!m(`^[A-Z]{2,4}-[0-9]{3,6}$`, "AB-12")); // too few digits
}

unittest // partial (unanchored) match semantics
{
    assert(m(`[0-9]{3}`, "abc123def"));
    assert(!m(`[0-9]{3}`, "ab12cd"));
    auto r = compile(`b.t`); // '.' is unsupported
    assert(!r.compiled);
}

unittest // * + ? quantifiers
{
    assert(m(`^a*b$`, "b"));
    assert(m(`^a*b$`, "aaab"));
    assert(m(`^a+b$`, "ab"));
    assert(!m(`^a+b$`, "b"));
    assert(m(`^colou?r$`, "color"));
    assert(m(`^colou?r$`, "colour"));
}

unittest // unsupported features fall back (compiled == false)
{
    assert(!compile(`(ab)+`).compiled);
    assert(!compile(`a|b`).compiled);
    assert(!compile(`[^x]`).compiled);
    assert(!compile(`\d+`).compiled);
    assert(!compile(`a.c`).compiled);
}

unittest // escaped ASCII punctuation literal
{
    assert(m(`^a\.b$`, "a.b"));
    assert(!m(`^a\.b$`, "axb"));
}

unittest // ASCII-only: non-ASCII input never matches an ASCII class
{
    assert(!m(`^[a-z]+$`, "héllo"));
    assert(m(`^[a-z]+$`, "hello"));
}
