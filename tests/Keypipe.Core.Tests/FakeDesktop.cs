using Keypipe.Core;

namespace Keypipe.Core.Tests;

public sealed class FakeDesktop : DesktopBase
{
    private readonly string? _app;
    private readonly Focus _focus;
    private readonly bool _ignoresBackspace;
    private readonly bool _backspacePerRead;
    private readonly bool _keysPerRead;
    private readonly bool _ignoresWrite;
    private readonly bool _goneAfterErase;
    private readonly bool _writePerRead;
    private readonly bool _secure;
    private readonly Dictionary<FactName, FactRead> _facts;
    private readonly string? _appAfterSlowRead;
    private string? _pendingWrite;
    private bool _erased;
    private bool _gone;
    private int _pendingBackspaces;
    private readonly Queue<char> _pendingKeys = new();

    public string FieldText { get; private set; }
    public int TextReads { get; private set; }
    public List<string> Notifications { get; } = new();
    public List<bool> Busy { get; } = new();
    public List<FiredEvent> Fired { get; } = new();
    public List<string> Windows { get; } = new();
    public List<FactName> Reads { get; } = new();

    public FakeDesktop(
        string? app = null,
        Focus focus = Focus.Nothing,
        string fieldText = "",
        bool ignoresBackspace = false,
        bool backspacePerRead = false,
        bool keysPerRead = false,
        bool ignoresWrite = false,
        bool goneAfterErase = false,
        bool writePerRead = false,
        bool secure = false,
        Dictionary<FactName, FactRead>? facts = null,
        string? appAfterSlowRead = null)
    {
        _app = app;
        _focus = focus;
        FieldText = fieldText;
        _ignoresBackspace = ignoresBackspace;
        _backspacePerRead = backspacePerRead;
        _keysPerRead = keysPerRead;
        _ignoresWrite = ignoresWrite;
        _goneAfterErase = goneAfterErase;
        _writePerRead = writePerRead;
        _secure = secure;
        _facts = facts ?? new Dictionary<FactName, FactRead>();
        _appAfterSlowRead = appAfterSlowRead;
    }

    public void Key(char character)
    {
        if (_keysPerRead && _focus == Focus.Text)
            _pendingKeys.Enqueue(character);
        else
            FieldText += character;
    }

    public override Snapshot Snapshot()
    {
        bool slowRead = Reads.Any(f => FactNames.Cost(f) == FactCost.Slow);
        return new Snapshot(
            slowRead ? (_appAfterSlowRead ?? _app) : _app,
            _focus,
            _focus == Focus.Text ? new Field(0) : null,
            _secure);
    }

    public override bool TypeText(string text)
    {
        if (_secure || _gone) return false;
        if (_focus != Focus.Text && _focus != Focus.Terminal) return false;
        if (_focus == Focus.Text) FieldText += text;
        return true;
    }

    public override FactRead GetFact(FactName name)
    {
        Reads.Add(name);
        return _facts.TryGetValue(name, out var read) ? read : FactRead.Absent.Instance;
    }

    public override void Backspace(int count)
    {
        _erased = true;
        if (_ignoresBackspace) return;
        if (_backspacePerRead)
        {
            _pendingBackspaces += count;
        }
        else
        {
            FieldText = RemoveLastTextElements(FieldText, count);
        }
    }

    // A Backspace count is a count of characters (text elements), matching
    // Swift FakeDesktop.backspace's removeLast(count) on a String.
    internal static string RemoveLastTextElements(string text, int count)
    {
        if (count <= 0 || text.Length == 0) return text;
        var elements = System.Globalization.StringInfo.ParseCombiningCharacters(text);
        if (elements.Length == 0) return text;
        if (count >= elements.Length) return "";
        return text.Substring(0, elements[elements.Length - count]);
    }

    public override string? GetText(Field field)
    {
        TextReads += 1;
        if (field.Token != 0 || _focus != Focus.Text || _gone) return null;
        try
        {
            if (_pendingKeys.Count > 0) FieldText += _pendingKeys.Dequeue();
            if (_pendingBackspaces > 0)
            {
                _pendingBackspaces -= 1;
                if (FieldText.Length > 0) FieldText = RemoveLastTextElements(FieldText, 1);
            }
            return FieldText;
        }
        finally
        {
            if (_pendingWrite is string pending)
            {
                FieldText = pending;
                _pendingWrite = null;
            }
        }
    }

    public override bool SetText(Field field, string text)
    {
        if (field.Token != 0 || _focus != Focus.Text || _gone) return false;
        if (_goneAfterErase && _erased)
        {
            _gone = true;
            return false;
        }
        if (_ignoresWrite) return true;
        if (_writePerRead) _pendingWrite = text;
        else FieldText = text;
        return true;
    }

    public override void Notify(string text) => Notifications.Add(text);

    public override void ShowBusy(Field? near)
    {
        Busy.Add(true);
        Windows.Add("spin");
    }

    public override void HideBusy()
    {
        Busy.Add(false);
        Windows.Add("unspin");
    }

    public override void ShowFired(FiredEvent evt)
    {
        Fired.Add(evt);
        Windows.Add("pill");
    }
}

public sealed class LineDesktop : DesktopBase
{
    private readonly string? _app;
    public string? Line { get; private set; }

    public LineDesktop(string? app, string? line)
    {
        _app = app;
        Line = line;
    }

    public override Snapshot Snapshot() => new(
        _app,
        Line is null ? Focus.Nothing : Focus.Text,
        Line is null ? null : new Field(0));

    public override void Backspace(int count)
        => Line = Line is null ? null : FakeDesktop.RemoveLastTextElements(Line, count);

    public override string? GetText(Field field) => Line;

    public override bool SetText(Field field, string text)
    {
        if (Line is null) return false;
        Line = text;
        return true;
    }

    public override void Notify(string text) { }
}
