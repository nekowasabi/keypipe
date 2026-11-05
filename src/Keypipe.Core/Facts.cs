using System.Text.RegularExpressions;

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

    public static bool GlobMatch(string glob, string value)
    {
        var sb = new System.Text.StringBuilder("^");
        for (int i = 0; i < glob.Length; i++)
        {
            char c = glob[i];
            switch (c)
            {
                case '*': sb.Append(".*"); break;
                case '?': sb.Append('.'); break;
                case '[':
                    int j = glob.IndexOf(']', i + 1);
                    if (j < 0) { sb.Append("\\["); break; }
                    sb.Append(glob.Substring(i, j - i + 1));
                    i = j;
                    break;
                case '\\' or '.' or '(' or ')' or '+' or '|' or '^' or '$' or '{' or '}' or '-':
                    sb.Append('\\').Append(c); break;
                default: sb.Append(c); break;
            }
        }
        sb.Append('$');
        return Regex.IsMatch(value, sb.ToString());
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
