# Command-line reference

The app bundles the `betterairdrop` command (Settings → Advanced → Install puts it at
`~/.local/bin/betterairdrop`). Everything the app does is available here too; both share the
same config, journal and undo.

## Naming backends

| Backend | Where it runs | What it sends | Names look like |
|---|---|---|---|
| `claude` (Claude Haiku 4.5) | Anthropic's API | a 1024 px JPEG re-encoded **with all metadata removed** (no EXIF, no GPS), plus text: the date, the city name, the detected kind, a short OCR snippet and a device hint | `cinema-seating-in-empty-theatre` |
| `vision` (Apple Vision) | on your Mac | nothing | `auditorium`, `window-brick` |
| `apple` (Foundation Models) | on your Mac, macOS 27 | nothing | planned (M4) |

`backend = "auto"` (the default) uses **Claude when a credential is found, otherwise Vision**.
Vision always runs anyway: it supplies the OCR text, kind hints and labels that go into Claude's
context, and it names the photo by itself if Claude fails for any reason (no network, timeout,
rate limit, refusal), so a rename never fails because of the network. The first time Claude is
used, BetterAirdrop prints a one-time notice saying what gets sent.

To keep everything on-device, set `backend = "vision"` or turn Claude off for `auto`:

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
2. **An API key in your Keychain**, stored by `betterairdrop auth claude` (hidden prompt; the key is
   never written to a file or a log). Remove it with `betterairdrop auth logout`.
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
betterairdrop status                                       is the app (or a Terminal watcher) running; this month's totals
betterairdrop uninstall [--purge]                          remove the app, login item, key, CLI link and permission
```

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

## Config

`~/.config/betterairdrop/config.toml`. Every key is optional; the defaults live in
`Sources/BetterAirdropCore/System/Config.swift`. For example:

```toml
backend = "auto"                        # auto | claude | vision | apple
template = "{date}_{place}_{subject}"   # tokens: date time place country subject kind device merchant total orig
originals = "trash"                     # trash | keep | delete
convert_heic = true

[watch]
folder = "~/Downloads"
notify = true

[claude]
model = "claude-haiku-4-5"              # any Messages API model id
auto = true                             # let backend = "auto" use Claude when a credential exists
```

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

