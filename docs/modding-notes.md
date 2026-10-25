# S.T.A.L.K.E.R. 2 modding notes — everything we learned the hard way

Reference distilled from the molotov build (2026-10). The README covers _what_ the mod is;
this is the _how_ and the traps. Game version 2.0.x, UE 5.5, Zone Kit SDK, UE4SS 3.0.1-experimental.

## Game data layer

- Gameplay cfgs ship **binarized** (`.cfg.bin` v2 = string pool + index tree) in
  `pakchunk0-Windows.pak` (unencrypted, V11, Oodle). Decode with [tools/bin2cfg.py](../tools/bin2cfg.py).
- Engine reads loose plain-text `.cfg` and mod paks as an **overlay**; new files under
  `GameData/**` are auto-registered. Cross-file inheritance:
  `Name : struct.begin {refurl=../ItemPrototypes.cfg;refkey=GrenadeRGD5}` — DLC paks are the
  ground truth for the syntax.
- `{bpatch}` merges by struct name **at root level only** — nested `{bpatch}` silently does
  nothing (tested v1–v7 on ItemGeneratorPrototypes).
- **New entries need `{refurl}`, not just `{bpatch}`.** A mod cfg in a `GameData/<Collection>/`
  subdir only registers its NEW root structs if the file binds to the vanilla collection via
  `{refurl=../<Collection>.cfg;refkey=<existing sibling SID>}`. `{bpatch}` edits an existing
  entry by name but does **not** bind the file, so plain new entries beside it are dropped in
  silence. Cost ~6 game restarts to isolate: a node that worked kept working only because an
  unrelated `refurl` entry sat in the same file; deleting that entry killed the others while
  the `{bpatch}` in the same file carried on working.
- Items resolve to their `refkey` parent when the child prototype is missing — purchased
  molotovs in a save transmuted to RGD-5s when the mod was disabled. Permanent; rebuy.
- Stale pak gotcha: UE mounts **any** pak under `Content\Paks` — renaming `~mods` does not
  disable it. A duplicate pak double-registered locres and broke item names.
- cfgs have **no comment syntax** — no `--`, `//` or `#`. A comment header fails the parse.
- cfgs can reference plugin assets: `Texture2D'/MolotovBottle/T_MolotovKitIcon...'` resolves
  the same way the mesh prototypes already point at `/MolotovBottle/SK_MolotovBottle`.

## Quest scripting (the only inventory-removal verb)

- There is **no native item-removal API** — all 42 `CustomConsoleManager*` classes were
  enumerated; `XCreateItemInInventoryByID` adds, and a negative count silently no-ops.
  `EQuestNodeType::ItemRemove` is the only way to take an item off the player.
- Lua drives it: `CustomConsoleManagerAA:XStartQuestNodeBySID("<node>")` fires a node directly,
  even when its host quest was never started.
- Firing a node **starts its host quest**, which then runs that quest's own
  `LaunchOnQuestStart` chain — hosting on `Bossfight_EquipTEST` dumped its whole dev loadout on
  every craft. Host on a vanilla quest with **zero nodes** (only 13 exist;
  `AnomalyTestMapSpawnOnStart` is the one in use) so there is nothing to cascade.
- **New quests never register** — only new *nodes* do. Don't ship a `QuestPrototypes` file.
- Node fields are `ItemSID` / `ItemsCount`. The names `ItemPrototypeSID` / `ItemsCount` appear
  only *inside* `Conditions`, where values are wrapped as
  `struct.begin VariableType=... VariableValue=... struct.end`.
- Nodes chain through `Launchers[N].Connections[N].SID` — these are **incoming** links (each
  node declares what launches it); `If` branches are picked by `Name = True` / `Name = False`.
- `refkey` also inherits the parent's `Launchers`. Override with an explicit empty
  `Launchers : struct.begin / struct.end` on any node that should only fire manually.
- **An `If` node fired directly does NOT evaluate its Conditions** — it runs the True branch
  regardless (a kit used with an empty pack still crafted). Gate in Lua instead.
- `PlaySound` takes an `AKEventPath` Wwise asset plus a `SoundLocation`; `0,0,0` is what
  vanilla uses for music, i.e. non-positional 2D.

## Grenade system

- Quick-slot cycling keys off the **`EGrenadeType` enum**, not item SID. The exe already
  defines `::Molotov` and `::Dynamite` (cut content) — claim the native value and the item
  gets its own cycle slot. Enum found via ASCII regex scan of the exe
  ([scripts/scan-exe-strings.ps1](../scripts/scan-exe-strings.ps1)).
- No impact-detonation cfg property exists (grenades are timer-only). Runtime solution:
  native `/Script/Stalker2.Grenade` has `OnHit` + `Explode()` UFunctions and a live
  `TimeToExplosion` float. Hook `OnHit`, set a flag, detonate from a tracker loop.
- **Never** unwrap the `FHitResult` hook param or call `Explode()` inside the physics
  dispatch — access violation at the landing moment. Hook body sets a flag only.
- Manual `Explode()` **bypasses** the engine wrapper that applies cfg
  `ConcussionEffects`/`NPCConcussionEffects` — NPCs flinch but never ignite. Fix: sweep
  `FindAllOf("Obj")` in radius, `CppMediator:GetGUID(npc)` →
  `RK:XApplyEffectOnNPCByUID("MolotovBurning", uid)`.
- `TimeToExplode` counts from **release** (no cook-off while held).
- `ExplosionPrototype` has separate ground / **InAir** / Underwater VFX slots — override
  ground _and_ in-air, short fuses airburst.
- Raw-spawning anomaly BPs (`BP_ClassicFireAnomaly_C`) = native AV that `pcall` cannot catch
  (they need spawner-system context). `BP_BonFire_C` and friends are self-contained and safe.

## Asset pipeline (Blender → Zone Kit → cook)

### Scale laundering (the big one)

GSC/UE's importer scales **geometry** by the FBX unit header but reads **bone numerics raw**:

| Export                       | Result                                  |
| ---------------------------- | --------------------------------------- |
| meter numerics, meter header | bind pose cooked ÷100 → invisible mesh  |
| cm numerics, meter header    | 26 m bottle                             |
| **cm numerics, cm header**   | **bit-identical to vanilla grenades** ✔ |

Winning recipe in [build_molotov.py](../asset-pipeline/build_molotov.py): bake
`Matrix.Scale(100)` into armature **and** mesh data (edit mode), clear delta transforms
(Blender's FBX importer hides the UE cm→m conversion in `DELTA_scale`, which
`transform_apply` ignores), set `unit_settings.scale_length = 0.01`, export
`apply_unit_scale=True` + `FBX_SCALE_NONE`.

**The editor preview lies** — it looks correct with broken scale. Only cooked output counts.
Verify by FModel-exporting the cooked pak and diffing in Blender; restart FModel between
cooks (stale pak cache).

### Mesh/import gotchas

- Keep the armature **object** named after the root bone (`jnt_wpn_rgd5`) — Blender absorbs
  the root bone into the object; naming it "Armature" strips the root on import.
- Flat-shaded geometry (`from_pydata` default) → UE can't weld verts → MikkTSpace makes
  per-**triangle** tangents → WPO cloth tears into shards. `use_smooth=True` on every poly.
- Import settings must force `recompute_normals=False`, `recompute_tangents=True`
  (MikkTSpace) and vertex colors `IVCIO_REPLACE` — FBX carries no tangents, and lost vertex
  colors read white (= whole-mesh droop).
- Interchange **dedupes identical bare materials** → sections fuse into one slot. Give every
  placeholder material a distinct base color, and import with materials/textures **off**
  (an FBX placeholder named like your editor material will stomp it).
- Setting material slots in a script only changes them **in memory** — call
  `EditorAssetLibrary.save_asset` and verify all slots non-NULL, or the cooked SK ships
  with a NULL slot (gray default material in game, correct in preview).
- `add_simple_collisions` returns the new shape **index** (0 = success, not failure);
  collision enum renamed `ScriptingCollisionShapeType` → `ScriptCollisionShapeType`.
- Disable Nanite on small static props (`nanite_settings.enabled=False`) — it broke the
  world bottle.

### Cook

```powershell
& "C:\...\STALKER2ZoneKit\Engine\Build\BatchFiles\RunUAT.bat" GSCCookModNewContent `
  "-Project=...\Stalker2\Stalker2.uproject" "-PluginPath=...\Mods\<Plugin>\<Plugin>.uplugin" `
  -TargetPlatform=Win64 -CustomConfig=ModCookNewContent -nocompile -nocompileuat `
  "-unrealexe=...\Binaries\Win64\Stalker2ModEditor-Win64-Shipping-Cmd.exe"
```

- `-CustomConfig=ModCookNewContent` is **mandatory** — without it the cook dies on a missing
  `S2_DLC1` asset-domain reference. `-TargetPlatform=Win64` (not `Windows`); full path to
  the unreal exe; editor must be closed.
- **Always grep the cook log for `Failed to translate|translation failed`** — the cook
  "succeeds" with a failed material translation and ships the checkerboard default. A ucas
  size drop vs the previous cook is the tell.
- Staged output lands in `SavedMods\Staged\<Plugin>\Windows\NewContent\...\Paks\Windows\`;
  copy pak/ucas/utoc into the game's `Stalker2\Mods\<Plugin>\Content\Paks\Windows\`.

## Materials

- **Vertex colors as data bus**: R = droop weight, G = shell sign, B = bend height,
  A = orange↔blue flame lerp. `MaterialExpressionVertexColor`'s default output is **RGB
  float3** — `ComponentMask(a)` on it passes editor recompile but **fails cook translation**
  ("Not enough components … for component mask 0001"). Use the node's dedicated `A` pin.
- Python can't wire WPO: `unreal.MaterialProperty` lacks the WPO member and the
  `Expressions` property is protected. Scripts build the graph; the final
  `Add → World Position Offset` hop is **hand-wired every time**.
- Subobject probe pattern (works where enumeration is blocked):
  `unreal.load_object(None, "<pkg>.<asset>:<ExpressionClass>_<N>")` in an index loop
  ("Failed to find object" spam is harmless), map edges with
  `MaterialEditingLibrary.get_inputs_for_material_expression`, mutate, `recompile_material`,
  `save_asset`. Preserves hand-wired pins.
- Flame material must **mirror the rag's** DroopStrength/flutter constants or the fire
  detaches from the cloth. Gravity re-point `(world_up − VertexNormalWS) × height` must be
  clamped (±0.75/axis) or an inverted tumbling bottle flings the flame ~28 cm off the mesh.
- **FP FOV seating**: GSC does foreground FOV warp _in material graphs_ —
  `MF_Foreground_FOVCorrection` (core HLSL), `MF_Foreground` (+anti-depth-clip),
  `MF_ForegroundWithShadowSwitch` (+shadow replace + MPC gate). Feed `Foreground FOV` from
  **`MPC_FOV` param `TanFOV`**, not a material FOV node (unit mismatch = floating mesh).
  Self-gating: world render has TanFOV == ViewFOV → factor 0. Opaque mats take the full
  switch; **additive** mats streak with it — use the core MF only.

## First-person rendering

- S2 uses UE 5.5 native FP rendering: `SetFirstPersonPrimitiveType(1)` = warped FP pass,
  `2` = world-space shadow twin. Unflagged comps sit at true world pos ("floating, 2× far").
  The FP pass also visually shrinks flagged prims ~⅓.
- Body-rig bones never visually match the rendered FP hands (separate authored warp). The
  only stable attach: author the pose, then `K2_AttachToComponent` to the **FP rig bone**
  KeepWorld — constant bone-local offset, perfect motion by construction.
- Swapping a grenade's FP rig to non-grenade assets (`MeshPrototypeSID` → vodka rig) = no
  hands, stuck state. Grenade AnimBPs are state-machine-coupled to the throw ability.

## UE4SS survival rules

- Crash lessons (all native AVs, `pcall` catches none):
  1. Never call UObject methods or unwrap hook params inside a physics dispatch hook.
  2. Never mass-sweep live mesh components (`FindAllOf` + property reads on subclasses).
  3. Never `LoopAsync`+`ExecuteInGameThread` per frame — hook a per-frame UFunction instead.
  4. Rapid keybind handlers must queue plain data; drain the queue inside the frame hook.
  5. `RegisterHook` from inside an async context (`ExecuteWithDelay` etc.) stores a dead
     callback ref — register from main-state context only.
- Reliable per-frame tick: HUD widget `W_UpdatedStatPanel_C:Tick`. `ReceiveTick` existing in
  reflection ≠ firing — demand proof-of-life.
- `FindAllOf` returns subclasses; skip `Default__*`. Missing-property reads return a
  `TrivialObject` sentinel that is `~= nil` — false positives everywhere.
- TArray elements are `RemoteUnrealParam` — `:get()` before `:ToString()`.
- Console-verb gold on `/Script/Stalker2.CustomConsoleManager{RK,Build,AM,AA,…}`:
  `XSpawnObjBySID`, `XCreateItemInInventoryByID`, `XApplyEffectOnNPCByUID`,
  `XTeleportNPCToPlayer`, `XForceWeather`, `XStartEmission`, ~450 total
  (see `build/exe-scan.txt`). Call the UFunctions directly on live instances.
- `DumpAllObjects()` while playing works (~0.7 s) — re-dump per session; it is the map of
  everything.

## Trade / misc

- Bartender restock = `TradeRegenHoursPassed8` (8 **game** hours) — sleep before concluding
  a trade overlay failed. `XCreateItemInInventoryByID` is the oracle for "is the prototype
  live".
- Mechanically-generated cfg text can be **silently ignored** (parse failure); hand-written
  edits parsed. Byte-surgical line edits beat regex spans.
- Achievements: the "mods disable achievements" gate is mod.io-subsystem only. UE4SS + paks
  - console verbs are below the detection floor. Never ship via the in-game mod.io browser.
