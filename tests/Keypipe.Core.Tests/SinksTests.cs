using Keypipe.Core;

namespace Keypipe.Core.Tests;

public sealed class SinksTests
{
    // V10b: typeText on the supplied path is unsupported, never a success.
    [Fact]
    public void TypeTextOnSuppliedPathIsUnsupported()
    {
        var line = new LineDesktop("editor", "hello@@@");
        var engine = new Engine(
            new KeypipeConfig(new[]
            {
                new Rule(new Trigger.Text("@@@"), new When(WhenFocus.TextField), null,
                    new Guarded<Output>(new Output.Builtin(BuiltinSink.TypeText))),
            }),
            line, (s, i, e, t) => new ShellOutcome.Exited(0, i), _ => { });
        Assert.Equal(new FireResult.Failed(0, "output", "unsupported"), engine.Fire(new Trigger.Text("@@@")));
        Assert.Equal("hello", line.Line);

        var fallbackSaved = new Dictionary<string, string>();
        var engine2 = new Engine(
            new KeypipeConfig(new[]
            {
                new Rule(new Trigger.Text("@@@"), new When(WhenFocus.TextField), null,
                    new Guarded<Output>(
                        new Output.Builtin(BuiltinSink.TypeText),
                        new Output.Shell(new ShellOutput("save")))),
            }),
            new LineDesktop("editor", "hi@@@"),
            (s, i, e, t) =>
            {
                fallbackSaved[s] = $"{i}|{e["KEYPIPE_FAILURE"]}";
                return new ShellOutcome.Exited(0, "");
            },
            _ => { });
        Assert.Equal(new FireResult.Delivered(0, true), engine2.Fire(new Trigger.Text("@@@")));
        Assert.Equal("hi|unsupported", fallbackSaved["save"]);
    }

    // Config parity: every sink's validity derives from its spec.
    [Fact]
    public void ValidityIsDerivedFromEverySinkSpec()
    {
        foreach (var sink in BuiltinSinks.AllCases())
        {
            var name = BuiltinSinks.Name(sink);
            var anyFocus = $"{{\"rules\":[{{\"trigger\":\"@@@\",\"output\":\"{name}\"}}]}}";
            if (SinkSpecs.Spec(sink).NeedsTextField)
            {
                var ex = Assert.Throws<ConfigException>(() => ConfigLoader.Load(anyFocus));
                Assert.Equal($"keypipe: invalid config: output {name} requires focus textField", ex.Message);
            }
            else
            {
                ConfigLoader.Load(anyFocus);
            }
            var withFallback =
                $"{{\"rules\":[{{\"trigger\":\"@@@\",\"when\":{{\"focus\":\"textField\"}},\"output\":\"{name}\",\"onFail\":{{\"output\":\"notify\"}}}}]}}";
            if (SinkSpecs.Spec(sink).CanFail)
            {
                ConfigLoader.Load(withFallback);
            }
            else
            {
                var ex = Assert.Throws<ConfigException>(() => ConfigLoader.Load(withFallback));
                Assert.Equal(
                    "keypipe: invalid config: onFail.output requires an output that can fail",
                    ex.Message);
            }
            var asBackgroundFallback =
                $"{{\"rules\":[{{\"trigger\":\"@@@\",\"when\":{{\"focus\":\"textField\"}},\"output\":{{\"shell\":\"x\",\"background\":true}},\"onFail\":{{\"output\":\"{name}\"}}}}]}}";
            if (SinkSpecs.Spec(sink).Detachable)
            {
                ConfigLoader.Load(asBackgroundFallback);
            }
            else
            {
                var ex = Assert.Throws<ConfigException>(() => ConfigLoader.Load(asBackgroundFallback));
                Assert.Equal(
                    $"keypipe: invalid config: a background output cannot fall back to {name}",
                    ex.Message);
            }
        }
    }

    // Report v1 parity: every FireResult kind renders its golden line.
    [Fact]
    public void EveryOutcomeRendersGoldenReportJson()
    {
        var golden = new (FireResult result, bool hit)[]
        {
            (new FireResult.Blocked("terminal"), false),
            (FireResult.NoMatch.Instance, false),
            (new FireResult.Unreadable("url", "timeout"), false),
            (new FireResult.NoInput(0), true),
            (new FireResult.Replaced(1, "お世話になっております。\n\"引用\" $(x) `y`", false), true),
            (new FireResult.Replaced(0, "HELLO", true), true),
            (new FireResult.Delivered(2, false), true),
            (new FireResult.Delivered(0, true), true),
            (new FireResult.Started(3), true),
            (new FireResult.Failed(0, "transform", "exit 1"), true),
            (new FireResult.Failed(0, "output", "unsupported"), true),
            (new FireResult.Failed(4, "spawn", "spawn"), true),
        };
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "report-v1.jsonl");
        var lines = File.ReadAllLines(path);
        Assert.Equal(golden.Length, lines.Length);
        for (int i = 0; i < golden.Length; i++)
        {
            Assert.Equal(golden[i].result.ToReportJson(), lines[i]);
            Assert.Equal(golden[i].hit, golden[i].result.IsHit);
        }
        Assert.Equal(
            Enum.GetValues<FireResult.Kind>().ToHashSet(),
            golden.Select(g => g.result.GetKind()).ToHashSet());
    }

    // V15: the 64-character trigger limit counts characters (Swift
    // String.count), not UTF-16 units, or a valid emoji trigger is rejected
    // at load for a length it does not have.
    [Fact]
    public void TriggerLengthLimitCountsCharactersNotUtf16Units()
    {
        var emoji = string.Concat(Enumerable.Repeat("😀", 40));
        ConfigLoader.Load($"{{\"rules\":[{{\"trigger\":\"{emoji}\"}}]}}");
        var tooLong = string.Concat(Enumerable.Repeat("😀", 65));
        var ex = Assert.Throws<ConfigException>(
            () => ConfigLoader.Load($"{{\"rules\":[{{\"trigger\":\"{tooLong}\"}}]}}"));
        Assert.Equal(
            $"keypipe: invalid config: rule trigger exceeds {TriggerMatcher.MaxBuffer} characters and can never match",
            ex.Message);
    }

    // V17: ConfigLoader.Load wraps malformed JSON in the same
    // ConfigException as LoadFile (Swift: "JSON decoding failed: ..."),
    // instead of leaking a raw JsonException to direct callers.
    [Fact]
    public void LoadFailureIsWrappedLikeLoadFile()
    {
        var ex = Assert.Throws<ConfigException>(() => ConfigLoader.Load("{ not json"));
        Assert.StartsWith("keypipe: invalid config: JSON decoding failed: ", ex.Message);
        var path = Path.GetTempFileName();
        try
        {
            File.WriteAllText(path, "{ not json");
            var ex2 = Assert.Throws<ConfigException>(() => ConfigLoader.LoadFile(path));
            Assert.StartsWith("keypipe: invalid config: JSON decoding failed: ", ex2.Message);
        }
        finally { File.Delete(path); }
    }

    // V18: a write that lands on a later read (writePerRead, Chromium-style)
    // still counts as written: performWrite polls the readback.
    [Fact]
    public void ReplaceInputLandsOnLaterReadWithWritePerRead()
    {
        var desktop = new FakeDesktop(focus: Focus.Text, fieldText: "hello@@@", writePerRead: true);
        var engine = new Engine(new KeypipeConfig(new[]
        {
            new Rule(new Trigger.Text("@@@"), new When(WhenFocus.TextField), null,
                new Guarded<Output>(new Output.Builtin(BuiltinSink.ReplaceInput))),
        }), desktop, (s, i, e, t) => new ShellOutcome.Exited(0, i), _ => { });
        Assert.Equal(new FireResult.Replaced(0, "hello", false),
            engine.Fire(new Trigger.Text("@@@")));
        Assert.Equal("hello", desktop.FieldText);
    }

    // V18: a write the app accepts but never applies (ignoresWrite) is the
    // "ignored" output failure after the readback deadline, not a delivery.
    [Fact]
    public void ReplaceInputIgnoredWriteIsAnOutputFailure()
    {
        var desktop = new FakeDesktop(focus: Focus.Text, fieldText: "hello@@@", ignoresWrite: true);
        var engine = new Engine(new KeypipeConfig(new[]
        {
            new Rule(new Trigger.Text("@@@"), new When(WhenFocus.TextField),
                new Guarded<string>("tr"),
                new Guarded<Output>(new Output.Builtin(BuiltinSink.ReplaceInput))),
        }), desktop, (s, i, e, t) => new ShellOutcome.Exited(0, "HELLO"), _ => { });
        Assert.Equal(new FireResult.Failed(0, "output", "ignored"),
            engine.Fire(new Trigger.Text("@@@")));
        Assert.Equal("hello", desktop.FieldText);
        Assert.Equal(new[] { "HELLO" }, desktop.Notifications);
    }
}
