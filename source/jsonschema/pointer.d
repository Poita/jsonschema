/// RFC 6901 JSON Pointer: parsing, escaping, and evaluation against the
/// internal document representation. Used for `$ref` fragment resolution.
module jsonschema.pointer;

import jsonschema.node : JsonNode;

@safe:

/// Split a JSON Pointer into unescaped reference tokens. The empty pointer
/// yields an empty array. Returns false for syntactically invalid pointers
/// (not starting with '/', or a bad ~ escape).
bool parsePointer(string pointer, out string[] tokens) pure
{
    tokens = null;
    if (pointer.length == 0)
        return true;
    if (pointer[0] != '/')
        return false;
    size_t start = 1;
    foreach (i; 1 .. pointer.length + 1)
    {
        if (i == pointer.length || pointer[i] == '/')
        {
            string tok;
            if (!unescapeToken(pointer[start .. i], tok))
                return false;
            tokens ~= tok;
            start = i + 1;
        }
    }
    return true;
}

private bool unescapeToken(string s, out string tok) pure
{
    size_t i = 0;
    string r;
    bool copied = false;
    while (i < s.length)
    {
        if (s[i] == '~')
        {
            if (!copied)
            {
                r = s[0 .. i].dup;
                copied = true;
            }
            if (i + 1 >= s.length)
                return false;
            if (s[i + 1] == '0')
                r ~= '~';
            else if (s[i + 1] == '1')
                r ~= '/';
            else
                return false;
            i += 2;
        }
        else
        {
            if (copied)
                r ~= s[i];
            i++;
        }
    }
    tok = copied ? r : s;
    return true;
}

/// Escape one reference token for embedding in a pointer string.
string escapeToken(string s) pure nothrow
{
    bool needs = false;
    foreach (c; s)
        if (c == '~' || c == '/')
        {
            needs = true;
            break;
        }
    if (!needs)
        return s;
    string r;
    foreach (c; s)
    {
        if (c == '~')
            r ~= "~0";
        else if (c == '/')
            r ~= "~1";
        else
            r ~= c;
    }
    return r;
}

/// Evaluate a parsed pointer against a document. Returns null when any token
/// does not resolve.
const(JsonNode)* evaluatePointer(const(JsonNode)* doc, string[] tokens) pure nothrow
{
    auto cur = doc;
    foreach (tok; tokens)
    {
        if (cur is null)
            return null;
        if (cur.isObject)
        {
            cur = cur.get(tok);
        }
        else if (cur.isArray)
        {
            // Array index: digits only, no leading zeros (RFC 6901).
            if (tok.length == 0 || (tok.length > 1 && tok[0] == '0'))
                return null;
            size_t idx = 0;
            foreach (c; tok)
            {
                if (c < '0' || c > '9')
                    return null;
                idx = idx * 10 + (c - '0');
            }
            if (idx >= cur.array_.length)
                return null;
            cur = &cur.array_[idx];
        }
        else
            return null;
    }
    return cur;
}

unittest  // parse the RFC 6901 example pointers
{
    string[] t;
    assert(parsePointer("", t) && t.length == 0);
    assert(parsePointer("/foo", t) && t == ["foo"]);
    assert(parsePointer("/foo/0", t) && t == ["foo", "0"]);
    assert(parsePointer("/", t) && t == [""]);
    assert(parsePointer("/a~1b", t) && t == ["a/b"]);
    assert(parsePointer("/c%d", t) && t == ["c%d"]);
    assert(parsePointer("/m~0n", t) && t == ["m~n"]);
}

unittest  // invalid pointers are rejected
{
    string[] t;
    assert(!parsePointer("foo", t));
    assert(!parsePointer("/a~2b", t));
    assert(!parsePointer("/a~", t));
}

unittest  // escapeToken round-trips
{
    assert(escapeToken("a/b~c") == "a~1b~0c");
    string[] t;
    assert(parsePointer("/" ~ escapeToken("a/b~c"), t) && t == ["a/b~c"]);
    assert(escapeToken("plain") == "plain");
}

unittest  // evaluatePointer walks objects and arrays
{
    import jsonschema.node : parseJson;

    auto docs = [parseJson(`{"foo":["bar","baz"],"a/b":1,"":{"x":2}}`)];
    auto doc = &docs[0];
    string[] t;

    parsePointer("/foo/1", t);
    auto r = evaluatePointer(doc, t);
    assert(r !is null && r.string_ == "baz");

    parsePointer("/a~1b", t);
    assert(evaluatePointer(doc, t).integer_ == 1);

    parsePointer("//x", t);
    assert(evaluatePointer(doc, t).integer_ == 2);
}

unittest  // evaluatePointer rejects bad array indices
{
    import jsonschema.node : parseJson;

    auto docs = [parseJson(`{"a":[1,2]}`)];
    auto doc = &docs[0];
    string[] t;
    parsePointer("/a/01", t);
    assert(evaluatePointer(doc, t) is null);
    parsePointer("/a/2", t);
    assert(evaluatePointer(doc, t) is null);
    parsePointer("/a/-", t);
    assert(evaluatePointer(doc, t) is null);
    parsePointer("/b", t);
    assert(evaluatePointer(doc, t) is null);
}
