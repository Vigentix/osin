# Mirror of Casks/osin.rb in https://github.com/Vigentix/homebrew-tap (the tap is the source of truth).
# After each release, update version and sha256 there; scripts/release.sh prints the DMG checksum.
cask "osin" do
  version "0.1.0"
  sha256 "56b6366e7a96eb3d3d1cbf6702c72af330442827e62d278fb27f3190ae6af4f9"

  url "https://github.com/Vigentix/osin/releases/download/v#{version}/Osin-#{version}.dmg"
  name "Osin"
  desc "Health monitor and cleaner for the menu bar"
  homepage "https://github.com/Vigentix/osin"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Osin.app"

  uninstall quit: "com.vigentix.osin"

  zap trash: [
    "~/Library/Application Support/Osin",
    "~/Library/Caches/com.vigentix.osin",
    "~/Library/HTTPStorages/com.vigentix.osin",
    "~/Library/Preferences/com.vigentix.osin.plist",
  ]

  caveats <<~EOS
    Osin #{version} is not notarized yet, so macOS blocks the first launch.
    Allow it in System Settings > Privacy & Security > Open Anyway, or run:
      xattr -dr com.apple.quarantine #{appdir}/Osin.app
  EOS
end
