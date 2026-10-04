#!/usr/bin/env python3
"""STEMEKI beat finder: every beat and downbeat of the whole song (Beat This!, JKU Linz, MIT).

Usage: beats.py <stems folder>
Reads the four stems, sums them back into the mix, and prints JSON:
{"beats": [seconds...], "downbeats": [seconds...]}
"""
import json
import os
import sys
import warnings

warnings.filterwarnings("ignore")

import numpy as np
import soundfile as sf


def main():
    folder = sys.argv[1]
    mix, sr = None, None
    for k in ("drums", "bass", "other", "vocals"):
        y, sr = sf.read(os.path.join(folder, k + ".wav"), dtype="float32", always_2d=True)
        m = y.mean(axis=1)
        mix = m if mix is None else mix[: len(m)] + m[: len(mix)]
    from beat_this.inference import Audio2Beats
    a2b = Audio2Beats(checkpoint_path="final0", device="cpu", dbn=False)
    beats, downbeats = a2b(mix, sr)
    print(json.dumps({"beats": [round(float(b), 5) for b in beats],
                      "downbeats": [round(float(b), 5) for b in downbeats]}), flush=True)


if __name__ == "__main__":
    main()
