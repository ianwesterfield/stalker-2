# Strips padded TEXCOORD_2..7 attributes CUE4Parse writes into exported GLBs (UE meshes carry
# only the real channels; extra zero/dupe UV sets would import as 8 UV channels in ZoneKit).
# Accessors/bufferViews stay in the binary (harmless dead weight); only attribute refs are removed.
# -Hulls <json>: [{verts:[[x,y,z],..] (UE cm), idx:[..]}] appended as UCX_<mesh>_NN collision meshes.
param(
  [Parameter(Mandatory)][string]$In,
  [Parameter(Mandatory)][string]$Out,
  [int]$KeepUVs = 2,
  [string]$Hulls = ''
)
$ErrorActionPreference = 'Stop'

$bytes = [IO.File]::ReadAllBytes($In)
if ([Text.Encoding]::ASCII.GetString($bytes, 0, 4) -ne 'glTF') { throw "$In is not a GLB" }
$jsonLen = [BitConverter]::ToInt32($bytes, 12)
if ([Text.Encoding]::ASCII.GetString($bytes, 16, 4) -ne 'JSON') { throw 'first chunk is not JSON' }
$json = [Text.Encoding]::UTF8.GetString($bytes, 20, $jsonLen) | ConvertFrom-Json

$removed = 0
foreach ($mesh in $json.meshes) {
  foreach ($prim in $mesh.primitives) {
    foreach ($attr in @($prim.attributes.PSObject.Properties.Name)) {
      if ($attr -match '^TEXCOORD_(\d+)$' -and [int]$Matches[1] -ge $KeepUVs) {
        $prim.attributes.PSObject.Properties.Remove($attr)
        $removed++
      }
    }
  }
}

$binStart = 20 + $jsonLen
$binLen = [BitConverter]::ToInt32($bytes, $binStart)
if ([Text.Encoding]::ASCII.GetString($bytes, $binStart + 4, 3) -ne 'BIN') { throw 'second chunk is not BIN' }
$extra = New-Object IO.MemoryStream
$ew = New-Object IO.BinaryWriter($extra)
$nHulls = 0
if ($Hulls) {
  if (@($json.meshes).Count -ne 1 -or @($json.nodes).Count -ne 1) { throw 'expected a single mesh/node GLB' }
  $meshName = $json.meshes[0].name
  # Name the render node like its mesh so UCX_<name>_NN pairs with it.
  $json.nodes[0] | Add-Member -NotePropertyName name -NotePropertyValue $meshName -Force
  $accessors = [Collections.Generic.List[object]]@($json.accessors)
  $views = [Collections.Generic.List[object]]@($json.bufferViews)
  $meshes = [Collections.Generic.List[object]]@($json.meshes)
  $nodes = [Collections.Generic.List[object]]@($json.nodes)
  $sceneNodes = [Collections.Generic.List[object]]@($json.scenes[0].nodes)
  foreach ($h in (Get-Content $Hulls -Raw | ConvertFrom-Json)) {
    $verts = @($h.verts); $idx = @($h.idx)
    if ($verts.Count -lt 4 -or $idx.Count -lt 12 -or $idx.Count % 3) { throw "hull $nHulls is degenerate ($($verts.Count) verts, $($idx.Count) idx)" }
    # UE (X,Y,Z) cm -> glTF (X,Z,Y) m, the same mapping CUE4Parse applied to the render mesh.
    $min = @([double]::MaxValue) * 3; $max = @([double]::MinValue) * 3
    $posOff = $binLen + $extra.Length
    foreach ($v in $verts) {
      $p = @([float]($v[0] / 100), [float]($v[2] / 100), [float]($v[1] / 100))
      for ($k = 0; $k -lt 3; $k++) { $ew.Write($p[$k]); $min[$k] = [Math]::Min($min[$k], $p[$k]); $max[$k] = [Math]::Max($max[$k], $p[$k]) }
    }
    $views.Add([ordered]@{ buffer = 0; byteOffset = $posOff; byteLength = 12 * $verts.Count; target = 34962 })
    $accessors.Add([ordered]@{ bufferView = $views.Count - 1; componentType = 5126; count = $verts.Count; type = 'VEC3'; min = $min; max = $max })
    $idxOff = $binLen + $extra.Length
    foreach ($i in $idx) { if ($i -lt 0 -or $i -ge $verts.Count) { throw "hull $nHulls index $i out of range" }; $ew.Write([uint32]$i) }
    $views.Add([ordered]@{ buffer = 0; byteOffset = $idxOff; byteLength = 4 * $idx.Count; target = 34963 })
    $accessors.Add([ordered]@{ bufferView = $views.Count - 1; componentType = 5125; count = $idx.Count; type = 'SCALAR' })
    $ucx = 'UCX_{0}_{1:00}' -f $meshName, $nHulls
    $meshes.Add([ordered]@{ name = $ucx; primitives = @([ordered]@{ attributes = [ordered]@{ POSITION = $accessors.Count - 2 }; indices = $accessors.Count - 1; mode = 4 }) })
    $nodes.Add([ordered]@{ name = $ucx; mesh = $meshes.Count - 1 })
    $sceneNodes.Add($nodes.Count - 1)
    $nHulls++
  }
  $json.accessors = $accessors; $json.bufferViews = $views; $json.meshes = $meshes; $json.nodes = $nodes
  $json.scenes[0].nodes = $sceneNodes
}
$ew.Flush()
$newBinLen = $binLen + $extra.Length
$json.buffers[0].byteLength = $newBinLen

$newJson = [Text.Encoding]::UTF8.GetBytes(($json | ConvertTo-Json -Depth 50 -Compress))
$pad = (4 - ($newJson.Length % 4)) % 4
$newJsonLen = $newJson.Length + $pad

$ms = New-Object IO.MemoryStream
$w = New-Object IO.BinaryWriter($ms)
$w.Write([Text.Encoding]::ASCII.GetBytes('glTF')); $w.Write([int]2)
$w.Write([int](12 + 8 + $newJsonLen + 8 + $newBinLen))
$w.Write([int]$newJsonLen); $w.Write([Text.Encoding]::ASCII.GetBytes('JSON'))
$w.Write($newJson); for ($i = 0; $i -lt $pad; $i++) { $w.Write([byte]0x20) }
$w.Write([int]$newBinLen); $w.Write($bytes, $binStart + 4, 4)
$w.Write($bytes, $binStart + 8, $binLen)
$eb = $extra.ToArray(); $w.Write($eb, 0, $eb.Length)
$w.Flush()
New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null
[IO.File]::WriteAllBytes($Out, $ms.ToArray())
Write-Host "stripped $removed UV attrs, added $nHulls UCX hulls: $In -> $Out ($((Get-Item $Out).Length) B)"
