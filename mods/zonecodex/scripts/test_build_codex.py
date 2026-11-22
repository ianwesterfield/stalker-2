import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import build_codex

ITEMS = """
TemplateArtifact : struct.begin
   Type = EItemType::Artifact
   Rarity = EArtifactRarity::Common
   Cost = 100.0
   Icon = PaperSprite'/Game/GameLite/FPS_Game/UI/ItemIcons/Placeholder.Placeholder'
struct.end
Shell : struct.begin {refkey=TemplateArtifact}
   Rarity = EArtifactRarity::Rare
   Icon = Texture2D'/Game/Inventory/T_inv_shell.T_inv_shell'
   EffectPrototypeSIDs : struct.begin
      [0] = Hidden
      [1] = Shown
   struct.end
   ShouldShowEffects : struct.begin
      [0] = false
      [1] = true
   struct.end
struct.end
ShellVariant : struct.begin {refkey=Shell}
   LocalizationSID = Shell
struct.end
FakeShell : struct.begin {refkey=Shell}
   ArtifactType = EArtifactType::Fake
   LocalizationSID = FakeShell
struct.end
MutantLootTemplate : struct.begin
   Type = EItemType::MutantLoot
struct.end
DeerLoot : struct.begin {refkey=MutantLootTemplate}
   LocalizationSID = mutpartspack_MutantPartHornhead
   Cost = 14000.0
   Icon = Texture2D'/Game/Inventory/T_inv_horn.T_inv_horn'
struct.end
"""

OBJECTS = """
Deer : struct.begin
   NameSID = sid_misc_statisticspack_pda_statictics_mutant_deer
   Icon = Texture2D'/Game/Stats/T_Deer_statisticbig.T_Deer_statisticbig'
struct.end
DeerVariant : struct.begin
   NameSID = sid_misc_statisticspack_pda_statictics_mutant_deer
   Icon = Texture2D'/Game/Stats/T_Other_statisticbig.T_Other_statisticbig'
struct.end
Soldier : struct.begin
   NameSID = sid_npc_soldier
   Icon = Texture2D'/Game/Stats/T_Soldier.T_Soldier'
struct.end
"""

EFFECTS = """
Hidden : struct.begin
struct.end
Shown : struct.begin
   Positive = EBeneficial::Negative
   EffectLevel = EEffectLevel::Medium
struct.end
"""

RELATIONS = """
Default : struct.begin
   RelationLevelRanges : struct.begin
      [0] : struct.begin
         start = -9999
         end = -800
      struct.end
      [1] : struct.begin
         start = -799
         end = -201
      struct.end
      [2] : struct.begin
         start = -200
         end = 200
      struct.end
      [3] : struct.begin
         start = 201
         end = 9999
      struct.end
   struct.end
   Factions : struct.begin
      Player =
      Army =
      Duty = Army
      Bandits =
   struct.end
   Relations : struct.begin
      Army<->Player = 0
      Bandits<->Player = -800
      Duty<->Bandits = -500
   struct.end
struct.end
"""

TEXTS = {
    "sid_effects_Shown_name": "Radiation",
    "sid_items_Shell_name": "Shell",
    "sid_items_Shell_description": "Line one\r\n\r\n\r\n\r\nLine <b>two</b>",
    "sid_items_FakeShell_name": "Fake shell",
    "sid_items_mutpartspack_MutantPartHornhead_name": "Hornhead horn",
    "sid_items_mutpartspack_MutantPartHornhead_description": "A horn.",
    "sid_misc_statisticspack_pda_statictics_mutant_deer": "Hornhead",
    "sid_misc_statisticspack_pda_statictics_mutant_rat": "Rat",
    "sid_misc_answer_faction_Duty": "Duty",
    "sid_misc_answer_faction_Bandits": "Bandits",
    "sid_misc_Faction_Enemy_Name": "Hostile",
    "sid_misc_Faction_Dislike_Name": "Dislikes",
    "sid_misc_Faction_Neutral_Name": "Neutral",
    "sid_misc_Faction_Friend_Name": "Friendly",
    "sid_lscreen_Loading_screen_24_desc": "Duty <b>guards</b> the Zone.",
    "sid_locations_region_cement_factory_desc": "Duty guards the Zone.",
}


def prototypes(text):
    return build_codex.prototypes_from(build_codex.parse_config(text))


class BuildCodexTests(unittest.TestCase):
    def test_artifacts_inherit_group_by_localization_and_filter_hidden_effects(self):
        effects = {sid: build_codex.resolve(prototypes(EFFECTS), sid) for sid in prototypes(EFFECTS)}
        exclude_fake = lambda fields: fields.get("ArtifactType") == "EArtifactType::Fake"

        entries = build_codex.item_entries(prototypes(ITEMS), effects, TEXTS, "EItemType::Artifact", exclude_fake)

        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["sids"], ["Shell", "ShellVariant"])
        self.assertEqual(entries[0]["name"], "{sid_items_Shell_name}")
        self.assertEqual(entries[0]["bullets"], ["- {sid_effects_Shown_name} (Medium)"])
        self.assertIn(["Rarity", "Rare"], entries[0]["facts"])
        self.assertIn(["Value", "100 coupons"], entries[0]["facts"])
        self.assertEqual(build_codex.english(entries[0]["description"], TEXTS), "Line one\n\nLine two")
        self.assertEqual(entries[0]["icon"], "/Game/Inventory/T_inv_shell.T_inv_shell")

    def test_placeholder_sprite_icons_are_dropped(self):
        self.assertEqual(build_codex.icon_path(prototypes(ITEMS)["TemplateArtifact"]["fields"]), "")

    def test_mutants_link_trophies_by_localized_name_stem(self):
        entries = build_codex.mutant_entries(prototypes(ITEMS), TEXTS)
        hornhead, rat = entries

        self.assertEqual(hornhead["sids"], ["DeerLoot"])
        self.assertEqual(build_codex.english(hornhead["name"], TEXTS), "Hornhead")
        self.assertEqual(
            hornhead["facts"][:2],
            [["Trophy", "{sid_items_mutpartspack_MutantPartHornhead_name}"], ["Trophy value", "14,000 coupons"]],
        )
        self.assertEqual(rat["sids"], [])

    def test_mutants_picture_their_render_and_keep_the_trophy_icon_for_the_detail(self):
        renders = build_codex.mutant_renders(prototypes(OBJECTS))
        hornhead, rat = build_codex.mutant_entries(prototypes(ITEMS), TEXTS, renders)

        self.assertNotIn("sid_npc_soldier", renders)
        self.assertEqual(hornhead["icon"], "/Game/Stats/T_Deer_statisticbig.T_Deer_statisticbig")
        self.assertEqual(hornhead["image"], hornhead["icon"])
        self.assertEqual(hornhead["detailIcon"], "/Game/Inventory/T_inv_horn.T_inv_horn")
        self.assertEqual((rat["icon"], rat["image"]), ("", ""))

    def test_factions_take_badges_from_the_icon_table_with_default_fallback(self):
        rows = {
            "Default": {"Texture": {"ObjectPath": "/Game/Icons/T_icon_fraction_neutrals.0"}},
            "Duty": {"Texture": {"ObjectPath": "/Game/Icons/T_icon_fraction_duty.0"}},
        }

        with tempfile.TemporaryDirectory() as directory:
            table_path = Path(directory) / "FactionIconsDataTable.json"
            table_path.write_text(json.dumps([{"Name": "FactionIconsDataTable", "Rows": rows}]), encoding="utf-8")
            badges = build_codex.faction_badges(table_path)

        bandits, duty = build_codex.faction_entries(build_codex.parse_config(RELATIONS), TEXTS, badges)

        self.assertEqual(duty["icon"], "/Game/Icons/T_icon_fraction_duty.T_icon_fraction_duty")
        self.assertEqual(bandits["icon"], "/Game/Icons/T_icon_fraction_neutrals.T_icon_fraction_neutrals")
        self.assertEqual(build_codex.faction_badges(None), {})

    def test_factions_resolve_stances_through_parent_factions(self):
        entries = build_codex.faction_entries(build_codex.parse_config(RELATIONS), TEXTS)
        bandits, duty = entries

        self.assertEqual(bandits["facts"], [["Starting standing", "{sid_misc_Faction_Enemy_Name}"]])
        self.assertEqual(duty["facts"], [["Starting standing", "{sid_misc_Faction_Neutral_Name}"]])
        self.assertEqual(build_codex.english(duty["bullets"][0], TEXTS), "Bandits: Dislikes")

    def test_faction_lore_keeps_present_distinct_passages_in_curated_order(self):
        entries = build_codex.faction_entries(build_codex.parse_config(RELATIONS), TEXTS)
        bandits, duty = entries

        # The location text cleans to the tip's text, and the Bandits keys are absent here.
        self.assertEqual(duty["description"], "{sid_lscreen_Loading_screen_24_desc}")
        self.assertEqual(build_codex.english(duty["description"], TEXTS), "Duty guards the Zone.")
        self.assertEqual(bandits["description"], "")

    def test_unbalanced_config_is_rejected(self):
        with self.assertRaises(ValueError):
            build_codex.parse_config("Broken : struct.begin\n   Type = X\n")

    def test_rendered_lua_escapes_quotes_and_newlines(self):
        tab = build_codex.tab("notes", "Notes", [build_codex.entry("id", 'Say "hi"', "a\\b\nc")])
        rendered = build_codex.render([tab], {})

        self.assertIn('name = "Say \\"hi\\""', rendered)
        self.assertIn('description = "a\\\\b\\nc"', rendered)

    def test_rendered_lua_carries_english_fallbacks_for_referenced_keys_only(self):
        entries = [build_codex.entry("Shell", "{sid_items_Shell_name}", "{sid_items_Shell_description}")]
        tab = build_codex.tab("lore", "Lore", entries, description_first=True)
        rendered = build_codex.render([tab], TEXTS)

        self.assertIn('["sid_items_Shell_description"] = "Line one\\n\\nLine two"', rendered)
        self.assertIn('["sid_items_Shell_name"] = "Shell"', rendered)
        self.assertNotIn("sid_items_FakeShell_name", rendered)
        self.assertIn("descriptionFirst = true", rendered)


if __name__ == "__main__":
    unittest.main()
