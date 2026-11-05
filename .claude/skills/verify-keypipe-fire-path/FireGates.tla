----------------------------- MODULE FireGates -----------------------------
\* One key arriving at Engine.fire, through the gates and rule choice, and
\* stopping at the moment runAfterBusy would start. Erase, transform and output
\* are FireStages.tla. The matcher that produced this trigger is TriggerMatch.tla.
\*
\* Each action is one branch of Engine.fire (Sources/keypipe/Engine.swift).
\* A desktop fact the code reads is a separate enabled action, not a value
\* computed inside another step.

EXTENDS FiniteSets

VARIABLES
  kind,             \* "text" | "hotkey"     Engine.key vs Engine.hotkey
  focus,            \* Snapshot.focus       nothing | text | composing | terminal
  secure,           \* Snapshot.secure      password field; only with focus nothing
  phase,
  ruled,            \* "none" | "field" | "any"   the chosen rule's when.focus
  erased,           \* backspace(count > 0) was called
  shelled,          \* a transform or output shell ran
  result,           \* FireResult kind, coarsely
  reason,           \* blocked reason, or "" 
  shorterChosen,    \* a shorter trigger's rule was selected (the code never does this)
  sawUnreadable     \* a when/deny fact came back unreadable

vars == <<kind, focus, secure, phase, ruled, erased, shelled, result, reason,
          shorterChosen, sawUnreadable>>

Init ==
  /\ kind \in {"text", "hotkey"}
  /\ focus \in {"nothing", "text", "composing", "terminal"}
  /\ secure \in {TRUE, FALSE}
  /\ (secure => focus = "nothing")   \* MacDesktop.snapshot: secure returns focus nothing
  /\ phase = "arrive"
  /\ ruled = "none"
  /\ erased = FALSE
  /\ shelled = FALSE
  /\ result = "none"
  /\ reason = ""
  /\ shorterChosen = FALSE
  /\ sawUnreadable = FALSE

Stop(res, why) ==
  /\ phase' = "done"
  /\ result' = res
  /\ reason' = why
  /\ UNCHANGED <<kind, focus, secure, ruled, erased, shelled, shorterChosen, sawUnreadable>>

\* --- terminal filter (Engine.fire, before composing) ----------------------
\* A text trigger's candidates become empty. A hotkey keeps only focus-any
\* rules; if none remain, the same stop.

TerminalStop ==
  /\ phase = "arrive"
  /\ focus = "terminal"
  /\ kind = "text"
  /\ Stop("blocked", "terminal")

TerminalHotkeyStop ==
  /\ phase = "arrive"
  /\ focus = "terminal"
  /\ kind = "hotkey"
  /\ Stop("blocked", "terminal")

TerminalHotkeyPass ==
  /\ phase = "arrive"
  /\ focus = "terminal"
  /\ kind = "hotkey"
  /\ phase' = "pastTerminal"
  /\ UNCHANGED <<kind, focus, secure, ruled, erased, shelled, result, reason,
                shorterChosen, sawUnreadable>>

NotTerminal ==
  /\ phase = "arrive"
  /\ focus # "terminal"
  /\ phase' = "pastTerminal"
  /\ UNCHANGED <<kind, focus, secure, ruled, erased, shelled, result, reason,
                shorterChosen, sawUnreadable>>

\* --- composing, then secure (still before deny and before any field read) --

BlockComposing ==
  /\ phase = "pastTerminal"
  /\ focus = "composing"
  /\ Stop("blocked", "composing")

PassComposing ==
  /\ phase = "pastTerminal"
  /\ focus # "composing"
  /\ phase' = "pastCompose"
  /\ UNCHANGED <<kind, focus, secure, ruled, erased, shelled, result, reason,
                shorterChosen, sawUnreadable>>

BlockSecure ==
  /\ phase = "pastCompose"
  /\ secure
  /\ Stop("blocked", "secure")

PassSecure ==
  /\ phase = "pastCompose"
  /\ ~secure
  /\ phase' = "pastDeny"
  /\ UNCHANGED <<kind, focus, secure, ruled, erased, shelled, result, reason,
                shorterChosen, sawUnreadable>>

\* --- deny, then the candidates of THIS trigger only -------------------------
\* Three configs: an entry matches, an entry's fact is unreadable, or none match.
\* Unreadable stops the fire (fail closed). It does not try the next entry as
\* if it had not matched.

DenyMatch ==
  /\ phase = "pastDeny"
  /\ Stop("blocked", "deny")

DenyUnreadable ==
  /\ phase = "pastDeny"
  /\ sawUnreadable' = TRUE
  /\ phase' = "done"
  /\ result' = "unreadable"
  /\ reason' = "deny"
  /\ UNCHANGED <<kind, focus, secure, ruled, erased, shelled, shorterChosen>>

DenyClear ==
  /\ phase = "pastDeny"
  /\ phase' = "selecting"
  /\ UNCHANGED <<kind, focus, secure, ruled, erased, shelled, result, reason,
                shorterChosen, sawUnreadable>>

\* textField matches only when focus is text (evaluate). In a terminal the
\* candidates were already narrowed to focus any, and evaluate is not used.
MatchField ==
  /\ phase = "selecting"
  /\ focus = "text"
  /\ ruled' = "field"
  /\ phase' = "matched"
  /\ UNCHANGED <<kind, focus, secure, erased, shelled, result, reason,
                shorterChosen, sawUnreadable>>

MatchAny ==
  /\ phase = "selecting"
  /\ ruled' = "any"
  /\ phase' = "matched"
  /\ UNCHANGED <<kind, focus, secure, erased, shelled, result, reason,
                shorterChosen, sawUnreadable>>

\* First candidate's fact is unreadable: stop, even if a later candidate of the
\* same trigger would have matched.
UnreadableStops ==
  /\ phase = "selecting"
  /\ sawUnreadable' = TRUE
  /\ phase' = "done"
  /\ result' = "unreadable"
  /\ reason' = "when"
  /\ UNCHANGED <<kind, focus, secure, ruled, erased, shelled, shorterChosen>>

NoMatch ==
  /\ phase = "selecting"
  /\ Stop("nomatch", "")

\* The code never does this. fire() filters rules by the one trigger string the
\* matcher returned. A shorter trigger that also fits the keystrokes is not a
\* candidate. mutants.sh adds this action; Next does not.
SelectShorter ==
  /\ phase = "selecting"
  /\ shorterChosen' = TRUE
  /\ ruled' = "any"
  /\ phase' = "ready"
  /\ UNCHANGED <<kind, focus, secure, erased, shelled, result, reason, sawUnreadable>>

\* --- after a match, a slow fact (when.url) was maybe read -----------------
\* readSlow: look again. Another app, focus, password field, or field means
\* nothing is erased. No slow read: this re-check does not run (FrontStable).

FrontMoved ==
  /\ phase = "matched"
  /\ phase' = "done"
  /\ result' = "blocked"
  /\ reason' = "front-changed"
  /\ erased' = FALSE
  /\ UNCHANGED <<kind, focus, secure, ruled, shelled, shorterChosen, sawUnreadable>>

FrontStable ==
  /\ phase = "matched"
  /\ phase' = "ready"
  /\ UNCHANGED <<kind, focus, secure, ruled, erased, shelled, result, reason,
                shorterChosen, sawUnreadable>>

Rest ==
  /\ phase \in {"done", "ready"}
  /\ UNCHANGED vars

Next ==
  \/ TerminalStop \/ TerminalHotkeyStop \/ TerminalHotkeyPass \/ NotTerminal
  \/ BlockComposing \/ PassComposing
  \/ BlockSecure \/ PassSecure
  \/ DenyMatch \/ DenyUnreadable \/ DenyClear
  \/ MatchField \/ MatchAny \/ UnreadableStops \/ NoMatch
  \/ FrontMoved \/ FrontStable
  \/ Rest

Spec == Init /\ [][Next]_vars

\* IME composition is never erased and never handed to a shell.
ComposingStops ==
  (focus = "composing") =>
    /\ phase \in {"arrive", "pastTerminal", "done"}
    /\ (phase = "done" => reason = "composing" /\ result = "blocked")
    /\ ~erased /\ ~shelled

\* A password field is never erased and never handed to a shell.
SecureStops ==
  secure =>
    /\ phase \in {"arrive", "pastTerminal", "pastCompose", "done"}
    /\ (phase = "done" => reason = "secure" /\ result = "blocked")
    /\ ~erased /\ ~shelled

\* A typed trigger in a terminal does not run. (A hotkey may; see TerminalHotkeyPass.)
TerminalTextStops ==
  (focus = "terminal" /\ kind = "text") =>
    /\ phase \in {"arrive", "done"}
    /\ (phase = "done" => reason = "terminal" /\ result = "blocked")
    /\ ~erased /\ ~shelled

\* An unreadable fact does not become the next rule.
UnreadableNeverFallsThrough ==
  sawUnreadable =>
    (phase = "done" /\ result = "unreadable" /\ ~erased /\ ~shelled)

\* The front moved during a slow read: nothing is erased or run.
FrontChangedDoesNotErase ==
  reason = "front-changed" =>
    (phase = "done" /\ result = "blocked" /\ ~erased /\ ~shelled)

\* No shorter trigger is substituted when this trigger's rules do not hold.
NeverShorter == ~shorterChosen

\* No rule held: nothing is erased or run.
NoMatchDoesNotAct ==
  result = "nomatch" => (phase = "done" /\ ~erased /\ ~shelled)

=============================================================================
