namespace Keypipe.Core;

public enum Focus { Nothing, Text, Composing, Terminal }

public sealed record Field(int Token);

public sealed record Snapshot(string? App, Focus Focus, Field? Field = null, bool Secure = false);

public static class Context
{
    public static Conditions.Verdict Evaluate(When when, FactSheet sheet)
    {
        if (sheet.Snapshot.Focus == Focus.Composing || sheet.Snapshot.Focus == Focus.Terminal)
            return new Conditions.Verdict.NoMatch();
        if (when.Focus != WhenFocus.TextField && when.Focus != WhenFocus.Any)
            return new Conditions.Verdict.NoMatch();
        if (when.Focus == WhenFocus.TextField && sheet.Snapshot.Focus != Focus.Text)
            return new Conditions.Verdict.NoMatch();
        return when.Conditions.Evaluate(sheet);
    }
}
