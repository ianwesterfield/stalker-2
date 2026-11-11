# Builds the single manifest driving import-englishzone-batch.py (textures -> MIs -> meshes) from
# the EzExport outputs: mod-batch (mod SM/MI JSON + GLB + meshinfo, refs resolved via --names),
# mod (mod texture PNGs), vanilla-batch (vanilla texture settings), vanilla-mi (vanilla sign MIs,
# static-switch templates). Also writes UV-stripped GLBs to mesh-import\. Fails on anything it
# can't map rather than guessing silently.
param(
  [string]$OutFile = ''
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\..\shared\scripts\paths.ps1"

$Zk = Join-Path $BuildDir 'EnglishZone-zk'
$Exp = Join-Path $Zk 'export'
$ModBatch = Join-Path $Exp 'mod-batch'
$ModTex = Join-Path $Exp 'mod'
$VanTex = Join-Path $Exp 'vanilla-batch'
$VanMi = Join-Path $Exp 'vanilla-mi'
$GlbOut = Join-Path $Zk 'mesh-import'
if (-not $OutFile) { $OutFile = Join-Path $Zk 'batch-manifest.json' }
$Root = '/EnglishZone'

# The mod's cooked meshes have NULL refs exactly where a slot used one of the mod's own (overridden
# or new) MIs. Slot names say MI_sign_font_02_a, but the mod also ships per-sign variants that
# nothing else references; map them by sign (inferred from naming; unverifiable against the
# author's editor project). Any other null slot falls back to the MI named like the slot.
$NullSlotVariant = @{
  'SM_sign_autostation_01_a' = 'MI_sign_font_02_a_busstation'
  'SM_sign_autostation_01_b' = 'MI_sign_font_02_a_busstation'
  'SM_sign_bakery_01'        = 'MI_sign_font_02_a_bakery'
  'SM_sign_birch_01'         = 'MI_sign_font_02_a_birch'
  'SM_sign_books_01'         = 'MI_sign_font_02_a_books'
  'SM_sign_cafe_01_a'        = 'MI_sign_font_02_a_cafe'
  'SM_sign_cafe_01_b'        = 'MI_sign_font_02_a_cafe'
  'SM_sign_cafe_01_c'        = 'MI_sign_font_02_a_cafe'
  'SM_sign_malachite_01'     = 'MI_sign_font_02_a_malachite'
  'SM_sign_firefly_01'       = 'MI_sign_font_02_firefly'
}

$errors = [Collections.Generic.List[string]]::new()
$notes = [Collections.Generic.List[string]]::new()
function Rel([string]$base, [string]$full) { $full.Substring($base.Length + 1) -replace '\\', '/' }
function ReadJson([string]$p) { Get-Content $p -Raw | ConvertFrom-Json }
function Strip([object]$v) { if ($v) { ($v -split '::')[-1] } else { $null } }
function PkgOf([string]$objPath) { ($objPath -split '\.')[0] }

# Known package names (vanilla /Game + mod /EnglishZone), lowercase -> canonical.
$pkgNames = @{}
Get-Content (Join-Path $ModBatch '_package-names.txt') | ForEach-Object { $pkgNames[$_.ToLowerInvariant()] = $_ }
function VanillaExists([string]$pkg) { $pkgNames.ContainsKey($pkg.ToLowerInvariant()) }

# ---------------------------------------------------------------- textures
$vanTexIdx = @{}
Get-ChildItem $VanTex -Recurse -Filter *.json | ForEach-Object {
  $vanTexIdx[((Rel $VanTex $_.FullName) -replace '\.json$', '').ToLowerInvariant()] = $_.FullName
}
$textures = foreach ($png in Get-ChildItem $ModTex -Recurse -Filter *.png) {
  $rel = (Rel $ModTex $png.FullName) -replace '\.png$', ''           # Stalker2/Content/_Stalker_2/...
  $vj = $vanTexIdx[$rel.ToLowerInvariant()]
  if (-not $vj) { $errors.Add("texture has no vanilla JSON: $rel"); continue }
  $p = (ReadJson $vj)[0].Properties
  $gameRel = $rel -replace '^Stalker2/Content/', ''
  [ordered]@{
    png      = $png.FullName
    dest     = $Root + '/' + ((Split-Path $gameRel -Parent) -replace '\\', '/')
    name     = Split-Path $gameRel -Leaf
    settings = [ordered]@{
      SRGB                    = if ($null -ne $p.SRGB) { [bool]$p.SRGB } else { $true }
      VirtualTextureStreaming = if ($null -ne $p.VirtualTextureStreaming) { [bool]$p.VirtualTextureStreaming } else { $false }
      LODGroup                = Strip $p.LODGroup
      CompressionSettings     = if ($p.CompressionSettings) { Strip $p.CompressionSettings } else { 'TC_Default' }
      Filter                  = Strip $p.Filter
    }
  }
}

# ---------------------------------------------------------------- materials
function ParamKey($pv) { $pv.ParameterInfo.Name }
function MiOf([string]$jsonPath) { (ReadJson $jsonPath) | Where-Object Type -eq 'MaterialInstanceConstant' | Select-Object -First 1 }
function ParamSig($p) {
  @(@($p.ScalarParameterValues) + @($p.VectorParameterValues) + @($p.TextureParameterValues) | Where-Object { $_ } |
    ForEach-Object { ParamKey $_ } | Sort-Object -Unique)
}
function ValueSig($p) {
  (@($p.ScalarParameterValues) + @($p.VectorParameterValues) + @($p.TextureParameterValues) | Where-Object { $_ } |
  ForEach-Object { '{0}={1}' -f (ParamKey $_), ($_.ParameterValue | ConvertTo-Json -Compress) } | Sort-Object) -join "`n"
}

$vanMis = @{}
foreach ($f in Get-ChildItem $VanMi -Recurse -Filter 'MI_*.json') {
  $mi = MiOf $f.FullName
  if ($mi) { $vanMis[$f.BaseName] = $mi }
}

$batchMi = @{}   # name -> object path in plugin
$miFiles = Get-ChildItem $ModBatch -Recurse -Filter 'MI_*.json'
foreach ($f in $miFiles) {
  $gameRel = ((Rel $ModBatch $f.FullName) -replace '\.json$', '') -replace '^Stalker2/Content/', ''
  $batchMi[$f.BaseName] = [ordered]@{ rel = $gameRel; file = $f.FullName }
}

$materials = [Collections.Generic.List[object]]::new()
$miTarget = @{}  # MI name -> object path meshes should reference
foreach ($name in $batchMi.Keys) {
  $e = $batchMi[$name]
  $mi = MiOf $e.file
  $p = $mi.Properties
  $gamePkg = '/Game/' + $e.rel
  $pluginPkg = $Root + '/' + $e.rel
  $van = $vanMis[$name]

  # Mod MIs identical to vanilla (same parent + params) add nothing; reference vanilla instead.
  if ($van -and $van.Properties.Parent -eq $p.Parent -and (ValueSig $van.Properties) -eq (ValueSig $p)) {
    $notes.Add("MI identical to vanilla, skipped: $name")
    $miTarget[$name] = "$gamePkg.$name"
    continue
  }

  # Static switches aren't readable from the 5.1 mod cook; take them from the vanilla MI of the same
  # name, else the vanilla sign MI with the same parent whose parameter-name set matches best.
  $tmplName = $name
  if (-not $van) {
    $sig = ParamSig $p
    $best = $null; $bestScore = -1
    foreach ($k in $vanMis.Keys) {
      $vp = $vanMis[$k].Properties
      if ($vp.Parent -ne $p.Parent) { continue }
      $vs = ParamSig $vp
      $inter = @($sig | Where-Object { $_ -in $vs }).Count
      $score = $inter / [Math]::Max(1, ($sig + $vs | Sort-Object -Unique).Count)
      if ($score -gt $bestScore) { $best = $k; $bestScore = $score }
    }
    if (-not $best) { $errors.Add("no vanilla template for MI $name"); continue }
    $tmplName = $best; $van = $vanMis[$best]
    $notes.Add(('MI {0}: static switches from vanilla {1} (param-name match {2:P0})' -f $name, $best, $bestScore))
  }
  $switches = @($van.Properties.StaticParametersRuntime.StaticSwitchParameters | Where-Object { $_ -and $_.bOverride } |
    ForEach-Object { [ordered]@{ name = $_.ParameterInfo.Name; value = [bool]$_.Value } })
  if (@($van.Properties.StaticParametersRuntime.StaticComponentMaskParameters | Where-Object { $_ }).Count) {
    $notes.Add("MI ${name}: template $tmplName has component-mask params (not applied)")
  }

  foreach ($pv in @($p.ScalarParameterValues) + @($p.VectorParameterValues) + @($p.TextureParameterValues) | Where-Object { $_ }) {
    if ((Strip $pv.ParameterInfo.Association) -ne 'GlobalParameter') { $errors.Add("MI ${name}: non-global param $(ParamKey $pv)") }
  }
  $tex = foreach ($t in @($p.TextureParameterValues | Where-Object { $_ })) {
    if ($t.ParameterValue -is [string] -and $t.ParameterValue -like 'UNRESOLVED*') { $errors.Add("MI ${name}: $($t.ParameterValue)"); continue }
    $v = $t.ParameterValue
    if ($null -eq $v) {
      # A null override can't be authored (UE falls back to the parent default), and the mod's cook
      # nulled refs elsewhere too; take the vanilla template's value for the same parameter.
      $tv = @($van.Properties.TextureParameterValues | Where-Object { $_ -and (ParamKey $_) -eq (ParamKey $t) })[0]
      if ($tv -and $tv.ParameterValue) {
        $v = $tv.ParameterValue
        $notes.Add("MI ${name}: texture '$(ParamKey $t)' null in mod -> template $tmplName value $v")
      }
      else { $notes.Add("MI ${name}: texture '$(ParamKey $t)' null in mod, no template value -> parent default"); continue }
    }
    [ordered]@{ name = ParamKey $t; value = $v }
  }
  $bpo = [ordered]@{}
  if ($p.BasePropertyOverrides) {
    foreach ($bp in $p.BasePropertyOverrides.PSObject.Properties) {
      if ($bp.Name -like 'bOverride_*' -and $bp.Value) {
        $prop = $bp.Name.Substring(10)
        $bpo[$prop] = $p.BasePropertyOverrides.$prop
      }
    }
  }
  if ($p.Parent -like 'UNRESOLVED*' -or -not $p.Parent) { $errors.Add("MI ${name}: parent $($p.Parent)"); continue }

  $materials.Add([ordered]@{
      dest      = $Root + '/' + ((Split-Path $e.rel -Parent) -replace '\\', '/')
      name      = $name
      parent    = $p.Parent
      template  = $tmplName
      switches  = $switches
      scalars   = @($p.ScalarParameterValues | Where-Object { $_ } | ForEach-Object { [ordered]@{ name = ParamKey $_; value = [double]$_.ParameterValue } })
      vectors   = @($p.VectorParameterValues | Where-Object { $_ } | ForEach-Object {
          $c = $_.ParameterValue; [ordered]@{ name = ParamKey $_; value = @([double]$c.R, [double]$c.G, [double]$c.B, [double]$c.A) } })
      textures  = @($tex)
      overrides = $bpo
    })
  # Reference via /Game when vanilla has the package (identity override), else the plugin path.
  $miTarget[$name] = if (VanillaExists $gamePkg) { "$gamePkg.$name" } else { "$pluginPkg.$name" }
}

# Parents first (MI chains inside the batch).
$byName = @{}; $materials | ForEach-Object { $byName[$_.name] = $_ }
$ordered = [Collections.Generic.List[object]]::new(); $seen = @{}
function Visit($m) {
  if ($seen[$m.name]) { return }; $seen[$m.name] = $true
  $parentLeaf = ((PkgOf $m.parent) -split '/')[-1]
  if ($byName[$parentLeaf]) { Visit $byName[$parentLeaf] }
  $ordered.Add($m)
}
$materials | ForEach-Object { Visit $_ }
foreach ($m in $ordered) {
  $parentLeaf = ((PkgOf $m.parent) -split '/')[-1]
  if ($byName[$parentLeaf]) { $m.parent = $miTarget[$parentLeaf] }
}

# ---------------------------------------------------------------- meshes
$meshes = foreach ($info in Get-ChildItem $ModBatch -Recurse -Filter '*.meshinfo.json') {
  $base = $info.FullName -replace '\.meshinfo\.json$', ''
  $name = Split-Path $base -Leaf
  $gameRel = (Rel $ModBatch $base) -replace '^Stalker2/Content/', ''
  $mi = ReadJson $info.FullName
  $j = ReadJson "$base.json"
  $sm = $j | Where-Object Type -eq 'StaticMesh' | Select-Object -First 1
  $body = $j | Where-Object Type -eq 'BodySetup' | Select-Object -First 1
  if ($mi.lods -ne 1) { $errors.Add("mesh ${name}: $($mi.lods) LODs (only LOD0 handled)"); continue }

  $slots = for ($i = 0; $i -lt $mi.slots.Count; $i++) {
    $slot = $mi.slots[$i]
    $ref = $sm.Properties.StaticMaterials[$i].MaterialInterface
    if ($ref -is [string] -and $ref -like 'UNRESOLVED*') { $errors.Add("mesh ${name} slot ${i}: $ref"); $ref = $null }
    if (-not $ref) {
      $want = if ($slot -eq 'MI_sign_font_02_a' -and $NullSlotVariant[$name]) { $NullSlotVariant[$name] } else { $slot }
      if ($miTarget[$want]) { $ref = $miTarget[$want] }
      else {
        $hits = @($pkgNames.Values | Where-Object { $_ -like '/Game/*' -and ($_ -split '/')[-1] -eq $want })
        if ($hits.Count -eq 1) { $ref = "$($hits[0]).$want" }
      }
      if ($ref) { $notes.Add("mesh ${name} slot ${i} '$slot': null in mod -> $ref") }
      elseif ($i -in $mi.usedSlots) { $errors.Add("mesh ${name} slot ${i} '$slot': null in mod and no fallback") }
    }
    [ordered]@{ slot = $slot; material = $ref; used = ($i -in $mi.usedSlots) }
  }

  $agg = $body.Properties.AggGeom
  $nConvex = @($agg.ConvexElems | Where-Object { $_ }).Count
  $nBox = @($agg.BoxElems | Where-Object { $_ }).Count
  $nOther = @($agg.SphereElems | Where-Object { $_ }).Count + @($agg.SphylElems | Where-Object { $_ }).Count + @($agg.TaperedCapsuleElems | Where-Object { $_ }).Count
  if ($nOther) { $errors.Add("mesh ${name}: $nOther sphere/capsule collision elems not supported") }
  if ($nConvex -and $nBox) { $errors.Add("mesh ${name}: mixed convex+box collision not supported") }

  # The mod's exact convex hulls (cooked VertexData/IndexData) go into the GLB as UCX_ meshes.
  $hullFile = ''
  if ($nConvex) {
    $hulls = foreach ($c in @($agg.ConvexElems | Where-Object { $_ })) {
      $t = $c.Transform
      if ($t -and ([Math]::Abs($t.Rotation.W) -lt 0.99999)) { $errors.Add("mesh ${name}: rotated convex elem"); continue }
      $tr = if ($t) { $t.Translation } else { [pscustomobject]@{ X = 0; Y = 0; Z = 0 } }
      $sc = if ($t) { $t.Scale3D } else { [pscustomobject]@{ X = 1; Y = 1; Z = 1 } }
      if (-not $c.IndexData -or @($c.IndexData).Count -lt 12) { $errors.Add("mesh ${name}: convex elem without IndexData"); continue }
      [ordered]@{
        verts = @($c.VertexData | ForEach-Object { , @(($_.X * $sc.X + $tr.X), ($_.Y * $sc.Y + $tr.Y), ($_.Z * $sc.Z + $tr.Z)) })
        idx   = @($c.IndexData)
      }
    }
    $hullFile = Join-Path $GlbOut ($gameRel + '.hulls.json')
    New-Item -ItemType Directory -Force -Path (Split-Path $hullFile) | Out-Null
    ConvertTo-Json @($hulls) -Depth 5 -Compress | Set-Content $hullFile -Encoding UTF8
  }
  if ($sm.Properties.bSupportPhysicalMaterialMasks) { $notes.Add("mesh ${name}: bSupportPhysicalMaterialMasks=true in mod (read-only from Python, left default)") }

  $glb = Join-Path $GlbOut ($gameRel + '.glb')
  & "$PSScriptRoot\strip-glb-extra-uvs.ps1" -In "$base.glb" -Out $glb -KeepUVs ([Math]::Max(1, [int]$mi.uvs)) -Hulls $hullFile 6>$null | Out-Null

  $lmIndex = if ($null -ne $sm.Properties.LightMapCoordinateIndex) { [int]$sm.Properties.LightMapCoordinateIndex } else { 0 }
  if ($lmIndex -ge [int]$mi.uvs) { $errors.Add("mesh ${name}: lightmap UV $lmIndex >= uvs $($mi.uvs)") }
  [ordered]@{
    glb       = $glb
    dest      = $Root + '/' + ((Split-Path $gameRel -Parent) -replace '\\', '/')
    name      = $name
    nanite    = [bool]$mi.nanite
    uvs       = [int]$mi.uvs
    lmIndex   = $lmIndex
    lmRes     = if ($null -ne $sm.Properties.LightMapResolution) { [int]$sm.Properties.LightMapResolution } else { 4 }
    slots     = @($slots)
    collision = [ordered]@{
      convex    = $nConvex
      box       = $nBox
      traceFlag = Strip $body.Properties.CollisionTraceFlag
    }
  }
}

$manifest = [ordered]@{ textures = @($textures); materials = @($ordered); meshes = @($meshes) }
New-Item -ItemType Directory -Force -Path (Split-Path $OutFile) | Out-Null
$manifest | ConvertTo-Json -Depth 8 | Set-Content $OutFile -Encoding UTF8
$notes | ForEach-Object { "  NOTE $_" }
$errors | ForEach-Object { "  ERROR $_" }
"manifest: $OutFile (textures=$(@($textures).Count) materials=$($ordered.Count) meshes=$(@($meshes).Count) errors=$($errors.Count))"
if ($errors.Count) { throw "$($errors.Count) manifest error(s)" }
