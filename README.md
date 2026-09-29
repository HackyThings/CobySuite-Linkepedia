# Coby's Linkepedia

<p align="center">
  <img src="https://raw.githubusercontent.com/HackyThings/CobySuite-Linkepedia/main/.publish-meta/icon/cobys-linkepedia-224.jpg" width="160" alt="Coby's Linkepedia">
</p>

Your personal item encyclopedia for WoW Midnight (12.1): search, autocomplete and link any item in the game.

Someone in guild asks what that trinket was called. You know the name, you just do not have the item, and nobody online does either. Type `[` in chat, start the name, pick it from the list, and the link is in your message. Coby's Linkepedia keeps a database of every item the game client knows about, built and kept current on your own machine, and puts it behind chat autocomplete, a search window and a quick search bar.

## The Problem

Linking an item you are not holding is a chore: find it on a website, find someone who has it, or give up and type the name. Item databases that ship inside an addon have a different problem. They are frozen at the moment the addon was packaged, so every patch that adds items leaves them a little more out of date, and they stay that way until the author ships an update.

Coby's Linkepedia does not ship a database. It builds one from the game client on your computer and keeps it current without an addon update. A background scan quietly fills in the items the server held back during the build, crafted-quality variants are captured as you play, and one command, which the addon offers to run after each game patch, picks up everything the patch added. If the client knows an item, you can link it.

## How It Works

1. **Build the database once.** On first login a welcome window offers a Build Database button; `/lp build` does the same. The scan walks every item ID the client recognises, roughly 175,000 of them, asks the server for the ones it has not cached yet, and saves each item's name, quality, type, item level, required level and expansion. It runs in the background over a few minutes, pauses by itself in combat, and can be paused, resumed or cancelled at any time. A build always starts from scratch and clears the items already stored. If a scan is cancelled or cut off by a logout, a chat line at your next login says so (unless chat verbosity is Quiet), and `/lp expand` continues it without losing anything already stored. The footer of the search window shows the progress bar, the rate and the time remaining, and a scan speed setting (Slow, Medium, Fast) trades frame rate for scan time. Shift-click Build or Expand for Boost (500 items per batch) or Ctrl+Shift-click for Max (1,000): both finish sooner, with heavy stutter for as long as the scan runs.
2. **Type `[` in chat.** Once you have typed a letter after the bracket, a dropdown opens beside the chat box with the best matches: icon, name in its quality color, and a count of captured variants on items that have some. Names that start with your text come first; if there are fewer of those than the dropdown holds, items containing the text anywhere fill the rest below a faint divider. Completion works where your cursor is, so you can add a link in the middle of a message and keep the text after it. Up and Down move the highlight and show its tooltip. Tab puts the highlighted item's link (the first one when none is highlighted) in place of what you typed and leaves you in the message; while the list is open, Tab does this instead of switching whisper targets. A click on a row does the same. Enter sends the message as it stands and never inserts, and Escape closes the list and, as the chat box always has, clears the message. A click anywhere else closes the list. It works in every tab of the default chat window, including ones you open later, and in pop-out whisper windows, and stays out of script lines (`/run`, `/script`, `/dump`, `/console`) and the game's own commands such as `/cast` and `/use`.
3. **Or just type `[Item Name]` and send.** Any bracketed exact item name (capitalisation does not matter) turns into a link at the moment the message is sent, so what you typed stays editable until then. Several brackets in one message all convert, links already in the message are left alone, and a bracket that matches nothing is sent as plain text. When several items share a name, the highest quality one is linked. For items with captured variants, add a qualifier: `[Item Name~R2]` for a crafted rank, `[Item Name~270]` for an item level, `[Item Name~R2~270]` for both. A qualifier only matches a captured variant with exactly that rank or item level; when none does, the brackets are sent as typed. Without a qualifier you get the best captured variant, or the base item. Script lines (`/run`, `/script`, `/dump`, `/console`) and the game's own commands such as `/cast` and `/use` are never touched.
4. **Item tokens, for macros.** A macro is written once and pressed often, so it names its item exactly instead of using brackets: `${i=6948}` links item ID 6948, and `${n=hearth}` links the item named exactly that, or else the first match autocomplete would show. Both take the same qualifiers, as in `${i=191234~R2}`. `${v=5}` links saved variant 5 (see the Variant Builder below), the exact crafted or upgrade-track version you saved. Tokens work in any chat line a macro sends (`/s`, `/p`, `/w Name`, `/1`, or no command) and in typed chat too; brackets in a macro are sent as written. The macro window gets a panel on its right edge that lists the syntax, shows what each token in the selected macro links right now in a scrolling list where you can edit a token in place (click it, then the check mark), remove it (the red X) or Pin an `n=` token to its exact `i=` token, and finds items to add at the cursor; its close button folds it to a book icon on the macro window's edge. Each change the panel makes closes and reopens the macro window for a moment, so the game saves the macro itself. Shift-click an item into a macro chat line and the panel offers its token in place of the name (a saved-variant token for crafted and upgrade-track gear); `/use` and `/cast` lines keep the name. Right-click an item in the search window to send its token to chat. A token whose item has not loaded yet is sent as the plain name, and the addon loads the items your macros name at login, so that is rare.
5. **`/link <name>` for a quick list.** Prints up to 20 matching items as clickable links in your chat frame. Only you see them; shift-click any of them into a message.
6. **The search window.** Open it with `/lp show`, a left-click on the minimap button, the addon compartment, or a keybind. A search box filters as you type, with the quality, type and expansion filters beside it on the same row. The picker next to the box sets how your words match: **Exact** finds the text as you typed it, **All words** finds names holding every word in any order (`storm blade` finds Blade of the Storm), and **Any word** finds names holding at least one of them; the window remembers your choice. The columns (name, item level, type, subtype, expansion, quality, ID, required level) sort and resize; when the window is too narrow for them, the columns shrink to fit rather than disappear. Every match is listed, and the list stays quick at six figures. Left-click an item and the detail pane shows its item ID, the raw link string and its Wowhead URL; the link and the URL each have a copy icon that selects the text for Ctrl+C (hover the icon for the tooltip). Shift-click links the item in chat (opening chat if it is closed), Ctrl-click previews it in the dressing room, and right-click opens a menu to add it to Favorites, link it, or put its name, item ID or Wowhead link into chat. Hold Shift over a row to compare it with what you have equipped. Drag the detail pane's left edge to make it wider or narrower (double-click it for the default); the window remembers the width. Below the item's fields the detail pane lists its saved and captured variants. Tabs along the bottom switch to Variants (the Variant Builder, below), Favorites (items and variants, saved across sessions), History (the items you linked most recently, with the time) and Stats (your database by quality and type, variants captured, scan coverage, updated while the tab is open). Favorites and History scroll, keep the detail pane beside them, and take the same clicks as the results. While you are typing in the search box, Escape clears it; press Escape again to close the window. It remembers its position and size. The ? beside the close button opens the feature guide (`/lp tutorial`): a section for each part of Coby's Linkepedia that you open with a click, saying what it does and what to try.
7. **The Variant Builder.** Click Build Variant in the detail pane (weapons and armor), choose Build variant from an item's right-click menu, or run `/lp variant`, and the Variants tab opens on that item; its own search box finds other gear, crafted pieces first and tagged "crafted". The choices box below the item depends on the gear. Crafted gear opens on **Crafting**: its quality and a menu for every optional reagent slot the recipe has, which is where embellishments, missives, sparks and crests go, for any recipe the game has, known or not, with reagents you do not need to own. Other gear opens on **Upgrade Track**: a Season (Midnight Season 1 or 2, or The War Within Season 3), a Track, a Rank and a Quality. Each rank is listed with its item level, including ranks past the track's usual top where the game has them (Myth 9/6); the usual top is the default. Quality starts on the rank's own (marked default) and can raise it, up to Heirloom, which saves as its own variant. The game only ever raises an item's quality, so the menu lists the ones above the rank's own: a Myth rank, already Epic, offers Legendary, Artifact and Heirloom. Crafted gear can switch to Upgrade Track with Build as; gear no recipe makes says so, since only crafted gear takes embellishments and missives. The preview under the choices is the game's own link, with its item level, track and season, and its length (a chat line holds 255 bytes). **Save** keeps it under a number, and `${v=N}` then links exactly that variant in chat or a macro; the star favorites it; **Link in Chat** puts it in the chat box; **Add to Macro**, with the macro window open, puts its token at the macro's cursor. Favoriting it or adding it to a macro saves it first. Open a saved variant and **Update** replaces it with your new choices, so macros that use its token link the new version. Saved variant numbers are never reused, and deleting one a macro still uses asks first. Every saved and captured variant shows in the detail pane, where a click opens it in the builder with its choices, Shift-click links it, Ctrl-click previews it in the dressing room and right-click saves, favorites, deletes or sends its token; favorited variants also appear in the Favorites tab. The game accepts any track on any gear, so whether an item really drops on the track you choose is yours to check. Crafted variants need a recipe index, which the addon builds by itself once per patch, a little after login, in under a minute, pausing in combat and while a profession window is open.
8. **The quick search bar.** `/lp qs` or its keybind opens a small floating box, already focused, with the top ten matches. Up and Down move the highlight, Enter or a click picks one, and the link goes into the chat box you had open, or chat opens with the link typed in. An item the game has not loaded yet takes a moment. Escape closes it. Drag it wherever you like; it remembers.
9. **Keeping the database current, with no addon update.**
   - **Idle scan** (default on): once a database exists, a background scanner asks the server again for the items it held back during a scan, five a second by default and never in combat. It never starts a scan; scans run only when you start one. Renamed items are corrected by the next Build.
   - **Capture as you play:** item variants (crafted ranks and other bonus versions of an item) are picked up from your bags and reagent bag, loot windows, both sides of a trade, mail, the gear you wear and the links other players post in chat, up to 12 per item and 5,000 in all (the oldest go first). Turn on capture toasts to see a small notice each time one lands.
   - **Expand** (`/lp expand` or the Expand button): scans only the IDs your database does not have, across the whole range, so new items come in without a rebuild. After a game patch a dialog offers to run it for you.
   - **Status window** (`/lp status`): the item and variant counts, the scan running now and the last one, and what the idle scan is doing (its queue, how far through it it is, and what it stored this session), updated live while the window is open.
   - **IDs the server does not have:** the game's own data lists tens of thousands of item IDs the server no longer serves. The server turns a few of them down and never answers for the rest, so an ID it refuses, or one that stays silent through two scans (or through a scan and the idle scan's retries), is remembered and skipped until the next game patch, so checks stay quick and the retry queue holds only items worth waiting for.

## Language

Coby's Linkepedia supports English game clients. Capitalisation is ignored for the letters A to Z, and a quoted search such as `"ring"` matches whole words, where letters and apostrophes count as part of a word. In the All words and Any word modes, each quoted word or phrase is matched on whole words while the rest match anywhere.

## Install

**CurseForge:** https://www.curseforge.com/wow/addons/linkepedia

**Manual:** Drop the `CobysLinkepedia` folder into your `Interface/AddOns/`. No dependencies.

**Upgrading from Linkepedia 1.5.0:** 2.0 installs as a new folder, `CobysLinkepedia`. If an old `Linkepedia` folder is still in your `Interface/AddOns/`, delete it; nothing carries over from it.

## Slash Commands

```
/lp show               Open or close the search window
/lp qs                 Open or close the quick search bar
/lp tutorial           Open or close the feature guide: every part of the addon, section by section
/lp build              Clear the item database and scan everything from scratch (asks first if one exists)
/lp expand             Scan only for items the database does not have yet; also continues an unfinished scan
/lp pause              Pause the running scan
/lp resume             Resume a paused scan
/lp stop               Cancel the running scan; what was found is kept
/lp status             Open or close the status window: the database, the scans and the idle scan, updated live
/lp stats              Open or close the live stats window: memory, framerate, latency and database counts
/lp settings           Open the settings window
/lp set <key> <value>  Change a setting by its key, such as /lp set scanSpeed Fast; /lp set alone lists every key and its value
/lp reset              Delete the item database with its captured variants and recipe index (asks first); settings, favorites, history and saved variants are kept
/lp variant [itemID]   Open the Variant Builder, optionally on an item
/lp recipes [cancel]   Build the recipe index the Variant Builder uses (it runs by itself after a patch), or stop it
/lp findmax [cancel]   Scan item IDs 0 to 1,000,000 and report the highest one the game knows, or stop it
/lp debug              Open or close the debug log window (copy it into a bug report)
/lp version            Print the addon version
/lp help               List every command
/link <name>           Print up to 20 matching item links in your chat frame
```

`/linkepedia` and `/cobyslinkepedia` work the same as `/lp`. `rebuild`, `cancel`, `quicksearch`, `guide` and `config` are aliases for `build`, `stop`, `qs`, `tutorial` and `settings`.

**Keybindings:** Options > Keybindings > AddOns lists two entries under Coby's Linkepedia, Toggle Search Window and Toggle Quick Search. Both are unbound until you pick keys.

## Settings

Open with `/lp settings`, a right-click on the minimap button, or the Open Settings button under Options > AddOns > Coby's Linkepedia. The settings are grouped into Autocomplete, Scanning, Chat & Linking and Display on the left. Changes wait until you click Apply; Cancel or closing the window discards them, and Defaults (after asking) shows every default until you click Apply. Drag the window's bottom-right corner to make it bigger; it keeps that size. `/lp set` only accepts values a setting allows and tells you why it refused one.

**Autocomplete**
- Enable autocomplete (default on)
- Autocomplete delay (default 0.25 s, 0 to 2. How long after your last keystroke the dropdown updates.)
- Max dropdown results (default 10, 1 to 10)

**Scanning**
- Scan speed (default Medium. Slow leaves more frame time for the game; Fast finishes sooner.)
- Enable idle background scan (default on. Asks the server again for the items a scan held back.)
- Idle scan speed (default 5, 1 to 20. Item IDs the idle scan checks each second.)

**Chat & Linking**
- Auto-linkify [Item Name] on send (default on)
- Item tokens ${i=ID} and ${n=name} in chat and macros (default on)
- Chat message verbosity (default Normal. Quiet shows only answers to your commands and warnings, Normal adds scan start, refine and completion notices, Verbose adds per-phase detail.)

**Display**
- Show minimap button (default on)
- Capture toast notifications (default off. A small notice at the bottom right each time a variant is captured.)
- Shift-hover item comparison (default on. Hold Shift over a result to compare it with what you have equipped.)
- Max recent history entries (default 50, 0 to 200)

## Troubleshooting

**Typing `[` does nothing.**

- There is no database yet. Run `/lp build`; a chat line says so the first time you try in a session.
- The dropdown waits for at least one character after the bracket, then for the delay set in the settings.
- Autocomplete stays out of script lines (`/run`, `/script`, `/dump`, `/console`) and the game's own commands such as `/cast` and `/use`, which it cannot safely touch.
- Check "Enable autocomplete" in `/lp settings`.
- Coby's Linkepedia works with the default chat edit boxes. A chat addon that replaces the chat box is not supported.

**`[Item Name]` was sent as plain text.**

- The name has to match an item exactly, though capitalisation does not matter. Autocomplete or `/link` will show you the exact name.
- The item may not be in the database yet. `/lp expand` picks up items added since your last scan.
- A qualifier such as `~R2` only matches a captured variant with exactly that rank; otherwise the brackets are sent as typed.
- Check "Auto-linkify [Item Name] on send" in `/lp settings`.
- In a macro, brackets are sent as written: use a token such as `${i=6948}` (see How It Works). The macro window's token panel shows what each token links.
- Links are much longer than names, and a chat line holds 255 bytes, so when the links would not fit, the message goes out as typed and chat says why; link fewer items per message.
- During instance encounters the game itself blocks some chat from macros, with or without Coby's Linkepedia.

**The token panel asked me to select the macro again.**

- The change was saved. The macro window reopens with its list scrolled to the top, so a macro further down is not selected again by itself; click it to keep editing.
- The panel makes no changes in combat or while the macro name and icon window is open.

**The Variant Builder shows no crafting choices (quality, embellishments, missives) for an item.**

- Only crafted gear takes them. If no recipe the game lists makes the item, the choices box says so and offers Upgrade Track.
- The recipe index may still be building: the box shows its progress, or an Index Recipes button when it has not run. `/lp recipes` starts it.

**The Variant Builder says "The game did not confirm" a track and rank.**

- The builder checks every link it builds and refuses one the game does not read back as the season, track and rank you chose. A new season's tracks arrive with an addon update.
- The game only describes the current season's tracks. A past season's variant keeps that rank's item level, but its tooltip may not name the track, and the builder says so.

**The scan looks stuck.**

- Scans pause in combat and carry on by themselves afterwards.
- "Waiting for stragglers" and "Refining" are normal. The server holds back some items on the first request, so the scan waits and asks again.
- Some item IDs are never sent by the server. The newest of them are left to the idle scan, which asks for each of them three more times and then skips it until the next game patch; the rest are skipped once a second Expand hears nothing either. `/lp status` shows how many are waiting and how many the server does not have.
- Cancelling keeps what was found so far. Expand fills in the rest without starting over, and a chat line at login (unless chat verbosity is Quiet) reminds you when the last scan did not finish.

**Items from the latest patch are missing.**

- After a game patch, Coby's Linkepedia offers to check for the new items; click Check Now.
- Or run `/lp expand` at any time, for example after a server hotfix, which adds items without a patch. It scans only the IDs your database does not have, including everything above the old top of the range, so new items arrive without a rebuild and without waiting for an addon update.

**A "Database Corrupted" window appeared at login.**

- Your item database was damaged, so the addon cleared it; click Rebuild Now, or run `/lp build` later. Settings, favorites, history and saved variants are kept.

**The minimap button is gone.**

- Check "Show minimap button" in `/lp settings`. The addon compartment entry beside the minimap works either way.

## License

GPL-2.0. See [LICENSE](LICENSE).

## Issues / Feedback

For bug reports, the cleanest path is the debug log. It is self-contained: it includes the addon version, your WoW build, a snapshot of every setting, and a timestamped event timeline. No need to paste anything else.

**How to capture and send:**

1. Reproduce the issue.
2. Run `/lp debug` to open the debug window and click **Copy Last 250**.
3. Email them to **hackythings@gmail.com** with a sentence about what you were doing.

**Other channels:**

- **BugSack errors:** whisper the report straight to **Figment-Illidan** in-game. BugSack copies the stack trace for you. Mention how to reproduce if you can.
- **CurseForge comments:** drop a note on the [project page](https://www.curseforge.com/wow/addons/linkepedia). Best for general feedback and quick questions.
- **GitHub issues:** [open one here](https://github.com/HackyThings/CobySuite-Linkepedia/issues). Best for reproducible bugs and feature proposals where back-and-forth helps. Attach the debug-log paste here too if it is relevant.
