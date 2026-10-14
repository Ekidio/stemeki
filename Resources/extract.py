# STEMEKI: the first audio track of a video (or of any file FFmpeg reads: WebM, MKV, AVI, Opus…) into a
# 32-bit float stereo WAV at its own sample rate. Uses PyAV (FFmpeg's decoders, LGPL).
# Usage: extract.py <input> <output.wav>   Prints one JSON line: {"ok": true} or {"error": "..."}.
import json
import sys


def main(src, dst):
    try:
        import av
    except ImportError:
        print(json.dumps({"error": "no-av"}))
        return 3
    import soundfile as sf

    with av.open(src) as container:
        if not container.streams.audio:
            print(json.dumps({"error": "This file has no audio."}))
            return 2
        stream = container.streams.audio[0]
        rate = stream.codec_context.sample_rate or 44100
        resampler = av.AudioResampler(format="flt", layout="stereo", rate=rate)
        with sf.SoundFile(dst, "w", samplerate=rate, channels=2, subtype="FLOAT") as out:
            for frame in container.decode(stream):
                for f in resampler.resample(frame):
                    out.write(f.to_ndarray().reshape(-1, 2))
            for f in resampler.resample(None):
                out.write(f.to_ndarray().reshape(-1, 2))
    print(json.dumps({"ok": True}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1], sys.argv[2]))
    except Exception as e:  # noqa: BLE001
        print(json.dumps({"error": str(e)[:300]}))
        sys.exit(1)
