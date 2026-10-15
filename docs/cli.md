# Command-line reference

The app bundles the `betterairdrop` command (the installer, or Settings → Advanced → Install, puts
it at `~/.local/bin/betterairdrop`; Homebrew links it too). Everything the app does is available here too; both share the
same config, journal and undo.

## Naming backends

| Backend | Where it runs | What it sends | Names look like |
|---|---|---|---|
| `claude` (Claude Haiku 4.5) | Anthropic's API | a 768 px JPEG re-encoded **with all metadata removed** (no EXIF, no GPS), plus text: the date, the city name, the camera model, the detected kind, on-device labels, a short OCR snippet and a device hint | `cinema-seating-in-empty-theatre` |
| `hosted` (Pro: Claude with no API key) | BetterAirdrop's server, then Anthropic's API | what `claude` sends, plus your Pro license key. The server keeps no photos, context or names. 500 names a month | like `claude` |
| `vision` (Apple Vision) | on your Mac | nothing | `auditorium`, `window-brick` |
| `apple` (Apple Intelligence, Foundation Models) | on your Mac, macOS 26+ with Apple Intelligence on | nothing | named from Vision's labels and text (the on-device model reads text, not pixels) |

`backend = "auto"` (the default) uses **Claude when a credential is found, else hosted naming when
this Mac has an active Pro license, else Apple Intelligence when it's ready, otherwise Vision**.
When hosted naming can't name a photo (the license is invalid, the month's 500 names are used, or
the server can't be reached), Apple Intelligence names it if it's ready, otherwise Vision. If Apple Intelligence isn't available, `--backend apple`
says why (off in System Settings → Apple Intelligence & Siri, model still downloading, Mac not
supported, macOS older than 26). Like Claude, it falls back to Vision for any photo it can't name.
Vision always runs anyway: it supplies the OCR text, kind hints and labels that go into Claude's
context, and it names the photo by itself if Claude fails for any reason (no network, timeout,
rate limit, refusal), so a rename never fails because of the network. The first time Claude is
used, BetterAirdrop prints a one-time notice saying what gets sent.

PDFs (Pro, see [Naming PDFs](#naming-pdfs-pro)) go to the same engine, as text only.

To keep everything on-device, set `backend = "vision"` or turn Claude (and hosted naming) off for `auto`:

```toml
[claude]
auto = false
```

Claude costs about $1.9 per 1,000 photos at Haiku 4.5's prices ($1/M input tokens, $5/M
output), measured on real AirDrops. On the same photos its names scored about 92% against Vision's 42%
(see [spikes.md](spikes.md)). Anthropic doesn't train on
API inputs. Vision's names are honest but flat (they read like tags); the spike notes have the scores.

### Giving BetterAirdrop a Claude credential

BetterAirdrop looks for a credential in this order and uses the first one it finds:

1. **`ANTHROPIC_API_KEY`** in the environment (sent as `x-api-key`).
2. **A stored API key**, saved by `betterairdrop auth claude` (hidden prompt) or the app, in
   `~/Library/Application Support/betterairdrop/credentials` (mode 0600 in a 0700 folder, like the
   `ant` CLI's tokens; never logged). Not the Keychain: its access list is tied to the code
   signature, so every update would ask again (spikes.md §f). A key left in the Keychain by an
   older build is moved to the file once. Remove it with `betterairdrop auth logout`.
3. **The Anthropic CLI's login.** If the Anthropic CLI `ant` (`brew install anthropics/tap/ant`) is
   installed and logged in, BetterAirdrop runs `ant auth print-credentials --access-token` and uses
   that OAuth token (`Authorization: Bearer …`). `betterairdrop auth login` runs `ant auth login` for
   you, or tells you to `brew install anthropics/tap/ant` first. The token is kept in memory for
   one run only.

`betterairdrop auth status` shows which source would be used, without printing any secret.

## Commands

```
betterairdrop watch --foreground [--dir DIR] [--backlog]   name AirDrops as they arrive (Ctrl-C to stop)
        [--backend auto|claude|vision] [--no-notify]
betterairdrop rename <files…> [--dry-run] [--json]         name (and convert) specific files
        [--backend auto|claude|vision] [--template STR] [--originals trash|keep|delete] [--format jpeg|keep] [--airdrop-only]
betterairdrop explain <file>                               show the context and why it picked that name
betterairdrop undo [--last | --batch ID | <file>]          put files back exactly as they were
betterairdrop log [-n 20]                                  recent renames
betterairdrop auth claude | status | login | logout        set up the Claude credential
betterairdrop setup [--engine auto|claude|vision|apple]    set up without the app's windows (scripts, AI agents)
        [--api-key-env VAR | --api-key-stdin] [--no-verify] [--[no-]launch-at-login] [--[no-]notify] [--no-open] [--yes]
betterairdrop status [--json]                              is anything renaming AirDrops, what's missing, this month's totals
betterairdrop license activate <key> | status [--json] | deactivate   BetterAirdrop Pro on this Mac
betterairdrop uninstall [--purge]                          remove the app, login item, key, CLI link and permission
```

`setup` writes the same config the app's Settings do, stores the key (verified with Anthropic
unless `--no-verify`), records that setup is done, and opens the app. The app's first launch then
only shows macOS's Downloads prompt and, if notifications are on, the notifications prompt. A
running app picks up the changes straight away. Without `--yes`, it asks before changing anything,
and refuses when stdin isn't a terminal. `status --json` reports the permissions the app last saw
and a `next_steps` list, each step marked `human` or `agent`. Both are described in
[install-for-agents.md](install-for-agents.md).

What `rename` (and each watcher batch) does, in order: it writes the new JPEG next to the
original and syncs it to disk, records it in the journal
(`~/Library/Application Support/betterairdrop/journal.jsonl`), gives it its final name (it never
overwrites: a clash becomes `-2`, `-3`…), and only then moves the original HEIC to the Trash.
`betterairdrop undo` brings the original back from the Trash, and refuses if you've edited the output
since. PNG screenshots and JPEGs are renamed, not re-encoded. Running it twice does nothing the
second time.

### How the watcher decides what to touch

- Only the top level of the folder (`watch.folder`, default `~/Downloads`).
- Only images (`heic heif jpg jpeg png dng`) and Live Photo `.mov` files.
- Only files whose `com.apple.quarantine` attribute names `sharingd` (AirDrop). Browser
  downloads, copies and everything else are ignored.
- It waits until a file stops growing and is a complete image, then waits for a 3-second quiet
  spell, so a burst of photos becomes one batch and one notification.
- A Live Photo's `.MOV` gets the same name as its photo. A video on its own is left alone.
- With Pro and `name_pdfs` on, PDFs too: see [Naming PDFs](#naming-pdfs-pro).

## Config

`~/.config/betterairdrop/config.toml`. Every key is optional; the defaults live in
`Sources/BetterAirdropCore/System/Config.swift`. For example:

```toml
backend = "auto"                        # auto | claude | hosted | vision | apple
template = "{date}_{place}_{subject}"   # tokens: date time place country subject kind device merchant total orig
originals = "trash"                     # trash | keep | delete
convert_heic = true
date_format = "yyyy-mm-dd"              # yyyy-mm-dd | yyyymmdd | yyyy-mm | dd-mm-yyyy | mm-dd-yyyy
finder_tags = false                     # Pro, menu-bar app only: tag renamed files with the kind (and city for photos)
name_pdfs = true                        # Pro: also name PDFs from their text (see "Naming PDFs")

[watch]
folder = "~/Downloads"
notify = true
screenshots = false                     # Pro, menu-bar app only: also name new screenshots
extra_folders = []                      # Pro, menu-bar app only: e.g. ["~/Pictures/Inbox"]

[file]                                  # Pro, menu-bar app only: move new arrivals by kind (undo moves them back)
receipt = "~/Documents/Receipts"        # photo | screenshot | receipt | document | whiteboard, and the PDF kinds
                                        # (invoice statement contract form letter ticket manual paper other); "" = leave in place
monthly = true                          # …/Receipts/2026-10/ from the photo's date

[claude]
model = "claude-haiku-4-5"              # any Messages API model id
auto = true                             # let backend = "auto" use Claude (or hosted naming) when a credential (or Pro license) exists

[hosted]
url = "https://api.betterairdrop.com"   # only to test another deployment of hosted/
```

## BetterAirdrop Pro

Everything above is free. Pro ($19 once, 3 Macs, lifetime updates, sold through Polar) adds to the
menu-bar app: naming new screenshots, watching other folders (new images only, same settle rules
and undo), the name builder (parts, order, separator, date format), renaming whole folders
(drop a folder on the menu-bar icon, or Finder → Services) and naming PDFs. The command-line tool
is the same with or without it, except that `rename`, `explain` and `watch` name PDFs too while
this Mac has Pro and `name_pdfs` is on.

```sh
betterairdrop license activate BA_XXXX-XXXX   # uses one of the key's 3 Macs; label = this Mac's name
betterairdrop license status --json           # {"pro": true, "state": "active", "key": "****-ABCD", …}
betterairdrop license deactivate              # frees this Mac's slot
```

The key and this Mac's activation ID are kept in
`~/Library/Application Support/betterairdrop/license` (0600). The app asks Polar about the key at
most once a week, with no account and no server of ours. **Pro stays on when Polar can't be
reached or answers with an error.** Only an explicit "revoked/invalid" answer starts a 14-day grace
period, after which Pro turns off until a valid key is activated.

`state` is `none`, `active`, `grace` (Polar said invalid; `grace_until` says when Pro turns off) or `invalid` (Pro is off). `betterairdrop status --json` carries the same `state` and `pro` under `credentials.license`.

## Naming PDFs (Pro)

On by default with Pro (Settings → Pro → **Name PDFs too**, or `name_pdfs = false` to turn it
off). Without Pro, PDFs are never touched, AirDropped or not.

```
document (3).pdf   →  2026-10-12_invoice_bell-canada_84-12.pdf
scan0004.pdf       →  2026-09-30_lease-agreement-45-carlton-st.pdf
```

**What gets named:** new PDFs in the AirDrop folder that arrived from outside this Mac (their
quarantine flag says downloaded: a browser download or AirDrop; a PDF an app on this Mac saved there
is left alone, even a sandboxed app's), every new PDF in the other folders you added, and PDFs you pass to Rename Files…, drop on the icon, rename with Finder → Services, or find
in a folder you rename. Never the screenshot folder.

**Left alone:** a PDF while a browser's `name.pdf.download`, `.crdownload` or `.part` file is next to
it; one that doesn't start with `%PDF-` and end with `%%EOF` (still being written); one whose size
changed in the last 2 seconds; one inside an app bundle or other package; an encrypted one (even
if it opens without a password); one already named (a date-first name or the BetterAirdrop marker).
The extension is kept exactly as it was. Undo works as for photos.

**How:** PDFKit reads the text of the first 2 pages, up to 4,000 characters. A scan with no text
layer has page 1 rendered and read with Vision OCR on the Mac. The engine gets **only that text**,
the page count and the PDF's metadata title: never the file, a page image or the file name. It
answers with a kind (invoice, receipt, statement, contract, form, letter, ticket, manual, paper,
other), a subject, the issuer, the amount and the document's own date, which is used instead of
the file's date.

| Engine | For PDFs |
|---|---|
| `claude` (your key) | a text-only request to Claude; about $2 per 1,000 PDFs on Haiku 4.5 |
| `hosted` (Pro) | `POST /v1/name-text` with the text; counts against the same 500 names a month |
| `apple` | on the Mac; also the fallback when Claude or hosted naming fails |
| `vision` | Apple Intelligence if it's ready (still on the Mac), otherwise the PDF is left as it is |

Apple Vision alone can't tell an invoice from a lease, and a PDF's first line or metadata title is
often a reference number or someone's name, so without a model the file keeps its name rather
than getting a guessed one.

Names come from per-kind templates, which you can change like any other (`[templates] invoice = …`):
`invoice` and `receipt` are `{date}_<kind>_{merchant}_{total}`, `statement` is
`{date}_statement_{merchant}`, `contract` and `other` are `{date}_{subject}`, and the rest are
`{date}_<kind>_{subject}`. PDF receipts and invoices are in **Export Receipts as CSV…**. Filing
uses the kind's own rule (`[file] invoice = "~/Documents/Invoices"`); PDF receipts follow the
`receipt` rule.

## Testing

`swift test` is offline and needs no credential (the Claude backend is tested against canned
HTTP responses). The live end-to-end suite runs the real pipeline with Claude on your own
photos in `fixtures-local/` (gitignored) and writes a review report, `e2e-report.html`:

```sh
scripts/e2e.sh            # or: BETTERAIRDROP_E2E=1 swift test --filter E2E
```

To try a real iPhone AirDrop, follow [TESTING-AIRDROP.md](../TESTING-AIRDROP.md).

## Known limits

- Converting to JPEG drops HDR gain maps and depth data, and it breaks Live Photo pairing in
  Photos. Set `convert_heic = false` if you care about those.
- Places are city-level only (GeoNames cities with 15,000+ people).
- `watch --foreground` steps aside while the menu-bar app is watching (pause the app to use it).

