# Homebrew cask for a tap (e.g. vigentix/homebrew-tap). Update version and sha256 for each release;
# scripts/release.sh prints the DMG checksum. Submit to homebrew/cask once releases are notarized.
cask "osin" do
  version "0.1.0"
  sha256 "REPLACE_WITH_DMG_SHA256"

  url "https://github.com/Vigentix/osin/releases/download/v#{version}/Osin-#{version}.dmg"
  name "Osin"
  desc "Honest, open-source health monitor and cleaner for the menu bar"
  homepage "https://github.com/Vigentix/osin"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Osin.app"

  uninstall quit: "com.vigentix.osin"

  zap trash: [
    "~/Library/Application Support/Osin",
    "~/Library/Caches/com.vigentix.osin",
    "~/Library/HTTPStorages/com.vigentix.osin",
    "~/Library/Preferences/com.vigentix.osin.plist",
  ]
end
