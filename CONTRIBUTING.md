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

## License

Flowlight is licensed under the [GNU GPL v3.0](LICENSE). By contributing, you agree that your contributions are
licensed under the same terms.
