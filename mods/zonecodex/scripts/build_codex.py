"""Generate ZoneCodex's codex_data.lua from decoded game data.

Every tab is derived from the decoded prototypes and localization. Game text is emitted as
{sid_...} localization-key templates that the mod resolves in the player's language at runtime;
the English source rides along as the fallback. That embeds vanilla game text, so the output is
written under build/ and never committed.
Usage: python build_codex.py <decoded-dir> <output-lua> [faction-icons-datatable.json]
"""

import csv
import json
import re
import sys
from pathlib import Path

LOCALIZATION_PREFIX = "ST_S2BaseGameLocalization/"
BADGE_PATH_PATTERN = re.compile(r"^(/Game/.+/([^/.]+))\.\d+$")
FACTION_NAME_PATTERN = re.compile(r"^sid_misc_answer_faction_(.+)$")
FIELD_PATTERN = re.compile(r"^([^:=\s][^:=]*?)\s*=\s*(.*?)$")
ICON_PATTERN = re.compile(r"^Texture2D'(/Game/[^']+)'$")
MUTANT_NAME_PATTERN = re.compile(r"^sid_misc_statisticspack_pda_statictics_mutant_(.+)$")
NOTE_PREFIX_PATTERN = re.compile(r"^\$[A-Z0-9]+")
STRUCT_PATTERN = re.compile(r"^(\S+) : struct\.begin(?: \{(.*)\})?$")
TAG_PATTERN = re.compile(r"<[^>]+>")
TOKEN_PATTERN = re.compile(r"\{(sid_[A-Za-z0-9_]+)\}")

# The game has no faction encyclopedia, so each faction's lore is the loading-screen tips and
# PDA location descriptions about it, curated by key; the text itself stays localization.
FACTION_LORE_KEYS = {
    "Bandits": ("sid_lscreen_Loading_screen_25_desc", "sid_locations_region_garbage_desc"),
    "Corpus": (
        "sid_locations_region_yanov_desc",
        "sid_locations_hub_yanov_desc",
        "sid_locations_hub_enerhetyk_desc",
        "sid_locations_region_prypiat_desc",
    ),
    "Duty": (
        "sid_lscreen_Loading_screen_24_desc",
        "sid_locations_region_cement_factory_desc",
        "sid_locations_hub_concreteplant_desc",
    ),
    "Freedom": (
        "sid_lscreen_Loading_screen_23_desc",
        "sid_lscreen_Loading_screen_01_desc",
        "sid_locations_region_rostok_desc",
        "sid_locations_hub_rostok_desc",
    ),
    "Mercenaries": ("sid_lscreen_Loading_screen_17_desc",),
    "Militaries": ("sid_lscreen_Loading_screen_22_desc", "sid_lscreen_Loading_screen_14_desc"),
    "Monolith": ("sid_lscreen_Loading_screen_20_desc",),
    "Neutrals": ("sid_lscreen_Loading_screen_26_desc",),
    "Noon": (
        "sid_lscreen_Loading_screen_19_desc",
        "sid_locations_hub_asulym_desc",
        "sid_locations_region_wild_island_desc",
    ),
    "Scientists": (
        "sid_lscreen_Loading_screen_27_desc",
        "sid_lscreen_advicespack_Loading_screen_88_desc",
        "sid_lscreen_advicespack_Loading_screen_89_desc",
        "sid_locations_region_malachite_desc",
        "sid_locations_hub_malahit_desc",
        "sid_locations_region_sircaa_desc",
    ),
    "Spark": ("sid_lscreen_Loading_screen_21_desc", "sid_locations_region_chemical_plant_desc"),
    "Varta": (
        "sid_lscreen_Loading_screen_16_desc",
        "sid_locations_hub_chemplant_desc",
        "sid_locations_hub_ikar_desc",
    ),
}

# Statistics renders the game ships but no decoded prototype references, keyed by PDA mutant id.
# The amok is the DLC's Object68 (Statistics.cfg lists Object68 in the amok's slot), and its
# prototypes live in DLC data the extraction doesn't decode.
MUTANT_RENDER_OVERRIDES = {
    "amok": (
        "/Game/GameLite/FPS_Game/UIRemaster/UITextures/PDA/Stats/Mutants/big/"
        "T_Object68_statisticbig.T_Object68_statisticbig"
    ),
    "jadedchimera": (
        "/Game/GameLite/FPS_Game/UIRemaster/UITextures/PDA/Stats/Mutants/big/"
        "T_Chimera_Jaded_statisticbig.T_Chimera_Jaded_statisticbig"
    ),
}

# RelationLevelRanges follow ERelationLevel order; the trailing Self range is never a stance.
# Each level pairs with its sid_misc_Faction_<label>_Name localization key.
RELATION_LEVELS = (("Enemy", "Enemy"), ("Disaffection", "Dislike"), ("Neutral", "Neutral"), ("Friend", "Friend"))


def warn(message):
    print(f"warning: {message}", file=sys.stderr)


def parse_config(text):
    """Parse a decoded .cfg into nested nodes of ordered (key, scalar-or-node) children."""
    root = {"attributes": {}, "children": []}
    stack = [root]

    for line_number, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()

        if not stripped or stripped.startswith("//"):
            continue

        if stripped == "struct.end":
            if len(stack) == 1:
                raise ValueError(f"line {line_number}: struct.end without struct.begin")

            stack.pop()
            continue

        struct = STRUCT_PATTERN.match(stripped)

        if struct:
            attributes = {}

            for part in (struct.group(2) or "").split(";"):
                if "=" in part:
                    key, value = part.split("=", 1)
                    attributes[key.strip()] = value.strip()

            node = {"attributes": attributes, "children": []}
            stack[-1]["children"].append((struct.group(1), node))
            stack.append(node)
            continue

        field = FIELD_PATTERN.match(stripped)

        if field:
            stack[-1]["children"].append((field.group(1), field.group(2)))

    if len(stack) != 1:
        raise ValueError("unterminated struct at end of file")

    return root


def scalars(node):
    return {key: value for key, value in node["children"] if isinstance(value, str)}


def child_node(node, name):
    return next((value for key, value in node["children"] if key == name and isinstance(value, dict)), None)


def prototypes_from(root):
    """Top-level prototypes: scalar fields, indexed scalar lists, and the in-file refkey."""
    prototypes = {}

    for sid, node in root["children"]:
        if not isinstance(node, dict):
            continue

        lists = {
            name: [value for key, value in child["children"] if key.startswith("[") and isinstance(value, str)]
            for name, child in node["children"]
            if isinstance(child, dict)
        }
        prototypes[sid] = {"fields": scalars(node), "lists": lists, "refkey": node["attributes"].get("refkey")}

    return prototypes


def parse_prototypes(path):
    return prototypes_from(parse_config(path.read_text(encoding="utf-8-sig")))


def resolve(prototypes, sid, seen=None):
    """Merge a prototype with its in-file refkey ancestors (child wins)."""
    seen = seen or set()

    if sid in seen:
        raise ValueError(f"refkey cycle at {sid}")

    seen.add(sid)
    prototype = prototypes[sid]
    parent = prototype["refkey"]
    merged = {"fields": {}, "lists": {}}

    # refkey=[0] points at the defaults of another file, which carry no codex data.
    if parent and parent in prototypes:
        merged = resolve(prototypes, parent, seen)

    merged = {"fields": dict(merged["fields"]), "lists": dict(merged["lists"])}
    merged["fields"].update(prototype["fields"])
    merged["lists"].update(prototype["lists"])
    return merged


def load_localization(path):
    texts = {}

    with path.open(encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle):
            key = row["key"]

            if key.startswith(LOCALIZATION_PREFIX):
                texts[key[len(LOCALIZATION_PREFIX):]] = row["source"]

    return texts


def clean_text(text):
    text = NOTE_PREFIX_PATTERN.sub("", text)
    text = text.replace("<input>", "[key]")
    text = TAG_PATTERN.sub("", text)
    text = text.replace("\r\n", "\n")
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def ref(key):
    """A template token the mod replaces with the key's text in the player's language."""
    if not TOKEN_PATTERN.fullmatch(f"{{{key}}}"):
        raise ValueError(f"localization key {key!r} can't be a template token")

    return f"{{{key}}}"


def english(template, texts):
    """A template expanded with the English source, as the fallback and build-time sort key."""
    return TOKEN_PATTERN.sub(lambda match: clean_text(texts.get(match.group(1), "")), template)


def enum_label(value):
    label = value.split("::")[-1] if value else ""
    return re.sub(r"(?<=[a-z])(?=[A-Z])", " ", label)


def number_label(value):
    number = float(value)
    return f"{number:,.0f}" if number == int(number) else f"{number:g}"


def entry(entry_id, name, description="", sids=None, facts=None, bullets=None, icon="", detail_icon="", image=""):
    """A codex entry. icon is the list texture, detail_icon the detail header's ("" reuses icon),
    and image a large detail picture ("" for none)."""
    return {
        "bullets": bullets or [],
        "description": description,
        "detailIcon": detail_icon,
        "facts": facts or [],
        "icon": icon,
        "id": entry_id,
        "image": image,
        "name": name,
        "sids": sids or [],
    }


def effect_lines(item, effects, texts):
    lines = []
    visible = item["lists"].get("ShouldShowEffects", [])

    for index, effect_sid in enumerate(item["lists"].get("EffectPrototypeSIDs", [])):
        if index < len(visible) and visible[index] != "true":
            continue

        if effect_sid not in effects:
            raise ValueError(f"unknown effect {effect_sid}")

        effect = effects[effect_sid]["fields"]
        candidates = [effect_sid, effect.get("LocalizationSID"), effect.get("Text")]
        name_key = next(
            (f"sid_effects_{sid}_name" for sid in candidates if sid and f"sid_effects_{sid}_name" in texts),
            None,
        )

        if not name_key:
            continue

        sign = "-" if effect.get("Positive") == "EBeneficial::Negative" else "+"
        level = enum_label(effect.get("EffectLevel", ""))
        lines.append(f"{sign} {ref(name_key)}" + (f" ({level})" if level and level != "None" else ""))

    return lines


def icon_path(fields):
    """The inventory texture object path; placeholder sprites and missing icons yield ""."""
    match = ICON_PATTERN.fullmatch(fields.get("Icon", ""))
    return match.group(1) if match else ""


def item_facts(fields):
    facts = []

    if fields.get("Type") == "EItemType::Artifact":
        facts.append(["Rarity", enum_label(fields.get("Rarity", "EArtifactRarity::Common"))])
        facts.append(["Anomaly", enum_label(fields.get("AnomalyElementType", "None"))])

        if fields.get("ArchiartifactType", "EArchiartifactType::None") != "EArchiartifactType::None":
            facts.append(["Class", "Archiartifact"])

    consumable_type = enum_label(fields.get("ConsumableType", ""))

    if consumable_type and consumable_type != "None":
        facts.append(["Kind", consumable_type])

    if "Cost" in fields and float(fields["Cost"]) > 0:
        facts.append(["Value", number_label(fields["Cost"]) + " coupons"])

    if "Weight" in fields:
        facts.append(["Weight", number_label(fields["Weight"]) + " kg"])

    return facts


def localized_items(prototypes, texts, item_type, exclude=lambda fields: False):
    """Concrete items of one type grouped by LocalizationSID, the unit the game names and describes."""
    grouped = {}

    for sid in prototypes:
        # Template prototypes are abstract bases (TemplateArtifact, MutantLootTemplate, ...).
        if "Template" in sid:
            continue

        resolved = resolve(prototypes, sid)
        fields = resolved["fields"]

        if fields.get("Type") != item_type or exclude(fields):
            continue

        localization_sid = fields.get("LocalizationSID", sid)
        name_key = f"sid_items_{localization_sid}_name"
        description_key = f"sid_items_{localization_sid}_description"

        if not texts.get(name_key):
            continue

        group = grouped.get(localization_sid)

        if group:
            group["sids"].append(sid)

            # The prototype named after its localization is the canonical one.
            if sid == localization_sid:
                group["resolved"] = resolved

            continue

        grouped[localization_sid] = {
            "description": ref(description_key) if texts.get(description_key) else "",
            "id": localization_sid,
            "name": ref(name_key),
            "resolved": resolved,
            "sids": [sid],
        }

    return list(grouped.values())


def by_name(entries, texts):
    return sorted(entries, key=lambda item: english(item["name"], texts).casefold())


def item_entries(prototypes, effects, texts, item_type, exclude=lambda fields: False):
    return by_name(
        (
            entry(
                item["id"],
                item["name"],
                item["description"],
                item["sids"],
                item_facts(item["resolved"]["fields"]),
                effect_lines(item["resolved"], effects, texts),
                icon_path(item["resolved"]["fields"]),
            )
            for item in localized_items(prototypes, texts, item_type, exclude)
        ),
        texts,
    )


def mutant_renders(objects):
    """Statistics-page creature render per mutant NameSID; the first prototype naming it wins."""
    renders = {}

    for prototype in objects.values():
        fields = prototype["fields"]
        name_key = fields.get("NameSID", "")
        render_path = icon_path(fields)

        if MUTANT_NAME_PATTERN.match(name_key) and render_path and name_key not in renders:
            renders[name_key] = render_path

    for mutant_id, texture in MUTANT_RENDER_OVERRIDES.items():
        renders.setdefault(f"sid_misc_statisticspack_pda_statictics_mutant_{mutant_id}", texture)

    return renders


def mutant_entries(prototypes, texts, renders=None):
    """PDA statistics mutants, each linked to its trophy item by SID or localized-name stem.

    The list and detail picture are the creature's statistics render; the trophy's icon heads the
    detail, since the trophy is what the mutant yields."""
    renders = renders or {}
    trophies = localized_items(prototypes, texts, "EItemType::MutantLoot")

    for trophy in trophies:
        trophy["keys"] = {trophy["id"].rsplit("MutantPart", 1)[-1].casefold()}
        trophy["keys"].update(sid.removesuffix("Loot").casefold() for sid in trophy["sids"])

    entries = []
    matched_ids = set()

    for key, value in texts.items():
        match = MUTANT_NAME_PATTERN.match(key)

        if not match:
            continue

        render_path = renders.get(key, "")

        if not render_path:
            warn(f"mutant {match.group(1)} has no statistics render; its list shows the trophy icon")

        name = clean_text(value)
        keys = {match.group(1).casefold(), name.replace(" ", "").casefold()}
        linked = [trophy for trophy in trophies if trophy["keys"] & keys]

        if not linked:
            facts = [["Trophy", "None listed in game data"]]
            entries.append(entry(match.group(1), ref(key), facts=facts, icon=render_path, image=render_path))
            continue

        trophy = linked[0]

        if len(linked) > 1:
            warn(f"mutant {match.group(1)} matches several trophies; using {trophy['id']}")

        matched_ids.add(trophy["id"])
        facts = [["Trophy", trophy["name"]]]
        trophy_facts = item_facts(trophy["resolved"]["fields"])
        facts.extend([f"Trophy {label.casefold()}", fact_value] for label, fact_value in trophy_facts)
        trophy_icon = icon_path(trophy["resolved"]["fields"])
        entries.append(
            entry(
                match.group(1),
                ref(key),
                trophy["description"],
                trophy["sids"],
                facts,
                icon=render_path or trophy_icon,
                detail_icon=trophy_icon,
                image=render_path,
            )
        )

    for trophy in trophies:
        if trophy["id"] not in matched_ids:
            warn(f"trophy {trophy['id']} matches no PDA statistics mutant")

    return by_name(entries, texts)


def lineage(faction, hierarchy):
    chain = []

    while faction:
        if faction in chain:
            raise ValueError(f"faction hierarchy cycle at {faction}")

        chain.append(faction)
        faction = hierarchy.get(faction)

    return chain


def faction_badges(table_path):
    """Faction id -> PDA badge texture from the game's FactionIconsDataTable export ({} if absent)."""
    if not table_path or not Path(table_path).is_file():
        warn("FactionIconsDataTable export not found; factions show no badges")
        return {}

    exported = json.loads(Path(table_path).read_text(encoding="utf-8"))
    rows = next((item["Rows"] for item in exported if isinstance(item, dict) and "Rows" in item), {})
    badges = {}

    for faction_id, row in rows.items():
        # Exports name the asset "<path>.0"; Unreal loads "<path>.<asset name>".
        match = BADGE_PATH_PATTERN.fullmatch(row.get("Texture", {}).get("ObjectPath", ""))

        if match:
            badges[faction_id] = f"{match.group(1)}.{match.group(2)}"

    return badges


def faction_entries(root, texts, badges=None):
    """Localized factions with their default standings, from the relation table's Factions/Relations."""
    badges = badges or {}
    relation_node = next(
        (node for _, node in root["children"] if isinstance(node, dict) and child_node(node, "Relations")),
        None,
    )

    if not relation_node:
        raise ValueError("no relation prototype with a Relations table")

    hierarchy = scalars(child_node(relation_node, "Factions"))
    relations = {}

    for key, value in scalars(child_node(relation_node, "Relations")).items():
        first, second = key.split("<->")
        relations[(first, second)] = relations[(second, first)] = int(value)

    ranges = [
        (int(scalars(node)["start"]), int(scalars(node)["end"]))
        for key, node in child_node(relation_node, "RelationLevelRanges")["children"]
        if isinstance(node, dict)
    ]

    if len(ranges) < len(RELATION_LEVELS):
        raise ValueError("RelationLevelRanges has fewer ranges than relation levels")

    def standing(first, second):
        """Nearest explicit relation, walking both factions' parent chains."""
        for first_ancestor in lineage(first, hierarchy):
            for second_ancestor in lineage(second, hierarchy):
                value = relations.get((first_ancestor, second_ancestor))

                if value is not None:
                    for (start, end), (_, label_key) in zip(ranges, RELATION_LEVELS):
                        if start <= value <= end:
                            return ref(f"sid_misc_Faction_{label_key}_Name")

                    raise ValueError(f"relation {first}<->{second} = {value} is outside every stance range")

        return None

    factions = {}

    for key in texts:
        match = FACTION_NAME_PATTERN.match(key)

        if not match:
            continue

        if match.group(1) not in hierarchy:
            warn(f"localized faction {match.group(1)} is missing from the relation hierarchy")
            continue

        factions[match.group(1)] = ref(key)

    entries = []

    for faction_id, name in factions.items():
        facts = []
        player_standing = standing(faction_id, "Player")

        if player_standing:
            facts.append(["Starting standing", player_standing])

        bullets = []

        for other_id, other_name in sorted(factions.items(), key=lambda pair: english(pair[1], texts).casefold()):
            other_standing = standing(faction_id, other_id) if other_id != faction_id else None

            if other_standing:
                bullets.append(f"{other_name}: {other_standing}")

        lore = faction_lore(faction_id, texts)
        badge = badges.get(faction_id, badges.get("Default", ""))

        if badges and faction_id not in badges:
            warn(f"faction {faction_id} has no badge row; using the default badge")

        entries.append(entry(faction_id, name, lore, facts=facts, bullets=bullets, icon=badge))

    for faction_id in FACTION_LORE_KEYS.keys() - factions.keys():
        warn(f"faction lore for {faction_id} has no localized faction")

    return by_name(entries, texts)


def faction_lore(faction_id, texts):
    """The faction's curated lore passages as one template, paragraph per present, distinct passage."""
    passages = []
    seen = set()

    for key in FACTION_LORE_KEYS.get(faction_id, ()):
        text = clean_text(texts.get(key, ""))

        if not text:
            warn(f"faction lore key {key} for {faction_id} is missing from localization")
            continue

        if text not in seen:
            seen.add(text)
            passages.append(ref(key))

    if not passages:
        warn(f"faction {faction_id} has no lore passages")

    return "\n\n".join(passages)


def lua_string(value):
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("\r", "").replace("\n", "\\n")
    return f'"{escaped}"'


def lua_list(values):
    return "{ " + ", ".join(values) + " }" if values else "{}"


def lua_entry(item):
    facts = [f"{{ {lua_string(label)}, {lua_string(value)} }}" for label, value in item["facts"]]
    return (
        "            {\n"
        f"                bullets = {lua_list([lua_string(line) for line in item['bullets']])},\n"
        f"                description = {lua_string(item['description'])},\n"
        f"                detailIcon = {lua_string(item['detailIcon'])},\n"
        f"                facts = {lua_list(facts)},\n"
        f"                icon = {lua_string(item['icon'])},\n"
        f"                id = {lua_string(item['id'])},\n"
        f"                image = {lua_string(item['image'])},\n"
        f"                name = {lua_string(item['name'])},\n"
        f"                sids = {lua_list([lua_string(sid) for sid in item['sids']])},\n"
        "            },\n"
    )


def template_keys(tabs):
    """Every localization key the tabs' templates reference."""
    templates = []

    for codex_tab in tabs:
        templates.extend([codex_tab["title"], codex_tab["bulletsTitle"]])

        for item in codex_tab["entries"]:
            templates.extend([item["name"], item["description"], *item["bullets"]])
            templates.extend(part for fact in item["facts"] for part in fact)

    return sorted({key for template in templates for key in TOKEN_PATTERN.findall(template)})


def render(tabs, texts):
    parts = [
        "-- Generated by mods/zonecodex/scripts/build_codex.py from decoded game data. Do not edit.\n",
        "return {\n",
        "    -- English fallbacks for the {sid_...} templates, used when the game can't localize a key.\n",
        "    fallbacks = {\n",
    ]

    for key in template_keys(tabs):
        parts.append(f"        [{lua_string(key)}] = {lua_string(clean_text(texts.get(key, '')))},\n")

    parts.append("    },\n")
    parts.append("    tabs = {\n")

    for codex_tab in tabs:
        parts.append("        {\n")
        parts.append(f"            bulletsTitle = {lua_string(codex_tab['bulletsTitle'])},\n")
        parts.append(f"            descriptionFirst = {'true' if codex_tab['descriptionFirst'] else 'false'},\n")
        parts.append(f"            id = {lua_string(codex_tab['id'])},\n")
        parts.append(f"            maskIcons = {'true' if codex_tab['maskIcons'] else 'false'},\n")
        parts.append(f"            title = {lua_string(codex_tab['title'])},\n")
        parts.append(f"            tracksInventory = {'true' if codex_tab['tracksInventory'] else 'false'},\n")
        parts.append("            entries = {\n")
        parts.extend(lua_entry(item) for item in codex_tab["entries"])
        parts.append("            },\n")
        parts.append("        },\n")

    parts.append("    },\n")
    parts.append("}\n")
    return "".join(parts)


def tab(tab_id, title, entries, bullets_title="", tracks_inventory=False, description_first=False, mask_icons=False):
    """mask_icons marks white-mask icons (faction badges) the page must tint to be visible."""
    if not entries:
        raise ValueError(f"no entries generated for {title}; is the decoded data complete?")

    return {
        "bulletsTitle": bullets_title,
        "descriptionFirst": description_first,
        "entries": entries,
        "id": tab_id,
        "maskIcons": mask_icons,
        "title": title,
        "tracksInventory": tracks_inventory,
    }


def build(decoded_directory, faction_icons_path=None):
    texts = load_localization(decoded_directory / "Game.en.csv")
    items = parse_prototypes(decoded_directory / "ItemPrototypes.cfg")
    objects = parse_prototypes(decoded_directory / "ObjPrototypes.cfg")
    raw_effects = parse_prototypes(decoded_directory / "EffectPrototypes.cfg")
    effects = {sid: resolve(raw_effects, sid) for sid in raw_effects}
    relations = parse_config((decoded_directory / "RelationPrototypes.cfg").read_text(encoding="utf-8-sig"))
    is_fake_artifact = lambda fields: fields.get("ArtifactType") == "EArtifactType::Fake"

    tabs = [
        tab(
            "artifacts",
            "Artifacts",
            item_entries(items, effects, texts, "EItemType::Artifact", is_fake_artifact),
            "Effects",
            True,
        ),
        tab("consumables", "Consumables", item_entries(items, effects, texts, "EItemType::Consumable"), "Effects", True),
        tab("mutants", "Mutants", mutant_entries(items, texts, mutant_renders(objects)), tracks_inventory=True),
        tab(
            "factions",
            "Factions",
            faction_entries(relations, texts, faction_badges(faction_icons_path)),
            "Stance toward others",
            description_first=True,
            mask_icons=True,
        ),
    ]
    return tabs, texts


def main():
    if len(sys.argv) not in (3, 4):
        raise SystemExit(__doc__)

    faction_icons_path = Path(sys.argv[3]) if len(sys.argv) == 4 else None
    tabs, texts = build(Path(sys.argv[1]), faction_icons_path)
    output = Path(sys.argv[2])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render(tabs, texts), encoding="utf-8", newline="\n")

    for codex_tab in tabs:
        print(f"{codex_tab['title']}: {len(codex_tab['entries'])} entries")

    print(f"wrote {output}")


if __name__ == "__main__":
    main()
