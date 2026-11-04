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
- **New quests never register** — only new _nodes_ do. Don't ship a `QuestPrototypes` file.
- Node fields are `ItemSID` / `ItemsCount`. The names `ItemPrototypeSID` / `ItemsCount` appear
  only _inside_ `Conditions`, where values are wrapped as
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

- Verified scheduling contract for installed commit `5e627997` (2026-11-03):
  `LoopAsync` and `ExecuteWithDelay` run asynchronously. UObject reads and mutations
  belong on the game thread. MolotovFire and ZoneXM now use
  `LoopInGameThreadWithDelay`; MolotovFire retries use `ExecuteInGameThreadWithDelay`.
  These APIs already exist in the installed DLL's source; no DLL upgrade was made.
  The local configuration selects `EngineTick` as the default scheduling method.
  Source: [LuaMod.cpp at the installed commit](https://github.com/UE4SS-RE/RE-UE4SS/blob/5e627997bf265ae6fc89d23357543d8c8ac05a6f/UE4SS/src/Mod/LuaMod.cpp).
- Important API difference: native repeating timers in this commit **ignore callback
  return values** (`call_function(0, 0)`). Stop them with `CancelDelayedAction(handle)`,
  not `return true`. The native timer retains its callback through a Lua registry
  reference. Callback count alone does not establish a dangling reference or GC bug.
- `pcall` catches Lua errors, not native access violations. Use `wrapper:IsValid()`;
  there is no global `IsValid` in this build. Validity is not ownership and does not
  guarantee that a component is still part of the current equip. Do not treat either
  address lookup or validity checking as a lifetime guarantee.
- Delayed rag physics/fire jobs carry an equip generation. Douse/restore invalidates
  pending jobs before they touch captured objects. Jobs also verify the held item and
  that the mesh's current animation instance still matches. Montage state resets on
  cleanup/new fire; a global "done" latch must not suppress the other montage.
- Keep physics-hook work minimal (OnHit records an impact for the tracker), and defer
  keybind-driven UObject work. Keep notification state-machine suppression disabled:
  a native crash was observed while calling those methods during animated banners.
- Crash `50ACE194...` occurred at 546 seconds, reading `0x0000023f26d754f9`, with UE4SS
  stack offsets beginning `c71b00`, `c7274f`, `c63fae`. This does **not** identify the
  responsible Lua callback, prove NotifyOnNewObject was involved, or prove that
  callback volume caused the crash. The preserved log is `UE4SS-investigation.log`
  alongside that crash report. In-game verification is still required.
- Exact symbolication needs a matching PDB: installed DLL identity is
  `{21AD178D-4639-470E-971E-F115B4924854}`, age 21. The stable and experimental PDBs
  previously checked did not match. Nearest-export offsets are not function boundaries;
  earlier claims that `c6xxxx` means generated trampolines were not established.
- Regression checks: from this repo, run `lua54 tools/test-ue4ss.lua .` with Lua 5.4.
  Tests load the real mod scripts with mocked UE4SS APIs and check timer registration,
  cancellation, cleanup, animation ownership, and thread confinement. They do not
  exercise native UObject lifetimes, physics, or prove the game cannot crash.
- Player damage feedback is keyed engine-side to the damage **event**, not to the effect
  prototype. Burn pulls the fire roar + `BurnDamageEffectProcessor` red screen edges; re-typing
  to Strike merely swaps in that type's feedback (hit vignette plus a pain grunt that reads as
  chewing once it repeats on a timer). For a drain with _no_ reaction, leave the damage
  pipeline entirely: `Obj:ForceSetHP(int32)` writes HP straight in. Mind the asymmetry —
  `CppMediator:ObjGetHP` returns float while `ForceSetHP` takes int32, so sub-point ticks have
  to bank up and land as whole points. Siblings: `ForceSetBleeding`,
  `ForceSetCurrentHungerPoints`. (`XDealDamage` is a dead end on the player: `GetGUID(pawn)`
  reads 0.)
- **A game patch kills UE4SS itself**, not just a mod. GSC recompiles shift register
  allocation without changing the code, the vendored AOB patterns miss, and a missed
  `GUObjectArray` is fatal — UE4SS aborts and every Lua mod silently stops existing. Symptom
  2026-10-26: rag fire, impact detonation and rag physics all vanished at once while
  `Stalker2.log` stayed clean; the tell is `Fatal Error: ... scan timed out` in
  `Binaries/Win64/ue4ss/UE4SS.log`. Fix: [tools/find_guobjectarray.py](../tools/find_guobjectarray.py)
  re-derives the pattern from the installed exe, and `deploy-ue4ss.ps1` now runs it every
  deploy. It locates the array by _structure_, not bytes — the inlined bounds check always
  pairs a RIP-relative `cmp [NumElements], reg` with a RIP-relative `mov r64, [Objects]` whose
  targets sit exactly `0x14` apart (`FUObjectArray` +0x24 vs +0x10), so
  `GUObjectArray = target(mov) - 0x10`. A pattern need not be _unique_, only unambiguous: 773
  matches all resolving to one address is the proof. Also delete the vendored
  `ProcessLocalScriptFunction.lua` — its miss is equally fatal, while UE4SS's built-in scan
  covers it and the only casualty is creating custom UFunctions/events for BPs.
- Don't hand-extend a byte pattern past a known instruction: a byte-walk can't tell opcodes
  from operands (`C1 E8 10`, `shr eax,0x10`, reads as a `call rel32` and silently corrupts the
  pattern). Stop at an anchor you decoded deliberately.
- HUD widget `W_UpdatedStatPanel_C:Tick` has registered without firing on some patches.
  Reflection presence and successful hook registration are not proof of execution.
- `FindAllOf` returns subclasses; skip `Default__*`. Missing-property reads return a
  `TrivialObject` sentinel that is `~= nil` — false positives everywhere.
- **Injecting into the inventory right-click menu** (probe series 2026-11-01/02):
  `W_RightClickMenu_C` is constructed per-open (currently discovered by polling), its `Menu`
  is a plain `VerticalBox`, and `MenuItemWidgetClass` + `WidgetBlueprintLibrary:Create` +
  `AddChild` renders a genuine styled row (copy `TextColor*` field-by-field — assigning a Lua
  table over a struct property silently no-ops). BUT the game binds row button delegates
  natively only for rows IT creates during population: a spawned row's
  `OnButtonClick/Hovered` never fire and Lua cannot `AddDynamic`. Own the click instead:
  `row:IsHovered()` is a callable native UFunction — gate an `LMB` keybind
  (`Key.LEFT_MOUSE_BUTTON` works) on it. Keep the keybind body a plain-field nil-check;
  it fires on every trigger pull in combat.
- Reflection dumps of BP widgets walk ONLY the leaf class by default — `ForEachProperty` on
  `GetClass()` misses every native-base property (that's where `ItemImage`, `SlotIndex` live).
  Walk `GetSuperStruct()` up the chain. Struct params with no usmap coverage expose no field
  names to Lua at all; brute-forcing names and `RegisterCustomProperty` by offset both failed
  on `RightClickMenuItemData` — item identity via the menu stayed unsolved (icon brush reads
  nil on the `W_Image_C` wrapper; the real texture sits deeper in its widget tree).
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
