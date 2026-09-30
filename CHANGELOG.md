# Changelog

All notable changes to this project will be documented in this file.

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
