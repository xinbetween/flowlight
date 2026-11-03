# Traffic visualization — 0.16.x

Flowlight 0.16.x introduces one native visualization shell with two evidence-preserving modes. Both modes use the same system-adaptive canvas, deterministic layout, inspector, exact drill-down actions, and accessible list.

## 0.16.0 — Traffic

Traffic mode answers: **which applications moved traffic, and where did it go?**

- Every observed application is an app node with its native icon and name.
- Every exact `(hostname, IP address)` is a destination node. Hostname-less traffic keeps its owner/address identity.
- Curved path width represents total bytes.
- Sparse moving dashes represent sent and received direction. Every edge has a distinct deterministic speed, both directions on one edge share its magnitude and move oppositely, and Reduce Motion removes animation.
- Values are bytes and network connections (`FlowCounters.flows`), never mislabeled as HTTP requests.
- Ordinary traffic is **Observed**, not “Allowed.” A status badge appears only when a store provides matching structured evidence.
- The semantic graph retains every relationship in the selected search and Focus scope. When an exact Map would be too dense, deterministic visible groups retain every member node and relationship ID; selecting a group reveals its exact chart items without changing totals. Search and Focus build an exact scoped Map, including low-volume applications and destinations. The independently paged List reveals the same complete graph 25 relationships at a time.
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

Direction colors remain separate from status colors. Received, sent, and proved invocation/lineage relationships also differ by moving dashes, labels, or line pattern so color is never the only channel.

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
- Map grouping is deterministic and presentation-only: a collapsed node or relationship stores the exact IDs it represents, while complete accounting remains unchanged.
- Expanding and collapsing groups may change geometry only. Exact membership, received bytes, sent bytes, and connection totals must remain identical to Reports for the same range, search, and Focus scope.

## 0.16.7 — scalable map geometry

Map geometry is now a stable product of semantic IDs and viewport size. Counter refreshes recompute only bounded ribbon widths; node frames, ordered ports, route curves, Fit bounds, and hit-testing geometry stay fixed until topology or canvas size changes.

- Canvas width and height derive from active semantic stages, card footprint, and relationship density instead of assuming a 900-point surface.
- Alternating barycentric sweeps use normalized positions across launcher, source, tool/MCP, gateway, inspection proxy, and destination lanes to reduce avoidable crossings deterministically.
- Ribbon ports reserve topology-stable capacity. Traffic changes can widen or narrow a ribbon inside its reserved slot without shifting another relationship.
- Layout runs outside the main actor and is cached by `TrafficGraphLayoutKey`; stale cancelled work cannot replace a newer topology.
- The screen viewport is converted exactly into graph coordinates. Ribbon and moving-dash drawing outside a padded visible region is skipped, while every card and relationship control remains available to keyboard and VoiceOver and the complete List stays unchanged.
- Fit still includes every card and relationship. After a person pans, zooms, or resets, asynchronous topology refreshes preserve that viewport until they choose Fit again. Anchored zoom round-trips between graph and screen coordinates, and Reduce Motion continues to remove moving dashes.
- A 600-relationship benchmark guards layout cost in addition to deterministic geometry, collision, route-avoidance, crossing, hit-testing, Fit, and accessibility coverage.

## 0.16.9 — complete expandable maps

Traffic and AI Maps no longer discard exact evidence behind a fixed top-N boundary. Dense stages collapse into deterministic alphabetical groups that state how many exact items they contain. Selecting a group expands its exact nodes and relationships; **Collapse groups** restores the stable overview. Search and Focus reveal exact matching chart items directly, even when their traffic volume is low.

Reports and Visualize now share an explicit parity contract for the same half-open time range and scope: raw application identity, exact destination identity, canonical observed relationships, received bytes, sent bytes, and connection counts must reconcile exactly. Collapsing or expanding groups cannot alter any of those values.

Every relationship uses the same smooth cubic curve family. Direction is drawn with sparse border-aligned dashes whose speed is unique per edge but stable across refreshes and launches; received and sent motion on one edge has equal magnitude and opposite direction. Swift's randomized `Hasher` is deliberately not part of the identity or animation contract.

## 0.16.10 — ranked overview and endpoint focus

The default Map is a bounded overview rather than a picture of the entire topology. Traffic mode selects the ten application roots with the greatest aggregate received-plus-sent traffic. AI activity selects the ten proved agent roots with the greatest aggregate traffic across the root and its attributed child processes. Equal totals use stable semantic node IDs as the tie-break, matching the ranking contract used by Reports and AI Agents.

Two searchable optional selectors narrow the evidence by source application or AI agent and by exact destination. They support any source to any destination, one source to any destination, any source to one destination, and one source to one destination. Each selection filters the opposite selector to endpoints with observed or blocked evidence, while Any remains available; Reset returns both selectors to Any. A focused Map carries every connected semantic dependency required to explain the selected observed or blocked relationships, including launcher, lineage, tool/MCP, configured gateway, observed route, Flowlight proxy, and destination stages.

A small focused neighborhood is shown exactly. A large one groups progressively only after the focused evidence exceeds the Map bounds, and every group retains its exact represented node and relationship IDs. The complete scoped snapshot still backs List and Reports, so every relationship remains searchable and exact totals never depend on what the Map can draw comfortably.

### Acceptance tests

1. Known agents, attributed parents, and non-browser provider callers are included; browsers are not auto-discovered.
2. Tool and MCP rows fold into the correct agent totals while remaining selectable nodes.
3. Provider grouping preserves exact host/IP members and exact navigation filters.
4. Lineage never appears as a measured invocation without inspected invocation evidence.
5. Duplicate rows aggregate without losing received, sent, or connection totals.
6. Complete semantics retain every relationship; deterministic collapsed groups retain exact member node and relationship IDs, and expansion leaves source totals unchanged.
7. List paging, counter-only refreshes, and unrelated group expansion leave surviving Map IDs and membership stable.
8. No feasible full-frame overlaps; hover and selection never mutate geometry.
9. Reduce Motion removes moving dashes; the list and accessibility labels retain direction and values.
10. Status overlays never classify ordinary observed traffic as an allow decision.
