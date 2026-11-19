namespace Keypipe.Core;

public enum FactName { App, Url }

public static class FactNames
{
    public static string Key(FactName name) => name switch { FactName.App => "app", _ => "url" };

    public static FactName Parse(string key) => key switch
    {
        "app" => FactName.App,
        "url" => FactName.Url,
        _ => throw new ConfigException($"unknown fact {key}"),
    };

    public static FactCost Cost(FactName name) => name == FactName.App ? FactCost.Structural : FactCost.Slow;
}

public enum FactCost { Structural, Cheap, Slow }

public abstract record FactRead
{
    public sealed record Value(string Text) : FactRead;
    public sealed record Absent : FactRead
    {
        public static readonly Absent Instance = new();
    }
    public sealed record Unreadable(string Reason) : FactRead;
}

public sealed record Term(FactName Fact, IReadOnlyList<string> Globs)
{
    public bool Matches(string value) => Globs.Any(g => GlobMatch(g, value));

    // fnmatch(3) with flags 0, as Swift's Term.matches: "*" crosses "/",
    // "?" takes one character, "[...]" is a class where only "!" negates,
    // and "\" escapes the next character. A class with an invalid range
    // (lo > hi) matches nothing for that range instead of throwing, and an
    // unterminated "[" is a literal "[". Matching is per UTF-16 code unit,
    // as in the rest of the port; bundle ids and URLs are ASCII in practice.
    public static bool GlobMatch(string glob, string value) => Match(glob, 0, value, 0);

    private static bool Match(string glob, int gi, string value, int vi)
    {
        while (gi < glob.Length)
        {
            switch (glob[gi])
            {
                case '*':
                    while (gi < glob.Length && glob[gi] == '*') gi++;
                    if (gi == glob.Length) return true;
                    for (int k = vi; k <= value.Length; k++)
                        if (Match(glob, gi, value, k)) return true;
                    return false;
                case '?':
                    if (vi >= value.Length) return false;
                    gi++; vi++;
                    break;
                case '[':
                    if (vi >= value.Length) return false;
                    if (!MatchClass(glob, ref gi, value[vi])) return false;
                    vi++;
                    break;
                case '\\':
                    gi++;
                    if (gi >= glob.Length)
                    {
                        if (vi >= value.Length || value[vi] != '\\') return false;
                        vi++;
                        break;
                    }
                    if (vi >= value.Length || value[vi] != glob[gi]) return false;
                    gi++; vi++;
                    break;
                default:
                    if (vi >= value.Length || value[vi] != glob[gi]) return false;
                    gi++; vi++;
                    break;
            }
        }
        return vi == value.Length;
    }

    private static bool MatchClass(string glob, ref int gi, char ch)
    {
        // glob[gi] == '['. Advances gi past the closing ']' on a real class.
        int i = gi + 1;
        bool negate = false;
        if (i < glob.Length && glob[i] == '!') { negate = true; i++; }
        int start = i;
        if (start < glob.Length && glob[start] == ']') start++;
        int end = start;
        while (end < glob.Length && glob[end] != ']') end++;
        if (end >= glob.Length)
        {
            gi += 1;
            return ch == '[';
        }
        bool matched = false;
        int p = i;
        while (p < end)
        {
            char lo;
            if (glob[p] == '\\' && p + 1 < end) { lo = glob[p + 1]; p += 2; }
            else { lo = glob[p]; p += 1; }
            if (p < end && glob[p] == '-' && p + 1 < end)
            {
                char hi;
                if (glob[p + 1] == '\\' && p + 2 < end) { hi = glob[p + 2]; p += 3; }
                else { hi = glob[p + 1]; p += 2; }
                if (lo <= hi && ch >= lo && ch <= hi) matched = true;
            }
            else if (ch == lo) matched = true;
        }
        gi = end + 1;
        return matched != negate;
    }
}

public sealed class Conditions : IEquatable<Conditions>
{
    private readonly List<Term> _terms;
    public IReadOnlyList<Term> Terms => _terms;

    public Conditions(IEnumerable<Term>? terms = null)
    {
        _terms = (terms ?? Enumerable.Empty<Term>())
            .Select((t, i) => (t, i))
            .OrderBy(p => ((int)FactNames.Cost(p.t.Fact), p.i))
            .Select(p => p.t)
            .ToList();
    }

    public abstract record Verdict
    {
        public sealed record Match : Verdict
        {
            public static readonly Match Instance = new();
        }
        public sealed record NoMatch : Verdict
        {
            public static readonly NoMatch Instance = new();
        }
        public sealed record Unreadable(FactName Fact, string Reason) : Verdict;
    }

    public Verdict Evaluate(FactSheet sheet)
    {
        foreach (var term in _terms)
        {
            var read = sheet[term.Fact];
            switch (read)
            {
                case FactRead.Value v:
                    if (!term.Matches(v.Text)) return Verdict.NoMatch.Instance;
                    break;
                case FactRead.Absent:
                    return Verdict.NoMatch.Instance;
                case FactRead.Unreadable u:
                    return new Verdict.Unreadable(term.Fact, u.Reason);
            }
        }
        return Verdict.Match.Instance;
    }

    public bool HasApp => _terms.Any(t => t.Fact == FactName.App);

    public bool Equals(Conditions? other)
        => other is not null && _terms.SequenceEqual(other._terms);

    public override bool Equals(object? obj) => obj is Conditions c && Equals(c);

    public override int GetHashCode()
    {
        var h = new HashCode();
        foreach (var t in _terms) { h.Add(t.Fact); foreach (var g in t.Globs) h.Add(g); }
        return h.ToHashCode();
    }
}

public sealed class FactSheet
{
    private readonly IDesktop? _desktop;
    private readonly Dictionary<FactName, FactRead> _memo = new();
    public Snapshot Snapshot { get; }
    public bool ReadSlow { get; private set; }

    public FactSheet(Snapshot snapshot, IDesktop? desktop)
    {
        Snapshot = snapshot;
        _desktop = desktop;
    }

    public FactRead this[FactName fact]
    {
        get
        {
            if (fact == FactName.App)
                return Snapshot.App is string app ? new FactRead.Value(app) : FactRead.Absent.Instance;
            if (_memo.TryGetValue(fact, out var known)) return known;
            var read = _desktop?.GetFact(fact) ?? FactRead.Absent.Instance;
            if (FactNames.Cost(fact) == FactCost.Slow) ReadSlow = true;
            _memo[fact] = read;
            return read;
        }
    }
}
