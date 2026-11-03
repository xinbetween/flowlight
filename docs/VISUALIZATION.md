# Traffic visualization — 0.16.x

Flowlight 0.16.x introduces one native visualization shell with two evidence-preserving modes. Both modes use the same system-adaptive canvas, deterministic layout, inspector, exact drill-down actions, and accessible list.

## 0.16.0 — Traffic

Traffic mode answers: **which applications moved traffic, and where did it go?**

- Every observed application is an app node with its native icon and name.
- Every exact `(hostname, IP address)` is a destination node. Hostname-less traffic keeps its owner/address identity.
- Curved path width represents total bytes.
- Moving particles represent sent and received direction; Reduce Motion removes them.
- Values are bytes and network connections (`FlowCounters.flows`), never mislabeled as HTTP requests.
- Ordinary traffic is **Observed**, not “Allowed.” A status badge appears only when a store provides matching structured evidence.
- The semantic graph retains every relationship in the selected search and Focus scope. The map derives a bounded projection for readability and reports exact omitted node, relationship, byte, and connection totals. The independently paged list reveals the complete graph 25 relationships at a time; paging never changes Map IDs or layout.
- Each application has one semantic card. Application-owned traffic, observed proxy routing, configured-gateway, launcher, agent, and tool roles remain distinct relationship evidence on that card, while observed traffic is counted exactly once.
- Selecting an app, destination, or relationship can open Reports, Inspect, or an unsaved rule editor with the exact app and host/address filter. Bare IPv4 and IPv6 destinations retain exact address identity and use `remoteIP` scope rather than a fabricated domain family.

The first slice reads the uncapped `TrafficDatabase.appDestinationRows` projection and builds a pure `TrafficGraphSnapshot`. Layout depends on stable topology IDs and viewport size, not counter values, so refreshes do not make nodes jump.

## 0.16.0 — AI

AI mode answers: **which AI agent clients and attributed tools moved traffic, which AI or MCP services did they use, and what else did they reach?**

### Inclusion

An AI root is included when any existing `AgentsModel` rule proves it is an agent:

1. `AgentCatalog.knownAgent` recognizes the client;
2. a stored row names it in `agent_parent`; or
3. a non-browser application contacts a domain or owner recognized by `AgentCatalog.provider`.

Browsers remain excluded from provider-based auto-discovery. A person opening an AI website is not automatically an agent.

Rows from a process with `agent_parent` fold into that agent's totals while retaining the process as a selectable tool node. A non-empty `mcp_server` makes that node an MCP service/tool node.

### Node types

- **Agent client** — Claude Code, Codex, Cursor, or another proved agent root.
- **Tool** — an attributed child process such as `git`, `curl`, or `node`.
- **MCP service** — an attributed local or remote MCP server, named from stored MCP attribution.
- **LLM service** — a provider recognized by `AgentCatalog.provider`, such as Anthropic, OpenAI, or Google Gemini.
- **Destination** — an exact domain/IP that is neither an LLM service nor an MCP service.

Provider nodes are a visual grouping only. Every grouped edge retains its exact hostname/IP members, counters, and filters; drill-down presents the exact members before opening Reports, Inspect, or Rules. Grouping must never silently turn one host into a provider-wide enforcement rule.

### Relationship types and wording

- **Observed traffic**: agent/tool/MCP process → service or destination. Bytes and connections come from traffic history.
- **Works for**: agent → attributed tool/MCP process. This is process-lineage evidence, not a network flow and has no byte width.
- **Invoked**: shown only when an inspected request/tool-call record proves a concrete invocation. Process lineage alone must not be labeled as an invocation or given an invocation count.

Direction colors remain separate from status colors. Received, sent, and proved invocation/lineage relationships also differ by particles, labels, or line pattern so color is never the only channel.

### Data projection

Add a purpose-built uncapped database projection rather than filtering the current app/destination result after it has discarded attribution. It must preserve:

- app bundle ID, name, and path;
- exact hostname, IP, owner, and ASN;
- `agent_parent`, `agent_parent_name`, and `mcp_server`;
- protocol/channel metadata needed by the inspector;
- `FlowCounters`;
- the same half-open `[from, to)` range and `TrafficFilter`/Focus scope as Traffic mode.

The pure AI builder can reuse `AgentCatalog` and the inclusion logic in `AgentsModel`, but produces generic graph nodes and typed relationships rather than view-specific `AgentSummary` rows.

### Status evidence

Do not derive one universal allowed/warning/blocked/inspected enum. These stores have different identities and retention:

- block/explicit-allow decisions: rule and managed-pack event stores;
- warnings: structured alerts, often app-scoped rather than destination-scoped;
- inspected HTTP: retained exchanges, excluding synthetic CONNECT pass-through rows;
- ordinary pass-through: no allow event, therefore **Observed**.

A later status overlay must expose completeness/retention and join only structured evidence over the same `[from, to)` window. It must not parse localized alert prose, subtract blocks from connection counts, or double-count a rule refusal and its generated alert.

### Stability and bounds

- Stable IDs are based on evidence identity, never rank or counters.
- Existing positions survive counter refreshes and mode-local filtering where topology permits.
- Layout recomputes only for material topology or viewport changes.
- Node frames include icon, labels, telemetry, and status footprint before collision resolution.
- Separate caps apply only to the Map projection: agents, tools/MCP nodes, services/destinations, and relationships remain complete in List.
- Map omission summaries are the exact ID-set difference from the complete semantic graph and include only omitted observed traffic in byte and connection totals.

## 0.16.7 — scalable map geometry

Map geometry is now a stable product of semantic IDs and viewport size. Counter refreshes recompute only bounded ribbon widths; node frames, ordered ports, route curves, Fit bounds, and hit-testing geometry stay fixed until topology or canvas size changes.

- Canvas width and height derive from active semantic stages, card footprint, and relationship density instead of assuming a 900-point surface.
- Alternating barycentric sweeps use normalized positions across launcher, source, tool/MCP, gateway, inspection proxy, and destination lanes to reduce avoidable crossings deterministically.
- Ribbon ports reserve topology-stable capacity. Traffic changes can widen or narrow a ribbon inside its reserved slot without shifting another relationship.
- Layout runs outside the main actor and is cached by `TrafficGraphLayoutKey`; stale cancelled work cannot replace a newer topology.
- The screen viewport is converted exactly into graph coordinates. Ribbon and particle drawing outside a padded visible region is skipped, while every card and relationship control remains available to keyboard and VoiceOver and the complete List stays unchanged.
- Fit still includes every card and relationship. After a person pans, zooms, or resets, asynchronous topology refreshes preserve that viewport until they choose Fit again. Anchored zoom round-trips between graph and screen coordinates, and Reduce Motion continues to remove particles.
- A 600-relationship benchmark guards layout cost in addition to deterministic geometry, collision, route-avoidance, crossing, hit-testing, Fit, and accessibility coverage.

### Acceptance tests

1. Known agents, attributed parents, and non-browser provider callers are included; browsers are not auto-discovered.
2. Tool and MCP rows fold into the correct agent totals while remaining selectable nodes.
3. Provider grouping preserves exact host/IP members and exact navigation filters.
4. Lineage never appears as a measured invocation without inspected invocation evidence.
5. Duplicate rows aggregate without losing received, sent, or connection totals.
6. Complete semantics retain every relationship; deterministic Map IDs are a subset, and visible plus omitted observed totals equal the full source totals.
7. List paging and counter-only refreshes leave Map IDs, node positions, and curves unchanged.
8. No feasible full-frame overlaps; hover and selection never mutate geometry.
9. Reduce Motion removes traveling particles; the list and accessibility labels retain direction and values.
10. Status overlays never classify ordinary observed traffic as an allow decision.
