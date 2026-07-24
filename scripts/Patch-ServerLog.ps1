#Requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$RepoRoot)
$ErrorActionPreference = 'Stop'
$path = Join-Path $RepoRoot 'src\Files.App.Server\Program.cs'
if (-not (Test-Path $path)) { Write-Host 'No Server Program.cs'; return }

$t = Get-Content -Raw $path
if ($t -notmatch 'ApplicationData\.Current\.LocalFolder') {
    Write-Host 'Server already patched or no ApplicationData usage'
    return
}

if ($t -notmatch 'using System\.IO') {
    $t = "using System.IO;`r`n" + $t
}

# Replace common field initializer with CreateLogWriter helper
$pattern = 'private static readonly StreamWriter logWriter = new\([^;]+;'
$replacement = @'
private static readonly StreamWriter logWriter = CreateLogWriter();

	private static StreamWriter CreateLogWriter()
	{
		var dir = Path.Combine(AppContext.BaseDirectory, "Data", "LocalState");
		Directory.CreateDirectory(dir);
		return new StreamWriter(Path.Combine(dir, "debug_server.log"), append: true) { AutoFlush = true };
	}
'@

if ($t -match $pattern) {
    $t = [regex]::Replace($t, $pattern, $replacement, 1)
} else {
    $t = $t.Replace('ApplicationData.Current.LocalFolder.Path', 'Path.Combine(AppContext.BaseDirectory, "Data", "LocalState")')
}

Set-Content -LiteralPath $path -Value $t -Encoding UTF8 -NoNewline
Write-Host 'Patched Files.App.Server Program.cs log path'
