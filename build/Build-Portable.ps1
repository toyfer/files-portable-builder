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
    $lines = @()
    foreach ($line in $output) {
        $s = "$line"
        $lines += $s
        Write-Host $s
        Add-Content -Path $LogPath -Value $s -Encoding utf8
    }

    if ($code -ne 0) {
        $errLines = $lines | Where-Object {
            $_ -match 'error CS|error MSB|: error |should not be applied|XamlCompiler error|WMC\d+|BUILD FAILED'
        } | Select-Object -First 40

        Write-Host "----- matching errors -----" -ForegroundColor Yellow
        $errLines | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        Write-Host "----- last 30 lines -----" -ForegroundColor Yellow
        $lines | Select-Object -Last 30 | ForEach-Object { Write-Host $_ }

        $errText = if ($errLines) { ($errLines -join "`n") } else { ($lines | Select-Object -Last 25) -join "`n" }
        throw @"
dotnet failed (exit $code)
Command: $cmdLine
--- errors ---
$errText
--- end ---
"@
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

$portableProps = Join-Path $PSScriptRoot '..\Directory.Build.portable.props'
$portableTargets = Join-Path $PSScriptRoot '..\Directory.Build.portable.targets'
if (Test-Path $portableProps) {
    Copy-Item -Force $portableProps (Join-Path $RepoRoot 'Directory.Build.portable.props')
}
if (Test-Path $portableTargets) {
    Copy-Item -Force $portableTargets (Join-Path $RepoRoot 'Directory.Build.portable.targets')
}

$appProj = Join-Path $RepoRoot 'src\Files.App\Files.App.csproj'
$serverProj = Join-Path $RepoRoot 'src\Files.App.Server\Files.App.Server.csproj'
if (-not (Test-Path $appProj)) { throw "Missing $appProj" }
if (-not (Test-Path $serverProj)) { throw "Missing $serverProj" }

# DO NOT pass WindowsAppSDKSelfContained / SelfContained as global -p: (breaks class libs).
# Directory.Build.portable.targets sets them only for WinExe/Exe.
$common = @(
    "-p:Platform=$platform"
    '-p:FILES_PORTABLE_BUILD=true'
    '-p:WindowsPackageType=None'
    '-p:EnableMsixTooling=false'
    '-p:GenerateAppxPackageOnBuild=false'
    '-p:AppxBundle=Never'
    '-p:PublishTrimmed=false'
    '-p:PublishReadyToRun=false'
    '-p:PublishReadyToRunComposite=false'
)

Write-Host "==> Restore Server + App"
Invoke-DotNetLogged -DotNetArguments (@('restore', $serverProj) + $common + @('-v:n'))
Invoke-DotNetLogged -DotNetArguments (@('restore', $appProj) + $common + @('-v:n'))

Write-Host "==> Build Server (bin layout for winmd)"
Invoke-DotNetLogged -DotNetArguments (@(
    'build', $serverProj,
    '-c', $Configuration,
    "-p:RuntimeIdentifier=$rid",
    '--no-restore',
    '-v:n'
) + $common)

Write-Host "==> Publish Server"
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Invoke-DotNetLogged -DotNetArguments (@(
    'publish', $serverProj,
    '-c', $Configuration,
    "-p:RuntimeIdentifier=$rid",
    '--no-restore',
    '-o', (Join-Path $OutputDir '_server_pub'),
    '-v:n'
) + $common)

Write-Host "==> Publish App"
Invoke-DotNetLogged -DotNetArguments (@(
    'publish', $appProj,
    '-c', $Configuration,
    "-p:RuntimeIdentifier=$rid",
    '--no-restore',
    '-o', $OutputDir,
    '-v:n'
) + $common)

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
