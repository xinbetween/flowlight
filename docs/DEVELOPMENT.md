# Flowlight: developer guide

Internals, build options and the Network Extension path. For an overview, see the [README](../README.md).

## Layout

```
project.yml                 XcodeGen spec (run `xcodegen generate` to regenerate the .xcodeproj)
Shared/                     Compiled into both targets
  TrafficModels.swift         FlowKey (pid, bundle, ip, domain, port, protocol) → bytes in/out, flows
  IPCProtocol.swift           XPC contract between the extension and the app
  Classification/             Pluggable protocol classifier, TLS SNI, HTTP Host, DNS parsers, DNS cache
FlowlightExtension/         System extension (NEFilterDataProvider)
  FilterDataProvider.swift    Peeks at the first bytes, never blocks, counts bytes from statistics reports
  FlowTracker.swift           Per-flow state, domain priority (SNI > Host > system hostname > DNS cache)
  ProcessResolver.swift       Audit token → pid, code signature, path, bundle ID
  IPCServer.swift             Mach service; pushes 1-second batches to the app (buffers up to 1 h)
Flowlight/                  SwiftUI host app
  Capture/                    Extension installer, XPC client, nettop fallback sampler
  Storage/                    SQLite (no dependencies): flows_1s → agg_1m → agg_1h / agg_1d rollups
  Enrichment/                 BPF packet capture (DNS + TLS SNI), network-owner (ASN) lookup
  Analysis/                   EWMA/z-score baselines, rule engine, AI agent catalog + rules, UI-activity tracker
  UI/                         Live, AI Agents, Reports (charts + three breakdown groupings + CSV), Alerts, Capture
Shared/Classification/ProtocolCatalog.swift   108 protocols in 13 families, used by both capture engines
FlowlightTests/             Parser, classifier, BPF filter, rollup, chart, agent and anomaly tests
```

## Capture sources

| | Network Extension | nettop sampler (fallback) |
|---|---|---|
| Requires | Paid team + NE entitlement, app in /Applications | Nothing |
| Attribution | Audit token → app (signing identity) | pid → process path |
| Domains | SNI, HTTP Host, system hostname, passive DNS | SNI + DNS from packet capture (one-time admin setup), reverse DNS, network owner |
| Protocols | First bytes + ports | Ports only |
| Short-lived flows | Every flow | Flows shorter than ~1 s are missed |

Choose the source in **Capture**. Both produce the same per-second batches, so storage, reports and
anomaly detection work the same way with either one.

### Hostnames in nettop mode

nettop only reports IP addresses, so Flowlight fills in names from several sources, in order:

1. **Packet capture** (Capture › Hostnames › *Enable Packet Capture…*). A one-time admin prompt installs
   `/Library/LaunchDaemons/com.flowlight.bpf-access.plist`, which gives the `access_bpf` group read access to
   `/dev/bpf*` at boot. This is the same approach as Wireshark's ChmodBPF. Capture follows the primary interface,
   so traffic confined to another interface or tunnel may lack names. A kernel BPF filter passes only DNS
   responses and TLS ClientHellos, so the cost doesn't grow with traffic. Packet contents are never stored.
   *Remove Packet Capture Access…* undoes the setup. On first launch, Flowlight offers the setup once
   ("Name Your Traffic") for both package and drag-and-drop installs. The package installs the app without
   granting BPF access. Launch with `-FLForceCaptureOnboarding YES` to show the offer again.
2. **Reverse DNS**, as a last resort.
3. **Network owner**: the IP's autonomous system (e.g. "Cloudflare, Inc. · AS13335"), from Team Cymru's DNS
   interface. This lookup is on by default and sends only public IPs; turn it off during setup or in Capture.
   Public IPs are sent to that service, while local and reserved addresses stay on the Mac.

Reports group any traffic still without a hostname under its network owner.

## Building

```sh
brew install xcodegen
xcodegen generate

# Any Mac, no entitlements: ad-hoc signed, nettop fallback only
scripts/build-local.sh
open build/Build/Products/Release/Flowlight.app

# With the Network Extension (after Apple grants the entitlement)
TEAM_ID=ABCDE12345 scripts/build-signed.sh
```

Run the tests with `xcodebuild -scheme Flowlight test CODE_SIGN_IDENTITY=- CODE_SIGN_ENTITLEMENTS= DEVELOPMENT_TEAM=`.

### Activating the extension

1. Request `content-filter-provider-systemextension` from Apple
   (https://developer.apple.com/contact/request/network-extension). A free Personal Team can't sign it.
2. For development, before the entitlement is granted: disable SIP on a test Mac and run
   `systemextensionsctl developer on`.
3. Copy the app to `/Applications`, open **Capture**, and click **Install & enable filter**.
   Then approve it in System Settings › General › Login Items & Extensions, and allow the content filter.
4. Switch the source to **Network Extension**.
5. Check the extension's logs:
   `log stream --predicate 'subsystem == "com.flowlight.app.filter"'`

The App Group and Mach service names come from `$(TeamIdentifierPrefix)com.flowlight.shared`.

## Storage and reports

- `flows_1s` is kept for 6 h (configurable), `agg_1m` for 14 days, `agg_1h` for 400 days, and `agg_1d` forever.
- Complete minutes fold into `agg_1m` once a minute. Hour and day tiers are folded from the immutable
  minute rows, keyed by a watermark, so re-running a rollup never double counts.
- Week, month and year reports bucket the daily table with the user's calendar.
- The database always lives in `~/Library/Application Support/Flowlight`, so history survives a build gaining or losing
  the App Group entitlement and a change of Team ID. The extension never opens it; it only shares the group for its XPC
  service. A database left in the group container by an older build is moved out on first launch (`resolveURL`).

## Anomaly detection

- **Traffic spike**: EWMA baseline of bytes per hour per app; alerts when an hour is at least Nσ above it
  (default 3σ, after 24 samples).
- **Unusual number of destinations**: EWMA of distinct destinations per day per app.
- **First contact with domain**: a new registrable domain for an app, after that app's learning period.
- **Non-standard port**: a new (app, port) pair outside the common-port list. Loopback, link-local and
  multicast are ignored.
- **Upload above 99th percentile**: an hour's upload exceeds the app's 30-day hourly p99 (needs 48 hours of history).
- **Traffic without UI activity**: a GUI app not frontmost for 10 min or more uploads over 5 MB/min.
- The Reports chart also marks buckets that are at least Nσ above the visible series.

## AI agent rules

Agents are apps in `AgentCatalog.agents` (matched by bundle ID or process name) plus any non-browser app seen
calling an LLM API provider (`AgentCatalog.providers`, matched by hostname suffix or network owner).

- **Sensitive channel**: the flow's protocol category is email, file transfer, remote access, tunnel/proxy,
  peer-to-peer or database (`ProtocolCategory.isSensitiveEgress`). Rate-limited per agent, protocol and
  destination every 6 h.
- **Possible exfiltration**: rolling 60-minute sum of uploads to non-provider, non-local hosts ≥ the threshold
  (default 100 MB).
- **Unnamed host**: no hostname, non-standard port, not on the local network.
- **Active while away**: `CGEventSource` reports no input for N minutes (default 15) and the agent moved ≥ 1 MB in
  the last minute.
- Agents use a 1-hour learning period for first-contact alerts.

## Demo mode

`open Flowlight.app --args -FLDemo YES` uses a separate database (`demo.sqlite`) seeded with 90 days of synthetic
traffic and a live synthetic feed. Suspicious destinations use reserved documentation addresses
(`203.0.113.0/24`, `*.example`). The README and website screenshots come from this mode.

## Known limitations

- Thread-level attribution isn't possible (see `product.md`). Attribution is per process or app.
- Byte counts in the extension come from `NEFilterReport` statistics events (`statisticsReportFrequency = .high`).
  Check them against the flows logged on a real device (build order step 2) before relying on them.
- QUIC SNI isn't decrypted. QUIC flows get their domain from the system hostname or the DNS cache.

## Releasing

```sh
TEAM_ID=ABCDE12345 \
DMG_SIGN_IDENTITY="Developer ID Application: Your Name (ABCDE12345)" \
NOTARY_PROFILE=flowlight-notary scripts/build-dmg.sh      # build/Flowlight.dmg, signed + notarized
INSTALLER_IDENTITY="Developer ID Installer: Your Name (ABCDE12345)" \
NOTARY_PROFILE=flowlight-notary TEAM_ID=ABCDE12345 scripts/build-pkg.sh
gh release create v0.1.0 build/Flowlight.dmg build/Flowlight-0.1.0.pkg --title "Flowlight 0.1.0" --generate-notes
scripts/update-cask.sh                                    # Homebrew cask → new version + checksum
git -C "$(brew --repository xinbetween/tap)" push          # publishes it
```

- Keep the DMG asset named exactly `Flowlight.dmg`: the website and README link to
  `releases/latest/download/Flowlight.dmg`, and so does the Homebrew cask.
- `scripts/update-cask.sh` runs after the release exists on GitHub: with no local build it checksums the published
  DMG. It lints the cask with `brew style` and `brew audit` in the tap, since Homebrew won't lint one outside a tap.
- `INSTALLER_IDENTITY` is what signs the `.pkg`. Leave it out and `build-pkg.sh` produces an unsigned package that
  Gatekeeper refuses, without saying so.
- Without `DMG_SIGN_IDENTITY` and `NOTARY_PROFILE` the DMG contains an ad-hoc signed app. That's fine for testing,
  but Gatekeeper will ask users to right-click › Open.
- The DMG window layout needs Finder automation permission for the terminal that runs the script. The background
  art comes from `packaging/dmg/background*.png` (regenerate with `swift scripts/dmg-background.swift`). On a CI
  runner the layout step is skipped with a warning and the DMG still works.
- `scripts/notarize.sh` does the submit-and-staple for all three scripts. It takes either `NOTARY_PROFILE` (a
  keychain profile, on your own Mac) or `NOTARY_KEY` + `NOTARY_KEY_ID` + `NOTARY_ISSUER` (an App Store Connect key,
  which is what CI uses). With neither, it prints why it did nothing and exits 0.

## Releasing from CI

`.github/workflows/release.yml` does all of the above on a version tag: it checks the tag matches
`MARKETING_VERSION`, runs the tests, signs, notarizes, verifies with `spctl`, publishes the release and updates the
Homebrew cask. `.github/workflows/ci.yml` builds and tests every push and pull request, and fails if `docs/` is out
of date with `site/`.

```sh
scripts/ci-secrets.sh                       # upload the secrets once
git tag -a v0.3.0 -m "Flowlight 0.3.0" && git push origin v0.3.0
gh workflow run Release --ref v0.3.0        # or run it by hand against an existing tag
```

Release notes come from `packaging/release-notes/<version>.md` when that file exists (checksums are appended), and
from generated notes when it doesn't.

`scripts/ci-secrets.sh` finds the two provisioning profiles by name in Xcode's folder, so the only things it asks
for are the certificate exports and how to notarize. Prefer the App Store Connect key where you can: it can only
notarize, so revoking it breaks nothing else, whereas an app-specific password authenticates as your Apple ID.

| Secret | What it is |
|---|---|
| `APP_CERTIFICATE_P12` | Developer ID **Application** certificate + key, exported from Keychain Access as .p12, base64 |
| `INSTALLER_CERTIFICATE_P12` | Developer ID **Installer** certificate + key, same treatment |
| `CERTIFICATE_PASSWORD` | the password protecting both .p12 files |
| `APP_PROVISIONING_PROFILE` | `Flowlight Developer ID.provisionprofile`, base64 |
| `EXT_PROVISIONING_PROFILE` | `Flowlight Extension Developer ID.provisionprofile`, base64 |
| `NOTARY_KEY_P8` | App Store Connect API key (`AuthKey_*.p8`), base64 — *one of two ways to notarize* |
| `NOTARY_KEY_ID`, `NOTARY_ISSUER` | that key's Key ID and Issuer ID |
| `NOTARY_APPLE_ID`, `NOTARY_PASSWORD`, `NOTARY_TEAM_ID` | *the other way:* an Apple ID and an app-specific password |
| `TEAM_ID` | e.g. `38RJUJHKZS` |
| `DMG_SIGN_IDENTITY`, `INSTALLER_IDENTITY` | the identity names, e.g. `Developer ID Application: Your Name (TEAMID)` |
| `TAP_TOKEN` | *optional.* Fine-grained token with Contents: write on `xinbetween/homebrew-tap`, so the cask updates itself |

### What protects it

A signing identity in GitHub Actions is a signing identity outside your Mac, so the release path is fenced in four
ways. Each one is a setting on the repository; they aren't in this file, so this is also the record of what to
check if the setup is ever rebuilt.

1. **The secrets live in the `release` environment, not the repository.** Only a job that declares
   `environment: release` can read them. A workflow added to a branch cannot.
2. **That environment requires a human approval.** A tag push starts the job and then waits. Nothing is signed
   until someone with access clicks approve, and the approval is recorded on the run.
3. **The environment only accepts `v*` tags.** Its deployment branch policy is a single tag rule, so a run from a
   branch — or from a tag with any other name — can't reach the secrets even with approval.
4. **Release tags can't move.** A ruleset over `refs/tags/v*` blocks deletion, updates and force-pushes, so a
   published tag always points at the commit that was reviewed. `main` is likewise protected from force-pushes
   and deletion.

Third-party actions are pinned to a commit SHA rather than a moving tag, so a compromised action release can't
change what runs here.

**What's still true after all that.** Anyone who can approve a release can sign software as you, and anyone with
admin access can change who that is — a compromise of the GitHub account is a compromise of the certificate. The
App Store Connect key only notarizes and can't sign, so rotating it is cheap; the Developer ID certificates are
the ones that matter, and they're revocable in Apple's developer portal. If that trade is ever the wrong one, the
local recipe above still works and the workflow can sit unused.

