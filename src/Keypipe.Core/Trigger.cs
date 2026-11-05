namespace Keypipe.Core;

public enum Modifier { Ctrl, Alt, Cmd }

public sealed record Hotkey(IReadOnlySet<Modifier> Modifiers, string Key)
{
    public bool Equals(Hotkey? other)
        => other is not null && Key == other.Key
            && Modifiers.Count == other.Modifiers.Count
            && Modifiers.All(other.Modifiers.Contains);

    public override int GetHashCode()
    {
        var h = new HashCode();
        h.Add(Key);
        foreach (var m in Modifiers.OrderBy(m => m)) h.Add(m);
        return h.ToHashCode();
    }

    public override string ToString()
    {
        var parts = new List<string>();
        foreach (var m in new[] { Modifier.Ctrl, Modifier.Alt, Modifier.Cmd })
            if (Modifiers.Contains(m))
                parts.Add(m switch { Modifier.Ctrl => "ctrl", Modifier.Alt => "alt", _ => "cmd" });
        parts.Add(Key);
        return string.Join("+", parts);
    }

    public static Hotkey Parse(string spec)
    {
        var parts = spec.Split('+');
        var pieces = new List<string>();
        int i = 0;
        while (i < spec.Length)
        {
            int j = spec.IndexOf('+', i);
            if (j < 0) { pieces.Add(spec.Substring(i)); break; }
            pieces.Add(spec.Substring(i, j - i));
            i = j + 1;
        }
        if (spec.EndsWith("+") && pieces.Count >= 2 && pieces[^1] == "" && pieces[^2] == "")
        {
            pieces.RemoveAt(pieces.Count - 1);
            pieces[^1] = "+";
        }
        else if (pieces.Count > 0 && pieces[^1] == "" && spec.EndsWith("+"))
        {
            pieces[^1] = "+";
        }
        var key = pieces[^1];
        if (key.Length == 0) throw new ConfigException("empty hotkey key");
        if (key.Length != 1) throw new ConfigException("hotkey key must be one character");
        var mods = new HashSet<Modifier>();
        foreach (var part in pieces.Take(pieces.Count - 1))
        {
            switch (part)
            {
                case "ctrl":
                case "control": mods.Add(Modifier.Ctrl); break;
                case "alt":
                case "option": mods.Add(Modifier.Alt); break;
                case "cmd":
                case "command": mods.Add(Modifier.Cmd); break;
                case "shift": throw new ConfigException("shift is written in the key (ctrl+A)");
                default: throw new ConfigException($"unknown modifier {part}");
            }
        }
        if (mods.Count == 0) throw new ConfigException("hotkey needs a modifier");
        return new Hotkey(mods, key);
    }
}

public abstract record Trigger
{
    public sealed record Text(string Value) : Trigger
    {
        public override string ToString() => Value;
    }
    public sealed record HotkeyTrigger(Hotkey Chord) : Trigger
    {
        public override string ToString() => Chord.ToString();
    }

    public bool IsHotkey => this is HotkeyTrigger;

    public static implicit operator Trigger(string text) => new Text(text);
}

public sealed class TriggerMatcher
{
    public const int MaxBuffer = 64;
    private readonly List<string> _triggers;
    private readonly int _maxBuffer;
    private readonly List<char> _chars = new();

    public TriggerMatcher(IEnumerable<string> triggers, int maxBuffer = MaxBuffer)
    {
        _triggers = triggers
            .Select((t, i) => (t, i))
            .OrderByDescending(p => p.t.Length)
            .ThenBy(p => p.i)
            .Select(p => p.t)
            .ToList();
        _maxBuffer = maxBuffer;
    }

    public string Buffer => new(_chars.ToArray());

    public void Reset() => _chars.Clear();

    public string? Feed(char character)
    {
        _chars.Add(character);
        if (_chars.Count > _maxBuffer)
            _chars.RemoveRange(0, _chars.Count - _maxBuffer);
        var current = Buffer;
        foreach (var trigger in _triggers)
        {
            if (trigger.Length == 0) continue;
            if (current.EndsWith(trigger, StringComparison.Ordinal))
                return trigger;
        }
        return null;
    }
}
