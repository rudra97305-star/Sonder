"""Check the shared build's native audio and inference dependencies."""

import ctypes
import sys
import traceback

try:
    ctypes.WinDLL("msvcp140.dll")
except OSError:
    print("The Microsoft Visual C++ x64 runtime is missing.")
    sys.exit(10)

if "--msvc-only" in sys.argv:
    sys.exit(0)

try:
    import onnxruntime as ort

    providers = ort.get_available_providers()
    if "CPUExecutionProvider" not in providers:
        raise RuntimeError(f"CPU inference provider is missing. Found: {providers}")
except Exception:
    traceback.print_exc()
    sys.exit(11)

try:
    import soundfile
    from scipy import fft
    from imageio_ffmpeg import get_ffmpeg_exe

    get_ffmpeg_exe()
    fft.rfft([1.0, 0.0])
except Exception:
    traceback.print_exc()
    sys.exit(12)

message = "Setup complete. DirectML and CPU are available." if "DmlExecutionProvider" in providers else "Setup complete. CPU mode is available."
print(message)
