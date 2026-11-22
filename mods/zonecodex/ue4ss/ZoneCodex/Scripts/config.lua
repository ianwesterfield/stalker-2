-- ZoneCodex settings. Restart the game (or hot-reload UE4SS Lua mods) after editing.
-- The codex contents come from codex_data.lua, generated from the game's own data by
-- build-zonecodex.ps1.
return {
    -- Characters per line in the Archive tab's detail pane before wrapping.
    ArchiveDetailColumns = 72,

    -- Detail lines shown at once on the Archive tab when its scroll panel can't be built; [ and ]
    -- page the rest. Normally the details sit in a scroll panel and this goes unused.
    ArchiveDetailLines = 18,

    -- Entry rows shown at once in the Archive tab's list. Lower it if the list runs past the
    -- bottom of the PDA at your resolution.
    ArchiveRows = 10,

    -- Characters per fallback-overlay detail line before wrapping. Lower it if text runs past the
    -- right edge at your resolution; raise it if lines wrap too early.
    DetailColumns = 64,

    -- UE4SS Key name for the fallback overlay (used when the Archive tab is taken or disabled).
    Key = "E",

    -- Vertical spacing of fallback-overlay lines, in Slate units. Raise it if lines overlap.
    LineHeight = 26,

    -- UE4SS ModifierKey held with Key: CONTROL, SHIFT, ALT, or "" for none.
    -- Ctrl+E avoids function keys, which are awkward over Remote Desktop.
    Modifier = "CONTROL",

    -- How often carried counts are re-read from the active save while shown, in seconds.
    RefreshSeconds = 2,

    -- Only open the fallback overlay while the PDA is on screen, and close it with the PDA.
    -- The navigation keys reach the game too, so the PDA may react to them.
    RequirePda = true,

    -- Play the Upgrades page's tab and selection sounds on the Archive tab.
    Sounds = true,

    -- Show the codex on the PDA's unused Archive tab. ZoneCodex backs off if another mod already
    -- uses that tab; set false to use only the fallback overlay.
    UseArchiveTab = true,

    -- Lines shown at once in the fallback overlay's list and detail panes.
    VisibleRows = 16,
}
