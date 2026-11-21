#!/usr/bin/env python3
"""Synthesises Garry's sound cues: short chiptune blips, square and triangle waves with
soft envelopes, 16-bit mono WAV. Original and generated here, so there's nothing to license.

    python3 -I scripts/make-garry-sounds.py <output-dir>
"""
import math, struct, sys, wave, os

RATE = 44100

def note(freq, dur, wave_kind="square", vol=0.32, duty=0.25, attack=0.004, release=0.06):
    n = int(RATE * dur)
    out = []
    for i in range(n):
        t = i / RATE
        phase = (t * freq) % 1.0
        if wave_kind == "square":
            v = 1.0 if phase < duty else -1.0
        elif wave_kind == "triangle":
            v = 4 * abs(phase - 0.5) - 1
        else:
            v = math.sin(2 * math.pi * phase)
        env = min(1.0, t / attack) if attack else 1.0
        tail = (dur - t)
        if tail < release:
            env *= max(0.0, tail / release)
        out.append(v * env * vol)
    return out

def rest(dur):
    return [0.0] * int(RATE * dur)

def mix(*tracks):
    n = max(len(t) for t in tracks)
    return [sum(t[i] for t in tracks if i < len(t)) for i in range(n)]

def hz(name):
    names = {"C": -9, "D": -7, "E": -5, "F": -4, "G": -2, "A": 0, "B": 2}
    letter, octave = name[0], int(name[-1])
    semis = names[letter] + (1 if "#" in name else 0) + (octave - 4) * 12
    return 440.0 * 2 ** (semis / 12)

def seq(notes, kind="square", gap=0.012, **kw):
    out = []
    for name, dur in notes:
        out += note(hz(name), dur, kind, **kw) + rest(gap)
    return out

SOUNDS = {
    # Session starts: a bright rising arpeggio, Garry clocking in.
    "garry-hello-1": lambda: mix(
        seq([("C5", .07), ("E5", .07), ("G5", .07), ("C6", .2)]),
        seq([("C4", .23), ("G4", .2)], "triangle", vol=.22)),
    # Needs your permission: two quick high pings, hard to miss.
    "garry-knock": lambda: seq([("A5", .07), ("E6", .14)], duty=.5, vol=.28) + rest(.04)
        + seq([("A5", .07), ("E6", .14)], duty=.5, vol=.22),
    # Waiting for you: a soft falling pair, a nudge rather than an alarm.
    "garry-nudge-1": lambda: seq([("G5", .12), ("D5", .22)], "triangle", vol=.4, release=.12),
    # Finished: a little cadence and a bubble on top.
    "garry-done-1": lambda: mix(
        seq([("G4", .09), ("C5", .26)], vol=.26),
        rest(.12) + seq([("E6", .04), ("G6", .05)], "sine", gap=.005, vol=.18)),
    # Session starts, gentler: a rounded sine arpeggio.
    "garry-morning": lambda: seq([("G4", .08), ("C5", .08), ("E5", .08), ("G5", .24)], "sine", vol=.45, release=.14),
    # Session starts, with weight: bass step under a short lead.
    "garry-clock-in": lambda: mix(
        seq([("E5", .06), ("G5", .06), ("D6", .18)], duty=.125),
        seq([("C3", .14), ("G3", .2)], "triangle", vol=.3)),
    # Needs you, classic: a two-tone door chime.
    "garry-doorbell": lambda: seq([("E5", .22), ("C5", .34)], "sine", vol=.5, release=.2),
    # Needs you, urgent: three short beeps.
    "garry-beep-beep": lambda: seq([("B5", .06), ("B5", .06), ("B5", .1)], duty=.5, gap=.05, vol=.26),
    # Waiting, barely there: one soft upward blip.
    "garry-psst": lambda: seq([("D5", .05), ("A5", .12)], "triangle", gap=.0, vol=.38, release=.08),
    # Finished, celebratory: a little major-chord stab.
    "garry-ta-da": lambda: mix(
        seq([("C5", .06), ("C5", .3)], gap=.04, vol=.22),
        seq([("E5", .06), ("E5", .3)], gap=.04, vol=.18, duty=.5),
        seq([("G5", .06), ("G5", .3)], "triangle", gap=.04, vol=.24)),
    # Finished, Garry style: a shell tumbling onto the pile.
    "garry-shell-drop": lambda: seq([("A5", .03), ("F5", .03), ("D5", .03), ("A4", .04)], "triangle", gap=.0, vol=.4)
        + rest(.03) + seq([("D3", .09)], "square", duty=.5, vol=.3, release=.08),
    # Plan approved, eager: a quick rising run.
    "garry-charge": lambda: seq([("C5", .04), ("D5", .04), ("E5", .04), ("F5", .04), ("G5", .04), ("A5", .04), ("B5", .04), ("C6", .16)],
                                duty=.25, gap=.004, vol=.26),
    # Plan approved, off he goes: a tiny fanfare.
    "garry-go": lambda: mix(
        seq([("G4", .06), ("G4", .06), ("C5", .06), ("E5", .09), ("G5", .22)]),
        seq([("C4", .3), ("C4", .22)], "triangle", vol=.2)),
    # Numbered takes of the three everyday cues, so the random pick has something to vary.
    # Each keeps its cue's shape (rise, fall, cadence) in a different key or voicing.
    "garry-hello-2": lambda: mix(
        seq([("D5", .07), ("F#5", .07), ("A5", .07), ("D6", .2)], duty=.125),
        seq([("D4", .23), ("A4", .2)], "triangle", vol=.22)),
    "garry-hello-3": lambda: mix(
        seq([("G4", .06), ("C5", .06), ("E5", .06), ("G5", .06), ("C6", .18)], duty=.5, vol=.26),
        seq([("C4", .2), ("E4", .24)], "triangle", vol=.22)),
    "garry-hello-4": lambda: mix(
        seq([("E5", .09), ("G5", .05), ("E5", .05), ("B5", .22)]),
        seq([("E4", .2), ("B3", .22)], "triangle", vol=.22)),
    "garry-nudge-2": lambda: seq([("A5", .12), ("E5", .22)], "triangle", vol=.4, release=.12),
    "garry-nudge-3": lambda: seq([("E5", .08), ("G5", .08), ("D5", .24)], "triangle", vol=.4, release=.14),
    "garry-nudge-4": lambda: seq([("F5", .14), ("C5", .1), ("C5", .16)], "sine", gap=.03, vol=.45, release=.1),
    "garry-done-2": lambda: mix(
        seq([("A4", .09), ("D5", .26)], vol=.26),
        rest(.12) + seq([("F#6", .04), ("A6", .05)], "sine", gap=.005, vol=.18)),
    "garry-done-3": lambda: mix(
        seq([("E4", .07), ("G4", .07), ("C5", .26)], vol=.26),
        rest(.16) + seq([("G6", .04), ("C7", .05)], "sine", gap=.005, vol=.16)),
    "garry-done-4": lambda: mix(
        seq([("G4", .09), ("C5", .09), ("E5", .24)], duty=.5, vol=.22),
        seq([("C4", .3)], "triangle", vol=.22),
        rest(.2) + seq([("C6", .04), ("E6", .06)], "sine", gap=.005, vol=.18)),
}

def tone(freq, dur, vol=.45, attack=.004, release=.02):
    return note(freq, dur, "sine", vol=vol, attack=attack, release=release)

# Pure tones and synthesised effects for the Mission control and Desk sets. A frequency has
# no owner, so these are ours to ship.
EXTRA = {
    # Apollo's Quindar tones: 2525 Hz opened a transmission, 2475 Hz closed it ("over").
    "mission-quindar-in": lambda: tone(2525, .25),
    "mission-quindar-out": lambda: tone(2475, .25),
    # The phone network's special information tones, before "the number you have dialed...".
    "mission-sit": lambda: tone(913.8, .276) + tone(1370.6, .276) + tone(1776.7, .38, release=.06),
    # A cash register: drawer click, then a two-partial bell.
    "desk-ka-ching": lambda: [x * .9 for x in note(180, .03, "square", duty=.5, vol=.5, release=.02)] + rest(.05)
        + mix(note(2093, .5, "sine", vol=.4, release=.4), note(3136, .45, "sine", vol=.22, release=.35),
              note(4186, .3, "sine", vol=.1, release=.25)),
    # Apollo's master alarm, from its spec: a square wave alternating 750 and 2000 Hz, 2.5
    # times a second. There is no clean recording of the real one to cut.
    "mission-master-alarm": lambda: (note(750, .2, "square", duty=.5, vol=.2, release=.01)
                                     + note(2000, .2, "square", duty=.5, vol=.2, release=.01)) * 3,
    # Morse at 700 Hz, 22 words a minute: "OK", and "SK", the sign-off at the end of a contact.
    "signal-morse-ok": lambda: morse("--- -.-"),
    "signal-morse-sk": lambda: morse("...-.-"),
    # A sonar ping: a short tone with a long, slightly lower echo tail.
    "signal-sonar": lambda: mix(
        note(1480, .9, "sine", vol=.5, attack=.002, release=.85),
        rest(.28) + note(1470, .9, "sine", vol=.16, attack=.05, release=.8),
        rest(.6) + note(1465, .8, "sine", vol=.07, attack=.08, release=.7)),
    # A radio time signal: three short pips and the long one on the hour.
    "signal-time-pips": lambda: (tone(1000, .1) + rest(.22)) * 3 + tone(1000, .5, release=.03),
}

def morse(code, freq=700, unit=.055):
    out = []
    for symbol in code:
        if symbol == " ":
            out += rest(unit * 2)  # with the gap after the last element: 3 units between letters
        else:
            out += tone(freq, unit * (3 if symbol == "-" else 1), vol=.4, attack=.004, release=.006) + rest(unit)
    return out

def write(path, samples):
    peak = max(1e-9, max(abs(s) for s in samples))
    scale = min(1.0, 0.89 / peak)
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s * scale)) * 32767)) for s in samples))

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)
    for name, make in {**SOUNDS, **EXTRA}.items():
        write(os.path.join(out, name + ".wav"), make())
        print(name)
