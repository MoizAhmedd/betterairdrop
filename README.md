# airname

> **Status: pre-alpha.** Not released or installable yet. What works today:
> `airname watch --foreground` (names AirDrops as they land, in a Terminal window),
> `airname rename` on files you pass it, plus `explain`, `undo`, `log` and `auth`. The naming
> backends are Claude Haiku (when you give it a credential) and Apple Vision (on-device, always
> there). The background agent (`airname install`) and Homebrew packaging come next. Expect
> names and flags to change.

AirDrop a photo from your iPhone and it lands in `~/Downloads` as `IMG_4821.HEIC`. airname
gives it a name you can find later, and converts it to a JPEG:

```
IMG_4821.HEIC  →  2026-09-21_toronto_walnut-lamp-on-oak-sideboard.jpg
IMG_4822.PNG   →  2026-09-21_screenshot_failed-payment-notice.png
```

The name is built from the photo's own context: the capture date, the city it was taken in,
what kind of image it is (photo, screenshot, receipt, document, whiteboard), text visible in
it, and what's in it. The date, city, kind and text are always worked out **on your Mac**. City
names come from a bundled offline table, so your coordinates never leave the machine.

## Try it (from source)

Needs macOS 13+ and Swift 6 (Xcode 16 or the command line tools).

```sh
git clone https://github.com/MoizAhmedd/airname.git && cd airname
swift build -c release
.build/release/airname watch --foreground        # then AirDrop something to this Mac
```

`watch --foreground` runs in your Terminal window (which already has access to Downloads) until
you press Ctrl-C. It only touches files AirDrop delivered **after it started**; your older
downloads are left alone (pass `--backlog` to include earlier AirDrops). Each batch gets one
notification, and `airname undo` puts the last batch back exactly as it was.

To see what it would do to files you already have, without changing anything:

```sh
.build/release/airname rename --dry-run ~/Downloads/IMG_*.HEIC
```

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
used, airname prints a one-time notice saying what gets sent.

To keep everything on-device, set `backend = "vision"` or turn Claude off for `auto`:

```toml
[claude]
auto = false
```

Claude costs about $1.9 per 1,000 photos at Haiku 4.5's prices ($1/M input tokens, $5/M
output), measured on real AirDrops. On the same photos its names scored about 92% against Vision's 42%
(see [docs/spikes.md](docs/spikes.md)). Anthropic doesn't train on
API inputs. Vision's names are honest but flat (they read like tags); the spike notes have the scores.

### Giving airname a Claude credential

airname looks for a credential in this order and uses the first one it finds:

1. **`ANTHROPIC_API_KEY`** in the environment (sent as `x-api-key`).
2. **An API key in your Keychain**, stored by `airname auth claude` (hidden prompt; the key is
   never written to a file or a log). Remove it with `airname auth logout`.
3. **The Anthropic CLI's login.** If the Anthropic CLI `ant` (`brew install anthropics/tap/ant`) is
   installed and logged in, airname runs `ant auth print-credentials --access-token` and uses
   that OAuth token (`Authorization: Bearer …`). `airname auth login` runs `ant auth login` for
   you, or tells you to `brew install anthropics/tap/ant` first. The token is kept in memory for
   one run only.

`airname auth status` shows which source would be used, without printing any secret.

## Commands

```
airname watch --foreground [--dir DIR] [--backlog]   name AirDrops as they arrive (Ctrl-C to stop)
        [--backend auto|claude|vision] [--no-notify]
airname rename <files…> [--dry-run] [--json]         name (and convert) specific files
        [--backend auto|claude|vision] [--template STR] [--originals trash|keep|delete] [--format jpeg|keep] [--airdrop-only]
airname explain <file>                               show the context and why it picked that name
airname undo [--last | --batch ID | <file>]          put files back exactly as they were
airname log [-n 20]                                  recent renames
airname auth claude | status | login | logout        set up the Claude credential
```

What `rename` (and each watcher batch) does, in order: it writes the new JPEG next to the
original and syncs it to disk, records it in the journal
(`~/Library/Application Support/airname/journal.jsonl`), gives it its final name (it never
overwrites: a clash becomes `-2`, `-3`…), and only then moves the original HEIC to the Trash.
`airname undo` brings the original back from the Trash, and refuses if you've edited the output
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

`~/.config/airname/config.toml`. Every key is optional; the defaults live in
`Sources/AirnameCore/System/Config.swift`. For example:

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
scripts/e2e.sh            # or: AIRNAME_E2E=1 swift test --filter E2E
```

To try a real iPhone AirDrop, follow [TESTING-AIRDROP.md](TESTING-AIRDROP.md).

## Known limits

- Converting to JPEG drops HDR gain maps and depth data, and it breaks Live Photo pairing in
  Photos. Set `convert_heic = false` if you care about those.
- Places are city-level only (GeoNames cities with 15,000+ people).
- The watcher runs only while `watch --foreground` is open; the background agent is next.

## Credits

City data: [GeoNames](https://www.geonames.org), licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
Regenerate it with `scripts/update-cities.sh`.

## License

MIT
