using System.Text.Json;

namespace Keypipe.Core;

public static class FireResultReport
{
    public static string ToReportJson(this FireResult result)
    {
        var o = new SortedDictionary<string, object?>();
        o["v"] = 1;
        switch (result)
        {
            case FireResult.Blocked b:
                o["outcome"] = "blocked"; o["reason"] = b.Reason; break;
            case FireResult.NoMatch:
                o["outcome"] = "nomatch"; break;
            case FireResult.Unreadable u:
                o["outcome"] = "unreadable"; o["fact"] = u.Fact; o["reason"] = u.Reason; break;
            case FireResult.NoInput n:
                o["outcome"] = "noinput"; o["rule"] = n.Rule; break;
            case FireResult.Replaced r:
                o["outcome"] = "replaced"; o["rule"] = r.Rule; o["text"] = r.Text;
                if (r.ViaFallback) o["fallback"] = true;
                break;
            case FireResult.Delivered d:
                o["outcome"] = "delivered"; o["rule"] = d.Rule;
                if (d.ViaFallback) o["fallback"] = true;
                break;
            case FireResult.Started s:
                o["outcome"] = "started"; o["rule"] = s.Rule; break;
            case FireResult.Failed f:
                o["outcome"] = "failed"; o["rule"] = f.Rule; o["stage"] = f.Stage; o["failure"] = f.Failure; break;
            default: throw new InvalidOperationException();
        }
        return JsonSerializer.Serialize(o, new JsonSerializerOptions
        {
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        });
    }
}
