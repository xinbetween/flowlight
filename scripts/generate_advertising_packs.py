#!/usr/bin/env python3
"""Derive Flowlight's host-only Advertising tiers from immutable vendored snapshots.

This generator never fetches the network. `sources.lock.json` binds every input byte;
runtime clients receive only Flowlight's separately signed official catalog.
"""

import argparse
import datetime
import hashlib
import ipaddress
import json
import pathlib
import re
import sys
from collections import defaultdict
from urllib.parse import urlsplit

ROOT = pathlib.Path(__file__).resolve().parent.parent
DATA = ROOT / "rule-packs" / "advertising"
LOCK_PATH = DATA / "sources.lock.json"
POLICY_PATH = DATA / "policy.json"
STABLE_IDS_PATH = DATA / "stable-ids.json"
OUTPUTS = {
    "stable_ids": STABLE_IDS_PATH,
    "official_source": ROOT / "rule-packs" / "official-source.json",
    "packs": DATA / "catalog-packs.generated.json",
    "provenance": DATA / "provenance.generated.json",
    "report": DATA / "report.generated.json",
    "psl_json": DATA / "public-suffix-rules.generated.json",
    "psl_swift": ROOT / "Shared" / "PublicSuffixRules.generated.swift",
}
COMMIT = re.compile(r"[0-9a-f]{40}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
UTC_RFC3339 = re.compile(
    r"[0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])"
    r"T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]+)?Z\Z"
)
ABP_BLOCK = re.compile(r"\|\|([A-Za-z0-9._-]+)\^")
ABP_ALLOW = re.compile(r"@@\|\|([A-Za-z0-9._-]+)\^")
ABP_SCOPED_ALLOW = re.compile(r"@@\|\|([A-Za-z0-9._-]+)\^\$.+")
LOCK_FIELDS = {"cutoff", "format", "generator", "sources"}
SOURCE_FIELDS = {
    "attribution", "bytes", "commit", "fetchURL", "fetchedAt", "homepage", "license",
    "licenseURL", "localPath", "role", "sha256", "sourceID", "upstreamVersion",
}
SOURCE_ROLES = {"candidate", "corroboration", "qa"}
CORROBORATION_PATHS = {
    "rule-packs/advertising/snapshots/hagezi/pro-onlydomains.txt",
    "rule-packs/advertising/snapshots/hagezi/pro.plus-onlydomains.txt",
}
FIXED_SOURCE_CLASSIFICATIONS = {
    "rule-packs/advertising/licenses/EasyList-COPYING.rst": ("easylist_license", "qa"),
    "rule-packs/advertising/licenses/HaGeZi-GPL-3.0.txt": ("hagezi", "qa"),
    "rule-packs/advertising/licenses/Public-Suffix-List-MPL-2.0.txt": ("psl", "qa"),
    "rule-packs/advertising/notices/EasyList-README.md": ("easylist", "qa"),
    "rule-packs/advertising/notices/HaGeZi-README.md": ("hagezi", "qa"),
    "rule-packs/advertising/notices/HaGeZi-sources.md": ("hagezi", "qa"),
    "rule-packs/advertising/snapshots/hagezi/pro-onlydomains.txt": ("hagezi", "corroboration"),
    "rule-packs/advertising/snapshots/hagezi/pro.plus-onlydomains.txt": ("hagezi", "corroboration"),
    "rule-packs/advertising/snapshots/publicsuffix/public_suffix_list.dat": ("psl", "qa"),
}
REVIEWED_SOURCE_METADATA = {
    "easylist": {
        "attribution": "The EasyList authors (https://easylist.to/)",
        "homepage": "https://github.com/easylist/easylist",
        "license": "GPL-3.0-or-later",
        "licenseURL": "https://easylist.to/pages/licence.html",
        "repository": "easylist/easylist",
    },
    "easylist_license": {
        "attribution": "easylist_license",
        "homepage": "https://easylist.to/",
        "license": "GPL-3.0-or-later",
        "licenseURL": "https://easylist.to/pages/licence.html",
        "repository": "easylist/easylist.github.io",
    },
    "hagezi": {
        "attribution": "HaGeZi DNS Blocklists, created and maintained by HaGeZi",
        "homepage": "https://github.com/hagezi/dns-blocklists",
        "license": "GPL-3.0",
        "licenseURL": "https://github.com/hagezi/dns-blocklists/blob/{commit}/LICENSE",
        "repository": "hagezi/dns-blocklists",
    },
    "psl": {
        "attribution": "Public Suffix List contributors",
        "homepage": "https://github.com/publicsuffix/list",
        "license": "MPL-2.0",
        "licenseURL": "https://github.com/publicsuffix/list/blob/{commit}/LICENSE",
        "repository": "publicsuffix/list",
    },
}
# IDs 1–12 landed in e2ade193 after v0.14.5 and first shipped in v0.15.0.
LEGACY_FIRST_SEEN_VERSION = "0.15.0"


class GenerationError(ValueError):
    pass


def fail(message):
    raise GenerationError(message)


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def load_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"cannot load {path.relative_to(ROOT)}: {error}")


def immutable_fetch_repository(value, commit):
    if (not isinstance(value, str) or not value
            or any(character.isspace() for character in value)):
        return None
    try:
        parsed = urlsplit(value)
    except ValueError:
        return None
    raw_parts = parsed.path.split("/")
    if (parsed.scheme != "https" or parsed.query or parsed.fragment
            or not parsed.path.startswith("/") or "%" in parsed.path or "\\" in parsed.path
            or any(part in ("", ".", "..") for part in raw_parts[1:])):
        return None
    parts = raw_parts[1:]
    if parsed.netloc == "raw.githubusercontent.com" and len(parts) >= 4 and parts[2] == commit:
        return f"{parts[0]}/{parts[1]}"
    if (parsed.netloc == "cdn.jsdelivr.net" and len(parts) >= 4 and parts[0] == "gh"
            and "@" in parts[2] and parts[2].rsplit("@", 1)[1] == commit):
        return f"{parts[1]}/{parts[2].rsplit('@', 1)[0]}"
    return None


def immutable_fetch_url(value, commit):
    return immutable_fetch_repository(value, commit) is not None


def utc_rfc3339(value, where):
    if not isinstance(value, str) or not UTC_RFC3339.fullmatch(value):
        fail(f"{where} must be a valid UTC RFC3339 timestamp")
    try:
        return datetime.datetime.fromisoformat(value.removesuffix("Z") + "+00:00")
    except ValueError:
        fail(f"{where} must be a valid UTC RFC3339 timestamp")


def https_audit_url(value):
    if not isinstance(value, str) or not value or any(character.isspace() for character in value):
        return False
    try:
        parsed = urlsplit(value)
        hostname = parsed.hostname
        parsed.port
    except ValueError:
        return False
    if (parsed.scheme != "https" or not parsed.netloc or hostname is None
            or parsed.username is not None or parsed.password is not None
            or "\\" in value):
        return False
    try:
        ipaddress.ip_address(hostname)
    except ValueError:
        try:
            ascii_hostname = hostname.encode("idna").decode("ascii")
        except UnicodeError:
            return False
        labels = ascii_hostname.split(".")
        if (len(ascii_hostname) > 253
                or any(not label or len(label) > 63
                       or label.startswith("-") or label.endswith("-")
                       or re.fullmatch(r"[A-Za-z0-9-]+", label) is None
                       for label in labels)):
            return False
    return True


def locked_inputs():
    lock = load_json(LOCK_PATH)
    if (
        not isinstance(lock, dict)
        or set(lock) != LOCK_FIELDS
        or lock.get("format") != 1
        or lock.get("generator") != "scripts/generate_advertising_packs.py"
        or not isinstance(lock.get("cutoff"), str)
        or not isinstance(lock.get("sources"), list)
    ):
        fail("sources.lock.json has an unsupported format")
    cutoff = utc_rfc3339(lock["cutoff"], "sources.lock.json cutoff")
    seen = set()
    result = []
    for index, item in enumerate(lock["sources"]):
        where = f"sources.lock.json source {index}"
        if not isinstance(item, dict):
            fail(f"{where} must be an object")
        missing = SOURCE_FIELDS - set(item)
        extra = set(item) - SOURCE_FIELDS
        if missing or extra:
            fail(f"{where} has invalid fields (missing {sorted(missing)}, extra {sorted(extra)})")
        for field in SOURCE_FIELDS - {"bytes"}:
            if not isinstance(item[field], str) or not item[field]:
                fail(f"{where} has invalid {field}")
        if isinstance(item["bytes"], bool) or not isinstance(item["bytes"], int) or item["bytes"] < 0:
            fail(f"{where} has invalid bytes")
        if not SHA256.fullmatch(item["sha256"]):
            fail(f"{where} has invalid sha256")
        local = item.get("localPath")
        commit = item.get("commit")
        fetch_url = item.get("fetchURL")
        source_id = item.get("sourceID")
        role = item.get("role")
        if not isinstance(local, str) or not local.startswith("rule-packs/advertising/"):
            fail(f"{where} has an invalid localPath")
        if local in seen:
            fail(f"{where} duplicates {local}")
        seen.add(local)
        if not isinstance(commit, str) or not COMMIT.fullmatch(commit):
            fail(f"{where} is not pinned to an immutable commit")
        fetched_at = utc_rfc3339(item["fetchedAt"], f"{where} fetchedAt")
        if fetched_at > cutoff:
            fail(f"{where} fetchedAt is later than the audit cutoff")
        if item["upstreamVersion"] != commit:
            fail(f"{where} upstreamVersion is not bound to its immutable commit")
        for field in ("homepage", "licenseURL"):
            if not https_audit_url(item[field]):
                fail(f"{where} has an invalid HTTPS {field}")
        if role not in SOURCE_ROLES:
            fail(f"{where} has unsupported role {role!r}")
        if not isinstance(source_id, str) or not source_id:
            fail(f"{where} has an invalid sourceID")
        expected_classification = FIXED_SOURCE_CLASSIFICATIONS.get(local)
        easylist_prefix = "rule-packs/advertising/snapshots/easylist/"
        if expected_classification is None and local.startswith(easylist_prefix):
            relative = local.removeprefix(easylist_prefix)
            expected_classification = (
                "easylist", "qa" if relative.startswith("easyprivacy") else "candidate"
            )
        if expected_classification != (source_id, role):
            fail(f"{where} has an invalid source/role/path combination")
        reviewed_metadata = REVIEWED_SOURCE_METADATA.get(source_id)
        if reviewed_metadata is None:
            fail(f"{where} has no reviewed source metadata")
        for field in ("attribution", "homepage", "license", "licenseURL"):
            expected = reviewed_metadata[field].format(commit=commit)
            if item[field] != expected:
                fail(f"{where} {field} does not match reviewed source metadata")
        repository = immutable_fetch_repository(fetch_url, commit)
        if repository is None:
            fail(f"{where} fetch URL is not bound to its immutable commit")
        if repository != reviewed_metadata["repository"]:
            fail(f"{where} fetch URL uses an unreviewed upstream repository")
        path = (ROOT / local).resolve()
        try:
            path.relative_to(ROOT)
        except ValueError:
            fail(f"{where} escapes the repository")
        try:
            data = path.read_bytes()
        except OSError as error:
            fail(f"{where} cannot read {local}: {error}")
        if item.get("bytes") != len(data):
            fail(f"{where} byte count drifted for {local}")
        if item.get("sha256") != sha256(data):
            fail(f"{where} SHA-256 drifted for {local}")
        result.append((item, path, data))
    candidates = [item for item, _, _ in result if item["role"] == "candidate"]
    corroboration = {item["localPath"] for item, _, _ in result if item["role"] == "corroboration"}
    psl_inputs = [
        item for item, _, _ in result
        if item["sourceID"] == "psl" and item["localPath"].endswith("/public_suffix_list.dat")
    ]
    if not candidates:
        fail("sources.lock.json has no candidate inputs")
    if corroboration != CORROBORATION_PATHS:
        fail("sources.lock.json does not contain exactly the two required HaGeZi corroboration inputs")
    if len(psl_inputs) != 1 or psl_inputs[0]["role"] != "qa":
        fail("sources.lock.json must contain exactly one qa Public Suffix List data input")
    return lock, result


def stable_record(where, key, value, legacy_format=False, current_version=None):
    if legacy_format:
        if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
            fail(f"{where} {key!r} has invalid legacy metadata")
        return {
            "id": value,
            "firstSeenVersion": LEGACY_FIRST_SEEN_VERSION if value <= 12 else current_version,
        }
    if not isinstance(value, dict) or set(value) != {"id", "firstSeenVersion"}:
        fail(f"{where} {key!r} must contain exactly id and firstSeenVersion")
    if isinstance(value["id"], bool) or not isinstance(value["id"], int) or value["id"] <= 0:
        fail(f"{where} {key!r} has an invalid ID")
    if not isinstance(value["firstSeenVersion"], str) or not VERSION.fullmatch(value["firstSeenVersion"]):
        fail(f"{where} {key!r} has an invalid firstSeenVersion")
    return dict(value)


def reconcile_stable_ledger(stable, all_keys, current_version):
    if not isinstance(current_version, str) or not VERSION.fullmatch(current_version):
        fail("policy minimumAppVersion is not a semantic version")
    if not isinstance(stable, dict):
        fail("stable ID format is unsupported")
    stable_format = stable.get("format")
    if stable_format not in (1, 2) or not isinstance(stable.get("entries"), dict):
        fail("stable ID format is unsupported")
    if not isinstance(stable.get("tombstones"), list):
        fail("stable ID tombstones must be an array")

    identities = {}
    id_to_key = {}

    def retain(where, key, record):
        if not isinstance(key, str) or key.count("|") != 1:
            fail(f"{where} has an invalid key {key!r}")
        previous = identities.get(key)
        if previous is not None and previous != record:
            fail(f"{where} conflicts with stable metadata for {key}")
        previous_key = id_to_key.get(record["id"])
        if previous_key is not None and previous_key != key:
            fail(f"stable ID {record['id']} is assigned to both {previous_key} and {key}")
        identities[key] = record
        id_to_key[record["id"]] = key

    for key, value in stable["entries"].items():
        retain(
            "stable entry",
            key,
            stable_record("stable entry", key, value, stable_format == 1, current_version),
        )
    seen_tombstones = set()
    for index, item in enumerate(stable["tombstones"]):
        where = f"stable tombstone {index}"
        if not isinstance(item, dict) or set(item) != {"key", "id", "firstSeenVersion"}:
            if stable_format == 1 and isinstance(item, dict) and set(item) == {"key", "id"}:
                item = {
                    **item,
                    "firstSeenVersion": (
                        LEGACY_FIRST_SEEN_VERSION if item.get("id", 0) <= 12 else current_version
                    ),
                }
            else:
                fail(f"{where} must contain exactly key, id, and firstSeenVersion")
        key = item["key"]
        if key in seen_tombstones:
            fail(f"stable tombstones duplicate {key}")
        seen_tombstones.add(key)
        retain(
            where,
            key,
            stable_record(where, key, {"id": item["id"], "firstSeenVersion": item["firstSeenVersion"]}),
        )

    next_id = stable.get("nextID")
    if isinstance(next_id, bool) or not isinstance(next_id, int) or next_id <= max(id_to_key, default=0):
        fail("stable nextID does not reserve every entry and tombstone ID")
    for key in sorted(all_keys):
        if key not in identities:
            identities[key] = {"id": next_id, "firstSeenVersion": current_version}
            id_to_key[next_id] = key
            next_id += 1

    tombstones = [
        {"key": key, **record}
        for key, record in identities.items()
        if key not in all_keys
    ]
    return identities, next_id, sorted(tombstones, key=lambda item: item["id"])


def canonical_host(value):
    value = value.strip().lower()
    if value.endswith("."):
        value = value[:-1]
    if not value or value.startswith("["):
        return None
    try:
        ipaddress.ip_address(value)
        return None
    except ValueError:
        pass
    try:
        value = value.encode("idna").decode("ascii")
    except (UnicodeError, ValueError):
        return None
    if len(value.encode("ascii")) > 253:
        return None
    labels = value.split(".")
    if any(
        not label or len(label) > 63 or label.startswith("-") or label.endswith("-")
        or re.fullmatch(r"[a-z0-9-]+", label) is None
        for label in labels
    ):
        return None
    return value


def suffixes(host):
    labels = host.split(".")
    return [".".join(labels[index:]) for index in range(len(labels))]


def descendant_ancestors(hosts):
    result = set()
    for host in hosts:
        result.update(suffixes(host))
    return result


def intersects(host, values, ancestors):
    return any(candidate in values for candidate in suffixes(host)) or host in ancestors


class PublicSuffixList:
    def __init__(self, exact, wildcard, exception):
        self.exact = frozenset(exact)
        self.wildcard = frozenset(wildcard)
        self.exception = frozenset(exception)

    @classmethod
    def parse(cls, data):
        exact = set()
        wildcard = set()
        exception = set()
        for number, raw in enumerate(data.decode("utf-8").splitlines(), 1):
            rule = raw.strip()
            if not rule or rule.startswith("//"):
                continue
            target = exception if rule.startswith("!") else wildcard if rule.startswith("*.") else exact
            if rule.startswith("!"):
                rule = rule[1:]
            elif rule.startswith("*."):
                rule = rule[2:]
            canonical = canonical_host(rule)
            if canonical is None:
                fail(f"public suffix rule {number} is not a canonical hostname: {rule!r}")
            target.add(canonical)
        return cls(exact, wildcard, exception)

    def public_suffix(self, host):
        labels = host.split(".")
        exceptions = [value for value in suffixes(host) if value in self.exception]
        if exceptions:
            rule = max(exceptions, key=lambda value: len(value.split(".")))
            parts = rule.split(".")
            return ".".join(parts[1:])
        best_count = 1
        for index in range(len(labels)):
            candidate = ".".join(labels[index:])
            if candidate in self.exact:
                best_count = max(best_count, len(labels) - index)
            if index > 0 and candidate in self.wildcard:
                best_count = max(best_count, len(labels) - index + 1)
        return ".".join(labels[-best_count:])

    def allows_suffix(self, host):
        canonical = canonical_host(host)
        return canonical == host and self.public_suffix(host) != host

    def generated_json(self):
        return {
            "format": 1,
            "exact": sorted(self.exact),
            "wildcard": sorted(self.wildcard),
            "exception": sorted(self.exception),
        }


def parse_easylist(inputs):
    candidates = defaultdict(list)
    exceptions = defaultdict(list)
    counts = defaultdict(int)
    candidate_files = [
        (item, path, data) for item, path, data in inputs
        if item.get("sourceID") == "easylist" and item.get("role") == "candidate"
    ]
    for item, path, data in candidate_files:
        relative = item["localPath"]
        for number, raw in enumerate(data.decode("utf-8").splitlines(), 1):
            line = raw.strip()
            if not line or line.startswith("!") or line.startswith("[") or line.startswith("%include "):
                counts["metadata"] += 1
                continue
            allow = ABP_ALLOW.fullmatch(line)
            scoped_allow = ABP_SCOPED_ALLOW.fullmatch(line)
            block = ABP_BLOCK.fullmatch(line)
            if allow or scoped_allow or block:
                host = canonical_host((allow or scoped_allow or block).group(1))
                if host is None:
                    counts["invalidHost"] += 1
                    continue
                reference = {"path": relative, "line": number, "rule": line}
                is_exception = allow is not None or scoped_allow is not None
                (exceptions if is_exception else candidates)[host].append(reference)
                counts["exceptions" if is_exception else "candidates"] += 1
                if scoped_allow is not None:
                    # A host-only blocker cannot preserve ABP request-type or domain scope. Excluding the
                    # destination globally is narrower and safer than turning a scoped allow into breakage.
                    counts["scopedExceptions"] += 1
            elif line.startswith("||") or line.startswith("@@||"):
                counts["unsupportedNetwork"] += 1
            else:
                counts["unsupportedOther"] += 1
    return candidates, exceptions, dict(sorted(counts.items()))


def parse_plain_domains(data, where):
    result = set()
    for number, raw in enumerate(data.decode("utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        host = canonical_host(line)
        if host is None:
            fail(f"{where}:{number} is not a canonical host-only entry")
        result.add(host)
    return result


def covered_by(host, suffix_set):
    return any(value in suffix_set for value in suffixes(host))


def minimized_suffixes(hosts):
    accepted = set()
    for host in sorted(hosts, key=lambda value: (len(value.split(".")), value)):
        if not covered_by(host, accepted):
            accepted.add(host)
    return accepted


def semantic_covers(candidate, required):
    candidate_host, candidate_match = candidate.split("|", 1)
    required_host, required_match = required.split("|", 1)
    if candidate_match == "exact":
        return required_match == "exact" and candidate_host == required_host
    if required_match == "exact":
        return required_host == candidate_host or required_host.endswith("." + candidate_host)
    return required_host == candidate_host or required_host.endswith("." + candidate_host)


def psl_swift(psl):
    def text(values):
        return "\n".join(sorted(values))
    return f'''// Generated by scripts/generate_advertising_packs.py. Do not edit.
import Foundation

private let flowlightPublicSuffixExact = """
{text(psl.exact)}
"""
private let flowlightPublicSuffixWildcard = """
{text(psl.wildcard)}
"""
private let flowlightPublicSuffixException = """
{text(psl.exception)}
"""

enum PublicSuffixRules {{
    private static let exact = Set(flowlightPublicSuffixExact.split(separator: "\\n").map(String.init))
    private static let wildcard = Set(flowlightPublicSuffixWildcard.split(separator: "\\n").map(String.init))
    private static let exception = Set(flowlightPublicSuffixException.split(separator: "\\n").map(String.init))

    static func allowsSuffixEntry(_ value: String) -> Bool {{
        guard let host = HostCanonicalizer.canonicalHost(value), host.value == value else {{ return false }}
        return allowsSuffixEntry(canonicalHost: host)
    }}

    static func allowsSuffixEntry(canonicalHost host: HostCanonicalizer.CanonicalHost) -> Bool {{
        let value = host.value
        guard !value.contains(":"),
              !value.split(separator: ".").allSatisfy({{ Int($0) != nil }}) else {{ return false }}
        return publicSuffix(value) != value
    }}

    static func registrableDomain(_ value: String) -> String? {{
        guard let host = HostCanonicalizer.canonicalHost(value) else {{ return nil }}
        return registrableDomain(canonicalHost: host)
    }}

    static func registrableDomain(canonicalHost host: HostCanonicalizer.CanonicalHost) -> String? {{
        let value = host.value
        guard !value.contains(":"),
              !value.split(separator: ".").allSatisfy({{ Int($0) != nil }}) else {{ return nil }}
        let labels = value.split(separator: ".").map(String.init)
        let suffixLabels = publicSuffix(value).split(separator: ".").count
        guard labels.count > suffixLabels else {{ return nil }}
        return labels.suffix(suffixLabels + 1).joined(separator: ".")
    }}

    private static func publicSuffix(_ host: String) -> String {{
        let labels = host.split(separator: ".").map(String.init)
        var exceptionRule: String?
        var bestRuleLabels = 1
        for index in labels.indices {{
            let candidate = labels[index...].joined(separator: ".")
            if exception.contains(candidate),
               candidate.split(separator: ".").count > (exceptionRule?.split(separator: ".").count ?? 0) {{
                exceptionRule = candidate
            }}
            if exact.contains(candidate) {{
                bestRuleLabels = max(bestRuleLabels, labels.count - index)
            }}
            if index > 0, wildcard.contains(candidate) {{
                bestRuleLabels = max(bestRuleLabels, labels.count - index + 1)
            }}
        }}
        if let exceptionRule {{
            return exceptionRule.split(separator: ".").dropFirst().joined(separator: ".")
        }}
        return labels.suffix(bestRuleLabels).joined(separator: ".")
    }}
}}
'''.encode("utf-8")


def validate_manual_entry(item, tier, psl, protected_ancestors):
    if not isinstance(item, dict):
        fail(f"manual {tier} entry must be an object")
    host = canonical_host(item.get("host", ""))
    match = item.get("match")
    if host is None or match not in ("exact", "suffix"):
        fail(f"manual {tier} entry is not canonical")
    if match == "suffix" and not psl.allows_suffix(host):
        fail(f"manual {tier} suffix {host} is a public suffix")
    if host in protected_ancestors:
        fail(f"manual {tier} entry {host} intersects a protected host")
    if not isinstance(item.get("evidence"), str) or not item["evidence"].strip():
        fail(f"manual {tier} entry {host} has no evidence")
    return host, match


def build():
    source_lock, inputs = locked_inputs()
    policy = load_json(POLICY_PATH)
    stable = load_json(STABLE_IDS_PATH)
    if policy.get("format") != 1:
        fail("policy format is unsupported")

    psl_item = next((item for item in inputs if item[0].get("sourceID") == "psl"
                     and item[1].name == "public_suffix_list.dat"), None)
    if psl_item is None:
        fail("the locked Public Suffix List snapshot is missing")
    psl = PublicSuffixList.parse(psl_item[2])

    easy_candidates, easy_exceptions, parser_counts = parse_easylist(inputs)
    hagezi_pro_item = next((item for item in inputs if item[1].name == "pro-onlydomains.txt"), None)
    hagezi_plus_item = next((item for item in inputs if item[1].name == "pro.plus-onlydomains.txt"), None)
    if hagezi_pro_item is None or hagezi_plus_item is None:
        fail("both locked HaGeZi corroboration tiers are required")
    hagezi_pro = parse_plain_domains(hagezi_pro_item[2], hagezi_pro_item[0]["localPath"])
    hagezi_plus = parse_plain_domains(hagezi_plus_item[2], hagezi_plus_item[0]["localPath"])

    exceptions = set(easy_exceptions)
    exception_ancestors = descendant_ancestors(exceptions)
    protected = {canonical_host(value) for value in policy["protectedHosts"]}
    forbidden = {canonical_host(value) for value in policy["forbiddenHosts"]}
    if None in protected or None in forbidden:
        fail("policy contains a non-canonical protected or forbidden host")
    protected_ancestors = descendant_ancestors(protected)
    forbidden_ancestors = descendant_ancestors(forbidden)

    stable_keys = set(stable.get("entries", {})) if isinstance(stable, dict) else set()
    known_identities, _, _ = reconcile_stable_ledger(
        stable, stable_keys, policy.get("minimumAppVersion")
    )
    legacy_suffixes = {
        key.split("|", 1)[0] for key, record in known_identities.items()
        if record["id"] <= 12 and key.endswith("|suffix")
    }
    legacy_suffixes = {
        host for host in legacy_suffixes
        if psl.allows_suffix(host)
        and not intersects(host, exceptions, exception_ancestors)
        and host not in protected_ancestors
        and not intersects(host, forbidden, forbidden_ancestors)
    }
    rejected = defaultdict(list)

    def candidates_for(corroboration, tier):
        result = set()
        for host in easy_candidates:
            if not psl.allows_suffix(host):
                rejected["publicSuffix"].append(host)
                continue
            if intersects(host, exceptions, exception_ancestors):
                rejected["exceptionOverlap"].append(host)
                continue
            if host in protected_ancestors:
                rejected["protectedSurface"].append(host)
                continue
            if intersects(host, forbidden, forbidden_ancestors):
                rejected["forbiddenSurface"].append(host)
                continue
            if not covered_by(host, corroboration):
                rejected[f"notCorroborated-{tier}"].append(host)
                continue
            result.add(host)
        return minimized_suffixes(result | legacy_suffixes)

    balanced_suffixes = candidates_for(hagezi_pro, "balanced")
    aggressive_suffixes = candidates_for(hagezi_plus, "aggressive") | balanced_suffixes
    balanced_forbidden = {canonical_host(value) for value in policy["balancedForbiddenSuffixes"]}
    balanced_forbidden_ancestors = descendant_ancestors(balanced_forbidden)
    balanced_suffixes = {
        host for host in balanced_suffixes
        if not intersects(host, balanced_forbidden, balanced_forbidden_ancestors)
    }

    tier_keys = {
        "balanced": {f"{host}|suffix" for host in balanced_suffixes},
        "aggressive": {f"{host}|suffix" for host in aggressive_suffixes},
    }
    manual_evidence = {}
    for tier in ("balanced", "aggressive"):
        for item in policy["manualEntries"][tier]:
            host, match = validate_manual_entry(item, tier, psl, protected_ancestors)
            key = f"{host}|{match}"
            tier_keys[tier].add(key)
            manual_evidence[key] = item["evidence"]

    for required in tier_keys["balanced"]:
        if not any(semantic_covers(candidate, required) for candidate in tier_keys["aggressive"]):
            fail(f"aggressive tier does not semantically cover balanced entry {required}")
    for tier, keys in tier_keys.items():
        if any(intersects(key.split("|", 1)[0], forbidden, forbidden_ancestors) for key in keys):
            fail(f"{tier} tier intersects a forbidden host")
    if "pubadx.one|suffix" in tier_keys["balanced"]:
        fail("balanced tier must not contain pubadx.one suffix coverage")
    if "pubadx.one|suffix" not in tier_keys["aggressive"]:
        fail("aggressive tier must contain pubadx.one suffix coverage")

    all_keys = tier_keys["balanced"] | tier_keys["aggressive"]
    stable_identities, next_id, tombstones = reconcile_stable_ledger(
        stable, all_keys, policy.get("minimumAppVersion")
    )
    stable_entries = {key: record["id"] for key, record in stable_identities.items()}
    stable_output = {
        "format": 2,
        "nextID": next_id,
        "entries": dict(sorted(stable_identities.items())),
        "tombstones": tombstones,
    }

    source_digests = {
        item["localPath"]: item["sha256"] for item in source_lock["sources"]
    }
    provenance_entries = []
    for key in sorted(all_keys):
        host, match = key.split("|", 1)
        tiers = [tier for tier in ("balanced", "aggressive") if key in tier_keys[tier]]
        evidence = []
        if stable_entries[key] <= 12:
            evidence.append({
                "source": "legacy-built-in",
                "detail": "Stable destination retained from the reviewed pre-0.18.5 Advertising pack.",
            })
        if host in easy_candidates:
            evidence.extend({"source": "easylist", **reference} for reference in easy_candidates[host])
        if key in manual_evidence:
            evidence.append({"source": "manual", "detail": manual_evidence[key]})
        evidence.append({
            "source": "hagezi",
            "tiers": [
                tier for tier, values in (("balanced", hagezi_pro), ("aggressive", hagezi_plus))
                if covered_by(host, values)
            ],
        })
        provenance_entries.append({
            "id": stable_entries[key],
            "host": host,
            "match": match,
            "tiers": tiers,
            "decision": "included",
            "policyFormat": policy["format"],
            "firstSeenVersion": stable_identities[key]["firstSeenVersion"],
            "evidence": evidence,
        })
    provenance = {
        "format": 1,
        "generatedAt": policy["generatedAt"],
        "sources": source_lock["sources"],
        "sourceDigests": source_digests,
        "entries": provenance_entries,
        "tombstones": stable_output["tombstones"],
    }
    provenance_data = json_bytes(provenance)
    provenance_digest = sha256(provenance_data)
    source_url = f"https://flowlight.xinbetween.com/packs/v1/provenance/{provenance_digest}.json"

    def pack(tier):
        metadata = policy[tier]
        entries = []
        for key in tier_keys[tier]:
            host, match = key.split("|", 1)
            entries.append({
                "id": stable_entries[key],
                "host": host,
                "match": match,
                "category": "advertising",
            })
        entries.sort(key=lambda item: f"{item['host']}|{item['match']}")
        canonical = "".join(
            f"{item['id']}\t{item['host']}\t{item['match']}\t{item['category']}\n"
            for item in entries
        ).encode("utf-8")
        return {
            "manifest": {
                "id": metadata["id"],
                "version": metadata["version"],
                "generatedAt": policy["generatedAt"],
                "entryCount": len(entries),
                "contentSHA256": sha256(canonical),
                "minimumAppVersion": policy["minimumAppVersion"],
                "minimumExtensionProtocol": 1,
                "titleKey": metadata["title"],
                "summaryKey": metadata["summary"],
                "caveatKey": metadata["caveat"],
                "source": source_url,
                "license": "GPL-3.0-or-later",
                "format": 1,
            },
            "entries": entries,
        }

    packs = sorted([pack("balanced"), pack("aggressive")], key=lambda value: value["manifest"]["id"])
    packs_data = json_bytes({"format": 1, "packs": packs})

    official_source = load_json(ROOT / "rule-packs" / "official-source.json")
    try:
        retained_packs = [
            value for value in official_source["payload"]["packs"]
            if value["manifest"]["id"] not in {
                policy["balanced"]["id"], policy["aggressive"]["id"]
            }
        ]
    except (KeyError, TypeError):
        fail("rule-packs/official-source.json has an invalid payload")
    catalog_sequence = policy.get("catalogSequence")
    if not isinstance(catalog_sequence, int) or catalog_sequence <= 0:
        fail("policy catalogSequence must be a positive integer")
    official_source["payload"]["sequence"] = catalog_sequence
    official_source["payload"]["issuedAt"] = policy["generatedAt"]
    official_source["payload"]["expiresAt"] = policy["generatedAt"] + 365 * 24 * 60 * 60
    official_source["payload"]["packs"] = sorted(
        retained_packs + packs,
        key=lambda value: value["manifest"]["id"],
    )
    official_source["signatures"] = []
    official_source_data = json_bytes(official_source)
    if len(official_source_data) > 16 * 1024 * 1024:
        fail("generated official catalog exceeds the 16 MiB transport limit")

    report = {
        "format": 1,
        "catalogSequence": catalog_sequence,
        "generatedAt": policy["generatedAt"],
        "sourceCount": len(source_lock["sources"]),
        "sourceBytes": sum(item["bytes"] for item in source_lock["sources"]),
        "parser": parser_counts,
        "easyListUniqueCandidates": len(easy_candidates),
        "easyListUniqueExceptions": len(easy_exceptions),
        "hageziProDomains": len(hagezi_pro),
        "hageziProPlusDomains": len(hagezi_plus),
        "balancedEntries": len(tier_keys["balanced"]),
        "aggressiveEntries": len(tier_keys["aggressive"]),
        "rejected": {key: len(set(values)) for key, values in sorted(rejected.items())},
        "provenanceSHA256": provenance_digest,
        "catalogPacksSHA256": sha256(packs_data),
        "stableIDHighWatermark": next_id - 1,
    }

    generated = {
        "stable_ids": json_bytes(stable_output),
        "official_source": official_source_data,
        "packs": packs_data,
        "provenance": provenance_data,
        "report": json_bytes(report),
        "psl_json": json_bytes(psl.generated_json()),
        "psl_swift": psl_swift(psl),
    }
    generated["provenance_publish"] = provenance_data
    generated["provenance_publish_path"] = (
        ROOT / "site" / "packs" / "v1" / "provenance" / f"{provenance_digest}.json"
    )
    return generated, report


def publication_files(directory):
    if not directory.is_dir():
        return set()
    return {
        path.relative_to(directory).as_posix()
        for path in directory.rglob("*")
        if path.is_file() or path.is_symlink()
    }


def invalid_publication_paths(directory):
    invalid = []
    for name in sorted(publication_files(directory)):
        path = directory / name
        relative = pathlib.PurePosixPath(name)
        if (len(relative.parts) != 1 or path.is_symlink() or not path.is_file()
                or not re.fullmatch(r"[0-9a-f]{64}\.json", name)):
            invalid.append(path)
            continue
        try:
            content = path.read_bytes()
            json.loads(content)
        except (OSError, json.JSONDecodeError, UnicodeDecodeError):
            invalid.append(path)
            continue
        if sha256(content) != path.stem:
            invalid.append(path)
    return invalid


def write_outputs(generated, skip_psl_swift=False):
    for name, path in OUTPUTS.items():
        if skip_psl_swift and name == "psl_swift":
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.is_symlink():
            fail(f"refusing to overwrite generated output symlink: {path.relative_to(ROOT)}")
        path.write_bytes(generated[name])
    publish_path = generated["provenance_publish_path"]
    publish_path.parent.mkdir(parents=True, exist_ok=True)
    if publish_path.is_symlink():
        fail(f"refusing to overwrite generated output symlink: {publish_path.relative_to(ROOT)}")
    publish_path.write_bytes(generated["provenance_publish"])
    publication_dirs = (
        publish_path.parent,
        ROOT / "docs" / "packs" / "v1" / "provenance",
    )
    invalid = [
        path
        for directory in publication_dirs
        for path in invalid_publication_paths(directory)
    ]
    for path in invalid:
        print(
            f"invalid generated provenance archive: {path.relative_to(ROOT)}",
            file=sys.stderr,
        )
    return invalid


def check_outputs(generated):
    failed = False
    for name, path in OUTPUTS.items():
        try:
            actual = path.read_bytes()
        except OSError:
            print(f"missing generated output: {path.relative_to(ROOT)}", file=sys.stderr)
            failed = True
            continue
        if actual != generated[name]:
            print(f"generated output drift: {path.relative_to(ROOT)}", file=sys.stderr)
            failed = True
    publish_path = generated["provenance_publish_path"]
    published = publication_files(publish_path.parent)
    if publish_path.name not in published:
        print(
            f"generated provenance publication is missing: {publish_path.name}",
            file=sys.stderr,
        )
        failed = True
    invalid = invalid_publication_paths(publish_path.parent)
    if invalid:
        print(
            "generated provenance archive contains invalid paths: "
            + ", ".join(str(path.relative_to(ROOT)) for path in invalid),
            file=sys.stderr,
        )
        failed = True
    try:
        if publish_path.is_symlink() or not publish_path.is_file():
            raise OSError("expected a regular file")
        actual = publish_path.read_bytes()
    except OSError:
        print(f"missing generated output: {publish_path.relative_to(ROOT)}", file=sys.stderr)
        failed = True
    else:
        if actual != generated["provenance_publish"]:
            print(f"generated output drift: {publish_path.relative_to(ROOT)}", file=sys.stderr)
            failed = True
    if failed:
        fail("generated advertising outputs are not committed exactly")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true", help="write deterministic generated outputs")
    parser.add_argument(
        "--skip-psl-swift",
        action="store_true",
        help="preserve Shared/PublicSuffixRules.generated.swift during coordinated regeneration",
    )
    args = parser.parse_args()
    if args.skip_psl_swift and not args.write:
        parser.error("--skip-psl-swift requires --write")
    generated, report = build()
    if args.write:
        invalid = write_outputs(generated, skip_psl_swift=args.skip_psl_swift)
        if invalid:
            print(
                "advertising pack generation failed: invalid generated provenance archive paths remain",
                file=sys.stderr,
            )
            return 1
        action = "generated"
    else:
        check_outputs(generated)
        action = "verified"
    print(
        f"{action} advertising packs: {report['balancedEntries']} balanced, "
        f"{report['aggressiveEntries']} aggressive, {report['sourceCount']} pinned sources"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GenerationError as error:
        print(f"advertising pack generation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
