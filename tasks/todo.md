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
- [ ] Mixer + recorder core (block diagram), punch in/out with erase-head gap
- [ ] Unit tests: wind time = 105 s, record/playback round trip, punch gap, counter
- [ ] Audio host (AVAudioEngine), latency-compensated overdubs
- [ ] Machine model: panel state, mechanical key interlock, persistence

## Phase 2 — the object

- [x] Controls: knob, fader, slide switch, tape counter
- [x] Cassette artwork with turning reels
- [ ] Transport keys, LED meters, REC TRK lamps
- [ ] Faceplate laid out from the manual drawing (380 × 195 mm)
- [ ] Cassette well, smoked lid, spindles
- [ ] The desk: cassettes lying around, new blank tapes, labels in handwriting
- [ ] The hand: inserts and removes cassettes
- [ ] Front-panel jacks: patch Mac inputs into INPUT 1–6
- [ ] Mechanical sounds: keys, motor, wind whine, lid, cassette

## Phase 3 — the studio around it

- [ ] Foot switch on PUNCH IN/OUT
- [ ] Reverb unit on the AUX loop
- [ ] Master recorder on LINE OUT (real-time mixdown to a file)
- [ ] Rhythm box to plug into an input
- [ ] App icon, About box, menus, keyboard shortcuts

## Review

(filled in at the end)
