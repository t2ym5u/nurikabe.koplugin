# Changelog

All notable changes to this project will be documented in this file.

## [1.7.1] - 2026-11-04

### Fixed
- A game no longer crashes when an outdated plugin is installed alongside:
  shared modules left behind by an older plugin are replaced by this
  plugin's own copy instead of being used as they are.

## [1.7.0] - 2026-11-04

### Changed
- More varied islands: on 10×10 and 15×15 grids about 70% of the islands
  used to be a single numbered cell; now islands of 2 to 4 cells are
  common and lone 1s are about 50% (10×10) to 60% (15×15) of the islands.
  Puzzles have fewer numbers (15×15: about 47 instead of 50-53), and on
  10×10 Hard has fewer than Easy (18 vs 20).
- Puzzles therefore differ from 1.6.0 for the same seed (Daily Challenge
  included).
- Uses less memory: the game loads when you open it, not when KOReader
  starts, so it no longer takes memory or startup time while unplayed.

### Fixed
- A Medium or Hard puzzle could come out easier than its level when the
  generator ran out of tries: 1 in 5 Medium 5×5 puzzles and 1 in 5 Hard
  10×10 puzzles did. The generator now keeps the hardest step reached and
  tries more ways to reach the level; this happens to about 1 in 50
  Medium puzzles, 1 in 10 Hard 10×10 and 1 in 20 Hard 15×15 puzzles.
- Every puzzle still has exactly one solution and can be solved without
  guessing. Generation takes at most about 0.05 s on a desktop (just over
  a second on a Kobo); the "Generating puzzle…" bar covers the wait.

## [1.6.0] - 2026-11-04

### Fixed
- 15×15 Hard always gave a "puzzle" that was one big island covering the
  whole grid, and 10×10 Hard and 15×15 Medium sometimes did too. Every size
  and difficulty now gives a real Nurikabe: many islands, a connected river,
  no 2×2 river block.
- Most 10×10 and 15×15 puzzles were not checked to have a single solution.
  Every puzzle now has exactly one solution and can be solved by deduction
  alone, without guessing.

### Changed
- New puzzle generator: puzzles are built so that they can be solved step
  by step, and the difficulty now sets how deep that reasoning goes. Easy
  needs only the basic rules; Medium also needs to keep the river connected
  and to work out how an island one or two cells short can end; Hard needs
  that for bigger islands too, with islands of up to 9 cells. Puzzles
  therefore differ from 1.5.0 for the same seed (Daily Challenge included).
- Generation takes at most about 0.04 s on a desktop (about a second on a
  Kobo) at every size; the "Generating puzzle…" bar covers the wait.

## [1.5.0] - 2026-11-04

### Changed
- Much faster puzzle generation: 5×5 Easy took up to 1.8 s on a desktop
  and 10×10 / 15×15 up to 0.6 s (up to a minute on an e-reader); it is
  now a few hundredths of a second at 5×5 and at most about a tenth of a
  second at 15×15. The uniqueness check deduces forced cells (unreachable
  cells, island borders, black connectivity) and the search is bounded by
  a fixed amount of work. A "Generating puzzle…" bar appears if
  generation still takes a moment (needs game-common 1.12.0).

### Fixed
- The uniqueness check counted the same island shape once per order its
  cells could be added in, so unique puzzles were taken for ambiguous and
  thrown away: 5×5 puzzles were only accepted when that happened not to
  occur, and at 10×10 almost none could be proven unique. 5×5 puzzles
  therefore differ from 1.4.x for the same seed (Daily Challenge
  included), still with exactly one solution; 10×10 Hard is now proven
  unique about half the time (was almost never), so those differ too.

## [1.4.3] - 2026-11-03

### Changed
- Picks up game-common 1.11.0: the shared on-screen keyboard (where used)
  gives every key the same letter size, and the no-repeat history helper.

## [1.4.2] - 2026-11-02

### Changed
- Picks up game-common 1.10.0: the shared Tools → Games menu also lists
  the games' new "· multiplayer" entries under Party & quiz.

## [1.4.1] - 2026-11-02

### Changed
- Listed under **Tools → Games**, grouped by category, instead of its own
  entry in the Tools menu (game-common 1.9.1).

## [1.4.0] - 2026-10-30

### Added
- "Daily Challenge" in the menu, right after "New game": today's puzzle at
  your size and difficulty, the same grid for everyone playing it today.
  Needs game-common 1.7.0.

## [1.3.0] - 2026-10-30

### Added
- "New game" once the puzzle is solved: the action bar shows it in place of
  Check, Hint and Undo, so the next puzzle no longer needs the menu.

### Changed
- Redesigned play screen, in line with the other games: a full-width action
  bar, a larger board that fills the available room, and one frame around
  it. The status line reads "size · difficulty · Unknown: n" and wraps in
  landscape instead of being cut off.
- Title-bar menu in the same order as every other game, with the current
  values shown: "Size: …" (was "Grid: …"), "Difficulty: …" (was "Diff:
  …"), and "Show solution" / "Hide solution" (was a bare "Show" / "Hide").
- New README screenshot.

### Fixed
- Tapping Undo crashed the game ("attempt to call method 'undo'").
- Two-digit clues overflowed their cells; the font is now sized for the
  largest clue on the board.
- Using Hint wiped the saved game: the board was saved as nothing. And when
  a hint fills the last cell, the status now shows the win message.
- The board's closing grid line was drawn just past its right and bottom
  edges.

## [1.2.2] - 2026-10-07

### Fixed
- The Tools menu entry is translated again. `main.lua` took `_` from
  KOReader's `gettext`, which knows nothing of this plugin's strings, so the
  menu label stayed English while the game's own screen, which goes through
  `i18n`, was translated. `_` now comes from `i18n` here too.
- `i18n_fr.lua` shipped to the device but was never loaded: nothing called
  `i18n.extend()` on it, so the whole table was dead weight. main.lua now
  merges it in before the menu entry is built.


## [1.2.1] - 2026-10-01

### Fixed
- Picks up game-common v1.5.0. Play statistics were recorded under a key no
  tool could match: `ReaderUI`/`FileManager:registerModule()` rewrite a plugin
  instance's `name` to `reader<id>` / `filemanager<id>` right after it is
  built, so this game's sessions were split across two rows and neither
  carried its plugin id. Rows written under the old keys are merged back on
  first read. The same release brings the `stopPlugin()` /
  `deletePluginSettings()` hooks KOReader 2026.07 calls when a plugin is
  deleted from the device (PR #15240).

  No change to this plugin's own code -- it inherits all of it from the
  shared library.

## [1.2.0] - 2026-09-30

### Added
- **Hint** button. Two taps, not one: the first says which cell is about to
  give, the second acts on it -- a player who is told where to look usually
  finds the rest themselves, and only pays for the full reveal if they want
  it. A cell that contradicts the solution is always reported before a fresh
  one is revealed, and on a mistake the hint empties the cell rather than
  solving it.

## [1.1.12] - 2026-07-31

### Fixed
- `board_widget.lua` referenced Blitbuffer color constants that don't
  exist (COLOR_GRAY_A), which evaluated to `nil` and crashed the
  color-comparison in `paintTo()` as soon as the corresponding
  highlight was drawn. Now uses the correct constant name(s)
  (COLOR_GRAY).

## [1.1.9] - 2026-07-29

### Fixed
- Generated puzzles had no uniqueness verification — the generator
  accepted the first structurally valid island layout it found, with no
  check for other valid tilings of the same clues. Real ambiguity was
  measured even though every island's size is fully revealed to the
  player. Added a uniqueness solver (mirroring the generator's own
  island-growth construction) and reworked generation to retry until a
  proven-unique layout is found. 5×5 puzzles are now guaranteed unique;
  10×10 and 15×15 are a documented partial improvement (see README).
