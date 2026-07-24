#Requires -Version 5.1
# Post-pass after Apply-PortablePatches: fix APIs that break unpackaged / offline builds.
param([Parameter(Mandatory=$true)][string]$RepoRoot)
$ErrorActionPreference = 'Stop'
$app = Join-Path $RepoRoot 'src\Files.App'

function Edit-File([string]$Rel, [scriptblock]$Edit) {
    $p = Join-Path $RepoRoot $Rel
    if (-not (Test-Path $p)) { return }
    $t = Get-Content -Raw $p
    $n = & $Edit $t
    if ($n -ne $t) {
        Set-Content -LiteralPath $p -Value $n -Encoding UTF8 -NoNewline
        Write-Host "fixed $Rel"
    }
}

# LaunchFolderPathAsync is not always available the same way; use GetFolderFromPathAsync + LaunchFolderAsync
Get-ChildItem $app -Filter *.cs -Recurse | ForEach-Object {
    $t = Get-Content -Raw $_.FullName
    if ($t -match 'LaunchFolderPathAsync\(PortableAppContext\.LocalFolderPath\)') {
        $n = $t.Replace(
            'await Launcher.LaunchFolderPathAsync(PortableAppContext.LocalFolderPath).AsTask();',
            'await Launcher.LaunchFolderAsync(await StorageFolder.GetFolderFromPathAsync(PortableAppContext.LocalFolderPath)).AsTask();')
        if ($n -ne $t) {
            if ($n -notmatch 'using Windows\.Storage') {
                $n = "using Windows.Storage;`r`n" + $n
            }
            Set-Content $_.FullName $n -Encoding UTF8 -NoNewline
            Write-Host "LaunchFolder fix $($_.Name)"
        }
    }
}

# WindowEx GetDataStore: never touch ApplicationData when portable
Edit-File 'src\Files.App\Data\Items\WindowEx.cs' {
    param($t)
    if ($t -match 'return Windows\.Storage\.ApplicationData\.Current\.LocalSettings\.Values; // unused on portable') {
        $t = $t.Replace(
            'return Windows.Storage.ApplicationData.Current.LocalSettings.Values; // unused on portable',
            'return new Windows.Foundation.Collections.ValueSet(); // portable dummy')
    }
    if ($t -match 'Callers return early on portable' -and $t -match 'ApplicationData\.Current\.LocalSettings\.Values') {
        $t = $t -replace 'return Windows\.Storage\.ApplicationData\.Current\.LocalSettings\.Values;', 'return new Windows.Foundation.Collections.ValueSet();'
    }
    # Any remaining dummy ApplicationData in GetDataStore portable branch
    $t = [regex]::Replace($t,
        '(if \(PortableAppContext\.IsPortable[\s\S]{0,200}?)return Windows\.Storage\.ApplicationData\.Current\.LocalSettings\.Values;',
        { param($m) $m.Groups[1].Value + 'return new Windows.Foundation.Collections.ValueSet();' })
    return $t
}

# Constants ReleaseNotesUrl may still need Helpers using
Edit-File 'src\Files.App\Constants.cs' {
    param($t)
    if ($t -match 'PortableAppContext' -and $t -notmatch 'using Files\.App\.Helpers') {
        $t = $t.Replace('using Windows.ApplicationModel;', "using Windows.ApplicationModel;`r`nusing Files.App.Helpers;")
    }
    return $t
}

# Prefer folder-local for OpenLogFileAction if still broken
Write-Host 'Fix-RemainingPortable done'
