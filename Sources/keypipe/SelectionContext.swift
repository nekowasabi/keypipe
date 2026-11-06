import Foundation

/// What one Cmd+C of a selection left on the pasteboard, read at the boundary.
struct SelectionCopy {
    var app: String?
    var text: String
    var html: String?
    /// `org.chromium.source-url`: the page the copy came from (Chromium only).
    var sourceURL: String?
}

/// The lines appended after the selected text: links hidden behind the text, then the page.
/// Empty when there is nothing to add. `axLinks` and `tabURL` are slow, so they run only when
/// the copy cannot answer: Slack in Chrome replaces the copy with plain text (seen 2026-11-06).
func selectionContext(
    _ copy: SelectionCopy, axLinks: () -> [String], tabURL: () -> String?
) -> String {
    let fromHTML = copy.html.map(hrefs) ?? []
    let candidates = copy.html == nil ? axLinks() : fromHTML
    var seen = Set<String>()
    let links = candidates.filter { url in
        url.hasPrefix("http") && !copy.text.contains(url) && seen.insert(url).inserted
    }
    var lines = links.map { "リンク: \($0)" }
    // Why: a desktop app's source-url (Electron) is its own shell page, not the page the text is on.
    if let app = copy.app, chromiumBrowsers.contains(app) || safariBrowsers.contains(app),
        let page = copy.sourceURL ?? tabURL()
    {
        lines.append("ページ: \(page)")
    }
    return lines.joined(separator: "\n")
}

/// The href of every anchor in a pasteboard HTML fragment, in order, entities decoded.
func hrefs(_ html: String) -> [String] {
    let pattern = #"<a\b[^>]*?\bhref\s*=\s*(?:"([^"]*)"|'([^']*)')"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else { return [] }
    let whole = NSRange(html.startIndex..., in: html)
    return regex.matches(in: html, range: whole).compactMap { match in
        let group = match.range(at: 1).location != NSNotFound ? 1 : 2
        guard let range = Range(match.range(at: group), in: html) else { return nil }
        return html[range]
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
