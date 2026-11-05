---------------------------- MODULE FireStages ----------------------------
\* The half of one fire after the gates have passed: runAfterBusy, then run.
\* performErase's poll is EraseReadback.tla; here that whole function is one
\* step, because Engine treats its return value as one result.
\*
\* Background is decided after the input is known and BEFORE the sync transform
\* (runAfterBusy). The parent does not run the transform itself.
\* onFail.transform runs at most once, then onFail.output at most once.
\* There is no third try (Engine.runTransform / Engine.run).

EXTENDS FiniteSets, Naturals

VARIABLES
  kind, ruleFocus, focus, path,
  phase, erased, shellInput, delivered, result, failStage,
  tries, outTries, shelled, sink

vars == <<kind, ruleFocus, focus, path, phase, erased, shellInput, delivered,
          result, failStage, tries, outTries, shelled, sink>>

Init ==
  /\ kind \in {"text", "hotkey"}
  /\ ruleFocus \in {"field", "any"}
  /\ focus \in {"nothing", "text", "terminal"}
  /\ path \in {"key", "supplied"}
  \* evaluate() rejects textField unless focus is text. A terminal match is
  \* only a hotkey whose when.focus is any (Engine.fire's terminal filter).
  /\ (ruleFocus = "field" => focus = "text")
  /\ (focus = "terminal" => kind = "hotkey" /\ ruleFocus = "any")
  /\ (focus = "nothing" => ruleFocus = "any")
  /\ phase = "erase"
  /\ erased = FALSE
  /\ shellInput = "none"
  /\ delivered = FALSE
  /\ result = "none"
  /\ failStage = ""
  /\ tries = 0
  /\ outTries = 0
  /\ shelled = FALSE
  /\ sink = ""

Keep == UNCHANGED <<kind, ruleFocus, focus, path>>

\* --- input (runAfterBusy's switch). supplied is --line / --rule stdin. -----

EraseTextField ==
  /\ phase = "erase"
  /\ kind = "text" /\ ruleFocus = "field"
  /\ erased' = TRUE
  /\ shellInput' = IF path = "key" THEN "field" ELSE "supplied"
  /\ phase' = "routed"
  /\ Keep
  /\ UNCHANGED <<delivered, result, failStage, tries, outTries, shelled, sink>>

ReadHotkeyField ==
  /\ phase = "erase"
  /\ kind = "hotkey" /\ ruleFocus = "field"
  /\ erased' = FALSE \* hotkey-field
  /\ shellInput' = IF path = "key" THEN "field" ELSE "supplied"
  /\ phase' = "routed"
  /\ Keep
  /\ UNCHANGED <<delivered, result, failStage, tries, outTries, shelled, sink>>

EraseAnyInText ==
  /\ phase = "erase"
  /\ kind = "text" /\ ruleFocus = "any" /\ focus = "text"
  /\ erased' = TRUE
  /\ shellInput' = IF path = "key" THEN "empty" ELSE "supplied" \* any-in-text
  /\ phase' = "routed"
  /\ Keep
  /\ UNCHANGED <<delivered, result, failStage, tries, outTries, shelled, sink>>

SkipEraseAny ==
  /\ phase = "erase"
  /\ kind = "text" /\ ruleFocus = "any" /\ focus # "text"
  /\ erased' = FALSE
  /\ shellInput' = IF path = "key" THEN "empty" ELSE "supplied"
  /\ phase' = "routed"
  /\ Keep
  /\ UNCHANGED <<delivered, result, failStage, tries, outTries, shelled, sink>>

HotkeyAny ==
  /\ phase = "erase"
  /\ kind = "hotkey" /\ ruleFocus = "any"
  /\ erased' = FALSE \* hotkey-any
  /\ shellInput' = IF path = "key" THEN "empty" ELSE "supplied"
  /\ phase' = "routed"
  /\ Keep
  /\ UNCHANGED <<delivered, result, failStage, tries, outTries, shelled, sink>>

\* Field vanished before any backspace (waitForTrigger / hotkey read returned nil).
FieldGone ==
  /\ phase = "erase"
  /\ ruleFocus = "field"
  /\ erased' = FALSE
  /\ shellInput' = "none"
  /\ phase' = "done"
  /\ result' = "noInput"
  /\ failStage' = ""
  /\ Keep
  /\ UNCHANGED <<delivered, tries, outTries, shelled, sink>>

\* Backspaces were posted, then the field vanished. The shell still does not run.
FieldGoneAfterErase ==
  /\ phase = "erase"
  /\ kind = "text" /\ ruleFocus = "field"
  /\ erased' = TRUE
  /\ shellInput' = "none"
  /\ phase' = "done"
  /\ result' = "noInput"
  /\ failStage' = ""
  /\ Keep
  /\ UNCHANGED <<delivered, tries, outTries, shelled, sink>>

\* --- background returns here; a sync fire enters the transform -------------

BeginSync ==
  /\ phase = "routed"
  /\ phase' = "transform"
  /\ Keep
  /\ UNCHANGED <<erased, shellInput, delivered, result, failStage, tries, outTries, shelled, sink>>

BackgroundOk ==
  /\ phase = "routed"
  /\ phase' = "done"
  /\ result' = "started"
  /\ failStage' = ""
  /\ sink' = "background"
  /\ delivered' = FALSE
  /\ Keep
  /\ UNCHANGED <<erased, shellInput, tries, outTries, shelled>>

BackgroundFail ==
  /\ phase = "routed"
  /\ phase' = "done"
  /\ result' = "failed"
  /\ failStage' = "spawn"
  /\ sink' = "background"
  /\ delivered' = FALSE
  /\ Keep
  /\ UNCHANGED <<erased, shellInput, tries, outTries, shelled>>

\* --- transform. empty, nonzero and timeout are one failure branch. ----------

SkipTransform ==
  /\ phase = "transform"
  /\ phase' = "output"
  /\ Keep
  /\ UNCHANGED <<erased, shellInput, delivered, result, failStage, tries, outTries, shelled, sink>>

PrimaryOk ==
  /\ phase = "transform"
  /\ phase' = "output"
  /\ shelled' = TRUE
  /\ Keep
  /\ UNCHANGED <<erased, shellInput, delivered, result, failStage, tries, outTries, sink>>

PrimaryFailStop ==
  /\ phase = "transform"
  /\ phase' = "done"
  /\ result' = "failed"
  /\ failStage' = "transform"
  /\ shelled' = TRUE
  /\ delivered' = FALSE \* primary-fail
  /\ Keep
  /\ UNCHANGED <<erased, shellInput, tries, outTries, sink>>

PrimaryFailToFallback ==
  /\ phase = "transform"
  /\ phase' = "fallback"
  /\ shelled' = TRUE
  /\ Keep
  /\ UNCHANGED <<erased, shellInput, delivered, result, failStage, tries, outTries, sink>>

FallbackOk ==
  /\ phase = "fallback"
  /\ tries = 0
  /\ tries' = 1
  /\ phase' = "output"
  /\ shelled' = TRUE
  /\ Keep
  /\ UNCHANGED <<erased, shellInput, delivered, result, failStage, outTries, sink>>

FallbackFail ==
  /\ phase = "fallback"
  /\ tries = 0
  /\ tries' = 1
  /\ phase' = "done"
  /\ result' = "failed"
  /\ failStage' = "transform"
  /\ delivered' = FALSE
  /\ shelled' = TRUE
  /\ Keep
  /\ UNCHANGED <<erased, shellInput, outTries, sink>>

\* Not in Next. A second onFail.transform. mutants.sh adds it.
SecondFallback ==
  /\ phase = "done"
  /\ failStage = "transform"
  /\ tries = 1
  /\ tries' = 2
  /\ UNCHANGED <<kind, ruleFocus, focus, path, phase, erased, shellInput,
                delivered, result, failStage, outTries, shelled, sink>>

\* --- output. notify and none cannot fail. typeText needs a caret the -------
\* --line/--rule desktop does not have (Desktop.typeText's default is false).

Deliver(res, sk) ==
  /\ phase' = "done"
  /\ result' = res
  /\ sink' = sk
  /\ delivered' = TRUE
  /\ failStage' = ""
  /\ Keep
  /\ UNCHANGED <<erased, shellInput, tries, outTries, shelled>>

ReplaceOk ==
  /\ phase = "output"
  /\ ruleFocus = "field"
  /\ Deliver("replaced", "replace")

ShellOk ==
  /\ phase = "output"
  /\ Deliver("delivered", "shell")

NotifyOk ==
  /\ phase = "output"
  /\ Deliver("delivered", "notify")

NoneOk ==
  /\ phase = "output"
  /\ Deliver("delivered", "none")

TypeOk ==
  /\ phase = "output"
  /\ path = "key"
  /\ focus \in {"text", "terminal"}
  /\ Deliver("delivered", "type")

\* replace, shell and typeText can fail. The fallback runs once from outfb.
OutputFail ==
  /\ phase = "output"
  /\ \/ ruleFocus = "field"
     \/ sink = ""  \* shell or typeText, which do not need a field
  /\ phase' = "outfb"
  /\ Keep
  /\ UNCHANGED <<erased, shellInput, delivered, result, failStage, tries, outTries, shelled, sink>>

\* The line above lets OutputFail run for every output state, including one
\* that will also NotifyOk. That is the config choice (this rule's sink can
\* fail, or it is notify). A notify rule takes NotifyOk, not OutputFail.

OutFbOk ==
  /\ phase = "outfb"
  /\ outTries = 0
  /\ outTries' = 1
  /\ phase' = "done"
  /\ result' = "delivered"
  /\ sink' = "fallback"
  /\ delivered' = TRUE
  /\ failStage' = ""
  /\ Keep
  /\ UNCHANGED <<erased, shellInput, tries, shelled>>

OutFbFail ==
  /\ phase = "outfb"
  /\ outTries = 0
  /\ outTries' = 1
  /\ phase' = "done"
  /\ result' = "failed"
  /\ failStage' = "output"
  /\ delivered' = FALSE
  /\ Keep
  /\ UNCHANGED <<erased, shellInput, tries, shelled, sink>>

\* Not in Next. A second onFail.output.
SecondOutputFallback ==
  /\ phase = "done"
  /\ failStage = "output"
  /\ outTries = 1
  /\ outTries' = 2
  /\ UNCHANGED <<kind, ruleFocus, focus, path, phase, erased, shellInput,
                delivered, result, failStage, tries, shelled, sink>>

Rest ==
  /\ phase = "done"
  /\ UNCHANGED vars

Next ==
  \/ EraseTextField \/ ReadHotkeyField \/ EraseAnyInText \/ SkipEraseAny \/ HotkeyAny
  \/ FieldGone \/ FieldGoneAfterErase
  \/ BeginSync \/ BackgroundOk \/ BackgroundFail
  \/ SkipTransform \/ PrimaryOk \/ PrimaryFailStop \/ PrimaryFailToFallback
  \/ FallbackOk \/ FallbackFail
  \/ ReplaceOk \/ ShellOk \/ NotifyOk \/ NoneOk \/ TypeOk \/ OutputFail
  \/ OutFbOk \/ OutFbFail
  \/ Rest

Spec == Init /\ [][Next]_vars

\* A hotkey posts no Backspace (erase 0).
HotkeyNeverBackspaces == kind = "hotkey" => ~erased

\* focus any on the keyboard path never feeds the field to the shell.
KeyAnySeesEmpty ==
  (path = "key" /\ ruleFocus = "any" /\ shellInput # "none") => shellInput = "empty"

\* A text trigger that uses the field, on the keyboard path, feeds the field
\* (the trigger already removed), not the empty string and not stdin.
KeyFieldSeesField ==
  (kind = "text" /\ ruleFocus = "field" /\ path = "key" /\ shellInput # "none")
    => shellInput = "field"

\* --line and --rule pass the caller's stdin through, whatever when.focus is.
SuppliedSeesCaller ==
  (path = "supplied" /\ shellInput # "none") => shellInput = "supplied"

\* A vanished field does not run a shell and does not count as delivered.
NoInputDoesNotRun ==
  result = "noInput" => ~shelled /\ ~delivered

\* Transform failure (including the one fallback) does not deliver.
FailedTransformDoesNotDeliver ==
  failStage = "transform" => (~delivered /\ result = "failed")

\* onFail.transform / onFail.output each run at most once.
TransformFallbackOnce == tries <= 1
OutputFallbackOnce == outTries <= 1

\* replaceInput is only a field rule (loadConfig rejects it otherwise).
ReplacedMeansField == result = "replaced" => ruleFocus = "field"

\* "started" is only a background spawn that did start.
StartedMeansSpawned ==
  result = "started" => (sink = "background" /\ failStage = "" /\ ~delivered)

\* typeText on --line/--rule has no caret: it must not report success.
NoFakeTypeText == ~(delivered /\ sink = "type" /\ path = "supplied")

\* On the keyboard path, typeText succeeds only where a caret exists.
NoTypeWithoutCaret ==
  (delivered /\ sink = "type") => (path = "key" /\ focus \in {"text", "terminal"})

=============================================================================
