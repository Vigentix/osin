# Mirror of Casks/osin.rb in https://github.com/Vigentix/homebrew-tap (the tap is the source of truth).
# After each release, update version and sha256 there; scripts/release.sh prints the DMG checksum.
cask "osin" do
  version "0.5.1"
  sha256 "a621a53b9124846ad3abc72aa682ff4c4f896442daaea6b13c7c14e7e820a492"

  url "https://github.com/Vigentix/osin/releases/download/v#{version}/Osin-#{version}.dmg"
  name "Osin"
  desc "Health monitor and cleaner for the menu bar"
  homepage "https://github.com/Vigentix/osin"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
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
    Osin #{version} is not notarized yet, so macOS blocks the first launch:
      1. Open Osin once and close the warning.
      2. Go to System Settings > Privacy & Security, scroll down,
         click Open Anyway next to Osin and confirm with your password.
    Or skip the warning by removing the quarantine flag:
      xattr -dr com.apple.quarantine #{appdir}/Osin.app
  EOS
end
