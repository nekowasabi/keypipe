---
name: verify-keypipe-selection-context
description: Feasibility and planned checks for carrying link context out of a text selection in keypipe's selection send (shell/selection-prompt.sh, used by the herdr-claude and grokbot rules and `keypipe --rule herdr-claude`) - URLs inside the selection, links hidden behind text via the copy's public.html (web pages) or Accessibility (Slack in Chrome, which copies plain text only), and the browser page URL via org.chromium.source-url or frontTabURLScript. Model-checks docs/design/statechart/SelectionCapture.tla with TLC (today's script vs the planned design) and probes the real pasteboard after a Cmd+C. Use before implementing selection link/URL context, after touching shell/selection-prompt.sh or frontTabURLScript in Sources/keypipe/MacDesktop.swift, or before claiming a hidden link or the page URL reaches the prompt.
---

# verify-keypipe-selection-context

The selection send copies the selection with Cmd+C and reads it back with `pbpaste`. `pbpaste`
returns plain text only. A link shown as text (Slack's 「こちら」, a web page's anchor) keeps its
URL only in the copy's HTML, so today the prompt loses it. The prompt also never says which page
the text came from. This skill records what the Mac makes possible (F items, checked on a real
Mac) and what an implementation must keep (I items, model-checked now and run against the real
code once it exists).

## Feasibility (F): what the Mac gives after Cmd+C

Checked on 2026-11-06 with a real Cmd+C from System Events, as selection-prompt.sh sends it,
on a test page with one anchor (「こちらのPR」 → a GitHub URL) and one bare URL.

| ID | Question | Result | Evidence |
|----|----------|--------|----------|
| F1 | Is a URL written in the selected text available? | Yes. It stays in `public.utf8-plain-text`, which is what `pbpaste` already returns; only extraction is missing. | Chrome: the plain text kept `https://example.com/plain` |
| F2 | Is a link hidden behind text available? | Yes in Chrome: `public.html` holds `<a href="https://github.com/...">こちらのPR</a>`. Not with `pbpaste`: the plain text has 「こちらのPR」 only. Needs a typed read (NSPasteboard). | Chrome 2026-11-06 |
| F3 | Same in Slack opened in Chrome (app.slack.com)? | Not through the clipboard: a Cmd+C in Slack's Chrome tab on 2026-11-06 left `public.utf8-plain-text` only (no `public.html`, and no `org.chromium.source-url` either). Slack replaces the copy with its own plain text. The page URL still comes from `frontTabURLScript` (I3). | user's probe.js run |
| F7 | Can Accessibility name the links under a selection instead? | Yes in Chrome on the test page: order AXSelectedTextMarkerRange with AXTextMarkerRangeForUnorderedTextMarkers, walk it with AXNextTextMarkerForTextMarker (about one marker per character), and climb from each AXUIElementForTextMarker to an enclosing AXLink for its AXURL; it printed the anchor's GitHub URL. Two shortcuts fail in Chrome: the attributed string has no AXLink attribute, and comparing link and selection ranges by AXIndexForTextMarker gave Slack's 9-character selection the span 4..0 (19 links on the page, none matched). On Slack's page (Chrome, 2026-11-06) the marker walk worked: a 9-character selection over a hyperlinked word gave 11 markers, roles AXGroup/AXLink/AXList/AXStaticText, and the hidden URL `https://www.yahoo.co.jp/`. Needs only the Accessibility permission keypipe already has. | `probe-ax.swift` 2026-11-06 |
| F8 | Slack desktop app (Electron)? | 未検証; not the user's setup. Expected like F3. | — |
| F4 | Same in Safari? | 未検証. No attempt copied from the page: after Cmd+R the copy was the address bar's URL as text (`public.url`), and after Tab, Cmd+A, Cmd+C the clipboard stayed empty (the keystrokes never reached the page). Safari is not expected to write `org.chromium.source-url`; the page URL must come from `frontTabURLScript` (I3). | run the probe below |
| F5 | Is the browser page URL available? | Yes, two ways. (a) `org.chromium.source-url` on the copy, Chromium only, no permission, the page at copy time. (b) `frontTabURLScript` (`URL of active tab of front window` / `URL of front document`), which keypipe already uses for `when.url`; slow and needs Automation permission for the browser. Both returned the test page URL. | Chrome 2026-11-06 |
| F6 | Can the probe read everything without changing the clipboard? | Yes: `NSPasteboard.generalPasteboard` from `osascript -l JavaScript` lists types and strings read-only. | probe.js |

Verdict: feasible for URLs in the text (F1), hidden links on ordinary pages (F2) and the page
URL (F5). Hidden links in Slack need the Accessibility route (F7), seen working on a test page
and on Slack in Chrome.

### Running the probe (F3, F4, or any new app)

1. In the app, select text that contains a link shown as words (in Slack, a message with a
   hyperlink; in Safari, a paragraph with an anchor) and press Cmd+C.
2. Run `osascript -l JavaScript .claude/skills/verify-keypipe-selection-context/probe.js`.
3. Expected: `public.html: yes` and the URL under `hidden links`. `org.chromium.source-url` is
   the page for a browser, and for Slack is whatever Electron writes; write down which.
4. For the Accessibility route (F7): select the text in the Slack tab, then in a terminal run
   `sleep 5; swift .claude/skills/verify-keypipe-selection-context/probe-ax.swift` and switch
   to Chrome with Cmd+Tab within the 5 s, leaving the Slack tab in front (a click can clear the
   selection). Expected: `link urls:` lists the hidden URL. Pass a bundle id for another app
   (`com.tinyspeck.slackmacgap` for Slack desktop). It prints counts, attribute names and URLs,
   never the text.
5. Put the result in the F table with the date and the app version. The probe prints types and
   URLs only, but `urls in plain text` comes from the copy, so do not paste output from private
   messages anywhere public.

## Planned checks (I): what an implementation must keep

The model is `docs/design/statechart/SelectionCapture.tla`. `After = FALSE` is today's script,
`After = TRUE` the planned design. Each I item is an invariant there, and becomes a case in
check.sh's real-code stage when the code exists (see "When implementing").

| ID | Property (one sentence) | Invariant | Today | Harm when broken |
|----|-------------------------|-----------|-------|------------------|
| I1 | The prompt's text is the copy's plain text, unchanged; links are added after it, never by pasting raw HTML. | (real-code only) | holds | Claude Code gets `<span style=...>` markup instead of the sentence. |
| I2 | Every link under the selection whose URL is not already in the text reaches the prompt: from the copy's `public.html`, else from Accessibility (F7). | HrefNeverDropped | breaks | 「こちら」 is sent without where it points (always, in Slack). |
| I3 | With a browser in front, the prompt names the page: `org.chromium.source-url` if the copy has it, else `frontTabURLScript`; an unreadable tab URL sends the prompt without it and says so on stderr, never fails the send. | BrowserUrlAttached | breaks | Claude cannot tell which page the text is from; or a denied Automation prompt loses the selection. |
| I4 | A page URL is attached only when the front app is a browser (the bundle ids in `frontTabURLScript`); a desktop app's source-url (Electron) is not a page. Slack in Chrome is a browser page and gets its tab URL. | PageUrlOnlyFromBrowser | holds (nothing attached) | `https://app.slack.com/client/...` is sent as "the page". |
| I5 | The old clipboard comes back with every type it had (images, rich text), on success and after a failed Cmd+C. | OldClipboardRestored | breaks | A copied image is gone after one send (today's known gap in verify-keypipe-failure-report "Not covered"). |
| I6 | A failed Cmd+C still exits 1 and is never sent as an empty selection. | FailedCopyNotSent | holds | Kept from verify-keypipe-failure-report P5. |

Decisions the model fixes, so an implementer does not reopen them: the source-url wins over the
tab URL, because it is the page at copy time and the tab can change before the read; a tab URL
that cannot be read is not a failure of the send.

## How to run

```sh
sh .claude/skills/verify-keypipe-selection-context/check.sh   # under a minute, exit 0 = all verdicts as expected
```

It installs TLC 1.7.4 and Java with mise on first use, then checks: after = all invariants hold;
before = I2, I3, I5 break and I4, I6 hold (today's script, so a pass here means the model still
describes it); mutants M1 (attach source-url for any app), M2 (no tab-URL fallback) and M3 (no
Accessibility read when the copy has no HTML) must break I4, I3 and I2. Each line prints `ok` or `FAIL ... expected X, got Y` followed by TLC's trace.

Read every result, pass or fail, with the `/statechart` skill on
`docs/design/statechart/SelectionCapture.tla` with `selection-before.cfg` or `selection-after.cfg`
and the view `docs/design/statechart/selection-view.mjs`. It tells each break as its shortest path
and redraws `selection-before.mmd` / `selection-after.mmd`; copy its report over
`selection-*-report.md` when the model changes.

## Bounds and assumptions

- One run, four front apps (Chrome, which includes Slack's tab; Safari; Slack desktop; an app
  that copies plain text only), the selection with or without a hidden link, an old clipboard
  with or without non-text content, Cmd+C landing or failing, Accessibility naming the links or
  not, the tab URL readable, absent or unreadable. 496 states.
- What each app writes is an assumption: Chrome gives HTML + source-url or, when the page
  replaces the copy (Slack), neither (F2, F3, F5); Slack desktop and Safari may write any
  combination until F4/F8 are probed. When a probe settles one, narrow its CASE in CopyLands and
  rerun.
- The lock, two racing sends, voice-switch's `open -b`, the dictation, and how the prompt is
  delivered are not modelled: verify-keypipe-failure-report checks those on the real script.

## Not covered

- The real code: there is no implementation yet. The model checks the design, not
  selection-prompt.sh's future lines.
- Slack's private pasteboard types, and whether Slack's mentions and channel links show up as
  AXLink elements with a usable AXURL.
- Apps that copy rich text only as RTF (`public.rtf`) without HTML; the design reads HTML only.
- The user switching tabs within the fraction of a second between copy and a tab-URL read
  (only on the fallback path, Safari).

## When implementing

1. Put the typed read where the clipboard is read today (selection-prompt.sh, `old=` and
   `selection=`); it can be a `keypipe` mode or an `osascript -l JavaScript` helper. A new mode goes
   into `modes` in the single parse in `Sources/keypipe/main.swift` (CLAUDE.md rule table). The
   Accessibility link search (F7) needs AX calls, so it belongs in keypipe (MacDesktop.swift)
   rather than a script; `probe-ax.swift` is the working reference.
2. Add a real-code stage to check.sh in the style of verify-keypipe-failure-report: stub
   `osascript`'s keystroke, write fixed types to a test pasteboard, run the script, compare the
   prompt. One case per I item, including Slack's source-url (I4) and an image old clipboard (I5).
3. Break each I item in the real code once (drop the href step, attach source-url for Slack, skip
   the fallback, restore text only) and see the stage go red, then record it below.
4. Update verify-keypipe-failure-report's P2 expected prompt shape and its "Not covered" line on
   non-text clipboards in the same change.

## Real bug or modeling error

Before the implementation, a FAIL on `before` means the script changed: read the diff of
shell/selection-prompt.sh and change the model's today-branch to match it. A FAIL on `after` or a
mutant means the model changed: say which property is meant to change and why, here first. Never
loosen an invariant to get a pass; a property that changes must be seen failing on the old design.

## Proved able to fail (2026-11-06)

- before (today's script): I2, I3, I5 break with 5-, 5- and 4-step paths
  (`docs/design/statechart/selection-before-report.md`).
- M1 source-url attached for any app: I4 breaks. M2 no tab-URL fallback: I3 breaks. M3 no
  Accessibility read: I2 breaks.
- Following this skill on a scratch break of the planned design (Restore brings back text only
  even when After): check.sh printed `FAIL after (all): expected PASS, got OldClipboardRestored`;
  restoring the file gave `ALL PASS`.

## Coverage record

Last confirmed that the model describes the code at commit `fdafbec` (2026-11-06).

| Check | Covers |
|-------|--------|
| before branch of SelectionCapture.tla | all of `shell/selection-prompt.sh` |
| F5, I3, I4 | `frontTabURLScript`, `chromiumBrowsers` and `safariBrowsers` in `Sources/keypipe/MacDesktop.swift` |

To see whether the covered code moved since then:

```sh
git log --oneline fdafbec..HEAD -- shell/selection-prompt.sh Sources/keypipe/MacDesktop.swift
```

Move the commit forward only after you have read the changed lines, confirmed that the model and
the F table still describe them, and check.sh passes at the new commit. For bringing it back in
line after changes that skipped this, use `/maintain-formal-verification-skill`.
