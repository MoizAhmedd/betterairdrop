# Testing the menu-bar app

About 30 minutes: build (5), the signing spike (10), a real AirDrop (15). Nothing here renames
files already in `~/Downloads`; the app only touches AirDrops that arrive after it starts, and
every rename can be undone.

Before you start: quit any `betterairdrop watch --foreground` running in Terminal.

## 1. Build and launch

```sh
cd <your clone>
git pull
scripts/make-app.sh                      # → .build/app/BetterAirdrop.app (ad-hoc signed)
swift test                               # should end "Test run with … tests passed"
```

### 1a. A dry run against a test folder (no permission prompts)

```sh
S=/tmp/betterairdrop-try; mkdir -p $S/Drop
printf 'backend = "vision"\n\n[watch]\nfolder = "%s/Drop"\n' $S > $S/config.toml
BETTERAIRDROP_HOME=$S/state BETTERAIRDROP_CONFIG=$S/config.toml \
  .build/app/BetterAirdrop.app/Contents/MacOS/BetterAirdrop &
```

- No wizard: the menu opens by itself with "Ready: watching Drop". (Add
  `BETTERAIRDROP_NO_LOGIN_ITEM=1` to the command above so this throwaway build doesn't register a
  login item.) The setup screens are still in Settings → General → **Open Setup…**.
- The tag icon appears in the menu bar. Then drop three fake AirDrops into the test folder:

```sh
scripts/simulate-airdrop.sh $S/Drop 3
```

- Within about 5 s, click the icon: three rows with thumbnails. Hover one → ↺ Undo → the row
  greys out with ↻ Redo. Try Pause › For 1 Hour, then Resume.
- In Terminal: `BETTERAIRDROP_HOME=$S/state BETTERAIRDROP_CONFIG=$S/config.toml .build/app/BetterAirdrop.app/Contents/Helpers/betterairdrop watch --foreground`
  should refuse politely ("The BetterAirdrop app is already watching…").
- Quit from the menu (⌘Q), then reset: `defaults delete dev.betterairdrop.app; rm -rf $S`.

### 1b. The real thing

```sh
ditto .build/app/BetterAirdrop.app ~/Applications/BetterAirdrop.app
open ~/Applications/BetterAirdrop.app
```

- Straight away macOS asks *"BetterAirdrop would like to access files in your Downloads folder"*
  → **Allow**. That's the only prompt at launch. The menu then opens by itself: "Ready: watching
  Downloads", the engine line, and launch at login is on.
- No credential? If `ANTHROPIC_API_KEY` is exported in your `~/.zshrc`, the menu offers "Found
  ANTHROPIC_API_KEY in your shell. Use it for photo names?" → **Use It** (saved to
  `~/Library/Application Support/betterairdrop/credentials`, 0600). Otherwise it shows
  "Better names: add a Claude key". With an `ant` login, neither appears.
- If Downloads has old `IMG_…` files: a "Found N unnamed photos in Downloads…" row → the preview
  (20 at a time, with a cost estimate). Nothing is renamed until **Rename**; that first rename
  asks for notifications → **Allow**.
- To see the first run again: `defaults delete dev.betterairdrop.app`.

Note: every rebuild of an ad-hoc app is a "new app" to macOS, so a rebuilt copy asks for
Downloads again. The panel shows an orange **Fix…** bar when that happens.

## 2. The signing spike (M7)

It decides whether a free self-signed certificate keeps permissions across updates. It builds a
tiny throwaway app (never touching your files beyond counting Downloads entries) and walks you
through six launches, pausing before each one:

```sh
scripts/spike-signing.sh walk
```

What to click, in order:

1. **signed v1**: Downloads prompt → **Allow**; notifications prompt → **Allow**; hover the banner → **Undo**.
2. **signed v2**: expect **no prompt at all**. If one appears, note it, then Allow. Banner → **Undo**.
3. **adhoc v1**: Downloads → **Allow**; notifications → **Allow**.
4. **adhoc v2**: probably prompts again. Downloads → **Don't Allow**; a Keychain prompt → **Deny**. Note what appeared.
5. **panel v1**: an Open panel at Downloads → **Grant Access**. Note whether a prompt appears too.
6. **panel v2**: note any prompt → **Don't Allow**.

Then:

```sh
scripts/spike-signing.sh results      # copy all of this
scripts/spike-signing.sh cleanup      # removes the apps, Keychain items and their TCC entries
```

## 3. A real AirDrop through the app

With the app from 1b running (no Terminal needed):

| # | Send from the iPhone | Expect |
|---|---|---|
| A | 3–4 ordinary photos | **one** banner "Renamed 4 photos" with a thumbnail; one group of rows in the menu |
| B | 1 screenshot | stays a PNG: `…_screenshot_….png` |
| C | a batch of ~6 photos | one banner within ~10 s of the transfer finishing |
| D | 1 Live Photo | the `.mov` (if it arrives) gets the photo's name |

Then:

- Hover a banner → **Undo** → it changes to "Undone". Check Finder: originals back.
- In the menu, hover a row → ↺; then ↻ Redo.
- Edit a renamed JPEG (e.g. rotate it in Preview), then undo it → "Undo anyway?" alert.
- Finder: right-click a HEIC → Services → **Rename with BetterAirdrop** → the preview window.
  (If it isn't listed, enable it in System Settings → Keyboard → Keyboard Shortcuts → Services.)
- Drag a photo onto the menu-bar icon → the same preview.
- Settings → Advanced → **Install** the CLI; `betterairdrop status` in a new Terminal.
- Revoke Downloads (System Settings → Privacy & Security → Files & Folders → BetterAirdrop off),
  AirDrop one more photo → orange dot on the icon and one "can't read Downloads" banner.
  **Fix…** → turn it back on → the window flips to ✓ on its own.
- Activity Monitor: BetterAirdrop at 0.0% CPU while nothing is arriving.

Uninstall when done (keeps your rename history unless you add `--purge`):

```sh
~/Applications/BetterAirdrop.app/Contents/Helpers/betterairdrop uninstall
```

## 4. What to report back

1. The whole output of `scripts/spike-signing.sh results`, plus which prompts you saw at each of
   the six steps (especially step 2: any prompt at all?).
2. For the AirDrop test: did each batch give exactly one banner, how long after the transfer, and
   did the thumbnail and the Undo / Show in Finder buttons appear?
3. Anything that looked off against the mockups (ux.html), with a screenshot.
4. Whether the Services entry showed up in Finder without enabling it by hand.
5. Settings → Advanced → **Copy Report** output (no file names or keys in it).
