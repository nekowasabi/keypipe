using System.Globalization;

namespace Keypipe.Core;

/// Character counting the way Swift's String.count does it: extended
/// grapheme clusters (text elements), not UTF-16 code units. Everywhere the
/// Swift code says `count` (trigger limit, Backspace count, buffer size),
/// the port must use this or non-BMP text diverges.
public static class TextCount
{
    public static int Of(string text) => new StringInfo(text).LengthInTextElements;
}

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
        // Split like Swift's split(separator:omittingEmptySubsequences:false):
        // every separator leaves a piece, so a trailing "+" leaves an empty
        // key, and only "++" at the end means the "+" key itself.
        var parts = spec.Split('+').ToList();
        var key = parts[^1];
        parts.RemoveAt(parts.Count - 1);
        if (key.Length == 0 && parts.Count > 0 && parts[^1] == "")
        {
            parts.RemoveAt(parts.Count - 1);
            key = "+";
        }
        if (key.Length == 0) throw new ConfigException("empty hotkey key");
        if (TextCount.Of(key) != 1) throw new ConfigException("hotkey key must be one character");
        var mods = new HashSet<Modifier>();
        foreach (var part in parts)
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
            .OrderByDescending(p => TextCount.Of(p.t))
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
        var current = Buffer;
        var elements = StringInfo.ParseCombiningCharacters(current);
        while (elements.Length > _maxBuffer)
        {
            _chars.RemoveRange(0, elements[1]);
            current = Buffer;
            elements = StringInfo.ParseCombiningCharacters(current);
        }
        foreach (var trigger in _triggers)
        {
            if (trigger.Length == 0) continue;
            if (current.EndsWith(trigger, StringComparison.Ordinal))
                return trigger;
        }
        return null;
    }
}
