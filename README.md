# stalker-2 — Zone mods

Projects here:

| Project               | What                                                                                                                                                            | Status                                           |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| **Molotov Cocktail**  | Throwable molotov: impact detonation, ground fire, burn DoT, hand-authored bottle                                                                               | Playable, iterating on polish                    |
| **ZoneLink**          | Co-op presence experiment — see each other as stalker puppets ([details](#zonelink--co-op-presence-experimental))                                               | Tier A ghost verified                            |
| **ZoneXM**            | Conversation awareness for your own music — ducks Windows audio when the Zone demands attention ([details](#zonexm--conversation-awareness-for-external-music)) | Working: gunfire, mutants, dialogue              |
| **QuestStash**        | Quest-item transfers through personal stash context menus ([details](#queststash--quest-items-in-personal-stashes))                                             | Personal-stash deposit/retrieval verified by Ian |
| **English Zone port** | Workshop English signage mod ported from UE 5.1 to 2.1.0 / UE 5.5 ([details](mods/english-zone/README.md))                                                      | 471 assets, in-game verified                     |
| **ZoneAtlas**         | Cycle PDA map styles in-game (vanilla satellite, Topographic, Topographic Dark...) with a hotkey ([details](#zoneatlas--switch-pda-map-styles-in-game))         | Working in-game; auto-sync at launch, MCM cycle  |

## Layout

```
mods/<mod>/       one folder per mod: scripts/, src/, ue4ss/, pak/, docs/ as needed
shared/scripts/   paths.ps1 (central config), deploy-ue4ss.ps1, extract-gamedata.ps1
shared/tools/     bin2cfg, find_guobjectarray, Lua test harness
shared/docs/      cross-mod modding notes
```

Source code, pipeline logic, docs, and the companion's supplied artwork/licensed fonts are committed.
Game data (`extracted/`), vanilla reference
assets and all build output (`build/`, `bin/`, `obj/`, `out/`) are
regenerated locally. Run scripts from the repo root.

## ZoneAtlas — switch PDA map styles in-game

Press **F6** on the PDA map, or click the **Map style** prompt in the map's bottom hint bar, to
cycle styles; **Shift+F6** goes back. A short toast names the active map, and the choice is
remembered between sessions. No mod is toggled at runtime.
Instead, the builder copies every installed map mod's texture to its own path inside one local
container. The Lua runtime then swaps the `MapTexture` parameter on the world-map scene's
dynamic material. Only `Texture2D` packages named `T_DLCWorldMap_UDIM`/`T_WorldMap_UDIM` are
ever taken, so non-map mods cannot enter the cycle. True vanilla is bundled from the game files.
Your map mods can stay installed: whichever wins becomes the game's default, and ZoneAtlas
overrides it.
ZoneAtlas keeps its modules inside its own `Scripts` folder: `catalog.lua`,
`texture_catalog.lua`, `world_map.lua`, `mcm.lua`, `toast.lua`, `hint_bar.lua`, and the
mod-local `unreal.lua` helpers. These are ordinary Lua modules with one state per mod:
`catalog.lua` owns configuration and selection, while the entrypoint coordinates polling
and input. There are no factories or cross-mod runtime dependencies. UObject work stays
on the game thread, and texture compatibility and stale-object checks remain in place.

**Setup (once):** run `.\mods\zoneatlas\scripts\deploy-zoneatlas.ps1` (game closed), then set
Steam → S.T.A.L.K.E.R. 2 → Properties → **Launch options** to:

```text
"C:\Code\westerfield.cloud\Gaming\stalker-2\mods\zoneatlas\scripts\zoneatlas-launch.cmd" %command%
```

From then on, every launch picks up whatever map mods are installed (Vortex staging, `Paks\~mods`,
`Stalker2\Mods`, Steam Workshop), from any source. Unchanged mods add about a second. An added,
removed or updated map mod triggers a rebuild of about 15 s, then the game starts and the launcher
window closes without waiting for the game to exit. A mod that
can't be converted is skipped with a warning; for example, Alternative World Map is packed for a
pre-2.0 game version. The sync never blocks the launch; its log is `build\zoneatlas\sync.log`.
To sync by hand instead, run `.\mods\zoneatlas\scripts\sync-zoneatlas.ps1`.

**Choosing the cycle in-game:** with [Mod Configuration Menu 2.0](https://www.nexusmods.com/stalker2heartofchornobyl/mods/2225)
installed, load a save and open MCM (F9) → **ZoneAtlas**. Every bundled map is a checkbox,
and new maps arrive ticked. Unticked maps are skipped by F6. MCM stores the ticks in the save
game, so they apply per save. If nothing is ticked, or MCM is missing, every bundled map cycles.
MCM has no way to remove a setting, so a map mod you uninstall leaves a dead checkbox in that
save. The checkbox does nothing.

No build configuration file is needed: vanilla is always included as `Vanilla`, and installed
map names are derived from their container filenames without hard-coded name overrides.
The former `Satellite` and `Topographic (Dark)` labels become `Vanilla` and `Topographic Map Dark`;
MCM treats renamed entries as new checkboxes, and a saved selection with an old name resets
to the first map. In-game settings live in `ue4ss\ZoneAtlas\Scripts\config.lua`:
the key, the open-map gate, the toast duration, the hint-bar prompt (`ShowHint`, `HintLabel`) and
MCM use (`UseMCM`). retoc writes the container uncompressed, so a Topographic-size map costs about
3.2 GB of disk; vanilla costs about 200 MB. The build output is hardlinked into `~mods`.

Known limits: the "map is open" gate is heuristic, so set `OnlyWhenMapOpen = false` if F6 seems
dead. A variant whose virtual-texture setting differs from the PDA's is skipped, not applied.
If the hint-bar prompt misbehaves, set `ShowHint = false`; if MCM causes trouble, `UseMCM = false`.
Keep F6 and F9 free in other UE4SS mods. F9 is MCM's hotkey, and a debug object dump on F9 froze
the game while MCM opened.
## QuestStash - quest items in personal stashes

This separate native ASI prototype restores only the game's transfer actions for protected,
unequipped items while a **personal stash** is open. Right-click an item in your backpack
to deposit it, or in the stash to retrieve it; native stack selection remains available.
It does not remove quest flags, create replacement items, unlock Drop/Sell, or permit
transfers to ordinary containers. Drag-and-drop and double-click restrictions are unchanged.
Equipped items must be unequipped first.

**Test on a separate manual save.** Quests may require an item in your backpack, not in
storage. Retrieve it before continuing the quest. Quest-item deposit and retrieval were
verified by Ian on 2026-11-06, including storing Skif's pistol; the storage screenshot still
shows its protection icon. Save/reload persistence and quest progression remain unverified.

```powershell
.\mods\quest-stash\scripts\build-quest-stash.ps1
# Close the game first. Adds winhttp.dll only if absent; leaves UE4SS untouched.
.\mods\quest-stash\scripts\deploy-quest-stash.ps1 -InstallLoader
# Remove only this mod; leaves the shared loader in place:
.\mods\quest-stash\scripts\deploy-quest-stash.ps1 -Remove
```

Requires the Visual Studio x64 C++ tools to build. The installer downloads the official
[Ultimate ASI Loader](https://github.com/ThirteenAG/Ultimate-ASI-Loader) 10.0.2 archive
with a pinned SHA-256 when requested; it never replaces an existing loader.
The plugin requires the exact verified Steam 2.1.0 executable and disables itself on
other builds or a conflicting inventory vtable hook. Check `QuestStash.log` beside
`Stalker2-Win64-Shipping.exe` for `ACTIVE` or a specific refusal reason.
Do not unload the plugin during play; installation/removal requires a restart.

The build runs policy and native-memory fixture tests. These verify destination scoping
and that only the intended menu bytes change; they do not prove in-game transfer safety.
The [native source](mods/quest-stash/src/) and
[investigation notes](shared/docs/modding-notes.md#personal-stash-quest-item-prototype) are separate
from ZoneXM and MolotovFire.

## Molotov Cocktail

Adds the Zone's most conspicuously missing weapon to S.T.A.L.K.E.R. 2: Heart of Chornobyl:
a throwable **Molotov Cocktail** (`GrenadeMolotov`) with impact detonation, ground fire,
burn-over-time, a hand-authored bottle with a burning rag — and bartender stock, because
there was already this much vodka lying around.

## Architecture: three cooperating layers

All under [mods/molotov-cocktail/](mods/molotov-cocktail/):

| Layer             | Lives in                                                       | Ships as                                                    | Does                                                                |
| ----------------- | -------------------------------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------- |
| Game-data overlay | [pak/](mods/molotov-cocktail/pak/)                             | `MolotovCocktail_P.pak` → `Content/Paks/~mods`              | Item/explosion/trade/mesh prototypes, localization                  |
| Custom asset      | [asset-pipeline/](mods/molotov-cocktail/asset-pipeline/)       | `MolotovBottle` Zone Kit plugin paks → `Mods/MolotovBottle` | Skeletal bottle + rag + flame (in-hand), static twin (world/thrown) |
| Runtime behavior  | [ue4ss/MolotovFire/](mods/molotov-cocktail/ue4ss/MolotovFire/) | UE4SS Lua → `Binaries/Win64/ue4ss/Mods`                     | Impact detonation, ground fire patches, fuse fallback               |

## Game-data overlay (cfg pak)

| Piece                 | File                                                                                                                                | Technique                                                                                          |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| Throwable item        | [GrenadeMolotov.cfg](mods/molotov-cocktail/pak/Stalker2/Content/GameLite/GameData/ItemPrototypes/GrenadeMolotov.cfg)                | `refkey=GrenadeRGD5` inheritance; claims the exe's native `EGrenadeType::Molotov` slot             |
| Fire explosion        | [ExplosionMolotov.cfg](mods/molotov-cocktail/pak/Stalker2/Content/GameLite/GameData/ExplosionPrototypes/ExplosionMolotov.cfg)       | `refkey=Empty`; `NS_Barrel_Explo` VFX, gas-cylinder SFX, `EDamageSource::Fire`                     |
| Burning victims       | same file                                                                                                                           | `ConcussionEffects`/`NPCConcussionEffects` → `FireBurning` (burn damage over time)                 |
| Bottle meshes         | [MolotovMeshes.cfg](mods/molotov-cocktail/pak/Stalker2/Content/GameLite/GameData/MeshPrototypes/MolotovMeshes.cfg)                  | Points at our own `/MolotovBottle` plugin: `SK_MolotovBottle` (hand), `SM_MolotovBottle` (world)   |
| Buyable at bartenders | [MolotovTradeStock.cfg](mods/molotov-cocktail/pak/Stalker2/Content/GameLite/GameData/ItemGeneratorPrototypes/MolotovTradeStock.cfg) | `{bpatch}` named-node append on `BartenderUniversal_TradeItemGenerator` (mod-friendly)             |
| Name + description    | [localization.en.csv](mods/molotov-cocktail/localization/localization.en.csv)                                                       | `editor_import_text.py` writes the plugin's Text Tool asset + `Autogenerated_*_LocalizationDatabase`; the game layers it over vanilla text (no `Game.locres` override) |

## Custom bottle asset (the fun part)

One command — [pipeline.ps1](mods/molotov-cocktail/asset-pipeline/pipeline.ps1) — builds the whole asset
headlessly: Blender mesh build → FBX sanity checks → preview renders → Zone Kit headless editor
import (materials, slots, physics) → cook → deploy. The asset is a cossack-vodka bottle on the
RGD-5 grenade skeleton with a cloth plug and a physics-simulated rag tail on its own bone
(`jnt_fuse`); the burning rag is the game's own `NS_Character_Fire` Niagara system attached at
runtime. The mesh has three material slots: vodka glass, vodka label and `M_MolotovRag`.

Techniques worth stealing:

- **Scale laundering** — GSC's importer scales geometry by the FBX unit header but reads bone
  numerics raw; the recipe bakes ×100 into mesh+armature data under a cm header so the cooked
  bind pose is bit-identical to vanilla grenades. The editor preview lies; only cooked output counts.
- **FP seating** — first-person weapons need GSC's foreground-FOV WPO correction
  (`MF_ForegroundWithShadowSwitch` fed from `MPC_FOV`'s `TanFOV`) or the mesh floats off the hand.
- **Flame = the game's own Niagara fire.** `NS_Character_Fire` attached to the rag bone at runtime.
- **Scripted materials** — Zone Kit's Python `MaterialProperty` enum is stripped (no WPO pin, no
  `MP_MATERIAL_ATTRIBUTES`), and wiring a graph to `MP_FRONT_MATERIAL` (the Substrate pin)
  "compiles clean" into an **empty shader**. Non-Substrate game ⇒ classic pins only
  (`MP_EMISSIVE_COLOR`, `MP_OPACITY`), and assert every `connect_material_property`.
- **Vertex colors as data bus** — R = droop weight, G = solidify shell sign. `VertexColor`'s RGB
  output is float3 — take alpha from the dedicated `A` pin or the cook's shader translation fails
  (the editor won't warn you).

## Runtime behavior (UE4SS)

[MolotovFire](mods/molotov-cocktail/ue4ss/MolotovFire/Scripts/): impact detonation via the grenade's hit
event (vanilla `BP_grenade` is timer-only), ground fire patches spawned from `BP_BonFire` with
staggered lifetimes, soft-landing fuse fallback, the burning-rag fire itself
(`NS_Character_Fire` attached to `jnt_fuse`, doused on throw), the rag physics kick
(pooled weapon meshes never create physics state on their own), the in-flight rag droop (pins
`M_MolotovRag`'s `DroopStrength` on the thrown static twin),
and two field rules: **menu crafting** (right-click vodka or bandages in the backpack while carrying
vodka and a bandage and a **Make Molotov** entry joins the context menu; one click spends one
of each and wraps a bottle) and a **hold singe** — while the
rag burns in hand you slowly lose HP (~0.33 HP/s, floored so it can't kill you), applied with
`Obj:ForceSetHP` so it lands silently. Every damage-typed route drags its own feedback along:
Burn triggers the engine's player-on-fire reaction (roaring audio that buries the mix, red
screen edges) and Strike a pain grunt on every tick — neither reads right for merely holding a
lit bottle. The fire in your hand is the warning.

The craft itself is a **quest-node chain** ([MolotovCraftNodes.cfg](mods/molotov-cocktail/pak/Stalker2/Content/GameLite/GameData/QuestNodePrototypes/MolotovCraftNodes.cfg)):
`ItemRemove` is the only inventory-removal verb the game exposes — no native API exists — so
the menu click fires the chain head with `XStartQuestNodeBySID`, and the quest does the
vodka/bandage/molotov transaction atomically. The menu row itself is a UE4SS injection: the
native `W_RightClickMenu` is built per-open, a `MenuItemWidgetClass` row is spawned and added
to its `VerticalBox`, and — because the game binds row delegates natively only for its own
rows — the click is detected as `row:IsHovered()` + an LMB keybind rather than a button event.
The selected slot is matched through its icon material's `Icon` texture against the exact
vanilla vodka/bandage assets, not its translated label. Selection and current-menu ownership
are checked before adding the row and again on click; stale rows are removed. Unreadable
icons suppress crafting with a diagnostic. Mods replacing those icon assets require updating
the allowlist; items reusing the same textures cannot be distinguished by this UI-only check.

The Lua follows the workspace [shared](../../Standards/conventions/coding/shared.md) and
[Lua](../../Standards/conventions/coding/lua.md) conventions, split by responsibility inside
[MolotovFire's Scripts folder](mods/molotov-cocktail/ue4ss/MolotovFire/Scripts/):

| Module | Responsibility |
| --- | --- |
| `main.lua` | Startup, timer registration order, equip watcher and hands-changed cleanup |
| `unreal.lua` | Logging and defensive UObject helpers |
| `hands.lua` | Shared in-hands state (`fp`, montage latch, equip generation) and molotov-mesh lookup |
| `rag_fire.lua` | Rag physics kick, rag/tip fire on the held bottle, douse |
| `pin_pull.lua` | Skips the RGD5 `TearOff` montage section on throw |
| `hold_burn.lua` | Silent HP singe while the lit bottle is held |
| `grenade_tracker.lua` | Thrown-grenade watcher, flight-look rag droop, impact/fuse detonation |
| `ground_fire.lua` | Ground fire pool spawn, expiry and NPC burns |
| `crafting.lua` | Quest-node craft chain, inventory counts and backpack repaint |
| `craft_menu.lua` | **Make Molotov** context-menu row, hover mirror and LMB click |

Format it with `stylua --config-path mods/molotov-cocktail/stylua.toml mods/molotov-cocktail/ue4ss/MolotovFire/Scripts`.

## Pipeline

```
# game-data pak (molotov scripts live in mods/molotov-cocktail/scripts/)
shared/scripts/extract-gamedata.ps1  # unpack pakchunk0 cfg.bin -> extracted/, decode via shared/tools/bin2cfg.py
pack-mod.ps1                         # pak/ -> build/MolotovCocktail_P.pak (repak V11, mount ../../../; rejects any .locres)
deploy-mod.ps1                       # copy into <game>/Stalker2/Content/Paks/~mods  (-Remove uninstalls)
shared/scripts/deploy-ue4ss.ps1      # sync mods/*/ue4ss/* -> <game>/Stalker2/Binaries/Win64/ue4ss/Mods
#   also re-derives the GUObjectArray AOB from the installed exe (shared/tools/find_guobjectarray.py):
#   a game patch shifts register allocation, the shipped pattern misses, and UE4SS then aborts
#   outright -- every Lua mod goes dark at once. -SkipSignatures opts out.

# bottle asset (Zone Kit required; editor and game closed)
asset-pipeline/pipeline.ps1          # Blender -> checks -> previews -> headless editor -> cook -> deploy
#   the headless editor step also turns localization/*.csv into the plugin's Text Tool asset
#   and its localization database (the headless cook doesn't generate the database itself);
#   the cook emits NewContent + OverrideContent containers (the database ships in OverrideContent)
#   -SkipBlender -SkipPreviews -SkipEditor -SkipCook -SkipDeploy for partial runs
#   gates on log sentinels (HEADLESS_ALL_DONE, SLOTS_FIXED, ...) because UE exit codes lie
asset-pipeline/build_icon.py         # Blender render of the inventory icon (then compose_icons.py)
```

Prereqs: repak (`C:\Tools\repak`), Python 3.11, Blender 5.x, STALKER 2 Zone Kit
(Epic Games Store), UE4SS. Paths are centralized in [shared/scripts/paths.ps1](shared/scripts/paths.ps1).
`build_molotov.py` needs the vanilla `SK_RGD5.FBX` exported with FModel into
`asset-pipeline/ref/Game/_STALKER2/SkeletalMeshes/weapons/grenades/RGD5/` (gitignored).
Grep every cook log for `Failed to translate` before deploying — a material that fails shader
translation cooks "successfully" and ships as the checkerboard.

## Key facts learned (2.0.x game data)

- Gameplay cfgs ship **binarized** (`.cfg.bin`, format v2) inside `pakchunk0-Windows.pak`
  (unencrypted, V11, Oodle). [shared/tools/bin2cfg.py](shared/tools/bin2cfg.py) (by joric/sdwvit/thexii) decodes them.
- The engine also reads **loose plain-text `.cfg`** files and mod paks as an overlay; new files
  under `GameData/` are picked up, structs inherit cross-file via `{refurl=..;refkey=SID}`.
- `{bpatch}` roots merge into an existing prototype by struct name instead of replacing the file —
  but only at root level; nested `{bpatch}` does nothing.
- All vanilla locres entries have `SourceStringHash = 0`. Mods don't touch locres at all: new
  keys go in the mod's own `*_LocalizationDatabase`, which the game merges over vanilla text.
  The game only merges it from the mod's **OverrideContent** container (remapped to
  `/Game/Autogenerated_*`). A NewContent-only cook ships the database but the game never reads it,
  so the item shows raw `sid_items_*` keys. `pipeline.ps1` runs `GSCCookMod` with the same
  classifier split as the GUI's "Package mod" (database → override, everything else → new).
- The grenade quick-slot cycles by **`EGrenadeType` enum**, not item SID. The shipping exe
  already defines `EGrenadeType::Molotov` (and `::Dynamite` — hello, cut content), so the mod
  claims the native type and gets its own entry in the grenade cycle.
- Raw-spawning anomaly BPs (`BP_ClassicFireAnomaly_C`) is a native AV that `pcall` cannot catch;
  `BP_BonFire` is self-contained and safe.

## In-game test checklist

1. Launch (cfg pak in `~mods` and `MolotovBottle` plugin paks load automatically; UE4SS mods via `enabled.txt`).
2. Buy from the Zalissya bartender (restocks on timer; sleep/wait if absent) — or open the
   backpack, right-click vodka or a bandage and pick **Make Molotov**: one vodka and one
   bandage spent, molotov in its place.
3. Equip grenades and **cycle the grenade slot** — the molotov is its own grenade type.
4. In hand: bottle with cloth plug, physics rag tail swinging with movement, Niagara fire +
   smoke riding the rag, all seated on the hand and following every animation — and your HP
   slowly ticking down (hold singe) until you throw or holster.
5. Throw: fire douses as the bottle leaves the hand; impact fireball + ground fire patches;
   victims tick burn damage.
6. Drop it: static bottle twin in the world.

## Known limitations / next ideas

- In-flight bottle shows no flame (candidate: attach the Niagara fire to the thrown grenade actor).
- The `MolotovBottle` plugin paks must be cooked locally with Zone Kit; they're not committed.
- Text covers all 18 game languages (`localization/localization.<culture>.csv`, `key,text`).
  A new key needs a row in every file; the editor step rejects partial coverage.

---

## ZoneLink — co-op presence (experimental)

First rung of a co-op MVP ladder: players each run their own single-player session and see
each other as `BP_AI_Human_C` stalker puppets driven from a ~15 Hz state stream — position,
locomotion animation, stance, spawn-time weapon. No combat sync, no world sync (yet).

Full design: [mods/zonelink/docs/01-presence.md](mods/zonelink/docs/01-presence.md) ·
Code: [mods/zonelink/ue4ss/ZoneLink/Scripts/main.lua](mods/zonelink/ue4ss/ZoneLink/Scripts/main.lua)

The core trick that makes it testable with **one game copy**: the puppet driver consumes an
abstract StateFeed, which can be filled by a socket, a trace file, or your own movement on a
delay. That yields a three-tier test ladder:

| Tier             | Needs                            | Validates                                                     | Status       |
| ---------------- | -------------------------------- | ------------------------------------------------------------- | ------------ |
| **A — Ghost**    | 1 game copy, pure Lua            | Puppet spawn/AI suppression/anim quality — all top game risks | **Verified** |
| **B — Sim peer** | 1 game copy + `zonelink-sim` exe | Wire protocol, jitter/loss, interp buffer, handshake          | Next         |
| **C — LAN**      | 2 machines, 2 licenses           | End-to-end bidirectional                                      | Later        |

Current Tier-A build keys: **F2** record own movement to trace · **F3** spawn + protect puppet ·
**F4** cycle drive OFF → ESCORT (10 m stations) → GHOST (trace replay) · **Ctrl+J** object dump (UE4SS built-in; F9 is MCM).

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

_"Many stalkers were hurt in the making of this modification... of course."_

Play your own music over the game; ZoneXM ducks other apps on the default Windows audio
device whenever the Zone needs your ears, and fades them back when the dust settles.
The companion excludes the Steam game process; game audio in other editions may also be
ducked. Two cooperating halves are joined by a flag file:

| Half      | Lives in                                                                       | Does                                                                                                                   |
| --------- | ------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------- |
| Sensor    | [mods/zonexm/ue4ss/ZoneXM/](mods/zonexm/ue4ss/ZoneXM/) (UE4SS Lua)             | Detects danger/speech in-game, keeps `%USERPROFILE%\ZoneXM\alert.flag` alive while it lasts                           |
| Companion | [ZoneXM Companion](mods/zonexm/src/ZoneXM.Notifications/) (native Windows app) | Polls the flag, ducks per-app CoreAudio session volumes, restores them, and optionally forwards selected notifications |

The mod follows the workspace [shared](../../Standards/conventions/coding/shared.md)
and [Lua](../../Standards/conventions/coding/lua.md) conventions. Its Lua modules stay
inside [ZoneXM's Scripts folder](mods/zonexm/ue4ss/ZoneXM/Scripts/):

| Module | Responsibility |
| --- | --- |
| `main.lua` | Startup and the game-thread poll |
| `sensors.lua` | Combat, speech and mutant detection; alert heartbeat |
| `bridge.lua` | Shared-file paths, bounded snapshot validation and alert I/O |
| `banner.lua` | Event selection, display formatting, widget layout and lifetime |
| `subtitle_style.lua` | Read-only subtitle capture and saved styling |
| `unreal.lua` | Shared widget operations and bounded host-error reporting |

State belongs to one module per UE4SS mod Lua state; there are no factories or
cross-mod runtime dependencies. Field/channel order in persisted protocols and
native API parameters is intentional, not alphabetically sorted.
Format this mod with `stylua --config-path mods/zonexm/stylua.toml mods/zonexm/ue4ss/ZoneXM/Scripts`
(MolotovFire: `stylua --config-path mods/molotov-cocktail/stylua.toml mods/molotov-cocktail/ue4ss/MolotovFire/Scripts`).
Legacy watchdog interop lives in `mods/zonexm/scripts/AudioSessions.cs`, beside
the PowerShell script that compiles it. Keep those files together when using the
legacy watchdog; the native companion does not depend on either.

### Player setup

1. Install a UE4SS build compatible with the game version and edition.
2. Install the matching ZoneXM archive using Vortex's S.T.A.L.K.E.R. 2 extension, or extract
   it manually into the game installation folder containing `Stalker2`. In Vortex, enable
   and deploy the mod; if the UE4SS Load Order page is enabled, enable ZoneXM there too.
3. Install [ZoneXM Companion](https://apps.microsoft.com/detail/9pcw3mjw0zwl) from the
   Microsoft Store and keep it running while playing.
4. Enable in-game subtitles for speech detection.
5. To use banners, enable Windows notifications, allow notification access in the companion,
   and select the apps to forward. Only new Notification Center entries from selected apps
   are forwarded.

Audio ducking does not require notification permission. The companion includes its .NET and
Windows App SDK runtimes: players will not need an SDK, PowerShell 7, a terminal command,
Developer Mode, or a manually trusted certificate for the Store installation. The game mod
and UE4SS remain separate prerequisites; the companion does not install them or start at logon.
The PowerShell commands below are developer or legacy workflows, not companion installation steps.

The game-side footprint is `Stalker2\Binaries\Win64\ue4ss\Mods\ZoneXM` on Steam, or
`Stalker2\Binaries\WinGDK\ue4ss\Mods\ZoneXM` for the Game Pass archive. Its `Scripts`
folder contains the six modules listed above. The companion and mod exchange files in
`%USERPROFILE%\ZoneXM`, outside the game installation. Generate both archives with
`.\mods\zonexm\scripts\package-zonexm.ps1`; they are written to `build\release`.
The Game Pass package and audio exclusion still need in-game verification.

#### Migrating a manual install to Vortex

With the game closed, disable ZoneXM in Vortex and deploy before touching its game folder.
Vortex may restore previously overwritten manual files from `.vortex_backup` files. Once
deployment finishes and Vortex's links are removed, move any remaining `ue4ss\Mods\ZoneXM`
folder outside the game as a backup. Then enable ZoneXM in Vortex and deploy again. Do not
run the manual deployment script over a Vortex-managed installation.

The UE4SS build used here also starts mods with an `enabled.txt` marker independently of
`mods.txt`, so a leftover manual marker can enable ZoneXM even when its load-order entry is
disabled. With Vortex's UE4SS Load Order enabled, verify that no unmanaged marker remains;
when that feature is disabled, Vortex may intentionally manage the marker instead.

### Now-playing banners (legacy script prototype)

GSMTC now-playing support is not yet integrated into the companion. This optional prototype
still uses PowerShell; it is not required for native audio ducking or Notification Center banners.
For a future release, port this read-only bridge into the companion before advertising
media-session banners, rather than require players to run another script.

The watchdog also launches the read-only [Windows media bridge](mods/zonexm/scripts/zonexm-media.ps1).
It reads Windows Global System Media Transport Controls (GSMTC), not a Pandora-specific
API: Pandora, iTunes/Apple Music, Spotify, browsers, or other players can supply tracks
**if that app/version exposes a Windows media session**. This is not universal app
support; the bridge cannot discover metadata from a player that does not publish it.
No streaming credentials, playback controls, or app automation are used.

The Lua mod displays `Artist - Song` for six seconds in independent text widgets
positioned at the bottom-right of the HUD, inset 64 horizontal and 80 vertical DPI-scaled
units. The title/artist uses the live subtitle speaker font, size, yellow
color, outline, and shadow; the body/track uses the subtitle dialogue font, size, white
color, outline, and shadow. No 28-point override is applied. Each new banner reads the
full font struct, retaining the font/outline materials (and their texture references),
typeface, spacing, and outline-to-drop-shadow settings instead of reconstructing a font.
This reuses the live text appearance, not the surrounding dialogue interaction panel.
Each new banner refreshes from available subtitle styles without changing the real subtitle
widgets. Two collapsed, viewport-owned text widgets retain the complete style when the game's
transient subtitle view disappears; the mod also captures it while idle, before a notification.
The cache resets on player/world changes and rebuilds if collected. If neither a live view nor
a valid retained style is available, a logged error/retry replaces a guessed font.
The compact quest-style text has no ZoneXM heading; its two adjacent, top-aligned text
segments share a maximum 640-by-100-unit area and wrap independently when long.
It does not create quests,
borrow live quest widgets, or manipulate notification queues. New songs replace the
banner rather than stacking. Combat/dialogue and paused/loading gameplay suppress it;
when clear, only the latest still-playing track is eligible. Repeated heartbeats and
pause/resume of the same track do not repeat a banner. An interrupted banner is dismissed.
Long titles/artists are shortened for display without changing their deduplication identity.

Windows' preferred session wins when playing; otherwise the first playing session sorted
by app ID is used. The bridge writes an atomic, UTF-8 `now-playing.txt` snapshot beside
`alert.flag` once per second; the Lua reader rejects malformed data and ignores snapshots
older than eight seconds. Empty titles, paused/stopped players, and absent sessions do
not produce banners. Title + artist + source identify a track; a consecutive repeat with
identical metadata cannot be distinguished from the previous play.

Windows PowerShell **5.1** runs the WinRT bridge; the audio watchdog still runs on **7+**.
The watchdog supervises its hidden child and keeps ducking if the bridge fails. Diagnostics
are `media.log` and `media-error.log` in `%USERPROFILE%\ZoneXM`.

```powershell
.\shared\scripts\deploy-ue4ss.ps1 -Mods ZoneXM -SkipSignatures
# Restart the game after deployment, and restart the watchdog to load the bridge.
pwsh -NoProfile -File .\mods\zonexm\scripts\zonexm-watchdog.ps1
# Read-only compatibility check (does not change audio or write a snapshot):
powershell.exe -NoProfile -File .\mods\zonexm\scripts\zonexm-media.ps1 -Probe
# Banners alone, with no audio ducking (do not run alongside the watchdog bridge):
powershell.exe -NoProfile -File .\mods\zonexm\scripts\zonexm-media.ps1
# Existing ducking behavior without the media bridge:
pwsh -NoProfile -File .\mods\zonexm\scripts\zonexm-watchdog.ps1 -NoBanner
```

Validation:
`lua54 shared/tools/test-ue4ss.lua .` covers banner state and existing sensor timer behavior;
`powershell.exe -NoProfile -File .\mods\zonexm\scripts\test-zonexm-media.ps1` covers source selection,
atomic snapshots, UTF-8, and live WinRT initialization. Native widget rendering/lifetimes
still require an in-game check: play two songs, pause/resume, trigger speech/combat,
and load another save. These tests do not prove native UI safety or player compatibility.

### Windows Notification Center banners

[ZoneXM Companion](mods/zonexm/src/ZoneXM.Notifications/) is a small, local packaged Windows
companion for players such as Pandora that emit notifications but expose no media session.
It uses Windows' permission-gated `UserNotificationListener`, not app hooks, notification
database scraping, or network services. All apps use the same bottom-right quest-style
`Title - Body` banner (title only when the body is empty), with no app heading or `+1` prefix.
Title is subtitle-speaker yellow; body and separator are subtitle-dialogue white.
Subtitle styling exists only after someone speaks, so ZoneXM saves the captured style to
`%USERPROFILE%\ZoneXM\subtitle-style.txt`. The file stores font/material asset
paths, size, colors, and shadow values, never notification text. It rebuilds that style on a fresh
load before anyone has spoken. Before any subtitle has ever been captured, or if the saved font
cannot be loaded, banners still show with the game's default text font and yellow/white colors.
The UE4SS log names the style source used.
Pandora's verified Windows app ID sends song in the title and artist in the body; those
fields are reversed for display so the artist is yellow and the song is white. Other apps
retain title/body order. The media-session path uses its explicit artist/song metadata.
This is an independent styled widget, not an actual quest completion or reward.

The helper uses **WinUI 3 / Windows App SDK with Fluent controls**, not WPF or WinForms, over
Ian's supplied forest artwork, weathered speaker/trefoil emblem, and translucent acrylic tab panels.
Its standard title bar is replaced by a draggable in-app header with minimize, maximize/restore,
and close controls; minimize/close still hide to the tray. Barlow Condensed display lettering,
IBM Plex Sans controls and body text, and IBM Plex Mono technical text are bundled with their font licenses.
The native uppercase app name is weathered white `ZONE` and yellow `XM`; amber section titles
use the same live glyph-masked wear texture, not pre-rendered lettering images.
This is a desktop approximation, not the game's exact font/material/texture rendering.
The activity log remains monospaced, and Windows high-contrast colors override the custom palette.

**Forwarding is opt-in per app; no apps are enabled by default.** This deliberately
differs from mirroring Windows' on-screen banners: entries retained under Do Not Disturb
or with app banners disabled may still be forwarded. The companion cannot reconstruct
Windows' banner/Focus policy. Apps that do not put an entry in Notification Center
(including custom app popup windows) cannot be read. A one-second poll can miss entries
that disappear between polls.

- First run: click **Allow notification access / Start**, then approve Windows' prompt.
  The permission is broad; the local allowlist blocks forwarding from unchecked apps.
  Later launches resume forwarding automatically when access is already granted, without
  prompting, replaying history, or changing consent. Transient Notification Center read failures
  (for example `0x80070005`) are logged and retried with backoff of 5-60 seconds instead of
  stopping forwarding. **Pause forwarding** remains manual until the next launch or Start.
- Apps appear as Windows exposes them. Check each app you want to forward; consent persists
  by exact Windows app ID in `%USERPROFILE%\ZoneXM\helper-settings.json`.
  Newly discovered/reopened apps stay unchecked unless previously opted in.
  Legacy `notification-apps.json` exclusions are retained but never converted into consent:
  upgrading starts with no opted-in apps. Changing consent skips accumulated history.
- Existing history is skipped on startup, Start/resume, and recovery. New/replaced entries
  are deduplicated by notification identity and content. Separate notifications with
  identical text still produce separate events.
- Only the latest new eligible entry is retained. Its six-second game banner shows
  immediately, including during combat, dialogue, and barks. Only pause, loading, or a missing
  player defers it, and the event expires after 30 seconds rather than surfacing much later.
  Dismissed notifications are discarded.
- While forwarding, a fresh `notification.txt` heartbeat takes priority over media-session
  banners, including while idle, preventing double announcements. Exiting/pausing clears
  the file; after a crash the reader expires it within eight seconds. Existing media
  banners can resume afterward if the media watchdog is running.
- **Minimize and Close hide to the notification-area tray** while audio and forwarding continue.
  Click the tray icon to reopen, or right-click it and choose **Exit** to quit and restore
  volumes. Launching the app again also reopens the existing instance.
  **Pause forwarding** stops notifications but leaves audio running.
  It does not auto-launch at logon. Start it independently
  of any PowerShell script: **audio ducking is now built into this app**. It starts armed
  when the window opens, even before notification permission is granted. The audio checkbox
  disables/enables ducking; the separate notification pause button does not disable audio.
  Exiting the app restores volumes. No PowerShell process is needed for this path.
- Built-in ducking follows the existing defaults: app sessions on the default output device,
  except Windows system sounds and the Steam game process. Other editions' game audio may
  also be ducked. The **volume retained while ducked**
  slider selects 0-100% of each session's original volume (default 15%; 0 mutes, 100 leaves
  volume unchanged), persists across launches, and applies during active ducking too.
  It keeps the existing
  350 ms fade down / 1.5 s recovery, new sessions ducked while an alert is active,
  eight-second stale-alert protection. The audio status shows armed/ducked/errors.
  It shares the legacy watchdog's singleton mutex so the two cannot race volume baselines.
  Do not run the standalone watchdog alongside it. For advanced PowerShell-only parameters
  or GSMTC-only use, exit the companion from the tray and use the legacy watchdog instead.
- **Activity log** tab shows the last 200 events with local timestamps: audio duck/restore
  transitions, notification receipts/updates, forwarding to the banner file, expiry/dismissal,
  filter changes, permission changes, and errors. It is memory-only, has a Clear button,
  and does not record notification titles or bodies. Unchanged audio status and snapshot
  heartbeats do not produce repeated entries. App IDs and notification IDs identify sources.
  "Forwarded" confirms a successful file write, not that the game rendered the banner.
  Lua additionally logs dismissal reason and elapsed seconds in the UE4SS log so a brief
  or interrupted banner can be distinguished from a layout failure (restart after deployment).
  Once per notification event, it logs metadata-only game receipt (event age), waits caused by
  pause or no player, and expiry before display.
- Normal close, unchecking ducking, and stale/cleared alerts restore each owned volume.
  Force-killing the app or losing the audio endpoint may prevent restoration; errors are
  surfaced in the app. The built-in worker uses a dedicated MTA thread, not the UI thread,
  and releases enumerated and retained CoreAudio interfaces.
- Notification text stays local and is never included in application diagnostics or
  saved history. The current event is temporarily stored in the shared plaintext
  `notification.txt`; other programs running as you can read it, and spectators or
  streams can see the game banner. Normal expiry/stop removes the text; a forced
  termination can leave an expired file on disk until the companion runs again.
  Original Windows notifications are never modified or dismissed by the companion.

Developer build/install (Windows x64, .NET 10 SDK, Windows SDK with MakeAppx):

```powershell
.\mods\zonexm\scripts\build-zonexm-notifications.ps1
# Register the unpacked development package for this Windows user:
.\mods\zonexm\scripts\build-zonexm-notifications.ps1 -Register
# Windows may require Developer Mode; the script does not enable it or install certificates.
# Launch "ZoneXM Companion" from Start; notification access is optional.
.\shared\scripts\deploy-ue4ss.ps1 -Mods ZoneXM -SkipSignatures
# Restart the game to load the updated Lua reader.
dotnet run --project .\mods\zonexm\src\ZoneXM.Notifications.Tests -c Release
lua54 shared/tools/test-ue4ss.lua .
pwsh -NoProfile -File .\mods\zonexm\scripts\test-zonexm-watchdog.ps1
powershell -NoProfile -File .\mods\zonexm\scripts\test-zonexm-media.ps1
```

The build produces a self-contained, unsigned development MSIX and a registerable folder
under `build/zonexm-notifications`. It references the WinUI SDK component rather than the
full AI/ML/widgets bundle. SDK reference WinMDs stay build-time only; the C#/WinRT
projection assemblies, native runtime binaries and activation registrations are retained.
Keep the registered folder in place. Exit the companion from the tray
before rebuilding it. Distribution to other machines would require an appropriate
package-signing/install workflow; no certificate trust changes are made here.
Uninstall with `Get-AppxPackage -Name ZoneXM.Notifications | Remove-AppxPackage`
after exiting the companion; consent and ducking settings in the shared ZoneXM folder are retained.

**Storage update (Companion 1.3.1 / mod 1.0.1):** update both components together and
restart them. Shared files now live in `%USERPROFILE%\ZoneXM`, outside MSIX's AppData
write virtualization. The companion no longer requests `unvirtualizedResources` or
disables file virtualization. On first run it imports a valid legacy
`%LOCALAPPDATA%\ZoneXM\helper-settings.json` only when new settings do not exist,
preserving the duck level and exact opt-in list. Invalid legacy settings are reported;
they never silently grant consent. Notification text, flags, snapshots, logs, and the old
subtitle-style cache are not copied. The game regenerates its style cache.
Old files remain untouched and may be deleted manually once the upgrade works.
Do not mix an old companion/watchdog/mod with the new versions: they use different folders.

### Microsoft Store release and maintenance

ZoneXM Companion is published in the Microsoft Store. The checked-in manifest uses a
development identity; Store builds use the Partner Center identity. For future releases:

- Use the exact package Identity Name, Publisher and Publisher Display Name from
  Partner Center's **Product identity**. The checked-in
  `ZoneXM.Notifications` / `CN=ZoneXM` values are development placeholders.
- Produce the self-contained x64 MSIX with those identity values. Use the existing
  `-IdentityName`, `-Publisher`, `-PublisherDisplayName` and `-Version` build parameters;
  the fourth version component must be zero. Use a separate `-OutputDirectory` and do not
  register the Store-identity draft over the local development install. Microsoft signs
  approved Store packages; local sideloading has a separate signing/trust workflow.
  The build passes the final identity into PRI generation and keeps identity-specific
  intermediate indexes; renaming a development PRI does not change its resource-map identity.
- Supply certification notes explaining `runFullTrust` (desktop WinUI, CoreAudio and tray)
  and `userNotificationListener` (explicit permission plus per-app opt-in).
  `unvirtualizedResources` and all virtualization overrides have been removed.
  Shared files use a normal user-owned folder outside AppData, which
  [MSIX permits without a virtualization exclusion](https://learn.microsoft.com/en-us/windows/msix/desktop/flexible-virtualization#default-msix-behavior).
  Check capability acceptance for updates in Partner Center; local MakeAppx validation
  is not Store approval.
- Review Notification Center forwarding against Store policy 10.9 before updates:
  retained entries can currently appear in-game under Do Not Disturb or disabled Windows
  banners. Explain the behavior and resolve any required policy change before shipping.
- Keep the [privacy policy](mods/zonexm/PRIVACY.md) and support contact at public HTTPS
  URLs. Maintain screenshots, an accurate description, age-rating answers and certification
  test steps. Disclose the game, UE4SS and ZoneXM mod dependency at the start of the listing;
  confirm redistribution rights for supplied artwork and keep bundled font license notices.
- Run Windows App Certification Kit and a fresh-account/machine install, upgrade and uninstall
  check. Verify notification denial/revocation, shared-file access, audio restoration, tray
  behavior, high contrast and mixed DPI; test the Steam and Game Pass mod packages in-game.
  WACK 10.0.28000.2957 package analysis of Companion 1.3.1 passes resource and metadata
  validation (23 passes, one optional blocked-executables failure). The remaining scan
  findings are in the .NET apphost and bundled Microsoft runtime files, not application
  calls to launch external executables. Microsoft's [Desktop Bridge test guidance](https://learn.microsoft.com/en-us/windows/uwp/debug-test-perf/windows-desktop-bridge-app-tests#42-blocked-executables)
  treats this test as informational; review findings after dependency changes rather than
  deleting required runtime files or modifying vendor binaries to silence the scanner.
- Continue shipping the native audio/notification features unless GSMTC now-playing is
  integrated in C# first. For GSMTC, review `globalMediaControl` capability requirements for the packaged
  desktop app and update privacy documentation/tests. Do not advertise that prototype as a
  script-free companion feature before it is implemented.

A full-trust desktop companion can launch bundled PowerShell as an ordinary child process,
but packaging does not override execution policy, application-control policy or elevation rules.
There is no need for that in the current companion, and a native GSMTC bridge is the preferred
way to avoid a second runtime/child process. Do not require players to disable security settings,
run setup scripts, or install PowerShell 7. Build-time artwork scripts are developer tools only.

References: [Microsoft Store publishing](https://learn.microsoft.com/en-us/windows/apps/publish/),
[Store policies](https://learn.microsoft.com/en-us/windows/apps/publish/store-policies), and
[capability declarations](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/app-capability-declarations).

Verified locally: package registration, user-granted notification permission, advancing
heartbeat at the game-readable path, and a synthetic Windows toast reaching the exact
eight-line snapshot. Tests cover filtering, startup/resume baselines, replacement IDs,
burst coalescing, expiry, UTF-8, Lua source priority, and existing sensors.
Tests cover opt-in defaults, unknown/reopened app rejection, consent revocation, settings
roundtrips, and malformed/legacy settings rejection.
Audio tests cover exact 0/15/67/100% levels, game exclusion, multiple sessions in one app, late
sessions, restoration and COM-reference cleanup; a live read-only check exercises
CoreAudio enumeration. The game log exposed an unreflected `SetWrapTextAt` call in the
first banner prototype; it was removed in favor of auto-wrap within the fixed-width widget.
Verified in-game after restart: a synthetic Windows notification reached the companion,
was logged as dispatched by Lua, and was visibly rendered in the original upper-left layout.
The bottom-right probe using measured viewport size/DPI was also confirmed visually.
Nonzero viewport anchors read back as zero in this game, putting the earlier layout off-screen.
The normal banner now uses the verified measured-position approach and updates during
viewport changes; narrow viewports reduce the box/insets to stay on-screen.
Restart to load this fix; normal song-change delivery with the new position still needs checking.
Ian subsequently confirmed viewport-measured normal notifications work well.
Subtitle-matched two-color styling is a later update and needs an in-game visual check.
Pandora song-change rendering and subtitle styling were confirmed visually; its
artist-first correction and prefix removal require a game restart.

Sensor tiers (each refreshes a timestamp; the flag stays hot while any window is open):

| Tier    | Trigger                                 | Mechanism                                                         | Tail                |
| ------- | --------------------------------------- | ----------------------------------------------------------------- | ------------------- |
| Gunfire | any shot near Skif (player or NPC)      | `ItemAppearanceComponent:OnShotSoundStart` hook (proven)          | 6s                  |
| Beasts  | live mutant within 35 m                 | `FindAllOf("AnimInstanceMutant")` radar sweep, `IsAlive`-filtered | 3s, self-refreshing |
| Speech  | anyone talking (dialog, bark, cutscene) | `SubtitleView` visibility poll — needs subtitles ON               | 2.5s                |
| Melee   | mutant lunge                            | `Obj:OnMeleeAttack_BP` battery (candidates under test)            | 3s                  |

The watchdog fades instead of stepping: smoothstep dip over 350 ms (combat is urgent),
rise over 1.5 s (recovery is musical). Per-session baselines mean every app returns to
exactly its pre-duck volume — including apps that started mid-fight. Single-instance
mutex; stale flag (> 8 s) = dead game = restore.

```powershell
.\shared\scripts\deploy-ue4ss.ps1 -Mods ZoneXM -SkipSignatures      # sensor → game
.\mods\zonexm\scripts\zonexm-watchdog.ps1                             # duck ALL except the game (default)
.\mods\zonexm\scripts\zonexm-watchdog.ps1 -ProcessName Pandora,msedge # narrow mode
.\mods\zonexm\scripts\zonexm-watchdog.ps1 -DuckLevel 0.15 -DuckFadeMs 350 -RestoreFadeMs 1500
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
