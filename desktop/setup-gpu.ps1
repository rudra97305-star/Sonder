param(
    [string]$UvrInstall = 'D:\Ultimate Vocal Remover',
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$python = Join-Path $workspace '.venv310\Scripts\python.exe'
$runtime = Join-Path $workspace 'vendor\kim-runtime'
$cudaDlls = Join-Path $UvrInstall 'torch\lib'
$model = Join-Path $UvrInstall 'models\MDX_Net_Models\Kim_Vocal_2.onnx'

if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    throw 'The Sonder Python environment is missing. Complete the initial setup before enabling CUDA.'
}
if (-not (Test-Path -LiteralPath (Join-Path $cudaDlls 'cudnn64_8.dll') -PathType Leaf)) {
    throw "The UVR installation at '$UvrInstall' does not contain the CUDA 11 and cuDNN 8 runtime."
}
if (-not (Test-Path -LiteralPath $model -PathType Leaf)) {
    throw "The Kim Vocal 2 model was not found at '$model'."
}

if (-not $CheckOnly -and -not (Test-Path -LiteralPath (Join-Path $runtime 'onnxruntime_gpu-1.20.1.dist-info'))) {
    # The official CUDA 11 feed targets the libraries included with desktop UVR.
    $cudaIndex = 'https://aiinfra.pkgs.visualstudio.com/PublicPackages/_packaging/onnxruntime-cuda-11/pypi/simple/'
    & $python -m pip install --disable-pip-version-check --no-deps --only-binary :all: --upgrade --target $runtime --index-url $cudaIndex 'onnxruntime-gpu==1.20.1'
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not install the isolated ONNX CUDA runtime.'
    }
}

$verifyCuda = @'
import os
import sys
from pathlib import Path

runtime, dlls, model = (Path(path).resolve() for path in sys.argv[1:4])
sys.path.insert(0, str(runtime))
os.environ["PATH"] = str(dlls) + os.pathsep + os.environ.get("PATH", "")

with os.add_dll_directory(str(dlls)):
    import numpy as np
    import onnxruntime as ort

    if not Path(ort.__file__).resolve().is_relative_to(runtime.resolve()):
        raise SystemExit("The isolated ONNX Runtime was not found.")
    provider = "CUDAExecutionProvider"
    if provider not in ort.get_available_providers():
        raise SystemExit("The installed runtime does not expose the CUDA provider.")

    providers = [(provider, {"cudnn_conv_algo_search": "HEURISTIC"}), "CPUExecutionProvider"]
    session = ort.InferenceSession(str(model), providers=providers)
    if provider not in session.get_providers():
        raise SystemExit("CUDA initialization failed. ONNX Runtime fell back to CPU.")
    session.disable_fallback()
    data = np.full((1, 4, 3072, 256), 0.01, dtype=np.float32)
    result = session.run(None, {session.get_inputs()[0].name: data})[0]
    if result.shape != data.shape or not np.isfinite(result).all():
        raise SystemExit("CUDA returned unexpected output for Kim Vocal 2.")
    print(f"Kim Vocal 2 ran on {session.get_providers()[0]} using ONNX Runtime {ort.__version__}.")
'@

$verifyCuda | & $python - $runtime $cudaDlls $model
if ($LASTEXITCODE -ne 0) {
    throw 'The GPU runtime did not pass the Kim Vocal 2 inference check.'
}
