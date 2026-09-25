# Testing a real AirDrop (iPhone → Mac)

About 15 minutes. You need the iPhone, this Mac, and a Terminal window. Nothing here touches
files that are already in `~/Downloads`: the watcher only handles AirDrops that arrive **after**
it starts, and every rename can be undone.

## 1. Build and check the backend

```sh
cd betterairdrop                  # your clone of the repo
swift build -c release
.build/release/betterairdrop auth status
```

`auth status` should end with `Claude would use: Anthropic CLI login (ant)` (or your API key).
If it says `No credential found`, run `.build/release/betterairdrop auth login`, or carry on anyway:
Apple Vision will name the photos instead (flatter names, but the rest of the test still works).

## 2. Start the watcher

```sh
.build/release/betterairdrop watch --foreground 2>&1 | tee /tmp/betterairdrop-watch.txt
```

You should see one line like
`betterairdrop: watching ~/Downloads for AirDrop arrivals · backend claude (Apple Vision if it fails) · Ctrl-C to stop`.
The first time Claude is used, a short notice about what gets sent is printed too. Leave this
window open for the whole test.

## 3. AirDrop these, one group at a time

Wait for each group's notification before sending the next, so each group is its own batch.

| # | What to send | What should happen |
|---|---|---|
| A | **3–4 ordinary photos** (camera shots, things and places) | One batch. Each becomes `YYYY-MM-DD_city_short-description.jpg`; the HEICs go to the Trash. |
| B | **1 screenshot** | Stays a PNG: `YYYY-MM-DD_screenshot_what-is-on-screen.png` (no city). |
| C | **1 receipt or printed document** (take a fresh photo of one) | `…_receipt_store_12-34.jpg` for a receipt, or `…_doc_topic.jpg` for a page. |
| D | **1 Live Photo** (the LIVE badge is on in Photos) | The photo becomes a `.jpg`, and if a `.mov` arrives with it, the `.mov` gets the **same name**. If only the photo arrives, tap **Options** at the top of the share sheet, turn on **All Photos Data**, and send it again. |
| E | **A batch of about 6 photos** selected together | **One** notification ("Renamed 6 photos") and one batch in the terminal. |

For each batch, the terminal prints something like:

```
[14:03:12] batch 20260924-140312-ab12
  ✓ IMG_5301.HEIC  →  2026-09-24_toronto_walnut-lamp-on-oak-sideboard.jpg
Renamed 1 photo. Undo: betterairdrop undo --batch 20260924-140312-ab12  (Claude: 1 photos, about $0.0017)
```

and macOS shows one notification titled **BetterAirdrop**. The notification comes from `osascript`,
so macOS may first ask whether "Script Editor" may send notifications; allow it. If no
notification appears, check System Settings → Notifications → Script Editor. The terminal output
is what counts.

Also check in Finder that the new names look right and the originals are in the Trash.

## 4. Undo

Try undo on at least one batch:

```sh
.build/release/betterairdrop log -n 30          # every batch with old → new names
.build/release/betterairdrop undo               # puts the most recent batch back (HEICs return from the Trash)
.build/release/betterairdrop undo --batch ID    # a specific batch, ID from the log
```

Undo refuses to touch a file you've edited since BetterAirdrop wrote it (use `--force` if you mean it).
Keep the renamed files if you like the names; undo is optional.

## 5. Stop

Press **Ctrl-C** in the watcher window. It finishes the batch it's on and exits (Ctrl-C twice
quits at once).

## 6. What to paste back

1. The terminal output: `cat /tmp/betterairdrop-watch.txt`. It holds file names and the generated
   descriptions; remove any you'd rather not share.
2. For each group (A–E): roughly how many seconds from "AirDrop finished" on the phone to the
   notification, and whether exactly one notification appeared.
3. For D: did a `.mov` arrive, and does it share the photo's new name?
4. Any names you'd score 0 (wrong) or 1 (vague), on the 0–2 scale in `docs/spikes.md`.
5. Any line starting with `note:` (e.g. Claude failing and Vision taking over), `skip` or `✗`.
6. Did undo put everything back?

If anything looks wrong, `.build/release/betterairdrop explain <file>` shows the context and the
reasoning behind a name; paste that too.
