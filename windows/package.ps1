# Assembles the distributable DroidProxy for Windows tree:
#   DroidProxy-Windows/
#     DroidProxy.exe            (WinUI app, published)
#     daemon/bin/droidproxy.exe (Go daemon, cross-compiled)
#     daemon/libexec/cli-proxy-api.exe
#     daemon/share/config.yaml
# Usage: pwsh ./package.ps1 -DaemonRoot <path-to-daemon-tree> [-Output <dir>]
param(
    [Parameter(Mandatory = $true)][string]$DaemonRoot,
    [string]$Output = "$PSScriptRoot\..\DroidProxy-Windows"
)
$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot 'DroidProxy\DroidProxy.csproj'
$publishDir = Join-Path $PSScriptRoot 'DroidProxy\bin\publish-winui'

dotnet publish $project -c Release -p:Platform=x64 -r win-x64 --self-contained false -p:PublishTrimmed=false -o $publishDir
if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }

if (Test-Path $Output) { Remove-Item -Recurse -Force $Output }
New-Item -ItemType Directory -Force $Output | Out-Null
Copy-Item "$publishDir\*" $Output -Recurse
New-Item -ItemType Directory -Force "$Output\daemon\bin", "$Output\daemon\libexec", "$Output\daemon\share" | Out-Null
Copy-Item "$DaemonRoot\bin\droidproxy.exe" "$Output\daemon\bin\"
Copy-Item "$DaemonRoot\libexec\cli-proxy-api.exe" "$Output\daemon\libexec\"
Copy-Item "$DaemonRoot\share\config.yaml" "$Output\daemon\share\"
Compress-Archive -Path "$Output\*" -DestinationPath "$Output.zip" -Force
Write-Output "packaged: $Output.zip"
