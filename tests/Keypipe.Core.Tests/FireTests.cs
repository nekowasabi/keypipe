using Keypipe.Core;

namespace Keypipe.Core.Tests;

public sealed class FireTests
{
    private static ShellOutcome Echo(string script, string input,
        IReadOnlyDictionary<string, string> env, TimeSpan timeout)
        => new ShellOutcome.Exited(0, input);

    private static (int hits, List<string> lines) Run(
        string keys, IReadOnlyList<Rule> rules, FakeDesktop desktop,
        Func<string, string, IReadOnlyDictionary<string, string>, TimeSpan, ShellOutcome>? shell = null)
    {
        var lines = new List<string>();
        var engine = new Engine(new KeypipeConfig(rules), desktop, shell ?? Echo, lines.Add);
        foreach (var c in keys)
        {
            desktop.Key(c);
            engine.Key(c);
        }
        return (engine.Hits, lines);
    }

    private static Rule TextRule(string trigger, When? when = null,
        Guarded<string>? transform = null, Guarded<Output>? output = null, string? name = null)
        => new(new Trigger.Text(trigger), when ?? new When(),
            transform, output ?? new Guarded<Output>(new Output.Builtin(BuiltinSink.None)), name);

    // V1: composing stops before deny, before erase, and before any shell.
    [Fact]
    public void ComposingDoesNotFireOrErase()
    {
        var desktop = new FakeDesktop(focus: Focus.Composing, fieldText: "hello");
        bool shelled = false;
        var (hits, lines) = Run("@@@", new[] { TextRule("@@@") }, desktop,
            (s, i, e, t) => { shelled = true; return new ShellOutcome.Exited(0, ""); });
        Assert.Equal(0, hits);
        Assert.False(shelled);
        Assert.Equal(new[] { "keypipe composing @@@" }, lines);
        Assert.Equal("hello@@@", desktop.FieldText);
    }

    // V2: a password field stops the same way.
    [Fact]
    public void SecureFieldStopsBeforeDenyEraseAndShell()
    {
        var desktop = new FakeDesktop(focus: Focus.Text, fieldText: "secret", secure: true);
        bool shelled = false;
        var lines = new List<string>();
        var config = new KeypipeConfig(
            new[] { TextRule("@@@") },
            new[] { new Conditions(new[] { new Term(FactName.App, new[] { "bank" }) }) });
        var engine = new Engine(config, desktop,
            (s, i, e, t) => { shelled = true; return new ShellOutcome.Exited(0, ""); }, lines.Add);
        foreach (var c in "@@@") { desktop.Key(c); engine.Key(c); }
        Assert.Equal(new FireResult.Blocked("secure"), engine.Fire(new Trigger.Text("@@@")));
        Assert.False(shelled);
        Assert.DoesNotContain(lines, l => l.StartsWith("keypipe erase "));
        Assert.Equal("secret@@@", desktop.FieldText);
    }

    // V3: a typed trigger in a terminal does nothing; a hotkey that reads no field passes.
    [Fact]
    public void TerminalTextTriggerStops_TerminalHotkeyWithoutFieldPasses()
    {
        var desktop = new FakeDesktop(app: "someterm", focus: Focus.Terminal, fieldText: "secret-token-123");
        bool shelled = false;
        var (hits, lines) = Run("@@@",
            new[]
            {
                TextRule("@@@", new When(WhenFocus.TextField),
                    output: new Guarded<Output>(new Output.Shell(new ShellOutput("send")))),
                TextRule("@@@", output: new Guarded<Output>(new Output.Builtin(BuiltinSink.Notify))),
            },
            desktop, (s, i, e, t) => { shelled = true; return new ShellOutcome.Exited(0, ""); });
        Assert.Equal(0, hits);
        Assert.False(shelled);
        Assert.Equal(new[] { "keypipe terminal @@@" }, lines);
        Assert.Equal("secret-token-123@@@", desktop.FieldText);
        Assert.Empty(desktop.Notifications);

        var hotkey = Hotkey.Parse("ctrl+@");
        var term2 = new FakeDesktop(app: "term", focus: Focus.Terminal);
        var ran = new List<string>();
        var lines2 = new List<string>();
        var engine = new Engine(
            new KeypipeConfig(new[]
            {
                new Rule(new Trigger.HotkeyTrigger(hotkey), new When(WhenFocus.TextField),
                    null, new Guarded<Output>(new Output.Shell(new ShellOutput("no")))),
                new Rule(new Trigger.HotkeyTrigger(hotkey), new When(),
                    null, new Guarded<Output>(new Output.Shell(new ShellOutput("yes")))),
            }),
            term2, (s, i, e, t) => { ran.Add(s); Assert.Equal("", i); return new ShellOutcome.Exited(0, ""); },
            lines2.Add);
        Assert.Equal(new FireResult.Delivered(1, false),
            engine.Fire(new Trigger.HotkeyTrigger(hotkey)));
        Assert.Equal(new[] { "yes" }, ran);
    }

    // V4: an unreadable fact stops the fire and never falls through to the next rule.
    [Fact]
    public void UnreadableFactStopsWithoutFallingThrough()
    {
        var desktop = new FakeDesktop(app: "com.google.Chrome", focus: Focus.Text, fieldText: "hi",
            facts: new Dictionary<FactName, FactRead>
            {
                [FactName.Url] = new FactRead.Unreadable("timeout"),
            });
        foreach (var c in "@@@") desktop.Key(c);
        var lines = new List<string>();
        var engine = new Engine(
            new KeypipeConfig(new[]
            {
                TextRule("@@@", new When(WhenFocus.TextField,
                    new Conditions(new[] { new Term(FactName.Url, new[] { "*github.com*" }) })),
                    output: new Guarded<Output>(new Output.Shell(new ShellOutput("github")))),
                TextRule("@@@", new When(WhenFocus.TextField),
                    output: new Guarded<Output>(new Output.Shell(new ShellOutput("catchall")))),
            }),
            desktop, (s, i, e, t) => { Assert.Fail("nothing runs"); return new ShellOutcome.Exited(0, ""); },
            lines.Add);
        Assert.Equal(new FireResult.Unreadable("url", "timeout"), engine.Fire(new Trigger.Text("@@@")));
        Assert.Equal("hi@@@", desktop.FieldText);
        Assert.Equal(new[] { "@@@: cannot read url: timeout" }, desktop.Notifications);
        Assert.Equal(0, engine.Hits);
        Assert.Contains("keypipe unreadable @@@ url", lines);
    }

    // V5: the front changed during a slow read erases and runs nothing.
    [Fact]
    public void FrontChangeDuringSlowReadErasesNothing()
    {
        var desktop = new FakeDesktop(app: "com.google.Chrome", focus: Focus.Text, fieldText: "x",
            facts: new Dictionary<FactName, FactRead>
            {
                [FactName.Url] = new FactRead.Value("https://github.com/"),
            },
            appAfterSlowRead: "com.apple.TextEdit");
        foreach (var c in "@@@") desktop.Key(c);
        var lines = new List<string>();
        var engine = new Engine(
            new KeypipeConfig(new[]
            {
                TextRule("@@@", new When(WhenFocus.TextField,
                    new Conditions(new[] { new Term(FactName.Url, new[] { "*" }) })),
                    output: new Guarded<Output>(new Output.Shell(new ShellOutput("x")))),
            }),
            desktop, (s, i, e, t) => { Assert.Fail("nothing runs"); return new ShellOutcome.Exited(0, ""); },
            lines.Add);
        Assert.Equal(new FireResult.Blocked("front-changed"), engine.Fire(new Trigger.Text("@@@")));
        Assert.Equal("x@@@", desktop.FieldText);
        Assert.Contains("keypipe front-changed @@@", lines);
    }

    // V6: this trigger's when failing never selects a shorter trigger.
    [Fact]
    public void NoMatchDoesNotEraseOrTryShorterTrigger()
    {
        var desktop = new FakeDesktop(focus: Focus.Nothing);
        var rules = new[]
        {
            TextRule("aab", new When(WhenFocus.TextField)),
            TextRule("ab"),
        };
        var (hits, lines) = Run("aab", rules, desktop);
        Assert.Equal(0, hits);
        Assert.Equal(new[] { "keypipe nomatch aab" }, lines);
        Assert.Equal("aab", desktop.FieldText);
    }

    // V7a: hotkey posts no Backspace; textField sees the field; unconfigured chords are ignored.
    [Fact]
    public void HotkeyReadsFieldWithoutErasing_AndIgnoresUnconfiguredChords()
    {
        var ctrlAt = Hotkey.Parse("ctrl+@");
        var desktop = new FakeDesktop(focus: Focus.Text, fieldText: "hello");
        var lines = new List<string>();
        var engine = new Engine(
            new KeypipeConfig(new[]
            {
                new Rule(new Trigger.HotkeyTrigger(ctrlAt), new When(WhenFocus.TextField),
                    new Guarded<string>("tr"),
                    new Guarded<Output>(new Output.Builtin(BuiltinSink.ReplaceInput))),
                TextRule("@@@"),
            }),
            desktop,
            (s, i, e, t) => { Assert.Equal("hello", i); return new ShellOutcome.Exited(0, "HELLO"); },
            lines.Add);
        engine.Hotkey(Hotkey.Parse("cmd+c"));
        Assert.Empty(lines);
        engine.Key('@');
        engine.Key('@');
        engine.Hotkey(ctrlAt);
        Assert.Equal(1, engine.Hits);
        Assert.Contains("keypipe matched ctrl+@ rule 0", lines);
        Assert.Contains("keypipe erase 0", lines);
        Assert.Equal("HELLO", desktop.FieldText);
        engine.Key('@');
        Assert.Equal(1, engine.Hits);
    }

    // V7b: focus any on the keyboard path feeds empty input; erases only in a text field.
    [Fact]
    public void AnySuppliesEmptyInputAndErasesOnlyInTextFields()
    {
        foreach (var (focus, late) in new[] { (Focus.Text, false), (Focus.Text, true), (Focus.Nothing, false) })
        {
            var desktop = new FakeDesktop(app: "editor", focus: focus, fieldText: "hello", keysPerRead: late);
            bool called = false;
            var (hits, lines) = Run("@@@",
                new[] { TextRule("@@@", output: new Guarded<Output>(new Output.Shell(new ShellOutput("send")))) },
                desktop,
                (s, i, e, t) =>
                {
                    called = true;
                    Assert.Equal("send", s);
                    Assert.Equal("", i);
                    Assert.Equal("editor", e["KEYPIPE_APP"]);
                    return new ShellOutcome.Exited(0, "");
                });
            Assert.True(called);
            Assert.Contains($"keypipe erase {(focus == Focus.Text ? 3 : 0)}", lines);
            Assert.Equal(focus == Focus.Text ? "hello" : "hello@@@", desktop.FieldText);
        }
    }

    // V8: --line/--rule (supplied path) pass stdin through for either focus.
    [Fact]
    public void FireRuleRunsOnlyThatRuleWithCallersInputInEveryFocus()
    {
        foreach (var trigger in new Trigger[]
                 {
                     new Trigger.Text("@@@"),
                     new Trigger.HotkeyTrigger(Hotkey.Parse("ctrl+cmd+g")),
                 })
        {
            foreach (var focus in new[] { WhenFocus.Any, WhenFocus.TextField })
            {
                string suffix = trigger is Trigger.Text t ? t.Value : "";
                var desktop = new LineDesktop("editor", "note" + suffix);
                var rules = new[]
                {
                    new Rule(trigger, new When(), null,
                        new Guarded<Output>(new Output.Shell(new ShellOutput("first")))),
                    new Rule(trigger, new When(focus), null,
                        new Guarded<Output>(new Output.Shell(new ShellOutput("second"))), "b"),
                };
                var ran = new List<string>();
                var engine = new Engine(new KeypipeConfig(rules), desktop,
                    (s, i, e, t) => { ran.Add($"{s}:{i}"); return new ShellOutcome.Exited(0, ""); },
                    _ => { });
                Assert.Equal(new FireResult.Delivered(1, false), engine.FireRule(1, "note"));
                Assert.Equal(new[] { "second:note" }, ran);
            }
        }
    }

    // V9a: empty transform output notifies instead of wiping the field.
    [Fact]
    public void EmptyTransformOutputNotifiesInsteadOfWipingField()
    {
        var desktop = new FakeDesktop(focus: Focus.Text, fieldText: "hello");
        var (hits, lines) = Run("@@@",
            new[] { TextRule("@@@", new When(WhenFocus.TextField),
                new Guarded<string>("true"),
                new Guarded<Output>(new Output.Builtin(BuiltinSink.ReplaceInput))) },
            desktop, (s, i, e, t) => new ShellOutcome.Exited(0, ""));
        Assert.Contains("keypipe transform empty", lines);
        Assert.DoesNotContain(lines, l => l.StartsWith("keypipe apply replaceInput"));
        Assert.Equal(new[] { "@@@ transform failed: empty" }, desktop.Notifications);
        Assert.Equal("hello", desktop.FieldText);
    }

    // V9b: onFail.transform runs at most once with the same input.
    [Fact]
    public void TransformFallbackRunsOnceWithSameInput()
    {
        foreach (var (outcome, token) in new[]
                 {
                     ((ShellOutcome)new ShellOutcome.Exited(3, "junk"), "exit 3"),
                     ((ShellOutcome)new ShellOutcome.TimedOut(1), "timeout"),
                     ((ShellOutcome)new ShellOutcome.Exited(0, ""), "empty"),
                 })
        {
            var desktop = new FakeDesktop(focus: Focus.Text, fieldText: "hello");
            var calls = new List<string>();
            var (hits, lines) = Run("@@@",
                new[] { TextRule("@@@", new When(WhenFocus.TextField),
                    new Guarded<string>("primary", "fallback"),
                    new Guarded<Output>(new Output.Builtin(BuiltinSink.ReplaceInput))) },
                desktop,
                (s, i, e, t) =>
                {
                    calls.Add(s);
                    Assert.Equal("hello", i);
                    Assert.Equal(TimeSpan.FromSeconds(30), t);
                    if (s == "primary")
                    {
                        Assert.False(e.ContainsKey("KEYPIPE_FAILURE"));
                        return outcome;
                    }
                    Assert.Equal(token, e["KEYPIPE_FAILURE"]);
                    return new ShellOutcome.Exited(0, "HELLO");
                });
            Assert.Equal(new[] { "primary", "fallback" }, calls);
            Assert.Contains("keypipe fallback transform exit 0", lines);
            Assert.Equal("HELLO", desktop.FieldText);
            Assert.Empty(desktop.Notifications);
        }
    }

    // V9c: onFail.output runs at most once.
    [Fact]
    public void OutputFallbackRunsOnce()
    {
        var desktop = new FakeDesktop(focus: Focus.Text, fieldText: "hello");
        var seen = new List<(string, string?)>();
        var (hits, lines) = Run("@@@",
            new[] { TextRule("@@@", new When(WhenFocus.TextField),
                output: new Guarded<Output>(
                    new Output.Shell(new ShellOutput("send")),
                    new Output.Shell(new ShellOutput("keep")))) },
            desktop,
            (s, i, e, t) =>
            {
                seen.Add((s, e.TryGetValue("KEYPIPE_FAILURE", out var f) ? f : null));
                Assert.Equal("hello", i);
                return s == "send" ? new ShellOutcome.TimedOut(30) : new ShellOutcome.Exited(0, "");
            });
        Assert.Equal(new[] { "send", "keep" }, seen.Select(p => p.Item1).ToArray());
        Assert.Equal("timeout", seen.Last().Item2);
        Assert.Contains("keypipe output-shell timeout 30", lines);
        Assert.Contains("keypipe fallback output-shell exit 0", lines);
    }

    // V10a: a failed spawn is failed, not started.
    [Fact]
    public void FailedSpawnIsReportedAsFailedNotStarted()
    {
        var desktop = new FakeDesktop(app: "editor", focus: Focus.Text, fieldText: "note&&&");
        var lines = new List<string>();
        var engine = new Engine(
            new KeypipeConfig(new[]
            {
                TextRule("&&&", new When(WhenFocus.TextField),
                    output: new Guarded<Output>(
                        new Output.Shell(new ShellOutput("curl", Background: true)))),
            }),
            desktop, (s, i, e, t) => new ShellOutcome.Exited(0, ""), lines.Add,
            background: _ => false);
        Assert.Equal(new FireResult.Failed(0, "spawn", "spawn"), engine.Fire(new Trigger.Text("&&&")));
        Assert.Equal(1, engine.Hits);
    }

    // V12: erase waits for every Backspace before reading.
    [Fact]
    public void EraseWaitsForEveryBackspaceBeforeReading()
    {
        var desktop = new FakeDesktop(focus: Focus.Text, fieldText: "hello", backspacePerRead: true);
        string? seenInput = null;
        var (hits, lines) = Run("@@@",
            new[] { TextRule("@@@", new When(WhenFocus.TextField),
                new Guarded<string>("tr"),
                new Guarded<Output>(new Output.Builtin(BuiltinSink.ReplaceInput))) },
            desktop,
            (s, i, e, t) => { seenInput = i; return new ShellOutcome.Exited(0, "HELLO"); });
        Assert.Equal("hello", seenInput);
        Assert.DoesNotContain("keypipe erase-rewrite", lines);
        Assert.Equal("HELLO", desktop.FieldText);
    }

    // V12b: an app that ignores Backspace entirely still yields the body, via the
    // setText rewrite (EraseReadback "ignores" behavior). Same harm as V12: the
    // transform must never see a half-deleted or still-present trigger.
    [Fact]
    public void EraseIgnoresBackspaceStillYieldsBody()
    {
        var desktop = new FakeDesktop(focus: Focus.Text, fieldText: "hello", ignoresBackspace: true);
        string? seenInput = null;
        var (hits, lines) = Run("@@@",
            new[] { TextRule("@@@", new When(WhenFocus.TextField),
                new Guarded<string>("tr"),
                new Guarded<Output>(new Output.Builtin(BuiltinSink.ReplaceInput))) },
            desktop,
            (s, i, e, t) => { seenInput = i; return new ShellOutcome.Exited(0, "HELLO"); });
        Assert.Equal("hello", seenInput);
        Assert.Contains("keypipe erase-rewrite", lines);
        Assert.Equal("HELLO", desktop.FieldText);
    }

    // V12c: the EraseReadback bound at the code level. A 3-char trigger against
    // one-Backspace-per-read takes the wait-for-trigger read plus at most 5
    // readback polls (the model's MaxReads) before the body is handed over.
    [Fact]
    public void EraseReadbackStaysWithinFiveReads()
    {
        var desktop = new FakeDesktop(focus: Focus.Text, fieldText: "hello@@@", backspacePerRead: true);
        var lines = new List<string>();
        var body = Engine.PerformErase(new Field(0), "@@@", desktop, lines.Add);
        Assert.Equal("hello", body);
        Assert.True(desktop.TextReads <= 6,
            $"expected <= 6 text reads (1 wait + 5 polls), got {desktop.TextReads}");
        Assert.Equal("hello", desktop.FieldText);
    }

    // V15: Backspace counts characters (graphemes), as Swift's trigger.count,
    // not UTF-16 units, or a non-BMP trigger erases characters past the trigger.
    [Fact]
    public void EraseCountsCharactersNotUtf16Units()
    {
        var desktop = new FakeDesktop(focus: Focus.Text, fieldText: "ab😀😀");
        var lines = new List<string>();
        var body = Engine.PerformErase(new Field(0), "😀😀", desktop, lines.Add);
        Assert.Equal("ab", body);
        Assert.Contains("keypipe erase 2", lines);
        Assert.Equal("ab", desktop.FieldText);
    }

    // V15 (any focus): the same character count drives the erase on the any path.
    [Fact]
    public void AnyFocusEraseCountsCharactersNotUtf16Units()
    {
        var desktop = new FakeDesktop(focus: Focus.Text, fieldText: "ab");
        var (hits, lines) = Run("😀😀",
            new[] { TextRule("😀😀", output: new Guarded<Output>(new Output.Shell(new ShellOutput("send")))) },
            desktop, (s, i, e, t) => new ShellOutcome.Exited(0, ""));
        Assert.Contains("keypipe erase 2", lines);
        Assert.Equal("ab", desktop.FieldText);
    }

    // V16: the fired label is capped at 40 graphemes after whitespace runs
    // collapse and the ends are trimmed (Swift firedLabel), not before.
    [Fact]
    public void FiredLabelCapsAfterCollapsingWhitespace()
    {
        var padded = new Rule(new Trigger.Text("@@@"), new When(), null,
            new Guarded<Output>(new Output.Builtin(BuiltinSink.Notify)),
            Label: "  " + new string('a', 45));
        Assert.Equal("@@@ → " + new string('a', 40),
            Engine.FiredLabel(new Trigger.Text("@@@"), padded));
        var spaced = new Rule(new Trigger.Text("@@@"), new When(), null,
            new Guarded<Output>(new Output.Builtin(BuiltinSink.Notify)),
            Label: "  foo   bar  ");
        Assert.Equal("@@@ → foo bar",
            Engine.FiredLabel(new Trigger.Text("@@@"), spaced));
    }

    // V18: a field that vanishes once erase starts turns a replaceInput apply
    // into the "gone" output failure, never a silent delivery.
    [Fact]
    public void FieldGoneAfterEraseFailsOutputAsGone()
    {
        var desktop = new FakeDesktop(focus: Focus.Text, fieldText: "hello@@@", goneAfterErase: true);
        var engine = new Engine(new KeypipeConfig(new[]
        {
            TextRule("@@@", new When(WhenFocus.TextField),
                output: new Guarded<Output>(new Output.Builtin(BuiltinSink.ReplaceInput))),
        }), desktop, Echo, _ => { });
        Assert.Equal(new FireResult.Failed(0, "output", "gone"),
            engine.Fire(new Trigger.Text("@@@")));
    }
}
