# ZoneXM Companion privacy policy

_Last updated: November 13, 2026_

ZoneXM Companion ("the app") is a free Windows helper for the ZoneXM game mod. This policy
explains what the app accesses and what it does with it.

## Summary

- The app works entirely on your PC. It has **no network code**: it sends nothing to the
  developer or anyone else, and contains no analytics, telemetry, advertising or crash reporting.
- No data is sent to the developer, sold, or shared over the network. The app processes
  data locally and temporarily shares selected notification text with the game mod as described below.

## What the app accesses

**Notifications (only with your permission).** Windows asks you to allow notification access
before the app can read notifications. This permission exposes Notification Center entries broadly;
forwarding is opt-in per app, and no apps are selected by default. For apps you select,
the app forwards a new notification's app name, title and body
and writes them to a local file so the game mod can show them as an in-game banner. Notifications
from unselected apps are not forwarded. You can revoke access at any time in
**Windows Settings > Privacy & security > Notifications**.

**Audio sessions.** To lower ("duck") other apps' volume while the game needs your attention, the
app reads and changes the per-app volume of audio sessions on your PC, then restores them. It does
not record or listen to audio.

## What is stored, and where

Current files live in `%USERPROFILE%\ZoneXM` on your PC. This is a user-owned shared
folder outside AppData; the app does not request the `unvirtualizedResources` capability
or disable Windows' file virtualization.

| File                   | Contents                                                                     | Kept                                                 |
| ---------------------- | ---------------------------------------------------------------------------- | ---------------------------------------------------- |
| `helper-settings.json` | Duck level and the IDs of apps you opted in                                  | Until you change or delete it                        |
| `notification.txt`     | The latest forwarded notification (app name, title, body) for the game       | Overwritten; cleared on expiry, pause or normal exit |
| `alert.flag`           | Written by the game mod while ducking is needed; no personal data            | Refreshed while the game runs                        |
| `subtitle-style.txt`   | Written by the game mod: subtitle font and colour settings; no personal data | Until deleted                                        |

The in-app activity log is kept in memory only, never includes notification titles or bodies, and
is discarded when the app closes.

The shared notification file is plaintext, not encrypted. Other programs running as your Windows
account can read it, and people watching your screen or stream can see in-game banners. A crash or
forced termination can leave an expired file behind; the game ignores stale entries. Original
Windows notifications are never modified or dismissed by the app.

The shared folder is not removed when the app is uninstalled.
Delete `%USERPROFILE%\ZoneXM` to remove its files.

Versions before Companion 1.3.1 used `%LOCALAPPDATA%\ZoneXM`. On first use of the new
folder, the app imports an existing valid `helper-settings.json` only if no new settings
file exists. This preserves the duck level and exactly the apps you previously opted in;
it does not import notification text, alert flags, media snapshots, or logs. Invalid old
settings are reported rather than silently treated as consent. The old folder is left
untouched; you can delete it separately after updating both the companion and game mod.

## Children

The app does not knowingly collect information from anyone, including children.

## Changes

Updates to this policy are published at this page with a new "Last updated" date.

## Contact

Open an issue at <https://github.com/ianwesterfield/stalker-2/issues>.
