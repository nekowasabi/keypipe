using System.Text.Json;

namespace Keypipe.Core;

public sealed class ConfigException : Exception
{
    public ConfigException(string detail, bool unreadable = false)
        : base($"keypipe: {(unreadable ? "cannot read config" : "invalid config")}: {detail}")
    {
    }
}

public enum WhenFocus { TextField, Any }

public sealed record When(WhenFocus Focus, Conditions Conditions)
{
    public When(WhenFocus focus = WhenFocus.Any) : this(focus, new Conditions()) { }
    public When() : this(WhenFocus.Any, new Conditions()) { }
}

public sealed record Guarded<T>(T Primary, T? OnFail) where T : class
{
    public Guarded(T Primary) : this(Primary, null) { }
}

public sealed record Rule(
    Trigger Trigger,
    When When,
    Guarded<string>? Transform,
    Guarded<Output> Output,
    string? Name = null,
    string? Label = null,
    string? Icon = null);

public sealed record KeypipeConfig(
    IReadOnlyList<Rule> Rules,
    IReadOnlyList<Conditions> Deny,
    TimeSpan ShellTimeout,
    TimeSpan BackgroundTimeout,
    bool Hud)
{
    public KeypipeConfig(IReadOnlyList<Rule> Rules)
        : this(Rules, Array.Empty<Conditions>(),
            TimeSpan.FromSeconds(30), TimeSpan.FromSeconds(300), true)
    {
    }

    public KeypipeConfig(IReadOnlyList<Rule> Rules, IReadOnlyList<Conditions> Deny)
        : this(Rules, Deny,
            TimeSpan.FromSeconds(30), TimeSpan.FromSeconds(300), true)
    {
    }
}

public static class ConfigLoader
{
    public static KeypipeConfig Load(string json)
    {
        using var doc = JsonDocument.Parse(json);
        if (doc.RootElement.ValueKind != JsonValueKind.Object)
            throw new ConfigException("expected object");
        return LoadRoot(doc.RootElement);
    }

    public static KeypipeConfig LoadFile(string path)
    {
        string text;
        try { text = File.ReadAllText(path); }
        catch (Exception ex) { throw new ConfigException(ex.Message, unreadable: true); }
        try { return Load(text); }
        catch (ConfigException) { throw; }
        catch (JsonException ex) { throw new ConfigException($"JSON decoding failed: {ex.Message}"); }
    }

    private static KeypipeConfig LoadRoot(JsonElement root)
    {
        CheckKeys(root, new[] { "rules", "deny", "shellTimeout", "backgroundTimeout", "hud" });
        var deny = new List<Conditions>();
        if (TryGet(root, "deny", out var denyEl))
        {
            if (denyEl.ValueKind != JsonValueKind.Array)
                throw new ConfigException("deny must be an array");
            foreach (var entry in denyEl.EnumerateArray())
            {
                var cond = ParseConditions(entry, allowlist: FactKeys());
                if (cond.Terms.Count == 0) throw new ConfigException("empty deny entry");
                var slow = cond.Terms.FirstOrDefault(t => FactNames.Cost(t.Fact) == FactCost.Slow);
                if (slow is not null && !cond.HasApp)
                    throw new ConfigException($"deny {FactNames.Key(slow.Fact)} requires app");
                deny.Add(cond);
            }
        }
        var shellTimeout = Seconds(root, "shellTimeout", TimeSpan.FromSeconds(30));
        var backgroundTimeout = Seconds(root, "backgroundTimeout", TimeSpan.FromSeconds(300));
        bool hud = true;
        if (TryGet(root, "hud", out var hudEl))
        {
            if (hudEl.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
                throw new ConfigException("hud must be a boolean");
            hud = hudEl.GetBoolean();
        }
        if (!TryGet(root, "rules", out var rulesEl) || rulesEl.ValueKind != JsonValueKind.Array)
            throw new ConfigException("rules must be an array");
        var rules = rulesEl.EnumerateArray().Select(ParseRule).ToList();
        var names = new HashSet<string>();
        foreach (var name in rules.Select(r => r.Name).Where(n => n is not null))
            if (!names.Add(name!)) throw new ConfigException($"duplicate name {name}");
        return new KeypipeConfig(rules, deny, shellTimeout, backgroundTimeout, hud);
    }

    private static Rule ParseRule(JsonElement el)
    {
        if (el.ValueKind != JsonValueKind.Object) throw new ConfigException("expected object");
        CheckKeys(el, new[] { "trigger", "hotkey", "when", "transform", "output", "onFail", "name", "label", "icon" });
        bool hasTrigger = el.TryGetProperty("trigger", out var triggerEl);
        bool hasHotkey = el.TryGetProperty("hotkey", out var hotkeyEl);
        Trigger trigger;
        if (hasTrigger == hasHotkey)
            throw new ConfigException(hasTrigger ? "rule has both trigger and hotkey" : "rule needs trigger or hotkey");
        if (hasTrigger)
        {
            var text = NonEmpty(triggerEl, "trigger");
            if (text.Length > TriggerMatcher.MaxBuffer)
                throw new ConfigException(
                    $"rule trigger exceeds {TriggerMatcher.MaxBuffer} characters and can never match");
            trigger = new Trigger.Text(text);
        }
        else
        {
            trigger = new Trigger.HotkeyTrigger(Hotkey.Parse(NonEmpty(hotkeyEl, "hotkey")));
        }
        var when = new When();
        if (TryGet(el, "when", out var whenEl))
        {
            if (whenEl.ValueKind != JsonValueKind.Object) throw new ConfigException("expected object");
            CheckKeys(whenEl, new[] { "focus", "app", "url" });
            var conditions = ParseConditions(whenEl, allowlist: FactKeys(), skip: new[] { "focus" });
            var focus = WhenFocus.Any;
            if (TryGet(whenEl, "focus", out var focusEl))
            {
                if (focusEl.ValueKind != JsonValueKind.String)
                    throw new ConfigException("focus must be a string");
                focus = focusEl.GetString() switch
                {
                    "textField" => WhenFocus.TextField,
                    "any" => WhenFocus.Any,
                    string s => throw new ConfigException($"unknown focus {s}"),
                    null => throw new ConfigException("focus must be a string"),
                };
            }
            when = new When(focus, conditions);
        }
        Guarded<string>? transform = null;
        if (TryGet(el, "transform", out var transformEl))
            transform = new Guarded<string>(NonEmpty(transformEl, "transform"));
        Output primary = new Output.Builtin(BuiltinSink.None);
        if (TryGet(el, "output", out var outputEl))
            primary = ParseOutput(outputEl, when.Focus, isPrimary: true);
        var output = new Guarded<Output>(primary);
        if (TryGet(el, "onFail", out var onFailEl))
        {
            if (onFailEl.ValueKind != JsonValueKind.Object) throw new ConfigException("expected object");
            CheckKeys(onFailEl, new[] { "transform", "output" });
            if (TryGet(onFailEl, "transform", out var fbTransform))
            {
                if (transform is null)
                    throw new ConfigException("onFail.transform requires transform");
                transform = transform with { OnFail = NonEmpty(fbTransform, "transform") };
            }
            if (TryGet(onFailEl, "output", out var fbOutput))
            {
                if (!primary.CanFail)
                    throw new ConfigException("onFail.output requires an output that can fail");
                var fallback = ParseOutput(fbOutput, when.Focus, isPrimary: false);
                if (primary.IsBackground && !fallback.Detachable)
                    throw new ConfigException(
                        $"a background output cannot fall back to {fallback.Name}");
                output = output with { OnFail = fallback };
            }
        }
        string? Name(JsonElement e, string key)
            => TryGet(e, key, out var v) ? NonBlank(v, key) : null;
        return new Rule(trigger, when, transform, output,
            Name(el, "name"), Name(el, "label"), Name(el, "icon"));
    }

    private static Output ParseOutput(JsonElement el, WhenFocus focus, bool isPrimary)
    {
        Output output;
        if (el.ValueKind == JsonValueKind.String)
        {
            var sink = BuiltinSinks.Parse(el.GetString() ?? "");
            output = new Output.Builtin(sink);
        }
        else if (el.ValueKind == JsonValueKind.Object)
        {
            CheckKeys(el, isPrimary ? new[] { "shell", "background" } : new[] { "shell" });
            if (!TryGet(el, "shell", out var shellEl))
                throw new ConfigException("expected object");
            var script = NonEmpty(shellEl, "output.shell");
            bool background = false;
            if (TryGet(el, "background", out var bgEl))
            {
                if (bgEl.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
                    throw new ConfigException("background must be a boolean");
                background = bgEl.GetBoolean();
            }
            output = new Output.Shell(new ShellOutput(script, background));
        }
        else
        {
            throw new ConfigException("expected object");
        }
        if (output.NeedsTextField && focus != WhenFocus.TextField)
            throw new ConfigException($"output {output.Name} requires focus textField");
        return output;
    }

    private static string[] FactKeys() => new[] { "app", "url" };

    private static Conditions ParseConditions(JsonElement el, string[] allowlist, string[]? skip = null)
    {
        if (el.ValueKind != JsonValueKind.Object) throw new ConfigException("expected object");
        CheckKeys(el, (skip ?? Array.Empty<string>()).Concat(allowlist));
        var terms = new List<Term>();
        foreach (var key in allowlist)
        {
            if (!TryGet(el, key, out var arr)) continue;
            if (arr.ValueKind != JsonValueKind.Array)
                throw new ConfigException($"{key} must be an array of strings");
            var globs = new List<string>();
            foreach (var g in arr.EnumerateArray())
            {
                if (g.ValueKind != JsonValueKind.String)
                    throw new ConfigException($"{key} must be an array of strings");
                globs.Add(g.GetString() ?? "");
            }
            if (globs.Count == 0) throw new ConfigException($"empty {key} list");
            terms.Add(new Term(FactNames.Parse(key), globs));
        }
        return new Conditions(terms);
    }

    private static TimeSpan Seconds(JsonElement root, string name, TimeSpan @default)
    {
        if (!TryGet(root, name, out var el)) return @default;
        double seconds;
        try { seconds = el.GetDouble(); }
        catch { throw new ConfigException($"{name} must be positive"); }
        if (!(seconds > 0)) throw new ConfigException($"{name} must be positive");
        return TimeSpan.FromSeconds(seconds);
    }

    private static string NonEmpty(JsonElement el, string name)
    {
        if (el.ValueKind != JsonValueKind.String)
            throw new ConfigException($"{name} must be a string");
        var s = el.GetString() ?? "";
        if (s.Length == 0) throw new ConfigException($"empty {name}");
        return s;
    }

    private static string NonBlank(JsonElement el, string name)
    {
        var s = NonEmpty(el, name);
        if (string.IsNullOrWhiteSpace(s)) throw new ConfigException($"empty {name}");
        return s;
    }

    private static bool TryGet(JsonElement el, string name, out JsonElement value)
        => el.TryGetProperty(name, out value);

    private static void CheckKeys(JsonElement el, IEnumerable<string> allowed)
    {
        var set = new HashSet<string>(allowed);
        foreach (var prop in el.EnumerateObject())
            if (!set.Contains(prop.Name))
                throw new ConfigException($"unknown key {prop.Name}");
    }
}
