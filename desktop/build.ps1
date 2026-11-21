param(
    [string]$WebViewSdkRoot = 'C:\Program Files (x86)\Acer\Jumpstart Agent',
    [string]$ExecutablePath,
    [string]$IconPath,
    [switch]$RelativeOnly
)

$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    throw 'The Windows .NET Framework C# compiler was not found.'
}

$sdk = (Resolve-Path -LiteralPath $WebViewSdkRoot).Path
$coreName = 'Microsoft.Web.WebView2.Core.dll'
$formsName = 'Microsoft.Web.WebView2.WinForms.dll'
$managed = $sdk
if (Test-Path -LiteralPath (Join-Path $sdk 'lib\net462\Microsoft.Web.WebView2.Core.dll')) {
    $managed = Join-Path $sdk 'lib\net462'
}
$core = Join-Path $managed $coreName
$forms = Join-Path $managed $formsName
$loader = Join-Path $sdk 'runtimes\win-x64\native\WebView2Loader.dll'
foreach ($dependency in @($core, $forms, $loader)) {
    if (-not (Test-Path -LiteralPath $dependency -PathType Leaf)) {
        throw "Missing WebView2 dependency: $dependency"
    }
}

$build = Join-Path $workspace 'work\desktop-build'
$output = Join-Path $workspace 'outputs'
New-Item -ItemType Directory -Force -Path $build, $output | Out-Null
$anchor = Join-Path $build 'workspace.txt'
$anchorValue = if ($RelativeOnly) { '' } else { $workspace }
[IO.File]::WriteAllText($anchor, $anchorValue, [Text.UTF8Encoding]::new($false))
$exe = if ($ExecutablePath) { $ExecutablePath } else { Join-Path $output 'Sonder.exe' }
$arguments = @(
    '/nologo', '/target:winexe', '/platform:x64', '/optimize+', "/out:$exe",
    '/reference:System.Windows.Forms.dll', '/reference:System.Drawing.dll',
    "/reference:$core", "/reference:$forms",
    "/resource:$core,Sonder.Desktop.$coreName",
    "/resource:$forms,Sonder.Desktop.$formsName",
    "/resource:$loader,Sonder.Desktop.WebView2Loader.dll",
    "/resource:$anchor,Sonder.Desktop.workspace.txt",
    (Join-Path $PSScriptRoot 'SonderDesktop.cs')
)
if ($IconPath) {
    $arguments += "/win32icon:$((Resolve-Path -LiteralPath $IconPath).Path)"
}
& $compiler @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Desktop compilation failed with exit code $LASTEXITCODE."
}
Get-Item -LiteralPath $exe | Select-Object FullName, Length
