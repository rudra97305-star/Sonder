param(
    [Parameter(Mandatory = $true)][string]$PythonInstaller,
    [Parameter(Mandatory = $true)][string]$EmbeddedPython,
    [Parameter(Mandatory = $true)][string]$PipWheel,
    [Parameter(Mandatory = $true)][string]$VCRedistributable
)

$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$installer = (Resolve-Path -LiteralPath $PythonInstaller).Path
if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ne 'D8DEDE5005564B408BA50317108B765ED9C3C510342A598F9FD42681CBE0648B') {
    throw 'Expected the official 64-bit Python 3.10.11 installer.'
}
$embedded = (Resolve-Path -LiteralPath $EmbeddedPython).Path
$pip = (Resolve-Path -LiteralPath $PipWheel).Path
$vc = (Resolve-Path -LiteralPath $VCRedistributable).Path
if ((Get-FileHash -LiteralPath $embedded -Algorithm SHA256).Hash -ne '608619F8619075629C9C69F361352A0DA6ED7E62F83A0E19C63E0EA32EB7629D' -or
    (Get-FileHash -LiteralPath $pip -Algorithm SHA256).Hash -ne '9655943313A94722B7774661C21049070F6BBB0A1516BF02F7C8D5D9201514CD') {
    throw 'Expected the official embedded Python 3.10.11 archive and pip 25.3 wheel.'
}
if ((Get-FileHash -LiteralPath $vc -Algorithm SHA256).Hash -ne '9C02C9ED120F671B900E6B9471D890E3B2414117A7E53F4AE2E855466FA2B7C9') {
    throw 'Expected the official Microsoft x64 Visual C++ Redistributable shipped with this setup.'
}

$uvrSource = Join-Path $workspace 'vendor\uvr-headless-master'
$modelFile = 'models\MDX_Net_Models\Kim_Vocal_2.onnx'
$modelPath = Join-Path $uvrSource $modelFile
if (-not (Test-Path -LiteralPath $modelPath -PathType Leaf) -or
    (Get-FileHash -LiteralPath $modelPath -Algorithm SHA256).Hash -ne 'CE74EF3B6A6024CE44211A07BE9CF8BC6D87728CC852A68AB34EB8E58CDE9C8B') {
    throw 'The expected Kim Vocal 2 model is missing or damaged.'
}

$staging = Join-Path $workspace ('work\share-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$package = Join-Path $staging 'Sonder'
$desktop = Join-Path $package 'desktop'
$installers = Join-Path $package 'installers'
New-Item -ItemType Directory -Path $package,$desktop,$installers -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $workspace 'app.py'),(Join-Path $workspace 'kim_engine.py') -Destination $package
Copy-Item -LiteralPath (Join-Path $workspace 'static') -Destination $package -Recurse
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'backend.py'),(Join-Path $PSScriptRoot 'share\setup-share.ps1'),(Join-Path $PSScriptRoot 'share\check-runtime.py') -Destination $desktop
Set-Content -LiteralPath (Join-Path $desktop 'shared-runtime.txt') -Value 'Allow CPU fallback if GPU inference is unavailable.' -Encoding ascii
foreach ($name in @('Setup Sonder.cmd', 'READ ME.txt', 'requirements.txt')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "share\$name") -Destination $package
}

# Ship the UVR source needed for MDX inference, its license, and the model.
$uvrFiles = @(
    'LICENSE',
    'gui_data\constants.py',
    'gui_data\model_manual_download.json',
    'lib_v5\tfc_tdf_v3.py',
    'lib_v5\vr_network\model_param_init.py',
    $modelFile,
    'models\MDX_Net_Models\model_data\model_name_mapper.json',
    'uvr_headless\__init__.py',
    'uvr_headless\cli.py',
    'uvr_headless\headless_root.py',
    'uvr_headless\core\__init__.py',
    'uvr_headless\core\model_data.py'
)
$uvrPackage = Join-Path $package 'vendor\uvr-headless-master'
foreach ($relativeFile in $uvrFiles) {
    $destination = Join-Path $uvrPackage $relativeFile
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $uvrSource $relativeFile) -Destination $destination
}

Copy-Item -LiteralPath $installer -Destination (Join-Path $installers 'python-3.10.11-amd64.exe')
Copy-Item -LiteralPath $embedded -Destination (Join-Path $installers 'python-3.10.11-embed-amd64.zip')
Copy-Item -LiteralPath $pip -Destination (Join-Path $installers 'pip-25.3-py3-none-any.whl')
Copy-Item -LiteralPath $vc -Destination (Join-Path $installers 'vc_redist.x64.exe')
& (Join-Path $PSScriptRoot 'build.ps1') -RelativeOnly -ExecutablePath (Join-Path $package 'Sonder.exe') | Out-Null

$zip = Join-Path $workspace 'outputs\Sonder-for-Windows.zip'
Compress-Archive -LiteralPath $package -DestinationPath $zip -Force
Get-Item -LiteralPath $zip | Select-Object FullName, Length
