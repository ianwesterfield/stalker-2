# stalker-2 — Zone mods

Two projects live here:

| Project              | What                                                                                  | Status                        |
| -------------------- | ------------------------------------------------------------------------------------- | ----------------------------- |
| **Molotov Cocktail** | Throwable molotov: impact detonation, ground fire, burn DoT, hand-authored bottle    | Playable, iterating on polish |
| **ZoneLink**         | Co-op presence experiment — see each other as stalker puppets ([details](#zonelink--co-op-presence-experimental)) | Tier A ghost verified         |

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

One Blender script — [asset-pipeline/build_molotov.py](asset-pipeline/build_molotov.py) — builds
the whole asset headlessly: cossack-vodka bottle on the RGD-5 grenade skeleton, cloth plug with a
hanging rag tail, and skinned flame cards (orange cap at the plug, faint blue alcohol burn down
the wick). The `editor_*.py` scripts run inside Zone Kit's Python console to reimport, assign
material slots, and build/tune the materials.

Techniques worth stealing:

- **Scale laundering** — GSC's importer scales geometry by the FBX unit header but reads bone
  numerics raw; the recipe bakes ×100 into mesh+armature data under a cm header so the cooked
  bind pose is bit-identical to vanilla grenades. The editor preview lies; only cooked output counts.
- **FP seating** — first-person weapons need GSC's foreground-FOV WPO correction
  (`MF_ForegroundWithShadowSwitch` fed from `MPC_FOV`'s `TanFOV`) or the mesh floats off the hand.
  The additive flame uses the core `MF_Foreground_FOVCorrection` only (the full switch streaks).
- **Flame = skinned geometry + animated material.** Cards hijack custom normals as a flame axis;
  the material re-points tongues world-up (clamped ±0.75/axis so a tumbling thrown bottle doesn't
  fling the fire off the mesh), sways, droops, and flutters in sync with the rag's cloth WPO.
- **Vertex colors as data bus** — R = droop weight, G = solidify shell sign, B = bend height,
  A = orange↔blue tint lerp. Note: `VertexColor`'s RGB output is float3 — take alpha from the
  dedicated `A` pin or the cook's shader translation fails (the editor won't warn you).

## Runtime behavior (UE4SS)

[MolotovFire](ue4ss-mods/MolotovFire/Scripts/main.lua): impact detonation via the grenade's hit
event (vanilla `BP_grenade` is timer-only), ground fire patches spawned from `BP_BonFire` with
staggered lifetimes, soft-landing fuse fallback, and debug spawn keybinds. The FP mesh-swap and
Niagara-flame paths in there are retired fallbacks — the baked asset made them obsolete.

## Pipeline

```
# game-data pak
scripts/extract-gamedata.ps1   # unpack pakchunk0 cfg.bin -> extracted/, decode via tools/bin2cfg.py
scripts/build-locres.ps1       # vanilla Game.locres + mod-source CSV rows -> mod/ (pylocres)
scripts/pack-mod.ps1           # mod/ -> build/MolotovCocktail_P.pak (repak V11, mount ../../../)
scripts/deploy-mod.ps1         # copy into <game>/Stalker2/Content/Paks/~mods  (-Remove uninstalls)
scripts/deploy-ue4ss.ps1       # sync ue4ss-mods/ -> <game>/Stalker2/Binaries/Win64/ue4ss/Mods

# bottle asset (Zone Kit required)
blender -b -P asset-pipeline/build_molotov.py        # headless: mesh + FBX pair + vertex data
# in Zone Kit:  py editor_reimport_sk.py  /  py editor_fix_slots2.py  (+ material scripts as needed)
# cook: RunUAT GSCCookModNewContent -CustomConfig=ModCookNewContent (editor closed)
# deploy: staged pak/ucas/utoc -> <game>/Stalker2/Mods/MolotovBottle/Content/Paks/Windows
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
2. Buy from the Zalissya bartender (restocks on timer; sleep/wait if absent).
3. Equip grenades and **cycle the grenade slot** — the molotov is its own grenade type.
4. In hand: bottle with cloth plug, drooping rag tail, orange flame cap + blue wick burn,
   all seated on the hand and following every animation.
5. Throw: flame stays on the bottle through the tumble; impact fireball + ground fire patches;
   victims tick burn damage.
6. Drop it: static bottle twin in the world.

## Known limitations / next ideas

- Inventory icon is still the vanilla Dvupalov vodka icon (`IIT_DvupalovVodka`) — custom icon pending.
- Thrown-bottle flame points world-up (candle behavior) rather than trailing the flight path.
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

| Tier             | Needs                            | Validates                                                      | Status       |
| ---------------- | -------------------------------- | --------------------------------------------------------------- | ------------ |
| **A — Ghost**    | 1 game copy, pure Lua            | Puppet spawn/AI suppression/anim quality — all top game risks  | **Verified** |
| **B — Sim peer** | 1 game copy + `zonelink-sim` exe | Wire protocol, jitter/loss, interp buffer, handshake            | Next         |
| **C — LAN**      | 2 machines, 2 licenses           | End-to-end bidirectional                                        | Later        |

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
