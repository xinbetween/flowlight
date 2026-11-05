#!/usr/bin/env python3
"""Create and verify Flowlight's build-once release handoff."""

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import shutil
import stat
import sys
import zipfile

SCHEMA = "flowlight-release-v1"
WORKFLOW_PATH = ".github/workflows/release.yml"
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
SOURCE_SHA = re.compile(r"[0-9a-f]{40}\Z")
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+\Z")
REQUIRED_REVIEW_CHECKS = {
    ("github-actions", "changes"),
    ("github-actions", "site"),
    ("github-actions", "unit (oldest Xcode)"),
    ("github-actions", "unit (newest Xcode)"),
    ("github-actions", "Review / gate"),
    ("github-actions", "CodeQL / gate"),
    ("github-advanced-security", "CodeQL"),
}
REVIEW_WORKFLOWS = {
    ("github-actions", "changes"): ".github/workflows/ci.yml",
    ("github-actions", "site"): ".github/workflows/ci.yml",
    ("github-actions", "unit (oldest Xcode)"): ".github/workflows/ci.yml",
    ("github-actions", "unit (newest Xcode)"): ".github/workflows/ci.yml",
    ("github-actions", "Review / gate"): ".github/workflows/ci.yml",
    ("github-actions", "CodeQL / gate"): ".github/workflows/codeql.yml",
}
GITHUB_AUTHOR_ASSOCIATIONS = frozenset({
    "COLLABORATOR", "CONTRIBUTOR", "FIRST_TIMER", "FIRST_TIME_CONTRIBUTOR",
    "MANNEQUIN", "MEMBER", "NONE", "OWNER",
})


class ReleaseArtifactError(ValueError):
    pass


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ReleaseArtifactError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path):
    try:
        return json.loads(pathlib.Path(path).read_text(), object_pairs_hook=reject_duplicate_keys)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ReleaseArtifactError(f"cannot read JSON from {path}: {error}") from error


def sha256(path):
    digest = hashlib.sha256()
    with pathlib.Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_record(path):
    path = pathlib.Path(path)
    return {"name": path.name, "size": path.stat().st_size, "sha256": sha256(path)}


def require_keys(value, expected, label):
    if not isinstance(value, dict):
        raise ReleaseArtifactError(f"{label} must be an object")
    actual = set(value)
    expected = set(expected)
    if actual != expected:
        raise ReleaseArtifactError(
            f"{label} fields differ: missing={sorted(expected - actual)} extra={sorted(actual - expected)}"
        )


def require_plain_name(name, label):
    if not isinstance(name, str) or not name or pathlib.PurePosixPath(name).name != name:
        raise ReleaseArtifactError(f"{label} is not a plain filename: {name!r}")
    if name in {".", ".."} or "/" in name or "\\" in name:
        raise ReleaseArtifactError(f"{label} is not a plain filename: {name!r}")


def parse_timestamp(value, label):
    if not isinstance(value, str):
        raise ReleaseArtifactError(f"{label} must be an ISO-8601 timestamp")
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ReleaseArtifactError(f"{label} is not an ISO-8601 timestamp") from error


def verify_run(document, artifacts_document, *, repository, workflow_id, run_id, tag, source_sha, now=None):
    if not str(run_id).isdigit():
        raise ReleaseArtifactError("prepare run ID must contain decimal digits only")
    run_id = int(run_id)
    if not SOURCE_SHA.fullmatch(source_sha):
        raise ReleaseArtifactError("expected source SHA must be 40 lowercase hexadecimal characters")
    if not isinstance(document, dict):
        raise ReleaseArtifactError("run response must be an object")
    checks = {
        "run ID": (document.get("id"), run_id),
        "repository": (document.get("repository", {}).get("full_name"), repository),
        "workflow path": (document.get("path"), WORKFLOW_PATH),
        "workflow ID": (document.get("workflow_id"), int(workflow_id)),
        "event": (document.get("event"), "push"),
        "tag": (document.get("head_branch"), tag),
        "source SHA": (document.get("head_sha"), source_sha),
        "status": (document.get("status"), "completed"),
        "conclusion": (document.get("conclusion"), "success"),
    }
    for label, (actual, expected) in checks.items():
        if actual != expected:
            raise ReleaseArtifactError(f"preparation {label} is {actual!r}, expected {expected!r}")

    if not isinstance(artifacts_document, dict) or not isinstance(artifacts_document.get("artifacts"), list):
        raise ReleaseArtifactError("artifact response has an unexpected shape")
    artifacts = artifacts_document["artifacts"]
    if artifacts_document.get("total_count") != len(artifacts):
        raise ReleaseArtifactError("artifact response count does not match its artifact list")
    run_attempt = document.get("run_attempt")
    if not isinstance(run_attempt, int) or run_attempt <= 0:
        raise ReleaseArtifactError("preparation run attempt is missing or malformed")
    expected_name = f"flowlight-release-{tag}-{run_id}-{run_attempt}"
    matching = [artifact for artifact in artifacts if artifact.get("name") == expected_name]
    if len(matching) != 1:
        raise ReleaseArtifactError(
            f"preparation attempt must have exactly one {expected_name!r} artifact, found {len(matching)}"
        )
    artifact = matching[0]
    if artifact.get("expired") is not False:
        raise ReleaseArtifactError("prepared artifact is expired")
    now = now or dt.datetime.now(dt.timezone.utc)
    if parse_timestamp(artifact.get("expires_at"), "artifact expiry") <= now:
        raise ReleaseArtifactError("prepared artifact has no remaining retention")
    if artifact.get("workflow_run", {}).get("id") != run_id:
        raise ReleaseArtifactError("artifact is not attached to the selected preparation run")
    digest = artifact.get("digest")
    if not isinstance(digest, str) or not digest.startswith("sha256:") or not SHA256.fullmatch(digest[7:]):
        raise ReleaseArtifactError("artifact archive digest is missing or malformed")
    if not isinstance(artifact.get("id"), int) or artifact["id"] <= 0:
        raise ReleaseArtifactError("artifact ID is missing or malformed")
    if not isinstance(artifact.get("size_in_bytes"), int) or artifact["size_in_bytes"] <= 0:
        raise ReleaseArtifactError("artifact size is missing or empty")
    return {
        "artifact_id": artifact["id"],
        "artifact_name": expected_name,
        "artifact_digest": digest,
        "run_attempt": run_attempt,
    }


def create_manifest(args):
    bundle = pathlib.Path(args.bundle)
    version = args.version
    if not VERSION.fullmatch(version):
        raise ReleaseArtifactError("version must be three numeric components")
    expected = [bundle / "Flowlight.dmg", bundle / f"Flowlight-{version}.pkg", bundle / "SHA256SUMS.txt"]
    notes = bundle / "RELEASE-NOTES.md"
    for path in [*expected, notes]:
        if not path.is_file() or path.is_symlink():
            raise ReleaseArtifactError(f"missing regular prepared file: {path.name}")
    evidence = load_json(args.evidence)
    manifest = {
        "schema": SCHEMA,
        "repository": args.repository,
        "tag": args.tag,
        "source_sha": args.source_sha,
        "source_tree": args.source_tree,
        "version": version,
        "build": str(args.build),
        "preparation": {
            "workflow": WORKFLOW_PATH,
            "workflow_id": int(args.workflow_id),
            "run_id": int(args.run_id),
            "run_attempt": int(args.run_attempt),
        },
        "review_evidence": evidence,
        "assets": [file_record(path) for path in expected],
        "release_notes": file_record(notes),
    }
    output = bundle / "RELEASE-MANIFEST.json"
    output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return output


def verify_record(record, expected_name, path):
    require_keys(record, {"name", "size", "sha256"}, f"record for {expected_name}")
    require_plain_name(record["name"], "manifest filename")
    if record["name"] != expected_name:
        raise ReleaseArtifactError(f"manifest names {record['name']!r}, expected {expected_name!r}")
    if not isinstance(record["size"], int) or record["size"] < 0:
        raise ReleaseArtifactError(f"manifest size for {expected_name} is malformed")
    if not isinstance(record["sha256"], str) or not SHA256.fullmatch(record["sha256"]):
        raise ReleaseArtifactError(f"manifest SHA-256 for {expected_name} is malformed")
    if path.stat().st_size != record["size"]:
        raise ReleaseArtifactError(f"size mismatch for {expected_name}")
    actual = sha256(path)
    if actual != record["sha256"]:
        raise ReleaseArtifactError(f"SHA-256 mismatch for {expected_name}")


def parse_checksums(path, expected_names):
    try:
        lines = path.read_text().splitlines()
    except (OSError, UnicodeError) as error:
        raise ReleaseArtifactError(f"cannot read checksum file: {error}") from error
    if len(lines) != len(expected_names):
        raise ReleaseArtifactError("checksum file must contain exactly one line per binary asset")
    checksums = {}
    for line in lines:
        match = re.fullmatch(r"([0-9a-f]{64}) [ *]([^/\\]+)", line)
        if not match:
            raise ReleaseArtifactError(f"malformed checksum line: {line!r}")
        digest, name = match.groups()
        require_plain_name(name, "checksum filename")
        if name in checksums:
            raise ReleaseArtifactError(f"duplicate checksum entry: {name}")
        checksums[name] = digest
    if set(checksums) != set(expected_names):
        raise ReleaseArtifactError("checksum filenames do not match the binary assets")
    return checksums


def verify_review_evidence(evidence, repository, source_sha):
    require_keys(
        evidence,
        {"repository", "source_sha", "pull_requests", "review_receipts", "checks"},
        "review evidence",
    )
    if evidence["repository"] != repository or evidence["source_sha"] != source_sha:
        raise ReleaseArtifactError("manifest review evidence does not bind the release repository and source SHA")
    pulls = evidence["pull_requests"]
    if not isinstance(pulls, list) or not pulls or any(not isinstance(number, int) or number <= 0 for number in pulls):
        raise ReleaseArtifactError("review evidence must name at least one valid pull request")
    if len(set(pulls)) != len(pulls):
        raise ReleaseArtifactError("review evidence contains duplicate pull requests")
    receipts = evidence["review_receipts"]
    if not isinstance(receipts, list) or not receipts:
        raise ReleaseArtifactError("review evidence must retain an authenticated review receipt")
    receipt_ids = set()
    for receipt in receipts:
        require_keys(
            receipt,
            {"pull_request", "comment_id", "reviewer", "author_association", "reviewed_commit", "url"},
            "review receipt",
        )
        pull_number = receipt["pull_request"]
        comment_id = receipt["comment_id"]
        if pull_number not in pulls:
            raise ReleaseArtifactError("review receipt does not belong to an exact-head pull request")
        if not isinstance(comment_id, int) or isinstance(comment_id, bool) or comment_id <= 0:
            raise ReleaseArtifactError("review receipt comment ID is malformed")
        if comment_id in receipt_ids:
            raise ReleaseArtifactError("review evidence contains duplicate review receipt IDs")
        receipt_ids.add(comment_id)
        reviewer = receipt["reviewer"]
        if not isinstance(reviewer, str) or not reviewer.strip():
            raise ReleaseArtifactError("review receipt reviewer is malformed")
        # GitHub's author association is viewer-dependent when organization
        # membership is private. Authorization was already established by the
        # configured reviewer login allowlist when this evidence was collected;
        # retain a valid GitHub association only as audit metadata.
        association = receipt["author_association"]
        if association not in GITHUB_AUTHOR_ASSOCIATIONS:
            raise ReleaseArtifactError("review receipt author association is malformed")
        if receipt["reviewed_commit"] != source_sha:
            raise ReleaseArtifactError("review receipt does not bind the exact release commit")
        expected_url = f"https://github.com/{repository}/pull/{pull_number}#issuecomment-{comment_id}"
        if receipt["url"] != expected_url:
            raise ReleaseArtifactError("review receipt URL does not bind its pull request and comment ID")
    checks = evidence["checks"]
    if not isinstance(checks, list) or len(checks) != len(REQUIRED_REVIEW_CHECKS):
        raise ReleaseArtifactError("review evidence does not contain every required check exactly once")
    found = set()
    for check in checks:
        require_keys(
            check,
            {"app", "name", "id", "details_url", "workflow", "workflow_run_id", "pull_request"},
            "review check",
        )
        key = (check["app"], check["name"])
        if key in found or key not in REQUIRED_REVIEW_CHECKS:
            raise ReleaseArtifactError(f"unexpected or duplicate review check: {key}")
        if not isinstance(check["id"], int) or check["id"] <= 0:
            raise ReleaseArtifactError(f"review check has an invalid ID: {key}")
        if not isinstance(check["details_url"], str) or not check["details_url"].startswith(f"https://github.com/{repository}/"):
            raise ReleaseArtifactError(f"review check points outside the release repository: {key}")
        expected_workflow = REVIEW_WORKFLOWS.get(key)
        if expected_workflow:
            if check["workflow"] != expected_workflow:
                raise ReleaseArtifactError(f"review check came from the wrong workflow: {key}")
            if not isinstance(check["workflow_run_id"], int) or check["workflow_run_id"] <= 0:
                raise ReleaseArtifactError(f"review check has no trusted workflow run ID: {key}")
            if check["pull_request"] not in pulls:
                raise ReleaseArtifactError(f"review check is not bound to an exact-head reviewed pull request: {key}")
            run_url = re.fullmatch(
                rf"https://github\.com/{re.escape(repository)}/actions/runs/([0-9]+)(?:/.*)?",
                check["details_url"],
            )
            if not run_url or int(run_url.group(1)) != check["workflow_run_id"]:
                raise ReleaseArtifactError(f"review check URL does not bind its workflow run ID: {key}")
        elif check["workflow"] is not None or check["workflow_run_id"] is not None or check["pull_request"] is not None:
            raise ReleaseArtifactError(f"non-Actions review check unexpectedly names workflow or pull-request provenance: {key}")
        found.add(key)
    if found != REQUIRED_REVIEW_CHECKS:
        raise ReleaseArtifactError("review evidence check set is incomplete")


def extract_archive(archive, destination, *, version, max_expanded_size=2_000_000_000):
    archive = pathlib.Path(archive)
    destination = pathlib.Path(destination)
    if not VERSION.fullmatch(version):
        raise ReleaseArtifactError("version must be three numeric components")
    if destination.exists():
        if not destination.is_dir() or any(destination.iterdir()):
            raise ReleaseArtifactError("archive destination must be an empty directory")
    else:
        destination.mkdir()
    expected = {
        "Flowlight.dmg",
        f"Flowlight-{version}.pkg",
        "SHA256SUMS.txt",
        "RELEASE-NOTES.md",
        "RELEASE-MANIFEST.json",
    }
    try:
        with zipfile.ZipFile(archive) as bundle:
            infos = bundle.infolist()
            names = [entry.filename for entry in infos]
            if len(names) != len(set(names)):
                raise ReleaseArtifactError("prepared archive contains duplicate paths")
            if set(names) != expected or len(infos) != len(expected):
                raise ReleaseArtifactError(f"prepared archive paths differ: {sorted(names)}")
            expanded_size = sum(entry.file_size for entry in infos)
            if expanded_size > max_expanded_size:
                raise ReleaseArtifactError("prepared archive expands beyond the release size bound")
            for entry in infos:
                require_plain_name(entry.filename, "prepared archive path")
                mode = entry.external_attr >> 16
                if mode and not stat.S_ISREG(mode):
                    raise ReleaseArtifactError(
                        f"prepared archive entry is not a regular file: {entry.filename}"
                    )
                if entry.flag_bits & 1:
                    raise ReleaseArtifactError(f"prepared archive entry is encrypted: {entry.filename}")
            for entry in infos:
                target = destination / entry.filename
                with bundle.open(entry) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)
    except (zipfile.BadZipFile, zipfile.LargeZipFile, RuntimeError) as error:
        raise ReleaseArtifactError(f"prepared archive cannot be extracted safely: {error}") from error
    return destination


def verify_bundle(bundle, *, repository, tag, source_sha, version, build, workflow_id, run_id, run_attempt, public=False):
    bundle = pathlib.Path(bundle)
    if not bundle.is_dir():
        raise ReleaseArtifactError(f"bundle is not a directory: {bundle}")
    names = set()
    for entry in bundle.iterdir():
        mode = entry.lstat().st_mode
        if not stat.S_ISREG(mode):
            raise ReleaseArtifactError(f"bundle entry is not a regular file: {entry.name}")
        require_plain_name(entry.name, "bundle entry")
        names.add(entry.name)
    pkg_name = f"Flowlight-{version}.pkg"
    prepared_names = {"Flowlight.dmg", pkg_name, "SHA256SUMS.txt", "RELEASE-NOTES.md", "RELEASE-MANIFEST.json"}
    public_names = prepared_names - {"RELEASE-NOTES.md"}
    expected_names = public_names if public else prepared_names
    if names != expected_names:
        raise ReleaseArtifactError(
            f"bundle files differ: missing={sorted(expected_names - names)} extra={sorted(names - expected_names)}"
        )

    manifest = load_json(bundle / "RELEASE-MANIFEST.json")
    require_keys(
        manifest,
        {"schema", "repository", "tag", "source_sha", "source_tree", "version", "build", "preparation", "review_evidence", "assets", "release_notes"},
        "manifest",
    )
    expected_scalars = {
        "schema": SCHEMA,
        "repository": repository,
        "tag": tag,
        "source_sha": source_sha,
        "version": version,
        "build": str(build),
    }
    for field, expected in expected_scalars.items():
        if manifest[field] != expected:
            raise ReleaseArtifactError(f"manifest {field} is {manifest[field]!r}, expected {expected!r}")
    if not SOURCE_SHA.fullmatch(manifest["source_sha"]):
        raise ReleaseArtifactError("manifest source SHA is malformed")
    if not SOURCE_SHA.fullmatch(manifest["source_tree"]):
        raise ReleaseArtifactError("manifest source tree is malformed")
    if not VERSION.fullmatch(manifest["version"]):
        raise ReleaseArtifactError("manifest version is malformed")
    preparation = manifest["preparation"]
    require_keys(preparation, {"workflow", "workflow_id", "run_id", "run_attempt"}, "preparation")
    if preparation != {
        "workflow": WORKFLOW_PATH,
        "workflow_id": int(workflow_id),
        "run_id": int(run_id),
        "run_attempt": int(run_attempt),
    }:
        raise ReleaseArtifactError("manifest preparation identity does not match the selected run")
    if preparation["run_attempt"] <= 0:
        raise ReleaseArtifactError("manifest run attempt is malformed")
    verify_review_evidence(manifest["review_evidence"], repository, source_sha)

    assets = manifest["assets"]
    if not isinstance(assets, list) or len(assets) != 3:
        raise ReleaseArtifactError("manifest must describe exactly three non-manifest public assets")
    records = {}
    for record in assets:
        if not isinstance(record, dict) or not isinstance(record.get("name"), str):
            raise ReleaseArtifactError("manifest asset record is malformed")
        if record["name"] in records:
            raise ReleaseArtifactError(f"duplicate manifest asset: {record['name']}")
        records[record["name"]] = record
    expected_asset_names = {"Flowlight.dmg", pkg_name, "SHA256SUMS.txt"}
    if set(records) != expected_asset_names:
        raise ReleaseArtifactError("manifest asset names do not match the release assets")
    for name in expected_asset_names:
        verify_record(records[name], name, bundle / name)

    notes_record = manifest["release_notes"]
    require_keys(notes_record, {"name", "size", "sha256"}, "release notes record")
    if notes_record.get("name") != "RELEASE-NOTES.md":
        raise ReleaseArtifactError("release notes record has an unexpected name")
    if not isinstance(notes_record.get("size"), int) or notes_record["size"] <= 0:
        raise ReleaseArtifactError("release notes must not be empty")
    if not isinstance(notes_record.get("sha256"), str) or not SHA256.fullmatch(notes_record["sha256"]):
        raise ReleaseArtifactError("release notes digest is malformed")
    if not public:
        verify_record(notes_record, "RELEASE-NOTES.md", bundle / "RELEASE-NOTES.md")

    checksums = parse_checksums(bundle / "SHA256SUMS.txt", ["Flowlight.dmg", pkg_name])
    for name, digest in checksums.items():
        actual = sha256(bundle / name)
        if digest != actual or digest != records[name]["sha256"]:
            raise ReleaseArtifactError(f"checksum disagreement for {name}")
    return manifest


def parser():
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)

    run = commands.add_parser("verify-run")
    run.add_argument("--run-json", required=True)
    run.add_argument("--artifacts-json", required=True)
    run.add_argument("--repository", required=True)
    run.add_argument("--workflow-id", required=True, type=int)
    run.add_argument("--run-id", required=True)
    run.add_argument("--tag", required=True)
    run.add_argument("--source-sha", required=True)

    extract = commands.add_parser("extract-archive")
    extract.add_argument("--archive", required=True)
    extract.add_argument("--destination", required=True)
    extract.add_argument("--version", required=True)

    create = commands.add_parser("create-manifest")
    create.add_argument("--bundle", required=True)
    create.add_argument("--repository", required=True)
    create.add_argument("--tag", required=True)
    create.add_argument("--source-sha", required=True)
    create.add_argument("--source-tree", required=True)
    create.add_argument("--version", required=True)
    create.add_argument("--build", required=True)
    create.add_argument("--workflow-id", required=True, type=int)
    create.add_argument("--run-id", required=True, type=int)
    create.add_argument("--run-attempt", required=True, type=int)
    create.add_argument("--evidence", required=True)

    verify = commands.add_parser("verify-bundle")
    verify.add_argument("--bundle", required=True)
    verify.add_argument("--repository", required=True)
    verify.add_argument("--tag", required=True)
    verify.add_argument("--source-sha", required=True)
    verify.add_argument("--version", required=True)
    verify.add_argument("--build", required=True)
    verify.add_argument("--workflow-id", required=True, type=int)
    verify.add_argument("--run-id", required=True, type=int)
    verify.add_argument("--run-attempt", required=True, type=int)
    verify.add_argument("--public", action="store_true")
    return root


def main():
    args = parser().parse_args()
    try:
        if args.command == "verify-run":
            result = verify_run(
                load_json(args.run_json),
                load_json(args.artifacts_json),
                repository=args.repository,
                workflow_id=args.workflow_id,
                run_id=args.run_id,
                tag=args.tag,
                source_sha=args.source_sha,
            )
            print(json.dumps(result, sort_keys=True))
        elif args.command == "extract-archive":
            print(extract_archive(args.archive, args.destination, version=args.version))
        elif args.command == "create-manifest":
            print(create_manifest(args))
        else:
            verify_bundle(
                args.bundle,
                repository=args.repository,
                tag=args.tag,
                source_sha=args.source_sha,
                version=args.version,
                build=args.build,
                workflow_id=args.workflow_id,
                run_id=args.run_id,
                run_attempt=args.run_attempt,
                public=args.public,
            )
            print(f"Verified release bundle in {args.bundle}")
    except (OSError, ReleaseArtifactError) as error:
        print(f"release artifact rejected: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
