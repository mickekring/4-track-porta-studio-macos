# The X-26, and how the X-2026 copies it

Everything here comes from the Fostex X-26 Owner's Manual (printed in Japan,
July 1988) unless marked otherwise. Page numbers are the printed ones.
"Inferred" means the manual does not say and we made a choice.

## What it is

A four-track cassette multitracker with a six-input mixer, released 1988,
£299 at launch in the UK. Two mic/line channels with faders, four line
channels that double as tape returns, one stereo buss, one mono AUX buss.
Records up to two tracks at a time. Mechanical piano-key transport. No
return-to-zero, no pause, no eject key.

## Specifications (p.27) and what the emulation does with them

| Spec | X-26 | X-2026 |
|---|---|---|
| Tape speed | 4.75 cm/s (1⅞ ips) | `CassetteStandard.nominalSpeed` = 4.7625 cm/s |
| Fast wind time | 105 s (no length given; C-60 inferred from the sibling X-18's "120 sec (C-60)") | Wind motor calibrated so a full C-60 takes 105 s. Other lengths follow from their turns of tape. Tested. |
| Pitch control | ±10 % on p.8, ±15 % in the spec table | ±10 % (`TapeDeck.Calibration.pitchRange`) |
| Wow & flutter | ±0.15 % | Capstan, pinch roller and reel components plus random drift, about 0.1 % RMS |
| Frequency response | 40 Hz – 12.5 kHz (recorder) | Head-bump highpass at 36 Hz, gap-loss lowpass around 13 kHz |
| S/N | 58 dB A-weighted (with Dolby B, per third-party listings) | Bare tape hiss 52 dB below the 0 mark; NR buys back up to 10 dB of treble hiss |
| Channel separation | 45 dB at 1 kHz | Adjacent-track crosstalk at -45 dB |
| Erasure | 70 dB | Erase head wipes to zero |
| Equaliser | ±12 dB at 100 Hz and 10 kHz (panel says ±10) | Shelving (inferred), on the stereo buss before MASTER |
| Tape | Type II, C-60 and C-90; never C-120 | C-46, C-60, C-90 |
| Tracks | 4, one direction | Same. Flipping the cassette plays all four backwards. |
| Size | 380 × 195 × 69 mm | Panel laid out at 380 × 195 mm from the drawing on p.6 |

## Signal flow (block diagram, p.27)

- **Channels 1–2**: jack → MIC/LINE preamp → INPUT fader → PAN → stereo buss.
  AUX 1–2 are **post-fader**.
- **Channels 3–6**: paired with tape tracks 1–4. Each strip's AUX knob and
  GAIN knob is a centre-zero pot with the LINE input on one end and the tape
  track on the other: left of centre brings up the input, right the track,
  never both. AUX 3–6 are **pre-fader** and independent of GAIN.
- **Sub mix**: GAIN 3–6 → SUB PAN → a stereo sub buss. REMIX puts it on the
  stereo buss; in NORM it reaches only the monitor (LINE + SUB MIX position).
- **Stereo buss**: channels 1–2 + AUX RCV L/R (+ sub mix in REMIX) → EQ →
  MASTER → LINE OUT, the meters (MIXER position), and the REC TRK selectors.
  **L feeds track 1 or 3, R feeds track 2 or 4.** EQ and MASTER are recorded.
- **AUX buss** (mono): AUX 1–6 → AUX SEND master → AUX SEND jack, meter 4
  (MIXER position), monitor selector.
- **Monitor**: LINE + AUX / AUX / LINE + SUB MIX → MONITOR knob → PHONES.
- **Track outputs**: an armed track passes its *input* (input monitor)
  except in plain PLAY, when it plays the tape. Unarmed tracks always play
  the tape. There is one combined record/play head, so you can never hear a
  track off the tape while recording it.

Implemented in `Engine/MachineDSP.swift`; the doc comment at the top of
`MachineDSP` restates it.

### Consequences the manual warns about, which the emulation reproduces

- Tape tracks are silent in the phones until you raise AUX n toward TRK
  (monitor on AUX) or SUB GAIN toward TRK (LINE + SUB MIX, or REMIX).
- An armed track fed back to its own buss howls (p.7, p.28). The loop is
  real here too; it is bounded by the op-amp rails and never goes to NaN.
- An armed instrument cuts out when you press PLAY to rehearse (p.28).
- LINE inputs 3–6 only reach tape in REMIX (p.28).
- Bouncing to the track next door can oscillate (p.21): the record head
  leaks into the neighbouring playback tracks (`MachineDSP.recordLeak`).

## Lamps and meters

Four LED columns of seven segments: +6 +3 0 −3 −6 −10 −20. TAPE: tracks 1–4.
MIXER: L, R, (dark), AUX SEND. Under them, four tri-colour arrows (p.8):

| Colour | Meaning |
|---|---|
| Green | Tape monitor: unarmed, or armed and in PLAY |
| Amber | Armed and in STOP / FF / REW: input monitor |
| Red | Recording |

## Transport

- RECORD alone enters record; it need not be pressed with PLAY (p.8). With no
  track armed it simply plays.
- Punch in/out three ways (p.17): foot switch while in PLAY; sliding REC TRK
  on and off while in RECORD; pressing RECORD while in PLAY.
- Counter: three digits, mechanical, belt-driven, reset button, no memory. It
  counts hub turns. Which hub drives it is not documented; we use the take-up
  hub at 0.6 digits per turn (inferred; a C-60 reads about 480 end to end).
- Auto-stop at the end of the tape is not mentioned in the manual. We have
  one (inferred): the keys spring up about half a second after the tape stalls.
- Record-protect tabs inhibit recording (p.28).

## Things we added that are physics rather than manual

- **Leader**: the first and last 24 cm of every cassette are non-magnetic.
- **Erase-head gap**: the erase head is 12.5 mm upstream of the record head.
  Punch-in leaves the old take underneath for 0.26 s (attenuated by the bias);
  punch-out leaves 0.26 s of silence.
- **Wind speed** depends on the radius of the pack being driven, so the
  counter races at one end of the tape and crawls at the other.
- **Run-in**: the capstan takes about a quarter of a second to pull the tape
  up to speed, and you can hear it.
- **Noise reduction** is a sliding single-band compander with encoder and
  decoder sharing one side chain. It is our own design ("Brusfri"), not
  Dolby's, and carries no Dolby marks.

## Things that are deliberately not the X-26

- The name and logo. The machine is a Brustex X-2026; "brus" is Swedish for
  hiss. No Fostex or Dolby names or marks appear in the app.
- Overdubs are shifted to cancel the Mac's audio round trip
  (`ControlFrame.recordLatency`). Signal that never makes that trip — tape
  tracks, the rhythm box — is held back by the same amount on its way to the
  record head, so bounces stay aligned; the effects box has a twin on the
  tape path for the same reason. See "Live and late" in `MachineDSP.render`.
- The factory panel is in REMIX, the manual's mixdown set-up, so that the
  first things anyone tries on a tape (SUB GAIN, SUB PAN, EQ, MASTER) all act
  on it. Arming a track in that state is the feedback loop described above;
  the first time it happens the machine says so in words and names the knob.
- The desk is an overview. A click on the X-2026, the rhythm box, the reverb
  or the master recorder zooms in until it fills the window, and only then do
  its controls answer (`Desk.focus`).
- The rhythm box, reverb, master recorder and foot switch on the desk are
  generic stand-ins for the gear the manual tells you to plug in.
- The machine plays through and records from whatever is chosen in System
  Settings → Sound, and follows it when it changes. It has no device pickers
  of its own, and `AudioHost` never sets a device: with a separate input and
  output the engine runs a private aggregate of the two, and re-asserting a
  device from the "configuration changed" handler restarts it for ever (the
  AirPods freeze). Changes are debounced and fused (`restartAfterChange`);
  a start that fails is tried again by the clock (`retryLater`).
- Silence is explained in words, because it reads as a broken app
  (`Machine.trouble`): audio that will not start, with the reason; an input
  jack the Mac will not let the machine hear, or has no device for. And,
  once, that a Bluetooth headset drops to hands-free mode while its
  microphone is open.

## Working on the code

```
X2026/X2026/
  Tape/      geometry of the cassette, memory-mapped oxide file
  DSP/       filters, noise reduction, tape channel, reverb, mechanical sounds
  Engine/    transport, mixer + recorder core, audio host, accessories' DSP
  Machine/   main-actor model: panel, keys, cassette well, persistence
  Library/   cassettes on disk (label.json + oxide.pcm per cassette)
  UI/        faceplate, controls, cassette art, desk, hand, accessories
```

- **The build to use is the one in `/Applications`.** `./scripts/install.sh`
  builds the optimised app and installs it there (it refuses if that copy is
  running). Xcode's Run, the unit tests and the previews still build to
  DerivedData, because they need a debug build.
- Tests: `xcodebuild test -project X2026/X2026.xcodeproj -scheme X2026 -destination 'platform=macOS'`
- **Test runs never work at the owner's desk.** Unit tests, previews, the
  icon errand and every flag below get `Machine.onScratchDesk()`: factory
  settings and an empty tape library in a temporary folder
  (`tmp/x2026-scratch/<uuid>`, removed on quit; strays are swept after a
  day). They cannot see the owner's cassettes, settings or mixdowns. This is
  not a nicety: before it existed, a test recorded on the owner's cassette.
  Any launch argument starting with `--` puts a debug build on a scratch
  desk (`leavesNoTrace` in `X2026App`), so a new flag is isolated by default.
  Their window does not save its position either (AppKit would write it
  into the owner's settings as if it were theirs).
- End-to-end run of the real app (debug builds): launch the built binary with
  `--self-test`. It inserts a scratch tape by hand, records the rhythm box,
  rewinds by counter, plays back, fast-forwards to the end and ejects,
  printing what it sees.
- Mouse gestures (debug builds): launch the built binary with `--touch-test`.
  It sends synthetic mouse events to the app's own window — zooming in and
  out, keys, faders, knobs, switches, lid, cassettes, then mixing the demo
  tape by dragging its knobs — and checks the machine felt each one. It runs
  in the background: the views it clicks are made to accept "first mouse", so
  it needs neither the foreground nor the real pointer.
- Hardware round trip (debug builds, needs the BlackHole virtual device):
  `--loopback-test` overdubs track 1 onto track 2 out of and back into that
  device (`AudioHost.loopbackDevice`, the one case where devices are set by
  hand) and reports how far apart they land. It fails unless track 2 is
  recognisably track 1, so it cannot pass while listening to something else.
- A real input (debug builds): `--input-test` plugs the Mac's default input
  into INPUT 1 and checks that audio settles, the tape runs in real time, the
  input lands on tape and unplugging lets the microphone go. Run it with the
  input you care about selected (a Bluetooth headset is the awkward one; it
  goes into hands-free mode for the half minute the test takes).
- Mixdown (debug builds): `--mixdown-test` records a demo cassette and mixes
  fifteen seconds of it to a WAV with the master recorder.
- Re-render the app icon: launch a debug build with `--render-icon <folder>`
  (inside the app's container) and copy the PNGs into `AppIcon.appiconset`.
- Cassettes live in the app's container under `Application Support/Tapes`.

## Dubbing a cassette from stems

To put finished music on a cassette (a song's stems, say) without playing it
in by hand:

```
./scripts/dub-tape.sh <folder> [<folder to keep the proof in>]
```

`<folder>` holds the audio files (48 kHz; anything macOS can read) and an
`order.json`:

```json
{
  "title": "What to write on the label",
  "design": "krom",
  "minutes": 46,
  "noiseReduction": true,
  "recordProtected": true,
  "gain": 0,
  "tracks": [
    { "note": "Vocals", "files": ["lead.mp3", "backing.mp3"] },
    { "note": "Drums and bass", "files": ["drums.mp3", "bass.mp3"] },
    { "note": "Guitars", "files": ["guitar.mp3"] },
    { "note": "Keys", "files": ["keys.mp3"] }
  ]
}
```

What happens (`Machine/TapeDub.swift`):

- Each track's files are folded to mono, (L+R)/2, and summed. Nothing is
  normalised. `gain` is one figure in dB for all four tracks, so they keep
  the balance they have in the files; at 0, digital full scale lands 12 dB
  over the meters' 0 mark, which puts an ordinary mix about where a
  recordist would.
- A second X-2026 behind the scenes records them the way the machine does:
  INPUT 1 and 2, faders at their 0 mark, panned hard left and right, onto
  tracks 1 and 2; then again onto tracks 3 and 4. Same record path, noise
  reduction, saturation and hiss as at the desk. This is also how the
  built-in demo is made.
- Each pass runs on a machine switched on fresh, so wow and flutter take the
  same course both times and the two pairs of tracks are in step to the
  sample. (Recorded on one machine carried over from pass to pass they
  drifted up to 10 ms apart: a dub is fed by the clock, with nobody playing
  along to the tape.)
- The tape is left at the start, one second before the music.
- Proof, if asked for: `in N.wav` is what went into the jack for track N,
  `out N.wav` the track played back alone (SUB GAIN full, SUB PAN centre),
  `mix.wav` all four with the factory panel.

The errand itself is `X2026 --dub-tape <folder>` (any build). It runs before
there is a machine or a window, works only inside the folder it is given
(which must be inside the app's container; the script sees to that), and
quits. The script then moves the finished cassette into the library, and
that is the only thing it touches there. A running X-2026 sees the new
cassette the next time it starts.

Play such a tape with the NR switch where `noiseReduction` says. SUB GAIN is
at unity with the knob at three o'clock (0.8); with all four there and SUB
PAN to taste, the mix is the one in the files.

