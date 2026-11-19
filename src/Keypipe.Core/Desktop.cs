namespace Keypipe.Core;

public enum FiredStatus { Ok, Failed, Started }

public sealed record FiredEvent(Trigger Trigger, string Label, FiredStatus Status, string? Stage, string? Icon);

public interface IDesktop
{
    Snapshot Snapshot();
    void Backspace(int count);
    string? GetText(Field field);
    bool SetText(Field field, string text);
    void Notify(string text);
    FactRead GetFact(FactName name);
    bool TypeText(string text);
    bool SameField(Field a, Field b);
    void ShowBusy(Field? near);
    void HideBusy();
    void ShowFired(FiredEvent evt);
}

public abstract class DesktopBase : IDesktop
{
    public abstract Snapshot Snapshot();
    public abstract void Backspace(int count);
    public abstract string? GetText(Field field);
    public abstract bool SetText(Field field, string text);
    public abstract void Notify(string text);

    public virtual FactRead GetFact(FactName name) => FactRead.Absent.Instance;
    public virtual bool TypeText(string text) => false;
    public virtual bool SameField(Field a, Field b) => a == b;
    public virtual void ShowBusy(Field? near) { }
    public virtual void HideBusy() { }
    public virtual void ShowFired(FiredEvent evt) { }
}
