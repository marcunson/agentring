"""An original, quiet instrumental loop, rendered locally without external assets."""

from functools import lru_cache

import numpy as np


@lru_cache(maxsize=4)
def _loop(sample_rate: int) -> bytes:
    length = sample_rate * 8
    tail = int(sample_rate * 1.2)
    mix = np.zeros(length + tail, dtype=np.float64)
    # Four gentle arpeggios, half a second per note. Wrap the final decay into
    # the next repeat so the loop has no abrupt boundary.
    chords = [(60, 64, 67, 71), (57, 60, 64, 67), (62, 65, 69, 72), (55, 59, 62, 67)]
    t = np.arange(tail) / sample_rate
    envelope = np.minimum(t / 0.015, 1) * np.exp(-t * 4.5) * np.minimum((1.2 - t) / 0.08, 1)
    for index, note in enumerate(n for chord in chords for n in chord):
        frequency = 440 * 2 ** ((note - 69) / 12)
        phase = 2 * np.pi * frequency * t
        sound = (np.sin(phase) + 0.18 * np.sin(2 * phase)) * envelope
        start = int(index * sample_rate / 2)
        mix[start:start + tail] += sound
    mix[:tail] += mix[length:]
    samples = mix[:length]
    samples *= 2400 / max(float(np.max(np.abs(samples))), 1e-9)
    return samples.astype("<i2").tobytes()


class HoldMusic:
    """PCM16 mono at the call backend's rate; fade in on each return from speech."""

    def __init__(self, sample_rate: int):
        self.sample_rate = sample_rate
        self._pcm = _loop(sample_rate)
        self._offset = 0
        self._fade_samples = 0

    def fade_in(self) -> None:
        self._fade_samples = 0

    def read(self, samples: int) -> bytes:
        size = samples * 2
        output = bytearray()
        while size:
            count = min(size, len(self._pcm) - self._offset)
            output += self._pcm[self._offset:self._offset + count]
            self._offset = (self._offset + count) % len(self._pcm)
            size -= count
        fade_length = self.sample_rate // 10
        if self._fade_samples < fade_length:
            gain = np.minimum((np.arange(samples) + self._fade_samples) / fade_length, 1)
            output = (np.frombuffer(output, dtype="<i2") * gain).astype("<i2").tobytes()
        self._fade_samples += samples
        return bytes(output)
