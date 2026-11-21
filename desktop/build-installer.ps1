param(
    [Parameter(Mandatory = $true)][string]$InnoCompiler,
    [Parameter(Mandatory = $true)][string]$EmbeddedPython,
    [Parameter(Mandatory = $true)][string]$VCRedistributable,
    [Parameter(Mandatory = $true)][string]$WebViewBootstrap,
    [string]$BuildPython,
    [string]$WheelDirectory
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
if (-not $BuildPython) { $BuildPython = Join-Path $workspace '.venv310\Scripts\python.exe' }
$compiler = (Resolve-Path -LiteralPath $InnoCompiler).Path
$python = (Resolve-Path -LiteralPath $BuildPython).Path
$embedded = (Resolve-Path -LiteralPath $EmbeddedPython).Path
$vc = (Resolve-Path -LiteralPath $VCRedistributable).Path
$webView = (Resolve-Path -LiteralPath $WebViewBootstrap).Path
$modelRelative = 'vendor\uvr-headless-master\models\MDX_Net_Models\Kim_Vocal_2.onnx'
$modelSource = Join-Path $workspace $modelRelative

if ((Get-FileHash -LiteralPath $embedded -Algorithm SHA256).Hash -ne '608619F8619075629C9C69F361352A0DA6ED7E62F83A0E19C63E0EA32EB7629D') {
    throw 'Expected the official embedded Python 3.10.11 x64 archive.'
}
if ((Get-FileHash -LiteralPath $modelSource -Algorithm SHA256).Hash -ne 'CE74EF3B6A6024CE44211A07BE9CF8BC6D87728CC852A68AB34EB8E58CDE9C8B') {
    throw 'The Kim Vocal 2 model does not match the expected file.'
}
foreach ($asset in @($vc, $webView)) {
    $signature = Get-AuthenticodeSignature -LiteralPath $asset
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notlike 'CN=Microsoft Corporation,*') {
        throw "Expected a Microsoft-signed installer at $asset."
    }
}
& $python -c 'import struct, sys; raise SystemExit(sys.version_info[:2] != (3, 10) or struct.calcsize(''P'') != 8)'
if ($LASTEXITCODE -ne 0) { throw 'Use 64-bit Python 3.10 to build the packaged runtime.' }

$job = Join-Path $workspace ('work\installer-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$payload = Join-Path $job 'payload'
$artwork = Join-Path $job 'artwork'
$runtime = Join-Path $payload '.python310'
$packages = Join-Path $runtime 'Lib\site-packages'
$desktop = Join-Path $payload 'desktop'
$modelDestination = Join-Path $payload $modelRelative
$output = Join-Path $workspace 'outputs'
New-Item -ItemType Directory -Force -Path $desktop,$artwork,$packages,$output,(Split-Path -Parent $modelDestination) | Out-Null

Copy-Item -LiteralPath (Join-Path $workspace 'app.py'),(Join-Path $workspace 'kim_engine.py') -Destination $payload
Copy-Item -LiteralPath (Join-Path $workspace 'static') -Destination $payload -Recurse
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'backend.py') -Destination $desktop
Set-Content -LiteralPath (Join-Path $desktop 'shared-runtime.txt') -Value 'Use DirectML with CPU fallback.' -Encoding ascii
Set-Content -LiteralPath (Join-Path $desktop 'installed-runtime.txt') -Value 'Installed by Sonder Setup.' -Encoding ascii
Copy-Item -LiteralPath $modelSource -Destination $modelDestination
Copy-Item -LiteralPath (Join-Path $workspace 'vendor\uvr-headless-master\LICENSE') -Destination (Join-Path $payload 'vendor\uvr-headless-master')

Write-Host 'Preparing the bundled Python and audio libraries...'
Expand-Archive -LiteralPath $embedded -DestinationPath $runtime -Force
@('python310.zip', '.', 'Lib\site-packages', '..', 'import site') |
    Set-Content -LiteralPath (Join-Path $runtime 'python310._pth') -Encoding ascii
$arguments = @('-m', 'pip', 'install', '--disable-pip-version-check', '--only-binary=:all:', '--no-compile', '--ignore-installed',
    '--target', $packages, '-r', (Join-Path $PSScriptRoot 'share\requirements.txt'), 'onnxruntime-directml==1.23.0')
if ($WheelDirectory) {
    $arguments += @('--no-index', '--find-links', (Resolve-Path -LiteralPath $WheelDirectory).Path)
}
& $python @arguments
if ($LASTEXITCODE -ne 0) { throw 'Could not assemble the Python runtime.' }
& (Join-Path $runtime 'python.exe') -B (Join-Path $PSScriptRoot 'share\check-runtime.py')
if ($LASTEXITCODE -ne 0) { throw 'The bundled runtime did not pass its health check.' }

& (Join-Path $PSScriptRoot 'installer\artwork.ps1') -Destination $artwork
$desktopBuild = @{
    RelativeOnly = $true
    IconPath = Join-Path $artwork 'Sonder.ico'
    ExecutablePath = Join-Path $payload 'Sonder.exe'
}
& (Join-Path $PSScriptRoot 'build.ps1') @desktopBuild | Out-Null
$setupArguments = @("/DPayloadDir=$payload", "/DArtworkDir=$artwork", "/DVCRedist=$vc",
    "/DWebViewBootstrap=$webView", "/DInstallerOutputDir=$job", (Join-Path $PSScriptRoot 'installer\Sonder.iss'))
& $compiler @setupArguments
if ($LASTEXITCODE -ne 0) { throw 'The Windows installer did not compile.' }

$installer = Join-Path $output 'Sonder-Setup.exe'
Move-Item -LiteralPath (Join-Path $job 'Sonder-Setup.exe') -Destination $installer -Force
Get-Item -LiteralPath $installer | Select-Object FullName, Length
