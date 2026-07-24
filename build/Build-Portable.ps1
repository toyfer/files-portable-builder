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
    $LogPath = Join-Path $PSScriptRoot "build-$Arch.log"
    if (-not (Test-Path (Split-Path $LogPath -Parent))) {
        $LogPath = Join-Path ([IO.Path]::GetTempPath()) "files-portable-build-$Arch.log"
    }
}

$rid = "win-$Arch"
$platform = $Arch

function Invoke-DotNetLogged {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$DotNetArguments
    )
    $cmdLine = 'dotnet ' + ($DotNetArguments -join ' ')
    Write-Host "==> $cmdLine" -ForegroundColor Cyan
    Add-Content -Path $LogPath -Value "==> $cmdLine" -Encoding utf8

    $output = & dotnet @DotNetArguments 2>&1
    $code = $LASTEXITCODE
    foreach ($line in $output) {
        $s = "$line"
        Write-Host $s
        Add-Content -Path $LogPath -Value $s -Encoding utf8
    }

    if ($code -ne 0) {
        Write-Host "----- matching errors -----" -ForegroundColor Yellow
        $output | ForEach-Object { "$_" } | Select-String -Pattern 'error CS|error MSB|: error |BUILD FAILED' | ForEach-Object { Write-Host $_.Line -ForegroundColor Red }
        Write-Host "----- last 40 lines -----" -ForegroundColor Yellow
        $output | Select-Object -Last 40 | ForEach-Object { Write-Host $_ }
        throw "dotnet failed (exit $code): $cmdLine"
    }
}

@"
==== Files portable build $(Get-Date -Format o) ====
RepoRoot=$RepoRoot
RID=$rid Platform=$platform Config=$Configuration
Output=$OutputDir
Log=$LogPath
PSVersion=$($PSVersionTable.PSVersion)
"@ | Set-Content -Path $LogPath -Encoding utf8

Write-Host "RepoRoot: $RepoRoot"
Write-Host "RID: $rid | Platform: $platform | Config: $Configuration"
Write-Host "Output: $OutputDir"
Write-Host "Log: $LogPath"
Write-Host "dotnet: $((Get-Command dotnet).Source)"
& dotnet --info 2>&1 | Select-Object -First 25 | ForEach-Object { Write-Host $_; Add-Content $LogPath $_ }

$env:FILES_PORTABLE_BUILD = 'true'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'

$appProj = Join-Path $RepoRoot 'src\Files.App\Files.App.csproj'
$serverProj = Join-Path $RepoRoot 'src\Files.App.Server\Files.App.Server.csproj'
if (-not (Test-Path $appProj)) { throw "Missing $appProj" }
if (-not (Test-Path $serverProj)) { throw "Missing $serverProj" }

Write-Host "==> Restore Server + App"
Invoke-DotNetLogged -DotNetArguments @(
    'restore', $serverProj,
    "-p:Platform=$platform",
    '-p:FILES_PORTABLE_BUILD=true',
    '-v:n'
)
Invoke-DotNetLogged -DotNetArguments @(
    'restore', $appProj,
    "-p:Platform=$platform",
    '-p:FILES_PORTABLE_BUILD=true',
    '-v:n'
)

# Build Server into default bin so Files.App CsWinRT can find .winmd
Write-Host "==> Build Server (bin layout for winmd)"
Invoke-DotNetLogged -DotNetArguments @(
    'build', $serverProj,
    '-c', $Configuration,
    "-p:Platform=$platform",
    "-p:RuntimeIdentifier=$rid",
    '-p:FILES_PORTABLE_BUILD=true',
    '-p:SelfContained=true',
    '-p:PublishTrimmed=false',
    '--no-restore',
    '-v:n'
)

Write-Host "==> Publish Server"
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Invoke-DotNetLogged -DotNetArguments @(
    'publish', $serverProj,
    '-c', $Configuration,
    "-p:Platform=$platform",
    "-p:RuntimeIdentifier=$rid",
    '-p:SelfContained=true',
    '-p:FILES_PORTABLE_BUILD=true',
    '-p:PublishReadyToRun=false',
    '-p:PublishTrimmed=false',
    '--no-restore',
    '-o', (Join-Path $OutputDir '_server_pub'),
    '-v:n'
)

Write-Host "==> Publish App (unpackaged, WASDK self-contained)"
Invoke-DotNetLogged -DotNetArguments @(
    'publish', $appProj,
    '-c', $Configuration,
    "-p:Platform=$platform",
    "-p:RuntimeIdentifier=$rid",
    '-p:WindowsPackageType=None',
    '-p:WindowsAppSDKSelfContained=true',
    '-p:SelfContained=true',
    '-p:EnableMsixTooling=false',
    '-p:FILES_PORTABLE_BUILD=true',
    '-p:PublishReadyToRun=false',
    '-p:PublishReadyToRunComposite=false',
    '-p:GenerateAppxPackageOnBuild=false',
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

Copy-Item $LogPath (Join-Path $OutputDir 'build.log') -Force -ErrorAction SilentlyContinue
$outParent = Split-Path $OutputDir -Parent
if ($outParent) {
    Copy-Item $LogPath (Join-Path $outParent 'build.log') -Force -ErrorAction SilentlyContinue
}

Write-Host "DONE: $OutputDir" -ForegroundColor Green
Write-Host "LOG:  $LogPath"
