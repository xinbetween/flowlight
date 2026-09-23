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
INSTALLER_IDENTITY="Developer ID Installer: Your Name (ABCDE12345)" TEAM_ID=ABCDE12345 scripts/build-pkg.sh
gh release create v0.1.0 build/Flowlight.dmg build/Flowlight-0.1.0.pkg --title "Flowlight 0.1.0" --generate-notes
```

- Keep the DMG asset named exactly `Flowlight.dmg`: the website and README link to
  `releases/latest/download/Flowlight.dmg`.
- Without `DMG_SIGN_IDENTITY` and `NOTARY_PROFILE` the DMG contains an ad-hoc signed app. That's fine for testing,
  but Gatekeeper will ask users to right-click › Open.
- The DMG window layout needs Finder automation permission for the terminal that runs the script. The background
  art comes from `packaging/dmg/background*.png` (regenerate with `swift scripts/dmg-background.swift`).
