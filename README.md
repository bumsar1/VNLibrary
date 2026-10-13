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
- **Blur cover** — per game, from the right-click menu. Images VNDB flags as suggestive are blurred in Discover and galleries with a *Show* button (can be turned off in Settings). Library covers VNDB flags as suggestive are blurred automatically; their pixels are blurred, so nothing shows through
- **Activity tracker** — every session is logged with its day, start and end time and length. The Activity tab shows today / week / month / all-time totals, your streak, a year-long heatmap of the days you played (click a day to see its sessions), your top games and the full session log. Idle time (no input for 10 minutes) doesn't count
- **Progress** — play time against VNDB's estimated length on each game's page
- **Discover** — search and browse all of VNDB (best match, highest rated, most popular, newest), with VNDB's filters: release language (defaults to Japanese), original language, platform, length, rating, release date, finished only, tags and developer. Click a developer on any game page to see everything they made. Filters are remembered. 18+ VNs get a red border. Add anything to your library as *Plan to play*; when you later drop in its game folder, it's linked to that entry automatically
- **Image gallery** — every screenshot and package scan VNDB has for a game, on its page and in Discover. Click for a large view, step through with the arrow keys, and use any image as the cover
- **jiten.moe** — length in characters, difficulty, unique words and kanji for each VN, and with a jiten.moe API key how much of its vocabulary you already know
- **Japanese titles** — show VNDB's original titles (e.g. グリザイアの果実) instead of romaji
- **Routes** — the heroines from VNDB as a checklist with portraits; tick off cleared routes, add your own (e.g. a true ending). Cards show "2/8 routes"
- **Companion apps** — open apps like Meikipop alongside every game, or a single one; they close again when the game quits
- **Weekly goal and Year in Review** — a goal ring on the Activity tab, and a yearly summary: hours, days played, longest streak, best day, months, most played and finished games
- **Try with Whisky / CrossOver** — run a game's .exe through one of your Wine bottles (with a Japanese locale) to see if it plays well, and keep the setup if it does
- **siglus_engine updates** — checks GitHub for a newer siglus_rs and pulls + rebuilds it with one click
- **Status, rating and notes** — Playing / Finished / On hold / Dropped / Plan to play, your own 1–10 rating and notes per game. Starting a game marks it as Playing
- **VNDB list sync** — connect your VNDB account (API token, kept in the keychain) and status, rating, notes and dates are sent to your list as you change them; import your existing list in one click
- **Collections** — your own groups, e.g. "Key games"
- **Ready to play / Not installed** — the library is split into games you can launch right now and ones without a folder yet (added from Discover, or moved)
- **Filter** — by status, collection, tag or installed, with removable filter chips; sort by last played, name, date added or your rating
- **Random pick** — the dice button (⌘R) picks something from your Plan to play list
- **Couch mode** — full-screen, console-style browsing (⌘⇧F) with arrow keys or a game controller: rows for Continue playing, Ready to play and Not installed, plus VNDB categories (new releases, coming soon, highest rated, most popular, hidden gems, and picks based on your favourite tags) that you can add to Plan to play from the sofa. Search with an on-screen keyboard (ABC, hiragana, katakana). Games started here open in full screen. A VNDB screenshot of the selected game fills the background, with soft UI sounds
- **Discreet mode** — one click (⌘⇧D) blurs every cover and hides adult games and sexual tags
- **Search** — matches names, VNDB titles (incl. Japanese), developers and tags

<p align="center">
  <img src="docs/info.png" alt="Game page">
</p>

<p align="center">
  <img src="docs/activity.png" alt="Activity tracker">
</p>

<p align="center">
  <img src="docs/discover.png" alt="Discover">
</p>

<p align="center">
  <img src="docs/couch.png" alt="Couch mode">
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
