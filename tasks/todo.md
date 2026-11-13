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

## Round 2 — feedback after the first test (2026-11-12)

Micke's report: (1) the demo can't be mixed, wants pan and volume; (2) the
machine is too small on the desk to see switches and knobs — click it to zoom
in "full screen", and be able to zoom back out; (3) the same for the TAKT-8,
the KLANG and the MASTER-2.

What the saved panel showed: the long faders 1–2 had been moved (they only
affect INPUT 1–2) and two SUB PAN / SUB GAIN knobs nudged slightly. The mixer
works; nobody could tell.

- [x] Zoom: click a device on the desk to fill the window with it; click the
      desk, press Esc, pinch out or use the bar at the top to go back
- [x] All four devices zoomable; jump between them from the bar or ⌘1–4
- [x] On the desk, a click on a device zooms instead of working its controls
      (no more knobs moved by accident at a size nobody can see)
- [x] Factory panel back to REMIX (the manual's mixdown set-up) so MASTER, EQ
      and the L/R meters act on the tape; a saved panel from before is
      switched once
- [x] A one-time notice when a track is armed into the REMIX feedback loop,
      instead of an unexplained howl
- [x] Manual: say plainly where tape volume and pan live, and what the long
      faders are for
- [x] Verify live: ghost finger zooms in and out, then mixes the demo by
      dragging SUB PAN / SUB GAIN / MASTER and watches LINE OUT follow

Verified: 44 unit tests (the factory panel mixes the tape in REMIX and in
NORM; the notice; the saved-panel switch). In the running app, 32 gesture
checks with synthetic mouse events, run in the background: a click on each of
the four boxes zooms in on it and works nothing; the bar's buttons go across
and back; a click on bare desk zooms out; SUB PAN 3 dragged down and up sends
track 1 of the demo hard left then hard right on LINE OUT; SUB GAIN 3 to
twelve o'clock removes it and back restores it; MASTER fades the mix out.
Not exercised: Esc, pinch, the ⌘-number shortcuts, and the menus.

Lessons from this round are in `tasks/lessons.md`.

## Round 3 — "recording with AirPods froze the app" (2026-11-12)

- [x] Find the cause: `sample` of the frozen app showed the audio engine
      restarting for ever (config change → set device → config change).
- [x] Follow the Mac's own choice of output and input (System Settings →
      Sound); never set devices from the change handler. Device pickers
      removed from Settings: they could not work with two devices.
- [x] Debounce hardware changes; a fuse if they will not settle; a fresh
      engine when the last input is unplugged, so the microphone is let go.
- [x] One-time notice that a Bluetooth headset drops to hands-free mode
      (telephone quality, delay) while its microphone is open.
- [x] If audio stays down, the machine says why in words.
- [x] `--input-test`: real default input → settles, tape runs in real time,
      input is on the tape, unplugging releases it.
- [x] **Test runs moved off the owner's desk** (found while verifying the
      above: the tests had recorded on Micke's DEMO cassette). Scratch desk
      for tests, previews and errands; `insert` throws on an occupied well;
      the gesture and mixdown tests record a demo of their own.
- [x] DEMO cassette restored: track 1, 38.6–54.2 s, from a regenerated
      demo; verified identical to pristine; wound back to 38.6 s.
- [x] Loopback test made honest: it was hearing the default microphone, not
      the loop. Both sides are pinned to the loopback device, the comparison
      is by treble, and it fails unless track 2 really is track 1.
      Result: +0.5 ms, the same on every run.

### Independent review of the audio rewrite

| Finding | Outcome |
|---|---|
| Audio that failed to start was never tried again unless the hardware happened to change | Fixed: retried by the clock (2 s, doubling to 16 s) with a fresh engine |
| Unplugging the jack did nothing if the input had never come up, leaving a dead engine or a held microphone | Fixed: unplugging the last hardware input always rebuilds |
| An input that is not there was only logged | Fixed: said in words (`inputMissing`) |
| A jack left plugged in with microphone access refused: no prompt, no word, on every launch | Fixed: settled at power-on, and explained |
| No output device fell through at an invented 48 kHz | Fixed: reported as "no audio output", then retried |
| A hardware change during the fuse's rest cut the rest short | Fixed: changes are ignored while resting |
| The "no sound" notice could repeat, and advised a step that did nothing | Fixed: once per cause; says to unplug and plug in again |
| Scratch-desk deletion was guarded by what the folder is not | Fixed: deletes only a folder inside `tmp/x2026-scratch`; tested |
| A slow restart loop (a second or more per turn) would not blow the fuse | Not done: no such loop has been seen |

Open: in one run of the gesture test two knob drags came up short, at the
moment the AirPods disconnected from the Mac. Not seen in six further runs,
and not reproduced by forcing an audio restart in the middle of a drag (which
is now a check in that test). Cause unknown; possibly the real pointer.

## Round 4 — Micke's own song on a cassette (2026-11-13)

Asked for: a demo tape of "Sometimes When I See You Smile" from its nine
stems. Track 1 all vocals; 2 bass, drums, percussion; 3 guitars; 4 keyboards
and other. Levels as they sit in the original mix: nothing normalised.

- [x] Measure the stems (all 48 kHz stereo, 4:39.5, aligned).
- [x] `TapeDub`: the two-passes-of-two-tracks recording that makes the
      built-in demo, lifted out so it can record anything. Checked
      bit-for-bit against the demo as it was before the move.
- [x] Errand `--dub-tape <folder>`: reads `order.json`, sums each track's
      stems to mono ((L+R)/2), applies ONE gain to all four (0 dB here),
      records them through the machine, writes a cassette package.
- [x] Prove it: each track played back through the machine against what
      went in, and the factory mix against the stems mixed the same way.
- [x] Found by that proof: tracks 3 and 4 wandered up to 10 ms against 1 and
      2 (the second pass had its own wow and flutter). Each pass now runs on
      a fresh machine; unit test that fails on the old recorder. The demo
      had the same fault and is cured with it (new copies only).
- [x] Found by the fingerprint: the errand's window, moved aside, was saved
      into Micke's settings. The errand is now headless and runs in any
      build (20 s instead of 17 min); test windows do not save their place.
- [x] `scripts/dub-tape.sh`; cassette on Micke's desk (one new folder,
      nothing else changed; bit-for-bit the copy that was verified).
- [x] Docs, lessons 20–22, commit (stems kept out of git), install.

Result for "Sometimes When I See You Smile" (KROM C-46, NR on, tabs out):

| | lag vs input | likeness | level vs track 2 |
|---|---|---|---|
| Track 1, vocals | +2 frames, steady | 0.99 | −0.35 dB |
| Track 2, drums, bass, percussion | +2 frames by its treble | 0.92 treble (0.71 full band: bass phase turned by the tape path) | 0 |
| Track 3, guitars | +2 frames, steady | 0.97 | +0.10 dB |
| Track 4, keys, synth, other | +1 frame | 0.83 (it is 20 dB quieter; hiss) | +0.21 dB |

Loud moments come back 0.4–0.8 dB down and the very highest sample peaks
are rounded off by up to 6 dB: tape. Not checked: by ear.

## Not done / ideas

- [x] Choose input and output devices in Settings
- [ ] Audio thread reads and writes the memory-mapped tape directly. Works, but a
      RAM window filled by a background queue would rule out page-fault stalls
      and a crash if the disk fills during a take.
- [ ] Stress run of the engine under Thread Sanitizer and Address Sanitizer
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

Engine speed, worst case (two tracks recording, four playing, reverb on),
measured as thread CPU time with the test running alone: 4.3× real time in
Debug, 89× in Release. (Earlier figures of 3.6× and 16× were taken while the
other tests ran in parallel and were pessimistic.)

### Independent review of the engine

A second agent read the audio engine cold. What it found and what was done:

| Finding | Outcome |
|---|---|
| Reverb kept stale buffer indices across a sample-rate change: out-of-bounds write on the audio thread | Fixed; test re-prepares at a quarter of the rate in both modes |
| Head kept reading tape for ~3.7 s after leaving PLAY (float underflow of the capstan), faulting cold pages during a wind | Fixed: reads are gated on the pinch roller actually being engaged |
| Tape was only paged in while moving; nothing warmed the spot it came to rest | Fixed: prefetch on stop and on PLAY/RECORD |
| The whole tape was synced to disk at the instant of punch-out, under the head; eject synced while holding the audio lock | Fixed: sync is deferred until the heads are off, and never done under the lock |
| Recording onto a full disk would crash (sparse file, SIGBUS) | Mitigated: RECORD is refused, with a notice, below 150 MB free. Not eliminated: a disk that fills *during* a take can still do it |
| Rhythm box was latency-compensated as if it came through the audio interface, so a guitar recorded with it landed late | Fixed: sources inside the Mac are treated like tape; tested |
| Reverb/echo on a bounce landed ahead of its dry signal when latency was being compensated | Fixed: the tape path has its own instance of the effect fed with correctly delayed signal; tested |
| First frame of a take from stop was written at full bias; record path lacked the output coupling; stale state when latency appeared | Fixed |
| Input ring replayed its last scraps for ever if the input device vanished | Fixed in the ring and on reconfigure; tested |
| Reading the tape position took the lock the audio thread try-locks, so a knob move could cost a block of audio | Fixed: position is an atomic; the lock is for tape and sample-rate changes only |
| Master recorder not closed on quit; kept recording at the wrong speed after a rate change | Fixed; tested |
| The NaN fuse looked at clipped values and could never blow | Fixed: it watches the signal before any clipping, and counts |
| Overdub offset depended on where the input ring happened to prime (± half a buffer) | Fixed: the age of the input is measured from callback times. Loopback: −0.3 ms, the same on every run |
| Smaller: telemetry default on a collided read, old reverb tail on reconnect, muted clunks queueing up, clunks able to exceed full scale, a lazy global read on the audio thread | Fixed |
| Tests: feedback test passed vacuously; leader test too weak; punch test compared RMS at a 1.6 % margin; claims without assertions; wall-clock performance threshold | Rewritten with real assertions (Goertzel for the punch overlap, meters for the howl, CPU time for speed) |
| Factory panel in REMIX with the sub mix up put an armed track at loop gain 0.988 | Factory panel is now NORM; tested that PLAY still just works and arming is safe |

Idle cost: the installed build sat at 18 % CPU doing nothing, all of it SwiftUI
re-evaluating two always-on timelines (LED meters, master recorder display).
Both now redraw only when what they show changes: under 1 % at rest.

Not done from the review: giving the audio thread a RAM window of tape instead
of touching the memory-mapped file directly (the robust cure for page faults
and for a disk filling mid-take), and a threaded stress run under TSan/ASan.
