#Requires -Version 5.1
<#
.SYNOPSIS
  Build Files as unpackaged, self-contained portable folder (no MSIX).
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64', 'x86')]
    [string]$Arch = 'x64',

    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    [string]$OutputDir = '',

    [string]$LogPath = ''
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $RepoRoot)) { throw "RepoRoot not found: $RepoRoot" }

if (-not $OutputDir) {
    $OutputDir = Join-Path $RepoRoot "artifacts\Files-Portable-$Arch"
}
if (-not $LogPath) {
    $LogPath = Join-Path ([IO.Path]::GetTempPath()) "files-portable-build-$Arch.log"
}

$rid = "win-$Arch"
$platform = $Arch

function Invoke-DotNet {
    param([string[]]$Args)
    Write-Host ("==> dotnet " + ($Args -join ' ')) -ForegroundColor Cyan
    & dotnet @Args 2>&1 | Tee-Object -FilePath $LogPath -Append
    if ($LASTEXITCODE -ne 0) {
        Write-Host "----- last 80 log lines -----" -ForegroundColor Yellow
        if (Test-Path $LogPath) {
            Get-Content $LogPath -Tail 80 | ForEach-Object { Write-Host $_ }
        }
        throw "dotnet failed ($LASTEXITCODE): $($Args -join ' ')"
    }
}

"==== Files portable build $(Get-Date -Format o) ====" | Set-Content -Path $LogPath -Encoding utf8
"RepoRoot=$RepoRoot" | Add-Content $LogPath
"RID=$rid Platform=$platform Config=$Configuration" | Add-Content $LogPath
"Output=$OutputDir" | Add-Content $LogPath

Write-Host "RepoRoot: $RepoRoot"
Write-Host "RID: $rid | Platform: $platform | Config: $Configuration"
Write-Host "Output: $OutputDir"
Write-Host "Log: $LogPath"

$env:FILES_PORTABLE_BUILD = 'true'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'

$appProj = Join-Path $RepoRoot 'src\Files.App\Files.App.csproj'
$serverProj = Join-Path $RepoRoot 'src\Files.App.Server\Files.App.Server.csproj'
if (-not (Test-Path $appProj)) { throw "Missing $appProj" }

# Ensure windows workload pieces if available (best-effort)
try {
    Write-Host "==> Workload list (best-effort)"
    & dotnet workload list 2>&1 | Tee-Object -FilePath $LogPath -Append | Out-Null
} catch {}

Write-Host "==> Restore Server + App"
Invoke-DotNet @(
    'restore', $serverProj,
    '-p:Platform=' + $platform,
    '-p:FILES_PORTABLE_BUILD=true',
    '-v:n'
)
Invoke-DotNet @(
    'restore', $appProj,
    '-p:Platform=' + $platform,
    '-p:FILES_PORTABLE_BUILD=true',
    '-v:n'
)

# Build Server into default bin layout so Files.App CsWinRT can find the .winmd
Write-Host "==> Build Server (bin layout for winmd)"
Invoke-DotNet @(
    'build', $serverProj,
    '-c', $Configuration,
    '-p:Platform=' + $platform,
    '-p:RuntimeIdentifier=' + $rid,
    '-p:FILES_PORTABLE_BUILD=true',
    '-p:SelfContained=true',
    '--no-restore',
    '-v:n'
)

Write-Host "==> Publish Server"
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Invoke-DotNet @(
    'publish', $serverProj,
    '-c', $Configuration,
    '-p:Platform=' + $platform,
    '-p:RuntimeIdentifier=' + $rid,
    '-p:SelfContained=true',
    '-p:FILES_PORTABLE_BUILD=true',
    '-p:PublishReadyToRun=false',
    '-p:PublishTrimmed=false',
    '--no-restore',
    '-o', (Join-Path $OutputDir '_server_pub'),
    '-v:n'
)

Write-Host "==> Publish App (unpackaged, WASDK self-contained)"
# ReadyToRun off first for CI reliability; still self-contained
Invoke-DotNet @(
    'publish', $appProj,
    '-c', $Configuration,
    '-p:Platform=' + $platform,
    '-p:RuntimeIdentifier=' + $rid,
    '-p:WindowsPackageType=None',
    '-p:WindowsAppSDKSelfContained=true',
    '-p:SelfContained=true',
    '-p:EnableMsixTooling=false',
    '-p:FILES_PORTABLE_BUILD=true',
    '-p:PublishReadyToRun=false',
    '-p:PublishReadyToRunComposite=false',
    '-p:GenerateAppxPackageOnBuild=false',
    '-p:AppxPackage=false',
    '-p:AppxBundle=Never',
    '--no-restore',
    '-o', $OutputDir,
    '-v:n'
)

$serverPub = Join-Path $OutputDir '_server_pub'
if (Test-Path $serverPub) {
    Copy-Item -Path (Join-Path $serverPub '*') -Destination $OutputDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $serverPub -Recurse -Force -ErrorAction SilentlyContinue
}

$data = Join-Path $OutputDir 'Data'
New-Item -ItemType Directory -Force -Path $data | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $data 'LocalState\settings') | Out-Null

@'
Files Portable (unpackaged)
===========================
- Run Files.exe (no install / no MSIX).
- Settings & logs: .\Data\LocalState\
- Override data dir: set FILES_PORTABLE_DATA=D:\path\to\data
- Built via toyfer/files-portable-builder GitHub Actions
'@ | Set-Content -Path (Join-Path $OutputDir 'PORTABLE_README.txt') -Encoding UTF8

@'
@echo off
cd /d "%~dp0"
start "" "%~dp0Files.exe" %*
'@ | Set-Content -Path (Join-Path $OutputDir 'Files-Portable.cmd') -Encoding ASCII

# Copy log next to output for artifact convenience
Copy-Item $LogPath (Join-Path $OutputDir 'build.log') -Force -ErrorAction SilentlyContinue
Copy-Item $LogPath (Join-Path (Split-Path $OutputDir -Parent) 'build.log') -Force -ErrorAction SilentlyContinue

Write-Host "DONE: $OutputDir" -ForegroundColor Green
Write-Host "LOG:  $LogPath"
