--------------------------- MODULE TriggerMatch ---------------------------
\* TriggerMatcher.feed plus the reset Engine.key does in the same keystroke,
\* and the reset Engine.hotkey does before it looks at the chord.
\*
\* At one feed, the longest configured suffix wins (triggers sorted longest
\* first). A shorter trigger that is already a suffix fires and the buffer is
\* cleared, so a longer trigger that would have needed more keys does not
\* accumulate. That is the streaming note on TriggerMatcher.
\*
\* mode:
\*   both      "aa" and "aaa" are configured (@@ and @@@)
\*   longOnly  only "aaa"
\*   tie       "a" and "za" complete on the same key, so longest must win
\*
\* The buffer keeps the last 3 characters, the same slide as triggerMaxBuffer
\* with the bound 3 instead of 64.

EXTENDS Sequences, FiniteSets, Naturals

VARIABLES mode, buf, phase, fired, saw

vars == <<mode, buf, phase, fired, saw>>

Alphabet == {"a", "z", "x"}

TriggerSet(m) ==
  CASE m = "both" -> {"aa", "aaa"}
    [] m = "longOnly" -> {"aaa"}
    [] m = "tie" -> {"a", "za"}

IsSuffix(s, b) ==
  Len(s) <= Len(b) /\ SubSeq(b, Len(b) - Len(s) + 1, Len(b)) = s

Init ==
  /\ mode \in {"both", "longOnly", "tie"}
  /\ buf = ""
  /\ phase = "idle"
  /\ fired = ""
  /\ saw = ""

Slide(full) ==
  IF Len(full) > 3 THEN SubSeq(full, Len(full) - 2, Len(full)) ELSE full

Feed(c) ==
  /\ phase = "idle"
  /\ c \in Alphabet
  /\ LET full == buf \o c
         buf2 == Slide(full)
         hits == {t \in TriggerSet(mode) : IsSuffix(t, buf2)}
     IN IF hits = {}
          THEN /\ buf' = buf2
               /\ UNCHANGED <<mode, phase, fired, saw>>
          ELSE /\ fired' = CHOOSE t \in hits : \A u \in hits : Len(u) <= Len(t)
               /\ saw' = buf2
               /\ buf' = ""          \* Engine.key resets after a hit
               /\ phase' = "fired"
               /\ UNCHANGED mode

\* A chord clears the text buffer and does not fire a text trigger.
Hotkey ==
  /\ phase = "idle"
  /\ buf # ""
  /\ buf' = ""
  /\ fired' = ""
  /\ UNCHANGED <<mode, phase, saw>>

Settle ==
  /\ phase = "fired"
  /\ phase' = "idle"
  /\ fired' = ""
  /\ UNCHANGED <<mode, buf, saw>>

Next ==
  \/ Feed("a") \/ Feed("z") \/ Feed("x")
  \/ Hotkey
  \/ Settle

Spec == Init /\ [][Next]_vars

\* The trigger returned on this keystroke is the longest configured suffix.
FiredIsLongest ==
  fired = "" \/
  (/\ fired \in TriggerSet(mode)
   /\ IsSuffix(fired, saw)
   /\ \A u \in TriggerSet(mode) : IsSuffix(u, saw) => Len(u) <= Len(fired))

\* The reset is part of the same keystroke: a hit does not leave the trigger
\* in the buffer for the next character.
ResetOnFire == phase = "fired" => buf = ""

=============================================================================
