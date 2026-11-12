# X-2026 — plan

A macOS emulation of the Fostex X-26 Multitracker (1988). Brand: **Brustex X-2026**
("brus" is Swedish for hiss). Facts come from the 1988 owner's manual; see
`docs/x26-reference.md`.

Note: CLAUDE.md asks for a check-in before implementation. The brief said "Go!",
so this plan was written and then executed without stopping.

## Principles

- The tape is the file. No save, no undo, no timeline. Recording overwrites oxide.
- Everything is derived from physics: head position is a distance along the tape,
  reel speed follows pack radius, the counter counts hub revolutions.
- The signal flow is the block diagram on p.27 of the manual, nothing more.

## Phase 1 — the machine

- [x] Xcode project (macOS 27, Swift 6, sandboxed, mic entitlement)
- [x] Research: owner's manual, block diagram, specs
- [x] Tape geometry: stock lengths, reel radii, hub turns
- [x] Tape medium: sparse memory-mapped 4-track file, flippable
- [x] DSP primitives: biquad, NR compander, tape channel (saturation, hiss, head response)
- [x] Transport: capstan run-in, pitch, wow & flutter, hub-driven fast wind, auto-stop
- [x] Mixer + recorder core (block diagram), punch in/out with erase-head gap
- [x] Unit tests: wind time = 105 s, record/playback round trip, punch gap, counter
- [x] Audio host (AVAudioEngine), latency-compensated overdubs
- [x] Machine model: panel state, mechanical key interlock, persistence

## Phase 2 — the object

- [x] Controls: knob, fader, slide switch, tape counter
- [x] Cassette artwork with turning reels
- [x] Transport keys, LED meters, REC TRK lamps
- [x] Faceplate laid out from the manual drawing (380 × 195 mm)
- [x] Cassette well, smoked lid, spindles, heads
- [x] The desk: cassettes lying around, new blank tapes, labels in handwriting
- [x] The hand: inserts and removes cassettes
- [x] Front-panel jacks: patch Mac inputs into INPUT 1–6
- [x] Mechanical sounds: keys, motor, wind whine, lid, cassette

## Phase 3 — the studio around it

- [x] Foot switch on PUNCH IN/OUT
- [x] Reverb unit on the AUX loop
- [x] Master recorder on LINE OUT (real-time mixdown to a file)
- [x] Rhythm box to plug into an input
- [x] App icon, owner's manual, menus, keyboard shortcuts
- [x] Demo cassette recorded by the machine itself on first run
- [x] Lean in / sit back

## Not done / ideas

- [ ] Choose input and output devices in Settings (uses the system defaults today)
- [ ] Wrong-tape behaviour: a Type I cassette on a Type II machine should sound dull
- [ ] "Condition" setting: mint / well loved / barn find (flutter, hiss, motor bleed, dropouts)
- [ ] Drop an audio file on an input jack as a line source that plays in real time
- [ ] Tape wear and position-locked dropouts
- [ ] Double-click a `.x2026tape` in Finder to put it on the desk
- [ ] Nobody has *listened* to it yet. Every sound was verified by measurement, not by ear.

## Review

What was verified, and how:

- **Engine, offline** (27 unit tests): a C-60 winds end to end in 105.7 s both
  ways and a C-90 takes longer; play speed and ±10 % pitch; auto-stop at both
  ends at 48 kHz; record → play round trip keeps level (±2 dB) and pitch
  (±0.4 %); RECORD with no track armed leaves the tape untouched; record-protect;
  nothing records on the leader; lamp colours; input vs tape monitor; the
  0.26 s punch-out gap and punch-in overlap; side B is the oxide reversed;
  bounces and live overdubs land on the right spot with latency compensation;
  NR encodes ≤10 dB and decodes transparently; hiss level and NR benefit;
  saturation instead of clipping; counter wheels carry; key interlock.
- **Real app, end to end** (`--self-test`): the hand inserts a cassette in
  about 4 s; rhythm box recorded to track 1 (lamp amber → red); rewound by
  counter; played back at +0.8 dB; a C-46 fast-forwarded to its end in 84 s of
  real time; auto-stop released the keys; the hand took the tape out.
- **Real audio hardware loop** (`--loopback-test` through BlackHole): reported
  round trip 9.7 ms; the overdub landed 0.7 ms from the track it was played to.
- **Gestures** (`--touch-test`): synthetic mouse events sent to the app's own
  window click the transport keys, drag a fader by a measured distance, turn
  knobs both ways, click and drag slide switches, reset the counter, open and
  close the lid, click a cassette to have it loaded and click it again to
  take it out. Menus (the jack patch menus, the blank-tape box) were not
  exercised: they open a modal tracking loop.
- **Looks**: every view checked by rendering previews and capturing the
  running app's window.

Bugs found on the way:

- Auto-stop never tripped after a fast wind at 48 kHz (the stall timer was reset
  every other sample). The unit test ran the deck at 8 kHz and missed it; the
  live self-test caught it. Fixed, with a 48 kHz test.
- The test host was detected with `NSClassFromString("XCTestCase")`, which is
  still nil at app launch, so unit-test runs started the real machine and
  recorded a second demo tape. Now detected from the environment.
- An interrupted self-test left its panel settings saved as the user's.
  Self-tests, test hosts and previews now use a machine that never saves.
- The LED meters and REC TRK lamps were drawn once and never again in the
  running app (the Canvas captured nothing that changed). Caught by comparing
  window captures with the telemetry log.
- Bare-letter menu shortcuts would have swallowed typing in the label editor;
  the desk view now handles transport keys itself while it has focus.

Engine speed, worst case (two tracks recording, four playing, reverb on):
3.6× real time in Debug, 16× in Release.
