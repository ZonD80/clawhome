# Changelog

All notable changes to ClawHome are documented in this file.

## [1.1.0] - 2025-03-03

### Added

- **Time Machine backups** — Built-in SMB backup server exposes `~/clawhome/backups`
- **Automatic CPU cores assignment** - Homes will run faster
- **Display size fix** - Display is now fixed with FullHD+ resolution and non-HD DPI, so requests to AI will be cheaper

### Fixed

- **Build packaging** — App package size reduced from ~2 GB to ~13 MB by using `electron-builder.json5` config so only `dist` and `dist-electron` are packaged (previously the entire project including `claw-vm/.build` was included).
