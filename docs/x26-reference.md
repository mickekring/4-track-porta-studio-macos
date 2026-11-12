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
  (`ControlFrame.recordLatency`), while tape-to-tape bounces stay aligned.
- The rhythm box, reverb, master recorder and foot switch on the desk are
  generic stand-ins for the gear the manual tells you to plug in.

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

- Tests: `xcodebuild test -project X2026/X2026.xcodeproj -scheme X2026 -destination 'platform=macOS'`
- End-to-end run of the real app (debug builds): launch the built binary with
  `--self-test`. It inserts a scratch tape by hand, records the rhythm box,
  rewinds by counter, plays back, fast-forwards to the end and ejects,
  printing what it sees.
- Re-render the app icon: launch a debug build with `--render-icon <folder>`
  (inside the app's container) and copy the PNGs into `AppIcon.appiconset`.
- Cassettes live in the app's container under `Application Support/Tapes`.
