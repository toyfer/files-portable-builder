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

    [string]$OutputDir = ''
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $RepoRoot)) { throw "RepoRoot not found: $RepoRoot" }

if (-not $OutputDir) {
    $OutputDir = Join-Path $RepoRoot "artifacts\Files-Portable-$Arch"
}

$rid = "win-$Arch"
$platform = $Arch

Write-Host "RepoRoot: $RepoRoot"
Write-Host "RID: $rid | Platform: $platform | Config: $Configuration"
Write-Host "Output: $OutputDir"

$env:FILES_PORTABLE_BUILD = 'true'

$appProj = Join-Path $RepoRoot 'src\Files.App\Files.App.csproj'
$serverProj = Join-Path $RepoRoot 'src\Files.App.Server\Files.App.Server.csproj'
if (-not (Test-Path $appProj)) { throw "Missing $appProj" }

Write-Host "==> Restore"
dotnet restore $appProj -p:Platform=$platform -p:FILES_PORTABLE_BUILD=true
if ($LASTEXITCODE -ne 0) { throw "restore failed" }

Write-Host "==> Publish Server"
dotnet publish $serverProj `
    -c $Configuration `
    -p:Platform=$platform `
    -p:RuntimeIdentifier=$rid `
    -p:SelfContained=true `
    -p:FILES_PORTABLE_BUILD=true `
    -o (Join-Path $OutputDir '_server_pub')
if ($LASTEXITCODE -ne 0) { throw "server publish failed" }

Write-Host "==> Publish App (unpackaged, WASDK self-contained)"
dotnet publish $appProj `
    -c $Configuration `
    -p:Platform=$platform `
    -p:RuntimeIdentifier=$rid `
    -p:WindowsPackageType=None `
    -p:WindowsAppSDKSelfContained=true `
    -p:SelfContained=true `
    -p:EnableMsixTooling=false `
    -p:FILES_PORTABLE_BUILD=true `
    -p:PublishReadyToRun=true `
    -p:GenerateAppxPackageOnBuild=false `
    -o $OutputDir
if ($LASTEXITCODE -ne 0) { throw "app publish failed" }

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

Write-Host "DONE: $OutputDir" -ForegroundColor Green
