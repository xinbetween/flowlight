#!/usr/bin/env python3
"""Build, sign, and verify Flowlight's official rule-pack catalog.

The JSON representation is for transport. Signatures cover the binary canonical
representation produced here, never a particular JSON serialization.
"""

import argparse
import base64
import binascii
import hashlib
import ipaddress
import json
import os
import pathlib
import re
import struct
import subprocess
import sys
import tempfile


MAX_FILE_BYTES = 8 * 1024 * 1024
MAX_PACKS = 16
MAX_ENTRIES = 250_000
MAX_STRING_BYTES = 16 * 1024
MAX_INT64 = (1 << 63) - 1
DOMAIN = "flowlight-rule-pack-catalog-signature-v1"
CATALOG_ID = "flowlight.official"
CHANNEL = "official"
SOURCE_URL = "https://flowlight.xinbetween.com/packs/v1/official.json"
ALGORITHM = "p256-sha256"

ENVELOPE_FIELDS = {"format", "payload", "signatures"}
PAYLOAD_FIELDS = {"catalogID", "channel", "sourceURL", "sequence", "issuedAt", "expiresAt", "publisher", "packs"}
PACK_FIELDS = {"manifest", "entries"}
MANIFEST_FIELDS = {
    "id", "version", "generatedAt", "entryCount", "contentSHA256", "minimumAppVersion",
    "minimumExtensionProtocol", "titleKey", "summaryKey", "caveatKey", "source", "license", "format",
}
ENTRY_FIELDS = {"id", "host", "match", "category"}
SIGNATURE_FIELDS = {"algorithm", "keyID", "value"}
PACK_ID = re.compile(r"official\.[A-Za-z0-9.-]+\Z")
HEX_SHA256 = re.compile(r"[0-9a-f]{64}\Z")

# official.tracking is deliberately an evidence-backed allowlist. Hostname filtering cannot separate a provider's
# product/control plane from collection paths on the same host, so every accepted entry must be a dedicated collector
# or tracker-bootstrap endpoint reviewed alongside this policy. Adding a destination requires changing both files.
TRACKING_ALLOWED_ENTRIES = {
    ("api.eu.amplitude.com", "exact"),
    ("api-eu.mixpanel.com", "exact"),
    ("api-in.mixpanel.com", "exact"),
    ("api-js.mixpanel.com", "exact"),
    ("api.mixpanel.com", "exact"),
    ("api.segment.io", "exact"),
    ("api2.amplitude.com", "exact"),
    ("browser-intake-ap1-datadoghq.com", "exact"),
    ("browser-intake-ap2-datadoghq.com", "exact"),
    ("browser-intake-datadoghq.com", "suffix"),
    ("browser-intake-datadoghq.eu", "exact"),
    ("browser-intake-ddog-gov.com", "exact"),
    ("browser-intake-uk1-datadoghq.com", "exact"),
    ("browser-intake-us2-ddog-gov.com", "exact"),
    ("browser-intake-us3-datadoghq.com", "exact"),
    ("browser-intake-us5-datadoghq.com", "exact"),
    ("c.eu.heap-api.com", "exact"),
    ("c.us.heap-api.com", "exact"),
    ("cdn.eu.heap-api.com", "exact"),
    ("cdn.heapanalytics.com", "exact"),
    ("cdn.matomo.cloud", "exact"),
    ("cdn.mxpnl.com", "exact"),
    ("cdn.us.heap-api.com", "exact"),
    ("clarity.ms", "suffix"),
    ("edge.eu1.fullstory.com", "exact"),
    ("edge.fullstory.com", "exact"),
    ("eu-assets.i.posthog.com", "exact"),
    ("eu.i.posthog.com", "exact"),
    ("events.eu1.segmentapis.com", "exact"),
    ("events.statsigapi.net", "exact"),
    ("google-analytics.com", "suffix"),
    ("googletagmanager.com", "suffix"),
    ("lr-ingest.com", "suffix"),
    ("lr-ingest.io", "suffix"),
    ("lr-intake.com", "suffix"),
    ("lrkt-in.com", "suffix"),
    ("prodregistryv2.org", "suffix"),
    ("r.logrocket.com", "exact"),
    ("rs.eu1.fullstory.com", "exact"),
    ("rs.fullstory.com", "exact"),
    ("services.fullstory.com", "exact"),
    ("us-assets.i.posthog.com", "exact"),
    ("us.i.posthog.com", "exact"),
}


class CatalogError(ValueError):
    """The catalog cannot be validated or canonicalized."""


def fail(message):
    raise CatalogError(message)


def exact_fields(value, expected, where):
    if not isinstance(value, dict):
        fail(f"{where} must be an object")
    missing = expected - value.keys()
    extra = value.keys() - expected
    if missing:
        fail(f"{where} is missing field(s): {', '.join(sorted(missing))}")
    if extra:
        fail(f"{where} has unknown field(s): {', '.join(sorted(extra))}")


def string(value, where, *, nonempty=True):
    if not isinstance(value, str):
        fail(f"{where} must be a string")
    size = len(value.encode("utf-8"))
    if size > MAX_STRING_BYTES:
        fail(f"{where} exceeds {MAX_STRING_BYTES} UTF-8 bytes")
    if nonempty and not value:
        fail(f"{where} must not be empty")
    return value


def integer(value, where, low, high):
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        fail(f"{where} must be an integer in {low}...{high}")
    return value


def version_tuple(value, where):
    text_value = string(value, where)
    parts = text_value.split(".")
    if not parts or any(not re.fullmatch(r"[0-9]+", part) for part in parts):
        fail(f"{where} must be a dot-separated numeric version")
    numbers = [int(part) for part in parts]
    if any(number > MAX_INT64 for number in numbers):
        fail(f"{where} has a version component outside the Int64 range")
    while len(numbers) > 1 and numbers[-1] == 0:
        numbers.pop()
    return tuple(numbers)


def canonical_host(value, where):
    host = string(value, where)
    if host != host.strip() or host.endswith(".") or host.startswith("["):
        fail(f"{where} is not canonical: {host!r}")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        try:
            ascii_host = host.encode("ascii")
        except UnicodeEncodeError:
            fail(f"{where} is not a canonical ASCII hostname: {host!r}")
        if len(ascii_host) > 253 or host != host.lower():
            fail(f"{where} is not a canonical ASCII hostname: {host!r}")
        labels = host.split(".")
        if any(not label or len(label) > 63 or label[0] == "-" or label[-1] == "-"
               or not re.fullmatch(r"[a-z0-9-]+", label) for label in labels):
            fail(f"{where} is not a canonical hostname: {host!r}")
    else:
        if address.compressed != host:
            fail(f"{where} is not a canonical IP address: {host!r}")
    return host


def entry_digest(entries):
    canonical = "".join(
        f"{entry['id']}\t{entry['host']}\t{entry['match']}\t{entry['category']}\n"
        for entry in entries
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def der_length(data, offset):
    if offset >= len(data):
        fail("signature DER has a truncated length")
    first = data[offset]
    if first < 0x80:
        return first, offset + 1
    count = first & 0x7F
    if count == 0 or count > 2 or offset + 1 + count > len(data):
        fail("signature DER has an invalid length")
    encoded = data[offset + 1:offset + 1 + count]
    if encoded[0] == 0 or (count == 1 and encoded[0] < 0x80):
        fail("signature DER length is not minimally encoded")
    return int.from_bytes(encoded, "big"), offset + 1 + count


def validate_der_signature(data, where):
    if not data or data[0] != 0x30:
        fail(f"{where} is not a DER ECDSA sequence")
    length, offset = der_length(data, 1)
    if offset + length != len(data):
        fail(f"{where} has trailing or truncated DER data")
    for component in ("r", "s"):
        if offset >= len(data) or data[offset] != 0x02:
            fail(f"{where} has no DER integer for {component}")
        integer_length, offset = der_length(data, offset + 1)
        end = offset + integer_length
        if integer_length == 0 or end > len(data):
            fail(f"{where} has a truncated DER integer")
        encoded = data[offset:end]
        if encoded[0] & 0x80 or (len(encoded) > 1 and encoded[0] == 0 and not encoded[1] & 0x80):
            fail(f"{where} has a non-canonical DER integer")
        value = int.from_bytes(encoded, "big")
        if value == 0 or value.bit_length() > 256:
            fail(f"{where} has an out-of-range ECDSA integer")
        offset = end
    if offset != len(data):
        fail(f"{where} has extra DER elements")


def validate(catalog, *, require_signature=False, enforce_tracking_policy=True):
    exact_fields(catalog, ENVELOPE_FIELDS, "catalog")
    integer(catalog["format"], "catalog.format", 1, 1)
    payload = catalog["payload"]
    exact_fields(payload, PAYLOAD_FIELDS, "catalog.payload")
    if string(payload["catalogID"], "catalog.payload.catalogID") != CATALOG_ID:
        fail(f"catalog.payload.catalogID must be {CATALOG_ID!r}")
    if string(payload["channel"], "catalog.payload.channel") != CHANNEL:
        fail(f"catalog.payload.channel must be {CHANNEL!r}")
    if string(payload["sourceURL"], "catalog.payload.sourceURL") != SOURCE_URL:
        fail(f"catalog.payload.sourceURL must be {SOURCE_URL!r}")
    integer(payload["sequence"], "catalog.payload.sequence", 1, MAX_INT64)
    issued = integer(payload["issuedAt"], "catalog.payload.issuedAt", 0, MAX_INT64)
    expires = integer(payload["expiresAt"], "catalog.payload.expiresAt", 0, MAX_INT64)
    if expires <= issued:
        fail("catalog.payload.expiresAt must be later than issuedAt")
    if string(payload["publisher"], "catalog.payload.publisher") != "Flowlight":
        fail("catalog.payload.publisher must be 'Flowlight'")

    packs = payload["packs"]
    if not isinstance(packs, list) or not 1 <= len(packs) <= MAX_PACKS:
        fail(f"catalog.payload.packs must contain 1...{MAX_PACKS} packs")
    pack_ids = []
    total_entries = 0
    for pack_index, pack in enumerate(packs):
        pack_where = f"catalog.payload.packs[{pack_index}]"
        exact_fields(pack, PACK_FIELDS, pack_where)
        manifest = pack["manifest"]
        exact_fields(manifest, MANIFEST_FIELDS, f"{pack_where}.manifest")
        pack_id = string(manifest["id"], f"{pack_where}.manifest.id")
        if not PACK_ID.fullmatch(pack_id):
            fail(f"{pack_where}.manifest.id must be in the official. namespace")
        pack_ids.append(pack_id)
        string(manifest["version"], f"{pack_where}.manifest.version")
        integer(manifest["generatedAt"], f"{pack_where}.manifest.generatedAt", 0, MAX_INT64)
        entry_count = integer(manifest["entryCount"], f"{pack_where}.manifest.entryCount", 0, MAX_ENTRIES)
        digest = string(manifest["contentSHA256"], f"{pack_where}.manifest.contentSHA256")
        if not HEX_SHA256.fullmatch(digest):
            fail(f"{pack_where}.manifest.contentSHA256 must be lowercase SHA-256 hex")
        version_tuple(manifest["minimumAppVersion"], f"{pack_where}.manifest.minimumAppVersion")
        integer(manifest["minimumExtensionProtocol"], f"{pack_where}.manifest.minimumExtensionProtocol", 0, 0xFFFF)
        for field in ("titleKey", "summaryKey", "caveatKey", "source", "license"):
            string(manifest[field], f"{pack_where}.manifest.{field}")
        integer(manifest["format"], f"{pack_where}.manifest.format", 1, 0xFFFF)
        if manifest["format"] != 1:
            fail(f"{pack_where}.manifest.format must be 1")

        entries = pack["entries"]
        if not isinstance(entries, list):
            fail(f"{pack_where}.entries must be an array")
        total_entries += len(entries)
        if total_entries > MAX_ENTRIES:
            fail(f"catalog has more than {MAX_ENTRIES} total entries")
        if entry_count != len(entries):
            fail(f"{pack_where}.manifest.entryCount does not match entries")
        entry_ids = set()
        host_keys = set()
        previous_key = None
        for entry_index, entry in enumerate(entries):
            entry_where = f"{pack_where}.entries[{entry_index}]"
            exact_fields(entry, ENTRY_FIELDS, entry_where)
            entry_id = integer(entry["id"], f"{entry_where}.id", 1, 0xFFFFFFFF)
            if entry_id in entry_ids:
                fail(f"{entry_where}.id is duplicated")
            entry_ids.add(entry_id)
            host = canonical_host(entry["host"], f"{entry_where}.host")
            match = string(entry["match"], f"{entry_where}.match")
            if match not in ("exact", "suffix"):
                fail(f"{entry_where}.match must be exact or suffix")
            if (enforce_tracking_policy and pack_id == "official.tracking"
                    and (host, match) not in TRACKING_ALLOWED_ENTRIES):
                fail(f"{entry_where}.host is not an approved dedicated tracking endpoint: "
                     f"{host!r} with {match} matching")
            host_key = f"{host}|{match}"
            if host_key in host_keys:
                fail(f"{entry_where}.host and match are duplicated")
            host_keys.add(host_key)
            category = string(entry["category"], f"{entry_where}.category")
            if category not in ("advertising", "tracking", "telemetry"):
                fail(f"{entry_where}.category is unsupported")
            if pack_id == "official.tracking" and category != "tracking":
                fail(f"{entry_where}.category must be tracking for official.tracking")
            if previous_key is not None and previous_key >= host_key:
                fail(f"{pack_where}.entries are not strictly sorted by host|match")
            previous_key = host_key
        if entry_digest(entries) != digest:
            fail(f"{pack_where}.manifest.contentSHA256 does not match entries")

    if pack_ids != sorted(pack_ids):
        fail("catalog.payload.packs are not sorted by manifest.id")
    if len(pack_ids) != len(set(pack_ids)):
        fail("catalog.payload.packs contains duplicate manifest.id values")

    signatures = catalog["signatures"]
    if not isinstance(signatures, list) or len(signatures) > 16:
        fail("catalog.signatures must be an array of at most 16 signatures")
    if require_signature and not signatures:
        fail("catalog has no signatures")
    key_ids = set()
    for index, signature in enumerate(signatures):
        where = f"catalog.signatures[{index}]"
        exact_fields(signature, SIGNATURE_FIELDS, where)
        if string(signature["algorithm"], f"{where}.algorithm") != ALGORITHM:
            fail(f"{where}.algorithm must be {ALGORITHM!r}")
        key_id = string(signature["keyID"], f"{where}.keyID")
        if key_id in key_ids:
            fail(f"{where}.keyID is duplicated")
        key_ids.add(key_id)
        encoded = string(signature["value"], f"{where}.value")
        try:
            decoded = base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError):
            fail(f"{where}.value is not valid Base64")
        if base64.b64encode(decoded).decode("ascii") != encoded or not decoded:
            fail(f"{where}.value is not canonical Base64 DER")
        validate_der_signature(decoded, f"{where}.value")
    return catalog


def u16(value):
    return struct.pack(">H", value)


def u32(value):
    return struct.pack(">I", value)


def u64(value):
    return struct.pack(">Q", value)


def text(value):
    encoded = value.encode("utf-8")
    if len(encoded) > MAX_STRING_BYTES:
        fail("canonical string exceeds the wire limit")
    return u32(len(encoded)) + encoded


def canonical_bytes(catalog, *, enforce_tracking_policy=True):
    """Return canonical signed bytes, raising CatalogError for every invalid input."""
    validate(catalog, enforce_tracking_policy=enforce_tracking_policy)
    payload = catalog["payload"]
    out = bytearray(text(DOMAIN))
    out += u16(catalog["format"])
    for field in ("catalogID", "channel", "sourceURL"):
        out += text(payload[field])
    for field in ("sequence", "issuedAt", "expiresAt"):
        out += u64(payload[field])
    out += text(payload["publisher"])
    out += u32(len(payload["packs"]))
    for pack in payload["packs"]:
        manifest = pack["manifest"]
        out += text(manifest["id"])
        out += text(manifest["version"])
        out += u64(manifest["generatedAt"])
        out += u32(manifest["entryCount"])
        out += text(manifest["contentSHA256"])
        out += text(manifest["minimumAppVersion"])
        out += u16(manifest["minimumExtensionProtocol"])
        for field in ("titleKey", "summaryKey", "caveatKey", "source", "license"):
            out += text(manifest[field])
        out += u16(manifest["format"])
        out += u32(len(pack["entries"]))
        for entry in pack["entries"]:
            out += u32(entry["id"])
            out += text(entry["host"])
            out += text(entry["match"])
            out += text(entry["category"])
    return bytes(out)


def no_duplicate_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail(f"JSON object contains duplicate key {key!r}")
        result[key] = value
    return result


def decode(raw, source, *, require_signature=False, enforce_tracking_policy=True):
    if len(raw) > MAX_FILE_BYTES:
        fail(f"{source} exceeds the {MAX_FILE_BYTES}-byte limit")
    try:
        catalog = json.loads(raw.decode("utf-8"), object_pairs_hook=no_duplicate_object)
    except UnicodeDecodeError:
        fail(f"{source} is not UTF-8")
    except json.JSONDecodeError as error:
        fail(f"{source} is not valid JSON: {error.msg} at line {error.lineno}, column {error.colno}")
    return validate(catalog, require_signature=require_signature,
                    enforce_tracking_policy=enforce_tracking_policy)


def load(path, *, require_signature=False, enforce_tracking_policy=True):
    path = pathlib.Path(path)
    try:
        raw = path.read_bytes()
    except OSError as error:
        fail(f"cannot read {path}: {error.strerror}")
    return decode(raw, str(path), require_signature=require_signature,
                  enforce_tracking_policy=enforce_tracking_policy)


def load_git(ref, path, *, require_signature=False, enforce_tracking_policy=True):
    repository = pathlib.Path(__file__).resolve().parent.parent
    try:
        result = subprocess.run(
            ["git", "show", f"{ref}:{path}"], cwd=repository, capture_output=True, timeout=30
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        fail("git could not read the previous catalog")
    if result.returncode:
        fail(f"git could not read previous catalog {ref}:{path}")
    return decode(result.stdout, f"{ref}:{path}", require_signature=require_signature,
                  enforce_tracking_policy=enforce_tracking_policy)


def serialized(catalog):
    data = (json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", ": ")) + "\n").encode("utf-8")
    if len(data) > MAX_FILE_BYTES:
        fail(f"serialized catalog exceeds the {MAX_FILE_BYTES}-byte limit")
    return data


def atomic_write(path, data):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def openssl(arguments, *, stdin=None):
    try:
        result = subprocess.run(["openssl", *arguments], input=stdin, capture_output=True, timeout=30)
    except FileNotFoundError:
        fail("OpenSSL is required but was not found")
    except subprocess.TimeoutExpired:
        fail("OpenSSL timed out")
    if result.returncode != 0:
        fail("OpenSSL rejected the key or signature")
    return result


def require_p256(path, *, public):
    arguments = ["pkey"]
    if public:
        arguments.append("-pubin")
    arguments += ["-in", str(path), "-text", "-noout"]
    details = openssl(arguments).stdout.decode("utf-8", "replace")
    if "prime256v1" not in details and "P-256" not in details:
        fail("key must be an EC P-256 key")


def command_build(args):
    catalog = load(args.input)
    canonical_bytes(catalog)
    atomic_write(args.output, serialized(catalog))
    print(f"Built validated catalog: {args.output}")


def command_validate(args):
    catalog = load(args.input)
    canonical = canonical_bytes(catalog)
    print(f"Valid catalog: {len(catalog['payload']['packs'])} pack(s), "
          f"{sum(len(pack['entries']) for pack in catalog['payload']['packs'])} entries, "
          f"{len(canonical)} canonical bytes")


def command_compare(args):
    source = load(args.source)
    signed = load(args.signed, require_signature=True)
    if source["signatures"]:
        fail("reviewed source must not contain signatures")
    if canonical_bytes(source) != canonical_bytes(signed):
        fail("reviewed source payload differs from signed catalog payload")
    print("Reviewed source payload matches signed catalog payload")


def command_compare_previous(args):
    current = load(args.current, require_signature=True)
    previous = (load(args.previous, require_signature=True, enforce_tracking_policy=False) if args.previous else
                load_git(args.previous_ref, args.previous_path, require_signature=True,
                         enforce_tracking_policy=False))
    current_sequence = current["payload"]["sequence"]
    previous_sequence = previous["payload"]["sequence"]
    current_digest = hashlib.sha256(canonical_bytes(current)).hexdigest()
    previous_digest = hashlib.sha256(canonical_bytes(previous, enforce_tracking_policy=False)).hexdigest()
    if current_sequence < previous_sequence:
        fail(f"catalog sequence rolled back from {previous_sequence} to {current_sequence}")
    if current_sequence == previous_sequence and current_digest != previous_digest:
        fail(f"catalog payload changed without increasing sequence {current_sequence}")
    print(f"Catalog sequence {current_sequence} is consistent with previous sequence {previous_sequence}")


def command_sign(args):
    catalog = load(args.input)
    key_id = string(args.key_id, "--key-id")
    require_p256(args.private_key, public=False)
    canonical = canonical_bytes(catalog)
    with tempfile.TemporaryDirectory(prefix="flowlight-rule-pack-sign-") as directory:
        canonical_path = pathlib.Path(directory) / "catalog.bin"
        signature_path = pathlib.Path(directory) / "signature.der"
        canonical_path.write_bytes(canonical)
        openssl(["dgst", "-sha256", "-sign", str(args.private_key), "-out", str(signature_path), str(canonical_path)])
        value = base64.b64encode(signature_path.read_bytes()).decode("ascii")
    replacement = {"algorithm": ALGORITHM, "keyID": key_id, "value": value}
    catalog["signatures"] = [signature for signature in catalog["signatures"] if signature["keyID"] != key_id]
    catalog["signatures"].append(replacement)
    catalog["signatures"].sort(key=lambda signature: signature["keyID"])
    validate(catalog, require_signature=True)
    atomic_write(args.output, serialized(catalog))
    print(f"Signed catalog with key ID {key_id}: {args.output}")


def command_verify(args):
    catalog = load(args.input, require_signature=True,
                   enforce_tracking_policy=not args.historical)
    if args.current_app_version is not None:
        current = version_tuple(args.current_app_version, "--current-app-version")
        for pack in catalog["payload"]["packs"]:
            manifest = pack["manifest"]
            required = version_tuple(manifest["minimumAppVersion"],
                                     f"{manifest['id']}.minimumAppVersion")
            if required > current:
                fail(f"{manifest['id']} requires app version {manifest['minimumAppVersion']}")
    if args.extension_protocol is not None:
        protocol = integer(args.extension_protocol, "--extension-protocol", 0, 0xFFFF)
        for pack in catalog["payload"]["packs"]:
            manifest = pack["manifest"]
            if manifest["minimumExtensionProtocol"] > protocol:
                fail(f"{manifest['id']} requires extension protocol {manifest['minimumExtensionProtocol']}")
    if args.now is not None:
        now = integer(args.now, "--now", 0, MAX_INT64)
        issued = catalog["payload"]["issuedAt"]
        expires = catalog["payload"]["expiresAt"]
        if issued > now + 5 * 60:
            fail("catalog is issued too far in the future")
        if expires < now:
            fail("catalog is expired")
    if len(args.public_key) != len(args.expected_key_id):
        fail("each --expected-key-id must have one corresponding --public-key")
    canonical = canonical_bytes(catalog, enforce_tracking_policy=not args.historical)
    for expected_value, public_key in zip(args.expected_key_id, args.public_key):
        expected = string(expected_value, "--expected-key-id")
        matches = [signature for signature in catalog["signatures"] if signature["keyID"] == expected]
        if len(matches) != 1:
            fail(f"catalog has no signature for expected key ID {expected!r}")
        signature = matches[0]
        if signature["algorithm"] != ALGORITHM:
            fail(f"signature for {expected!r} does not use {ALGORITHM}")
        require_p256(public_key, public=True)
        with tempfile.TemporaryDirectory(prefix="flowlight-rule-pack-verify-") as directory:
            canonical_path = pathlib.Path(directory) / "catalog.bin"
            signature_path = pathlib.Path(directory) / "signature.der"
            canonical_path.write_bytes(canonical)
            signature_path.write_bytes(base64.b64decode(signature["value"], validate=True))
            openssl(["dgst", "-sha256", "-verify", str(public_key), "-signature", str(signature_path),
                     str(canonical_path)])
        print(f"Verified catalog signature for key ID {expected}")


def command_digest(args):
    catalog = load(args.input)
    print(f"catalog  {hashlib.sha256(canonical_bytes(catalog)).hexdigest()}")
    for pack in catalog["payload"]["packs"]:
        print(f"{pack['manifest']['id']}  {entry_digest(pack['entries'])}")


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build", help="validate and atomically serialize an unsigned or signed catalog")
    build.add_argument("input", type=pathlib.Path)
    build.add_argument("output", type=pathlib.Path)
    build.set_defaults(run=command_build)
    validate_command = commands.add_parser("validate", help="validate without requiring a signature")
    validate_command.add_argument("input", type=pathlib.Path)
    validate_command.set_defaults(run=command_validate)
    compare = commands.add_parser("compare", help="require reviewed source and signed catalog payloads to match")
    compare.add_argument("source", type=pathlib.Path)
    compare.add_argument("signed", type=pathlib.Path)
    compare.set_defaults(run=command_compare)
    previous = commands.add_parser("compare-previous", help="reject rollback or equivocation against a prior catalog")
    previous.add_argument("current", type=pathlib.Path)
    prior = previous.add_mutually_exclusive_group(required=True)
    prior.add_argument("--previous", type=pathlib.Path)
    prior.add_argument("--previous-ref")
    previous.add_argument("--previous-path", default="site/packs/v1/official.json")
    previous.set_defaults(run=command_compare_previous)
    sign = commands.add_parser("sign", help="add or replace one P-256 signature")
    sign.add_argument("input", type=pathlib.Path)
    sign.add_argument("output", type=pathlib.Path)
    sign.add_argument("--private-key", required=True, type=pathlib.Path)
    sign.add_argument("--key-id", required=True)
    sign.set_defaults(run=command_sign)
    verify = commands.add_parser("verify", help="verify the signature for an explicit key ID")
    verify.add_argument("input", type=pathlib.Path)
    verify.add_argument("--public-key", required=True, action="append", type=pathlib.Path)
    verify.add_argument("--expected-key-id", required=True, action="append")
    verify.add_argument("--current-app-version")
    verify.add_argument("--extension-protocol", type=int)
    verify.add_argument("--now", type=int, help="also require the signed acceptance window to contain this Unix time")
    verify.add_argument("--historical", action="store_true",
                        help="verify an immutable prior catalog without applying the current endpoint policy")
    verify.set_defaults(run=command_verify)
    digest = commands.add_parser("digest", help="print each validated pack's entry digest")
    digest.add_argument("input", type=pathlib.Path)
    digest.set_defaults(run=command_digest)
    return result


def main():
    try:
        arguments = parser().parse_args()
        arguments.run(arguments)
        return 0
    except CatalogError as error:
        print(f"rule-pack catalog error: {error}", file=sys.stderr)
        return 1
    except OSError as error:
        print(f"rule-pack catalog error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
