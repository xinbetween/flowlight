# macOS Network Traffic Monitor — Design Notes

## Goal

A native macOS application that monitors all TCP/UDP-based traffic (HTTP, HTTPS, FTP, FTPS, DNS, etc.) per IP and domain, attributes each connection to the process/application that created it, and produces analytical reports at second, minute, hour, day, week, month, and year granularity. Accumulated bytes sent and received should be easy to inspect, and the reports should make abnormal traffic visible. Think Wireshark-style visibility plus analytics.

## Key constraints on macOS

1. **Process attribution requires the Network Extension framework.** Raw packet capture (libpcap / `/dev/bpf`, what Wireshark uses) gives packets but not the owning process. `NEFilterDataProvider` (content filter) delivers every TCP/UDP *flow* together with the source app's audit token, PID, bundle ID, and signing identity. This is how Little Snitch and LuLu work.
2. **Thread-level attribution is not available.** The kernel provides a per-process audit token, not a thread ID. Process → flow is reliable; thread → flow would require injecting into the target process, which is not viable under the hardened runtime. Plan for process/app granularity.
3. **Apple entitlements are required.** `com.apple.developer.networking.networkextension` with `content-filter-provider-systemextension` (and `transparent-proxy` if that route is taken) must be requested from Apple via a form. Approval can take days to weeks. Kernel extensions are effectively dead for this since macOS 11; a System Extension is the only path.
4. **HTTPS payloads are opaque** unless you MITM. For the stated goal (who sent how much to whom) this is not needed: destination IP + port, the SNI hostname from the TLS ClientHello, and DNS answers give the domain mapping, and byte counts come from the flow itself.

## Architecture overview

```
Kernel
  └─ TCP / UDP flows with audit token
        │
        ▼
System extension (NEFilterDataProvider)
  Flow observer (PID, bundle, bytes)
        → Enrichment (SNI, DNS, protocol)
        → Aggregator (1s buckets → XPC)
        │
        ▼
Host app (SwiftUI)
  SQLite rollups  ←  Charts + anomaly engine
```

## Component choices

### Capture layer

Implement `NEFilterDataProvider` in a System Extension. In `handleNewFlow` you receive an `NEFilterSocketFlow` with remote endpoint, protocol, and `sourceAppAuditToken`. Call `audit_token_to_pid` and `SecCodeCopySigningInformation` to obtain PID, bundle ID, and code-signing identity. Return `.allow()` with `peekInboundBytes` / `peekOutboundBytes` set; `handleInboundData` / `handleOutboundData` then provide byte counts per flow. Payloads do not need to be retained — count them and move on. Configure the filter to observe both TCP and UDP so DNS and QUIC are covered.

### Domain resolution

Three sources, in priority order:

1. SNI parsed from the first outbound TLS record on port 443.
2. The `Host` header for plain HTTP.
3. A passive DNS cache built from UDP/53 flows (map answered IPs → queried name).

Fall back to reverse DNS only as a last resort; it is slow and often wrong.

### Protocol classification

Port heuristics plus the first few bytes:

- TLS handshake byte `0x16`
- HTTP method tokens (`GET`, `POST`, ...)
- FTP `220` banner
- SSH `SSH-` banner
- FTPS: TLS on port 990, or explicit `AUTH TLS` on port 21

Keep this as a small pluggable classifier so protocols can be added later.

### Aggregation

The extension should emit only per-second summaries over XPC, never per-packet events:

- **Key:** `(pid, bundle id, remote ip, domain, port, protocol)`
- **Value:** bytes in, bytes out, flow count

This keeps the hot path cheap and avoids IPC flooding.

### Storage

SQLite (via GRDB) in an App Group container so both processes can access it.

- `flows_1s` — raw per-second table with a short retention window (hours)
- `agg_1m`, `agg_1h`, `agg_1d` — materialized rollup tables

A background task folds each tier into the next and prunes older rows. Week/month/year queries hit the daily table and stay fast.

### Anomaly detection

Start simple and explainable:

- Per-app baselines: EWMA of bytes/hour, distinct destinations/day
- Z-score alerts when current usage exceeds baseline by N sigma
- Rule triggers:
  - First contact with a never-seen domain
  - Connections to non-standard ports
  - Uploads exceeding the app's historical 99th percentile
  - Traffic while the app has no UI activity

Add seasonality (weekday/hour) later if baselines are noisy.

### UI

- SwiftUI with Swift Charts for time series
- Sortable table grouped by app → domain → IP
- Live "top talkers" view reading the 1s table
- App-icon column via `NSWorkspace.shared.icon(forFile:)`

## Suggested build order

1. Submit the entitlement request immediately. Work in parallel with a development-signed extension (requires disabling SIP or using `systemextensionsctl developer on` on a test Mac).
2. Ship a minimal extension that logs flows with PID and bytes to the console. This validates the hardest part.
3. Add XPC + SQLite + a bare table UI.
4. Domain enrichment, rollups, charts.
5. Anomaly rules, notifications, export.

## Reference codebases

- **LuLu** — Objective-C, open source; uses exactly this filter approach.
- **Apple's SimpleFirewall sample project** — shows the extension/app plumbing.