# M0 spikes

*Run 2026-09-24 on an M1 Pro, macOS 15.4.1, Swift 6.1. Covers PLAN.md §7 M0 (a), (c), (d) and (e). (b), Foundation Models image input, waits until a macOS 27 machine is available.*

## Summary

| Spike | Result |
|---|---|
| (a) Vision labels + OCR + kind | **The floor works, but the names are flat.** Kind detection for screenshots was 6/6 using metadata alone. The subject phrase scored 23/52 (44%) after one round of heuristics, and 14/52 before that. It's usable as a fallback, not as the headline. |
| (b) Foundation Models | Deferred: needs macOS 27. `AppleFMNamer` compiles behind `#if canImport(FoundationModels)` plus `@available`, and reports "unavailable" here. |
| (c) Claude Haiku 4.5 | **Primary namer (M5).** On the same 26 photos it scored about **48/52 (92%) vs Vision's 22/52 (42%)**, with no fallbacks, at **$1.9 per 1,000 photos**. `output_config` structured output works on `claude-haiku-4-5`. |
| (d) AirDrop atomicity | Needs a real AirDrop. The procedure is below. The xattr inventory of the existing files is done. |
| (e) TCC shim | The script is written and checked (`bash -n`, `--dry-run`, and a sandboxed build plus local run of the launcher and child). **The maintainer needs to run it**, because it triggers a permission prompt. |

**Decision on the `auto` order (revised Sept 24 by the maintainer):** `apple` → **`claude` when a credential resolves** → `vision`. Claude Haiku is the primary namer; Vision stays as the offline fallback and still supplies OCR text, kind hints and labels as Claude's context. The original M0 decision was `apple` → `vision`. Vision alone doesn't meet the "descriptive names" promise, which is why Claude is now the primary namer. The README must say plainly that the Vision names read like tags ("window-brick", "drinking-glass").

---

## (a) Vision eval

**Setup.** 26 images were **copied** (not moved) from `~/Downloads` into `fixtures-local/`, which is gitignored and never committed: 19 HEIC, 4 PNG and 3 JPG, all tagged `sharingd`. The script is `scripts/spike-vision-eval.swift`. It uses `VNClassifyImageRequest`, `VNRecognizeTextRequest` (accurate, with language correction) and `VNDetectDocumentSegmentationRequest` on a 2048 px thumbnail, plus ImageIO metadata and the `com.apple.assetsd.creatorBundleID` xattr. Its output went to `spike-out/vision.json`, which is also gitignored.

**Metadata signals**

- EXIF `DateTimeOriginal` was present in 25/26. The exception is a JPG saved from a third-party app, where only the file dates can be used.
- GPS was present in 19/26: every camera HEIC, and no screenshot.
- iPhone screenshots carry EXIF `UserComment = "Screenshot"`. That held for all 6, including the 2 that arrived as JPG.
- AirDropped files keep the iPhone Photos xattrs (see (d)). `creatorBundleID` is `com.apple.springboard` for screenshots and `com.apple.camera` for camera shots. That's a second, independent screenshot signal.

**Speed.** The median was 741 ms per image for all three requests together at 2048 px, and the maximum was 3.6 s (an image dense with text, 41 OCR lines). That's fine for a background agent. `rename` on 53 files takes about 40 s.

**Kinds.** Screenshots were 6/6 correct, from metadata alone. The set had no receipts, printed documents or whiteboards, so those rules are **untested on real photos**; M3 covers them with synthetic tests only. Document segmentation fires on nearly anything rectangular (0.99 confidence on ordinary objects on a table, and a large area on a room shot), so it can't be used on its own. It needs OCR line count as well.

**Names.** The maintainer scored each candidate subject. Scale: 2 = a name you'd keep, 1 = true but vague or partly wrong, 0 = wrong or a fallback. v1 took the top 3 labels ≥ 0.3 minus a generic list, and used the *first* OCR line for screenshots. v2 drops Vision's parent labels (Vision returns `portal` with the same score as `window`, `tableware` with the same score as `drinking_glass`) and uses the *tallest* OCR line that isn't status-bar noise. `{place}` is left out here because Places arrived in M1. The per-image table stays private because the images are personal; only aggregates are published.

| | Images | Score 2 | Score 1 | Score 0 | Total |
|---|---|---|---|---|---|
| Screenshots | 6 | 2 | 3 | 1 | 7/12 |
| Photos | 20 | 4 | 7 | 9 | 15/40 |
| **All (v2)** | **26** | **6** | **10** | **10** | **22/52 (42%)** |
| All (v1) | 26 | | | | 14/52 (27%) |

Neutral examples of v2 output: a window onto brick buildings → `window-brick` (2), cinema seating → `auditorium` (2), a glass of beer → `drinking-glass` (2), a film projected in a cinema → `suit` (0).

**Verdict.** Vision is an honest floor and nothing more:

- **The date and kind are the valuable part.** `2026-09-21_drinking-glass.jpg` beats `IMG_4821.HEIC` even with a bland subject, and adding the city (all camera shots had GPS) will make most names findable.
- Leaf labels are right about half the time, but they name *an object in the scene*, not *the scene* (`suit` for a film screening).
- Screenshot OCR works when there is a clear heading (a screen title). It fails on media-heavy screens. Ranking lines by text height was the single biggest improvement.
- The fallback `photo-{orig}` is needed about 10% of the time, and that's the right call over a wrong guess.
- **Implications for M3**, all implemented there: use the parent-label blocklist, cap the subject at 2 labels, rank OCR by salience, fall back to salient OCR when no label is strong (≥ 0.5) and there are ≥ 3 OCR lines, and use the EXIF `UserComment` / `creatorBundleID` screenshot signals.

### After M3: the shipped `VisionNamer`

`airname rename --dry-run` on the same 26 files, with the v2 rules plus two changes: photos only fall back to OCR text with confidence ≥ 0.8, and screenshot text in the top 5% (the status bar) is ignored. The result matches v2 except that one screenshot is now named by a button label (still a 1), and one photo that was named by an OCR misread now gets a correctly read line of text from the image (0 → 0–1). That's about 22–23/52 (≈ 44%).

Place names now resolve too (all camera shots got a city). Total 26 images in 30 s, about 1.1 s each including decoding a 24 MP HEIC.

Still bad: low-quality OCR on media-heavy screenshots produces nonsense words. A dictionary check on OCR words (`NSSpellChecker`) is the obvious next rule, if the Apple/Claude backends don't make it moot.

## (b) Foundation Models

Deferred until macOS 27 (PLAN decision 10).

## (c) Claude Haiku 4.5

**Run 2026-09-24** with `scripts/e2e.sh` (credential: the Anthropic CLI OAuth login), on the same 26
`fixtures-local/` photos plus 3 synthetic images, then a simulated AirDrop burst of 8 through the watcher.
The full report (`e2e-report.html`, with thumbnails) stays local and gitignored.

| | Vision (M3 rules) | Claude Haiku 4.5 |
|---|---|---|
| Subject score, 26 real photos (0–2 scale) | 22/52 (42%) | ≈ 48/52 (92%): 22 at 2, 4 at 1, none at 0 |
| Screenshots (6) | 7/12 | ≈ 11/12 |
| Camera photos (20) | 15/40 | ≈ 37/40 |
| Names that fell back to the image number | 2 | 0 |
| Single-word subjects | 9 | 0 |
| Kind correct: 6 metadata screenshots + synthetic receipt, document, screenshot | 9/9 | 9/9 |

The Claude scores are a provisional first pass by the implementing agent, checked against the maintainer's
private descriptions of the images; the maintainer should confirm them from the report. The four names
scored 1 are all plausible but miss the point of the scene. Wording changes between runs (21 of 29
subjects were worded differently on a second run) but the meaning stays the same. Subjects tend to use the full 6 words.

Neutral examples (Vision → Claude):

- a window onto brick buildings: `window-brick` → `black-framed-windows-overlooking-brick-building`
- cinema seating: `auditorium` → `movie-theater-seating-rows-recliners`
- a glass of wine: `drinking-glass` → `glass-rose-wine-wooden`
- synthetic receipt: `receipt_loblaws_84-12` from both (Claude returned the merchant and total itself)

**Cost and speed.** 29 photos: 49,325 input and 1,208 output tokens = **$0.0554** (about 1,700 input tokens
per camera photo and 1,430 per screenshot, about 42 output tokens each), so **≈ $1.9 per 1,000 photos**, within
6% of the PLAN D2 estimate. The watcher burst of 8 cost $0.0152. With 4 photos in flight, the 29 photos took
32 s end to end, including Vision.

**Checks that passed:** every name has the EXIF date and the offline city where the template includes one;
subjects are 2–6 word lowercase slugs with no `img`/number fallback and no given names; all filenames are unique;
the second run is a no-op; `undo` restores byte-identical files. In the watcher run (sharingd xattrs, one
chunked slow write, a Live Photo MOV) there was one batch, the MOV got the still's name, and non-AirDrop files were untouched.

**output_config:** accepted by `claude-haiku-4-5`; the prompted-JSON fallback was not needed (it stays in place and is unit-tested).

**What the backend does** (`Sources/AirnameCore/Naming/ClaudeNamer.swift`):

- Model `claude-haiku-4-5` (config `claude.model`), `POST /v1/messages`, `anthropic-version: 2023-06-01`,
  `max_tokens` 256, no `thinking`, 20 s timeout.
- The image is a 1024 px (long edge) JPEG at quality 0.8, redrawn from pixels so that **no metadata**
  (EXIF, GPS, TIFF make/model) is carried over. A unit test decodes the uploaded bytes and checks this.
  The image block comes before the text block.
- The context goes as text: capture date and time, the offline city name (never coordinates), device
  model, the creator hint (`com.apple.springboard` → "an iOS screenshot"), the local kind guess and why,
  up to 6 Vision labels, and up to 300 characters of OCR, biggest text first. The file name isn't sent.
- Structured output: `output_config.format` = `json_schema` with `subject`, `kind` (photo, screenshot,
  receipt, document, whiteboard, other), `merchant`, `total`, `confidence` and `people_present`, all required,
  `additionalProperties: false`. If the API rejects `output_config` with a 400, airname remembers that
  for the rest of the run and asks for JSON in the system prompt instead, then parses and validates
  strictly (known kind, non-empty subject, finite confidence). Haiku 4.5 accepted `output_config` in the live run.
- `stop_reason` is checked first: `refusal` and `max_tokens` are errors. 429, 529 and 5xx are retried
  (3 attempts, honouring `retry-after`, else 1 s then 2 s); 400 and 401 are not retried. A 401 with an
  `ant` OAuth token re-fetches the token once. **Any** failure falls back to Vision for that photo.
- Kind: a screenshot identified by metadata stays a screenshot; otherwise Claude's kind wins over the
  local heuristics. The subject is lowercased, loses a "photo of" lead-in and a repeated city name,
  and is capped at 6 words.

## (d) AirDrop atomicity and what AirDropped files carry

### xattr inventory (read-only, 53 HEICs in ~/Downloads)

- **`com.apple.quarantine`** on every file: `0081;<hex time>;sharingd;<UUID>`. Two of the screenshots have flags `0083`. The agent field is always `sharingd`, which confirms RESEARCH.md. Parse field 3, and don't depend on the flags.
- **`com.apple.assetsd.*`**, about 30 keys on 47 of 53 HEICs. The iPhone's Photos library metadata travels with the file. The useful keys:
  - `originalFilename` (e.g. `IMG_5007.HEIC`)
  - `creatorBundleID` (`com.apple.camera`, `com.apple.springboard` = screenshot, or a third-party app id)
  - `importedByDisplayName` ("Camera")
  - `timeZoneName` (e.g. `GMT-0400`)
  - `customLocation` (binary coordinates; **don't rely on it**, EXIF GPS is the documented source)
  - `mediaGroupUUID` (present on some files; probably the Live Photo pairing id, to verify in M6)
- **Copies lose the tag.** A plain `cp` of an AirDropped file (how `fixtures-local/` was built) gets a *new* quarantine value with an empty agent (`0281;<time>;;<uuid>`). So `sharingd` identifies the original arrival only, and a copied or re-downloaded file is correctly not treated as AirDrop. `--airdrop-only` tests have to set the xattr themselves (the unit tests do).
- **Absent:** `kMDItemWhereFroms`, `kMDItemUserSharedReceivedTransport` and `…Sender` are all null. Spotlight doesn't record AirDrop provenance. Quarantine is the only signal.
- Some files also carry `com.apple.macl` (sandbox file-access grants), `com.apple.lastuseddate#PS` and `com.apple.cscachefs`. A plain rename (`rename(2)`) keeps them. A converted JPEG is a new file with none of them: it gets the `dev.airname.done` marker instead, and since it has no `sharingd` quarantine the watcher can't pick it up a second time.

### Procedure (needs an iPhone, about 5 minutes)

Goal: does AirDrop write the file in place in `~/Downloads` (so a watcher sees a growing file), or stage it elsewhere and move it in when it's complete?

```sh
# Terminal 1: watch Downloads at the filesystem level (needs sudo; read-only)
sudo fs_usage -w -f filesys sharingd | grep -E 'Downloads|rename|open' | tee /tmp/airdrop-fsusage.txt

# Terminal 2: poll the folder every 100 ms
while :; do date +%T.%N | cut -c1-12; ls -la ~/Downloads | grep -iE 'heic|mov|download|tmp|partial'; sleep 0.1; done | tee /tmp/airdrop-ls.txt
```

1. On the iPhone, pick **one large video (> 200 MB)** and **3 photos including a Live Photo**, and AirDrop them to the Mac.
2. Stop both terminals with Ctrl-C once the transfer finishes.
3. Look for:
   - **Atomic:** `rename`/`renamex_np` lines from `sharingd` whose source path is *outside* `~/Downloads` (e.g. `/private/var/folders/…/com.apple.sharingd/…` or a `.sharingd` temp folder), and the file appears in the `ls` poll at full size in one step. → The M6 settler can be a single `CGImageSource` status check.
   - **In place:** the file appears in `ls` with a growing size, or as a `.download` / hidden temp name that gets renamed. → Keep the 2-check size+mtime settler from PLAN §5.
   - Also note whether the HEIC and the MOV of the Live Photo arrive in one burst, and roughly how far apart (it sets the 3 s batch window).
4. Paste the few relevant lines (no personal file names needed) into this section.

## (e) TCC shim: does a stable launcher hold the Downloads grant?

`scripts/spike-tcc-shim.sh` builds, in `~/Library/Application Support/airname-spike/`:

- **`Airname Spike.app`**: a roughly 25-line Swift launcher, ad-hoc signed with identifier `dev.airname.spike` and `LSUIElement`. It lists `~/Downloads` itself, then spawns the child and waits for it.
- **`child/airname-child`**: a separate ad-hoc binary *outside* the bundle (standing in for the Homebrew Cellar binary). It lists `~/Downloads` too.
- **`~/Library/LaunchAgents/dev.airname.spike.plist`**: `Program` = the launcher, `AssociatedBundleIdentifiers` = `dev.airname.spike`, not run at load. Each phase starts it with `launchctl kickstart`.

It only **counts** directory entries. It never prints names or reads, changes or deletes anything in Downloads. Results go to `results.log` in the same folder.

Verified here without installing: `bash -n`, `install --dry-run`, `cleanup --dry-run`, and a `build` into a sandbox directory. Running that launcher from Terminal (so it inherited Terminal's grant) listed Downloads and spawned the child correctly.

### How to run it

```sh
cd airname
scripts/spike-tcc-shim.sh install          # phase 1. A prompt should say "Airname Spike" would like to access Downloads → Allow
scripts/spike-tcc-shim.sh run              # phase 2: with the grant in place
scripts/spike-tcc-shim.sh swap             # phase 3: child replaced (new cdhash, new inode) = a simulated brew upgrade
scripts/spike-tcc-shim.sh rebuild-launcher # phase 4: launcher re-signed with a new cdhash, same identifier
scripts/spike-tcc-shim.sh results          # copy the output into this file
scripts/spike-tcc-shim.sh cleanup          # removes the agent, bundle, plist and the TCC entry (log saved to /tmp)
```

Check afterwards that System Settings → Privacy & Security → Files and Folders no longer lists "Airname Spike". The log file never contains file names, only counts.

### Reading the results

| Phase | What to look for | Meaning |
|---|---|---|
| 1 | A prompt naming **"Airname Spike"** (not "airname-child", not "bash"/"Terminal") | TCC attributes access to the launcher bundle. D3 (a) passes. |
| 1 | No prompt and `launcher LIST FAIL … Operation not permitted` | launchd agents can't prompt. We'd need `airname install` to deep-link to System Settings and have the user add the app by hand. |
| 1 | No prompt and `LIST OK` | Something already granted it, e.g. a stale entry. Run `cleanup` and repeat. |
| 2 | `launcher LIST OK` **and** `child(v1) … LIST OK` | The child inherits the launcher's grant, because the launcher is the responsible process. **D3 (b) passes.** |
| 2 | launcher OK but child `FAIL` | The child is attributed to itself. Fall back to putting the full `airname` binary inside the bundle (PLAN D3). |
| 3 | `child(v2) … LIST OK` | **The key result.** Swapping the Homebrew binary keeps the grant. D3 (c) passes and the free path works. |
| 3 | `child(v2) … FAIL` | Swaps break it. Same fallback as above, plus `doctor` detection. |
| 4 | `launcher LIST OK` (no new prompt) | TCC keyed the grant on the identifier (surprising for ad-hoc). The launcher can be rebuilt freely. |
| 4 | A new prompt or `FAIL` | Expected. Ad-hoc grants are tied to the cdhash, so the launcher must stay byte-stable (version-stamped, rebuilt only when its source changes) or use `--local-cert`. D3 (d) confirmed. |

### Results

*(pending: paste `results` output here)*
