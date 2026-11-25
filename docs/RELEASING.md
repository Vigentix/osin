# Releasing Osin

Releases are built by `scripts/release.sh`, locally or by the **Release** workflow when a `v*` tag is pushed.
Without any keys the workflow still produces an ad-hoc signed DMG; each key below unlocks one more step.

## One-time setup

| Step | What you need | GitHub secret(s) |
|---|---|---|
| Developer ID signing | Apple Developer Program ($99/yr), a "Developer ID Application" certificate exported as `.p12` | `DEVELOPER_ID_CERT_P12` (base64 of the .p12), `DEVELOPER_ID_CERT_PASSWORD`, `DEVELOPER_ID` (e.g. `Developer ID Application: Vigentix (TEAMID)`) |
| Notarization | An app-specific password for the Apple ID | `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_APP_PASSWORD` |
| In-app updates (Sparkle) | An EdDSA key pair from Sparkle's `generate_keys` (stores the private key in your login keychain; export it with `generate_keys -x key.txt`) | `SPARKLE_PUBLIC_KEY`, `SPARKLE_PRIVATE_KEY` |

`generate_keys` ships in the Sparkle package: after `make build` it is at
`build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`.

> Keep the Sparkle private key safe. Losing it means existing installs can no longer verify updates.

## Each release

1. Update `CHANGELOG` notes in the draft release, bump nothing in code: the version comes from the tag.
2. `git tag v0.1.0 && git push origin v0.1.0`
3. The workflow uploads `Osin-0.1.0.dmg`, `Osin-0.1.0.zip` and (with Sparkle keys) `appcast.xml` to a **draft** release.
4. Review the draft, then publish it. Sparkle's feed URL points at `releases/latest/download/appcast.xml`, so publishing is what ships the update.
5. Update `Casks/osin.rb` in [Vigentix/homebrew-tap](https://github.com/Vigentix/homebrew-tap) (version and the DMG sha256 printed by the script), run `brew audit --cask --strict vigentix/tap/osin`, and mirror it to `packaging/homebrew/osin.rb`.

## Local build

```sh
scripts/release.sh 0.1.0            # ad-hoc signed DMG in build/release/
DEVELOPER_ID="Developer ID Application: …" NOTARY_PROFILE=osin-notary scripts/release.sh 0.1.0
```

Ad-hoc signed builds are blocked on first launch. Open the app once, then click **Open Anyway** in System Settings › Privacy & Security (right-click › Open no longer works on macOS 15 and later), or:

```sh
xattr -dr com.apple.quarantine /Applications/Osin.app
```
