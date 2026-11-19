using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Keypipe.Core;

public abstract record ShellOutcome
{
    public sealed record Exited(int Status, string Stdout) : ShellOutcome;
    public sealed record TimedOut(int Seconds) : ShellOutcome;
}

public enum WriteOutcome { Written, Ignored, Gone }

public abstract record FireResult
{
    public sealed record Blocked(string Reason) : FireResult;
    public sealed record NoMatch : FireResult
    {
        public static readonly NoMatch Instance = new();
    }
    public sealed record Unreadable(string Fact, string Reason) : FireResult;
    public sealed record NoInput(int Rule) : FireResult;
    public sealed record Replaced(int Rule, string Text, bool ViaFallback) : FireResult;
    public sealed record Delivered(int Rule, bool ViaFallback) : FireResult;
    public sealed record Started(int Rule) : FireResult;
    public sealed record Failed(int Rule, string Stage, string Failure) : FireResult;

    public enum Kind { Blocked, NoMatch, Unreadable, NoInput, Replaced, Delivered, Started, Failed }

    public Kind GetKind() => this switch
    {
        Blocked => Kind.Blocked,
        NoMatch => Kind.NoMatch,
        Unreadable => Kind.Unreadable,
        NoInput => Kind.NoInput,
        Replaced => Kind.Replaced,
        Delivered => Kind.Delivered,
        Started => Kind.Started,
        Failed => Kind.Failed,
        _ => throw new InvalidOperationException(),
    };

    public bool IsHit => this switch
    {
        Blocked => false,
        NoMatch => false,
        Unreadable => false,
        _ => true,
    };
}

public sealed record Job(int Rule, string Input, IReadOnlyDictionary<string, string> Environment);

public sealed class Engine
{
    private readonly KeypipeConfig _config;
    private readonly IDesktop _desktop;
    private readonly Func<string, string, IReadOnlyDictionary<string, string>, TimeSpan, ShellOutcome> _shell;
    private readonly Action<string> _emit;
    private readonly Func<Job, bool> _background;
    private TriggerMatcher _matcher;
    private readonly HashSet<Hotkey> _hotkeys;

    public int Hits { get; private set; }

    public Engine(
        KeypipeConfig config,
        IDesktop desktop,
        Func<string, string, IReadOnlyDictionary<string, string>, TimeSpan, ShellOutcome> shell,
        Action<string> emit,
        Func<Job, bool>? background = null)
    {
        _config = config;
        _desktop = desktop;
        _shell = shell;
        _emit = emit;
        _background = background ?? (_ => false);
        var texts = new List<string>();
        _hotkeys = new HashSet<Hotkey>();
        foreach (var rule in config.Rules)
        {
            switch (rule.Trigger)
            {
                case Trigger.Text t: texts.Add(t.Value); break;
                case Trigger.HotkeyTrigger h: _hotkeys.Add(h.Chord); break;
            }
        }
        _matcher = new TriggerMatcher(texts);
    }

    public void Key(char character)
    {
        var text = _matcher.Feed(character);
        if (text is null) return;
        _matcher.Reset();
        Fire((Trigger)new Trigger.Text(text));
    }

    public void Hotkey(Hotkey hotkey)
    {
        _matcher.Reset();
        if (!_hotkeys.Contains(hotkey)) return;
        Fire((Trigger)new Trigger.HotkeyTrigger(hotkey));
    }

    public FireResult Fire(Trigger trigger)
    {
        var matching = _config.Rules
            .Select((r, i) => (r, i))
            .Where(p => p.r.Trigger.Equals(trigger))
            .Select(p => p.i)
            .ToList();
        return Fire(trigger, matching, null);
    }

    public FireResult FireRule(int index, string input)
        => Fire(_config.Rules[index].Trigger, new List<int> { index }, input);

    private FireResult Fire(Trigger trigger, List<int> candidates, string? input)
    {
        var snapshot = _desktop.Snapshot();
        if (snapshot.Focus == Focus.Terminal)
        {
            candidates = trigger.IsHotkey
                ? candidates.Where(i => _config.Rules[i].When.Focus == WhenFocus.Any).ToList()
                : new List<int>();
            if (candidates.Count == 0)
            {
                _emit($"keypipe terminal {trigger}");
                return new FireResult.Blocked("terminal");
            }
        }
        if (snapshot.Focus == Focus.Composing)
        {
            _emit($"keypipe composing {trigger}");
            return new FireResult.Blocked("composing");
        }
        if (snapshot.Secure)
        {
            _emit($"keypipe secure {trigger}");
            return new FireResult.Blocked("secure");
        }
        var sheet = new FactSheet(snapshot, _desktop);
        foreach (var entry in _config.Deny)
        {
            var verdict = entry.Evaluate(sheet);
            switch (verdict)
            {
                case Conditions.Verdict.NoMatch: continue;
                case Conditions.Verdict.Match:
                    _emit($"keypipe deny {trigger}");
                    return new FireResult.Blocked("deny");
                case Conditions.Verdict.Unreadable u:
                    _emit($"keypipe deny-unreadable {trigger} {FactNames.Key(u.Fact)}");
                    Notify($"{trigger}: deny cannot read {FactNames.Key(u.Fact)}: {u.Reason}");
                    return new FireResult.Unreadable(FactNames.Key(u.Fact), u.Reason);
            }
        }
        int? chosen = null;
        foreach (var candidate in candidates)
        {
            var when = _config.Rules[candidate].When;
            var verdict = snapshot.Focus == Focus.Terminal
                ? when.Conditions.Evaluate(sheet)
                : Context.Evaluate(when, sheet);
            if (verdict is Conditions.Verdict.NoMatch) continue;
            if (verdict is Conditions.Verdict.Unreadable u)
            {
                _emit($"keypipe unreadable {trigger} {FactNames.Key(u.Fact)}");
                Notify($"{trigger}: cannot read {FactNames.Key(u.Fact)}: {u.Reason}");
                return new FireResult.Unreadable(FactNames.Key(u.Fact), u.Reason);
            }
            chosen = candidate;
            break;
        }
        if (chosen is null)
        {
            _emit($"keypipe nomatch {trigger}");
            return FireResult.NoMatch.Instance;
        }
        var rule = _config.Rules[chosen.Value];
        if (sheet.ReadSlow)
        {
            var now = _desktop.Snapshot();
            bool moved = now.App != snapshot.App || now.Focus != snapshot.Focus || now.Secure;
            if (!moved && snapshot.Field is not null && now.Field is not null
                && !_desktop.SameField(snapshot.Field, now.Field))
                moved = true;
            if (!moved && trigger is Trigger.Text text && snapshot.Focus == Focus.Text
                && snapshot.Field is not null)
            {
                moved = !(WaitForTrigger(snapshot.Field, text.Value, _desktop)?.EndsWith(text.Value, StringComparison.Ordinal) ?? false);
                if (!moved)
                {
                    var after = _desktop.Snapshot();
                    moved = after.App != snapshot.App || after.Focus != snapshot.Focus || after.Secure
                        || !(after.Field is not null && _desktop.SameField(snapshot.Field, after.Field));
                }
            }
            if (moved)
            {
                _emit($"keypipe front-changed {trigger}");
                return new FireResult.Blocked("front-changed");
            }
        }
        Hits += 1;
        _emit($"keypipe matched {trigger} rule {chosen.Value}");
        _desktop.ShowBusy(snapshot.Field);
        var result = RunAfterBusy(rule, chosen.Value, trigger, snapshot, input);
        _desktop.HideBusy();
        ShowFiredIfNeeded(result, trigger, rule);
        return result;
    }

    private FireResult RunAfterBusy(
        Rule rule, int index, Trigger trigger, Snapshot snapshot, string? suppliedInput)
    {
        string input;
        switch ((trigger, rule.When.Focus))
        {
            case (Trigger.Text text, WhenFocus.TextField):
                if (snapshot.Field is null) return new FireResult.NoInput(index);
                var erased = PerformErase(snapshot.Field, text.Value, _desktop, _emit);
                if (erased is null) return new FireResult.NoInput(index);
                input = suppliedInput ?? erased;
                break;
            case (Trigger.HotkeyTrigger, WhenFocus.TextField):
                _emit("keypipe erase 0");
                if (snapshot.Field is null) return new FireResult.NoInput(index);
                var current = _desktop.GetText(snapshot.Field);
                if (current is null) return new FireResult.NoInput(index);
                input = suppliedInput ?? current;
                break;
            case (Trigger.Text text, WhenFocus.Any):
            {
                int count = snapshot.Focus == Focus.Text ? TextCount.Of(text.Value) : 0;
                if (count > 0 && snapshot.Field is not null)
                {
                    WaitForTrigger(snapshot.Field, text.Value, _desktop);
                    _desktop.Backspace(count);
                }
                _emit($"keypipe erase {count}");
                input = suppliedInput ?? "";
                break;
            }
            case (Trigger.HotkeyTrigger, WhenFocus.Any):
                _emit("keypipe erase 0");
                input = suppliedInput ?? "";
                break;
            default: throw new InvalidOperationException();
        }
        var environment = new Dictionary<string, string> { ["KEYPIPE_APP"] = snapshot.App ?? "" };
        if (rule.Output.Primary.IsBackground)
        {
            _emit($"keypipe background rule {index}");
            if (!_background(new Job(index, input, environment)))
                return new FireResult.Failed(index, "spawn", "spawn");
            return new FireResult.Started(index);
        }
        return Run(rule, index, input, environment, snapshot);
    }

    private void ShowFiredIfNeeded(FireResult result, Trigger trigger, Rule rule)
    {
        if (!_config.Hud) return;
        FiredStatus status;
        switch (result)
        {
            case FireResult.Replaced:
            case FireResult.Delivered: status = FiredStatus.Ok; break;
            case FireResult.Started: status = FiredStatus.Started; break;
            case FireResult.Failed: status = FiredStatus.Failed; break;
            default: return;
        }
        string? stage = result is FireResult.Failed f ? f.Stage : null;
        var evt = new FiredEvent(trigger, FiredLabel(trigger, rule), status, stage, rule.Icon);
        _desktop.ShowFired(evt);
        _emit($"keypipe hud {trigger} {status.ToString().ToLowerInvariant()} {Json(Json(evt.Label))} {(rule.Icon is string icon ? Json(icon) : "none")}");
    }

    public FireResult Run(Job job)
    {
        if (job.Rule < 0 || job.Rule >= _config.Rules.Count)
        {
            Notify($"background job: no rule {job.Rule}");
            return FireResult.NoMatch.Instance;
        }
        return Run(_config.Rules[job.Rule], job.Rule, job.Input, job.Environment, null);
    }

    private FireResult Run(
        Rule rule, int index, string input,
        IReadOnlyDictionary<string, string> environment, Snapshot? origin)
    {
        var trigger = rule.Trigger;
        var result = input;
        if (rule.Transform is not null)
        {
            var outcome = RunTransform(rule.Transform, input, environment);
            if (outcome.IsFailure(out var failure))
            {
                Notify($"{trigger} transform failed: {failure}");
                return new FireResult.Failed(index, "transform", failure);
            }
            result = outcome.Value!;
        }
        FireResult Success(Output output, bool viaFallback) => output.WritesField
            ? new FireResult.Replaced(index, result, viaFallback)
            : new FireResult.Delivered(index, viaFallback);
        var failure1 = Apply(rule.Output.Primary, result, environment, origin, "");
        if (failure1 is null) return Success(rule.Output.Primary, false);
        if (rule.Output.OnFail is null)
        {
            if (rule.Output.Primary is Output.Builtin)
                Notify(result);
            else if (rule.Output.Primary.IsBackground)
                Notify($"{trigger} output failed: {failure1}");
            return new FireResult.Failed(index, "output", failure1);
        }
        var env2 = new Dictionary<string, string>(environment) { ["KEYPIPE_FAILURE"] = failure1 };
        var failure2 = Apply(rule.Output.OnFail, result, env2, origin, "fallback ");
        if (failure2 is not null)
        {
            Notify($"{trigger} output failed: {failure2}");
            return new FireResult.Failed(index, "output", failure2);
        }
        return Success(rule.Output.OnFail, true);
    }

    private TransformOutcome RunTransform(
        Guarded<string> transform, string input, IReadOnlyDictionary<string, string> env)
    {
        var primary = ShellStage(transform.Primary, input, env, "", "transform");
        if (primary.IsFailure(out var failure))
        {
            if (transform.OnFail is null) return TransformOutcome.Fail(failure);
            var env2 = new Dictionary<string, string>(env) { ["KEYPIPE_FAILURE"] = failure };
            return ShellStage(transform.OnFail, input, env2, "fallback ", "transform") switch
            {
                { } r => r.IsFailure(out var f2) ? TransformOutcome.Fail(f2) : TransformOutcome.Ok(r.Value!),
            };
        }
        return TransformOutcome.Ok(primary.Value!);
    }

    private TransformOutcome ShellStage(
        string script, string input, IReadOnlyDictionary<string, string> env,
        string prefix, string stage)
    {
        var outcome = _shell(script, input, env, _config.ShellTimeout);
        switch (outcome)
        {
            case ShellOutcome.Exited e:
                _emit($"keypipe {prefix}{stage} exit {e.Status}");
                if (e.Status != 0) return TransformOutcome.Fail($"exit {e.Status}");
                if (stage == "transform" && e.Stdout.Length == 0)
                {
                    _emit($"keypipe {prefix}{stage} empty");
                    return TransformOutcome.Fail("empty");
                }
                return TransformOutcome.Ok(e.Stdout);
            case ShellOutcome.TimedOut t:
                _emit($"keypipe {prefix}{stage} timeout {t.Seconds}");
                return TransformOutcome.Fail("timeout");
            default: throw new InvalidOperationException();
        }
    }

    private string? Apply(
        Output output, string result,
        IReadOnlyDictionary<string, string> env, Snapshot? origin, string prefix)
    {
        switch (output)
        {
            case Output.Builtin b:
                var failure = SinkRunner.Perform(b.Sink, result, origin, _desktop);
                if (failure is not null)
                {
                    _emit($"keypipe {prefix}apply-failed {BuiltinSinks.Name(b.Sink)} {failure}");
                    return failure;
                }
                _emit($"keypipe {prefix}apply {BuiltinSinks.Name(b.Sink)} {Json(result)}");
                return null;
            case Output.Shell s:
                var outcome = ShellStage(s.Value.Script, result, env, prefix, "output-shell");
                return outcome.IsFailure(out var f) ? f : null;
            default: throw new InvalidOperationException();
        }
    }

    private void Notify(string text)
    {
        _desktop.Notify(text);
        _emit($"keypipe apply notify {Json(text)}");
    }

    public static string? WaitForTrigger(Field field, string trigger, IDesktop desktop)
    {
        var text = desktop.GetText(field);
        if (text is null) return null;
        var deadline = DateTime.UtcNow.AddMilliseconds(100);
        while (!text.EndsWith(trigger, StringComparison.Ordinal) && DateTime.UtcNow < deadline)
        {
            Thread.Sleep(5);
            var current = desktop.GetText(field);
            if (current is null) return null;
            text = current;
        }
        return text;
    }

    public static string? PerformErase(
        Field field, string trigger, IDesktop desktop, Action<string> emit)
    {
        var before = WaitForTrigger(field, trigger, desktop);
        if (before is null) return null;
        var count = TextCount.Of(trigger);
        desktop.Backspace(count);
        emit($"keypipe erase {count}");
        if (!before.EndsWith(trigger, StringComparison.Ordinal))
        {
            emit("keypipe erase-failed trigger-absent");
            return desktop.GetText(field);
        }
        var expected = before.Substring(0, before.Length - trigger.Length);
        var deadline = DateTime.UtcNow.AddMilliseconds(200);
        var after = desktop.GetText(field);
        while (after != expected && DateTime.UtcNow < deadline)
        {
            Thread.Sleep(5);
            after = desktop.GetText(field);
        }
        var current = after;
        if (current is null) return null;
        if (current != before) return current;
        if (!desktop.SetText(field, expected)) return null;
        var rewritten = desktop.GetText(field);
        if (rewritten is null) return null;
        if (rewritten == expected) emit("keypipe erase-rewrite");
        else emit("keypipe erase-failed rewrite-ignored");
        return rewritten;
    }

    public static WriteOutcome PerformWrite(Field field, string text, IDesktop desktop)
    {
        if (!desktop.SetText(field, text)) return WriteOutcome.Gone;
        var deadline = DateTime.UtcNow.AddMilliseconds(200);
        while (true)
        {
            var readback = desktop.GetText(field);
            if (readback is null) return WriteOutcome.Gone;
            if (readback == text) return WriteOutcome.Written;
            if (DateTime.UtcNow >= deadline) return WriteOutcome.Ignored;
            Thread.Sleep(5);
        }
    }

    public static string FiredLabel(Trigger trigger, Rule rule)
    {
        string raw = rule.Label ?? rule.Name
            ?? (rule.Output.Primary is Output.Shell s ? s.Value.Script
                : rule.Output.Primary is Output.Builtin b ? BuiltinSinks.Name(b.Sink) : "");
        var collapsed = Regex.Replace(raw, @"\s+", " ").Trim();
        var si = new StringInfo(collapsed);
        string capped = si.LengthInTextElements <= 40
            ? collapsed
            : si.SubstringByTextElements(0, 40);
        return $"{trigger} → {capped.Trim()}";
    }

    private static string Json(string text) => JsonSerializer.Serialize(text);

    private sealed class TransformOutcome
    {
        public string? Value { get; }
        public string? Failure { get; }
        private TransformOutcome(string? value, string? failure) { Value = value; Failure = failure; }
        public static TransformOutcome Ok(string value) => new(value, null);
        public static TransformOutcome Fail(string failure) => new(null, failure);
        public bool IsFailure(out string failure) { failure = Failure!; return Failure is not null; }
    }
}
