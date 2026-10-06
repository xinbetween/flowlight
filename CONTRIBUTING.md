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
  publishes them under `/<code>/`, adds the `hreflang` links and the entry in the language menu, leaves
  anything you haven't translated pointing at the English page, and then checks the result — an unrendered
  placeholder, a dead link, a heading anchor that only exists in English. Reuse the words the app already uses, from
  `Flowlight/Localization/<code>.lproj/Localizable.strings`.
- **Name another protocol.** Add the port to `ProtocolCatalog`, give it a category, and, if its first bytes are
  distinctive, add a detector in `ProtocolClassifier.swift`. `testExtendedProtocolCoverage` checks that every named
  protocol has a category.

## Ground rules

- **Privacy first.** Never store packet payloads, and never send user data off the Mac without an explicit opt-in.
- **Explainable alerts.** Every alert names the app, the destination and the number that tripped it.
- **Don't commit real traffic.** Screenshots and fixtures come from demo mode or synthetic data only.
- Match the surrounding code style. Keep PRs focused, with tests for behavior changes.

## Branches and releases

Every release follows this non-negotiable sequence:

```text
feature branch → release branch → reviewed green PR → immutable tag → signed dry run → publish and verify → merge to main
```

`main` is what has shipped, not what is being built. Start each feature from it and rebase it onto it; never merge
`main` into a feature branch. The release branch gathers the finished work and carries the version, release notes and
rebuilt site until the release is public.

```sh
git switch -c feature/relaunch-through-proxy main
# work, test, then keep current with: git rebase main

git switch -c release/0.13.4 main
git merge --ff-only feature/relaunch-through-proxy
# final release commit: MARKETING_VERSION/CURRENT_PROJECT_VERSION, site/pages/releases.html, rebuilt docs/

git push -u origin release/0.13.4
gh pr create --base main --title "Flowlight 0.13.4"
# wait for review and every required PR check to pass

git tag -a v0.13.4 -m "Flowlight 0.13.4"
git push origin v0.13.4
# cancel the automatic publish run, then exercise the immutable tag first:
gh workflow run Release --ref v0.13.4 -f dry_run=true
# inspect the successful signed/notarized/Gatekeeper dry run, then publish from the same tag:
gh workflow run Release --ref v0.13.4
# verify the GitHub release, DMG, PKG and SHA256SUMS.txt before the final merge
gh pr merge --merge --delete-branch
```

**Tags are immutable.** Never retag, force-push or move a version after it has been pushed. If a tag is wrong or a
release needs another change, bump the patch version and begin a new release branch and tag.

**The PR precedes the tag, and the merge follows publication.** Review and green checks protect the exact tree that
will be signed. Publishing before merging keeps the GitHub Pages site from announcing a download that does not exist:
`docs/` is served from `main`, its Download button resolves to the latest GitHub release, CI requires `docs/` to match
`site/`, and the site builder reads `MARKETING_VERSION`.

A tag push starts `release.yml`; cancel that automatic publication before it reaches its publish step and dispatch the
dry run from the immutable tag. A dry run must prove tests, signing, notarization and Gatekeeper verification before a
production dispatch is allowed. After production succeeds, verify the release page and downloaded DMG, PKG and
`SHA256SUMS.txt` checksums, then merge the release PR into `main`.

[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#release-branches) documents the signing inputs and workflow internals.

## License

Flowlight is licensed under the [GNU GPL v3.0](LICENSE). By contributing, you agree that your contributions are
licensed under the same terms.
