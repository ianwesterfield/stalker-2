# ZoneLink probe pass: static string scan of the shipping exe (P-1/P-2/P-5/P-6 leads)
# Technique: null-terminated ASCII name scan (same as EGrenadeType discovery)
param(
  [string]$Exe = 'C:\Program Files (x86)\Steam\steamapps\common\S.T.A.L.K.E.R. 2 Heart of Chornobyl\Stalker2\Binaries\Win64\Stalker2-Win64-Shipping.exe',
  [string]$Out = "$PSScriptRoot\..\build\exe-scan.txt"
)
$ErrorActionPreference = 'Stop'
Write-Host "Reading $Exe ..."
$t = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($Exe))

$pats = [ordered]@{
  'XVERBS (CustomConsoleManager console verbs)' = '(?<=\x00)X[A-Z][A-Za-z0-9_]{3,60}(?=\x00)'
  'SPAWN (NPC/agent spawn surface)'             = '(?<=\x00)[A-Za-z0-9_]{0,40}(SpawnNPC|SpawnStalker|SpawnAgent|SpawnHuman|NPCSpawner|SpawnActorByPrototype)[A-Za-z0-9_]{0,40}(?=\x00)'
  'AI (brain/logic suppression surface)'        = '(?<=\x00)[A-Za-z0-9_]{0,30}(StopLogic|BehaviorTree|BrainComponent|AILogic|SetAIEnabled)[A-Za-z0-9_]{0,30}(?=\x00)'
  'ALIFE (director/system names)'               = '(?<=\x00)ALife[A-Za-z0-9_]{1,50}(?=\x00)'
  'CROUCH (stance surface)'                     = '(?<=\x00)[A-Za-z0-9_]{0,30}Crouch[A-Za-z0-9_]{0,30}(?=\x00)'
  'TELEPORT (verbs/functions)'                  = '(?<=\x00)[A-Za-z0-9_]{0,30}Teleport[A-Za-z0-9_]{0,30}(?=\x00)'
  'INVULN (protection flags)'                   = '(?<=\x00)[A-Za-z0-9_]{0,30}(Invulnerab|Immortal|GodMode)[A-Za-z0-9_]{0,30}(?=\x00)'
}

$report = foreach ($k in $pats.Keys) {
  "=== $k ==="
  [regex]::Matches($t, $pats[$k]) | ForEach-Object Value | Sort-Object -Unique
  ''
}
$report | Set-Content $Out -Encoding UTF8
Write-Host "Wrote $Out"
$report
