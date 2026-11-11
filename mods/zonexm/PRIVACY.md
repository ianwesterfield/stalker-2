# ZoneXM Companion privacy policy

_Last updated: November 11, 2026_

ZoneXM Companion ("the app") is a free Windows helper for the ZoneXM game mod. This policy
explains what the app accesses and what it does with it.

## Summary

- The app works entirely on your PC. It has **no network code**: it sends nothing to the
  developer or anyone else, and contains no analytics, telemetry, advertising or crash reporting.
- Nothing is collected, sold or shared.

## What the app accesses

**Notifications (only with your permission).** Windows asks you to allow notification access
before the app can read anything. Forwarding is opt-in per app, and no apps are selected by
default. For apps you select, the app reads the newest notification's app name, title and body
and writes them to a local file so the game mod can show them as an in-game banner. Notifications
from unselected apps are not forwarded. You can revoke access at any time in
**Windows Settings > Privacy & security > Notifications**.

**Audio sessions.** To lower ("duck") other apps' volume while the game needs your attention, the
app reads and changes the per-app volume of audio sessions on your PC, then restores them. It does
not record or listen to audio.

## What is stored, and where

All files live in `%LOCALAPPDATA%\ZoneXM` on your PC:

| File                   | Contents                                                                 | Kept                                                     |
| ---------------------- | ------------------------------------------------------------------------ | -------------------------------------------------------- |
| `helper-settings.json` | Duck level and the IDs of apps you opted in                              | Until you change or delete it                            |
| `notification.txt`     | The latest forwarded notification (app name, title, body) for the game   | Overwritten by the next one; cleared on pause or exit    |
| `alert.flag`           | Written by the game mod while ducking is needed; no personal data        | Refreshed while the game runs                            |
| `subtitle-style.txt`   | Written by the game mod: subtitle font and colour settings; no personal data | Until deleted                                        |

The in-app activity log is kept in memory only, never includes notification titles or bodies, and
is discarded when the app closes.

Because the game mod must read these files, Windows keeps the folder when the app is uninstalled.
Delete `%LOCALAPPDATA%\ZoneXM` to remove everything.

## Children

The app does not knowingly collect information from anyone, including children.

## Changes

Updates to this policy are published at this page with a new "Last updated" date.

## Contact

Open an issue at <https://github.com/ianwesterfield/stalker-2/issues>.
