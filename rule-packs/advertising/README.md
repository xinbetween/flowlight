# Advertising pack source bundle

This directory is the preferred, editable source for Flowlight's generated Advertising packs. It is reviewed data, not runtime input: released apps obtain updates only from Flowlight's signed official catalog and never fetch EasyList, HaGeZi, the Public Suffix List, or raw GitHub files directly. Every release bundles the exact signed catalog, and accepted updates remain available as a verified last-known-good cache, so a source-host or feed outage delays updates without removing active enforcement or leaving a fresh install empty.

## Pinned inputs

The bundle was last modified on 2026-11-15 and is bound byte-for-byte by `sources.lock.json`.

- EasyList and EasyPrivacy: `easylist/easylist` commit `0fd01f73f94db975f4ce922c2771069289616294`, attributed to the EasyList authors, under GPL-3.0-or-later for this redistribution route.
- HaGeZi Multi PRO and Multi PRO++: `hagezi/dns-blocklists` commit `b4ad77c48a0a185dbfacb86c97950bc3f77963e5`, attributed to HaGeZi, under GPL-3.0.
- Public Suffix List: `publicsuffix/list` commit `fd22c6c8b3fd7e854c1eff2194cfd4ebc9854b88`, attributed to Public Suffix List contributors, under MPL-2.0.

The corresponding license texts and upstream notices are retained under `licenses/` and `notices/`. Raw immutable snapshots are under `snapshots/`. The lock records each source URL, role, revision, byte count, and SHA-256 digest.

## Derivation policy

`scripts/generate_advertising_packs.py` is deterministic and offline. It verifies every locked byte before parsing and accepts only hostname semantics Flowlight can enforce:

- optionless Adblock Plus network rules in the form `||hostname^`;
- canonical hostname exceptions, with scoped ABP exceptions conservatively excluding the host globally because Flowlight cannot preserve request-type or domain scope;
- plain HaGeZi domains used as corroboration, not as a wholesale Advertising import;
- EasyPrivacy retained as tracking/QA evidence and never reclassified wholesale as Advertising;
- Public Suffix List exact, wildcard, and exception rules used to reject unsafe suffix entries.

Cosmetic filters, scriptlets, paths, regular expressions, redirects, CSP rules, block-rule request options, and unknown syntax are not reinterpreted. `policy.json` records protected product surfaces, reviewed exceptions, and manual evidence. `stable-ids.json` preserves entry identities and tombstones; an ID is never reassigned to a different destination.

The generated tiers are mutually exclusive:

- **Advertising** is the recommended balanced tier.
- **Advertising — Aggressive** is an opt-in semantic superset with higher breakage risk.

Hostname blocking cannot remove same-origin ads, page-layout gaps, or browser/app overlays. Product, login, dashboard, and shared media hosts remain reachable unless a dedicated advertising hostname has independent evidence.

## PubADX boundary

The reviewed evidence supports exact balanced entries for `platform.pubadx.one` and `imp9.pubadx.one`, and an aggressive suffix entry for `pubadx.one`. `pubadx.com` is deliberately not covered. This repository makes no ownership, affiliation, or technical-linkage claim between `pubadx.one` and `pubadx.com`.

## Reproduce and review

Run from the repository root:

```sh
python3 -I scripts/generate_advertising_packs.py
scripts/test-rule-pack-policy.sh
python3 -I scripts/rule_pack_catalog.py validate rule-packs/official-source.json
```

The generator's check mode byte-compares the committed outputs. Use `--write` only after reviewing source-lock changes and policy changes. Generated review material includes:

- `catalog-packs.generated.json`
- `provenance.generated.json`
- `public-suffix-rules.generated.json`
- `report.generated.json`
- `Shared/PublicSuffixRules.generated.swift`
- the Advertising definitions in `rule-packs/official-source.json`

`provenance.generated.json` is published at the content-addressed URL recorded in each Advertising manifest. The official catalog must remain unsigned until source, policy, localization, tests, and generated output are final. Signing uses the separate offline release procedure documented in `docs/DEVELOPMENT.md`; the private key is never stored here or in CI.
