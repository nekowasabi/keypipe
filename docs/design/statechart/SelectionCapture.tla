-------------------------- MODULE SelectionCapture --------------------------
\* One run of shell/selection-prompt.sh (the hotkey rules herdr-claude and
\* grokbot, and `keypipe --rule herdr-claude` from voice-switch): take the lock,
\* save the old clipboard, clear it, send Cmd+C to the front app, read what the
\* copy left, put the old clipboard back, print the prompt.
\*
\* After = FALSE: the script today. It reads the copy with pbpaste (plain text
\*                only) and puts the old clipboard back with pbcopy (text only).
\* After = TRUE:  the planned design (I1-I6 in
\*                .claude/skills/verify-keypipe-selection-context/SKILL.md): read
\*                the copy's typed items (public.html, public.utf8-plain-text,
\*                org.chromium.source-url), and when the copy has no HTML ask
\*                Accessibility for the links under the selection; keep every
\*                href, attach the page URL only when a browser is in front, and
\*                restore every type.
\*
\* What each front app puts on the pasteboard was seen on this Mac on
\* 2026-11-06: a plain Chrome page gives public.html + plain +
\* org.chromium.source-url; Slack opened in Chrome replaces the copy with plain
\* text only (its own copy handler), so "chrome" may give either. Slack desktop
\* and Safari are 未検証 (F3, F4): the model lets them put any of the sets.

EXTENDS Naturals

CONSTANT After

Fronts == {"chrome", "safari", "slack", "plainApp"}
Browsers == {"chrome", "safari"}

VARIABLES
    front,      \* the app the selection is in
    hasLink,    \* the selection holds a link whose href is not in its text
    oldRich,    \* the old clipboard holds more than text (an image, rich text)
    phase,
    copyOk,     \* Cmd+C reached the app (osascript exit 0)
    pbHtml,     \* the copy left public.html (with <a href>)
    pbSource,   \* the copy left org.chromium.source-url
    tabUrl,     \* frontTabURLScript's answer: "value" / "absent" / "unreadable"
    axAvail,    \* Accessibility would return the links under the selection
    hrefKept,   \* the printed prompt carries the hidden href
    pageUrl,    \* the page URL in the prompt: "none" / "source" / "tab"
    restored,   \* the old clipboard came back: "none" / "text" / "full"
    result      \* "none" / "sent" / "failed"

vars == <<front, hasLink, oldRich, phase, copyOk, pbHtml, pbSource, tabUrl,
          axAvail, hrefKept, pageUrl, restored, result>>

Init ==
    /\ front \in Fronts
    /\ hasLink \in BOOLEAN
    /\ oldRich \in BOOLEAN
    /\ phase = "start"
    /\ copyOk = FALSE
    /\ pbHtml = FALSE
    /\ pbSource = FALSE
    /\ tabUrl = "absent"
    /\ axAvail = FALSE
    /\ hrefKept = FALSE
    /\ pageUrl = "none"
    /\ restored = "none"
    /\ result = "none"

\* mkdir lock, then old=$(pbpaste) and `printf '' | pbcopy`.
LockSaveClear ==
    /\ phase = "start"
    /\ phase' = "cleared"
    /\ UNCHANGED <<front, hasLink, oldRich, copyOk, pbHtml, pbSource, tabUrl, axAvail,
                   hrefKept, pageUrl, restored, result>>

\* osascript keystroke "c" using command down. What lands depends on the app.
\* Chrome (seen): html + source-url, or plain text only when the page replaces
\* the copy (Slack in Chrome). Slack desktop (Electron, 未検証) and Safari
\* (未検証): any combination. plainApp: plain text only. Whether Accessibility
\* would name the links under the selection is decided here too: seen working in
\* Chrome on a test page (probe-ax.swift); 未検証 on Slack's page and elsewhere.
CopyLands ==
    /\ phase = "cleared"
    /\ copyOk' = TRUE
    /\ \E h \in BOOLEAN, s \in BOOLEAN, a \in BOOLEAN :
         /\ pbHtml' = CASE front = "plainApp" -> FALSE
                        [] OTHER              -> h
         /\ pbSource' = CASE front = "chrome"   -> h
                          [] front = "plainApp" -> FALSE
                          [] front = "safari"   -> FALSE
                          [] OTHER              -> s
         /\ axAvail' = (front # "plainApp" /\ a)
    /\ phase' = "copied"
    /\ UNCHANGED <<front, hasLink, oldRich, tabUrl, hrefKept, pageUrl, restored, result>>

CopyFails ==
    /\ phase = "cleared"
    /\ copyOk' = FALSE
    /\ phase' = "copied"
    /\ UNCHANGED <<front, hasLink, oldRich, pbHtml, pbSource, tabUrl, axAvail, hrefKept,
                   pageUrl, restored, result>>

\* Read the copy. Today: selection=$(pbpaste), nothing else.
\* Planned: the typed items; the links from Accessibility when there is no HTML;
\* the tab URL when a browser gave no source-url.
ReadCopy ==
    /\ phase = "copied"
    /\ copyOk
    /\ IF After
         THEN /\ hrefKept' = (hasLink /\ (pbHtml \/ axAvail))
              /\ \E t \in {"value", "absent", "unreadable"} :
                   /\ tabUrl' = IF front \in Browsers /\ ~pbSource THEN t ELSE "absent"
                   /\ pageUrl' = CASE front \notin Browsers -> "none"
                                   [] pbSource              -> "source"
                                   [] t = "value"           -> "tab"
                                   [] OTHER                 -> "none"
         ELSE /\ hrefKept' = FALSE
              /\ tabUrl' = tabUrl
              /\ pageUrl' = "none"
    /\ phase' = "read"
    /\ UNCHANGED <<front, hasLink, oldRich, copyOk, pbHtml, pbSource, axAvail, restored, result>>

\* printf '%s' "$old" | pbcopy. Today only the text comes back.
Restore ==
    /\ \/ phase = "read"
       \/ (phase = "copied" /\ ~copyOk)
    /\ restored' = IF After \/ ~oldRich THEN "full" ELSE "text"
    /\ phase' = "restored"
    /\ UNCHANGED <<front, hasLink, oldRich, copyOk, pbHtml, pbSource, tabUrl, axAvail,
                   hrefKept, pageUrl, result>>

\* Exit 1 on a failed copy (verify-keypipe-failure-report P5), else print.
Emit ==
    /\ phase = "restored"
    /\ result' = IF copyOk THEN "sent" ELSE "failed"
    /\ phase' = "done"
    /\ UNCHANGED <<front, hasLink, oldRich, copyOk, pbHtml, pbSource, tabUrl, axAvail,
                   hrefKept, pageUrl, restored>>

Done == phase = "done" /\ UNCHANGED vars

Next ==
    \/ LockSaveClear
    \/ CopyLands \/ CopyFails
    \/ ReadCopy
    \/ Restore
    \/ Emit
    \/ Done

Spec == Init /\ [][Next]_vars

\* I2: a link the copy's public.html or Accessibility can name is never dropped.
HrefNeverDropped ==
    (phase = "done" /\ result = "sent" /\ hasLink /\ (pbHtml \/ axAvail)) => hrefKept

\* I3: with a browser in front, the prompt names the page whenever it can be known.
BrowserUrlAttached ==
    (phase = "done" /\ result = "sent" /\ front \in Browsers
        /\ (pbSource \/ tabUrl = "value")) => pageUrl # "none"

\* I4: only a browser's page counts as "the page" (Slack's source-url is its app shell).
PageUrlOnlyFromBrowser == pageUrl # "none" => front \in Browsers

\* I5: the old clipboard comes back whole, rich content too, even after a failed copy.
OldClipboardRestored == phase = "done" => restored = "full"

\* Kept from today: a failed Cmd+C is never sent as if nothing was selected.
FailedCopyNotSent == (phase = "done" /\ ~copyOk) => result = "failed"

=============================================================================
