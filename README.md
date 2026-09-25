# BetterAirdrop

**No more IMG_4821.HEIC.** AirDropped photos get names you can search for.

```
IMG_4821.HEIC  →  2026-09-21_toronto_walnut-lamp-on-oak-sideboard.jpg
IMG_4822.PNG   →  2026-09-21_screenshot_failed-payment-notice.png
```

> **Pre-release.** A menu-bar app for macOS 13+. The one-line install is coming with v0.3;
> for now, build it from source. (Formerly `airname`.)

## What it does

- Names from date, city, kind and content
- HEIC → JPEG, originals to the Trash
- Undo from the notification or the menu
- Touches only what AirDrop delivered

## Build and run from source

Needs Xcode 16 or the Command Line Tools.

```sh
git clone https://github.com/MoizAhmedd/betterairdrop.git && cd betterairdrop
scripts/make-app.sh
open .build/app/BetterAirdrop.app
```

It appears in the menu bar and asks for Downloads access once.

## Install (coming with v0.3)

```sh
curl -fsSL https://moizahmedd.github.io/betterairdrop/install.sh | sh
```

Not live yet.

## Naming engines

| Engine | Runs on | Sends |
|---|---|---|
| Claude Haiku (your API key) | Anthropic | a 1024 px copy, no location or camera data |
| Apple Vision | your Mac | nothing |
| Apple Intelligence (macOS 27) | your Mac | nothing (planned) |

City names come from a built-in table, so coordinates never leave the Mac.

## Command line

```sh
betterairdrop rename --dry-run ~/Downloads/IMG_*.HEIC
betterairdrop undo
```

Settings → Advanced installs it. Reference: [docs/cli.md](docs/cli.md).

## License

MIT. City data © [GeoNames](https://www.geonames.org), CC BY 4.0.
