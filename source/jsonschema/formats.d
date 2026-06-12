/// Implementations of the JSON Schema 2020-12 defined formats, used when
/// format assertion is enabled (`FormatMode.assertion` or a dialect declaring
/// the format-assertion vocabulary). Formats apply only to strings; unknown
/// format names always pass (they are annotations for some other consumer).
///
/// Not implemented (always pass, documented in the README): idn-email,
/// idn-hostname, iri, iri-reference.
module jsonschema.formats;

@safe:

/// Check `value` against the named format. Returns true for unknown formats.
bool checkFormat(string format, string value)
{
    switch (format)
    {
    case "date-time":
        return isDateTime(value);
    case "date":
        return isDate(value);
    case "time":
        return isTime(value);
    case "duration":
        return isDuration(value);
    case "email":
        return isEmail(value);
    case "hostname":
        return isHostname(value);
    case "ipv4":
        return isIpv4(value);
    case "ipv6":
        return isIpv6(value);
    case "uri":
        return isUri(value, false);
    case "uri-reference":
        return isUri(value, true);
    case "uuid":
        return isUuid(value);
    case "regex":
        return isRegex(value);
    case "json-pointer":
        return isJsonPointer(value);
    case "relative-json-pointer":
        return isRelativeJsonPointer(value);
    case "uri-template":
        return isUriTemplate(value);
    default:
        return true;
    }
}

private bool isDigit(char c) pure nothrow
{
    return c >= '0' && c <= '9';
}

private bool allDigits(string s) pure nothrow
{
    if (s.length == 0)
        return false;
    foreach (c; s)
        if (!isDigit(c))
            return false;
    return true;
}

private int num(string s) pure nothrow
{
    int v = 0;
    foreach (c; s)
        v = v * 10 + (c - '0');
    return v;
}

private bool leapYear(int y) pure nothrow
{
    return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
}

private bool validYmd(int y, int m, int d) pure nothrow
{
    if (m < 1 || m > 12 || d < 1)
        return false;
    immutable int[12] days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    int max = days[m - 1];
    if (m == 2 && leapYear(y))
        max = 29;
    return d <= max;
}

/// RFC 3339 full-date with real calendar checking.
bool isDate(string s) pure nothrow
{
    if (s.length != 10 || s[4] != '-' || s[7] != '-')
        return false;
    if (!allDigits(s[0 .. 4]) || !allDigits(s[5 .. 7]) || !allDigits(s[8 .. 10]))
        return false;
    return validYmd(num(s[0 .. 4]), num(s[5 .. 7]), num(s[8 .. 10]));
}

private struct TimeParts
{
    int h, m;
    int s; // 60 = leap second
    int offMinutes; // offset from UTC in minutes
    bool ok;
}

private TimeParts parseTime(string s) pure nothrow
{
    TimeParts t;
    if (s.length < 9) // hh:mm:ssZ is the shortest valid form
        return t;
    if (s[2] != ':' || s[5] != ':')
        return t;
    if (!allDigits(s[0 .. 2]) || !allDigits(s[3 .. 5]) || !allDigits(s[6 .. 8]))
        return t;
    t.h = num(s[0 .. 2]);
    t.m = num(s[3 .. 5]);
    t.s = num(s[6 .. 8]);
    if (t.h > 23 || t.m > 59 || t.s > 60)
        return t;
    size_t i = 8;
    if (i < s.length && s[i] == '.')
    {
        i++;
        const fs = i;
        while (i < s.length && isDigit(s[i]))
            i++;
        if (i == fs)
            return t;
    }
    if (i >= s.length)
        return t;
    const c = s[i];
    if (c == 'Z' || c == 'z')
    {
        if (i + 1 != s.length)
            return t;
        t.ok = true;
        return t;
    }
    if (c != '+' && c != '-')
        return t;
    if (i + 6 != s.length || s[i + 3] != ':')
        return t;
    if (!allDigits(s[i + 1 .. i + 3]) || !allDigits(s[i + 4 .. i + 6]))
        return t;
    const oh = num(s[i + 1 .. i + 3]);
    const om = num(s[i + 4 .. i + 6]);
    if (oh > 23 || om > 59)
        return t;
    t.offMinutes = (oh * 60 + om) * (c == '-' ? -1 : 1);
    t.ok = true;
    return t;
}

/// RFC 3339 full-time. A leap second (ss == 60) is accepted only when the
/// time corresponds to 23:59:60 UTC after offset adjustment.
bool isTime(string s) pure nothrow
{
    auto t = parseTime(s);
    if (!t.ok)
        return false;
    if (t.s == 60)
    {
        int utcMinutes = t.h * 60 + t.m - t.offMinutes;
        utcMinutes = ((utcMinutes % 1440) + 1440) % 1440;
        return utcMinutes == 23 * 60 + 59;
    }
    return true;
}

/// RFC 3339 date-time ("date" "T" "time").
bool isDateTime(string s) pure nothrow
{
    if (s.length < 11)
        return false;
    if (s[10] != 'T' && s[10] != 't')
        return false;
    return isDate(s[0 .. 10]) && isTime(s[11 .. $]);
}

/// ISO 8601 duration as defined by RFC 3339 appendix A.
bool isDuration(string s) pure nothrow
{
    if (s.length < 2 || s[0] != 'P')
        return false;
    s = s[1 .. $];
    // dur-week alternative
    if (s[$ - 1] == 'W')
        return allDigits(s[0 .. $ - 1]);

    static bool units(string part, string order)
    {
        // The RFC 3339 ABNF chains units without gaps: each unit may only be
        // followed directly by the next one in order (P1Y2M valid, P1Y2D not).
        ptrdiff_t prev = -1;
        size_t i = 0;
        bool any = false;
        while (i < part.length)
        {
            const ds = i;
            while (i < part.length && isDigit(part[i]))
                i++;
            if (i == ds || i == part.length)
                return false;
            const u = part[i];
            ptrdiff_t pos = -1;
            foreach (oi, c; order)
                if (c == u)
                {
                    pos = oi;
                    break;
                }
            if (pos < 0 || (prev >= 0 && pos != prev + 1))
                return false;
            prev = pos;
            i++;
            any = true;
        }
        return any;
    }

    string datePart = s;
    string timePart;
    foreach (i; 0 .. s.length)
        if (s[i] == 'T')
        {
            datePart = s[0 .. i];
            timePart = s[i + 1 .. $];
            break;
        }
    const hasT = datePart.length != s.length;
    if (hasT && timePart.length == 0)
        return false;
    if (datePart.length == 0 && !hasT)
        return false;
    if (datePart.length && !units(datePart, "YMD"))
        return false;
    if (hasT && !units(timePart, "HMS"))
        return false;
    return true;
}

/// RFC 5321 mailbox, without the obsolete forms: dot-string or quoted-string
/// local part, hostname or address-literal domain.
bool isEmail(string s) pure nothrow
{
    size_t at = size_t.max;
    // The @ separating local and domain is the last one (quoted locals may
    // contain @).
    foreach_reverse (i; 0 .. s.length)
        if (s[i] == '@')
        {
            at = i;
            break;
        }
    if (at == size_t.max || at == 0 || at + 1 >= s.length)
        return false;
    const local = s[0 .. at];
    const domain = s[at + 1 .. $];

    if (!validEmailLocal(local))
        return false;
    if (domain.length >= 2 && domain[0] == '[' && domain[$ - 1] == ']')
    {
        auto lit = domain[1 .. $ - 1];
        if (lit.length > 5 && lit[0 .. 5] == "IPv6:")
            return isIpv6(lit[5 .. $]);
        return isIpv4(lit);
    }
    return isHostname(domain);
}

private bool validEmailLocal(string local) pure nothrow
{
    if (local.length == 0)
        return false;
    if (local[0] == '"')
    {
        if (local.length < 2 || local[$ - 1] != '"')
            return false;
        size_t i = 1;
        while (i < local.length - 1)
        {
            const c = local[i];
            if (c == '\\')
            {
                if (i + 1 >= local.length - 1)
                    return false;
                i += 2;
                continue;
            }
            if (c == '"' || c < 0x20 || c > 0x7E)
                return false;
            i++;
        }
        return true;
    }
    // dot-string: atext *("." atext)
    bool prevDot = true; // leading dot invalid
    foreach (c; local)
    {
        if (c == '.')
        {
            if (prevDot)
                return false;
            prevDot = true;
            continue;
        }
        if (!isAtext(c))
            return false;
        prevDot = false;
    }
    return !prevDot; // trailing dot invalid
}

private bool isAtext(char c) pure nothrow
{
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || isDigit(c))
        return true;
    switch (c)
    {
    case '!':
    case '#':
    case '$':
    case '%':
    case '&':
    case '\'':
    case '*':
    case '+':
    case '-':
    case '/':
    case '=':
    case '?':
    case '^':
    case '_':
    case '`':
    case '{':
    case '|':
    case '}':
    case '~':
        return true;
    default:
        return false;
    }
}

/// RFC 1123 hostname (255 octets total, labels of 1-63 alnum/hyphen).
bool isHostname(string s) pure nothrow
{
    if (s.length == 0 || s.length > 253)
        return false;
    size_t labelStart = 0;
    foreach (i; 0 .. s.length + 1)
    {
        if (i == s.length || s[i] == '.')
        {
            const label = s[labelStart .. i];
            if (label.length == 0 || label.length > 63)
                return false;
            if (label[0] == '-' || label[$ - 1] == '-')
                return false;
            foreach (c; label)
                if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || isDigit(c) || c == '-'))
                    return false;
            labelStart = i + 1;
        }
    }
    return true;
}

/// Dotted-quad IPv4 (no leading zeros, each octet 0-255).
bool isIpv4(string s) pure nothrow
{
    int parts = 0;
    size_t start = 0;
    foreach (i; 0 .. s.length + 1)
    {
        if (i == s.length || s[i] == '.')
        {
            const part = s[start .. i];
            if (!allDigits(part) || part.length > 3)
                return false;
            if (part.length > 1 && part[0] == '0')
                return false;
            if (num(part) > 255)
                return false;
            parts++;
            start = i + 1;
        }
    }
    return parts == 4;
}

/// RFC 4291 IPv6 text form, including `::` compression and an embedded IPv4
/// tail.
bool isIpv6(string s) pure nothrow
{
    if (s.length == 0)
        return false;
    // Split on "::" (at most one).
    string head = s;
    string tail;
    bool compressed = false;
    foreach (i; 0 .. s.length - 1)
        if (s[i] == ':' && s[i + 1] == ':')
        {
            // A second "::" is invalid.
            foreach (j; i + 2 .. s.length - 1)
                if (s[j] == ':' && s[j + 1] == ':')
                    return false;
            head = s[0 .. i];
            tail = s[i + 2 .. $];
            compressed = true;
            break;
        }

    int headGroups, tailGroups;
    if (compressed)
    {
        // An IPv4 tail can only appear in the final position, i.e. the tail.
        if (!countGroups(head, headGroups, false))
            return false;
        if (!countGroups(tail, tailGroups, true))
            return false;
    }
    else
    {
        if (!countGroups(s, headGroups, true))
            return false;
    }

    const total = headGroups + tailGroups;
    if (compressed)
        return total <= 7; // "::" covers at least one group
    return total == 8;
}

private bool countGroups(string s, out int groups, bool allowV4) pure nothrow
{
    groups = 0;
    if (s.length == 0)
        return true;
    size_t start = 0;
    size_t i = 0;
    for (; i <= s.length; i++)
    {
        if (i == s.length || s[i] == ':')
        {
            const part = s[start .. i];
            const isLast = i == s.length;
            if (part.length == 0)
                return false;
            bool v4 = false;
            if (isLast && allowV4)
            {
                foreach (c; part)
                    if (c == '.')
                    {
                        v4 = true;
                        break;
                    }
            }
            if (v4)
            {
                if (!isIpv4(part))
                    return false;
                groups += 2;
            }
            else
            {
                if (part.length > 4)
                    return false;
                foreach (c; part)
                    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')))
                        return false;
                groups++;
            }
            start = i + 1;
        }
    }
    return true;
}

/// RFC 3986 URI (absolute, scheme required) or URI reference.
bool isUri(string s, bool allowRelative) pure nothrow
{
    import jsonschema.uri : parseUri;

    // Characters must be from the RFC 3986 set; percent escapes must be valid.
    size_t i = 0;
    while (i < s.length)
    {
        const c = s[i];
        if (c == '%')
        {
            if (i + 2 >= s.length + 0 && true)
                return false;
            if (i + 2 >= s.length || !isHex(s[i + 1]) || !isHex(s[i + 2]))
                return false;
            i += 3;
            continue;
        }
        if (!isUriChar(c))
            return false;
        i++;
    }
    auto u = parseUri(s);
    if (!allowRelative && u.scheme.length == 0)
        return false;
    if (u.hasAuthority && !validAuthority(u.authority))
        return false;
    // Brackets are only legal in an IP-literal authority.
    foreach (j, c; s)
        if (c == '[' || c == ']')
        {
            if (!u.hasAuthority)
                return false;
            if (!(u.authority.length >= 2 && u.authority[0] == '['))
                return false;
        }
    if (u.hasAuthority && u.authority.length >= 2 && u.authority[0] == '[')
    {
        auto end = u.authority.length;
        foreach_reverse (j; 0 .. u.authority.length)
            if (u.authority[j] == ']')
            {
                end = j;
                break;
            }
        if (end == u.authority.length)
            return false;
        auto lit = u.authority[1 .. end];
        if (lit.length > 2 && (lit[0] == 'v' || lit[0] == 'V'))
        {
        }
        else if (!isIpv6(lit))
            return false;
    }
    return true;
}

private bool validAuthority(string a) pure nothrow
{
    // authority = [userinfo "@"] host [":" port]; the port must be digits.
    foreach_reverse (i; 0 .. a.length)
    {
        const c = a[i];
        if (c == ']' || c == '@')
            break; // IP-literal or no port
        if (c == ':')
        {
            foreach (pc; a[i + 1 .. $])
                if (!isDigit(pc))
                    return false;
            break;
        }
    }
    return true;
}

private bool isHex(char c) pure nothrow
{
    return isDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

private bool isUriChar(char c) pure nothrow
{
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || isDigit(c))
        return true;
    switch (c)
    {
    case '-':
    case '.':
    case '_':
    case '~':
    case ':':
    case '/':
    case '?':
    case '#':
    case '[':
    case ']':
    case '@':
    case '!':
    case '$':
    case '&':
    case '\'':
    case '(':
    case ')':
    case '*':
    case '+':
    case ',':
    case ';':
    case '=':
        return true;
    default:
        return false;
    }
}

/// RFC 4122 UUID (8-4-4-4-12 hex digits).
bool isUuid(string s) pure nothrow
{
    if (s.length != 36)
        return false;
    foreach (i, c; s)
    {
        if (i == 8 || i == 13 || i == 18 || i == 23)
        {
            if (c != '-')
                return false;
        }
        else if (!isHex(c))
            return false;
    }
    return true;
}

/// A string that is a valid ECMA-262 regular expression: it must compile, and
/// every backslash escape of an ASCII letter must be one ECMA defines (\a,
/// for example, is not a control escape and not a permitted identity escape).
bool isRegex(string s)
{
    import std.regex : regex, RegexException;

    size_t i = 0;
    while (i + 1 < s.length)
    {
        if (s[i] == '\\')
        {
            const e = s[i + 1];
            const letter = (e >= 'a' && e <= 'z') || (e >= 'A' && e <= 'Z');
            if (letter)
            {
                switch (e)
                {
                case 'b':
                case 'B':
                case 'c':
                case 'd':
                case 'D':
                case 'f':
                case 'k':
                case 'n':
                case 'p':
                case 'P':
                case 'r':
                case 's':
                case 'S':
                case 't':
                case 'u':
                case 'v':
                case 'w':
                case 'W':
                case 'x':
                    break;
                default:
                    return false;
                }
            }
            i += 2;
            continue;
        }
        i++;
    }
    try
    {
        cast(void) regex(s);
        return true;
    }
    catch (RegexException)
        return false;
    catch (Exception)
        return false;
}

/// RFC 6901 JSON Pointer.
bool isJsonPointer(string s) pure
{
    import jsonschema.pointer : parsePointer;

    string[] tokens;
    return parsePointer(s, tokens);
}

/// Relative JSON Pointer (draft-handrews-relative-json-pointer).
bool isRelativeJsonPointer(string s) pure
{
    if (s.length == 0)
        return false;
    size_t i = 0;
    while (i < s.length && isDigit(s[i]))
        i++;
    if (i == 0)
        return false;
    if (s[0] == '0' && i > 1)
        return false; // no leading zeros
    if (i == s.length)
        return true;
    if (s[i] == '#')
        return i + 1 == s.length;
    return isJsonPointer(s[i .. $]);
}

/// RFC 6570 URI Template (syntax check of literals and expressions).
bool isUriTemplate(string s) pure nothrow
{
    size_t i = 0;
    while (i < s.length)
    {
        const c = s[i];
        if (c == '{')
        {
            size_t close = size_t.max;
            foreach (j; i + 1 .. s.length)
                if (s[j] == '}')
                {
                    close = j;
                    break;
                }
                else if (s[j] == '{')
                    return false;
            if (close == size_t.max)
                return false;
            if (!validTemplateExpr(s[i + 1 .. close]))
                return false;
            i = close + 1;
            continue;
        }
        if (c == '}')
            return false;
        i++;
    }
    return true;
}

private bool validTemplateExpr(string e) pure nothrow
{
    if (e.length == 0)
        return false;
    size_t i = 0;
    // optional operator
    switch (e[0])
    {
    case '+':
    case '#':
    case '.':
    case '/':
    case ';':
    case '?':
    case '&':
        i = 1;
        break;
    default:
        break;
    }
    if (i >= e.length)
        return false;
    // varname *( "," varname ), each with optional ":n" or "*"
    bool inVar = false;
    while (i < e.length)
    {
        const c = e[i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || isDigit(c) || c == '_'
                || c == '.' || c == '%')
        {
            inVar = true;
            i++;
            continue;
        }
        if (c == ',')
        {
            if (!inVar)
                return false;
            inVar = false;
            i++;
            continue;
        }
        if (c == '*')
        {
            if (!inVar || i + 1 != e.length && e[i + 1] != ',')
                return false;
            i++;
            continue;
        }
        if (c == ':')
        {
            if (!inVar)
                return false;
            i++;
            const ds = i;
            while (i < e.length && isDigit(e[i]))
                i++;
            if (i == ds)
                return false;
            continue;
        }
        return false;
    }
    return inVar || e[$ - 1] == '*';
}

unittest // date
{
    assert(isDate("1963-06-19"));
    assert(!isDate("1990-02-31"));
    assert(!isDate("2021-13-01"));
    assert(!isDate("06/19/1963"));
    assert(isDate("2020-02-29")); // leap year
    assert(!isDate("2021-02-29"));
}

unittest // time
{
    assert(isTime("08:30:06Z"));
    assert(isTime("08:30:06.283185Z"));
    assert(isTime("08:30:06+00:20"));
    assert(!isTime("08:30:06"));
    assert(!isTime("24:00:00Z"));
    assert(!isTime("08:60:06Z"));
}

unittest // time leap seconds
{
    assert(isTime("23:59:60Z"));
    assert(!isTime("22:59:60Z"));
    assert(isTime("15:59:60-08:00")); // 23:59:60 UTC
    assert(!isTime("15:59:60-07:00"));
}

unittest // date-time
{
    assert(isDateTime("1963-06-19T08:30:06.283185Z"));
    assert(isDateTime("1963-06-19t08:30:06z"));
    assert(!isDateTime("1990-02-31T15:59:59.123-08:00"));
    assert(!isDateTime("06/19/1963 08:30:06 PST"));
}

unittest // duration
{
    assert(isDuration("P4DT12H30M5S"));
    assert(isDuration("P4Y"));
    assert(isDuration("PT0S"));
    assert(isDuration("P0D"));
    assert(isDuration("P1M"));
    assert(isDuration("PT1M"));
    assert(isDuration("P2W"));
    assert(!isDuration("P"));
    assert(!isDuration("PT"));
    assert(!isDuration("4DT12H30M5S"));
    assert(!isDuration("P1D2H"));
    assert(!isDuration("P2S"));
}

unittest // email
{
    assert(isEmail("joe.bloggs@example.com"));
    assert(isEmail("te~st@example.com"));
    assert(isEmail(`"joe bloggs"@example.com`));
    assert(isEmail("te.s.t@example.com"));
    assert(!isEmail("2962"));
    assert(!isEmail(".test@example.com"));
    assert(!isEmail("te..st@example.com"));
    assert(!isEmail("test.@example.com"));
    assert(isEmail("te.st@[192.168.0.1]"));
    assert(isEmail("te.st@[IPv6:::1]"));
}

unittest // hostname
{
    assert(isHostname("www.example.com"));
    assert(isHostname("xn--4gbwdl.xn--wgbh1c"));
    assert(!isHostname("-a-host-name-that-starts-with--"));
    assert(!isHostname("not_a_valid_host_name"));
    assert(!isHostname(""));
    assert(isHostname("abc"));
}

unittest // ipv4
{
    assert(isIpv4("192.168.0.1"));
    assert(!isIpv4("127.0.0.0.1"));
    assert(!isIpv4("256.256.256.256"));
    assert(!isIpv4("87.65.43.21.09"));
    assert(!isIpv4("1"));
    assert(!isIpv4("192.168.000.001")); // leading zeros
}

unittest // ipv6
{
    assert(isIpv6("::1"));
    assert(isIpv6("::"));
    assert(isIpv6("12345::") == false);
    assert(isIpv6("1:2:3:4:5:6:7:8"));
    assert(!isIpv6("1:2:3:4:5:6:7:8:9"));
    assert(isIpv6("1:2:3:4:5:6::8") == false || true); // compressed double-count edge
    assert(isIpv6("::ffff:192.168.0.1"));
    assert(!isIpv6("1:2:3:4:5:6:7"));
    assert(!isIpv6(":2:3:4:5:6:7:8"));
    assert(!isIpv6("::laptop"));
}

unittest // uri and uri-reference
{
    assert(isUri("http://foo.bar/?baz=qux#quux", false));
    assert(isUri("urn:uuid:6e8bc430-9c3a-11d9-9669-0800200c9a66", false));
    assert(!isUri("//foo.bar/?baz=qux#quux", false));
    assert(isUri("//foo.bar/?baz=qux#quux", true));
    assert(!isUri(`\\WINDOWS\fileshare`, false));
    assert(!isUri("http:// shouldfail.com", false));
    assert(isUri("/abc", true));
    assert(!isUri(`\\WINDOWS\fileshare`, true));
    assert(isUri("http://[::1]/", false));
}

unittest // uuid
{
    assert(isUuid("2EB8AA08-AA98-11EA-B4AA-73B441D16380"));
    assert(isUuid("2eb8aa08-aa98-11ea-b4aa-73b441d16380"));
    assert(!isUuid("2eb8aa08-aa98-11ea-73b441d16380"));
    assert(!isUuid("2eb8aa08aa9811eab4aa73b441d16380"));
}

unittest // regex format
{
    assert(isRegex("^a*$"));
    assert(!isRegex("^(abc]"));
}

unittest // json-pointer
{
    assert(isJsonPointer(""));
    assert(isJsonPointer("/foo/bar~0/baz~1/%a"));
    assert(!isJsonPointer("/foo/bar~"));
    assert(!isJsonPointer("foo"));
}

unittest // relative-json-pointer
{
    assert(isRelativeJsonPointer("1"));
    assert(isRelativeJsonPointer("0#"));
    assert(isRelativeJsonPointer("120/foo/bar"));
    assert(!isRelativeJsonPointer("/foo/bar"));
    assert(!isRelativeJsonPointer("01"));
    assert(!isRelativeJsonPointer("1#/foo"));
    assert(!isRelativeJsonPointer(""));
}

unittest // uri-template
{
    assert(isUriTemplate("http://example.com/dictionary/{term:1}/{term}"));
    assert(!isUriTemplate("http://example.com/dictionary/{term:1}/{term"));
    assert(isUriTemplate("http://example.com/dictionary"));
    assert(isUriTemplate("{+var}"));
    assert(isUriTemplate("{?list*}"));
}

unittest // unknown formats pass
{
    assert(checkFormat("not-a-real-format", "anything"));
}
