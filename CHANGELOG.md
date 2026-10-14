# Changelog

All notable changes to ClawHome are documented in this file.

## [1.2.0] - 2026-10-14

### Added

- **Linux (bia) homes** — Create a home for bia as well as macOS. The latest bia release on GitHub is used when it includes the arm64 disk image. A disk image path is asked for only when that release is missing.
- **Cloud AI keys** — Same flow as bia-flash when Linux is selected. Continue with ChatGPT, or paste an API key (OpenRouter, OpenAI, Anthropic, xAI, DeepSeek, or Qwen) and pick a model from that account. The key is checked with a real tool-calling request before the home is created, then stored in plaintext at `EFI/bia/fmm.json` on the disk. A ChatGPT sign-in is for that one home only.
- **OpenRouter default model** — OpenRouter now starts on `deepseek/deepseek-v4.1-flash`.

## [1.1.0] - 2025-03-03

### Added

- **Time Machine backups** — Built-in SMB backup server exposes `~/clawhome/backups`
- **Automatic CPU cores assignment** - Homes will run faster
- **Display size fix** - Display is now fixed with FullHD+ resolution and non-HD DPI, so requests to AI will be cheaper

### Fixed

- **Build packaging** — App package size reduced from ~2 GB to ~13 MB by using `electron-builder.json5` config so only `dist` and `dist-electron` are packaged (previously the entire project including `claw-vm/.build` was included).
