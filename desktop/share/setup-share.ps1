$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root
$runtime = Join-Path $root '.python310'
$python = Join-Path $runtime 'python.exe'
$packages = Join-Path $runtime 'Lib\site-packages'

function Invoke-Checked {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Setup command failed: $Command $($Arguments -join ' ')" }
}

function Get-VerifiedAsset {
    param([string]$RelativePath, [string]$Hash)
    $path = Join-Path $root $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $Hash) {
        $Name = Split-Path -Leaf $RelativePath
        throw "$Name is missing or damaged. Extract a fresh copy of the entire Sonder ZIP."
    }
    return $path
}

$null = Get-VerifiedAsset 'vendor\uvr-headless-master\models\MDX_Net_Models\Kim_Vocal_2.onnx' 'CE74EF3B6A6024CE44211A07BE9CF8BC6D87728CC852A68AB34EB8E58CDE9C8B'
Write-Host 'Verified the bundled Kim Vocal 2 model.'

$embedded = Get-VerifiedAsset 'installers\python-3.10.11-embed-amd64.zip' '608619F8619075629C9C69F361352A0DA6ED7E62F83A0E19C63E0EA32EB7629D'
$pipWheel = Get-VerifiedAsset 'installers\pip-25.3-py3-none-any.whl' '9655943313A94722B7774661C21049070F6BBB0A1516BF02F7C8D5D9201514CD'
if (-not (Test-Path -LiteralPath (Join-Path $runtime 'python310.zip') -PathType Leaf) -or -not (Test-Path -LiteralPath $python -PathType Leaf)) {
    Write-Host 'Setting up the bundled Python runtime for Sonder...'
    Expand-Archive -LiteralPath $embedded -DestinationPath $runtime -Force
}

New-Item -ItemType Directory -Path $packages -Force | Out-Null
@(
    'python310.zip',
    '.',
    'Lib\site-packages',
    '..',
    '..\vendor\uvr-headless-master',
    'import site'
) | Set-Content -LiteralPath (Join-Path $runtime 'python310._pth') -Encoding ascii

if (-not (Test-Path -LiteralPath (Join-Path $packages 'pip\__init__.py') -PathType Leaf)) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($pipWheel, $packages)
}
Invoke-Checked $python @('-X', 'utf8', '-c', 'import struct, sys; raise SystemExit(sys.version_info[:2] != (3, 10) or struct.calcsize(''P'') != 8)')
if (-not (Test-Path -LiteralPath (Join-Path $root 'vendor\uvr-headless-master\uvr_headless\cli.py'))) {
    throw 'Sonder is missing files. Extract the entire updated ZIP and rerun setup.'
}

$healthCheck = Join-Path $PSScriptRoot 'check-runtime.py'
& $python $healthCheck --msvc-only
$runtimeExit = $LASTEXITCODE
if ($runtimeExit -eq 10) {
    $redistributable = Get-VerifiedAsset 'installers\vc_redist.x64.exe' '9C02C9ED120F671B900E6B9471D890E3B2414117A7E53F4AE2E855466FA2B7C9'
    $log = Join-Path $root 'vc-runtime-setup.log'
    Write-Host 'Installing the bundled Microsoft Visual C++ runtime...'
    $installer = Start-Process -FilePath $redistributable -ArgumentList ('/install /passive /norestart /log "{0}"' -f $log) -Wait -PassThru
    if ($installer.ExitCode -notin @(0, 1638, 3010)) {
        throw "Visual C++ setup failed (exit code $($installer.ExitCode)). See $log."
    }
    & $python $healthCheck --msvc-only
    if ($LASTEXITCODE -ne 0) {
        throw "The installed Visual C++ runtime could not load (installer exit code $($installer.ExitCode)). See $log."
    }
} elseif ($runtimeExit -ne 0) {
    throw 'Could not check the Visual C++ runtime. See the Python error above.'
}

function Test-InstalledPackage {
    param([string]$Name)
    & $python -c 'import sys, importlib.metadata as m; raise SystemExit(not list(m.distributions(name=sys.argv[1])))' $Name
    return $LASTEXITCODE -eq 0
}

$missing = @(@('fastapi', 'uvicorn', 'numpy', 'scipy', 'soundfile', 'imageio-ffmpeg') | Where-Object { -not (Test-InstalledPackage $_) })
if ($missing.Count -eq 0) {
    Write-Host 'Python packages are already installed. No downloads needed.'
} else {
    Write-Host 'Installing audio, GPU, and app dependencies...'
    Invoke-Checked $python @('-m', 'pip', 'install', '--disable-pip-version-check', '--no-warn-script-location', '-r', 'requirements.txt')
}
if (-not (Test-InstalledPackage 'onnxruntime-directml') -and -not (Test-InstalledPackage 'onnxruntime')) {
    Write-Host 'Installing ONNX Runtime...'
    Invoke-Checked $python @('-m', 'pip', 'install', '--disable-pip-version-check', 'onnxruntime-directml==1.23.0')
}

& $python $healthCheck
$runtimeExit = $LASTEXITCODE
if ($runtimeExit -eq 11 -and (Test-InstalledPackage 'onnxruntime-directml')) {
    Write-Host 'DirectML could not load. Switching to the CPU runtime...'
    Invoke-Checked $python @('-m', 'pip', 'uninstall', '-y', 'onnxruntime-directml')
    Invoke-Checked $python @('-m', 'pip', 'install', '--disable-pip-version-check', 'onnxruntime==1.23.0')
    & $python $healthCheck
    $runtimeExit = $LASTEXITCODE
}
if ($runtimeExit -ne 0) { throw 'A native audio dependency could not load. See the Python error above.' }

& $python -X utf8 -m uvr_headless.cli list-models *> $null
if ($LASTEXITCODE -ne 0) { throw 'The bundled separation files could not load. Extract the updated ZIP again.' }
