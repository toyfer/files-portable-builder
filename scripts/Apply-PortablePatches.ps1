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

if (-not (Test-Path $ctxSrc)) { throw "Missing $ctxSrc" }
if (-not (Test-Path $propsSrc)) { throw "Missing $propsSrc" }

Copy-Item -Force $propsSrc (Join-Path $RepoRoot 'Directory.Build.portable.props')

# Always install PortableAppContext into Files.App only
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

function Add-HelpersUsing([string]$text) {
    if ($text -match 'using Files\.App\.Helpers') { return $text }
    if ($text -match '(?m)^using .+;\r?\n') {
        return [regex]::Replace($text, '((?m)^using .+;\r?\n)+', { param($m) $m.Value + "using Files.App.Helpers;`r`n" }, 1)
    }
    return "using Files.App.Helpers;`r`n" + $text
}

function Apply-Replacements([string]$text) {
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
    foreach ($r in $replacements) {
        $text = [regex]::Replace($text, $r.From, $r.To)
    }
    $text = $text -replace 'Package\.Current\.Id\.Version\.Major', 'PortableAppContext.PackageVersion.Major'
    $text = $text -replace 'Package\.Current\.Id\.Version\.Minor', 'PortableAppContext.PackageVersion.Minor'
    $text = $text -replace 'Package\.Current\.Id\.Version\.Build', 'PortableAppContext.PackageVersion.Build'
    $text = $text -replace 'Package\.Current\.Id\.Version\.Revision', 'PortableAppContext.PackageVersion.Revision'
    $text = $text -replace 'Package\.Current\.Id\.Version', 'PortableAppContext.PackageVersion'
    return $text
}

Write-Step 'Scripted portable patch (Files.App only)'

# IMPORTANT: only patch Files.App project — Server/BackgroundTasks cannot reference Files.App.Helpers
$appRoot = Join-Path $RepoRoot 'src\Files.App'
$csFiles = Get-ChildItem -Path $appRoot -Filter '*.cs' -Recurse |
    Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' -and $_.Name -ne 'PortableAppContext.cs' }

$changed = 0
foreach ($f in $csFiles) {
    $text = Get-Content -Raw -LiteralPath $f.FullName
    $orig = $text
    $text = Apply-Replacements $text
    if ($text -ne $orig) {
        if ($text -match 'PortableAppContext') {
            $text = Add-HelpersUsing $text
        }
        Set-Content -LiteralPath $f.FullName -Value $text -Encoding UTF8 -NoNewline
        $changed++
    }
}
Write-Step "Rewrote $changed files under Files.App"

# Program.cs EnsureDataLayout
$program = Join-Path $appRoot 'Program.cs'
if (Test-Path $program) {
    $pt = Get-Content -Raw $program
    if ($pt -notmatch 'PortableAppContext\.EnsureDataLayout') {
        $pt = $pt.Replace(
            'Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);',
            "PortableAppContext.EnsureDataLayout();`r`n`t`t`tEncoding.RegisterProvider(CodePagesEncodingProvider.Instance);")
        $pt = Add-HelpersUsing $pt
        Set-Content -LiteralPath $program -Value $pt -Encoding UTF8 -NoNewline
        Write-Step 'Program.cs EnsureDataLayout'
    }
}

# AppLifecycleHelper.AppVersion
$life = Join-Path $appRoot 'Helpers\Application\AppLifecycleHelper.cs'
if (Test-Path $life) {
    $lt = Get-Content -Raw $life
    $lt2 = [regex]::Replace($lt,
        'public static Version AppVersion \{ get; \} =\s*new\([^;]+;',
        'public static Version AppVersion { get; } = PortableAppContext.AppVersion;')
    if ($lt2 -ne $lt) {
        $lt2 = Add-HelpersUsing $lt2
        Set-Content -LiteralPath $life -Value $lt2 -Encoding UTF8 -NoNewline
        Write-Step 'AppLifecycleHelper.AppVersion'
    }
}

# Guard update services (Files.App only)
$upd = Get-ChildItem -Path $appRoot -Filter '*Update*Service*.cs' -Recurse -ErrorAction SilentlyContinue
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
            $ut2 = Add-HelpersUsing $ut2
            Set-Content -LiteralPath $u.FullName -Value $ut2 -Encoding UTF8 -NoNewline
            Write-Step "Guarded updates in $($u.Name)"
        }
    }
}

# WindowEx: skip placement when portable; avoid field-init ApplicationData
$winEx = Join-Path $appRoot 'Data\Items\WindowEx.cs'
if (Test-Path $winEx) {
    $wt = Get-Content -Raw $winEx
    $orig = $wt
    $wt = Add-HelpersUsing $wt

    if ($wt -match 'private readonly ApplicationDataContainer _applicationDataContainer = ApplicationData\.Current\.LocalSettings') {
        $wt = $wt.Replace(
            'private readonly ApplicationDataContainer _applicationDataContainer = ApplicationData.Current.LocalSettings;',
            'private ApplicationDataContainer? _applicationDataContainer => PortableAppContext.IsPackaged ? Windows.Storage.ApplicationData.Current.LocalSettings : null;')
    }

    foreach ($method in @('SaveWindowPlacement', 'RestoreWindowPlacement', 'SaveWindowPlacementData', 'RestoreWindowPlacementData')) {
        if ($wt -match "void $method" -and $wt -notmatch "$method[\s\S]{0,180}IsPortable") {
            $wt = [regex]::Replace($wt,
                "(private void $method[^\r\n]*\r?\n\s*\{)",
                "`$1`r`n`t`t`tif (PortableAppContext.IsPortable) return;")
        }
    }

    if ($wt -match 'GetDataStore' -and $wt -notmatch 'GetDataStore[\s\S]{0,160}IsPortable') {
        $wt = [regex]::Replace($wt,
            '(private IPropertySet GetDataStore\(out bool oldDataExists, bool useNewStore = true\)\s*\{)',
            "`$1`r`n`t`t`toldDataExists = false;`r`n`t`t`tif (PortableAppContext.IsPortable || _applicationDataContainer is null)`r`n`t`t`t{`r`n`t`t`t`t// Callers return early on portable; provide dummy to satisfy compiler`r`n`t`t`t`treturn Windows.Storage.ApplicationData.Current.LocalSettings.Values;`r`n`t`t`t}")
    }

    if ($wt -ne $orig) {
        Set-Content -LiteralPath $winEx -Value $wt -Encoding UTF8 -NoNewline
        Write-Step 'WindowEx portable-hardened'
    }
}

# --- Server: folder-local log path WITHOUT Files.App.Helpers ---
$serverProg = Join-Path $RepoRoot 'src\Files.App.Server\Program.cs'
if (Test-Path $serverProg) {
    $st = Get-Content -Raw $serverProg
    if ($st -match 'ApplicationData\.Current\.LocalFolder\.Path') {
        if ($st -notmatch 'using System\.IO') {
            $st = "using System.IO;`r`n" + $st
        }
        $st = $st.Replace(
            'ApplicationData.Current.LocalFolder.Path',
            'Path.Combine(AppContext.BaseDirectory, "Data", "LocalState")')
        # Ensure directory exists before StreamWriter - inject static ctor helper near field if needed
        if ($st -match 'new\(Path\.Combine\(AppContext\.BaseDirectory' -and $st -notmatch 'Directory\.CreateDirectory') {
            $st = $st.Replace(
                'private static readonly StreamWriter logWriter = new(Path.Combine(AppContext.BaseDirectory, "Data", "LocalState"), "debug_server.log"), append: true) { AutoFlush = true };',
                @'
private static readonly StreamWriter logWriter = CreateLogWriter();

	private static StreamWriter CreateLogWriter()
	{
		var dir = Path.Combine(AppContext.BaseDirectory, "Data", "LocalState");
		Directory.CreateDirectory(dir);
		return new StreamWriter(Path.Combine(dir, "debug_server.log"), append: true) { AutoFlush = true };
	}
'@)
            # fallback simpler replace if field format differs
            if ($st -match 'ApplicationData' -or ($st -match 'logWriter = new\(Path\.Combine\(AppContext' -and $st -notmatch 'CreateLogWriter')) {
                $st = [regex]::Replace($st,
                    'private static readonly StreamWriter logWriter = new\(([^;]+);',
                    {
                        param($m)
                        @'
private static readonly StreamWriter logWriter = CreateLogWriter();

	private static StreamWriter CreateLogWriter()
	{
		var dir = Path.Combine(AppContext.BaseDirectory, "Data", "LocalState");
		Directory.CreateDirectory(dir);
		return new StreamWriter(Path.Combine(dir, "debug_server.log"), append: true) { AutoFlush = true };
	}
'@
                    }, 1)
            }
        }
        Set-Content -LiteralPath $serverProg -Value $st -Encoding UTF8 -NoNewline
        Write-Step 'Files.App.Server log path -> Data\LocalState'
    }
}

# --- BackgroundTasks: simple path, no Helpers ---
$bg = Join-Path $RepoRoot 'src\Files.App.BackgroundTasks\UpdateTask.cs'
if (Test-Path $bg) {
    $bt = Get-Content -Raw $bg
    if ($bt -match 'ApplicationData\.Current\.LocalFolder\.Path') {
        if ($bt -notmatch 'using System\.IO') { $bt = "using System.IO;`r`n" + $bt }
        $bt = $bt.Replace(
            'ApplicationData.Current.LocalFolder.Path',
            'Path.Combine(AppContext.BaseDirectory, "Data", "LocalState")')
        Set-Content -LiteralPath $bg -Value $bt -Encoding UTF8 -NoNewline
        Write-Step 'BackgroundTasks paths patched'
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

# Sanity: no Files.App.Helpers outside Files.App
$bad = Select-String -Path (Join-Path $RepoRoot 'src\Files.App.Server\*.cs'), (Join-Path $RepoRoot 'src\Files.App.BackgroundTasks\*.cs') -Pattern 'Files\.App\.Helpers|PortableAppContext' -SimpleMatch -ErrorAction SilentlyContinue
# Select-String -SimpleMatch can't do OR well; use regex
$leaks = @()
foreach ($p in @(
    (Join-Path $RepoRoot 'src\Files.App.Server'),
    (Join-Path $RepoRoot 'src\Files.App.BackgroundTasks')
)) {
    if (Test-Path $p) {
        $leaks += Get-ChildItem $p -Filter '*.cs' -Recurse | Select-String -Pattern 'Files\.App\.Helpers|PortableAppContext' -ErrorAction SilentlyContinue
    }
}
if ($leaks.Count -gt 0) {
    $leaks | ForEach-Object { Write-Warning $_.ToString() }
    throw 'PortableAppContext leaked into non-App projects'
}

Write-Step 'Portable patches applied'
Get-ChildItem (Join-Path $ctxDstDir 'PortableAppContext.cs') -ErrorAction Stop | Out-Null
Write-Host 'OK'
