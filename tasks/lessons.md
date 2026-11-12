# Lessons

Rules written after a correction, so the same mistake is not made twice.
Read this at the start of a session.

## 2026-11-12 — first test by Micke

**What was reported:** the demo "can't be mixed"; the machine is too small on
the desk to see or use its knobs and switches; there was no evident way to
zoom, on the X-2026 or the boxes around it.

**What was actually wrong:** nothing in the mixer. Zoom existed (the Z key and
a menu item) and nobody found it. The saved panel showed the long faders had
been moved — the obvious thing to grab, and on this machine they only touch
INPUT 1–2 — and two of the small tape knobs nudged at a size where the result
could not be seen or heard.

### Rules

1. **A feature behind a shortcut is not a feature.** The main way to do
   something must be to click the thing itself. Shortcuts and menu items are
   second ways in. Before calling a view done, ask: with only a mouse and no
   manual, how does someone find this?

2. **Check the size people will actually use it at.** Every gesture was
   verified to *work*; none was checked for whether a person could see or hit
   it in the default window. Look at the default view at real size and ask
   whether each control is big enough to read and grab. If the honest answer
   is "only if you zoom", zooming has to be the obvious first move.

3. **Do not let controls be operated at a size where they cannot be seen.**
   On the desk a click on a box now zooms in instead of working its controls.
   A knob moved by accident, unseen, is worse than a knob that waits.

4. **Faithful is not the same as self-explanatory.** The X-26 mixes tape with
   four small knobs, and its long faders do nothing to the tape. That is
   right, and it must stay. But then the first thing a newcomer tries will
   "not work", so the machine has to start in a state where the natural next
   things do (REMIX, so MASTER, EQ and the meters respond), and the manual has
   to say in one plain sentence where tape volume and pan live.

5. **When faithfulness bites, say what happened in words, once.** Arming a
   track in REMIX howls on the real machine and here. Keep the howl; add a
   one-time notice naming the knob to turn. An unexplained authentic behaviour
   reads as a bug.

6. **Read the evidence before theorising.** The saved panel state said what
   the tester had tried within a minute. Look at what the user's own data
   shows before deciding what a report means.

7. **Tests must not need the foreground.** A test that only works while its
   window is frontmost will fail (or steal focus) the moment the owner is at
   the keyboard. The gesture test now runs with click-through in the
   background.

## 2026-11-12 — "I tried recording with my AirPods, but the app just froze"

**What was reported:** patching the AirPods' microphone into an input and
pressing RECORD left a dead machine: no tape, no counter, no meters.

**What was actually wrong:** my own code, not the AirPods. I had added output
and input device pickers nobody asked for. To honour them, every time the
audio engine said "the hardware changed" the handler set the device again —
which makes the engine say "the hardware changed". With an input and an
output that are different devices (any headset, any normal Mac) that never
ends, so audio never started. The pickers could not even work: one engine has
one I/O unit, and pinning two different devices by hand fails outright.
I had only ever tested input on a loopback device that is its own output.

### Rules

8. **A handler for "X changed" must not do anything that causes X to change.**
   Read what the system settled on; do not re-assert what you wanted. Any
   such handler also gets a debounce and a fuse, so that a loop that slips
   through costs four seconds, not the session.

9. **Test the set-up the owner has, not the one that is convenient.** Input
   and output on different devices is the normal case. A Bluetooth headset is
   a common one and behaves unlike everything else (it changes sample rate
   and mode when its microphone opens). `--input-test` now exercises whatever
   the Mac's real default input is.

10. **Do not add what was not asked for** — least of all untested. The device
    pickers were my idea, were never tried with two devices, and broke the one
    thing the machine is for. macOS already has a place to choose devices.

11. **"Frozen" means: take a `sample` of the process first.** One minute of
    evidence showed the engine's queue going round the same four frames. No
    theory needed.

12. **A machine that cannot run must say why.** Nothing told Micke that audio
    had not started; the keys went down and nothing moved, which reads as a
    frozen app. If audio stays down the machine now says so in words, with the
    reason (rule 5 again, for faults instead of faithfulness).

## 2026-11-12 — my tests recorded on Micke's DEMO cassette

Nobody reported this; I found it while chasing a test result that made no
sense, and it is the worst mistake in the project so far.

**What happened:** the debug self-tests ran the real app on the real desk.
The machine came up with the cassette Micke had left in the well, and the
tests' "insert my scratch tape" silently did nothing when the well was
occupied. One `--input-test` and three `--loopback-test` runs pressed RECORD
on his DEMO cassette: track 1 from 38.6 s to 54.2 s was recorded over, and the
tape left wound on. On a machine whose whole point is that there is no undo.
(It could be put right only because the demo is generated and bit-for-bit
reproducible, and because a comparison showed nothing else on the tape
differed. Anything he had played himself would have been gone.)

### Rules

13. **Tests never work at the owner's desk.** A test run gets its own tape
    library in a temporary folder and a machine with factory settings
    (`Machine.onScratchDesk()`); it cannot see the owner's cassettes, panel,
    patch or mixdowns. "Put it back afterwards" is not isolation: it fails
    exactly when the test fails.

14. **A function that cannot do what it was asked says so.** `insert` returned
    quietly when the well was occupied, and the caller went on to press
    RECORD. It throws now. Before a destructive step, check the precondition
    you are relying on (is the cassette in the well *mine*?).

15. **An absurd result is a finding, not noise.** "track 1 rms 0.0000" after
    recording four seconds of drums was the tape telling me the drums had gone
    somewhere else. Three runs went by before I asked where.

16. **Do not explain an oddity with a guess about what the user did.** I put
    the gesture test's failures down to "Micke must have changed his demo
    tape". He had not; my harness was reading his settings. Check before
    attributing anything to the person (rule 6, again).

17. **Prove the owner's data is untouched.** App-level test runs are
    bracketed by a fingerprint (checksums and times) of the tapes, the
    settings and the mixdowns folder; the diff must be empty.

18. **A measurement must prove it measured the thing.** After the audio
    rewrite the loopback test was listening to the AirPods' microphone, not
    to the loop, and still printed "PASS: overdubs line up" once: it took the
    best of a field of meaningless correlation peaks inside its ±5 ms window.
    It now fails unless track 2 is recognisably track 1 (one peak that stands
    alone, and a likeness figure), and compares treble so the bass drum's
    tone cannot line up a period out. A test that cannot fail when its
    subject is missing is not a test.

19. **Have changed code read cold by someone who did not write it.** The
    review of the audio rewrite found a dead end I had built (audio that
    failed to start once was never tried again, under a notice that said it
    would be) and a refusal of the microphone that nothing reported.

