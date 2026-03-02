# ClawHome

**A private home for your Claw**

ClawHome is an app that builds secure virtual homes for your Claws directly on your Mac with click of a button.

You don't need to buy a separate mac anymore.

## Screenshots

**Your bots' homes** — List, start, stop, and access your homes.

![Your bots' homes](screenshots/0.png)

**Preparing a home** — Automatic IPSW download and home creation.

![Preparing a home](screenshots/1.png)

**Home Access** — Full macOS guest in a window.

![Home Access](screenshots/3.png)

## Features

- **macOS VMs** — Create macOS guests with automatic IPSW download (latest supported) or use your own
- **Storage** — VMs live in `~/clawhome/homes/{name}/`
- **Shared directories** — Host folders accessible from the guest
- **Clipboard sync** — Copy and paste between host and guest

## Data locations

All data lives under `~/clawhome/` so it persists across app updates:

| Path | Purpose |
| ---- | ------- |
| `~/clawhome/homes/` | VM disk images and configs |
| `~/clawhome/Shared/` | Shared clipboard (guest mounts at /Volumes/My Shared Files) |
| `~/clawhome/userData/` | Electron app data (cookies, cache, etc.) |

## Directory sharing

When a VM is running, these host directories are shared and appear in the guest at `/Volumes/My Shared Files/`:

| Host path                      | Guest path                           | Writable |
| ------------------------------ | ------------------------------------ | -------- |
| `~/Downloads`                  | `/Volumes/My Shared Files/Downloads` | Yes      |
| `~/clawhome/Shared/clipboard` | `/Volumes/My Shared Files/clipboard` | Yes      |

## Clipboard syncing

**Right-click dock icon → Paste to [name]'s home** — Copy on the host (Cmd+C), then right-click the VM icon in the dock and choose "Paste to [name]'s home" to paste into the guest.

## Requirements

- Apple Silicon Mac
- macOS 13 or later

## Build and run

```bash
./launch.sh
```

Or build for release:

```bash
./build.sh
```

Output is in `release/{version}/` (e.g. `release/1.0.0/`).

## Uninstall

1. Quit ClawHome if it is running.
2. Move the app to Trash (from Applications or wherever you installed it).
3. Remove the data folder:

   ```bash
   rm -rf ~/clawhome
   ```

## Project structure

```
clawhome/
├── electron/          # Electron main process, preload
├── src/               # Renderer UI
├── claw-vm/           # Swift VM backend (ClawVM)
└── scripts/           # Build scripts
```
