# Release pipeline (M12): draft, not enabled

Nothing here runs. It waits for the maintainer's go-ahead, because it needs secrets and a
GitHub Pages site. See UX-PROPOSAL §4.3 (M12).

- `release.yml.draft`: the GitHub Actions workflow. To enable it, move it to
  `.github/workflows/release.yml` after adding the secrets below.
- `../../scripts/install.sh`: the one-line installer, to be served from GitHub Pages.

## Secrets it expects (none exist yet)

| Secret | What |
|---|---|
| `SIGNING_P12_BASE64` | the release certificate and key (self-signed, `extendedKeyUsage=codeSigning`), base64 |
| `SIGNING_P12_PASSWORD` | its password |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle's EdDSA private key (from `generate_keys`) |

The matching public values go into the build as `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_KEY`
(repository variables, not secrets). Decide on the M7 spike result first (docs/spikes.md §f).
