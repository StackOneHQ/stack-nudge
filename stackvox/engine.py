"""Core engine: model loading, synthesis, and playback."""

from __future__ import annotations

import logging
import urllib.request
from pathlib import Path

import numpy as np
import sounddevice as sd
from kokoro_onnx import Kokoro

from stackvox.paths import cache_dir as _default_cache_dir

logger = logging.getLogger(__name__)

DEFAULT_VOICE = "af_sarah"
DEFAULT_SPEED = 1.0
DEFAULT_LANG = "en-us"

_MODEL_URL = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx"
_VOICES_URL = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin"


def _ensure_models(cache_dir: Path) -> tuple[Path, Path]:
    cache_dir.mkdir(parents=True, exist_ok=True)
    model_path = cache_dir / "kokoro-v1.0.onnx"
    voices_path = cache_dir / "voices-v1.0.bin"
    for path, url in [(model_path, _MODEL_URL), (voices_path, _VOICES_URL)]:
        if path.exists():
            continue
        logger.info("downloading %s...", path.name)
        urllib.request.urlretrieve(url, path)
    return model_path, voices_path


class Stackvox:
    """Reusable TTS engine. Load the model once, speak many times.

    Example:
        tts = Stackvox(voice="af_bella")
        tts.speak("Hello world")
    """

    def __init__(
        self,
        voice: str = DEFAULT_VOICE,
        speed: float = DEFAULT_SPEED,
        lang: str = DEFAULT_LANG,
        cache_dir: Path | None = None,
    ) -> None:
        self.voice = voice
        self.speed = speed
        self.lang = lang
        model_path, voices_path = _ensure_models(cache_dir or _default_cache_dir())
        self._kokoro = Kokoro(str(model_path), str(voices_path))

    def synthesize(
        self,
        text: str,
        voice: str | None = None,
        speed: float | None = None,
        lang: str | None = None,
    ) -> tuple[np.ndarray, int]:
        """Return (samples, sample_rate) without playing."""
        samples, sample_rate = self._kokoro.create(
            text,
            voice=voice or self.voice,
            speed=speed if speed is not None else self.speed,
            lang=lang or self.lang,
        )
        return samples, sample_rate

    def speak(
        self,
        text: str,
        voice: str | None = None,
        speed: float | None = None,
        lang: str | None = None,
        blocking: bool = True,
    ) -> None:
        """Synthesize and play through the system default output device."""
        samples, sample_rate = self.synthesize(text, voice=voice, speed=speed, lang=lang)
        sd.play(samples, sample_rate)
        if blocking:
            sd.wait()

    def stop(self) -> None:
        """Stop any in-progress playback started with blocking=False."""
        sd.stop()

    def voices(self) -> list[str]:
        return sorted(self._kokoro.get_voices())

    def speak_sequence(
        self,
        lines: list[dict],
        gap_seconds: float = 0.0,
        concurrent: bool = True,
    ) -> None:
        """Synthesize multiple lines, concatenate, play as one gapless buffer.

        Each line is a dict: {"text": str, "voice": str?, "speed": float?, "lang": str?}.
        With concurrent=True, synthesis happens in parallel threads (ONNX runtime
        releases the GIL) so the upfront wait is closer to the longest single
        synthesis rather than the sum of all of them.
        """
        if not lines:
            return

        def synth(line: dict) -> tuple[np.ndarray, int]:
            kwargs = {k: v for k, v in line.items() if k != "text"}
            return self.synthesize(line["text"], **kwargs)

        if concurrent and len(lines) > 1:
            from concurrent.futures import ThreadPoolExecutor

            with ThreadPoolExecutor(max_workers=len(lines)) as pool:
                results = list(pool.map(synth, lines))
        else:
            results = [synth(line) for line in lines]

        sample_rate = results[0][1]
        segments: list[np.ndarray] = []
        gap = np.zeros(int(sample_rate * gap_seconds), dtype=results[0][0].dtype) if gap_seconds > 0 else None
        for idx, (samples, _) in enumerate(results):
            segments.append(samples)
            if gap is not None and idx < len(results) - 1:
                segments.append(gap)

        audio = np.concatenate(segments)
        sd.play(audio, sample_rate)
        sd.wait()


_default: Stackvox | None = None


def _get_default() -> Stackvox:
    global _default
    if _default is None:
        _default = Stackvox()
    return _default


def speak(
    text: str,
    voice: str = DEFAULT_VOICE,
    speed: float = DEFAULT_SPEED,
    lang: str = DEFAULT_LANG,
    blocking: bool = True,
) -> None:
    """One-shot: synthesize and play. Reuses a module-level engine across calls."""
    _get_default().speak(text, voice=voice, speed=speed, lang=lang, blocking=blocking)


def synthesize(
    text: str,
    voice: str = DEFAULT_VOICE,
    speed: float = DEFAULT_SPEED,
    lang: str = DEFAULT_LANG,
) -> tuple[np.ndarray, int]:
    """One-shot synthesis. Returns (samples, sample_rate)."""
    return _get_default().synthesize(text, voice=voice, speed=speed, lang=lang)
