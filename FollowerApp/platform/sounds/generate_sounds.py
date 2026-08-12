#!/usr/bin/env python3
"""Generates the follower's notification alert tones.

The tones are synthesised rather than sourced so the repository carries no
third-party audio and no licensing question. Re-running this script reproduces
the committed .wav files byte for byte.

Format is deliberately conservative: 16-bit PCM mono at 44.1 kHz, which both
UNNotificationSound (iOS, under 30 seconds) and Android's res/raw accept
without conversion.

    python3 generate_sounds.py
"""

import math
import os
import struct
import wave

SAMPLE_RATE = 44100
AMPLITUDE = 0.55


def tone(frequency, seconds, fade=0.01):
    """A sine tone with short fades, so it starts and ends without a click."""
    total = int(SAMPLE_RATE * seconds)
    fade_samples = max(1, int(SAMPLE_RATE * fade))
    samples = []
    for index in range(total):
        value = math.sin(2 * math.pi * frequency * index / SAMPLE_RATE)
        if index < fade_samples:
            value *= index / fade_samples
        elif index > total - fade_samples:
            value *= (total - index) / fade_samples
        samples.append(value * AMPLITUDE)
    return samples


def silence(seconds):
    return [0.0] * int(SAMPLE_RATE * seconds)


def write(name, samples):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name)
    with wave.open(path, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        frames = b"".join(
            struct.pack("<h", max(-32768, min(32767, int(value * 32767))))
            for value in samples
        )
        handle.writeframes(frames)
    print(f"wrote {name} ({len(samples) / SAMPLE_RATE:.2f}s)")


# Gentle: one soft mid tone. For alerts the user wants to notice, not react to.
write("alert_gentle.wav", tone(660, 0.32) + silence(0.08) + tone(880, 0.36))

# Standard: a rising two-tone chime, the default for low and high alerts.
write(
    "alert_standard.wav",
    tone(784, 0.18) + silence(0.06) + tone(1047, 0.18) + silence(0.06) + tone(1319, 0.28),
)

# Urgent: a fast, insistent triple burst, repeated. For urgent low and high,
# where the point is to be hard to sleep through.
urgent = []
for _ in range(3):
    for _ in range(3):
        urgent += tone(1568, 0.09, fade=0.005) + silence(0.05)
    urgent += silence(0.18)
write("alert_urgent.wav", urgent)
