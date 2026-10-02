# Changelog

All notable changes to Coby's Linkepedia are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), version numbering follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.0.3] - 2026-10-01

### Changed

- **Settings redesigned:** five pages with live examples, your database's status and buttons, your key bindings and a sample notice. Every setting keeps its value.
- **Stats tab redesigned:** your database's status and buttons, then a tile for each quality and item type with its share. Hover a tile for its percent.
- `/lp help` now lists `/link` too.
- Hover the filters' **Clear**, **Clear History** and the folded macro token icon to see what they do.
- The scan footer and `/lp status` name each step the same way: Finding items, Waiting for item data, Retrying. Scan messages call the IDs no longer asked about "skipped".
- Shorter tooltips, settings descriptions and first guide section; the Build and Expand buttons' tooltips say only what they do.
- The search, status, stats and debug windows show the Linkepedia icon on their titles.
- Item counts use thousands separators (176,228). `/lp stats` shows an idle scan in gray, not red.
- Dialogs fit their text, with no empty space above their buttons.

### Fixed

- Search results show long words and six-digit item IDs in full; the search window is now at least 1005 wide. Column widths you set yourself are kept.
- The Variants tab's empty hint no longer runs under the search box.
- `/lp status` keeps the real "Highest item ID" after you cancel a scan.
- The Variant Builder saves the rank it built, even when the item's rank details arrive mid-preview.
- `/lp status` pointed to a settings page that no longer exists when the idle scan is off.
- The Item tokens setting no longer says it hides the macro window's token panel; turned off, tokens are sent as typed.

## [2.0.2] - 2026-10-01

### Added

- **What's New window:** after an update, a window opens once with what changed in every version since the one you last played. `/lp changelog` (or `/lp whatsnew`) opens it any time.
- A fresh install opens the feature guide at its first section, the item database, with a **Build Database** button right there to start your first build, and an **Expand Database** button beside it (also in Keeping it current) that adds only the items your database is missing. Shift-click and Ctrl+Shift-click speed them up as in the search window. It replaces the old welcome window.
- The settings window has a **Guide** button beside Defaults that opens the feature guide.

### Changed

- `/lp guide` is now the guide's command (`/lp tutorial` still works), and `/lp options` opens the settings too. Typing `/lp settings` again closes the settings window, and typing just `/lp` opens the search window, as the other Coby addons open their main window (`/lp help` lists every command).
- The settings, guide and changelog windows show the Linkepedia book icon in their title bar, the settings title shows the addon's name in its teal, and the guide says at the bottom how to open it again.

### Fixed

- An open Variants tab no longer keeps showing the recipe scan's old progress after you reset the item database; it updates at once.
- Dragging the corner of the search or settings window stops at the edge of the screen, so the corner can no longer end up off screen where you can't grab it.

## [2.0.1] - 2026-09-29

### Changed

- **Windows no longer stay on top of the game's own windows.** Coby's Linkepedia's windows now sit with the game's panels: clicking any window brings it to the front, and a window opens in front. Only questions that need an answer, such as confirmations, stay above everything.
- The settings window can now be made bigger by dragging its bottom-right corner, and it remembers its size.
- Settings sections sit closer together, so each group reads as one block.
- The command list in chat (`/lp help`) is easier to read: commands in gold and their descriptions in white.

### Fixed

- The minimap button sits just outside the minimap's edge again, and follows it when Edit Mode resizes the minimap; on the larger minimap it had been stuck inside the map.
- Resizing the search window by its corner no longer makes it jump bigger than where the cursor is, and a column drag in the results always ends when you let go. Pressing a column divider no longer makes that column slightly narrower.
- Expand now learns which item IDs the server does not have after two scans. The server refuses only a few of them and never answers for the rest, and only the 5,000 newest silent ones per scan were being retired (through the idle scan), so Expand kept asking about tens of thousands of IDs every time. An ID that stays silent through two complete scans is now skipped until the next game patch, and `/lp status` shows how many have gone unanswered once. Once they are all known, an Expand with nothing new to find takes about two seconds and asks the server nothing.
- **Blocked-action errors after opening the settings from the game's menu:** pressing **Open Settings** on the Coby's Linkepedia page under Options > AddOns brought the game menu back behind the settings window, and the game blamed Coby's Linkepedia for SpellStopCasting, SpellStopTargeting and an unnamed protected action ("Coby's Linkepedia has been blocked from an action only available to the Blizzard UI"). The button now just closes Options and opens the settings window.

## [2.0.0] - 2026-09-21

Coby's Linkepedia 2.0 is a complete rewrite of Linkepedia (last released as 1.5.0) for WoW Midnight 12.1. Nothing carries over from the old version, and there is no data to migrate.

### Added

- An item database built from your own game client. `/lp build` (or the Build button in the welcome window and the search window) scans every item ID the client knows, about 175,000 items, in the background. It pauses in combat and can be paused or cancelled at any time. Shift-click Build or Expand for Boost (500 items per batch) or Ctrl+Shift-click for Max (1,000), which finish sooner with heavy stutter while they run.
- `/lp expand` scans only the item IDs your database does not have, across the whole range, so a new patch's items arrive without an addon update. It is also how you continue a scan that was cancelled or cut off by a logout: a chat line at login tells you when the last scan did not finish. Build always starts from scratch.
- A background idle scan asks the server again for the items it held back during a scan, five a second by default and never in combat. Scans themselves run only when you start one; after a game patch a dialog offers to check for the new items.
- Item IDs the game lists but the server no longer serves (tens of thousands of them) are remembered and skipped until the next game patch, so Expand asks the server only about IDs that might be new, and the retry queue keeps the newest items. `/lp status` shows how many IDs are waiting on the server and how many it does not have.
- Chat autocomplete. Type `[` and a letter in any chat tab or pop-out whisper window (not in a `/run` or `/script` line) and a dropdown lists the best matches, with a count of captured variants where there are any. Completion works at your cursor, even in the middle of a message. Up and Down move the highlight and show its tooltip, Tab inserts the link (while the list is open it does not switch whisper targets), Enter sends the message as typed, Escape closes the list, and a click elsewhere closes it too. Matches are found over a few frames, so even a one-letter search does not pause the game. With no item database yet, the first try in a session says so in chat and points you to `/lp build` (while a build is running, it says suggestions appear as items are stored).
- `[Item Name]` turns into a link when the message is sent. When several items share a name, the highest quality one is linked. `[Item Name~R2]` asks for a crafted rank and `[Item Name~270]` for an item level; a qualifier that matches no captured variant leaves the brackets as typed. `/run` and `/script` lines are never changed.
- Item tokens for macros: `${i=6948}` links that exact item ID and `${n=hearth}` the item named exactly that, or else the first match autocomplete would show, with the same `~R2` and item level qualifiers. They work in every chat line a macro sends and in typed chat. A panel on the right of the macro window lists the syntax, shows what each token in the selected macro links in a scrolling list where a token can be edited in place, removed, or pinned from a name token to its exact ID token, and searches for items to add at the cursor. Shift-clicking an item into a macro chat line offers its token in place of the name; `/use` and `/cast` lines keep the name. The search window's right-click menu sends an item's token to chat. The panel changes a macro by closing and reopening the macro window for a moment, so Blizzard's own macro saving is never touched. The items your macros name are loaded at login so their first press links.
- The Variant Builder, on the search window's new Variants tab (Build Variant in the detail pane, Build variant in the right-click menu, or `/lp variant`). Pick a piece of gear and build any version the game allows: a crafted item at each quality with any missive, embellishment, spark, crest or other optional reagent, whether or not you know the recipe or own the reagents, or dropped gear on any upgrade track and rank of Midnight Season 1 or 2 or The War Within Season 3, with each rank's item level in its menu. Ranks past a track's usual top are offered where the game has them, such as Myth 9/6, and a Quality menu starts on the rank's own quality and can raise it, up to Heirloom. The game never lowers an item's quality, so a Myth rank offers Legendary, Artifact and Heirloom. The preview shows the game's own link, its item level, its track and season, and its size in bytes. Save it, favorite it, link it in chat, or add it to a macro.
- Saved variants. Each gets a number, and the token `${v=5}` links saved variant 5 exactly, in chat and in macros. Adding a variant to a macro, favoriting it or sending its token saves it first. Numbers are never reused, so a macro never starts linking a different variant after a delete, and deleting one a macro uses asks first. Shift-clicking a crafted or upgrade-track item into a macro chat line offers its saved-variant token.
- The detail pane lists every saved and captured variant of the item, with the same clicks as the item lists: click opens it in the Variant Builder, Shift-click links it, Ctrl-click opens the dressing room, and right-click saves, favorites, deletes or sends its token. Favorited variants appear in the Favorites tab under their item.
- A recipe index for the Variant Builder. The game cannot tell which recipe makes an item, so the addon looks through the game's recipes once per patch, by itself a little after login; it takes under a minute, pauses in combat and while a profession window is open, and `/lp recipes` runs or stops it by hand.
- Item variants (crafted ranks and other bonus versions) are captured from your bags, reagent bag, equipment, loot, trades, mail and chat links, up to 12 per item and 5,000 in all; past either limit the oldest goes first. Optional capture toasts announce each new one.
- The search window (`/lp show`, the minimap button, the addon compartment or a key binding): a search box with quality, type and expansion filters on the same row, a search mode picker (Exact, All words in any order, or Any word), sortable and resizable columns, and a detail pane with the item ID, the raw link string and the Wowhead URL, each with a copy icon that selects it for Ctrl+C. Drag the detail pane's left edge to resize it. Click shows details, Shift-click links the item, Ctrl-click opens the dressing room, and right-click adds it to Favorites or puts its name, item ID or Wowhead link into chat. The tabs along the bottom are Results, Variants, Favorites, History and Stats. The same clicks work on the Favorites and History tabs, which scroll, and the Stats tab updates while it is open. Searches, the full item list and column sorts fill in over a few frames with a progress line, so even a one-letter search or a sort of the whole database does not freeze the game. Escape closes the window.
- The quick search bar (`/lp qs` or a key binding): pick an item and its link goes into the chat box you had open, or chat opens with the link typed in.
- `/link <name>` prints up to 20 matching item links in your chat frame.
- Key bindings for the search window and the quick search bar under Options > Keybindings > AddOns, unbound until you choose keys.
- A settings window (`/lp settings`, a right-click on the minimap button, or the button under Options > AddOns > Coby's Linkepedia). Settings are grouped into Autocomplete, Scanning, Chat & Linking and Display on the left. Changes wait for Apply; Cancel or closing the window discards them, and Defaults shows every default until you press Apply. `/lp set <key> <value>` changes a setting from chat and refuses values outside the setting's range.
- Chat message verbosity: Quiet shows only answers to your commands and warnings, Normal adds scan start, refine and completion notices, Verbose adds per-phase detail.
- `/lp status` (a live window of the database, the scans and the idle scan), `/lp stats` (a live performance window), `/lp findmax` (with `/lp findmax cancel`) and `/lp debug`.
- A feature guide: `/lp tutorial`, or the ? beside the search window's close button, opens a window with a section for each part of the addon. Click a heading to open or close it; each section says what that part does and which commands and keys to try.
- If the saved item database is damaged, it is cleared at login and a dialog offers to rebuild it. Favorites, history and settings are kept.
- English game clients are supported: capitalisation is ignored for the letters A to Z, and a quoted search such as `"ring"` matches whole words.

[Unreleased]: https://github.com/HackyThings/CobySuite-Linkepedia/compare/v2.0.3...HEAD
[2.0.3]: https://github.com/HackyThings/CobySuite-Linkepedia/releases/tag/v2.0.3
[2.0.2]: https://github.com/HackyThings/CobySuite-Linkepedia/releases/tag/v2.0.2
[2.0.1]: https://github.com/HackyThings/CobySuite-Linkepedia/releases/tag/v2.0.1
[2.0.0]: https://github.com/HackyThings/CobySuite-Linkepedia/releases/tag/v2.0.0
