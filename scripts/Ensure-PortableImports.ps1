#Requires -Version 5.1
# Copy portable props/targets into Files repo and wire Directory.Build.* / Packages imports.
param(
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [Parameter(Mandatory=$true)][string]$BuilderRoot
)
$ErrorActionPreference = 'Stop'

$props = Join-Path $BuilderRoot 'Directory.Build.portable.props'
$targets = Join-Path $BuilderRoot 'Directory.Build.portable.targets'
$pkgs = Join-Path $BuilderRoot 'Directory.Packages.portable.props'
if (-not (Test-Path $props)) { throw "missing $props" }
if (-not (Test-Path $targets)) { throw "missing $targets" }

Copy-Item -Force $props (Join-Path $RepoRoot 'Directory.Build.portable.props')
Copy-Item -Force $targets (Join-Path $RepoRoot 'Directory.Build.portable.targets')
if (Test-Path $pkgs) {
    Copy-Item -Force $pkgs (Join-Path $RepoRoot 'Directory.Packages.portable.props')
}

function Ensure-Import([string]$FileName, [string]$ImportName) {
    $path = Join-Path $RepoRoot $FileName
    $importLine = "  <Import Project=`"$ImportName`" Condition=`"Exists('$ImportName')`" />"
    if (-not (Test-Path $path)) {
        @(
            '<Project>'
            $importLine
            '</Project>'
        ) -join "`n" | Set-Content -LiteralPath $path -Encoding UTF8
        Write-Host "Created $FileName"
        return
    }
    $text = Get-Content -Raw $path
    if ($text -match [regex]::Escape($ImportName)) {
        Write-Host "$FileName already imports $ImportName"
        return
    }
    if ($text -match '</Project>') {
        $text = $text -replace '</Project>', ($importLine + "`n</Project>")
        Set-Content -LiteralPath $path -Value $text -Encoding UTF8 -NoNewline
        Write-Host "Patched $FileName"
    } else {
        throw "$FileName missing </Project>"
    }
}

Ensure-Import 'Directory.Build.props' 'Directory.Build.portable.props'
Ensure-Import 'Directory.Build.targets' 'Directory.Build.portable.targets'
if (Test-Path (Join-Path $RepoRoot 'Directory.Packages.portable.props')) {
    Ensure-Import 'Directory.Packages.props' 'Directory.Packages.portable.props'
}
Write-Host 'Portable imports ready'
# Show pinned WASDK line for CI logs
$p = Join-Path $RepoRoot 'Directory.Packages.portable.props'
if (Test-Path $p) {
    Write-Host '--- Directory.Packages.portable.props ---'
    Get-Content $p
}
