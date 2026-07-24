#Requires -Version 5.1
<#
.SYNOPSIS
  Patch files-community/Files for unpackaged portable builds.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$BuilderRoot
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }

if (-not (Test-Path (Join-Path $RepoRoot 'src\Files.App\Files.App.csproj'))) {
    throw "Not a Files repo: $RepoRoot"
}

$propsSrc = Join-Path $BuilderRoot 'Directory.Build.portable.props'
$ctxSrc = Join-Path $BuilderRoot 'patches\PortableAppContext.cs'
$patchFile = Join-Path $BuilderRoot 'patches\files-portable-unpackaged.patch'

if (-not (Test-Path $ctxSrc)) { throw "Missing $ctxSrc" }
if (-not (Test-Path $propsSrc)) { throw "Missing $propsSrc" }

Copy-Item -Force $propsSrc (Join-Path $RepoRoot 'Directory.Build.portable.props')

# Always install PortableAppContext
$ctxDstDir = Join-Path $RepoRoot 'src\Files.App\Helpers\Application'
New-Item -ItemType Directory -Force -Path $ctxDstDir | Out-Null
Copy-Item -Force $ctxSrc (Join-Path $ctxDstDir 'PortableAppContext.cs')
Write-Step 'Installed PortableAppContext.cs'

# Import portable props
$dbp = Join-Path $RepoRoot 'Directory.Build.props'
$dbpText = Get-Content -Raw -LiteralPath $dbp
if ($dbpText -notmatch 'Directory\.Build\.portable\.props') {
    $import = '  <Import Project="Directory.Build.portable.props" Condition="Exists(''Directory.Build.portable.props'')" />' + "`n</Project>"
    if ($dbpText -match '</Project>') {
        $dbpText = $dbpText -replace '</Project>', $import
        Set-Content -LiteralPath $dbp -Value $dbpText -Encoding UTF8 -NoNewline
        Write-Step 'Patched Directory.Build.props import'
    } else {
        throw 'Directory.Build.props missing </Project>'
    }
}

# Optional full patch file
$usedGitPatch = $false
if (Test-Path $patchFile) {
    Write-Step 'Trying git apply...'
    Push-Location $RepoRoot
    try {
        git apply --3way --whitespace=nowarn $patchFile 2>&1 | Write-Host
        if ($LASTEXITCODE -eq 0) {
            $usedGitPatch = $true
            Write-Step 'git apply succeeded'
            Copy-Item -Force $ctxSrc (Join-Path $ctxDstDir 'PortableAppContext.cs')
        } else {
            Write-Warning "git apply exit $LASTEXITCODE — falling back to scripted patch"
        }
    } finally {
        Pop-Location
    }
}

if (-not $usedGitPatch) {
    Write-Step 'Scripted portable patch'

    $replacements = @(
        @{ From = 'ApplicationData\.Current\.LocalFolder\.Path'; To = 'PortableAppContext.LocalFolderPath' }
        @{ From = 'ApplicationData\.Current\.TemporaryFolder\.Path'; To = 'PortableAppContext.TemporaryFolderPath' }
        @{ From = 'ApplicationData\.Current\.RoamingFolder\.Path'; To = 'PortableAppContext.RoamingFolderPath' }
        @{ From = 'ApplicationData\.Current\.LocalCacheFolder\.Path'; To = 'PortableAppContext.LocalCacheFolderPath' }
        @{ From = 'ApplicationData\.Current\.LocalSettings\.Values'; To = 'PortableAppContext.LocalSettingsValues' }
        @{ From = 'Windows\.ApplicationModel\.Package\.Current\.EffectivePath'; To = 'PortableAppContext.EffectivePath' }
        @{ From = 'Package\.Current\.EffectivePath'; To = 'PortableAppContext.EffectivePath' }
        @{ From = 'Package\.Current\.InstalledLocation\.Path'; To = 'PortableAppContext.InstalledLocationPath' }
        @{ From = 'Windows\.ApplicationModel\.Package\.Current\.Id\.FamilyName'; To = 'PortableAppContext.PackageFamilyName' }
        @{ From = 'Package\.Current\.Id\.FamilyName'; To = 'PortableAppContext.PackageFamilyName' }
        @{ From = 'Package\.Current\.Id\.Name'; To = 'PortableAppContext.PackageName' }
        @{ From = 'Package\.Current\.DisplayName'; To = 'PortableAppContext.PackageDisplayName' }
    )

    $csFiles = Get-ChildItem -Path (Join-Path $RepoRoot 'src') -Filter '*.cs' -Recurse |
        Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' -and $_.Name -ne 'PortableAppContext.cs' }

    $changed = 0
    foreach ($f in $csFiles) {
        $text = Get-Content -Raw -LiteralPath $f.FullName
        $orig = $text
        foreach ($r in $replacements) {
            $text = [regex]::Replace($text, $r.From, $r.To)
        }

        $text = $text -replace 'Package\.Current\.Id\.Version\.Major', 'PortableAppContext.PackageVersion.Major'
        $text = $text -replace 'Package\.Current\.Id\.Version\.Minor', 'PortableAppContext.PackageVersion.Minor'
        $text = $text -replace 'Package\.Current\.Id\.Version\.Build', 'PortableAppContext.PackageVersion.Build'
        $text = $text -replace 'Package\.Current\.Id\.Version\.Revision', 'PortableAppContext.PackageVersion.Revision'
        $text = $text -replace 'Package\.Current\.Id\.Version', 'PortableAppContext.PackageVersion'

        if ($text -ne $orig) {
            if ($text -match 'PortableAppContext' -and $text -notmatch 'using Files\.App\.Helpers' -and $text -notmatch 'namespace Files\.App\.Helpers') {
                if ($text -match '(?m)^using .+;\r?\n') {
                    $text = [regex]::Replace($text, '((?m)^using .+;\r?\n)+', { param($m) $m.Value + "using Files.App.Helpers;`r`n" }, 1)
                }
            }
            Set-Content -LiteralPath $f.FullName -Value $text -Encoding UTF8 -NoNewline
            $changed++
        }
    }
    Write-Step "Rewrote $changed C# files"

    $program = Join-Path $RepoRoot 'src\Files.App\Program.cs'
    if (Test-Path $program) {
        $pt = Get-Content -Raw $program
        if ($pt -notmatch 'PortableAppContext\.EnsureDataLayout') {
            $pt = $pt.Replace(
                'Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);',
                "PortableAppContext.EnsureDataLayout();`r`n`t`t`tEncoding.RegisterProvider(CodePagesEncodingProvider.Instance);")
            if ($pt -notmatch 'using Files\.App\.Helpers') {
                $pt = $pt.Replace('namespace Files.App', "using Files.App.Helpers;`r`n`r`nnamespace Files.App")
            }
            Set-Content -LiteralPath $program -Value $pt -Encoding UTF8 -NoNewline
        }
    }

    $life = Join-Path $RepoRoot 'src\Files.App\Helpers\Application\AppLifecycleHelper.cs'
    if (Test-Path $life) {
        $lt = Get-Content -Raw $life
        $lt2 = [regex]::Replace($lt,
            'public static Version AppVersion \{ get; \} =\s*new\([^;]+;',
            'public static Version AppVersion { get; } = PortableAppContext.AppVersion;')
        if ($lt2 -ne $lt) {
            Set-Content -LiteralPath $life -Value $lt2 -Encoding UTF8 -NoNewline
            Write-Step 'AppLifecycleHelper.AppVersion -> PortableAppContext'
        }
    }

    $upd = Get-ChildItem -Path (Join-Path $RepoRoot 'src\Files.App') -Filter '*Update*Service*.cs' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 8
    foreach ($u in $upd) {
        $ut = Get-Content -Raw $u.FullName
        if ($ut -match 'DownloadUpdatesAsync' -and $ut -notmatch 'folder-local build') {
            $ut2 = $ut -replace '(public async Task DownloadUpdatesAsync\(\)\s*\{)', "`$1`r`n`t`t`tif (PortableAppContext.IsPortable)`r`n`t`t`t`treturn; // folder-local build"
            if ($ut2 -match 'CheckForUpdatesAsync\(\)\s*\{' -and $ut2 -notmatch 'IsPortable\)\s*\{\s*IsUpdateAvailable') {
                $ut2 = [regex]::Replace($ut2,
                    '(public async Task CheckForUpdatesAsync\(\)\s*\{)',
                    "`$1`r`n`t`t`tif (PortableAppContext.IsPortable)`r`n`t`t`t{`r`n`t`t`t`tIsUpdateAvailable = false;`r`n`t`t`t`treturn;`r`n`t`t`t}")
            }
            if ($ut2 -ne $ut) {
                Set-Content -LiteralPath $u.FullName -Value $ut2 -Encoding UTF8 -NoNewline
                Write-Step "Guarded updates in $($u.Name)"
            }
        }
    }
}

# WindowEx: neutralize field init; skip placement save/restore when portable
$winEx = Join-Path $RepoRoot 'src\Files.App\Data\Items\WindowEx.cs'
if (Test-Path $winEx) {
    $wt = Get-Content -Raw $winEx
    $orig = $wt

    if ($wt -notmatch 'using Files\.App\.Helpers') {
        $wt = $wt.Replace('using Windows.Storage;', "using Windows.Storage;`r`nusing Files.App.Helpers;")
    }

    if ($wt -match 'private readonly ApplicationDataContainer _applicationDataContainer = ApplicationData\.Current\.LocalSettings') {
        $wt = $wt.Replace(
            'private readonly ApplicationDataContainer _applicationDataContainer = ApplicationData.Current.LocalSettings;',
            'private ApplicationDataContainer? _applicationDataContainer => PortableAppContext.IsPackaged ? Windows.Storage.ApplicationData.Current.LocalSettings : null;')
    }

    # Early-out placement methods when portable (avoid ApplicationData)
    if ($wt -match 'void SaveWindowPlacement' -and $wt -notmatch 'SaveWindowPlacement[\s\S]{0,200}IsPortable') {
        $wt = [regex]::Replace($wt,
            '(private void SaveWindowPlacement[^\r\n]*\r?\n\s*\{)',
            "`$1`r`n`t`t`tif (PortableAppContext.IsPortable) return;")
    }
    if ($wt -match 'void RestoreWindowPlacement' -and $wt -notmatch 'RestoreWindowPlacement[\s\S]{0,200}IsPortable') {
        $wt = [regex]::Replace($wt,
            '(private void RestoreWindowPlacement[^\r\n]*\r?\n\s*\{)',
            "`$1`r`n`t`t`tif (PortableAppContext.IsPortable) return;")
    }

    # Null-safe GetDataStore if field became nullable property
    if ($wt -match 'GetDataStore' -and $wt -match '_applicationDataContainer' -and $wt -notmatch 'GetDataStore[\s\S]{0,120}IsPortable') {
        $wt = [regex]::Replace($wt,
            '(private IPropertySet GetDataStore\(out bool oldDataExists, bool useNewStore = true\)\s*\{)',
            "`$1`r`n`t`t`toldDataExists = false;`r`n`t`t`tif (PortableAppContext.IsPortable || _applicationDataContainer is null)`r`n`t`t`t`treturn Windows.Storage.ApplicationData.Current.LocalSettings.Values; // unused on portable (callers return early)")
    }

    if ($wt -ne $orig) {
        Set-Content -LiteralPath $winEx -Value $wt -Encoding UTF8 -NoNewline
        Write-Step 'WindowEx portable-hardened'
    }
}

# Force portable props into app csproj
$appCsproj = Join-Path $RepoRoot 'src\Files.App\Files.App.csproj'
$appText = Get-Content -Raw $appCsproj
if ($appText -match '<SelfContained>false</SelfContained>') {
    $appText = $appText.Replace('<SelfContained>false</SelfContained>', '<SelfContained Condition="''$(FILES_PORTABLE_BUILD)'' != ''true''">false</SelfContained><SelfContained Condition="''$(FILES_PORTABLE_BUILD)'' == ''true''">true</SelfContained>')
    $appText = $appText.Replace('<WindowsAppSDKSelfContained>false</WindowsAppSDKSelfContained>', '<WindowsAppSDKSelfContained Condition="''$(FILES_PORTABLE_BUILD)'' != ''true''">false</WindowsAppSDKSelfContained><WindowsAppSDKSelfContained Condition="''$(FILES_PORTABLE_BUILD)'' == ''true''">true</WindowsAppSDKSelfContained>')
    Set-Content -LiteralPath $appCsproj -Value $appText -Encoding UTF8 -NoNewline
    Write-Step 'Files.App.csproj self-contained toggles'
}

$appText2 = Get-Content -Raw $appCsproj
if ($appText2 -match '<EnableMsixTooling>true</EnableMsixTooling>') {
    $appText2 = $appText2.Replace('<EnableMsixTooling>true</EnableMsixTooling>', '<EnableMsixTooling Condition="''$(FILES_PORTABLE_BUILD)'' != ''true''">true</EnableMsixTooling><EnableMsixTooling Condition="''$(FILES_PORTABLE_BUILD)'' == ''true''">false</EnableMsixTooling>')
    Set-Content -LiteralPath $appCsproj -Value $appText2 -Encoding UTF8 -NoNewline
    Write-Step 'EnableMsixTooling conditional'
}

Write-Step 'Portable patches applied'
Get-ChildItem (Join-Path $RepoRoot 'src\Files.App\Helpers\Application\PortableAppContext.cs') -ErrorAction Stop | Out-Null
Write-Host 'OK PortableAppContext.cs present'
