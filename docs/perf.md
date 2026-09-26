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
