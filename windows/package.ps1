# Builds the DroidProxy for Windows installer and update packages with Velopack (vpk):
#   <Output>/nikships.DroidProxy-win-Setup.exe     per-user installer, no admin
#   <Output>/nikships.DroidProxy-<Version>-full.nupkg (+ -delta.nupkg when <Output> holds the previous full package)
#   <Output>/releases.win.json                     the update feed
# The app tree it packs:
#   DroidProxy.exe            (WinUI app, published)
#   daemon/bin/droidproxy.exe (Go daemon, cross-compiled)
#   daemon/libexec/cli-proxy-api.exe
#   daemon/share/config.yaml
# Usage: pwsh ./package.ps1 -DaemonRoot <path-to-daemon-tree> -Version <x.y.z> [-Output <dir>]
# Needs vpk: dotnet tool install -g vpk --version 1.2.161 (keep it on the Velopack package version).
param(
    [Parameter(Mandatory = $true)][string]$DaemonRoot,
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$Output = "$PSScriptRoot\..\DroidProxy-Windows"
)
$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot 'DroidProxy\DroidProxy.csproj'
$publishDir = Join-Path $PSScriptRoot 'DroidProxy\bin\publish-winui'

if (Test-Path $publishDir) { Remove-Item -Recurse -Force $publishDir }
dotnet publish $project -c Release -p:Platform=x64 -r win-x64 --self-contained false -p:Version=$Version -o $publishDir
if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }

New-Item -ItemType Directory -Force "$publishDir\daemon\bin", "$publishDir\daemon\libexec", "$publishDir\daemon\share" | Out-Null
Copy-Item "$DaemonRoot\bin\droidproxy.exe" "$publishDir\daemon\bin\"
Copy-Item "$DaemonRoot\libexec\cli-proxy-api.exe" "$publishDir\daemon\libexec\"
Copy-Item "$DaemonRoot\share\*" "$publishDir\daemon\share\"

# The pack id must not be "DroidProxy": Velopack installs to %LOCALAPPDATA%\<packId>, and
# %LOCALAPPDATA%\DroidProxy holds the control socket and host log.
vpk pack --packId nikships.DroidProxy --packTitle DroidProxy --packAuthors nikships `
    --packVersion $Version --packDir $publishDir --mainExe DroidProxy.exe `
    --icon (Join-Path $PSScriptRoot 'DroidProxy\Assets\AppIcon.ico') `
    --runtime win-x64 --framework net10.0-x64-desktop --outputDir $Output
if ($LASTEXITCODE -ne 0) { throw 'vpk pack failed' }
Write-Output "packaged: $Output"
