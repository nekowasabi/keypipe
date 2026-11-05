-------------------------- MODULE EraseReadback ---------------------------
\* performErase (Engine.swift) after the Backspaces have been posted.
\* The app applies zero or one queued Backspace per text() read
\* (FakeDesktop.backspacePerRead / ignoresBackspace).
\*
\* The loop does not return on the first change. It returns when the field
\* equals the body (trigger removed), or the wait is used up. If the field is
\* still the original text then, the trigger is removed by setText
\* (erase-rewrite). A partial field is returned only when the wait is used up.
\*
\* Bound: a trigger of 3 characters and 5 reads. 5 > 3, so an app that applies
\* one Backspace per read finishes inside the wait. This is the assumption
\* behind the 200 ms deadline, not a proof that every app is that fast.

EXTENDS Naturals

Len == 3
MaxReads == 5

VARIABLES behavior, applied, reads, phase, handed

vars == <<behavior, applied, reads, phase, handed>>

Text(applied2) ==
  IF behavior = "ignores" \/ applied2 = 0 THEN "full"
  ELSE IF applied2 < Len THEN "partial"
  ELSE "body"

Init ==
  /\ behavior \in {"lands", "ignores"}
  /\ applied = 0
  /\ reads = 0
  /\ phase = "poll"
  /\ handed = ""

\* One text() poll. Matches the read before the while, and each pass of it.
Poll ==
  /\ phase = "poll"
  /\ LET applied2 == IF behavior = "lands" /\ applied < Len THEN applied + 1 ELSE applied
         text2 == Text(applied2)
         reads2 == reads + 1
     IN /\ applied' = applied2
        /\ reads' = reads2
        /\ IF text2 = "body"
             THEN /\ phase' = "done" /\ handed' = "body"
             ELSE IF reads2 >= MaxReads
               THEN /\ phase' = "done"
                    \* unchanged text: Backspace was ignored, so rewrite.
                    /\ handed' = IF text2 = "full" THEN "body" ELSE text2
               ELSE /\ phase' = "poll" /\ handed' = ""
        /\ UNCHANGED behavior

Rest ==
  /\ phase = "done"
  /\ UNCHANGED vars

Next == Poll \/ Rest

Spec == Init /\ [][Next]_vars

\* A partial trigger is not handed to the transform while reads remain.
NoEarlyPartial ==
  phase = "done" => handed = "body" \/ reads >= MaxReads

\* Under this bound, both modeled apps hand the body over.
HandsBody == phase = "done" => handed = "body"

=============================================================================
