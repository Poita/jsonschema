/// RFC 3986 URI handling: parsing into components, reference resolution
/// against a base URI (§5.2), and fragment splitting. Used for `$id`, `$ref`,
/// `$anchor`, and `$dynamicRef` base-URI resolution.
module jsonschema.uri;

@safe:

/// Decomposed URI reference (RFC 3986 §3). Empty-vs-absent matters for
/// authority and query, so those carry presence flags.
struct Uri
{
    string scheme; // without ':'; empty = relative reference
    bool hasAuthority;
    string authority;
    string path;
    bool hasQuery;
    string query;
    bool hasFragment;
    string fragment;

    /// Recompose per RFC 3986 §5.3.
    string toString() const pure nothrow
    {
        string r;
        if (scheme.length)
            r ~= scheme ~ ":";
        if (hasAuthority)
            r ~= "//" ~ authority;
        r ~= path;
        if (hasQuery)
            r ~= "?" ~ query;
        if (hasFragment)
            r ~= "#" ~ fragment;
        return r;
    }
}

/// Parse a URI reference into components (regex from RFC 3986 appendix B,
/// implemented directly).
Uri parseUri(string s) pure nothrow
{
    Uri u;
    // fragment
    foreach (i; 0 .. s.length)
        if (s[i] == '#')
        {
            u.hasFragment = true;
            u.fragment = s[i + 1 .. $];
            s = s[0 .. i];
            break;
        }
    // scheme: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":"
    foreach (i; 0 .. s.length)
    {
        const c = s[i];
        if (c == ':' && i > 0)
        {
            u.scheme = s[0 .. i];
            s = s[i + 1 .. $];
            break;
        }
        const alpha = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
        const schemeChar = alpha || (c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.';
        if (i == 0 ? !alpha : !schemeChar)
            break;
    }
    // authority
    if (s.length >= 2 && s[0] == '/' && s[1] == '/')
    {
        s = s[2 .. $];
        size_t end = s.length;
        foreach (i; 0 .. s.length)
            if (s[i] == '/' || s[i] == '?')
            {
                end = i;
                break;
            }
        u.hasAuthority = true;
        u.authority = s[0 .. end];
        s = s[end .. $];
    }
    // query
    foreach (i; 0 .. s.length)
        if (s[i] == '?')
        {
            u.hasQuery = true;
            u.query = s[i + 1 .. $];
            s = s[0 .. i];
            break;
        }
    u.path = s;
    return u;
}

/// Remove "." and ".." path segments (RFC 3986 §5.2.4).
string removeDotSegments(string input) pure nothrow
{
    string output;
    while (input.length)
    {
        if (input.length >= 3 && input[0 .. 3] == "../")
            input = input[3 .. $];
        else if (input.length >= 2 && input[0 .. 2] == "./")
            input = input[2 .. $];
        else if (input.length >= 3 && input[0 .. 3] == "/./")
            input = "/" ~ input[3 .. $];
        else if (input == "/.")
            input = "/";
        else if (input.length >= 4 && input[0 .. 4] == "/../")
        {
            input = "/" ~ input[4 .. $];
            output = popLastSegment(output);
        }
        else if (input == "/..")
        {
            input = "/";
            output = popLastSegment(output);
        }
        else if (input == "." || input == "..")
            input = "";
        else
        {
            size_t end = input.length;
            foreach (i; (input[0] == '/' ? 1 : 0) .. input.length)
                if (input[i] == '/')
                {
                    end = i;
                    break;
                }
            output ~= input[0 .. end];
            input = input[end .. $];
        }
    }
    return output;
}

private string popLastSegment(string s) pure nothrow
{
    foreach_reverse (i; 0 .. s.length)
        if (s[i] == '/')
            return s[0 .. i];
    return "";
}

/// Resolve a URI reference against a base URI (RFC 3986 §5.2.2) and return the
/// recomposed target string. The fragment of `reference` is preserved; the
/// base's fragment never propagates.
string resolveUri(string base, string reference) pure nothrow
{
    const r = parseUri(reference);
    const b = parseUri(base);
    Uri t;
    if (r.scheme.length)
    {
        t.scheme = r.scheme;
        t.hasAuthority = r.hasAuthority;
        t.authority = r.authority;
        t.path = removeDotSegments(r.path);
        t.hasQuery = r.hasQuery;
        t.query = r.query;
    }
    else
    {
        if (r.hasAuthority)
        {
            t.hasAuthority = true;
            t.authority = r.authority;
            t.path = removeDotSegments(r.path);
            t.hasQuery = r.hasQuery;
            t.query = r.query;
        }
        else
        {
            if (r.path.length == 0)
            {
                t.path = b.path;
                t.hasQuery = r.hasQuery ? true : b.hasQuery;
                t.query = r.hasQuery ? r.query : b.query;
            }
            else
            {
                if (r.path[0] == '/')
                    t.path = removeDotSegments(r.path);
                else
                    t.path = removeDotSegments(mergePaths(b, r.path));
                t.hasQuery = r.hasQuery;
                t.query = r.query;
            }
            t.hasAuthority = b.hasAuthority;
            t.authority = b.authority;
        }
        t.scheme = b.scheme;
    }
    t.hasFragment = r.hasFragment;
    t.fragment = r.fragment;
    return t.toString();
}

private string mergePaths(in Uri base, string refPath) pure nothrow
{
    if (base.hasAuthority && base.path.length == 0)
        return "/" ~ refPath;
    return popLastSegment(base.path) ~ "/" ~ refPath;
}

/// Split a URI into its fragment-free part and the fragment ("" when none).
void splitFragment(string uri, out string base, out string fragment) pure nothrow
{
    foreach (i; 0 .. uri.length)
        if (uri[i] == '#')
        {
            base = uri[0 .. i];
            fragment = uri[i + 1 .. $];
            return;
        }
    base = uri;
    fragment = "";
}

/// Percent-decode a string (used on JSON Pointer fragments). Invalid escapes
/// are left verbatim.
string percentDecode(string s) pure nothrow
{
    if (s.length == 0)
        return s;
    string r;
    r.reserve(s.length);
    size_t i = 0;
    while (i < s.length)
    {
        if (s[i] == '%' && i + 2 < s.length + 0 && i + 2 < s.length)
        {
            const h = hexVal(s[i + 1]);
            const l = hexVal(s[i + 2]);
            if (h >= 0 && l >= 0)
            {
                r ~= cast(char)((h << 4) | l);
                i += 3;
                continue;
            }
        }
        r ~= s[i];
        i++;
    }
    return r;
}

private int hexVal(char c) pure nothrow
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

unittest // parse an absolute URI with all components
{
    auto u = parseUri("https://example.com/a/b?q=1#frag");
    assert(u.scheme == "https");
    assert(u.hasAuthority && u.authority == "example.com");
    assert(u.path == "/a/b");
    assert(u.hasQuery && u.query == "q=1");
    assert(u.hasFragment && u.fragment == "frag");
}

unittest // parse a relative reference
{
    auto u = parseUri("../x/y");
    assert(u.scheme == "");
    assert(!u.hasAuthority);
    assert(u.path == "../x/y");
}

unittest // a colon inside the path does not create a scheme when prefix is invalid
{
    auto u = parseUri("./a:b");
    assert(u.scheme == "");
    assert(u.path == "./a:b");
}

unittest // urn parses as scheme + opaque path
{
    auto u = parseUri("urn:uuid:deadbeef-1234-ffff-ffff-4321feebdaed");
    assert(u.scheme == "urn");
    assert(u.path == "uuid:deadbeef-1234-ffff-ffff-4321feebdaed");
}

unittest // resolveUri: RFC 3986 §5.4.1 normal examples
{
    const base = "http://a/b/c/d;p?q";
    assert(resolveUri(base, "g") == "http://a/b/c/g");
    assert(resolveUri(base, "./g") == "http://a/b/c/g");
    assert(resolveUri(base, "g/") == "http://a/b/c/g/");
    assert(resolveUri(base, "/g") == "http://a/g");
    assert(resolveUri(base, "//g") == "http://g");
    assert(resolveUri(base, "?y") == "http://a/b/c/d;p?y");
    assert(resolveUri(base, "g?y") == "http://a/b/c/g?y");
    assert(resolveUri(base, "#s") == "http://a/b/c/d;p?q#s");
    assert(resolveUri(base, "g#s") == "http://a/b/c/g#s");
    assert(resolveUri(base, ";x") == "http://a/b/c/;x");
    assert(resolveUri(base, "") == "http://a/b/c/d;p?q");
    assert(resolveUri(base, ".") == "http://a/b/c/");
    assert(resolveUri(base, "..") == "http://a/b/");
    assert(resolveUri(base, "../g") == "http://a/b/g");
    assert(resolveUri(base, "../..") == "http://a/");
    assert(resolveUri(base, "../../g") == "http://a/g");
}

unittest // resolveUri: RFC 3986 §5.4.2 abnormal examples
{
    const base = "http://a/b/c/d;p?q";
    assert(resolveUri(base, "../../../g") == "http://a/g");
    assert(resolveUri(base, "../../../../g") == "http://a/g");
    assert(resolveUri(base, "/./g") == "http://a/g");
    assert(resolveUri(base, "/../g") == "http://a/g");
    assert(resolveUri(base, "g.") == "http://a/b/c/g.");
    assert(resolveUri(base, ".g") == "http://a/b/c/.g");
    assert(resolveUri(base, "g..") == "http://a/b/c/g..");
    assert(resolveUri(base, "..g") == "http://a/b/c/..g");
    assert(resolveUri(base, "./../g") == "http://a/b/g");
    assert(resolveUri(base, "./g/.") == "http://a/b/c/g/");
    assert(resolveUri(base, "g/./h") == "http://a/b/c/g/h");
    assert(resolveUri(base, "g/../h") == "http://a/b/c/h");
    assert(resolveUri(base, "g;x=1/./y") == "http://a/b/c/g;x=1/y");
    assert(resolveUri(base, "g;x=1/../y") == "http://a/b/c/y");
    assert(resolveUri(base, "http:g") == "http:g");
}

unittest // resolveUri against a urn base keeps the urn for fragment-only refs
{
    assert(resolveUri("urn:uuid:dead-beef", "#frag") == "urn:uuid:dead-beef#frag");
}

unittest // resolveUri with an absolute reference ignores the base
{
    assert(resolveUri("http://a/b", "https://x/y#f") == "https://x/y#f");
}

unittest // splitFragment
{
    string b, f;
    splitFragment("http://a/b#/c/d", b, f);
    assert(b == "http://a/b" && f == "/c/d");
    splitFragment("http://a/b", b, f);
    assert(b == "http://a/b" && f == "");
    splitFragment("#anchor", b, f);
    assert(b == "" && f == "anchor");
}

unittest // percentDecode
{
    assert(percentDecode("a%20b") == "a b");
    assert(percentDecode("%7Euser") == "~user");
    assert(percentDecode("100%") == "100%");
    assert(percentDecode("a%2Gb") == "a%2Gb");
}
