# Changelog

All notable changes to this project will be documented in this file.

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
