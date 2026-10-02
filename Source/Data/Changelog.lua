-------------------------------------------------------------------------------
-- Data.Changelog: the in-game changelog (Guide/WhatsNew.lua, /lp changelog),
-- one entry per version, newest first. Shown after an update with every
-- version newer than the one the player last ran opened.
--
-- An entry: version (the TOC's), title (a few words), date ("2026-10-02"
-- once released; nil shows "Beta"), and the lists new, changed and fixed,
-- each a line a player reads (the CHANGELOG.md style: what changed for
-- them, no internals), short enough to fit on one line: "Feature: what it
-- does", the part before the first ": " shown in blue, and {/lp} for a
-- command in gold (so a line never holds a macro token's own braces).
-- Keep it in step with CHANGELOG.md: /release adds the
-- entry. The 1.x releases of the original Linkepedia are not listed: 2.0 is
-- a new addon with nothing carried over.
-------------------------------------------------------------------------------
CobysLinkepedia.Data.Changelog = {
  {
    version = "2.0.3",
    title = "Redesigned settings and stats",
    date = "2026-10-01",
    changed = {
      "Settings: five pages with live examples, your values kept",
      "Stats tab: status, buttons and a tile per quality and type",
      "Scan messages: the same step names in the footer and {/lp status}",
      "Item counts: thousands separators, like 176,228",
      "Dialogs: sized to their text",
    },
    fixed = {
      "Search results: long words and six-digit IDs show in full",
      "{/lp status}: keeps the real highest item ID after a cancel",
      "Variant Builder: saves the rank it built",
      "Variants tab: the empty hint no longer runs under the search box",
    },
  },
  {
    version = "2.0.2",
    title = "What's New and a quicker start",
    date = "2026-10-01",
    new = {
      "What's New: opens after an update, {/lp changelog}",
      "First run: the guide opens with a Build Database button",
      "Expand Database: adds only the items you're missing",
      "Settings: a Guide button beside Defaults",
    },
    changed = {
      "Commands: {/lp} opens the search window, {/lp guide} the guide",
      "Titles: the Linkepedia icon, and its name in teal",
    },
    fixed = {
      "Variants tab: updates at once after a database reset",
      "Window corners: resizing stops at the screen edge",
    },
  },
  {
    version = "2.0.1",
    title = "Windows and scans",
    date = "2026-09-29",
    changed = {
      "Windows: sit with the game's own panels, a click brings one to the front",
      "Settings window: drag its corner to resize it; it keeps the size",
      "Command list: {/lp help} is easier to read",
    },
    fixed = {
      "Minimap button: back outside the minimap's edge",
      "Search window: resizing and column drags follow the cursor",
      "Expand: skips item IDs the server never answers, so it finishes fast",
      "Open Settings under Options > AddOns: no more blocked-action errors",
    },
  },
  {
    version = "2.0.0",
    title = "A complete rewrite",
    date = "2026-09-21",
    new = {
      "Item database: built on your own client with {/lp build}",
      "Chat autocomplete: type [ and a letter, pick an item with Tab",
      "Linking by name: send [Item Name] and it becomes a link",
      "Item tokens: a macro links an exact item by its ID, name or saved variant",
      "Search window: search, filter and browse every item with {/lp show}",
      "Variant Builder: build any crafted or upgrade-track version of gear",
      "Quick search: a small bar that drops a link into chat, {/lp qs}",
      "Feature guide: a section for each part of the addon, {/lp guide}",
    },
  },
}
