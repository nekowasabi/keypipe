namespace Keypipe.Core;

public enum BuiltinSink { None, ReplaceInput, Notify, TypeText }

public static class BuiltinSinks
{
    public static string Name(BuiltinSink sink) => sink switch
    {
        BuiltinSink.None => "none",
        BuiltinSink.ReplaceInput => "replaceInput",
        BuiltinSink.Notify => "notify",
        BuiltinSink.TypeText => "typeText",
        _ => throw new ArgumentOutOfRangeException(nameof(sink)),
    };

    public static BuiltinSink Parse(string name) => name switch
    {
        "none" => BuiltinSink.None,
        "replaceInput" => BuiltinSink.ReplaceInput,
        "notify" => BuiltinSink.Notify,
        "typeText" => BuiltinSink.TypeText,
        _ => throw new ConfigException($"unknown output {name}"),
    };

    public static IEnumerable<BuiltinSink> AllCases()
    {
        yield return BuiltinSink.None;
        yield return BuiltinSink.ReplaceInput;
        yield return BuiltinSink.Notify;
        yield return BuiltinSink.TypeText;
    }
}

public sealed record SinkSpec(
    IReadOnlySet<string> Failures,
    bool NeedsTextField = false,
    bool WritesField = false,
    bool Detachable = true)
{
    public bool CanFail => Failures.Count > 0;
}

public static class SinkSpecs
{
    public static SinkSpec Spec(BuiltinSink sink) => sink switch
    {
        BuiltinSink.None => new SinkSpec(new HashSet<string>()),
        BuiltinSink.Notify => new SinkSpec(new HashSet<string>()),
        BuiltinSink.ReplaceInput => new SinkSpec(
            new HashSet<string> { "ignored", "gone" },
            NeedsTextField: true, WritesField: true, Detachable: false),
        BuiltinSink.TypeText => new SinkSpec(
            new HashSet<string> { "gone", "unsupported" }, Detachable: false),
        _ => throw new ArgumentOutOfRangeException(nameof(sink)),
    };
}

public abstract record Output
{
    public sealed record Builtin(BuiltinSink Sink) : Output;
    public sealed record Shell(ShellOutput Value) : Output;

    public bool IsBackground => this is Shell s && s.Value.Background;

    public string Name => this switch
    {
        Builtin b => BuiltinSinks.Name(b.Sink),
        Shell => "output.shell",
        _ => throw new InvalidOperationException(),
    };

    public bool CanFail => this switch
    {
        Builtin b => SinkSpecs.Spec(b.Sink).CanFail,
        Shell => true,
        _ => throw new InvalidOperationException(),
    };

    public bool NeedsTextField => this is Builtin b && SinkSpecs.Spec(b.Sink).NeedsTextField;

    public bool WritesField => this is Builtin b && SinkSpecs.Spec(b.Sink).WritesField;

    public bool Detachable => this is not Builtin b || SinkSpecs.Spec(b.Sink).Detachable;
}

public sealed record ShellOutput(string Script, bool Background = false);

public static class SinkRunner
{
    public static string? Perform(BuiltinSink sink, string text, Snapshot? origin, IDesktop desktop)
    {
        var field = origin?.Field;
        switch (sink)
        {
            case BuiltinSink.None: return null;
            case BuiltinSink.Notify:
                desktop.Notify(text);
                return null;
            case BuiltinSink.ReplaceInput:
            {
                var outcome = field is not null
                    ? Engine.PerformWrite(field, text, desktop)
                    : WriteOutcome.Gone;
                return outcome switch
                {
                    WriteOutcome.Written => null,
                    WriteOutcome.Ignored => "ignored",
                    _ => "gone",
                };
            }
            case BuiltinSink.TypeText:
                if (origin is null || !StillAt(origin, desktop)) return "gone";
                return desktop.TypeText(text) ? null : "unsupported";
            default: throw new ArgumentOutOfRangeException(nameof(sink));
        }
    }

    private static bool StillAt(Snapshot origin, IDesktop desktop)
    {
        var now = desktop.Snapshot();
        if (now.App != origin.App || now.Focus != origin.Focus || now.Secure) return false;
        return (origin.Field, now.Field) switch
        {
            (null, null) => true,
            (not null, not null) => desktop.SameField(origin.Field!, now.Field!),
            _ => false,
        };
    }
}
