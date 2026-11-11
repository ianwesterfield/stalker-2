# Build the mod's localization: vanilla Game.locres + localization/localization.<lang>.csv rows.
# Extracts the vanilla locres fresh each run so game patches are picked up.
# Output lands in pak/ but is gitignored (it embeds the full vanilla string table).
param([string[]]$Languages = @("en"))

. "$PSScriptRoot\..\..\..\shared\scripts\paths.ps1"
$ModRoot = Split-Path $PSScriptRoot -Parent
$ModDir = Join-Path $ModRoot "pak"

$pak = Join-Path $PaksDir "pakchunk0-Windows.pak"

foreach ($lang in $Languages) {
  $csv = Join-Path $ModRoot "localization\localization.$lang.csv"
  if (-not (Test-Path $csv)) { Write-Warning "No $csv — skipping $lang"; continue }

  & $Repak unpack -o $VanillaDir -i "Stalker2/Content/Localization/Game/$lang/Game.locres" -f $pak | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "repak unpack failed for $lang locres" }

  $vanillaLocres = Join-Path $VanillaDir "Stalker2\Content\Localization\Game\$lang\Game.locres"
  $outLocres = Join-Path $ModDir "Stalker2\Content\Localization\Game\$lang\Game.locres"
  python (Join-Path $SharedTools "make_locres.py") $vanillaLocres $csv $outLocres
  if ($LASTEXITCODE -ne 0) { throw "make_locres failed for $lang" }
}
