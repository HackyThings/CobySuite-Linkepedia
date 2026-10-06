# Coby's Linkepedia

<p align="center">
  <img src="https://raw.githubusercontent.com/HackyThings/CobySuite-Linkepedia/main/.publish-meta/icon/cobys-linkepedia-224.jpg" width="160" alt="Coby's Linkepedia">
</p>

Search, autocomplete and link any item in WoW Midnight (12.1), even ones you don't own. Coby's Linkepedia builds its item database from your own game client. Built for English clients.

## Features

- **Chat autocomplete:** type `[` and part of an item name, then press Tab to insert its link.
- **Link by name:** send `[Item Name]` and it goes out as a link.
- **Search window:** search and filter every item, keep Favorites, and see the items you linked recently.
- **Variant Builder:** build and save crafted or upgrade-track versions of gear.
- **Macro tokens:** `${i=6948}` links an item by ID, `${v=N}` a saved variant.
- **Quick search:** `/lp qs` opens a small search bar that drops a link into chat.
- **Stays current:** Expand Database adds a new patch's items without an addon update, and variants you come across are captured as you play.

## Quick start

1. Install from [CurseForge](https://www.curseforge.com/wow/addons/linkepedia), or put the `CobysLinkepedia` folder in `Interface/AddOns`.
2. On first login, click **Build Database** in the guide. It takes a few minutes and pauses in combat.
3. Type `[hearth` in chat and press Tab, or type `/lp` to search.
4. After a patch, run `/lp expand`.

Upgrading from Linkepedia 1.5.0? Delete the old `Linkepedia` folder; the new addon is `CobysLinkepedia`.

## Commands

```
/lp show - Open or close the search window
/lp settings - Open or close the settings window
/lp guide - Open or close the feature guide
/lp changelog - Open or close the changelog: what changed in each version
/lp debug - Open or close the debug log window
/lp build - Build the item database from scratch (asks first when it already has items)
/lp expand - Add the items the database lacks, or finish a stopped scan
/lp pause - Pause the running scan
/lp resume - Resume a paused scan
/lp stop - Cancel the running scan; items found so far are kept
/lp qs - Open or close the quick search bar
/lp status - Open or close the live database and scan status window
/lp stats - Open or close the live performance stats window
/lp set <key> <value> - Change a setting by key; alone, lists every key and value
/lp reset - Delete the item database (asks first); settings, favorites, history and saved variants stay
/lp recipes [cancel] - Index the recipes the Variant Builder uses; cancel stops it
/lp variant [itemID] - Open the Variant Builder, optionally on an item ID
/lp findmax [cancel] - Find the highest item ID the game knows; cancel stops it
/lp version - Print the addon version
/lp help - Show this help
/link <name> - Print up to 20 matching item links in your chat frame
```

A bare `/lp` opens the search window. `/linkepedia` and `/cobyslinkepedia` work too. Right-click the minimap button for settings, and set keys for the search window and quick search under Options > Keybindings > AddOns.

## License

GPL-2.0. See [LICENSE](LICENSE).

## Issues / Feedback

Found a bug? Run `/lp debug`, press **Copy Last 250** and send the text with a line about what you were doing. The log holds the addon version, your WoW build and your settings.

- **Email:** hackythings@gmail.com
- **BugSack errors:** whisper them to **Figment-Illidan** in game.
- **CurseForge:** comment on the [project page](https://www.curseforge.com/wow/addons/linkepedia) for questions and feedback.
- **GitHub:** [open an issue](https://github.com/HackyThings/CobySuite-Linkepedia/issues) for bugs you can reproduce.
