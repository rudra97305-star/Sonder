"""Reusable GPU inference for UVR's Kim Vocal 2 MDX model."""

from __future__ import annotations

import os
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path
from threading import Lock

SAMPLE_RATE = 44_100
FFT_SIZE = 7_680
HOP_SIZE = 1_024
FREQUENCY_BINS = 3_072
FRAMES = 256
COMPENSATION = 1.009
CHUNK_SIZE = HOP_SIZE * (FRAMES - 1)
TRIM = FFT_SIZE // 2
STEP = CHUNK_SIZE - 2 * TRIM
CUDA_DLLS = Path(r"D:\Ultimate Vocal Remover\torch\lib")
_model_lock = Lock()
_dll_directories = []
_engine: KimEngine | None = None


def open_engine(model: Path, runtime: Path, allow_cpu: bool = False) -> KimEngine:
    global _engine
    with _model_lock:
        if _engine is None:
            _engine = KimEngine(model, runtime, allow_cpu)
        return _engine


class MdxStft:
    def __init__(self):
        import numpy as np
        from scipy import fft

        self._np = np
        self._fft = fft
        self._window = np.hanning(FFT_SIZE + 1)[:-1].astype(np.float32)
        self._frame_starts = range(0, CHUNK_SIZE + 1, HOP_SIZE)
        self._weights = np.zeros(CHUNK_SIZE + FFT_SIZE, dtype=np.float32)
        squared_window = self._window ** 2
        for start in self._frame_starts:
            self._weights[start:start + FFT_SIZE] += squared_window

    def forward(self, block):
        np = self._np
        padded = np.pad(block, ((0, 0), (TRIM, TRIM)), mode="reflect")
        frames = np.lib.stride_tricks.sliding_window_view(padded, FFT_SIZE, axis=-1)[:, ::HOP_SIZE]
        transformed = self._fft.rfft(frames * self._window, workers=2)[..., :FREQUENCY_BINS].transpose(0, 2, 1)
        spectrum = np.empty((1, 4, FREQUENCY_BINS, FRAMES), dtype=np.float32)
        spectrum[0, ::2] = transformed.real
        spectrum[0, 1::2] = transformed.imag
        return spectrum

    def inverse(self, spectrum):
        real, imag = spectrum[0, ::2], spectrum[0, 1::2]
        transformed = (real + 1j * imag).transpose(0, 2, 1)
        frames = self._fft.irfft(transformed, n=FFT_SIZE, workers=2) * self._window
        wave = self._np.zeros((2, CHUNK_SIZE + FFT_SIZE), dtype=self._np.float32)
        for index, start in enumerate(self._frame_starts):
            wave[:, start:start + FFT_SIZE] += frames[:, index, :]
        center = slice(TRIM, TRIM + CHUNK_SIZE)
        return wave[:, center] / self._weights[center]


class KimEngine:
    def __init__(self, model: Path, runtime: Path, allow_cpu: bool = False):
        import numpy as np

        self._np = np
        self._stft = MdxStft()
        self._window = np.hanning(CHUNK_SIZE).astype(np.float32)
        self._inference_lock = Lock()

        if runtime.is_dir():
            sys.path.insert(0, str(runtime))
        if not allow_cpu and sys.platform == "win32" and CUDA_DLLS.is_dir():
            _dll_directories.append(os.add_dll_directory(str(CUDA_DLLS)))
            os.environ["PATH"] = str(CUDA_DLLS) + os.pathsep + os.environ.get("PATH", "")

        import onnxruntime as ort

        providers = ort.get_available_providers()
        failures = []
        choices = [("CUDAExecutionProvider", "CUDA"), ("DmlExecutionProvider", "DirectML")]
        if allow_cpu:
            choices.append(("CPUExecutionProvider", "CPU"))
        for provider, label in choices:
            if provider not in providers:
                continue
            try:
                options = ort.SessionOptions()
                options.intra_op_num_threads = 2
                options.log_severity_level = 3
                configuration = {}
                if provider == "CUDAExecutionProvider":
                    configuration = {"device_id": 0, "cudnn_conv_algo_search": "HEURISTIC"}
                elif provider == "DmlExecutionProvider":
                    configuration = {"device_id": 0}
                    options.enable_mem_pattern = False
                    options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
                else:
                    options.intra_op_num_threads = min(4, os.cpu_count() or 1)
                session = ort.InferenceSession(str(model), sess_options=options, providers=[(provider, configuration)])
                if not session.get_providers() or session.get_providers()[0] != provider:
                    raise RuntimeError(f"ONNX Runtime did not activate {label}.")
                session.disable_fallback()
                name = session.get_inputs()[0].name
                session.run(None, {name: np.zeros((1, 4, FREQUENCY_BINS, FRAMES), dtype=np.float32)})
                self._session, self._input_name, self.provider = session, name, label
                self.device_label = "CPU" if label == "CPU" else f"{label} GPU"
                return
            except Exception as exc:
                failures.append(f"{label}: {exc}")
        detail = "; ".join(failures) or f"Available ONNX providers: {', '.join(providers)}."
        raise RuntimeError(f"Kim Vocal 2 could not start an inference session. {detail}")

    def separate(
        self, ffmpeg: str, source: Path, vocals: Path, instrumental: Path,
        report: Callable[[int], None],
    ) -> None:
        import soundfile as sf

        np = self._np
        decoded = subprocess.run(
            [ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-i", str(source),
             "-map", "0:a:0", "-ac", "2", "-ar", str(SAMPLE_RATE), "-f", "f32le", "pipe:1"],
            capture_output=True,
            timeout=180,
        )
        if decoded.returncode or not decoded.stdout:
            detail = decoded.stderr.decode("utf-8", errors="replace").strip()[-1200:]
            raise RuntimeError(f"Could not decode the downloaded audio. {detail}")
        mix = np.frombuffer(decoded.stdout, dtype="<f4").reshape(-1, 2).T
        padded = np.pad(mix, ((0, 0), (TRIM, STEP + TRIM - mix.shape[1] % STEP)))
        result = np.zeros_like(padded)
        weights = np.zeros(padded.shape[1], dtype=np.float32)
        chunk_count = (padded.shape[1] + STEP - 1) // STEP
        report(0)

        # Match UVR's MDX framing, frequency trim, and overlap-add. The
        # instrumental is the mix minus the compensated vocal estimate.
        with self._inference_lock:
            for index, start in enumerate(range(0, padded.shape[1], STEP), start=1):
                end = min(start + CHUNK_SIZE, padded.shape[1])
                length = end - start
                block = np.zeros((2, CHUNK_SIZE), dtype=np.float32)
                block[:, :length] = padded[:, start:end]
                spectrum = self._stft.forward(block)
                spectrum[:, :, :3, :] = 0
                estimate = self._session.run(None, {self._input_name: spectrum})[0]
                wave = self._stft.inverse(estimate)[:, :length]
                window = self._window if length == CHUNK_SIZE else np.hanning(length).astype(np.float32)
                result[:, start:end] += wave * window
                weights[start:end] += window
                report(index * 100 // chunk_count)

        samples = slice(TRIM, TRIM + mix.shape[1])
        voice = result[:, samples] / weights[samples] * COMPENSATION
        sf.write(vocals, voice.T, SAMPLE_RATE, subtype="FLOAT")
        sf.write(instrumental, (mix - voice).T, SAMPLE_RATE, subtype="FLOAT")
