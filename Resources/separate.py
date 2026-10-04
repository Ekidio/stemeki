#!/usr/bin/env python3
"""STEMEKI szétválasztó: Demucs 4 (htdemucs) az Apple GPU-n.

Használat: separate.py <bemenet> <kimeneti-mappa>
Négy stemet ír 32 bites float WAV-ba, vágás és átskálázás nélkül
(drums, bass, other, vocals), így az összegük a dal maga.
Haladás a stdout-on: "PROGRESS 0.42" sorok.
"""
import os
import sys
import types
import warnings

warnings.filterwarnings("ignore")

import numpy as np
import soundfile as sf
import torch
import demucs.apply
from demucs.apply import apply_model
from demucs.pretrained import get_model
from demucs.separate import load_track


def progress(x):
    print(f"PROGRESS {x:.4f}", flush=True)


class _Progress:
    """A demucs belső tqdm-je helyett: haladás sorokban."""

    def __init__(self, it, **kw):
        self.items = list(it)

    def __iter__(self):
        n = len(self.items)
        for i, item in enumerate(self.items):
            yield item
            progress(0.05 + 0.9 * (i + 1) / n)


demucs.apply.tqdm = types.SimpleNamespace(tqdm=_Progress)


def main():
    src, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    progress(0.0)
    model = get_model("htdemucs")
    model.eval()
    wav = load_track(src, model.audio_channels, model.samplerate)
    progress(0.03)
    ref = wav.mean(0)
    mean, std = ref.mean(), ref.std()
    wav = (wav - mean) / std
    with torch.no_grad():
        sources = apply_model(model, wav[None], device=device, shifts=1,
                              split=True, overlap=0.25, progress=True)[0]
    sources = sources * std + mean
    for source, name in zip(sources, model.sources):
        data = source.cpu().numpy().T.astype(np.float32)
        sf.write(os.path.join(out, name + ".wav"), data, model.samplerate,
                 subtype="FLOAT")
    progress(1.0)
    print("DONE", flush=True)


if __name__ == "__main__":
    main()
