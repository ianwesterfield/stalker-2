# stalker-2 — Zone mods

Two projects live here:

| Project              | What                                                                                                              | Status                        |
| -------------------- | ----------------------------------------------------------------------------------------------------------------- | ----------------------------- |
| **Molotov Cocktail** | Throwable molotov: impact detonation, ground fire, burn DoT, hand-authored bottle                                 | Playable, iterating on polish |
| **ZoneLink**         | Co-op presence experiment — see each other as stalker puppets ([details](#zonelink--co-op-presence-experimental)) | Tier A ghost verified         |
| **ZoneXM**           | Conversation awareness for your own music — ducks Windows audio when the Zone demands attention ([details](#zonexm--conversation-awareness-for-external-music)) | Working: gunfire, mutants, dialogue |

## Molotov Cocktail

Adds the Zone's most conspicuously missing weapon to S.T.A.L.K.E.R. 2: Heart of Chornobyl:
a throwable **Molotov Cocktail** (`GrenadeMolotov`) with impact detonation, ground fire,
burn-over-time, a hand-authored bottle with a burning rag — and bartender stock, because
there was already this much vodka lying around.

## Architecture: three cooperating layers

| Layer             | Lives in                                           | Ships as                                                    | Does                                                                |
| ----------------- | -------------------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------- |
| Game-data overlay | [mod/](mod/)                                       | `MolotovCocktail_P.pak` → `Content/Paks/~mods`              | Item/explosion/trade/mesh prototypes, localization                  |
| Custom asset      | [asset-pipeline/](asset-pipeline/)                 | `MolotovBottle` Zone Kit plugin paks → `Mods/MolotovBottle` | Skeletal bottle + rag + flame (in-hand), static twin (world/thrown) |
| Runtime behavior  | [ue4ss-mods/MolotovFire/](ue4ss-mods/MolotovFire/) | UE4SS Lua → `Binaries/Win64/ue4ss/Mods`                     | Impact detonation, ground fire patches, fuse fallback               |

## Game-data overlay (cfg pak)

| Piece                 | File                                                                                                          | Technique                                                                                        |
| --------------------- | ------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Throwable item        | [GrenadeMolotov.cfg](mod/Stalker2/Content/GameLite/GameData/ItemPrototypes/GrenadeMolotov.cfg)                | `refkey=GrenadeRGD5` inheritance; claims the exe's native `EGrenadeType::Molotov` slot           |
| Fire explosion        | [ExplosionMolotov.cfg](mod/Stalker2/Content/GameLite/GameData/ExplosionPrototypes/ExplosionMolotov.cfg)       | `refkey=Empty`; `NS_Barrel_Explo` VFX, gas-cylinder SFX, `EDamageSource::Fire`                   |
| Burning victims       | same file                                                                                                     | `ConcussionEffects`/`NPCConcussionEffects` → `FireBurning` (burn damage over time)               |
| Bottle meshes         | [MolotovMeshes.cfg](mod/Stalker2/Content/GameLite/GameData/MeshPrototypes/MolotovMeshes.cfg)                  | Points at our own `/MolotovBottle` plugin: `SK_MolotovBottle` (hand), `SM_MolotovBottle` (world) |
| Buyable at bartenders | [MolotovTradeStock.cfg](mod/Stalker2/Content/GameLite/GameData/ItemGeneratorPrototypes/MolotovTradeStock.cfg) | `{bpatch}` named-node append on `BartenderUniversal_TradeItemGenerator` (mod-friendly)           |
| Name + description    | [mod-source/localization.en.csv](mod-source/localization.en.csv)                                              | Full `Game.locres` override rebuilt from vanilla + added keys (pylocres)                         |

## Custom bottle asset (the fun part)

One command — [asset-pipeline/pipeline.ps1](asset-pipeline/pipeline.ps1) — builds the whole asset
headlessly: Blender mesh build → FBX sanity checks → preview renders → Zone Kit headless editor
import (materials, slots, physics) → cook → deploy. The asset is a cossack-vodka bottle on the
RGD-5 grenade skeleton with a cloth plug and a physics-simulated rag tail on its own bone
(`jnt_fuse`); the burning rag is the game's own `NS_Character_Fire` Niagara system attached at
runtime. The old skinned flame cards ship invisible (`OpacityBoost 0`) but keep their
geometry/slots so the flight-look and physics code stay stable.

Techniques worth stealing:

- **Scale laundering** — GSC's importer scales geometry by the FBX unit header but reads bone
  numerics raw; the recipe bakes ×100 into mesh+armature data under a cm header so the cooked
  bind pose is bit-identical to vanilla grenades. The editor preview lies; only cooked output counts.
- **FP seating** — first-person weapons need GSC's foreground-FOV WPO correction
  (`MF_ForegroundWithShadowSwitch` fed from `MPC_FOV`'s `TanFOV`) or the mesh floats off the hand.
  The additive flame uses the core `MF_Foreground_FOVCorrection` only (the full switch streaks).
- **Flame = the game's own Niagara fire.** `NS_Character_Fire` attached to the rag bone at runtime
  beats every hand-built flame card we tried. The card materials remain as invisible stubs — and
  taught the big lesson: Zone Kit's Python `MaterialProperty` enum is stripped (no WPO pin, no
  `MP_MATERIAL_ATTRIBUTES`), and wiring a graph to `MP_FRONT_MATERIAL` (the Substrate pin)
  "compiles clean" into an **empty shader** — emissive black, opacity 1.0, every param compiled
  out. Non-Substrate game ⇒ classic pins only (`MP_EMISSIVE_COLOR`, `MP_OPACITY`), and assert
  every `connect_material_property`.
- **Vertex colors as data bus** — R = droop weight, G = solidify shell sign, B = bend height,
  A = orange↔blue tint lerp. Note: `VertexColor`'s RGB output is float3 — take alpha from the
  dedicated `A` pin or the cook's shader translation fails (the editor won't warn you).

## Runtime behavior (UE4SS)

[MolotovFire](ue4ss-mods/MolotovFire/Scripts/main.lua): impact detonation via the grenade's hit
event (vanilla `BP_grenade` is timer-only), ground fire patches spawned from `BP_BonFire` with
staggered lifetimes, soft-landing fuse fallback, the burning-rag fire itself
(`NS_Character_Fire` attached to `jnt_fuse`, doused on throw), the rag physics kick
(pooled weapon meshes never create physics state on their own), flight-look material pinning,
and two field rules: **menu crafting** (right-click anything in the backpack while carrying
vodka and a bandage and a **Make Molotov** entry joins the context menu; one click spends one
of each and wraps a bottle — the old Bottle Prep Kit item is retired but stays defined for
save compatibility) and a **hold singe** — while the
rag burns in hand you slowly lose HP (~0.33 HP/s, floored so it can't kill you), applied with
`Obj:ForceSetHP` so it lands silently. Every damage-typed route drags its own feedback along:
Burn triggers the engine's player-on-fire reaction (roaring audio that buries the mix, red
screen edges) and Strike a pain grunt on every tick — neither reads right for merely holding a
lit bottle. The fire in your hand is the warning.

The craft itself is a **quest-node chain** ([MolotovCraftNodes.cfg](mod/Stalker2/Content/GameLite/GameData/QuestNodePrototypes/MolotovCraftNodes.cfg)):
`ItemRemove` is the only inventory-removal verb the game exposes — no native API exists — so
the menu click fires the chain head with `XStartQuestNodeBySID`, and the quest does the
vodka/bandage/molotov transaction atomically. The menu row itself is a UE4SS injection: the
native `W_RightClickMenu` is built per-open, a `MenuItemWidgetClass` row is spawned and added
to its `VerticalBox`, and — because the game binds row delegates natively only for its own
rows — the click is detected as `row:IsHovered()` + an LMB keybind rather than a button event.

Diagnosis kit (UE4SS console `dofile`, bottle equipped):
[droop.lua](ue4ss-mods/MolotovFire/Scripts/droop.lua) `PARAM="X" VAL=n` scalar params on the
rag/flame MIDs · [hide.lua](ue4ss-mods/MolotovFire/Scripts/hide.lua) `SLOT=n SHOW=0/1` geometry
kill switch · [emit.lua](ue4ss-mods/MolotovFire/Scripts/emit.lua) Niagara emitter dump/toggle ·
[matprobe.lua](ue4ss-mods/MolotovFire/Scripts/matprobe.lua) cooked-material fingerprint.

## Pipeline

```
# game-data pak
scripts/extract-gamedata.ps1   # unpack pakchunk0 cfg.bin -> extracted/, decode via tools/bin2cfg.py
scripts/build-locres.ps1       # vanilla Game.locres + mod-source CSV rows -> mod/ (pylocres)
scripts/pack-mod.ps1           # mod/ -> build/MolotovCocktail_P.pak (repak V11, mount ../../../)
scripts/deploy-mod.ps1         # copy into <game>/Stalker2/Content/Paks/~mods  (-Remove uninstalls)
scripts/deploy-ue4ss.ps1       # sync ue4ss-mods/ -> <game>/Stalker2/Binaries/Win64/ue4ss/Mods
#   also re-derives the GUObjectArray AOB from the installed exe (tools/find_guobjectarray.py):
#   a game patch shifts register allocation, the shipped pattern misses, and UE4SS then aborts
#   outright -- every Lua mod goes dark at once. -SkipSignatures opts out.

# bottle asset (Zone Kit required; editor and game closed)
asset-pipeline/pipeline.ps1    # Blender -> checks -> previews -> headless editor -> cook -> deploy
#   -SkipBlender -SkipPreviews -SkipEditor -SkipCook -SkipDeploy for partial runs
#   gates on log sentinels (HEADLESS_ALL_DONE, *_MAT_DONE, ...) because UE exit codes lie
```

Prereqs: repak (`C:\Tools\repak`), Python 3.11 + `pylocres`, Blender 5.x, STALKER 2 Zone Kit
(Epic Games Store), UE4SS. Paths are centralized in [scripts/paths.ps1](scripts/paths.ps1).
Grep every cook log for `Failed to translate` before deploying — a material that fails shader
translation cooks "successfully" and ships as the checkerboard.

## Key facts learned (2.0.x game data)

- Gameplay cfgs ship **binarized** (`.cfg.bin`, format v2) inside `pakchunk0-Windows.pak`
  (unencrypted, V11, Oodle). [tools/bin2cfg.py](tools/bin2cfg.py) (by joric/sdwvit/thexii) decodes them.
- The engine also reads **loose plain-text `.cfg`** files and mod paks as an overlay; new files
  under `GameData/` are picked up, structs inherit cross-file via `{refurl=..;refkey=SID}`.
- `{bpatch}` roots merge into an existing prototype by struct name instead of replacing the file —
  but only at root level; nested `{bpatch}` does nothing.
- All vanilla locres entries have `SourceStringHash = 0`; new keys must match.
  UnrealLocres `import` cannot add keys — hence pylocres.
- The grenade quick-slot cycles by **`EGrenadeType` enum**, not item SID. The shipping exe
  already defines `EGrenadeType::Molotov` (and `::Dynamite` — hello, cut content), so the mod
  claims the native type and gets its own entry in the grenade cycle.
- Raw-spawning anomaly BPs (`BP_ClassicFireAnomaly_C`) is a native AV that `pcall` cannot catch;
  `BP_BonFire` is self-contained and safe.

## In-game test checklist

1. Launch (cfg pak in `~mods` and `MolotovBottle` plugin paks load automatically; UE4SS mods via `enabled.txt`).
2. Buy from the Zalissya bartender (restocks on timer; sleep/wait if absent) — or open the
   backpack and **use the Bottle Prep Kit**: one vodka and one bandage spent, molotov in its place.
3. Equip grenades and **cycle the grenade slot** — the molotov is its own grenade type.
4. In hand: bottle with cloth plug, physics rag tail swinging with movement, Niagara fire +
   smoke riding the rag, all seated on the hand and following every animation — and your HP
   slowly ticking down (hold singe) until you throw or holster.
5. Throw: fire douses as the bottle leaves the hand; impact fireball + ground fire patches;
   victims tick burn damage.
6. Drop it: static bottle twin in the world.

## Known limitations / next ideas

- Inventory icon is the vanilla Cossacks vodka art; the Bottle Prep Kit uses a rendered
  composite icon (`T_MolotovKitIcon`, built by [build_icon.py](asset-pipeline/build_icon.py)).
- In-flight bottle shows no flame (card flames retired; candidate: attach the Niagara fire to
  the thrown grenade actor).
- The `MolotovBottle` plugin paks must be cooked locally with Zone Kit; they're not committed.
- English locres only; add `localization.<lang>.csv` and pass `-Languages` to extend.
- After a game patch: re-run `build-locres.ps1` + `pack-mod.ps1` + `deploy-mod.ps1`
  (locres is a full-file override and must be rebuilt against the new vanilla).

---

## ZoneLink — co-op presence (experimental)

First rung of a co-op MVP ladder: players each run their own single-player session and see
each other as `BP_AI_Human_C` stalker puppets driven from a ~15 Hz state stream — position,
locomotion animation, stance, spawn-time weapon. No combat sync, no world sync (yet).

Full design: [docs/coop/01-presence.md](docs/coop/01-presence.md) ·
Code: [ue4ss-mods/ZoneLink/Scripts/main.lua](ue4ss-mods/ZoneLink/Scripts/main.lua)

The core trick that makes it testable with **one game copy**: the puppet driver consumes an
abstract StateFeed, which can be filled by a socket, a trace file, or your own movement on a
delay. That yields a three-tier test ladder:

| Tier             | Needs                            | Validates                                                     | Status       |
| ---------------- | -------------------------------- | ------------------------------------------------------------- | ------------ |
| **A — Ghost**    | 1 game copy, pure Lua            | Puppet spawn/AI suppression/anim quality — all top game risks | **Verified** |
| **B — Sim peer** | 1 game copy + `zonelink-sim` exe | Wire protocol, jitter/loss, interp buffer, handshake          | Next         |
| **C — LAN**      | 2 machines, 2 licenses           | End-to-end bidirectional                                      | Later        |

Current Tier-A build keys: **F2** record own movement to trace · **F3** spawn + protect puppet ·
**F4** cycle drive OFF → ESCORT (10 m stations) → GHOST (trace replay) · **F9** object dump.

Hard-won findings baked into the build:

- Reliable tick source is the HUD stat-panel widget's `Tick` — `WeatherController:ReceiveTick`
  exists in reflection but never fires.
- Puppet = `GeneralNPC_Neutral_Stormtrooper` (generic neutral A-Life stalker), identified via
  `CppMediator:GetGUID`.
- Ragdoll gate: hold the drive loop while the mesh simulates physics, and fetch anim instances
  fresh (stale montage refs AV when an explosion lands near the puppet).

ZoneLink will likely graduate to its own repo (`stalker2-zonelink`) once Tier B's sim peer
lands; for now it rides along here.

## Known limitations / next ideas (ZoneLink)

- Loopback/trace feeds only — no sockets yet (`zonelink-sim` is the next milestone).
- Escort stations are placeholder motion; real peer data replaces them in Tier B.
- Damage/death, weapon-swap mirroring, A-Life/weather sync all deferred (see the phase table
  in the design doc).

---

## ZoneXM — conversation awareness for external music

*"Many stalkers were hurt in the making of this modification... of course."*

Play your own music over the game; ZoneXM ducks it — every app except the game, each to a
fraction of its own volume — whenever the Zone needs your ears, and fades it back when the
dust settles. Two cooperating halves joined by a flag file:

| Half     | Lives in                                                               | Does                                                                                                        |
| -------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Sensor   | [ue4ss-mods/ZoneXM/](ue4ss-mods/ZoneXM/) (UE4SS Lua)                   | Detects danger/speech in-game, keeps `%LOCALAPPDATA%\Stalker2\Saved\ZoneXM\alert.flag` alive while it lasts |
| Watchdog | [tools/zonexm-watchdog.ps1](tools/zonexm-watchdog.ps1) (PowerShell 7+) | Polls the flag, ducks per-app CoreAudio session volumes, tray icon shows armed/ducked, restores exactly     |

Sensor tiers (each refreshes a timestamp; the flag stays hot while any window is open):

| Tier     | Trigger                             | Mechanism                                                | Tail |
| -------- | ----------------------------------- | --------------------------------------------------------- | ---- |
| Gunfire  | any shot near Skif (player or NPC)  | `ItemAppearanceComponent:OnShotSoundStart` hook (proven)  | 6s   |
| Beasts   | live mutant within 35 m             | `FindAllOf("AnimInstanceMutant")` radar sweep, `IsAlive`-filtered | 3s, self-refreshing |
| Speech   | anyone talking (dialog, bark, cutscene) | `SubtitleView` visibility poll — needs subtitles ON    | 2.5s |
| Melee    | mutant lunge                        | `Obj:OnMeleeAttack_BP` battery (candidates under test)    | 3s   |

The watchdog fades instead of stepping: smoothstep dip over 350 ms (combat is urgent),
rise over 1.5 s (recovery is musical). Per-session baselines mean every app returns to
exactly its pre-duck volume — including apps that started mid-fight. Single-instance
mutex; stale flag (> 8 s) = dead game = restore.

```powershell
.\scripts\deploy-ue4ss.ps1 -Mods ZoneXM -SkipSignatures   # sensor → game
.\tools\zonexm-watchdog.ps1                               # duck ALL except the game (default)
.\tools\zonexm-watchdog.ps1 -ProcessName Pandora,msedge   # narrow mode
.\tools\zonexm-watchdog.ps1 -DuckLevel 0.15 -DuckFadeMs 350 -RestoreFadeMs 1500
```

Hard-won findings baked into the build:

- **Almost nothing crosses the script VM.** Of 9 damage/shot UFunction candidates
  (`ReceiveDamage`, `OnDamageReceived_BP`, `OnShot_BP`, `OnShootingStarted_BP`,
  `OnFirePressed[_BP]`, `Shoot`, two voice notifies), exactly **one** dispatches where Lua
  can see it: `OnShotSoundStart`. A `_BP` suffix is no guarantee — demand proof-of-life
  logging inside the callback before trusting any hook.
- **Never hook per-contact physics events on character base classes** (`Obj:OnHit` pegged
  the game thread and froze input). Shot/attack notifies are rate-bounded; contacts aren't.
- **No `os.execute` at mod load** — the console flash steals the game's mouse capture
  (stuck until a menu toggle). The watchdog owns directory creation.
- **Combat state has no reflected property.** The compass threat indicator, agent aggro,
  and Wwise combat music are all native-only; proximity + sound events are the signals
  that actually exist.
- **Raw-vtable CoreAudio.** `ComImport` interface casts fail as managed `InvalidCast` on
  modern PowerShell before QI is ever attempted; delegate-per-vtable-slot works everywhere.
- The watchdog is game-agnostic: anything that writes/heartbeats the flag file can drive it.

## Known limitations / next ideas (ZoneXM)

- Speech tier requires subtitles enabled in game settings (it watches `SubtitleView`).
- Tray glyph is the molotov bottle; a proper PDA icon awaits extraction.
- Anomalies, emissions, and gravity whooshes don't duck yet — no sound-event hook found
  for them so far; the beast radar covers the creatures that ride them.
- Melee battery (`OnMeleeAttack_BP`, `MakeAttack_BP`) still awaiting a confirmed live fire.
