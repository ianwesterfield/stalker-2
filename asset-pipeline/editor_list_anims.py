# List the throw/grenade animation assets so we can see what the pin-pull is
# actually made of. Read-only.
#   Stalker2ModEditor-Win64-Shipping-Cmd.exe <uproject> -run=pythonscript -script="<this>"
import unreal

AR = unreal.AssetRegistryHelpers.get_asset_registry()
ROOTS = [
    "/Game/_STALKER2/Animations/Weapons/grenades",
    "/Game/GameLite/Blueprints/Grenades",
]
AR.scan_paths_synchronous(ROOTS, force_rescan=True)

for root in ROOTS:
    assets = AR.get_assets_by_path(root, recursive=True)
    unreal.log(f"ANIMLIST root={root} count={len(assets)}")
    for a in assets:
        unreal.log(f"ANIMLIST   {a.asset_class_path.asset_name} {a.package_name}")

# player-side throw montages live under the player anim tree; find by keyword
PLAYER = "/Game/_STALKER2/Animations/Player"
AR.scan_paths_synchronous([PLAYER], force_rescan=True)
hits = []
for a in AR.get_assets_by_path(PLAYER, recursive=True):
    name = str(a.package_name).lower()
    if any(k in name for k in ("grenade", "throw", "pin")):
        hits.append(f"{a.asset_class_path.asset_name} {a.package_name}")
unreal.log(f"ANIMLIST player-throw count={len(hits)}")
for h in sorted(hits):
    unreal.log(f"ANIMLIST   {h}")

unreal.log("ANIMLIST_DONE")
