# Installing BetterAirdrop from an AI agent

For Claude Code, Codex or any script running in Terminal. Everything is a command except
**two clicks a person makes in macOS's own prompts**. No script can grant them: macOS records them
per app, only after a click.

| Prompt | Needed? | When it appears |
|---|---|---|
| “BetterAirdrop would like to access files in your Downloads folder” | **Yes.** Without it nothing is renamed. | As soon as the app opens. |
| “BetterAirdrop would like to send you notifications” | No. Banners with Undo after each batch. | Right after the Downloads prompt, if `setup` ran and notifications are on. |

Open at login needs no click. macOS shows an informational “Background item added” notice.

## 1. Install and set up

```sh
curl -fsSL https://betterairdrop.com/install | sh -s -- --yes --engine vision --launch-at-login
```

With Homebrew instead:

```sh
brew install moizahmedd/tap/betterairdrop
betterairdrop setup --yes --engine vision --launch-at-login
```

`setup` writes the config, records that setup is done, and opens the app. The installer
links the CLI at `~/.local/bin/betterairdrop`. If that's not on `PATH`, use
`~/Applications/BetterAirdrop.app/Contents/Helpers/betterairdrop`.

**Engines:** `vision` is on-device and free. `auto` picks Apple Intelligence if it's on (macOS 26+),
then Claude if the app has a key, then Vision. `claude` needs a key. `apple` fails unless Apple
Intelligence is ready on this Mac.

For Claude names, store the user's Anthropic key from an environment variable. Never pass it as
an argument:

```sh
betterairdrop setup --yes --engine auto --api-key-env ANTHROPIC_API_KEY
```

The app can't read the shell's environment, so a key that's only exported in `~/.zshrc` must be
stored this way. `setup` checks the key with Anthropic first. Add `--no-verify` when offline.

Other flags: `--no-notify`, `--no-launch-at-login`, `--no-open`, `--api-key-stdin`. Exit code 2
means setup stopped, and the message says why. Bad flags and a rejected key stop it before anything
is changed.

## 2. Tell the person

> BetterAirdrop is open in your menu bar. macOS will ask whether it may access your Downloads
> folder: click **Allow**. Then it asks about notifications: click **Allow** if you want a banner
> with an Undo button after each AirDrop.

## 3. Verify

```sh
betterairdrop status --json
```

Done when `"ready": true`. Otherwise, `next_steps` lists what's left:

```json
{
  "ready": false,
  "permissions": { "folder_access": "waiting", "notifications": "not_asked", "login_item": "enabled", "reported_at": "…" },
  "watching": { "state": "starting", "folder": "~/Downloads", "by": null },
  "next_steps": [
    { "who": "human", "required": true, "text": "Click Allow when macOS asks “BetterAirdrop would like to access files in your Downloads folder”." },
    { "who": "human", "required": false, "text": "Click Allow when macOS asks to let BetterAirdrop send notifications (banners with Undo)." }
  ]
}
```

- `who: "human"`: relay `text` to the person. If there's a `command`, run it to open the right
  System Settings pane for them.
- `who: "agent"`: run `command` yourself.
- `required: false`: optional.

Poll every few seconds until `ready` is true. Each call asks the running app to re-check its
permissions.

If they clicked **Don't Allow**, macOS won't ask again. `folder_access` is `"denied"`, the app
shows a window explaining how to turn access on, and the step's `command` opens
*Privacy & Security → Files & Folders*.

### Fields

| Field | Values |
|---|---|
| `ready` | `true` once AirDrops are being renamed |
| `app` | `installed`, `path`, `version`, `running` |
| `setup` | `done` (setup has run), `completed_at` |
| `engine` | `backend` (configured), `active` (what names the next photo), `detail` |
| `credentials.claude` | `present` (a key the app can use), `source`: `stored`, `ant` or null |
| `credentials.license` | BetterAirdrop Pro: `state` `none`, `active`, `grace` (Polar rejected the key; Pro stays on until `grace_until`) or `invalid`; `pro` (features unlocked); `key` (masked). Activate with `betterairdrop license activate <key>` |
| `credentials.hosted` | Hosted naming (Pro: Claude with no API key): `available` (Pro is active or in grace); `remaining` names this month, `resets_at` and `last_error`, as the app last heard from the server (null until it has used hosted naming, and after the month resets) |
| `permissions` | `folder_access`: granted, denied, waiting, unknown. `notifications`: allowed, denied, not_asked, unknown. `login_item`: enabled, requires_approval, disabled, unknown. As last reported by the app (`reported_at`). |
| `watching` | `state`: watching, paused, no_access, standing_by, starting, not_running, unknown. `folder`. `by`: app, cli or null. |
| `next_steps[]` | `who`, `required`, `text`, `command` (optional) |

`schema` is 1. Fields are only ever added, never renamed.

## Undo, uninstall

```sh
betterairdrop undo                     # the last batch
betterairdrop uninstall --yes          # app, login item, key, CLI link, permission
```
