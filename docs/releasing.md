# Releasing

How a release of SessionVisualizer is made: a tag, a notarised build of that tag, a GitHub release, and the Homebrew
cask. Written after the first one (v0.1.0, 2026-11-11). It takes a Mac with the signing identity on it; nothing here
runs in CI.

## What a release is

- **A tag `vX.Y.Z`** on a commit of `main` that CI passed.
- **`SessionVisualizer-X.Y.Z.zip`** on the GitHub release of that tag: the app, with `skit` in `Contents/Helpers/`,
  signed with the Developer ID, notarised and stapled.
- **The cask** `sessionvisualizer` in [`juan7732/homebrew-tap`](https://github.com/juan7732/homebrew-tap), pointing at
  that zip by version and checksum.

The version is the tag's. `skit --version`, the app's About box and the zip's name all come from it, so there is one
place to get it wrong and the script reads it from there.

Versions stay below 1.0 until the list under "M16 Release 1.0" in [`plan-v0.md`](plan-v0.md) is done; the one that
decides it is `/v0` becoming `/v1` with the JSON shapes frozen.

## Once per Mac

Both need the Apple account, so they are done by its owner, by hand.

1. **The certificate.** A "Developer ID Application" certificate, made at developer.apple.com under Certificates and
   installed in the **login** keychain (signing keys do not go in iCloud Keychain). Check:

   ```sh
   security find-identity -v -p codesigning
   ```

   It must list one valid `Developer ID Application: …` identity. If the certificate is installed and the list is still
   empty, Apple's intermediate is missing: download "Developer ID - G2" from
   <https://www.apple.com/certificateauthority/> and add it to the login keychain.

2. **The notarytool profile.** An app-specific password from account.apple.com, stored in the keychain under a name:

   ```sh
   xcrun notarytool store-credentials skit-notary --apple-id <Apple ID> --team-id <team id>
   ```

   The password is typed at its prompt and nowhere else: not in a script, not in an environment variable, not in a chat.
   `xcrun notarytool history --keychain-profile skit-notary` answers when it works.

## Each release

1. **Everything is committed and pushed, and CI is green** on the commit to release.

   ```sh
   just check && just client-contract
   git status --short        # nothing
   gh run list --limit 1     # completed, success, for this commit
   ```

2. **Tag it.**

   ```sh
   git tag -a vX.Y.Z -m "SessionVisualizer X.Y.Z: <what this release is, in a line>"
   ```

3. **Build, sign, notarise.** From the tagged checkout:

   ```sh
   just client-app-notarize
   ```

   [`notarize.sh`](../client/SessionVisualizer/notarize.sh) refuses a checkout with uncommitted changes or one that is
   not on a tag, builds through `build.sh` with the Developer ID, sends the app to Apple and waits, staples the ticket,
   and asks Gatekeeper for its verdict. It ends by printing the zip's path and its SHA-256. If Apple does not accept, it
   prints Apple's log: fix what the log says.

   The zip is in `client/SessionVisualizer/.build/notarized/`.

4. **Publish the tag and the release.**

   ```sh
   git push origin vX.Y.Z
   gh release create vX.Y.Z client/SessionVisualizer/.build/notarized/SessionVisualizer-X.Y.Z.zip \
     --verify-tag --title "SessionVisualizer X.Y.Z" --notes-file <notes.md>
   ```

   The notes say what changed for someone who uses the app, how to install, and anything they should know before
   upgrading (an index that will be rebuilt, a setting that moved).

5. **Point the cask at it.** In a checkout of the tap, in `Casks/sessionvisualizer.rb`, set `version` and `sha256` to
   what step 3 printed. Then:

   ```sh
   brew style Casks/sessionvisualizer.rb
   git commit -am "sessionvisualizer X.Y.Z" && git push
   brew update
   brew audit --cask --online juan7732/tap/sessionvisualizer
   brew fetch --cask --force juan7732/tap/sessionvisualizer    # downloads the zip and checks the sum
   ```

   Change anything else in the cask only when the app changed what it installs: the bundle's name, the launchd label
   (`dev.sessionkit.skit`), the bundle identifier, where it keeps things.

6. **Try it as a stranger would,** on a Mac that is not the one that built it:

   ```sh
   brew install --cask juan7732/tap/sessionvisualizer    # or brew upgrade --cask sessionvisualizer
   ```

   The app opens by double click with no warning; the first run starts the archiver; `skit --version` in a new terminal
   says `vX.Y.Z`; a session shows up. Then `brew uninstall --cask sessionvisualizer` leaves nothing running
   (`launchctl list | grep sessionkit` prints nothing) and leaves `~/.sessionkit` where it was.

## A trial that is not a release

To see whether a change still notarises, without a tag:

```sh
ALLOW_DIRTY=1 APP_VERSION=0.0.0 client/SessionVisualizer/notarize.sh /tmp/skit-trial
```

It goes to Apple like any other submission. Do not hand the result out.

## What is not in the app

- **`llama-server`.** Search by meaning runs it, and the cask depends on Homebrew's `llama.cpp` for it (decided
  2026-11-11). Someone who takes the zip installs `llama.cpp` themselves.
- **The embedding model.** It is the one download, made by `skit embed`, never shipped.

## Known edges

- **Upgrades and the archiver.** Homebrew runs the cask's uninstall steps on an upgrade, the removal of the launchd
  agent among them. The app installs the agent again the next time it is opened and nothing is serving. Until then
  nothing is archived. Not yet seen in practice: watch it at the first upgrade.
- **Tap trust.** Homebrew 7 does not load casks from a tap it was not told to trust. Installing by full name
  (`juan7732/tap/sessionvisualizer`) trusts that cask; `brew info` or `brew audit` on a Mac that never installed it ask
  for `brew trust juan7732/tap` first.
- **The everyday build is untouched.** `just client-app-install` signs ad hoc and needs neither certificate nor profile.
