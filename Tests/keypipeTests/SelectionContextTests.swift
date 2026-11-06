import XCTest

@testable import keypipe

final class SelectionContextTests: XCTestCase {
    private let pr = "https://github.com/nekowasabi/keypipe/pull/14"
    private let text = "詳細はこちらのPR。素のURL https://example.com/plain"

    private func context(
        _ copy: SelectionCopy, ax: [String] = [], tab: String? = nil
    ) -> (String, axAsked: Bool, tabAsked: Bool) {
        var axAsked = false
        var tabAsked = false
        let out = selectionContext(
            copy,
            axLinks: {
                axAsked = true
                return ax
            },
            tabURL: {
                tabAsked = true
                return tab
            })
        return (out, axAsked, tabAsked)
    }

    func testChromeCopyGivesTheHiddenLinkAndTheSourcePageWithoutSlowReads() {
        let html = #"<span>詳細は</span><a href="\#(pr)">こちらのPR</a>。素のURL https://example.com/plain"#
        let copy = SelectionCopy(
            app: "com.google.Chrome", text: text, html: html, sourceURL: "https://a.test/page")
        let (out, axAsked, tabAsked) = context(
            copy, ax: ["https://never.test/"], tab: "https://tab.test/")
        XCTAssertEqual(out, "リンク: \(pr)\nページ: https://a.test/page")
        XCTAssertFalse(axAsked)
        XCTAssertFalse(tabAsked)
    }

    func testSlackInChromeFallsBackToAccessibilityAndTheTab() {
        let slack = "https://app.slack.com/client/T1/C2"
        let copy = SelectionCopy(app: "com.google.Chrome", text: "ヤフー", html: nil)
        let yahoo = "https://www.yahoo.co.jp/"
        XCTAssertEqual(
            context(copy, ax: [yahoo, yahoo], tab: slack).0, "リンク: \(yahoo)\nページ: \(slack)")
    }

    func testAURLAlreadyInTheTextIsNotRepeated() {
        let url = "https://example.com/plain"
        let html = #"<a href="\#(url)">\#(url)</a>"#
        let copy = SelectionCopy(app: "com.example.Editor", text: url, html: html)
        XCTAssertEqual(context(copy).0, "")
    }

    func testADesktopAppNeverGetsAPageEvenWithASourceURL() {
        let copy = SelectionCopy(
            app: "com.tinyspeck.slackmacgap", text: "x", html: nil,
            sourceURL: "https://app.slack.com/client")
        let (out, _, tabAsked) = context(copy, tab: "https://tab.test/")
        XCTAssertEqual(out, "")
        XCTAssertFalse(tabAsked)
    }

    func testNonWebLinksAreDropped() {
        let html =
            #"<a href="mailto:a@b.test">a</a><a href='javascript:void(0)'>b</a>"#
            + #"<a href="https://x.test/?a=1&amp;b=2">c</a>"#
        let copy = SelectionCopy(app: nil, text: "abc", html: html)
        XCTAssertEqual(context(copy).0, "リンク: https://x.test/?a=1&b=2")
    }
}
