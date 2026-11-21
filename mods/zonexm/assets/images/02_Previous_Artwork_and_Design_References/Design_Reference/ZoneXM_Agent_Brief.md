# ZoneXM — Texture & Typography Reference

> **Implementation handoff for the coding agent** — design reference, not a request to rebuild the app. Version 2.1.

## Primary directive

Build around the **existing supplied, weathered, soundwave-cut radiation trefoil with bolted loudspeaker cone at the center**. Treat `references/brand_icon_master_512.png` as the definitive brand artwork. **Do not replace it with a clean generic radiation symbol, Wi-Fi glyph, or flat SVG.** The chipped golden-orange industrial paint, dark incised arc grooves, dented corroded rim, fasteners, oxidized steel, and speaker texture are intentional brand elements.

**Mood:** worn East European industrial equipment; wet ash, corroded metal, oil, distressed safety paint, moss-gray fog, restrained amber reflected light. Think *field equipment recovered from The Zone*, not bright gaming-neon, cyberpunk or glossy sci-fi. Original art rather than copying game titles, logos or UI.

## Font stack

| Use | Font | Weight & treatment | Fallback |
| --- | --- | --- | --- |
| Main app name & section headings | **Barlow Condensed** | 700–800; mostly uppercase for headings; tracking +0.04em to +0.06em | Segoe UI Semibold, sans-serif |
| Settings, tabs and long-form UI | **IBM Plex Sans** | 400 body / 500 labels / 600 emphasis | Segoe UI, sans-serif |
| Status telemetry, notification source IDs, activity log timestamps | **IBM Plex Mono** | 400–500; tabular numerals where appropriate | Consolas, monospace |

**Download sources:** Barlow Condensed https://fonts.google.com/specimen/Barlow+Condensed ; IBM Plex Sans and Mono https://github.com/IBM/plex . Both families are SIL Open Font License 1.1; when distributing actual font binaries with software, include their original license and copyright notices. This kit deliberately does **not** bundle font binaries. For native Windows styling, load bundled fonts only if necessary; otherwise keep fallbacks. Avoid fonts intended to imitate the copyrighted S.T.A.L.K.E.R. title logo.

### Suggested type scale at the current 764 × 732 window

- App name: **27px**, Barlow Condensed 700; preserve the displayed `ZoneXM` casing in the window title.
- Section headers: **21px**, Barlow Condensed 700, hazard amber; `WINDOWS NOTIFICATION CENTER`, `APPS`.
- Tabs: **17px**, Barlow Condensed 600, moderate tracking.
- UI body & explanatory text: **14px**, IBM Plex Sans 400, line-height **1.42**; allow text wrapping.
- Labels, checkbox text, button text: **13–14px**, IBM Plex Sans 500.
- Log rows and technical source IDs: **12px**, IBM Plex Mono 400–500, wrap long IDs; never allow horizontal overflow.
- Small hint text: **12px**, IBM Plex Sans 400. Do not crush explanatory paragraphs below 12px.

Use clean, sharp font rendering in the app. **Do not distress individual small UI letters.** Save gritty typographic erosion for large promotional/store text, and do it with a texture mask over display lettering, not a hard-to-read novelty typeface.

## Brand palette

The values below are **intentional implementation tokens inspired by the actual supplied artwork**, not claims of exact pixel matches. Backgrounds and UI text are tuned for contrast. Use `design_tokens.json` as the source of truth.

| Token | Hex | Purpose |
| --- | --- | --- |
| Canvas | `#141715` | Window backing |
| Surface | `#202421` | Primary control groups |
| Surface raised | `#282C29` | Tabs, buttons, active panels |
| Border | `#585348` | Aged metal perimeter; not a focus indicator |
| Text primary | `#F0ECE3` | Paragraphs / controls |
| Text secondary | `#BEC0B8` | Explanatory labels |
| Text muted | `#A5A9A0` | Hints (check contrast in disabled state) |
| Hazard amber | `#E6AD38` | Primary accent, active section label, selected tab |
| Amber hover | `#F2C15A` | Hover/brightened hazard accent |
| Dark amber | `#A56A1D` | Textured accents only; not normal small text |
| Corrosion | `#8B4C28` | Oxide highlights on borders and art |
| Faded olive | `#4B5142` | Muted accents, backgrounds |
| Signal cyan | `#72BDD1` | Optional **functional** notification/audio status, not general branding |
| Focus | `#FFD16C` | 2px visible keyboard focus ring |
| Danger | `#DE8B72` | Explicit warning/error states |

**Contrast rule:** preserve readable off-white text on charcoal opaque panels. Do not place full-color artwork or active rust overlays behind paragraphs. Text panels should remain at ~94% opacity even when artwork appears beneath.

## Texture recipes — included actual PNG tiles

`textures/` contains **procedurally generated 512×512 tileable texture references**. These are reusable design layers, not copies of game material assets. They visually support the higher-resolution **actual** master artwork; do not swap out the master icon for these procedural approximations.

1. **fine_grain_overlay_512.png** — grayscale translucent film grain: repeat with opacity **0.05–0.10** over larger panels, background art and marketing graphics; avoid placing on text itself.
2. **rust_patina_overlay_512.png** — orange corrosion speckle: repeat with opacity **0.10–0.20** over **decorative borders only** (top rail, badge, section dividers, frame corners); do not tint all controls brown.
3. **dark_oxidized_metal_tile_512.png** — near-black metal texture: headers / empty margins at opacity **0.18–0.35** above neutral charcoal. Avoid under dense settings copy.
4. **chipped_hazard_paint_tile_512.png** — weathered hazard yellow panel: brand plaques, rare active navigation accents, or an app splash. **Never** cover buttons, tabs, or slider tracks wholesale with high-contrast chips.
5. **paint_wear_overlay_512.png** — selective dark scratches/erosion, only for decorative elements and large display graphics; do not cover checkboxes, icons at 16px, or body text.

For web stacks, use `background-image` layered with controlled alpha and `pointer-events:none` in pseudo-elements; for native frameworks use bitmap overlay brushes/images on background/decorative layers. Rendering must remain performant when the audio/notification app runs in the system tray.

## Surface and UI details

- Keep 6–8px corner radii on top-level cards, 4–5px on buttons/inputs; slight metal inset borders rather than heavy shadows.
- Distressed surface texture on **outer shell** and **decorative borders**, restrained on interactive controls. Make main panels flat/legible.
- Use subdued amber for active tabs; reserve blue/cyan for explicit audio/notification state if needed. Do not use orange for every element.
- Slider thumb: warm amber with light focus ring; track charcoal-gray. Preserve actual user-selected ducking value semantics.
- Enabled/disabled states must remain distinguishable by visual treatment, not texture alone.
- Maintain existing focus, keyboard, screen-reader, DPI scaling, scroll behavior, and accessibility. Decorative textures are non-interactive.
- The `ZoneXM_app_background_subtle_764x732.png` in the v2 artwork pack is appropriate behind the current UI. The **cropped reference** in this kit is `references/in_app_background_reference.png`.

## Emblem preservation across surfaces

- **Store and splash**: actual master emblem, peeling gold paint, four curved soundwave grooves per trefoil blade, circular dark speaker with corroded bolted ring. Preserve placement and aspect ratio. Add weathering to scene, not to UI text.
- **Window/taskbar**: use `ZoneXM_app_textured.ico` from v2 artwork pack with multiple size-specific sources.
- **System tray**: prefer `ZoneXM_tray_textured.ico`; alternative `ZoneXM_tray_transparent.ico` if the OS taskbar contrast calls for it. Test at 16, 20, 24, 32 and 48 logical px, light and dark Windows taskbars, 100% and 150% scaling.
- **Never** redraw as a pristine trefoil, remove central speaker bolts, or flatten the textured icon into a monochrome glyph unless a separately justified accessibility mode demands it.

## Implementation notes / non-goals

Implement the style with the framework already in use. `zonexm-theme.css` is a **reference for CSS-capable UIs**, not an instruction to migrate frameworks. Do not rewrite working audio ducking, Notification Center forwarding, permissions, or system tray behavior. Keep the main window legible before adding grain; decorative assets are replaceable layers. Verify font licenses if embedding binaries in a shipped installer. Review third-party game trademarks/art usage separately from the original ZoneXM branding.

## Acceptance checklist

- [ ] App icon and Windows tray still depict the **same oxidized, screwed speaker + three weathered audio-wave blades**.
- [ ] Header type evokes industrial field equipment, body text remains easily readable at native size.
- [ ] Chipped paint/rust visible on decorative elements; no noise applied directly to small text.
- [ ] All paragraph text and checkbox labels remain legible against the charcoal UI.
- [ ] Keyboard focus, disabled controls, long app names, DPI scaling and scrollbar unchanged.
- [ ] No functional UI changes or added resource-intensive animations.
