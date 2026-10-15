# BetterAirdrop

**No more IMG_4821.HEIC.** AirDropped photos get names you can search for.

[betterairdrop.com](https://betterairdrop.com/)

```
IMG_4821.HEIC  →  2026-09-21_toronto_walnut-lamp-on-oak-sideboard.jpg
IMG_4822.PNG   →  2026-09-21_screenshot_failed-payment-notice.png
```

## Install

```sh
brew install moizahmedd/tap/betterairdrop
```

No Homebrew? `curl -fsSL https://betterairdrop.com/install | sh`

macOS 13 or later. It opens in the menu bar and asks for Downloads access once. If
`ANTHROPIC_API_KEY` is set in your shell (or you're logged in with `ant`), it offers to use it;
otherwise it uses Apple Intelligence (macOS 26+, when it's on) or Apple Vision. Photos already in
Downloads can be previewed and renamed from the menu.

### Installing with an AI agent

Tell Claude Code or Codex: *"Install BetterAirdrop by following
https://github.com/MoizAhmedd/betterairdrop/blob/main/docs/install-for-agents.md"*. It runs:

```sh
curl -fsSL https://betterairdrop.com/install | sh -s -- --yes --engine vision --launch-at-login
betterairdrop status --json      # "ready": true, or next_steps says what's left
```

You click **Allow** on macOS's Downloads prompt (and the notifications prompt, if you want banners).
Nothing else needs a click.

Signed with the project's own certificate rather than an Apple Developer ID, so it isn't notarized.
Both install paths leave it unquarantined, so there's no Gatekeeper dialog.
([Details](docs/release/README.md).)

## What it does

- Names from date, city, kind and content
- HEIC → JPEG, originals to the Trash
- Undo from the notification or the menu
- Touches only what AirDrop delivered

## Build from source

Needs Xcode 16 or the Command Line Tools. Apple Intelligence naming needs Xcode 26 or later.

```sh
git clone https://github.com/MoizAhmedd/betterairdrop.git && cd betterairdrop
scripts/make-app.sh && open .build/app/BetterAirdrop.app
```

## Naming engines

| Engine | Runs on | Sends |
|---|---|---|
| Claude Haiku (your API key) | Anthropic | a 768 px copy with GPS and EXIF stripped; the date, city name, camera model, kind and a short text snippet go as text |
| Hosted naming (Pro) | BetterAirdrop's server, then Anthropic | the same, plus your Pro license key; the server keeps no photos, context or names |
| Apple Vision | your Mac | nothing |
| Apple Intelligence (macOS 26+) | your Mac | nothing |

City names come from a built-in table, so coordinates never leave the Mac.

## Command line

```sh
betterairdrop rename --dry-run ~/Downloads/IMG_*.HEIC
betterairdrop undo
```

`brew` and the installer link it; Settings → Advanced can too. Reference: [docs/cli.md](docs/cli.md).

## Pro

Free does everything above. Pro, $19 once for 3 Macs, adds:

- Screenshots, named as you take them
- Any folder you choose
- A name builder
- Whole folders renamed at once

[Details](docs/cli.md#betterairdrop-pro).

## License

MIT. City data © [GeoNames](https://www.geonames.org), CC BY 4.0.
