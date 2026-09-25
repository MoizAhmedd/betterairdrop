# Releasing

Push a tag. Everything else is `.github/workflows/release.yml`:

```sh
git tag v0.3.1 && git push origin v0.3.1          # a hyphen (v0.3.1-rc.1) makes a pre-release
```

1. **build** (macos-15): `swift test`; imports the certificate into a temporary keychain; runs
   `scripts/make-app.sh --universal --sign` (arm64 and x86_64 built separately and joined with
   `lipo`, signed inside-out); checks `codesign --verify --deep --strict` and prints
   `codesign -d -r-`; zips with `ditto`; writes `SHA256SUMS`; signs the zip for Sparkle
   (`scripts/release/appcast-item.sh`); creates the GitHub release with `BetterAirdrop.zip`,
   `SHA256SUMS` and `appcast-item.xml`.
2. **pages**: dispatches `.github/workflows/pages.yml` on main, which publishes `site/public/` plus `/install`
   (`scripts/install.sh`) and `/appcast.xml`, which `scripts/release/build-appcast.sh` rebuilds from
   every release's `appcast-item.xml`. Pre-releases are in Sparkle's opt-in `beta` channel, so
   nobody is updated to them. Also runs on pushes to main that touch `site/`.
3. **tap**: renders `packaging/homebrew/betterairdrop.rb` with the version and sha256 and pushes it
   to [MoizAhmedd/homebrew-tap](https://github.com/MoizAhmedd/homebrew-tap) as `Casks/betterairdrop.rb`.

If the tap job ever fails, do its step by hand: fill in `__VERSION__` and `__SHA256__` (from the
release's `SHA256SUMS`) in the template, and commit it to the tap as `Casks/betterairdrop.rb`.

## Secrets (repository → Settings → Secrets → Actions)

| Secret | What |
|---|---|
| `SIGNING_P12_BASE64` | the "BetterAirdrop Release" certificate and key (self-signed, `extendedKeyUsage=codeSigning`, valid to 2036), base64 |
| `SIGNING_P12_PASSWORD` | its password |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle's EdDSA private key (from `generate_keys`); the public key is in `Resources/App/Info.plist` |
| `TAP_DEPLOY_KEY` | SSH key with write access to MoizAhmedd/homebrew-tap (a deploy key there) |

The maintainer keeps backups outside the repo. **Never replace the certificate**: macOS ties the
Downloads permission to it (docs/spikes.md §f), so a new one means every user is asked again.

## Why this works without a Developer ID

- The certificate is self-signed and not trusted by anyone; `codesign` doesn't need trust, and the
  designated requirement (`identifier "dev.betterairdrop.app" and certificate leaf = H"…"`) is the
  same in every release, so TCC keeps the Downloads grant across updates.
- It isn't notarized, so a quarantined copy would get a Gatekeeper dialog. Neither install path
  quarantines it: `curl` doesn't set the flag, and the cask's `postflight_steps` removes the flag
  Homebrew adds. Sparkle updates aren't quarantined either.
- The API key is a 0600 file, not a Keychain item: the Keychain prompts after every update, even
  with the same certificate.
