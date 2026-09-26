# Contributing to Flowlight

Thanks for helping make network activity on macOS understandable.

## Getting started

```sh
brew install xcodegen
xcodegen generate
scripts/build-local.sh
open build/Build/Products/Release/Flowlight.app --args -FLDemo YES   # synthetic data, safe for screenshots
```

Run the tests before opening a PR:

```sh
xcodebuild -project Flowlight.xcodeproj -scheme Flowlight -derivedDataPath build \
  CODE_SIGN_IDENTITY=- CODE_SIGN_ENTITLEMENTS= CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= test
```

Internals are documented in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Good first contributions

- **Recognize another AI agent.** Add it to `AgentCatalog.agents` (bundle ID or process name) with a test in `AgentTests`.
- **Recognize another LLM provider.** Add its API hostname suffix to `AgentCatalog.providers`.
- **Translate the website.** Copy `site/i18n/en.json` to `site/i18n/<code>.json` and translate the values — that
  is the header, the footer and the 404 page. Then copy the pages you want from `site/pages/` into
  `site/pages/<code>/`, keeping the file names and the markup, and translate the text. `scripts/build-site.sh`
  publishes them under `/<code>/`, adds the `hreflang` links and the entry in the language menu, and leaves
  anything you haven't translated pointing at the English page. Reuse the words the app already uses, from
  `Flowlight/Localization/<code>.lproj/Localizable.strings`.
- **Name another protocol.** Add the port to `ProtocolCatalog`, give it a category, and, if its first bytes are
  distinctive, add a detector in `ProtocolClassifier.swift`. `testExtendedProtocolCoverage` checks that every named
  protocol has a category.

## Ground rules

- **Privacy first.** Never store packet payloads, and never send user data off the Mac without an explicit opt-in.
- **Explainable alerts.** Every alert names the app, the destination and the number that tripped it.
- **Don't commit real traffic.** Screenshots and fixtures come from demo mode or synthetic data only.
- Match the surrounding code style. Keep PRs focused, with tests for behavior changes.

## Releasing

Every release goes **branch → merge request → release → merge**, in that order, whatever the size of the
change:

```sh
git switch -c release/0.8.0                          # version bump, release notes and rebuilt docs/, one commit
git push -u origin release/0.8.0
gh pr create --base main --title "Flowlight 0.8.0"   # its checks run while the release builds
git tag -a v0.8.0 -m "Flowlight 0.8.0" && git push origin v0.8.0   # signs, notarizes, publishes
gh pr merge --merge --delete-branch                                # last: the site catches up
```

The order is not a convention, it is what keeps the website honest. `docs/` is served from `main` and its
Download button points at `releases/latest/download/Flowlight.dmg`, so a version that reaches `main` before
the release exists sends people to the previous DMG while announcing a newer one. The bump can't simply land
later either: CI requires `docs/` to match `site/`, and the site build reads `MARKETING_VERSION`, so the
version and the rebuilt site travel in the same commit. The release branch is what holds both back until the
download is real.

CI enforces it rather than trusting anyone to remember: on `main` it fails when the newest version on the
releases page is ahead of the newest published release. It does not run that check on a release branch, since
carrying the next version is that branch's job.

[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#release-branches) has the rest: the dry run, the signing secrets and
what the release workflow does.

## License

Flowlight is licensed under the [GNU GPL v3.0](LICENSE). By contributing, you agree that your contributions are
licensed under the same terms.
