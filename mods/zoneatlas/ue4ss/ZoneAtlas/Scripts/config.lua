-- ZoneAtlas in-game settings. Restart the game (or hot-reload UE4SS Lua mods) after editing.
-- Which bundled maps the key cycles through is picked in Mod Configuration Menu 2.0
-- (ZoneAtlas page, one checkbox per map; saved with your game). Which maps are bundled,
-- and their names, is a build-time choice: mods\zoneatlas\zoneatlas.psd1, then build + deploy.
return {
    -- Name for "whatever the game shows by itself"; only offered when the build
    -- didn't bundle true vanilla (IncludeVanilla = $false in zoneatlas.psd1).
    GameDefaultName = "Game default",

    -- Label added to the PDA map's hint bar.
    HintLabel = "Map style",

    -- UE4SS Key name (F6, F8, T, N, ...). Shift + this key cycles backwards.
    Key = "F6",

    -- Ignore the hotkey unless the PDA map is on screen. Set false if the key ever
    -- seems dead on the map (the open-map check is heuristic; see UE4SS.log).
    OnlyWhenMapOpen = true,

    -- Add a "<Key> Map style" prompt to the PDA map's hint bar (clickable, like the others).
    ShowHint = true,

    -- How long the map-name toast stays up, in seconds. 0 disables it.
    ToastSeconds = 2.5,

    -- Read the cycle from Mod Configuration Menu 2.0 when it is installed. false = always
    -- cycle every bundled map.
    UseMCM = true,
}
