# Build the mod's localization: vanilla Game.locres + mod-source/localization.<lang>.csv rows.
# Extracts the vanilla locres fresh each run so game patches are picked up.
param([string[]]$Languages = @("en"))

. "$PSScriptRoot\paths.ps1"

$pak = Join-Path $PaksDir "pakchunk0-Windows.pak"

foreach ($lang in $Languages) {
  $csv = Join-Path $RepoRoot "mod-source\localization.$lang.csv"
  if (-not (Test-Path $csv)) { Write-Warning "No $csv — skipping $lang"; continue }

  & $Repak unpack -o $VanillaDir -i "Stalker2/Content/Localization/Game/$lang/Game.locres" -f $pak | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "repak unpack failed for $lang locres" }

  $vanillaLocres = Join-Path $VanillaDir "Stalker2\Content\Localization\Game\$lang\Game.locres"
  $outLocres = Join-Path $ModDir "Stalker2\Content\Localization\Game\$lang\Game.locres"
  python (Join-Path $RepoRoot "tools\make_locres.py") $vanillaLocres $csv $outLocres
  if ($LASTEXITCODE -ne 0) { throw "make_locres failed for $lang" }
}
