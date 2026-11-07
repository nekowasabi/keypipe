using Keypipe.Core;

namespace Keypipe.Core.Tests;

public sealed class TriggerMatcherTests
{
    // V11: one keystroke returns the longest configured suffix; the firing keystroke clears.
    [Fact]
    public void LongestMatchWins_AndBufferResetsOnFire()
    {
        foreach (var triggers in new[] { new[] { "ab", "aab" }, new[] { "aab", "ab" } })
        {
            var matcher = new TriggerMatcher(triggers);
            string? hit = null;
            foreach (var c in "aab") hit = matcher.Feed(c);
            Assert.Equal("aab", hit);
        }

        var single = new TriggerMatcher(new[] { "@@@" });
        Assert.Null(single.Feed('@'));
        Assert.Null(single.Feed('@'));
        Assert.Equal("@@@", single.Feed('@'));
        single.Reset();
        Assert.Equal("", single.Buffer);
        Assert.Null(single.Feed('@'));
        Assert.Null(single.Feed('@'));
        Assert.Equal("@@@", single.Feed('@'));

        // With @@ and @@@ both configured, the 2nd char fires @@ and clears, so @@@ never builds.
        var lines = new List<string>();
        var desktop = new FakeDesktop(focus: Focus.Text, fieldText: "");
        var engine = new Engine(
            new KeypipeConfig(new[]
            {
                new Rule(new Trigger.Text("@@"), new When(), null,
                    new Guarded<Output>(new Output.Builtin(BuiltinSink.Notify))),
                new Rule(new Trigger.Text("@@@"), new When(), null,
                    new Guarded<Output>(new Output.Builtin(BuiltinSink.Notify))),
            }),
            desktop, (s, i, e, t) => new ShellOutcome.Exited(0, ""), lines.Add);
        foreach (var c in "@@@")
        {
            desktop.Key(c);
            engine.Key(c);
        }
        Assert.Equal(1, engine.Hits);
        Assert.Contains("keypipe matched @@ rule 0", lines);
        Assert.DoesNotContain(lines, l => l.Contains("rule 1"));
    }

    // V14: a trailing separator leaves an empty key, which Swift rejects
    // ("empty hotkey key"); the port must not silently drop it and accept
    // the previous key.
    [Fact]
    public void HotkeyParseRejectsATrailingPlus()
    {
        var ex = Assert.Throws<ConfigException>(() => Hotkey.Parse("ctrl+a+"));
        Assert.Equal("keypipe: invalid config: empty hotkey key", ex.Message);
    }

    // V14: "ctrl+" alone ends in the same empty key, not in the key "ctrl".
    [Fact]
    public void HotkeyParseRejectsABareTrailingSeparator()
    {
        var ex = Assert.Throws<ConfigException>(() => Hotkey.Parse("ctrl+"));
        Assert.Equal("keypipe: invalid config: empty hotkey key", ex.Message);
    }

    // V14: "+" itself stays a valid key: "ctrl++" is ctrl plus the "+" key.
    [Fact]
    public void HotkeyParseKeepsThePlusKey()
    {
        var hotkey = Hotkey.Parse("ctrl++");
        Assert.Equal("+", hotkey.Key);
        Assert.Equal("ctrl++", hotkey.ToString());
    }
}
