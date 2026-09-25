# BetterAirdrop

**No more IMG_4821.HEIC.** AirDropped photos get names you can search for.

[moizahmedd.github.io/betterairdrop](https://moizahmedd.github.io/betterairdrop/)

```
IMG_4821.HEIC  →  2026-09-21_toronto_walnut-lamp-on-oak-sideboard.jpg
IMG_4822.PNG   →  2026-09-21_screenshot_failed-payment-notice.png
```

## Install

```sh
brew install moizahmedd/tap/betterairdrop
```

No Homebrew? `curl -fsSL https://moizahmedd.github.io/betterairdrop/install | sh`

macOS 13 or later. It opens in the menu bar and asks for Downloads access once. If
`ANTHROPIC_API_KEY` is set in your shell (or you're logged in with `ant`), it offers to use it;
otherwise it names photos with Apple Vision. Photos already in Downloads can be previewed and
renamed from the menu.

Signed with the project's own certificate rather than an Apple Developer ID, so it isn't notarized.
Both install paths leave it unquarantined, so there's no Gatekeeper dialog.
([Details](docs/release/README.md).)

## What it does

- Names from date, city, kind and content
- HEIC → JPEG, originals to the Trash
- Undo from the notification or the menu
- Touches only what AirDrop delivered

## Build from source

Needs Xcode 16 or the Command Line Tools.

```sh
git clone https://github.com/MoizAhmedd/betterairdrop.git && cd betterairdrop
scripts/make-app.sh && open .build/app/BetterAirdrop.app
```

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

`brew` links it; otherwise Settings → Advanced installs it. Reference: [docs/cli.md](docs/cli.md).

## License

MIT. City data © [GeoNames](https://www.geonames.org), CC BY 4.0.
