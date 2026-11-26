#!/usr/bin/env python3
"""Builds Verb's multilingual speech benchmark set.

Sentences come from FLEURS (google/fleurs, CC BY 4.0): read Wikipedia sentences in 102 languages,
about ten seconds each, close to a dictation. Each language's test archive is streamed and the
download stops once enough clips are kept, so a language costs tens of megabytes, not the whole
archive. The set also gets long clips, several sentences in a row that exercise chunking, and
non-speech clips (silence, noise, hum, clicks) where the right transcript is empty.

Usage:
    python3 scripts/fetch-speech-benchmark.py [--out DIR] [--per-language N] [--languages en_us,it_it]

Then run the models over it with `verb-check speech-bench DIR/manifest.jsonl Benchmarks/speech-models.json RESULTS.jsonl`.
"""
import argparse
import csv
import io
import json
import math
import os
import random
import struct
import sys
import tarfile
import urllib.request
import wave

# Pinned, so every run of the benchmark hears the same clips.
REVISION = "70bb2e84b976b7e960aa89f1c648e09c59f894dd"
BASE = f"https://huggingface.co/datasets/google/fleurs/resolve/{REVISION}/data"

# FLEURS configuration and the ISO 639-1 code models are scored and hinted with.
LANGUAGES = {
    "en_us": "en", "it_it": "it", "es_419": "es", "fr_fr": "fr", "de_de": "de", "pt_br": "pt",
    "nl_nl": "nl", "pl_pl": "pl", "ru_ru": "ru", "uk_ua": "uk", "cs_cz": "cs", "sv_se": "sv",
    "da_dk": "da", "fi_fi": "fi", "el_gr": "el", "ro_ro": "ro", "hu_hu": "hu", "tr_tr": "tr",
    "ar_eg": "ar", "hi_in": "hi", "ja_jp": "ja", "cmn_hans_cn": "zh", "ko_kr": "ko", "vi_vn": "vi",
}
# Long clips cost minutes per model, so only the languages most Verb users dictate in get them.
LONG_LANGUAGES = ["en_us", "it_it", "es_419", "fr_fr", "de_de", "pt_br"]
SAMPLE_RATE = 16000


class CountingReader(io.RawIOBase):
    """Counts the bytes that actually crossed the network."""

    def __init__(self, response):
        self.response, self.count = response, 0

    def readable(self):
        return True

    def readinto(self, buffer):
        data = self.response.read(len(buffer))
        self.count += len(data)
        buffer[: len(data)] = data
        return len(data)


def fetch_language(config, code, out, per_language):
    rows = {}
    with urllib.request.urlopen(f"{BASE}/{config}/test.tsv", timeout=60) as response:
        for row in csv.reader(io.TextIOWrapper(response, encoding="utf-8"), delimiter="\t", quoting=csv.QUOTE_NONE):
            if len(row) >= 6:
                rows[row[1]] = {"sentence": row[0], "raw": row[2], "samples": int(row[5])}
    folder = os.path.join(out, "fleurs", config)
    os.makedirs(folder, exist_ok=True)
    clips, sentences, scanned = [], set(), 0
    response = urllib.request.urlopen(f"{BASE}/{config}/audio/test.tar.gz", timeout=120)
    counter = CountingReader(response)
    try:
        with tarfile.open(fileobj=io.BufferedReader(counter, buffer_size=1 << 20), mode="r|gz") as archive:
            for member in archive:
                if not member.isfile():
                    continue
                name = os.path.basename(member.name)
                row = rows.get(name)
                scanned += 1
                # One recording per sentence, so the set has as many different sentences as clips.
                if row is None or row["sentence"] in sentences:
                    if scanned > per_language * 6:
                        break
                    continue
                data = archive.extractfile(member).read()
                with open(os.path.join(folder, name), "wb") as file:
                    file.write(data)
                sentences.add(row["sentence"])
                clips.append({
                    "id": f"fleurs-{config}-{os.path.splitext(name)[0]}", "source": "fleurs", "kind": "speech", "language": code,
                    "audio": [f"fleurs/{config}/{name}"], "reference": row["raw"], "seconds": round(row["samples"] / SAMPLE_RATE, 3),
                })
                if len(clips) >= per_language:
                    break
    finally:
        response.close()
    return clips, counter.count


def long_clips(config, clips, count, per_clip=6):
    """Sentences in a row, 0.4 seconds apart as the benchmark plays them: about a minute each."""
    result = []
    for index in range(count):
        group = clips[index * per_clip:(index + 1) * per_clip]
        if len(group) < per_clip:
            break
        result.append({
            "id": f"long-{config}-{index + 1}", "source": "fleurs", "kind": "long", "language": group[0]["language"],
            "audio": [audio for clip in group for audio in clip["audio"]], "reference": " ".join(clip["reference"] for clip in group),
            "seconds": round(sum(clip["seconds"] for clip in group) + 0.4 * (per_clip - 1), 3),
        })
    return result


def write_wave(path, samples):
    with wave.open(path, "wb") as file:
        file.setnchannels(1)
        file.setsampwidth(2)
        file.setframerate(SAMPLE_RATE)
        file.writeframes(b"".join(struct.pack("<h", max(-32767, min(32767, int(sample * 32767)))) for sample in samples))


def nonspeech_clips(out):
    """What a microphone hears when nobody speaks. Seeded, so the clips are the same on every run."""
    rng = random.Random(7)
    folder = os.path.join(out, "nonspeech")
    os.makedirs(folder, exist_ok=True)

    def level(db):
        return 10 ** (db / 20)

    def white(seconds, db):
        return [rng.gauss(0, level(db)) for _ in range(int(seconds * SAMPLE_RATE))]

    def brown(seconds, db):
        value, result = 0.0, []
        for _ in range(int(seconds * SAMPLE_RATE)):
            value = 0.995 * value + rng.gauss(0, 1)
            result.append(value)
        peak = max(abs(v) for v in result) or 1
        return [v / peak * level(db) for v in result]

    def hum(seconds, db):
        return [level(db) * (math.sin(2 * math.pi * 50 * t / SAMPLE_RATE) + 0.5 * math.sin(2 * math.pi * 150 * t / SAMPLE_RATE)) / 1.5
                for t in range(int(seconds * SAMPLE_RATE))]

    def clicks(seconds, db):
        result = [rng.gauss(0, level(-60)) for _ in range(int(seconds * SAMPLE_RATE))]
        for _ in range(int(seconds * 5)):
            start = rng.randrange(0, len(result) - 800)
            for offset in range(800):
                result[start + offset] += rng.gauss(0, level(db)) * math.exp(-offset / 120)
        return result

    variants = [
        ("silence-3s", [0.0] * 3 * SAMPLE_RATE), ("silence-8s", [0.0] * 8 * SAMPLE_RATE),
        ("hiss-quiet", white(5, -55)), ("hiss-loud", white(5, -35)), ("rumble", brown(6, -30)),
        ("mains-hum", hum(5, -35)), ("keyboard", clicks(6, -20)), ("fan", [a + b for a, b in zip(brown(6, -36), white(6, -48))]),
    ]
    result = []
    for name, samples in variants:
        write_wave(os.path.join(folder, f"{name}.wav"), samples)
        result.append({"id": f"nonspeech-{name}", "source": "synthetic", "kind": "nonspeech", "language": "und",
                       "audio": [f"nonspeech/{name}.wav"], "reference": "", "seconds": round(len(samples) / SAMPLE_RATE, 3)})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", default=os.path.expanduser("~/Library/Caches/Verb/SpeechBenchmark"))
    parser.add_argument("--per-language", type=int, default=80, help="sentences per language (default 80)")
    parser.add_argument("--long", type=int, default=2, help="long clips per language that gets them (default 2)")
    parser.add_argument("--languages", default=",".join(LANGUAGES), help="FLEURS configurations, comma separated")
    args = parser.parse_args()
    configs = [config.strip() for config in args.languages.split(",") if config.strip()]
    unknown = [config for config in configs if config not in LANGUAGES]
    if unknown:
        sys.exit(f"Unknown FLEURS configurations: {', '.join(unknown)}. Known: {', '.join(LANGUAGES)}")
    os.makedirs(args.out, exist_ok=True)
    manifest, downloaded = [], 0
    for config in configs:
        clips, size = fetch_language(config, LANGUAGES[config], args.out, args.per_language)
        downloaded += size
        manifest += clips
        if config in LONG_LANGUAGES:
            manifest += long_clips(config, clips, args.long)
        print(f"{config}: {len(clips)} clips, {size / 1e6:.1f} MB downloaded", flush=True)
    manifest += nonspeech_clips(args.out)
    with open(os.path.join(args.out, "manifest.jsonl"), "w", encoding="utf-8") as file:
        for clip in manifest:
            file.write(json.dumps(clip, ensure_ascii=False) + "\n")
    with open(os.path.join(args.out, "ATTRIBUTION.txt"), "w", encoding="utf-8") as file:
        file.write(f"Speech clips: FLEURS (Conneau et al., 2022), google/fleurs at {REVISION}, CC BY 4.0.\n"
                   "https://huggingface.co/datasets/google/fleurs\nNon-speech clips: generated by scripts/fetch-speech-benchmark.py.\n")
    hours = sum(clip["seconds"] for clip in manifest) / 3600
    print(f"{len(manifest)} clips, {hours:.1f} hours of audio, {downloaded / 1e6:.0f} MB downloaded, in {args.out}")


if __name__ == "__main__":
    main()
