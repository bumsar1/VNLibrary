# VN Library

<p align="center">
  <img src="logo.png" width="160" alt="VN Library logo">
</p>

<p align="center">
  A native macOS library and launcher for visual novels — with covers, tags and info from <a href="https://vndb.org">VNDB</a>.
</p>

<p align="center">
  <a href="https://github.com/bumsar1/VNLibrary/releases/latest">
    <img src="https://img.shields.io/github/v/release/bumsar1/VNLibrary?label=Download&style=for-the-badge&color=7c3aed" alt="Download">
  </a>
  &nbsp;
  <img src="https://img.shields.io/badge/macOS-14%2B-black?style=for-the-badge" alt="macOS">
  &nbsp;
  <img src="https://img.shields.io/badge/Swift-SwiftUI-black?style=for-the-badge" alt="Swift">
</p>

<p align="center">
  <img src="docs/library.png" alt="Library">
</p>

---

## Install

1. Download **VN-Library.dmg** from the [latest release](https://github.com/bumsar1/VNLibrary/releases/latest)
2. Open the DMG and drag **VN Library** into your Applications folder
3. The app isn't notarized, so the first time: right-click it → **Open**

Or build it yourself (needs Xcode):

```bash
./build_app.sh
```

---

## Features

- **Drag & drop** — drop game folders or Mac apps into the window (or onto the Dock icon)
- **VNDB** — cover, description, developer, release year, length, rating and tags are fetched automatically; pick the right entry yourself with *Fetch from VNDB…** if the guess was wrong
- **Tags** — click a tag on a game's page, or use the **Tags** menu, to filter the library. Sexual-content tags are shown in pink and can be hidden in Settings; spoiler tags are never shown
- **Blur cover** — per game, from the right-click menu. Covers VNDB flags as suggestive are blurred automatically. The pixels themselves are blurred, so nothing shows through
- **Play time** — tracks when you last played and for how long
- **Search** — matches names, VNDB titles (incl. Japanese), developers and tags

<p align="center">
  <img src="docs/info.png" alt="Game page">
</p>

## Launching games

| Kind | How it starts |
|---|---|
| **Siglus** (Key games: Summer Pockets, Clannad, …) | Detected automatically (`Scene.pck` + `Gameexe.dat`). Runs [`siglus_engine`](https://github.com/xmoezzz/siglus_rs) built from source — it scales the game to fill the window, which the prebuilt Siglus.app doesn't. Set its path under Settings. |
| **Mac app** | Any `.app` — a Ren'Py port, a CrossOver/Whisky shortcut, … |
| **Custom command** | Run in `zsh` with the game folder as working directory; `$GAME_DIR` is its path. E.g. `open -a Whisky "$GAME_DIR/game.exe"` |

### Building siglus_engine

```bash
git clone --depth 1 https://github.com/xmoezzz/siglus_rs ~/siglus_rs
cd ~/siglus_rs && cargo build --release -p siglus_scene_vm --bin siglus_engine
```

The default path in Settings is `~/siglus_rs/target/release/siglus_engine`.

---

Library data lives in `~/Library/Application Support/VN Library/`. Game data from [VNDB](https://vndb.org) (ODbL).
