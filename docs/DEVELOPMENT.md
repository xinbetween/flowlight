# Flowlight: developer guide

Internals, build options and the Network Extension path. For an overview, see the [README](../README.md).

## Layout

```
project.yml                 XcodeGen source of truth
Flowlight.xcodeproj/         Committed shared output so Xcode Cloud can discover the project before build scripts run
Shared/                     Compiled into both targets
  TrafficModels.swift         FlowKey (pid, bundle, ip, domain, port, protocol) → bytes in/out, flows
  IPCProtocol.swift           XPC contract between the extension and the app
  AgentPolicy.swift           Per-agent allowlist: patterns, AI providers, whether it blocks
  AgentCatalog.swift          Known agents and LLM API providers
  BlockRules.swift            Whether a flow is refused — pure functions over plain data
  Classification/             Pluggable protocol classifier, TLS SNI, HTTP Host, DNS parsers, DNS cache
FlowlightExtension/         System extension (NEFilterDataProvider)
  FilterDataProvider.swift    Peeks at the first bytes, counts bytes from statistics reports, drops refused flows
  FlowTracker.swift           Per-flow state, domain priority (SNI > Host > system hostname > DNS cache)
  ProcessResolver.swift       Audit token → pid, code signature, path, bundle ID
  BlockEnforcer.swift         Holds the enforcing allowlists, resolves a flow's agent, reports every refusal
  IPCServer.swift             Mach service; pushes 1-second batches to the app (buffers up to 1 h)
Flowlight/                  SwiftUI host app
  Capture/                    Extension installer, XPC client, nettop fallback sampler
  Storage/                    SQLite (no dependencies): flows_1s → agg_1m → agg_1h / agg_1d rollups
  Enrichment/                 BPF packet capture (DNS + TLS SNI), network-owner (ASN) lookup
  Analysis/                   EWMA/z-score baselines, rule engine, AI agent catalog + rules, UI-activity tracker
  Inspection/                 HTTPS inspection: local CA, decrypting proxy, HTTP parser, recorder, mock rules
  Export/                     opt-in export to a collector the user chooses: OTLP/NDJSON payloads, queue, Keychain
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
brew install xcodegen  # project regeneration requires exactly 2.46.0
scripts/check_xcode_project.sh --write

# Any Mac, no entitlements: ad-hoc signed, nettop fallback only
scripts/build-local.sh
open build/Build/Products/Release/Flowlight.app

# With the Network Extension (after Apple grants the entitlement)
TEAM_ID=ABCDE12345 scripts/build-signed.sh
```

Run the tests with `xcodebuild -scheme Flowlight test CODE_SIGN_IDENTITY=- CODE_SIGN_ENTITLEMENTS= DEVELOPMENT_TEAM=`.

`project.yml` remains the editable project definition. After changing it, run
`scripts/check_xcode_project.sh --write`, verify with `scripts/check_xcode_project.sh`, and commit the four shared files under
`Flowlight.xcodeproj/`. The generated project is deliberately committed because Xcode Cloud must find its selected
container before a post-clone script can run. User data and Xcode Cloud's local manifest remain ignored.

**If the checkout is under `~/Desktop`, `~/Documents` or `~/Downloads`, two tests will hang for two minutes
each and the run will fail.** `HelpTests` reads the built `docs/docs/index.html` to check that every screen's
Help anchor exists, and macOS asks for consent before the test host may read those folders — with nobody there
to click Allow, the read blocks until the test times out. Nothing is wrong with the code: the same two tests
pass in milliseconds from a checkout outside those folders, which is also why CI never sees it. Move the
checkout, or grant the test host Full Disk Access. `python3 scripts/check_site.py` asserts the same agreement
without a test host, so it is the quicker way to check that particular thing anyway.

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

## Blocking

An allowlist reports by default. Turning on **Block connections that aren't allowed** for one agent (AI Agents ›
its allowlist) sets `AgentPolicy.enforce`, and from then on the content filter refuses what the list doesn't cover.
The switch only appears when the Network Extension is the capture source and is actually filtering: nothing else
sits in the path of a connection, and a switch that did nothing would be worse than the explanation that replaces it.

- The app sends the enforcing policies to the extension over XPC (`setEnforcement`) on every connection and every
  change. The extension keeps no copy on disk, so a policy can never outlive the app that owns it.
- The decision happens in `handleOutboundData`, not `handleNewFlow`: `flow.remoteHostname` is usually nil when a
  flow starts and TLS SNI arrives in the first outbound bytes. `BlockRules.verdict` returns `.undecided` until the
  flow has a hostname or can no longer produce one, and a flow that never names itself is judged on its IP alone.
- Never refused, whatever a list says: the local network, Apple's services, anything from a `com.apple.*` process
  or from Flowlight itself, and DNS. Where the rules are unsure they allow and record.
- Enforcement lapses a few seconds after the app disconnects (`BlockRules.inForce`). A refusal that can't be
  recorded is worse than no refusal, and "allow this from now on" lives in the app.
- Every refusal travels back as a `BlockEvent` and becomes a **Connection blocked** alert naming the agent, the
  process, the destination and the fact that it didn't get there. That alert's context menu offers *Allow … from
  Now On*, which adds the destination to the agent's list and pushes the change straight back to the filter.
- A flow through the HTTPS inspection proxy leaves the Mac as exempt Flowlight traffic. Before opening that upstream
  connection, the proxy attributes the original client and applies destination rules plus the exact managed-pack snapshot
  acknowledged by the extension. Pack refusal waits for its durable activity record and fails open if that record cannot
  commit. Agent allowlists remain extension-only and do not compose with the proxied leg.
- `BlockRules` is plain functions over plain data (like `AgentPolicy.matches`), so `BlockingTests` covers the whole
  decision without a filter installed.

## Mock responses

A rule (`MockRule`) answers a chosen endpoint from Flowlight instead of letting the request reach the server, so an
agent can be shown an API that fails, stalls or replies with something odd. Rules live in UserDefaults as JSON
(`inspection.mockRules`), are tried in order, and the first enabled match answers.

- **Matching** is `MockRules`, plain functions over plain data like `AgentPolicy.matches`, so `MockResponseTests`
  covers precedence and every host, path and method form without a proxy. Host: `api.example.com` is that host
  exactly, `*.example.com` covers the domain and its subdomains. Path: one glob where `*` is any run of characters,
  compared against the path alone unless the pattern contains a `?`. Method: empty or `ANY` matches all. An empty
  host matches nothing — a rule in progress must never answer everything.
- **In the proxy**, `relay` reads the rules once per flow. A host no rule names keeps the byte-for-byte relay it had
  before, never framed; otherwise a `MockGate` frames the client's stream and partitions every byte into forward,
  hold or answer. `pump`'s tap returns what carries on to the destination, so a held request simply isn't written
  upstream, and the canned response goes back to the client after the rule's delay.
- **It's still recorded.** The recorder sees the same client bytes either way, plus the canned response as if the
  server had sent it, so pairing, parsing and storage are unchanged. Flowlight writes `Content-Length`,
  `Connection: close` and `X-Flowlight-Mock` itself — a mock whose framing disagreed with its body would hang the
  client rather than test it — and strips CR/LF from rule-supplied headers so a rule can't forge a second response.
- **Draft versus rule data.** **Mock This…** reads only retained body blobs and already-redacted stored headers into a
  temporary editor draft. Request headers and payload are reference-only and never become match criteria or durable
  preferences. The saved response is deliberate rule data: text is encoded as UTF-8, binary bytes as validated hex,
  and the rule remains in `inspection.mockRules` until removed even after captured traffic is cleared.
- **A mocked exchange says so**: the rule's name goes in `HTTPExchange.mockRule` (column `mock_rule`, an in-place
  `ALTER`), not in `note`, which means "nothing was inspected". Inspect badges the row and leads the detail pane
  with the fact that the request was never sent, and the active rule count sits in the status bar — a mock left on
  otherwise looks exactly like an agent misbehaving.
- A host named by a rule is decrypted whatever the scope says: a rule can only answer a request Flowlight can read.
  Nothing can be mocked on a tunnelled connection (never-inspect list, pinned certificates, traffic that doesn't go
  through the proxy), and the UI says so rather than leaving it to be discovered.
- The destination is still connected to before the gate runs, so a mock changes the answer, not whether the
  connection can be made: "the API returns 500" works, "the API is entirely down" doesn't.

## Export to OpenTelemetry / SIEM

The first feature that deliberately sends recorded traffic off the Mac, so most of its design is about being
predictable rather than about throughput. Settings › Export, off by default, and there is no Flowlight-operated
endpoint to fall back to — the user names one or nothing is sent.

- **Two formats.** OTLP over HTTP with a JSON body (the protobuf's canonical JSON mapping) is the primary one:
  rollups become **metrics** on `/v1/metrics` and alerts become **logs** on `/v1/logs`, appended to the base
  endpoint unless it already names a signal. Rollups are delta sums (`aggregationTemporality: 1`) because each one
  covers one window — a monitor that restarts has no running total to report. 64-bit values go on the wire as
  strings, which ProtoJSON requires and which a large byte count needs. The alternative is one JSON object per
  line to a single URL, which is all most SIEM HTTP inputs want.
- **`ExportField` is the contract.** Every key either format can emit is a case on it, with the sentence Settings
  shows beside it, and the payload builders take their keys from nowhere else. `ExportTests` walks generated JSON
  and fails on any key that isn't declared, so the list a user reads can't fall behind what the code sends.
- **Nothing from inspection, structurally.** `ExportPayload` accepts `ExportRollup` and `ExportAlert` and nothing
  else, and neither has anywhere to put a header, a body or a tool call. A test mirrors both types and asserts
  their exact field sets, so adding one is a deliberate change rather than a slip. `appPath` is dropped on the way
  in: it names the user's home folder and a collector has no use for it.
- **`ExportQueue` is plain functions over plain data**, like `AgentPolicy.matches` and `BlockRules.verdict`, so
  batching, the buffer cap and giving up are covered without a network. It holds at most 10,000 records including
  the batch in flight, drops oldest-first (rollups before alerts) and counts what it dropped; a failing batch is
  retried as-is, with a capped exponential delay and no jitter — there is one Flowlight talking to one collector,
  so there is no herd to spread out — and is dropped after five attempts rather than blocking everything behind it.
  One OTLP batch is two requests, so only the half that failed is retried.
- **Timing.** Rollups come from `breakdown(.minute, …)`, the same query Reports uses, over the window since the
  last export; it stops two minutes short of now because a minute only lands in `agg_1m` once maintenance has
  folded it, and reaches back at most an hour, so a Mac that slept for a week resumes instead of replaying it.
  Alerts are enqueued as `AnomalyEngine` raises them. Switching export on sets the watermark to that moment:
  history already in the database is never sent.
- **The token lives in the Keychain** (`ExportSecrets`, a generic password under `com.flowlight.app.export`), not
  UserDefaults, and the whole header set goes in rather than a guess at which header is the secret one.
- **It has to be visible.** The requests leave as the app's own traffic and are never routed through the
  inspection proxy, even when the system proxy points at it, so they appear in Live and Reports and raise a
  first-contact alert the first time they go somewhere new. One gap to know about: with HTTPS inspection running,
  `ProxyAttribution.rewrite` discards Flowlight's own loopback records, so an export to a collector on
  `127.0.0.1` isn't counted while inspection is on. A remote collector is unaffected either way.
- **Before anything leaves**, Settings offers a preview built from the reader's own last 15 minutes — the real
  request, pretty-printed, with header values masked and nothing sent — and a Test Connection that posts the
  smallest thing the format allows (an OTLP request with an empty record list, or one line marked as a test) and
  reports the status code it actually got back.

## Demo mode

`open Flowlight.app --args -FLDemo YES` uses a separate database (`demo.sqlite`) seeded with 90 days of synthetic
traffic and a live synthetic feed. Suspicious destinations use reserved documentation addresses
(`203.0.113.0/24`, `*.example`). The README and website screenshots come from this mode.

## Known limitations

- Thread-level attribution isn't possible (see `product.md`). Attribution is per process or app.
- Byte counts in the extension come from `NEFilterReport` statistics events (`statisticsReportFrequency = .high`).
  Check them against the flows logged on a real device (build order step 2) before relying on them.
- QUIC SNI isn't decrypted. QUIC flows get their domain from the system hostname or the DNS cache.

## Website

`site/` is the source, `docs/` is the generated site GitHub Pages serves, and both are committed — CI rebuilds
and fails if they differ. Pages are templates: `site/pages/` for English, `site/pages/<lang>/` for the nine
translations, strings in `site/i18n/<lang>.json`, and `{{link:}}`, `{{t:}}`, `{{current:}}`, `{{root}}`
placeholders the build resolves.

```sh
python3 scripts/build_site.py     # regenerate docs/
python3 scripts/check_site.py     # then check what the build cannot
```

The build is a renderer, so anything that is still valid HTML gets published. `check_site.py` covers the ways
that has gone wrong, most of them in production:

| Check | The bug it exists for |
| --- | --- |
| No unrendered `{{...}}` | `{{t:nav.threat-model}}` printed itself on all 51 pages — the pattern didn't allow hyphens |
| No third-party fetches | The privacy page loaded its fonts from Google, which is the one thing it promises not to do |
| Anchors exist in their target | A section added to the English docs left nine translated pages linking to `#coverage` |
| Internal links resolve | — |
| The roadmap is ahead of the newest release | "What's coming" kept listing versions you could already download |
| Translations have every English section | The same `#coverage` gap, caught at the missing section rather than at the dangling link |
| Translated roadmaps list as much as English | Nine home pages promised "the rest, in this order" and then one item |
| Every screen's `helpAnchor` has a docs section | Coverage shipped with a Help button and nothing on the page to land on |
| Screenshots exist, and none is unused | `live.png` was served to nobody for two releases |
| The views table matches the sidebar | It gave Inspect ⌘5 long after it became ⌘7, and never listed Rules, Ask, Devices or Coverage |
| One `<h1>` per page | A translation duplicating a heading while editing |

Three of those read the app rather than the site — `helpAnchor` and the sidebar's own order come from
`AppNavigation.swift`, so adding a screen is itself what asks for the documentation and renumbers the
shortcuts. That order is positional, which is exactly why the table drifted: inserting Rules moved every
screen after it and nothing said so. Screenshot `width`/`height` used to be on this list; the
build now stamps them from the PNG, which is better than checking a number a person has to keep correct.

Add a rule when something slips past this list; that is cheaper than finding it twice.

### Publishing official rule packs

`rule-packs/official-source.json` is the reviewed, unsigned source for the official catalog. The signed catalog is
`site/packs/v1/official.json`; `build_site.py` copies it byte-for-byte to `docs/packs/v1/official.json`, which Pages
serves at `https://flowlight.xinbetween.com/packs/v1/official.json`. CI and Pages validate the catalog and verify its
P-256 signature against `Flowlight/Resources/RulePacks/official-rule-packs-v1-public.pem`. They never sign it and have
no private key.

Validate edits before asking the offline signer to sign them. The catalog validator also enforces an explicit,
evidence-backed allowlist for `official.tracking`: dedicated collection, replay and tracker-bootstrap hosts are allowed,
while product/shared domains fail before signing. Add a new endpoint only with vendor documentation and regression
coverage showing both its collector behavior and the product surfaces that must remain reachable.

```sh
scripts/test-rule-pack-policy.sh
python3 -I scripts/rule_pack_catalog.py validate rule-packs/official-source.json
python3 -I scripts/rule_pack_catalog.py digest rule-packs/official-source.json
```

Every publication has a strictly increasing positive `sequence`. Never reuse or lower one, even to restore older
content: make the desired content a new catalog with a higher sequence. Set fixed Unix-second `issuedAt` and
`expiresAt` values as part of the reviewed source. Keep the signing key offline, pass its path explicitly, and write
the result directly to the site source without printing or copying key material:

```sh
python3 -I scripts/rule_pack_catalog.py sign rule-packs/official-source.json site/packs/v1/official.json \
  --private-key /offline/path/official-rule-packs-private.pem \
  --key-id flowlight-rule-packs-2026-01
python3 -I scripts/rule_pack_catalog.py compare \
  rule-packs/official-source.json site/packs/v1/official.json
python3 -I scripts/rule_pack_catalog.py compare-previous site/packs/v1/official.json \
  --previous-ref origin/main
# Use `verify --historical` only for an immutable prior catalog; it still verifies structure and signature but does
# not retroactively apply today's endpoint allowlist to content published before that policy existed.
python3 -I scripts/rule_pack_catalog.py verify site/packs/v1/official.json \
  --public-key Flowlight/Resources/RulePacks/official-rule-packs-v1-public.pem \
  --expected-key-id flowlight-rule-packs-2026-01
python3 scripts/build_site.py
python3 scripts/check_site.py
```

For key rotation, first release an app that trusts both the old and new public keys. During that overlap, sign the
same canonical payload once with each key; `sign` replaces only the named key's signature and preserves the other.
Add both `--expected-key-id`/`--public-key` pairs to the CI and Pages verification commands for the entire overlap so
neither signature can disappear unnoticed. Publish the dual-signed feed, wait for the trusting app release to
propagate, then a later app release may remove the old key. A compromised or retired key is revoked by an app release
that removes it from the trust set; the feed
cannot revoke its own signing authority. If compromise is suspected, stop publishing, ship the trust change, and
resume with a higher sequence signed by a trusted key. Clients reject rollback by sequence, so restoring an older
catalog always means republishing its contents under a new, higher sequence.

### Consuming the official rule-pack feed

`RulePackCatalogUpdater` is app-owned and has one compiled HTTPS source. It uses an ephemeral cookieless session,
requires same-origin redirects and JSON, caps both declared and streamed response bytes, sends persisted ETag and
Last-Modified validators, and permits only one request at a time. Healthy automatic checks run daily; failures back off
from one hour to six hours and then 24 hours. Manual checks bypass only that schedule. Demo and XCTest startup establish
the local trusted catalog but do not use the network unless a test explicitly injects a transport.

The receipt watermark and exact envelope cache are separate SQLite rows. Startup reverifies the exact accepted bytes
before saved configuration or exceptions can produce a snapshot, and capture does not start until that reload completes.
If a higher watermark has missing, corrupt, expired-before-acceptance, or newly untrusted bytes, definitions and the
snapshot stay empty while recovery fetches without validators; the bundled lower sequence is never silently restored.
An already accepted envelope may reverify after expiry as stale last-known-good.

Acceptance runs in `BEGIN IMMEDIATE`: rollback/equivocation checks, exact bytes, validators, scheduling state, and consent
invalidation commit together. Only then may `RulePackStore` publish definitions or a snapshot. New packs default off;
changed content preserves saved scope, app selection, exceptions, and historical activity but is effectively disabled.
Every enabling Save carries the immutable pack and catalog receipt displayed when the editor opened, and SQLite checks
the durable catalog again inside the save transaction.

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
  which is what CI uses). With neither, it prints why it did nothing and exits 0. After Apple accepts an upload,
  stapling retries a bounded four times only for `NSURLErrorDomain -1005`; every other stapler failure stops
  immediately, and the upload is never submitted twice.

## Release branches

`main` is what has shipped. Work happens on a feature branch, lands on the release branch, and reaches `main`
only when the release is published.

The reason is the website. It is served from `docs/` on `main`, and its Download button points at
`releases/latest/download/Flowlight.dmg` — so a `main` carrying the new version announces a release that
cannot be downloaded until signing and notarization finish. `docs/` also has to match `site/` in the same
commit (CI checks it) and `build_site.py` reads `MARKETING_VERSION`, so the version bump and the rebuilt site
cannot be separated. Keeping both off `main` until the release exists is what the branch is for.

Every release follows the mandatory sequence **feature branch → release branch → reviewed green PR → immutable tag → signed dry run → publish and verify → merge to main**:

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
git push origin v0.13.4  # automatically runs the signed dry run; it cannot publish
# inspect that successful signed/notarized/Gatekeeper run, then publish from the same tag:
gh workflow run Release --ref v0.13.4 -f tag=v0.13.4
# verify the GitHub release, DMG, PKG and SHA256SUMS.txt before the final merge
gh pr merge --merge --delete-branch
```

The PR comes before the tag so the release's whole diff is reviewed and green before anything is signed; the merge
comes after publication so the site can only ever describe something downloadable. **Tags are immutable:** never retag,
force-push or move a pushed version. If a tag is wrong or a release needs another change, bump the patch version and
begin a new release branch and tag.

A tag push starts `release.yml` automatically in dry-run-only mode; push-triggered runs cannot publish. It must build,
sign, notarize and pass Gatekeeper verification before an explicit production dispatch for the immutable tag. After
production succeeds, verify the GitHub release page and downloaded DMG, PKG and
`SHA256SUMS.txt` checksums before merging the release PR.

## Releasing from CI

`.github/workflows/release.yml` checks the tag matches `MARKETING_VERSION`, runs the tests, signs, notarizes and
verifies with `spctl`. A tag push always stops there; an explicit dispatch for that tag publishes the release and updates
the Homebrew cask. `.github/workflows/ci.yml` builds and tests every push and pull request, and fails if `docs/` is out
of date with `site/`.

```sh
scripts/ci-secrets.sh                                  # upload the secrets once
git tag -a v0.3.0 -m "Flowlight 0.3.0" && git push origin v0.3.0  # automatic dry run
gh workflow run Release --ref v0.3.0 -f tag=v0.3.0     # after it passes: publish
```

`--ref` has to name a tag whose tree *contains* the workflow: `gh` reads the workflow file from the ref you give
it, so tags older than `.github/workflows/release.yml` fail with "Workflow does not have 'workflow_dispatch'
trigger". The environment only accepts `v*` tags, so dispatching from a branch is refused at the approval gate —
which is the point of it.

A tag push—and an explicit dispatch with **dry_run=true**—builds, signs, notarizes and asks Gatekeeper for a verdict,
then stops without creating a release or touching the cask. Production requires an explicit dispatch with the tag input
and **dry_run=false**.

Release notes come from `packaging/release-notes/<version>.md` when that file exists (checksums are appended), and
from generated notes when it doesn't.

`scripts/ci-secrets.sh` finds the two provisioning profiles by name in Xcode's folder, so the only things it asks
for are the certificate exports and how to notarize. Prefer the App Store Connect key where you can: it can only
notarize, so revoking it breaks nothing else, whereas an app-specific password authenticates as your Apple ID.

| Secret | What it is |
|---|---|
| `APP_CERTIFICATE_P12` | Developer ID **Application** certificate + key as .p12, base64. Export it from Keychain Access's **My Certificates** tab (File › Export Items…) — All Items shows the bare certificate and offers no Export |
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
2. **Only listed accounts can start a release.** The environment no longer waits for a click — a release by the
   maintainer shouldn't need the maintainer to approve themselves. In its place the job refuses to run unless
   `github.actor` is in `RELEASE_ACTORS` (a repository variable, `blessdyb` by default), so a tag pushed by
   anyone else fails instead of producing a signed build. This is weaker than an approval: it trusts the account
   rather than a person at the keyboard, so it stands on the account's own protection. Put the reviewers back
   (Settings › Environments › release) if that trade stops being the right one.
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

