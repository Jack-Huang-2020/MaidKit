# MaidKit

<p align="center">
  <img src="assets/icons/icon-padded.png" width="120" alt="MaidKit Logo">
</p>

<p align="center">
  <b>A cross-platform SSH server manager</b>
</p>

<p align="center">
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-AGPL--3.0-blue" alt="License"></a>
  <a href="https://solsynth.dev/zh/products/maid-kit#download"><img src="https://img.shields.io/badge/download-solsynth.dev-blue" alt="Download"></a>
</p>

<p align="center">
  English · <a href="README_ZH.md">简体中文</a>
</p>

---

MaidKit is a collection of tools used by LittleSheep when acting as a "maid" for servers (i.e., performing server maintenance). The goal is to provide a more convenient way to maintain servers that is non-intrusive — being 100% SSH-based, without installing any software on the server or increasing security risks.

Built with Flutter, MaidKit runs on desktop and mobile platforms alike. Inspired by the [Island](https://github.com/Solsynth/HyperNet.Surface) project's desktop-native approach, it brings the same calm, functional philosophy to server administration.

---

## Table of Contents

- [Features](#features)
- [Getting Started](#getting-started)
- [Architecture](#architecture)
- [Tech Stack](#tech-stack)
- [Contributing](#contributing)
- [Licensing](#licensing)

---

## Features

### Servers

| Feature | Description |
|---------|-------------|
| Dashboard | Grid of server cards with live status, load, memory, and uptime; reorder via context menu, organize into groups, tag, and customize with environment variables |
| Activity | Real-time performance charts (CPU, memory, network, disk) |
| Terminal | Full SSH terminal with split panes, drag-and-drop tabs, command palette, and terminal color schemes |
| File Management | Dual-pane SFTP browser with drag-and-drop transfers, in-app editor, and keyboard shortcuts (copy/cut/paste, rename, refresh, search, delete) |
| Processes | List and kill running processes |
| Services | Systemd unit management (start/stop/enable/disable) |
| Web Servers | nginx and Caddy configuration management |
| Crontab | Edit scheduled tasks |
| Packages | Package management (apt, dnf, and more) |
| Firewall | UFW, firewalld, nftables, and iptables management |
| Port Forwarding | Local and remote tunnel configuration |
| Proxy | Reach hosts through a per-server HTTP CONNECT or SOCKS5 proxy |
| Tailscale | Connect over your tailnet with an embedded node — no Tailscale app required |

### Containers

- Docker and Podman container management
- Start, stop, restart, pause, kill, and remove containers
- Compose project grouping with detail view (per-service status, merged logs, lifecycle actions)
- Container image management
- Runtime installation assistance

### Projects

- Deployment project catalog
- Group compose stacks, web servers, and containers
- Import and export as TOML

### Snippets

- Create and edit reusable shell scripts
- Execute on one or more connected servers
- Streaming output with progress tracking

### Agent

- Chat with an AI agent that can operate your servers through tools
- Bring your own AI provider or use Solar Network AI
- MCP servers and reusable skills extend the agent's toolset
- Proposed actions require approval (review mode) before they run
- Conversation history is stored on-device, outside the vault

### GitHub

- Sign in with device-flow authorization
- Pin repositories and follow workflow runs, pull requests, and releases
- GitHub tools are available to the agent

### Local MCP Server

- Expose MaidKit's SSH servers, snippets, and skills to other agents on this machine through a local Model Context Protocol server
- Connect from Claude Desktop or any MCP client

### Security

- AES-GCM 256-bit encrypted credential vault
- PBKDF2 key derivation (310,000 iterations)
- Biometric unlock support
- Optional per-vault cloud sync over encrypted blobs (Solar Network)
- Encrypted backup archives (.mkb)

### Settings

- Theme (system/light/dark), accent color, and workspace background image
- Language (English / 简体中文)
- Terminal renderer selection (Ghostty libghostty-vt or xterm), font, and color scheme
- Connect on startup
- Hide server addresses when screen sharing or recording
- Metrics refresh intervals
- Tailscale sign-in and connection settings
- Cloud sync per vault, import and export of server connections

---

## Getting Started

### Prerequisites

- [Flutter SDK](https://flutter.dev) installed (SDK ^3.12.2)
- For iOS App Store archives, install Zig 0.15.2 for the vendored Ghostty
  terminal library. The current Ghostty source is not compatible with Zig 0.16:
  ```bash
  brew install zig@0.15
  ```
- For Windows development, install [NASM](https://www.nasm.us) (required by `webcrypto` native assets):
  ```powershell
  winget install NASM.NASM
  ```
- For Linux development, install additional dependencies:
  ```bash
  sudo apt-get update -y
  sudo apt-get install -y \
    ninja-build \
    libgtk-3-dev \
    libayatana-appindicator3-dev \
    keybinder-3.0 \
    libnotify-dev
  ```

### Running the App

```bash
# Install dependencies
flutter pub get

# Run in debug mode
flutter run

# Build release version
flutter build <platform>
```

### Linux AppImage

Bundle a self-contained AppImage for Linux after building the release bundle:

```bash
flutter build linux
bash buildtools/build-appimage.sh
```

The script packs the x64 release bundle with the desktop entry and run helpers
into `MaidKit-x86_64.AppImage`.

### iOS App Store Archive

The bundled Ghostty terminal library is compiled from source for iOS so the
binary is linked by Apple's linker and includes the encryption metadata
required by App Store Connect. After installing `zig@0.15`, the build hook
selects it automatically when creating an IPA:

```bash
flutter clean
flutter pub get
flutter build ipa
```

The build stops if the generated Ghostty framework lacks
`LC_ENCRYPTION_INFO_64`, preventing an invalid IPA from being produced.

### Development

After changing route annotations or Drift schema:

```bash
dart run build_runner build
```

Run checks before committing:

```bash
dart format lib test
flutter analyze
flutter test
```

---

## Architecture

Features are flat and live directly under `lib/<feature>/`. The app uses:

- **Riverpod** for state management with `ConsumerWidget` for reactive views
- **auto_route** for declarative nested navigation
- **Drift** for local SQLite persistence
- **dartssh2** for SSH connections
- **island_ui_foundation** for the desktop window frame

See [docs/architecture.md](./docs/architecture.md) for the full architecture guide.

---

## Tech Stack

| Layer | Technology |
|-------|------------|
| **Framework** | Flutter with Material 3 |
| **State** | Riverpod + flutter_hooks |
| **Navigation** | auto_route |
| **Database** | Drift (SQLite) |
| **SSH** | dartssh2 |
| **Encryption** | cryptography (AES-GCM, PBKDF2) |
| **Terminal** | libghostty-vt / xterm |
| **Tailscale** | tailscale (embedded node, macOS/Linux) |
| **MCP** | Model Context Protocol client + local server |
| **Desktop** | window_manager + island_ui_foundation |

---

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

---

## Licensing

This project is licensed under the GNU Affero General Public License v3.0 (AGPL-3.0).

If you deploy an instance, fork this project, or redistribute modified versions of this software, you must comply with the AGPL-3.0 license terms, including:

- Including a copy of the original license
- Preserving existing copyright notices and attribution
- Clearly stating any modifications you made
- Providing corresponding source code to users interacting with the service over a network

Original authorship and copyright attribution to LittleSheep, Solsynth, and this project's contributors must be retained where applicable.

Please note that the AGPL-3.0 license applies to the software source code only. Certain assets, logos, icons, branding materials, and trademarks may be licensed separately and are not automatically covered under the same terms.

See [LICENSE.txt](./LICENSE.txt) for the full license text.

---

<p align="center">
  Made by LittleSheep with ❤️
</p>
