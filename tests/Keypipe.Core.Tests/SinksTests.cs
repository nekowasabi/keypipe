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
}
