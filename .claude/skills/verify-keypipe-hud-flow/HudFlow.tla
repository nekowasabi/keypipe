---------------------------- MODULE HudFlow ----------------------------
(* The busy spinner and the fired pill around one keypipe fire, on a Mac.
   Two serial queues, as in the code:
   - the engine queue "keypipe.engine" (main.swift), which runs Engine.fire
     one fire at a time and posts window work to the main queue;
   - the main queue (FIFO), which runs BusySpinner.show/hide and
     FiredHUD.show, plus the pill's asyncAfter hide work item.
   Each action below is one indivisible step in the code; its comment names it. *)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS MaxFires,  \* fires in one run (bound)
          HUD        \* KeypipeConfig.hud

Fires    == 1..MaxFires
Outcomes == {"gated", "ok", "failed", "started", "noInput"}
PillOutcomes == {"ok", "failed", "started"}

VARIABLES
  fire,      \* number of the fire the engine is on (0 before the first)
  pc,        \* where Engine.fire is for that fire
  result,    \* result[k]: how fire k ended ("none" while it runs)
  mainQ,     \* blocks posted with DispatchQueue.main.async, oldest first
  spinner,   \* fire whose spinner is on screen, 0 = hidden (BusySpinner)
  pill,      \* fire whose pill is on screen, 0 = hidden (FiredHUD.panel)
  pending,   \* hide work items scheduled with asyncAfter, by fire
  cancelled, \* work items cancelled by a later FiredHUD.show
  spun,      \* spun[k]: fire k's spinner was ever shown
  shown,     \* shown[k]: how many pills fire k showed
  stale      \* a work item hid a pill that was not its own

vars == <<fire, pc, result, mainQ, spinner, pill, pending, cancelled, spun, shown, stale>>

Init ==
  /\ fire = 0
  /\ pc = "idle"
  /\ result = [k \in Fires |-> "none"]
  /\ mainQ = <<>>
  /\ spinner = 0
  /\ pill = 0
  /\ pending = {}
  /\ cancelled = {}
  /\ spun = [k \in Fires |-> FALSE]
  /\ shown = [k \in Fires |-> 0]
  /\ stale = FALSE

EngineVars == <<fire, pc, result>>
MainVars   == <<spinner, pill, pending, cancelled, spun, shown, stale>>

(* --- engine queue: Engine.key / Engine.hotkey -> Engine.fire --- *)

\* MacKeyTap posts the key to the engine queue; the matcher completes a trigger.
TriggerTyped ==
  /\ pc = "idle" /\ fire < MaxFires
  /\ fire' = fire + 1 /\ pc' = "gating"
  /\ UNCHANGED <<result, mainQ>> /\ UNCHANGED MainVars

\* Engine.fire returns before showBusy: terminal, composing, secure, deny,
\* unreadable, noMatch, front-changed.
GateStops ==
  /\ pc = "gating"
  /\ result' = [result EXCEPT ![fire] = "gated"] /\ pc' = "idle"
  /\ UNCHANGED <<fire, mainQ>> /\ UNCHANGED MainVars

\* Engine.fire: hits += 1, "keypipe matched".
GatePasses ==
  /\ pc = "gating" /\ pc' = "matched"
  /\ UNCHANGED <<fire, result, mainQ>> /\ UNCHANGED MainVars

\* desktop.showBusy -> MacDesktop.showBusy: DispatchQueue.main.async { BusySpinner.show }
PostSpinner ==
  /\ pc = "matched" /\ pc' = "running"
  /\ mainQ' = Append(mainQ, [op |-> "spin", f |-> fire])
  /\ UNCHANGED <<fire, result>> /\ UNCHANGED MainVars

\* Engine.runAfterBusy returns: erase, input, then the sync stages or the background spawn.
RunEnds(o) ==
  /\ pc = "running" /\ pc' = "ran"
  /\ result' = [result EXCEPT ![fire] = o]
  /\ UNCHANGED <<fire, mainQ>> /\ UNCHANGED MainVars

\* desktop.hideBusy -> MacDesktop.hideBusy: DispatchQueue.main.async { BusySpinner.hide }
PostHide ==
  /\ pc = "ran" /\ pc' = "hidden"
  /\ mainQ' = Append(mainQ, [op |-> "unspin", f |-> fire])
  /\ UNCHANGED <<fire, result>> /\ UNCHANGED MainVars

\* Engine.showFiredIfNeeded -> MacDesktop.showFired: DispatchQueue.main.async { FiredHUD.show }
\* Nothing is posted when hud is false or the result is noInput.
PostPill ==
  /\ pc = "hidden" /\ pc' = "idle"
  /\ mainQ' = IF HUD /\ result[fire] \in PillOutcomes
                THEN Append(mainQ, [op |-> "pill", f |-> fire])
                ELSE mainQ
  /\ UNCHANGED <<fire, result>> /\ UNCHANGED MainVars

(* --- main queue --- *)

\* BusySpinner.show(at:): orderFrontRegardless.
MainShowsSpinner ==
  /\ mainQ /= <<>> /\ Head(mainQ).op = "spin"
  /\ spinner' = Head(mainQ).f
  /\ spun' = [spun EXCEPT ![Head(mainQ).f] = TRUE]
  /\ mainQ' = Tail(mainQ)
  /\ UNCHANGED EngineVars /\ UNCHANGED <<pill, pending, cancelled, shown, stale>>

\* BusySpinner.hide(): orderOut.
MainHidesSpinner ==
  /\ mainQ /= <<>> /\ Head(mainQ).op = "unspin"
  /\ spinner' = 0
  /\ mainQ' = Tail(mainQ)
  /\ UNCHANGED EngineVars /\ UNCHANGED <<pill, pending, cancelled, spun, shown, stale>>

\* FiredHUD.show: hideWork?.cancel(), orderOut the old panel, orderFront the new one,
\* asyncAfter(1.5 s or 3 s) a new hide work item.
MainShowsPill ==
  /\ mainQ /= <<>> /\ Head(mainQ).op = "pill"
  /\ LET k == Head(mainQ).f IN
       /\ cancelled' = cancelled \cup pending
       /\ pill' = k
       /\ pending' = pending \cup {k}
       /\ shown' = [shown EXCEPT ![k] = @ + 1]
  /\ mainQ' = Tail(mainQ)
  /\ UNCHANGED EngineVars /\ UNCHANGED <<spinner, spun, stale>>

\* The asyncAfter deadline passes and the work item runs on main. A cancelled item does
\* nothing; a live one orders out whatever FiredHUD.panel is now.
HideTimerFires(i) ==
  /\ i \in pending
  /\ pending' = pending \ {i}
  /\ IF i \in cancelled
       THEN UNCHANGED <<pill, stale>>
       ELSE /\ pill' = 0
            /\ stale' = (stale \/ (pill /= 0 /\ pill /= i))
  /\ UNCHANGED EngineVars /\ UNCHANGED <<mainQ, spinner, cancelled, spun, shown>>

\* Every fire is over and every window is gone.
Done ==
  /\ fire = MaxFires /\ pc = "idle" /\ mainQ = <<>> /\ pending = {}
  /\ UNCHANGED vars

Next ==
  \/ TriggerTyped \/ GateStops \/ GatePasses \/ PostSpinner
  \/ \E o \in Outcomes \ {"gated"} : RunEnds(o)
  \/ PostHide \/ PostPill
  \/ MainShowsSpinner \/ MainHidesSpinner \/ MainShowsPill
  \/ \E i \in Fires : HideTimerFires(i)
  \/ Done

Spec == Init /\ [][Next]_vars

(* --- rules (each one is a promise the code makes) --- *)

\* A fire stopped at a gate shows neither the spinner nor a pill.
GatedFireShowsNothing ==
  \A k \in Fires : result[k] = "gated" => (~spun[k] /\ shown[k] = 0)

\* A fire's pill never sits on screen together with its own spinner.
SpinnerGoneBeforeItsPill == ~(pill /= 0 /\ spinner = pill)

\* At most one pill per fire, and only for ok, failed or started with hud on.
OnePillPerFinishedFire ==
  \A k \in Fires :
    /\ shown[k] <= 1
    /\ shown[k] = 1 => (HUD /\ result[k] \in PillOutcomes)

\* A pill is hidden only by its own timer or replaced by a newer pill.
NoStaleHide == ~stale

\* When the engine is idle and main has run everything posted, the spinner is hidden.
SpinnerGoneAtRest == (pc = "idle" /\ mainQ = <<>>) => spinner = 0

\* When no hide work item is left either, the pill is hidden too.
PillGoneAtRest == (pc = "idle" /\ mainQ = <<>> /\ pending = {}) => pill = 0

=============================================================================
