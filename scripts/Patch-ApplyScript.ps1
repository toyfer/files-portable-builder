#Requires -Version 5.1
<#
.SYNOPSIS
  Patch Apply-PortablePatches.ps1 to also install Directory.Packages.portable.props (WASDK 1.6 override).
  This is a one-shot patch script run by the workflow BEFORE Apply-PortablePatches.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$BuilderRoot
)
$ErrorActionPreference = 'Stop'

$applyScript = Join-Path $BuilderRoot 'scripts\Apply-PortablePatches.ps1'
$text = Get-Content -Raw -LiteralPath $applyScript

# Insert WASDK override block right after "Copy-Item -Force $propsSrc" line
$marker = "Copy-Item -Force `$propsSrc (Join-Path `$RepoRoot 'Directory.Build.portable.props')"
$insertBlock = @"
Copy-Item -Force `$propsSrc (Join-Path `$RepoRoot 'Directory.Build.portable.props')

# Install WASDK version override (1.6.x) to avoid WMC9999 XAML compiler resource issue on .NET 10
`$pkgsSrc = Join-Path `$BuilderRoot 'Directory.Packages.portable.props'
if (Test-Path `$pkgsSrc) {
    Copy-Item -Force `$pkgsSrc (Join-Path `$RepoRoot 'Directory.Packages.portable.props')
    `$dpp = Join-Path `$RepoRoot 'Directory.Packages.props'
    if (Test-Path `$dpp) {
        `$dppText = Get-Content -Raw -LiteralPath `$dpp
        if (`$dppText -notmatch 'Directory\.Packages\.portable\.props') {
            `$dppImport = '  <Import Project="Directory.Packages.portable.props" Condition="Exists(''Directory.Packages.portable.props'')" />' + "`n</Project>"
            `$dppText = `$dppText -replace '</Project>', `$dppImport
            Set-Content -LiteralPath `$dpp -Value `$dppText -Encoding UTF8 -NoNewline
            Write-Step 'Patched Directory.Packages.props import (WASDK 1.6 override)'
        }
    }
}
"@

if ($text -notmatch 'Directory\.Packages\.portable\.props') {
    $text = $text -replace [regex]::Escape($marker), $insertBlock
    Set-Content -LiteralPath $applyScript -Value $text -Encoding UTF8 -NoNewline
    Write-Host "Patched Apply-PortablePatches.ps1 with WASDK 1.6 override"
} else {
    Write-Host "Apply-PortablePatches.ps1 already has WASDK override"
}
