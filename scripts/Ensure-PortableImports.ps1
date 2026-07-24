#Requires -Version 5.1
# Copy portable props/targets into Files repo and wire Directory.Build.* imports.
param(
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [Parameter(Mandatory=$true)][string]$BuilderRoot
)
$ErrorActionPreference = 'Stop'

$props = Join-Path $BuilderRoot 'Directory.Build.portable.props'
$targets = Join-Path $BuilderRoot 'Directory.Build.portable.targets'
if (-not (Test-Path $props)) { throw "missing $props" }
if (-not (Test-Path $targets)) { throw "missing $targets" }

Copy-Item -Force $props (Join-Path $RepoRoot 'Directory.Build.portable.props')
Copy-Item -Force $targets (Join-Path $RepoRoot 'Directory.Build.portable.targets')

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
Write-Host 'Portable imports ready'
