#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
temporary=$(mktemp -d "${TMPDIR:-/tmp}/flowlight-pack-policy.XXXXXX")
trap 'rm -rf "$temporary"' EXIT

TZ=UTC LC_ALL=C python3 -I scripts/generate_advertising_packs.py > "$temporary/generator-utc"
TZ=Pacific/Honolulu LC_ALL=C python3 -I scripts/generate_advertising_packs.py > "$temporary/generator-honolulu"
cmp "$temporary/generator-utc" "$temporary/generator-honolulu"
python3 -I scripts/rule_pack_catalog.py validate rule-packs/official-source.json > "$temporary/valid-output"

python3 -I - rule-packs/official-source.json rule-packs/advertising/provenance.generated.json rule-packs/advertising/stable-ids.json <<'PY'
import json
import pathlib
import sys

catalog = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
provenance = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
stable = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
legacy = (
    "adnxs.com", "adservice.google.com", "adsrvr.org", "casalemedia.com", "criteo.com", "criteo.net",
    "doubleclick.net", "googleadservices.com", "googlesyndication.com", "openx.net", "pubmatic.com",
    "rubiconproject.com",
)
for entry_id, host in enumerate(legacy, 1):
    metadata = stable["entries"].get(f"{host}|suffix")
    if metadata != {"id": entry_id, "firstSeenVersion": "0.15.0"}:
        raise SystemExit(f"legacy Advertising identity {entry_id} or first-seen version moved from {host}")
protected_by_scoped_exceptions = (
    "moatads.com",
    "prebid.adnxs.com",
    "survey.g.doubleclick.net",
    "tpc.googlesyndication.com",
)
def covers(entry, host):
    return entry["host"] == host or (
        entry["match"] == "suffix" and host.endswith("." + entry["host"])
    )
for pack in catalog["payload"]["packs"]:
    if pack["manifest"]["id"] not in ("official.advertising", "official.advertising-aggressive"):
        continue
    for protected in protected_by_scoped_exceptions:
        if any(covers(entry, protected) for entry in pack["entries"]):
            raise SystemExit(f"scoped EasyList exception did not conservatively protect {protected}")
required_source_fields = {
    "attribution", "bytes", "commit", "fetchURL", "homepage", "license", "licenseURL",
    "localPath", "role", "sha256", "sourceID", "upstreamVersion",
}
if not provenance.get("sources"):
    raise SystemExit("published provenance has no pinned source metadata")
for source in provenance["sources"]:
    missing = required_source_fields - source.keys()
    if missing:
        raise SystemExit(f"published provenance source metadata is missing {sorted(missing)}")
PY

python3 -I - rule-packs/official-source.json "$temporary/unreviewed-host.json" <<'PY'
import json
import pathlib
import sys

source = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
tracking = next(pack for pack in source["payload"]["packs"] if pack["manifest"]["id"] == "official.tracking")
tracking["entries"][0]["host"] = "amplitude.com"
tracking["entries"][0]["match"] = "suffix"
pathlib.Path(sys.argv[2]).write_text(json.dumps(source, indent=2) + "\n", encoding="utf-8")
PY

if python3 -I scripts/rule_pack_catalog.py validate "$temporary/unreviewed-host.json" \
    > "$temporary/unreviewed-output" 2>&1; then
  echo "unreviewed tracking host was not rejected" >&2
  exit 1
fi
grep -Fq "is not an approved dedicated tracking endpoint: 'amplitude.com' with suffix matching" \
  "$temporary/unreviewed-output"

python3 -I - rule-packs/official-source.json "$temporary/wrong-category.json" <<'PY'
import json
import pathlib
import sys

source = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
tracking = next(pack for pack in source["payload"]["packs"] if pack["manifest"]["id"] == "official.tracking")
tracking["entries"][0]["category"] = "advertising"
pathlib.Path(sys.argv[2]).write_text(json.dumps(source, indent=2) + "\n", encoding="utf-8")
PY

if python3 -I scripts/rule_pack_catalog.py validate "$temporary/wrong-category.json" \
    > "$temporary/category-output" 2>&1; then
  echo "misclassified tracking endpoint was not rejected" >&2
  exit 1
fi
grep -Fq "category must be tracking for official.tracking" "$temporary/category-output"

python3 -I - rule-packs/official-source.json "$temporary" <<'PY'
import copy
import hashlib
import json
import pathlib
import sys

source = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
out = pathlib.Path(sys.argv[2])

def pack(value, pack_id):
    return next(item for item in value["payload"]["packs"] if item["manifest"]["id"] == pack_id)

def refresh(value, pack_id):
    selected = pack(value, pack_id)
    selected["entries"].sort(key=lambda item: f"{item['host']}|{item['match']}")
    selected["manifest"]["entryCount"] = len(selected["entries"])
    canonical = "".join(
        f"{item['id']}\t{item['host']}\t{item['match']}\t{item['category']}\n"
        for item in selected["entries"]
    ).encode()
    selected["manifest"]["contentSHA256"] = hashlib.sha256(canonical).hexdigest()

def write(name, value):
    (out / name).write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")

missing_exact = copy.deepcopy(source)
balanced = pack(missing_exact, "official.advertising")
balanced["entries"] = [item for item in balanced["entries"] if item["host"] != "platform.pubadx.one"]
refresh(missing_exact, "official.advertising")
write("missing-balanced-exact.json", missing_exact)

balanced_suffix = copy.deepcopy(source)
balanced = pack(balanced_suffix, "official.advertising")
balanced["entries"].append({"id": 4294967295, "host": "pubadx.one", "match": "suffix", "category": "advertising"})
refresh(balanced_suffix, "official.advertising")
write("balanced-pubadx-suffix.json", balanced_suffix)

missing_aggressive = copy.deepcopy(source)
aggressive = pack(missing_aggressive, "official.advertising-aggressive")
aggressive["entries"] = [item for item in aggressive["entries"] if not (item["host"] == "pubadx.one" and item["match"] == "suffix")]
refresh(missing_aggressive, "official.advertising-aggressive")
write("missing-aggressive-suffix.json", missing_aggressive)

blocked_product = copy.deepcopy(source)
balanced = pack(blocked_product, "official.advertising")
balanced["entries"].append({"id": 4294967295, "host": "pubadx.com", "match": "suffix", "category": "advertising"})
refresh(blocked_product, "official.advertising")
write("blocked-pubadx-com.json", blocked_product)

public_suffix = copy.deepcopy(source)
balanced = pack(public_suffix, "official.advertising")
balanced["entries"].append({"id": 4294967295, "host": "com", "match": "suffix", "category": "advertising"})
refresh(public_suffix, "official.advertising")
write("public-suffix.json", public_suffix)

non_superset = copy.deepcopy(source)
balanced = pack(non_superset, "official.advertising")
aggressive = pack(non_superset, "official.advertising-aggressive")
required = next(item for item in balanced["entries"] if item["match"] == "suffix" and item["host"] != "pubadx.one")
aggressive["entries"] = [
    item for item in aggressive["entries"]
    if not (item["match"] == "suffix" and (
        required["host"] == item["host"] or required["host"].endswith("." + item["host"])
    ))
]
refresh(non_superset, "official.advertising-aggressive")
write("non-superset.json", non_superset)

stable_id_mismatch = copy.deepcopy(source)
balanced = pack(stable_id_mismatch, "official.advertising")
aggressive = pack(stable_id_mismatch, "official.advertising-aggressive")
aggressive_by_key = {
    (item["host"], item["match"]): item
    for item in aggressive["entries"]
}
shared = next(
    item for item in balanced["entries"]
    if (item["host"], item["match"]) in aggressive_by_key
)
aggressive_by_key[(shared["host"], shared["match"])]["id"] = 4294967295
refresh(stable_id_mismatch, "official.advertising-aggressive")
write("stable-id-mismatch.json", stable_id_mismatch)

stable_id_reuse = copy.deepcopy(source)
balanced = pack(stable_id_reuse, "official.advertising")
aggressive = pack(stable_id_reuse, "official.advertising-aggressive")
balanced_keys = {(item["host"], item["match"]) for item in balanced["entries"]}
aggressive_keys = {(item["host"], item["match"]) for item in aggressive["entries"]}
balanced_only = next(
    item for item in balanced["entries"]
    if (item["host"], item["match"]) not in aggressive_keys
)
aggressive_only = next(
    item for item in aggressive["entries"]
    if (item["host"], item["match"]) not in balanced_keys
    and item["id"] != balanced_only["id"]
)
aggressive_only["id"] = balanced_only["id"]
refresh(stable_id_reuse, "official.advertising-aggressive")
write("stable-id-reuse.json", stable_id_reuse)
PY

assert_rejected() {
  local fixture="$1" expected="$2" label="$3"
  if python3 -I scripts/rule_pack_catalog.py validate "$fixture" > "$temporary/rejected-output" 2>&1; then
    echo "$label was not rejected" >&2
    exit 1
  fi
  grep -Fq "$expected" "$temporary/rejected-output"
}

assert_rejected "$temporary/missing-balanced-exact.json" \
  "official.advertising is missing required exact PubADX entry platform.pubadx.one" \
  "missing balanced PubADX evidence"
assert_rejected "$temporary/balanced-pubadx-suffix.json" \
  "official.advertising must not contain pubadx.one suffix coverage" \
  "balanced PubADX suffix"
assert_rejected "$temporary/missing-aggressive-suffix.json" \
  "official.advertising-aggressive must contain pubadx.one suffix coverage" \
  "missing aggressive PubADX suffix"
assert_rejected "$temporary/blocked-pubadx-com.json" \
  "official.advertising must not match pubadx.com" \
  "pubadx.com coverage"
assert_rejected "$temporary/public-suffix.json" \
  "is a public suffix or address and cannot use suffix matching" \
  "public suffix coverage"
assert_rejected "$temporary/non-superset.json" \
  "official.advertising-aggressive is not a semantic superset" \
  "non-superset aggressive tier"
assert_rejected "$temporary/stable-id-mismatch.json" \
  "advertising tiers assign different stable IDs to shared entry" \
  "cross-tier stable ID mismatch"
assert_rejected "$temporary/stable-id-reuse.json" \
  "advertising tiers reuse stable ID" \
  "cross-tier stable ID reuse"

python3 -I - scripts/generate_advertising_packs.py "$temporary/repository" <<'PY'
import copy
import hashlib
import importlib.util
import json
import pathlib
import subprocess
import sys

script = pathlib.Path(sys.argv[1])
repository = pathlib.Path(sys.argv[2]).resolve()
spec = importlib.util.spec_from_file_location("advertising_generator", script)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.ROOT = repository
module.DATA = repository / "rule-packs" / "advertising"
module.LOCK_PATH = module.DATA / "sources.lock.json"
module.POLICY_PATH = module.DATA / "policy.json"
module.STABLE_IDS_PATH = module.DATA / "stable-ids.json"
module.DATA.mkdir(parents=True)

commit = "0123456789abcdef0123456789abcdef01234567"
valid_raw = f"https://raw.githubusercontent.com/example/list/{commit}/source.txt"
valid_jsdelivr = f"https://cdn.jsdelivr.net/gh/example/list@{commit}/source.txt"
if not module.immutable_fetch_url(valid_raw, commit) or not module.immutable_fetch_url(valid_jsdelivr, commit):
    raise SystemExit("supported immutable source URL was rejected")
for invalid in (
    f"https://raw.githubusercontent.com/example/list/refs/heads/release/source.txt",
    f"https://mutable.example/{commit}/source.txt",
    f"https://raw.githubusercontent.com/example/list/{commit}/../../list/main/source.txt",
    f"https://cdn.jsdelivr.net/gh/example/list@{commit}/../list@main/source.txt",
    f"https://raw.githubusercontent.com/example/list/{commit}/%2e%2e/main/source.txt",
    f"https://raw.githubusercontent.com/example/list/{commit}/source file.txt",
    "https://[",
):
    if module.immutable_fetch_url(invalid, commit):
        raise SystemExit("mutable or untrusted source URL was accepted")

def locked_source(local, source_id, role):
    target = repository / local
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(f"pinned bytes for {local}\n".encode())
    metadata = module.REVIEWED_SOURCE_METADATA[source_id]
    return {
        "attribution": metadata["attribution"],
        "bytes": target.stat().st_size,
        "commit": commit,
        "fetchURL": (
            f"https://raw.githubusercontent.com/{metadata['repository']}/{commit}/{target.name}"
        ),
        "fetchedAt": "2026-11-15T23:59:59Z",
        "homepage": metadata["homepage"],
        "license": metadata["license"],
        "licenseURL": metadata["licenseURL"].format(commit=commit),
        "localPath": local,
        "role": role,
        "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
        "sourceID": source_id,
        "upstreamVersion": commit,
    }

candidate = locked_source(
    "rule-packs/advertising/snapshots/easylist/source.txt", "easylist", "candidate"
)
lock = {
    "cutoff": "2026-11-15T23:59:59Z",
    "format": 1,
    "generator": "scripts/generate_advertising_packs.py",
    "sources": [
        candidate,
        locked_source(
            "rule-packs/advertising/snapshots/hagezi/pro-onlydomains.txt",
            "hagezi", "corroboration",
        ),
        locked_source(
            "rule-packs/advertising/snapshots/hagezi/pro.plus-onlydomains.txt",
            "hagezi", "corroboration",
        ),
        locked_source(
            "rule-packs/advertising/snapshots/publicsuffix/public_suffix_list.dat",
            "psl", "qa",
        ),
    ],
}
module.LOCK_PATH.write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")
module.locked_inputs()

def assert_lock_rejected(mutator, expected, label):
    invalid = copy.deepcopy(lock)
    mutator(invalid)
    module.LOCK_PATH.write_text(json.dumps(invalid, indent=2) + "\n", encoding="utf-8")
    try:
        module.locked_inputs()
    except module.GenerationError as error:
        if expected not in str(error):
            raise
    else:
        raise SystemExit(f"{label} was not rejected")
    finally:
        module.LOCK_PATH.write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")

assert_lock_rejected(
    lambda value: value.__setitem__("cutoff", "2026-11-31T23:59:59Z"),
    "cutoff must be a valid UTC RFC3339 timestamp",
    "invalid audit cutoff",
)
assert_lock_rejected(
    lambda value: value["sources"][0].__setitem__("fetchedAt", "2026-11-15T23:59:59+00:00"),
    "fetchedAt must be a valid UTC RFC3339 timestamp",
    "non-Z source fetch timestamp",
)
assert_lock_rejected(
    lambda value: value["sources"][0].__setitem__("fetchedAt", "2026-11-16T00:00:00Z"),
    "fetchedAt is later than the audit cutoff",
    "post-cutoff source fetch",
)
assert_lock_rejected(
    lambda value: value["sources"][0].__setitem__("upstreamVersion", "main"),
    "upstreamVersion is not bound to its immutable commit",
    "mutable upstream version",
)
assert_lock_rejected(
    lambda value: value["sources"][0].__setitem__("homepage", "http://example.com"),
    "invalid HTTPS homepage",
    "non-HTTPS source homepage",
)
assert_lock_rejected(
    lambda value: value["sources"][0].__setitem__("licenseURL", "https://example..com/license"),
    "invalid HTTPS licenseURL",
    "invalid source license URL",
)
assert_lock_rejected(
    lambda value: value["sources"][0].__setitem__("attribution", "Unrelated vendor"),
    "attribution does not match reviewed source metadata",
    "source attribution drift",
)
assert_lock_rejected(
    lambda value: value["sources"][0].__setitem__("license", "Proprietary"),
    "license does not match reviewed source metadata",
    "source license drift",
)
assert_lock_rejected(
    lambda value: value["sources"][0].__setitem__("homepage", "https://example.com"),
    "homepage does not match reviewed source metadata",
    "source homepage drift",
)
assert_lock_rejected(
    lambda value: value["sources"][0].__setitem__("licenseURL", "https://example.com/license"),
    "licenseURL does not match reviewed source metadata",
    "source license URL drift",
)
assert_lock_rejected(
    lambda value: value["sources"][0].__setitem__(
        "fetchURL", f"https://raw.githubusercontent.com/unreviewed/list/{commit}/source.txt"
    ),
    "fetch URL uses an unreviewed upstream repository",
    "source repository drift",
)

target = repository / candidate["localPath"]
target.write_bytes(target.read_bytes() + b"\n")
try:
    module.locked_inputs()
except module.GenerationError as error:
    if "SHA-256 drifted" not in str(error) and "byte count drifted" not in str(error):
        raise
else:
    raise SystemExit("source hash drift was not rejected")
target.write_bytes(target.read_bytes()[:-1])

lock["sources"][0]["role"] = "candidates"
module.LOCK_PATH.write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")
try:
    module.locked_inputs()
except module.GenerationError as error:
    if "unsupported role 'candidates'" not in str(error):
        raise
else:
    raise SystemExit("misspelled source role was not rejected")

ledger = {
    "format": 2,
    "nextID": 100,
    "entries": {
        "legacy.example|suffix": {"id": 7, "firstSeenVersion": "0.14.5"},
    },
    "tombstones": [{
        "key": "retired.example|suffix",
        "id": 99,
        "firstSeenVersion": "0.18.4",
    }],
}
identities, next_id, tombstones = module.reconcile_stable_ledger(
    ledger,
    {"legacy.example|suffix", "retired.example|suffix", "future.example|suffix"},
    "0.18.5",
)
if identities["retired.example|suffix"] != {"id": 99, "firstSeenVersion": "0.18.4"}:
    raise SystemExit("tombstone reintroduction did not preserve identity metadata")
if identities["future.example|suffix"] != {"id": 100, "firstSeenVersion": "0.18.5"}:
    raise SystemExit("future stable identity did not receive the current first-seen version")
if next_id != 101 or tombstones:
    raise SystemExit("stable ledger reconciliation did not restore and allocate identities")

_, _, tombstones = module.reconcile_stable_ledger(
    ledger, {"legacy.example|suffix"}, "0.18.5"
)
if tombstones != [{
    "key": "retired.example|suffix", "id": 99, "firstSeenVersion": "0.18.4"
}]:
    raise SystemExit("tombstone did not preserve first-seen metadata")

bad_ledger = dict(ledger, nextID=99)
try:
    module.reconcile_stable_ledger(bad_ledger, {"future.example|suffix"}, "0.18.5")
except module.GenerationError as error:
    if "reserve every entry and tombstone ID" not in str(error):
        raise
else:
    raise SystemExit("tombstone-only high ID was available for reuse")

bad_metadata = {
    "format": 2,
    "nextID": 2,
    "entries": {"bad.example|suffix": {"id": 1}},
    "tombstones": [],
}
try:
    module.reconcile_stable_ledger(bad_metadata, {"bad.example|suffix"}, "0.18.5")
except module.GenerationError as error:
    if "exactly id and firstSeenVersion" not in str(error):
        raise
else:
    raise SystemExit("missing stable first-seen metadata was not rejected")

publication = repository / "site/packs/v1/provenance"
publication.mkdir(parents=True)
(publication / "current.json").write_bytes(b"current")
(publication / "nested").mkdir()
(publication / "nested/extra.bin").write_bytes(b"extra")
if module.publication_files(publication) != {"current.json", "nested/extra.bin"}:
    raise SystemExit("nested provenance publication extras were not detected")
if module.stale_publication_paths(publication, "current.json") != [publication / "nested/extra.bin"]:
    raise SystemExit("stale provenance paths were not reported exactly")

exit_repository = repository / "exit-status"
site_publication = exit_repository / "site/packs/v1/provenance"
docs_publication = exit_repository / "docs/packs/v1/provenance"
site_publication.mkdir(parents=True)
docs_publication.mkdir(parents=True)
(site_publication / "old-site.json").write_bytes(b"site transition")
(docs_publication / "old-docs.json").write_bytes(b"docs transition")
driver = r'''\
import importlib.util
import pathlib
import sys

script = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("advertising_generator_exit_fixture", script)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.ROOT = root
module.OUTPUTS = {}
publish_path = root / "site/packs/v1/provenance/current.json"
module.build = lambda: ({
    "provenance_publish": b"current provenance",
    "provenance_publish_path": publish_path,
}, {
    "balancedEntries": 1,
    "aggressiveEntries": 1,
    "sourceCount": 1,
})
sys.argv = [str(script), "--write"]
raise SystemExit(module.main())
'''
result = subprocess.run(
    [sys.executable, "-I", "-c", driver, str(script), str(exit_repository)],
    capture_output=True,
    text=True,
    timeout=30,
)
if result.returncode != 1:
    raise SystemExit(f"stale --write fixture exited {result.returncode}, expected 1")
for relative in (
    "site/packs/v1/provenance/old-site.json",
    "docs/packs/v1/provenance/old-docs.json",
):
    warning = (
        "stale generated provenance; remove explicitly after catalog publication: " + relative
    )
    if warning not in result.stderr:
        raise SystemExit(f"stale --write fixture omitted warning for {relative}")
if "stale generated provenance paths remain" not in result.stderr:
    raise SystemExit("stale --write fixture omitted its failure reason")
if (site_publication / "old-site.json").read_bytes() != b"site transition":
    raise SystemExit("stale --write fixture removed the site transitional file")
if (docs_publication / "old-docs.json").read_bytes() != b"docs transition":
    raise SystemExit("stale --write fixture removed the docs transitional file")
if (site_publication / "current.json").read_bytes() != b"current provenance":
    raise SystemExit("stale --write fixture did not write the current provenance")

class AcceptingPSL:
    @staticmethod
    def allows_suffix(_host):
        return True

try:
    module.validate_manual_entry(
        {"host": "google.com", "match": "suffix", "evidence": "negative fixture"},
        "balanced", AcceptingPSL(), {"google.com", "com"},
    )
except module.GenerationError as error:
    if "intersects a protected host" not in str(error):
        raise
else:
    raise SystemExit("manual protected-host entry was not rejected")
PY

echo "Rule-pack policy fixtures passed: immutable inputs, scoped exceptions, protected hosts, PSL boundaries, PubADX scope, tier superset, and reviewed collectors are enforced."
