# Template. The release workflow fills in the version and sha256 and pushes the result to
# MoizAhmedd/homebrew-tap as Casks/betterairdrop.rb.
cask "betterairdrop" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/MoizAhmedd/betterairdrop/releases/download/v#{version}/BetterAirdrop.zip"
  name "BetterAirdrop"
  desc "Menu bar app that names AirDropped photos by what's in them"
  homepage "https://moizahmedd.github.io/betterairdrop/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :ventura

  app "BetterAirdrop.app"
  binary "#{appdir}/BetterAirdrop.app/Contents/Helpers/betterairdrop"

  # Signed with the project's own certificate, not an Apple Developer ID, so it isn't notarized.
  # Removing the quarantine flag is what lets it open without a Gatekeeper dialog.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/BetterAirdrop.app"], must_succeed: false
  end

  uninstall quit: "dev.betterairdrop.app"

  zap trash: [
    "~/.config/betterairdrop",
    "~/Library/Application Support/betterairdrop",
    "~/Library/Caches/dev.betterairdrop.app",
    "~/Library/HTTPStorages/dev.betterairdrop.app",
    "~/Library/Preferences/dev.betterairdrop.app.plist",
  ]

  caveats <<~EOS
    BetterAirdrop is signed with its own certificate rather than an Apple Developer ID, so
    Homebrew's quarantine flag is removed after install. Source: https://github.com/MoizAhmedd/betterairdrop

    Open it once to start it:
      open "#{appdir}/BetterAirdrop.app"
  EOS
end
