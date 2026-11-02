---------------------------- MODULE KeypipeFire ----------------------------
\* One keypipe fire, from a trigger arriving to a result, with two rules on the
\* same trigger: rule 0 = "URL rule" (when.app browser + when.url github, output
\* replaceInput), rule 1 = catch-all (focus textField, output chosen at run time).
\*
\* After = FALSE: the pre-review design (candidate-2 sketch as first written, on
\*                top of today's code): no secure gate, an unreadable fact counts
\*                as "did not match", typeText on the --line desktop reports a
\*                success, a failed background spawn reports "started".
\* After = TRUE:  the decided design (docs/design/extension-architecture.md,
\*                decisions of 2026-11-01).
\* The invariants are the planned checks P2, P5, P6, P10 of verify-keypipe-trigger.

EXTENDS Naturals

CONSTANT After

Fronts == {"editor", "browser", "terminal", "secureField", "composing"}
Paths == {"key", "line"}

VARIABLES front, path, phase, rule, url, out, spawnOk, fieldRead, result

vars == <<front, path, phase, rule, url, out, spawnOk, fieldRead, result>>

Init ==
    /\ front \in Fronts
    /\ path \in Paths
    /\ phase = "start"
    /\ rule = "none"
    /\ url = "unknown"
    /\ out = "none"
    /\ spawnOk = TRUE
    /\ fieldRead = FALSE
    /\ result = "none"

\* Gates, evaluated before any rule and before the field is read.
GateBlocks ==
    /\ phase = "start"
    /\ \/ front = "composing"
       \/ front = "terminal"
       \/ (After /\ front = "secureField")
    /\ result' = "blocked"
    /\ phase' = "done"
    /\ UNCHANGED <<front, path, rule, url, out, spawnOk, fieldRead>>

GatePasses ==
    /\ phase = "start"
    /\ front \notin {"composing", "terminal"}
    /\ ~(After /\ front = "secureField")
    /\ phase' = "select"
    /\ UNCHANGED <<front, path, rule, url, out, spawnOk, fieldRead, result>>

\* Rule selection. The URL rule is a candidate only when a browser is in front;
\* its url fact is read lazily here and can be ok / not github / unreadable.
\* On the --line path (zsh, voice) the decided design reads no live fact.
SelectUrlRule ==
    /\ phase = "select"
    /\ front = "browser"
    /\ path = "key"
    /\ url' = "github"
    /\ rule' = "url"
    /\ phase' = "selected"
    /\ UNCHANGED <<front, path, out, spawnOk, fieldRead, result>>

UrlDiffers ==
    /\ phase = "select"
    /\ front = "browser"
    /\ path = "key"
    /\ url' = "other"
    /\ rule' = "catchAll"
    /\ phase' = "selected"
    /\ UNCHANGED <<front, path, out, spawnOk, fieldRead, result>>

UrlUnreadable ==
    /\ phase = "select"
    /\ front = "browser"
    /\ path = "key"
    /\ url' = "unreadable"
    /\ IF After
         THEN /\ rule' = "none"
              /\ result' = "unreadable"
              /\ phase' = "done"
         ELSE /\ rule' = "catchAll"       \* falls through to the next rule
              /\ result' = result
              /\ phase' = "selected"
    /\ UNCHANGED <<front, path, out, spawnOk, fieldRead>>

SelectCatchAll ==
    /\ phase = "select"
    /\ ~(front = "browser" /\ path = "key")
    /\ rule' = "catchAll"
    /\ phase' = "selected"
    /\ UNCHANGED <<front, path, url, out, spawnOk, fieldRead, result>>

\* Today's erase + capture: the field is read (polling, untouched by the design).
EraseAndRead ==
    /\ phase = "selected"
    /\ fieldRead' = TRUE
    /\ phase' = "erased"
    /\ UNCHANGED <<front, path, rule, url, out, spawnOk, result>>

\* Run: transform (not modelled) then the output.
RunUrlRule ==
    /\ phase = "erased"
    /\ rule = "url"
    /\ out' = "replaceInput"
    /\ result' = "replaced"
    /\ phase' = "done"
    /\ UNCHANGED <<front, path, rule, url, spawnOk, fieldRead>>

RunReplaceInput ==
    /\ phase = "erased"
    /\ rule = "catchAll"
    /\ out' = "replaceInput"
    /\ result' = "replaced"
    /\ phase' = "done"
    /\ UNCHANGED <<front, path, rule, url, spawnOk, fieldRead>>

RunTypeText ==
    /\ phase = "erased"
    /\ rule = "catchAll"
    /\ out' = "typeText"
    /\ result' = IF path = "line" /\ After THEN "failed" ELSE "delivered"
    /\ phase' = "done"
    /\ UNCHANGED <<front, path, rule, url, spawnOk, fieldRead>>

RunBackground ==
    /\ phase = "erased"
    /\ rule = "catchAll"
    /\ out' = "background"
    /\ \E ok \in BOOLEAN :
         /\ spawnOk' = ok
         /\ result' = IF ok \/ ~After THEN "started" ELSE "failed"
    /\ phase' = "done"
    /\ UNCHANGED <<front, path, rule, url, fieldRead>>

Done == phase = "done" /\ UNCHANGED vars

Next ==
    \/ GateBlocks \/ GatePasses
    \/ SelectUrlRule \/ UrlDiffers \/ UrlUnreadable \/ SelectCatchAll
    \/ EraseAndRead
    \/ RunUrlRule \/ RunReplaceInput \/ RunTypeText \/ RunBackground
    \/ Done

Spec == Init /\ [][Next]_vars

\* P6: a password field is never read.
NoReadInSecureField == front = "secureField" => ~fieldRead

\* P5: an unreadable fact never lets the next rule of the same trigger run.
UnreadableNeverFallsThrough == url = "unreadable" => rule # "catchAll"

\* P10: typeText on a desktop that cannot type never reports a success.
NoFakeTypeText == (out = "typeText" /\ path = "line") => result # "delivered"

\* P2: "started" is reported only when the job really spawned.
StartedMeansSpawned == result = "started" => spawnOk

=============================================================================
