#!/usr/bin/env python3
"""STEMEKI elemző: tempó, ütemrács (egyesek), dob belépése, hangnem.

Használat: analyze.py <stem-mappa>
A mappában: drums.wav, bass.wav, other.wav (vocals.wav nem kell).
A kimenet egy JSON sor a stdout-on.
"""
import json
import sys
import os
import warnings

warnings.filterwarnings("ignore")

import numpy as np
import librosa

SR = 22050
HOP = 256


def load(folder, name):
    path = os.path.join(folder, name + ".wav")
    if not os.path.exists(path):
        return None
    y, _ = librosa.load(path, sr=SR, mono=True, dtype=np.float32)
    return y


def frames_to_time(f):
    return f * HOP / SR


def drum_entry(drums):
    """Az első pont, ahol a dob tartósan megszólal (mp)."""
    rms = librosa.feature.rms(y=drums, frame_length=2048, hop_length=HOP)[0]
    ref = np.percentile(rms, 95)
    if ref < 1e-4:
        return None
    db = 20 * np.log10(np.maximum(rms, 1e-9) / ref)
    win = int(2.0 * SR / HOP)  # 2 mp-en át tartsa
    loud = db > -24
    for i in range(len(db) - win):
        if loud[i] and np.mean(db[i:i + win]) > -18:
            return frames_to_time(i)
    return frames_to_time(int(np.argmax(loud)))


def peak_near(env, t, radius):
    """Az onset-burkoló csúcsa t körül, parabolikus finomítással (mp)."""
    c = t * SR / HOP
    lo = max(0, int(c - radius))
    hi = min(len(env) - 1, int(c + radius) + 1)
    if hi - lo < 3:
        return None, 0.0
    i = lo + int(np.argmax(env[lo:hi]))
    if 0 < i < len(env) - 1:
        a, b, d = env[i - 1], env[i], env[i + 1]
        den = a - 2 * b + d
        off = 0.5 * (a - d) / den if den != 0 else 0.0
    else:
        off = 0.0
    return frames_to_time(i + off), float(env[i])


def fit_grid(env, beats, period, start, end):
    """Állandó tempójú rács illesztése: periódus + fázis, robusztus regresszióval."""
    t0 = beats[0]
    for _ in range(3):
        n = int((end - t0) / period)
        idx, ts, ws = [], [], []
        for k in range(n + 1):
            pred = t0 + k * period
            if pred < start or pred > end:
                continue
            t, w = peak_near(env, pred, 0.12 * period * SR / HOP)
            if t is None or w <= 0:
                continue
            idx.append(k), ts.append(t), ws.append(w)
        if len(idx) < 8:
            break
        idx, ts, ws = np.array(idx, float), np.array(ts), np.array(ws)
        keep = np.ones(len(idx), bool)
        for _ in range(4):
            A = np.vstack([idx[keep], np.ones(keep.sum())]).T
            sol, *_ = np.linalg.lstsq(A * np.sqrt(ws[keep])[:, None],
                                      ts[keep] * np.sqrt(ws[keep]), rcond=None)
            res = ts - (sol[0] * idx + sol[1])
            keep = np.abs(res) < 0.08 * sol[0]
            if keep.sum() < 8:
                break
        period, t0 = float(sol[0]), float(sol[1])
    return period, t0


def refine_phase(folder, grid, radius=0.03):
    """A rács finomhangolása mintapontosan a dob ütéseinek kezdetére."""
    y, sr = librosa.load(os.path.join(folder, "drums.wav"), sr=None, mono=True,
                         dtype=np.float32)
    win, hop = 64, 8
    n = (len(y) - win) // hop
    if n <= 0:
        return 0.0
    frames = np.lib.stride_tricks.as_strided(
        y, shape=(n, win), strides=(y.strides[0] * hop, y.strides[0]))
    loge = np.log10(np.mean(frames ** 2, axis=1) + 1e-10)
    rise = np.diff(loge, prepend=loge[0])
    offs = []
    r = int(radius * sr / hop)
    for t in grid[:400]:
        c = int(t * sr / hop)
        lo, hi = max(0, c - r), min(len(rise), c + r)
        if hi - lo < 4:
            continue
        seg = rise[lo:hi]
        if seg.max() < 0.3:  # nincs határozott ütés
            continue
        offs.append((lo + int(np.argmax(seg))) * hop / sr + win / 2 / sr - t)
    if len(offs) < 4:
        return 0.0
    return float(np.median(offs))


def hit_list(path, start, lowpass=None):
    """Sample-accurate hits of a stem (time, strength), optionally low-passed (kicks)."""
    y, sr = librosa.load(path, sr=None, mono=True, dtype=np.float32)
    if lowpass:
        from scipy.signal import butter, sosfiltfilt
        # Zero-phase, so the kick times are not delayed by the filter.
        y = np.ascontiguousarray(sosfiltfilt(butter(4, lowpass, btype="low", fs=sr, output="sos"), y), dtype=np.float32)
    win, hop = 64, 16
    n = (len(y) - win) // hop
    if n <= 8:
        return np.zeros(0), np.zeros(0)
    fr = np.lib.stride_tricks.as_strided(y, shape=(n, win), strides=(y.strides[0] * hop, y.strides[0]))
    e = np.log10(np.mean(fr ** 2, axis=1) + 1e-10)
    rise = np.r_[np.zeros(4), e[4:] - e[:-4]]
    top = e.max()
    gap = int(0.05 * sr / hop)
    ts, ws = [], []
    i = int(start * sr / hop)
    while i < n:
        if rise[i] > 0.3 and e[i] > top - 4.0:
            b = i + int(np.argmax(rise[i:i + 12]))
            ts.append(((b - 2) * hop + win / 2) / sr)
            ws.append(max(1e-3, rise[b] * (e[b] - (top - 4.0))))
            i = b + gap
        else:
            i += 1
    return np.array(ts), np.array(ws)


def coherent_tempo(ts, ws, guess):
    """BPM and beat phase that line up the most hits (weighted), searched finely around a guess."""
    best = (0.0, guess, 0.0)
    for lo, hi, step in ((guess * 0.96, guess * 1.04, 0.01), (None, None, 0.0005)):
        if lo is None:
            lo, hi = best[1] - 0.02, best[1] + 0.02
        for bpm in np.arange(lo, hi, step):
            z = np.sum(ws * np.exp(2j * np.pi * ts * bpm / 60.0))
            c = abs(z)
            if c > best[0]:
                best = (c, bpm, np.angle(z))
    _, bpm, ang = best
    period = 60.0 / bpm
    phase = (-ang / (2 * np.pi)) * period  # a beat falls at phase + k*period
    return bpm, phase % period


def regress_hits(ts, ws, period, t0):
    """Least-squares line through the hits that sit on the beat: exact period and phase."""
    for tol in (0.12, 0.06, 0.03):
        k = np.round((ts - t0) / period)
        res = ts - (t0 + k * period)
        on = np.abs(res) < tol * period
        if on.sum() < 16:
            break
        w = np.sqrt(ws[on])
        A = np.vstack([k[on], np.ones(on.sum())]).T
        sol, *_ = np.linalg.lstsq(A * w[:, None], ts[on] * w, rcond=None)
        period, t0 = float(sol[0]), float(sol[1])
    return period, t0


def coherence(ts, ws, bpm):
    return abs(np.sum(ws * np.exp(2j * np.pi * ts * bpm / 60.0))) / max(ws.sum(), 1e-9)


def prefer_whole_bpm(ts, ws, bpm, t0):
    """Produced music is almost always on a whole BPM: take it when it fits as well."""
    whole = round(bpm)
    if abs(bpm - whole) > 0.06 or abs(bpm - whole) < 1e-6:
        return bpm, t0
    if coherence(ts, ws, whole) < 0.97 * coherence(ts, ws, bpm):
        return bpm, t0
    period = 60.0 / whole
    # Same phase fit as before, with the period fixed.
    for tol in (0.12, 0.06, 0.03):
        k = np.round((ts - t0) / period)
        res = ts - (t0 + k * period)
        on = np.abs(res) < tol * period
        if on.sum() < 16:
            break
        t0 += float(np.average(res[on], weights=ws[on]))
    return float(whole), t0


def onset_env(y, fmax=None):
    S = librosa.feature.melspectrogram(y=y, sr=SR, hop_length=HOP, n_mels=64,
                                       fmax=fmax or SR / 2)
    return librosa.onset.onset_strength(S=librosa.power_to_db(S).astype(np.float32), sr=SR,
                                        hop_length=HOP)


def estimate_tempo(env, start, end):
    """Tempó autokorrelációval (70-180 BPM), plusz az első ütés fázisa."""
    a = int(start * SR / HOP)
    b = int(end * SR / HOP)
    x = env[a:b].astype(np.float64)
    if len(x) < 4 * SR / HOP:
        return None, None
    x = x - x.mean()
    n = 1 << int(np.ceil(np.log2(2 * len(x))))
    ac = np.fft.irfft(np.abs(np.fft.rfft(x, n)) ** 2)[:len(x)]
    fps = SR / HOP
    best, best_lag = -np.inf, None
    for bpm10 in range(700, 1800):
        lag = fps * 60.0 / (bpm10 / 10.0)
        i = int(lag)
        if i + 1 >= len(ac):
            continue
        v = ac[i] + (lag - i) * (ac[i + 1] - ac[i])
        # a dupla periódus is erősítse (ütem-szint)
        j = 2 * lag
        if int(j) + 1 < len(ac):
            v += 0.5 * (ac[int(j)] + (j - int(j)) * (ac[int(j) + 1] - ac[int(j)]))
        bpm = bpm10 / 10.0
        v *= np.exp(-0.5 * (np.log2(bpm / 120.0) / 0.9) ** 2)
        if v > best:
            best, best_lag = v, lag
    if best_lag is None:
        return None, None
    # fázis: melyik eltolásnál a legnagyobb a fésű összege
    L = best_lag
    phases = np.arange(int(np.ceil(L)))
    sums = [x[np.round(np.arange(p, len(x) - 1, L)).astype(int)].sum() for p in phases]
    p = phases[int(np.argmax(sums))]
    return 60.0 * fps / L, start + p / fps


def sample_env(env, t):
    i = int(round(t * SR / HOP))
    if 0 <= i < len(env):
        return float(env[max(0, i - 1):i + 2].max())
    return 0.0


def downbeat_phase(beat_times, entry, drums, bass, harm):
    """Melyik ütés az „egyes” a négy közül."""
    feats = []
    if bass is not None and np.abs(bass).max() > 1e-3:
        feats.append(onset_env(bass, fmax=300))
    feats.append(onset_env(drums, fmax=150))  # lábdob
    if harm is not None:
        chroma = librosa.feature.chroma_stft(y=harm, sr=SR, hop_length=HOP)
        chroma = librosa.util.normalize(chroma, axis=0)
        change = np.r_[0, np.linalg.norm(np.diff(chroma, axis=1), axis=0)]
        change = np.convolve(change, np.ones(9) / 9, mode="same")
        feats.append(change)

    scores = np.zeros(4)
    for env in feats:
        ph = np.zeros(4)
        cnt = np.zeros(4)
        for k, t in enumerate(beat_times):
            ph[k % 4] += sample_env(env, t)
            cnt[k % 4] += 1
        ph = ph / np.maximum(cnt, 1)
        if ph.mean() > 0:
            scores += ph / ph.mean()
    # A dob belépése szinte mindig egyesre esik.
    if entry is not None:
        k_entry = int(np.argmin(np.abs(np.array(beat_times) - entry)))
        scores[k_entry % 4] += 0.35
    return int(np.argmax(scores))


MAJOR = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
MINOR = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
NAMES = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
# Camelot: dúr = B, moll = A
CAMELOT_MAJ = {0: 8, 7: 9, 2: 10, 9: 11, 4: 12, 11: 1, 6: 2, 1: 3, 8: 4, 3: 5, 10: 6, 5: 7}
CAMELOT_MIN = {9: 8, 4: 9, 11: 10, 6: 11, 1: 12, 8: 1, 3: 2, 10: 3, 5: 4, 0: 5, 7: 6, 2: 7}


def detect_key(harm):
    if harm is None or np.abs(harm).max() < 1e-3:
        return None, None
    chroma = librosa.feature.chroma_stft(y=harm, sr=SR, n_fft=8192, hop_length=2048)
    prof = chroma.sum(axis=1)
    best = (-2, 0, True)
    for r in range(12):
        p = np.roll(prof, -r)
        for maj, tmpl in ((True, MAJOR), (False, MINOR)):
            c = np.corrcoef(p, tmpl)[0, 1]
            if c > best[0]:
                best = (c, r, maj)
    _, root, maj = best
    name = NAMES[root] + ("" if maj else "m")
    cam = f"{CAMELOT_MAJ[root]}B" if maj else f"{CAMELOT_MIN[root]}A"
    return name, cam


def main():
    folder = sys.argv[1]
    drums = load(folder, "drums")
    bass = load(folder, "bass")
    other = load(folder, "other")
    if drums is None:
        print(json.dumps({"error": "no drums.wav"}))
        return
    duration = len(drums) / SR
    harm = None
    if other is not None and bass is not None:
        harm = other + bass
    elif other is not None:
        harm = other

    entry = drum_entry(drums)
    source = drums
    if entry is None:  # nincs dob: a kíséretből keressük a ritmust
        source = harm if harm is not None else drums
        entry = 0.0

    env = onset_env(source)
    start = entry
    end = duration
    s0 = int(start * SR / HOP)
    tempo, first = estimate_tempo(env, start, end)
    if tempo is None:
        print(json.dumps({"error": "no beat found", "duration": duration,
                          "drumStart": entry}))
        return
    beats = [first]

    period, t0 = fit_grid(env, beats, 60.0 / tempo, start, end)
    bpm = 60.0 / period

    # Precise tempo and phase from the kicks (hi-hats between them would pull the phase).
    kick_phase = False
    if source is drums:
        dpath = os.path.join(folder, "drums.wav")
        ts, ws = hit_list(dpath, start, lowpass=150)
        if len(ts) < 16:
            ts, ws = hit_list(dpath, start)
        if len(ts) >= 16:
            bpm, ph = coherent_tempo(ts, ws, bpm)
            period = 60.0 / bpm
            t0 = ph + np.ceil((start - ph) / period) * period
            period, t0 = regress_hits(ts, ws, period, t0)
            bpm = 60.0 / period
            bpm, t0 = prefer_whole_bpm(ts, ws, bpm, t0)
            kick_phase = True
            kick_times = ts

    # Rács ütései a dob belépésétől a végéig.
    k0 = int(np.ceil((start - t0) / period - 0.25))
    grid = [t0 + k * period for k in range(k0, int((end - t0) / period) + 1)]
    phase = downbeat_phase(grid, entry, drums, bass, harm)
    downbeat = grid[phase] if grid else t0
    if source is drums and not kick_phase:
        downbeat += refine_phase(folder, grid)
    elif kick_phase:
        # Exact attack of the kicks, measured on the unfiltered drums at beats that have a kick.
        kicks = [t for t in grid if np.min(np.abs(kick_times - t)) < 0.02]
        downbeat += refine_phase(folder, kicks, radius=0.015)
        # Keep the anchor near where the drums come in.

    key, camelot = detect_key(harm)
    print(json.dumps({
        "bpm": round(bpm, 4),
        "downbeat": round(downbeat, 5),
        "drumStart": round(entry, 4),
        "duration": round(duration, 4),
        "key": key,
        "camelot": camelot,
        "rawTempo": round(tempo, 3),
    }))


if __name__ == "__main__":
    main()
