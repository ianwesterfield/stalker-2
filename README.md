# stalker-2 — Molotov Cocktail mod

Adds the Zone's most conspicuously missing weapon to S.T.A.L.K.E.R. 2: Heart of Chornobyl:
a throwable **Molotov Cocktail** (`GrenadeMolotov`) with a gasoline fireball, burn-over-time,
and bartender stock — because there was already this much vodka lying around.

## What the mod does

| Piece                 | File                                                                                                                                          | Technique                                                                                     |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Throwable item        | [mod/.../ItemPrototypes/GrenadeMolotov.cfg](mod/Stalker2/Content/GameLite/GameData/ItemPrototypes/GrenadeMolotov.cfg)                         | New prototype, `refkey=GrenadeRGD5` inheritance; vodka icon + world mesh                      |
| Fire explosion        | [mod/.../ExplosionPrototypes/ExplosionMolotov.cfg](mod/Stalker2/Content/GameLite/GameData/ExplosionPrototypes/ExplosionMolotov.cfg)           | New prototype, `refkey=Empty`; `NS_Barrel_Explo` VFX, gas-cylinder SFX, `EDamageSource::Fire` |
| Burning victims       | same file                                                                                                                                     | `ConcussionEffects`/`NPCConcussionEffects` → `FireBurning` (10×10 burn damage over 10 s)      |
| Buyable at bartenders | [mod/.../ItemGeneratorPrototypes/MolotovTradeStock.cfg](mod/Stalker2/Content/GameLite/GameData/ItemGeneratorPrototypes/MolotovTradeStock.cfg) | `{bpatch}` on `BartenderUniversal_TradeItemGenerator`, named node append (mod-friendly)       |
| Name + description    | [mod-source/localization.en.csv](mod-source/localization.en.csv)                                                                              | Full `Game.locres` override rebuilt from vanilla + added `sid_items_GrenadeMolotov_*` keys    |

Balance: 650 damage radius, 35 player / 120 NPC direct damage, minimal armor damage,
tiny impulse (it's a bottle, not a frag), 2 s fuse. Tune in the two cfg files above.

## Pipeline

```
scripts/extract-gamedata.ps1   # unpack pakchunk0 cfg.bin -> extracted/, decode via tools/bin2cfg.py
scripts/build-locres.ps1       # vanilla Game.locres + mod-source CSV rows -> mod/ (pylocres)
scripts/pack-mod.ps1           # mod/ -> build/MolotovCocktail_P.pak (repak V11, mount ../../../)
scripts/deploy-mod.ps1         # copy into <game>/Stalker2/Content/Paks/~mods  (-Remove uninstalls)
```

Prereqs: repak (`C:\Tools\repak`), Python 3.11 + `pylocres`, UnrealLocres (verification only).
Paths are centralized in [scripts/paths.ps1](scripts/paths.ps1).

## Key facts learned (2.0.x game data)

- Gameplay cfgs ship **binarized** (`.cfg.bin`, format v2) inside `pakchunk0-Windows.pak`
  (unencrypted, V11, Oodle). [tools/bin2cfg.py](tools/bin2cfg.py) (by joric/sdwvit/thexii) decodes them.
- The engine also reads **loose plain-text `.cfg`** files and mod paks as an overlay; new files
  under `GameData/` are picked up, structs inherit cross-file via `{refurl=..;refkey=SID}`
  (same mechanism the Deluxe/Ultimate DLC paks use).
- `{bpatch}` roots merge into an existing prototype by struct name instead of replacing the file —
  this is what keeps two mods touching the same generator compatible.
- All vanilla locres entries have `SourceStringHash = 0`; new keys must match.
  UnrealLocres `import` cannot add keys — hence pylocres.
- Useful vanilla SIDs: `TemplateGrenade`, `GrenadeRGD5/F1`, `ExplosionGasolineCan/Barrels`
  (fire VFX), `FireBurning` (burn DoT), `Vodka` (mesh + icon),
  `BartenderUniversal_TradeItemGenerator`.
- The grenade quick-slot cycles by **`EGrenadeType` enum**, not by item SID — two items
  sharing a type shadow each other. The shipping exe already defines
  `EGrenadeType::Molotov` (and `::Dynamite` — hello, cut content), so the mod claims the
  native Molotov type and appears as its own entry in the grenade cycle.

## In-game test checklist

1. Launch game (mod pak in `~mods` loads automatically; no menu toggle on Steam builds).
2. Visit the Zalissya bartender — "Molotov Cocktail" under his stock (restocks on timer;
   sleep/wait if absent).
3. Verify: vodka icon + name/description in trade UI and inventory.
4. Equip grenades and **cycle the grenade slot** (same key you'd use to swap RGD-5 ↔ F1) —
   the molotov is its own grenade type in that rotation.
5. Throw at a fuel-free patch of ground: barrel-style fireball, gas SFX, scorch decal.
6. Throw at mutants: initial hit + they keep ticking burn damage ~10 s.
7. Drop it: world model is a vodka bottle.

## Known limitations / next ideas

- First-person hands show the RGD-5 (mesh/anim inherited) — v1 keeps the proven skeletal
  mesh + AnimBP; swapping to the vodka skeletal mesh (`SK_vodka_fp`) needs its own
  grenade AnimBP to avoid T-pose/crash.
- Timed 2 s fuse, not impact detonation (vanilla `BP_grenade` is timer-driven).
- No lingering ground fire pool — the burn lives on victims, not terrain.
- English locres only; add `localization.<lang>.csv` and pass `-Languages` to extend.
- After a game patch: re-run `build-locres.ps1` + `pack-mod.ps1` + `deploy-mod.ps1`
  (locres is a full-file override and must be rebuilt against the new vanilla).
