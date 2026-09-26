# Rename speed

*M1 Pro, macOS 15.4.1, Swift 6.1, release build, Claude Haiku 4.5 through an `ant` login.
Measured 2026-09-26 with `scripts/perf.sh` on copies of personal photos (12 MP iPhone HEICs and
iPhone screenshots) in a throwaway folder. The photos themselves stay local.*

`scripts/perf.sh single PHOTO...` drops each copy into a watched folder the way AirDrop does (a
finished file with a `sharingd` quarantine tag appearing in one step) and times it until the renamed
file appears. `batch` drops them 0.2 s apart as one burst. The per-stage numbers come from the
watcher's own timings (`watch` prints them; `explain` shows the naming stages; the app logs them to
`log stream --predicate 'subsystem == "dev.betterairdrop"' --info`).

Stages: **settle** (first seen → size, mtime and container stable), **quiet** (waiting for the burst
to end), **credential** (the Claude token), **vision** (Apple Vision labels and OCR), **encode**
(downscaling the copy sent to Claude), **claude** (the API request), **convert** (HEIC → JPEG),
**commit** (journal, move, marker, original to the Trash). **Wall** is arrival → rename measured
outside the process; it includes the watcher noticing the file.

## Before (v0.3.0)

| Run | Wall | settle | quiet | credential | vision | encode | claude | convert | commit |
|---|---|---|---|---|---|---|---|---|---|
| single HEIC | 8.3 s | 762 | 2287 | 0 | 632 | 160 | 3864 | 60 | 120 |
| single HEIC | 8.8 s | 776 | 2293 | 0 | 1081 | 369 | 3594 | 118 | 49 |
| single HEIC | 8.0 s | 955 | 2079 | 0 | 758 | 436 | 3348 | 128 | 40 |
| single PNG screenshot | 8.2 s | 1049 | 2092 | 0 | 1353 | 285 | 3067 | – | 23 |
| batch of 3 HEIC | 10.6 s | 760 | 2295–2551 | 0 | 972–1090 | 144–160 | 3663–4460 | 134–517 | 33–206 |

Stage times in ms. Everything ran one after the other: wait for the file to settle, wait 3 s of quiet,
then Vision, then Claude, then convert and commit.

- **Claude was the biggest stage, 3.1–4.5 s.** Almost all of it was structured output: the same
  request with `output_config.format` took 3.1–4.7 s, and with the JSON asked for in the prompt
  instead, 0.9–1.4 s (36 requests each, no warm-up effect).
- **The quiet window cost 2–2.5 s** on top of settling, even for a single photo.
- **Vision cost 0.6–1.4 s** per photo, although Claude does the naming.
- **The credential was free here**: `ant auth print-credentials` takes 10–60 ms while its token is
  valid and the token is looked up once per process. But the cache never expired, so after the ~8 h
  token lifetime the next AirDrop paid a failed request (a 401) plus a refresh before its real one.
- Encode, convert and commit are small.

### Upload size

Same 8 photos, JSON asked for in the prompt:

| Long edge | Claude request | Input tokens |
|---|---|---|
| 1024 px | 0.86–1.40 s (mean 1.2 s) | 1,160–1,650 |
| 768 px | 0.76–1.22 s (mean 1.05 s) | 900–1,450 |

The names were equally good at both sizes: the same subjects, with wording that varies as much as it
does between two runs at one size (e.g. `croissant-ceramic-plate-wooden` vs
`croissant-ceramic-plate-white`; screenshot text such as a portfolio dashboard's app name was read at
both). 768 px is slightly faster and about 25% cheaper, so it's the new size.

## After (v0.3.1)

Same photos, same harness:

| Run | Wall | settle | quiet | credential | vision | encode | claude | convert | commit |
|---|---|---|---|---|---|---|---|---|---|
| single HEIC | 2.3 s | 509 | 16 | 0 | – | 252 | 986 | 61 | 37 |
| single HEIC | 2.4 s | 509 | 82 | 0 | – | 150 | 1035 | 67 | 9 |
| single HEIC | 2.4 s | 511 | 191 | 0 | – | 149 | 918 | 63 | 21 |
| single PNG screenshot | 2.8 s | 511 | 230 | 0 | 660 | 39 | 856 | – | 14 |
| batch of 3 HEIC | 2.9 s | 505–512 | 168–317 | 0 | – | 158–222 | 1200–1281 | 64–87 | 11–38 |

(Three clean rounds gave 2.3–2.6 s for a single HEIC and 2.9 s for the batch. A round run while a
release build was compiling was 4–5 s, and one screenshot 10.8 s with Vision at 7.9 s, so CPU
contention matters.)

**About 10 s → about 2.5 s** for one photo, and 10.6 s → 2.9 s for three. What changed:

1. **JSON in the prompt, not `output_config`**: Claude 3.5 s → 1.0 s. `output_config` is kept as a
   one-time retry for an answer that doesn't parse.
2. **A 768 px copy** instead of 1024 px: about 0.1 s and 25% of the input tokens.
3. **Naming starts as soon as a photo settles** (up to 3 at once) instead of after the burst, and the
   burst ends after **1 s** of quiet instead of 3 s. A burst is still one journal batch, one undo and
   one notification. Quiet is now 0–0.3 s: the time between a photo's name being ready and the
   burst being committed.
4. **Settle 0.5 s** instead of 0.75 s. The container check that catches truncated HEICs is unchanged.
5. **No Vision for camera photos** when Claude names them. Screenshots and images of unknown origin
   still get it (its OCR helps Claude), and so does any photo Claude fails on, for the Vision namer.
6. **A batch's conversions run in parallel** before the sequential journal and moves.
7. **The `ant` token is cached until 5 minutes before its expiry** (from `ant`'s JSON), so a
   long-running app refreshes it ahead of time instead of after a 401.

**The floor** is about 1.9 s from first seen: settle 0.5 s (needed to trust that a transfer has
stopped) + encode 0.15–0.25 s + one Haiku request 0.9–1.3 s + convert and commit 0.1 s. Wall time
adds the watcher noticing the file: up to 0.5 s for the CLI's polling (these runs); the app is
notified by FSEvents straight away. The Claude request is the one big stage left, and it's network
and model time.
