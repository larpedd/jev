# Runs Luau's type checker over the package.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\typecheck.ps1
#
# Install the analyzer with `aftman install`. Roblox globals come from
# tools/roblox.d.luau rather than Roblox's own database, because the analyzer
# CLI does not download it; your editor uses the real one.

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
Push-Location $root

try {
	$luau = Get-Command luau-lsp -ErrorAction SilentlyContinue
	if ($null -eq $luau) {
		Write-Error "luau-lsp not found. Run 'aftman install' from $root."
	}

	# `script.Parent.X` only resolves through a Rojo sourcemap. The file is
	# gitignored because it is a build artifact; regenerate it with your
	# editor's Rojo plugin if it is missing.
	$sourcemapArgs = @()
	$sourcemap = Join-Path $root "sourcemap.json"
	if (Test-Path $sourcemap) {
		$sourcemapArgs = @("--sourcemap", $sourcemap)
	} else {
		Write-Warning "sourcemap.json not found; 'script.Parent' requires will not resolve."
	}

	$files = Get-ChildItem -Path (Join-Path $root "src") -Recurse -Filter *.luau |
		ForEach-Object { $_.FullName }

	# The analyzer logs progress to stderr, and `Stop` would turn that into a
	# terminating error, so relax it for the call and merge both streams.
	$strict = $ErrorActionPreference
	$ErrorActionPreference = "Continue"
	$output = & $luau.Source analyze `
		--formatter=plain `
		--defs (Join-Path $PSScriptRoot "roblox.d.luau") `
		@sourcemapArgs `
		@files 2>&1
	$ErrorActionPreference = $strict

	$noise = "didChangeWatchedFiles|No definitions file provided|Loading definitions file|sourcemap is disabled"
	$diagnostics = @($output |
		Where-Object { "$_" -notmatch $noise } |
		ForEach-Object { "$_" } |
		Sort-Object -Unique)

	if ($diagnostics.Count -gt 0) {
		$diagnostics | ForEach-Object { Write-Output $_ }
		Write-Error "$($diagnostics.Count) type check diagnostic(s)."
	}

	Write-Host "No type check diagnostics."
} finally {
	Pop-Location
}
