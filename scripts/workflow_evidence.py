#!/usr/bin/env python3
"""Create and verify CI reuse receipts and trusted Pages payloads."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import io
import json
import pathlib
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from dataclasses import dataclass
from typing import Any, Iterable


REVIEW_SCHEMA = "flowlight-review-v3"
PAGES_SCHEMA = "flowlight-pages-v1"
CI_WORKFLOW = ".github/workflows/ci.yml"
SHA = re.compile(r"[0-9a-f]{40}")
SHA256 = re.compile(r"[0-9a-f]{64}")
REQUIRED_CONCLUSIONS = {
    "changes": "success",
    "site": "success",
    "project_drift": "success",
    "unit_oldest": "success",
    "unit_newest": "success",
    "store": "success",
    "merge_compatibility": "success",
}


class EvidenceError(ValueError):
    """Evidence is absent, malformed, stale, or bound to another identity."""


@dataclass(frozen=True)
class ReuseExpectation:
    repository: str
    source_sha: str
    source_tree: str
    app_fingerprint: str
    current_run_id: int
    workflow: str = CI_WORKFLOW
    schema: str = REVIEW_SCHEMA
    base_branch: str = "main"


def _object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise EvidenceError(f"{label} has an unexpected shape")
    return value


def _positive_int(value: Any, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise EvidenceError(f"{label} is missing or malformed")
    return value


def _exact_sha(value: Any, label: str) -> str:
    if not isinstance(value, str) or not SHA.fullmatch(value):
        raise EvidenceError(f"{label} is missing or malformed")
    return value


def _digest(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.startswith("sha256:") or not SHA256.fullmatch(value[7:]):
        raise EvidenceError(f"{label} is missing or malformed")
    return value


def _timestamp(value: Any, label: str) -> dt.datetime:
    if not isinstance(value, str):
        raise EvidenceError(f"{label} is missing or malformed")
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise EvidenceError(f"{label} is missing or malformed") from error
    if parsed.tzinfo is None:
        raise EvidenceError(f"{label} has no timezone")
    return parsed


def _safe_path(raw: Any, label: str) -> pathlib.PurePosixPath:
    if not isinstance(raw, str) or not raw or raw.startswith("/") or "\\" in raw:
        raise EvidenceError(f"{label} is unsafe")
    if any(part in {"", ".", ".."} for part in raw.split("/")):
        raise EvidenceError(f"{label} is unsafe")
    path = pathlib.PurePosixPath(raw)
    if path.as_posix() != raw:
        raise EvidenceError(f"{label} is not canonical")
    return path


def _require_fields(document: dict[str, Any], expected: set[str], label: str) -> None:
    if set(document) != expected:
        raise EvidenceError(f"{label} fields do not match the schema")


def trusted_pr_run(run: Any, expected: ReuseExpectation) -> dict[str, Any]:
    run = _object(run, "workflow run")
    checks = {
        "repository": (_object(run.get("repository"), "workflow run repository").get("full_name"), expected.repository),
        "workflow": (run.get("path"), expected.workflow),
        "event": (run.get("event"), "pull_request"),
        "head repository": (
            _object(run.get("head_repository"), "workflow run head repository").get("full_name"),
            expected.repository,
        ),
    }
    for label, (actual, wanted) in checks.items():
        if actual != wanted:
            raise EvidenceError(f"workflow run {label} is {actual!r}, expected {wanted!r}")
    _positive_int(run.get("id"), "workflow run ID")
    _positive_int(run.get("run_attempt"), "workflow run attempt")
    head_sha = _exact_sha(run.get("head_sha"), "workflow run source SHA")

    pull_requests = run.get("pull_requests")
    if not isinstance(pull_requests, list) or len(pull_requests) != 1:
        raise EvidenceError("workflow run is not bound to exactly one pull request")
    pull_request = _object(pull_requests[0], "workflow run pull request")
    _positive_int(pull_request.get("number"), "workflow run pull request number")
    head = _object(pull_request.get("head"), "workflow run pull request head")
    base = _object(pull_request.get("base"), "workflow run pull request base")
    if _exact_sha(head.get("sha"), "workflow run pull request head SHA") != head_sha:
        raise EvidenceError("workflow run pull request head does not match the run source SHA")
    if _object(head.get("repo"), "workflow run pull request head repository").get("full_name") != expected.repository:
        raise EvidenceError("workflow run pull request head repository is not trusted")
    if base.get("ref") != expected.base_branch:
        raise EvidenceError(
            f"workflow run pull request base is {base.get('ref')!r}, expected {expected.base_branch!r}"
        )
    _exact_sha(base.get("sha"), "workflow run pull request base SHA")
    if _object(base.get("repo"), "workflow run pull request base repository").get("full_name") != expected.repository:
        raise EvidenceError("workflow run pull request base repository is not trusted")
    return run


def select_exact_tree_run(
    runs: Iterable[Any], trees_by_sha: dict[str, str], expected: ReuseExpectation
) -> dict[str, Any] | None:
    """Select the newest trusted exact-tree run, including a newer failed run."""
    candidates: list[dict[str, Any]] = []
    for raw in runs:
        try:
            run = trusted_pr_run(raw, expected)
        except EvidenceError:
            continue
        if run["id"] == expected.current_run_id:
            continue
        if trees_by_sha.get(run["head_sha"]) != expected.source_tree:
            continue
        candidates.append(run)
    if not candidates:
        return None
    return max(candidates, key=lambda run: (run["id"], run["run_attempt"]))


def validate_artifact(
    artifact: Any,
    *,
    run_id: int,
    expected_name: str,
    archive_digest: str,
    now: dt.datetime | None = None,
) -> dict[str, Any]:
    artifact = _object(artifact, "artifact")
    if artifact.get("name") != expected_name:
        raise EvidenceError(f"artifact name is {artifact.get('name')!r}, expected {expected_name!r}")
    if artifact.get("expired") is not False:
        raise EvidenceError("artifact is expired")
    now = now or dt.datetime.now(dt.timezone.utc)
    if _timestamp(artifact.get("expires_at"), "artifact expiry") <= now:
        raise EvidenceError("artifact has no remaining retention")
    if _object(artifact.get("workflow_run"), "artifact workflow run").get("id") != run_id:
        raise EvidenceError("artifact is not attached to the selected workflow run")
    _positive_int(artifact.get("id"), "artifact ID")
    if not isinstance(artifact.get("size_in_bytes"), int) or artifact["size_in_bytes"] <= 0:
        raise EvidenceError("artifact is empty or has a malformed size")
    metadata_digest = _digest(artifact.get("digest"), "artifact digest")
    if metadata_digest != _digest(archive_digest, "downloaded artifact digest"):
        raise EvidenceError("downloaded artifact digest does not match API metadata")
    return artifact


def validate_reuse_evidence(
    run: Any,
    artifact: Any,
    receipt: Any,
    expected: ReuseExpectation,
    archive_digest: str,
    *,
    now: dt.datetime | None = None,
) -> dict[str, Any]:
    run = trusted_pr_run(run, expected)
    if run.get("status") != "completed" or run.get("conclusion") != "success":
        raise EvidenceError("newest exact-tree workflow run is not completed successfully")
    run_id = run["id"]
    run_attempt = run["run_attempt"]
    expected_name = f"review-receipt-{run['head_sha']}-{run_attempt}"
    artifact = validate_artifact(
        artifact,
        run_id=run_id,
        expected_name=expected_name,
        archive_digest=archive_digest,
        now=now,
    )
    receipt = _object(receipt, "review receipt")
    _require_fields(
        receipt,
        {
            "schema", "repository", "workflow", "event", "source_sha", "source_tree",
            "app_fingerprint", "app_route", "conclusions", "run_id", "run_attempt", "app_evidence",
        },
        "review receipt",
    )
    identity = {
        "schema": (receipt.get("schema"), expected.schema),
        "repository": (receipt.get("repository"), expected.repository),
        "workflow": (receipt.get("workflow"), expected.workflow),
        "event": (receipt.get("event"), "pull_request"),
        "source SHA": (receipt.get("source_sha"), run["head_sha"]),
        "source tree": (receipt.get("source_tree"), expected.source_tree),
        "app fingerprint": (receipt.get("app_fingerprint"), expected.app_fingerprint),
        "app route": (receipt.get("app_route"), True),
        "run ID": (receipt.get("run_id"), run_id),
        "run attempt": (receipt.get("run_attempt"), run_attempt),
    }
    for label, (actual, wanted) in identity.items():
        if actual != wanted:
            raise EvidenceError(f"review receipt {label} is {actual!r}, expected {wanted!r}")
    conclusions = _object(receipt.get("conclusions"), "review receipt conclusions")
    if conclusions != REQUIRED_CONCLUSIONS:
        raise EvidenceError("review receipt does not contain every required successful app-job conclusion")
    app_evidence = _object(receipt.get("app_evidence"), "review receipt app evidence")
    if app_evidence != {"mode": "executed", "source": None}:
        raise EvidenceError("review receipt is not direct executed app evidence")
    return {
        "run_id": run_id,
        "run_attempt": run_attempt,
        "artifact_id": artifact["id"],
        "artifact_name": artifact["name"],
        "artifact_digest": artifact["digest"],
    }


def pages_manifest(root: pathlib.Path, repository: str, source_sha: str, source_tree: str) -> dict[str, Any]:
    _exact_sha(source_sha, "Pages source SHA")
    _exact_sha(source_tree, "Pages source tree")
    if not root.is_dir() or root.is_symlink():
        raise EvidenceError("Pages payload root is not a regular directory")
    files = []
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        _safe_path(relative, "Pages payload path")
        if path.is_symlink():
            raise EvidenceError(f"Pages payload contains a symlink: {relative}")
        if path.is_dir():
            continue
        if not path.is_file():
            raise EvidenceError(f"Pages payload contains a non-file: {relative}")
        info = path.stat(follow_symlinks=False)
        files.append({
            "path": relative,
            "mode": stat.S_IMODE(info.st_mode),
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        })
    if not files:
        raise EvidenceError("Pages payload is empty")
    return {
        "schema": PAGES_SCHEMA,
        "repository": repository,
        "source_sha": source_sha,
        "source_tree": source_tree,
        "files": files,
    }


def create_pages_bundle(
    root: pathlib.Path,
    output: pathlib.Path,
    repository: str,
    source_sha: str,
    source_tree: str,
) -> dict[str, Any]:
    manifest = pages_manifest(root, repository, source_sha, source_tree)
    manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(output, "w", format=tarfile.PAX_FORMAT) as archive:
        records = [("manifest.json", manifest_bytes, 0o644)]
        records += [
            (f"site/{record['path']}", (root / record["path"]).read_bytes(), record["mode"])
            for record in manifest["files"]
        ]
        for name, data, mode in records:
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = mode
            info.mtime = info.uid = info.gid = 0
            info.uname = info.gname = ""
            archive.addfile(info, io.BytesIO(data))
    return manifest


def _tar_members(bundle: pathlib.Path) -> tuple[dict[str, Any], dict[str, tuple[bytes, int]]]:
    manifest: dict[str, Any] | None = None
    payload: dict[str, tuple[bytes, int]] = {}
    seen: set[str] = set()
    try:
        archive = tarfile.open(bundle, "r:")
    except (OSError, tarfile.TarError) as error:
        raise EvidenceError("Pages bundle is not a readable uncompressed tar archive") from error
    with archive:
        for member in archive:
            path = _safe_path(member.name, "Pages archive path").as_posix()
            if path in seen:
                raise EvidenceError(f"Pages archive contains a duplicate path: {path}")
            seen.add(path)
            if not member.isfile() or member.issym() or member.islnk():
                raise EvidenceError(f"Pages archive contains a non-regular entry: {path}")
            extracted = archive.extractfile(member)
            if extracted is None:
                raise EvidenceError(f"Pages archive entry cannot be read: {path}")
            data = extracted.read()
            if path == "manifest.json":
                try:
                    value = json.loads(data)
                except (UnicodeDecodeError, json.JSONDecodeError) as error:
                    raise EvidenceError("Pages manifest is not valid JSON") from error
                manifest = _object(value, "Pages manifest")
            elif path.startswith("site/") and len(path) > len("site/"):
                relative = path[len("site/"):]
                _safe_path(relative, "Pages payload path")
                payload[relative] = (data, member.mode)
            else:
                raise EvidenceError(f"Pages archive contains an unexpected path: {path}")
    if manifest is None:
        raise EvidenceError("Pages archive has no manifest")
    return manifest, payload


def verify_pages_bundle(
    bundle: pathlib.Path,
    output: pathlib.Path,
    *,
    repository: str,
    source_sha: str,
    source_tree: str,
) -> dict[str, Any]:
    manifest, payload = _tar_members(bundle)
    _require_fields(manifest, {"schema", "repository", "source_sha", "source_tree", "files"}, "Pages manifest")
    identity = {
        "schema": (manifest.get("schema"), PAGES_SCHEMA),
        "repository": (manifest.get("repository"), repository),
        "source SHA": (manifest.get("source_sha"), source_sha),
        "source tree": (manifest.get("source_tree"), source_tree),
    }
    for label, (actual, wanted) in identity.items():
        if actual != wanted:
            raise EvidenceError(f"Pages manifest {label} is {actual!r}, expected {wanted!r}")
    records = manifest.get("files")
    if not isinstance(records, list) or not records:
        raise EvidenceError("Pages manifest file list is missing or empty")
    expected_paths: list[str] = []
    for record in records:
        record = _object(record, "Pages manifest file")
        _require_fields(record, {"path", "mode", "sha256"}, "Pages manifest file")
        path = _safe_path(record.get("path"), "Pages manifest path").as_posix()
        if path in expected_paths:
            raise EvidenceError(f"Pages manifest repeats a path: {path}")
        expected_paths.append(path)
        if not isinstance(record.get("mode"), int) or record["mode"] < 0 or record["mode"] > 0o777:
            raise EvidenceError(f"Pages manifest mode is malformed for {path}")
        if not isinstance(record.get("sha256"), str) or not SHA256.fullmatch(record["sha256"]):
            raise EvidenceError(f"Pages manifest digest is malformed for {path}")
        item = payload.get(path)
        if item is None:
            raise EvidenceError(f"Pages payload is missing {path}")
        data, mode = item
        if mode != record["mode"]:
            raise EvidenceError(f"Pages payload mode changed for {path}")
        if hashlib.sha256(data).hexdigest() != record["sha256"]:
            raise EvidenceError(f"Pages payload digest changed for {path}")
    if expected_paths != sorted(expected_paths):
        raise EvidenceError("Pages manifest paths are not deterministically sorted")
    extra = sorted(set(payload) - set(expected_paths))
    if extra:
        raise EvidenceError(f"Pages payload contains an unmanifested file: {extra[0]}")
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        raise EvidenceError("Pages output directory is not empty")
    output.mkdir(parents=True, exist_ok=True)
    for path in expected_paths:
        data, mode = payload[path]
        destination = output.joinpath(*pathlib.PurePosixPath(path).parts)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        destination.chmod(mode)
    return manifest


def validate_pages_source(run: Any, *, repository: str, current_main_sha: str) -> dict[str, Any]:
    run = _object(run, "Pages source workflow run")
    checks = {
        "repository": (_object(run.get("repository"), "Pages source repository").get("full_name"), repository),
        "head repository": (_object(run.get("head_repository"), "Pages source head repository").get("full_name"), repository),
        "workflow": (run.get("path"), CI_WORKFLOW),
        "event": (run.get("event"), "push"),
        "branch": (run.get("head_branch"), "main"),
        "status": (run.get("status"), "completed"),
        "conclusion": (run.get("conclusion"), "success"),
    }
    for label, (actual, wanted) in checks.items():
        if actual != wanted:
            raise EvidenceError(f"Pages source {label} is {actual!r}, expected {wanted!r}")
    _positive_int(run.get("id"), "Pages source run ID")
    _positive_int(run.get("run_attempt"), "Pages source run attempt")
    source_sha = _exact_sha(run.get("head_sha"), "Pages source SHA")
    if source_sha != _exact_sha(current_main_sha, "current main SHA"):
        raise EvidenceError("Pages source is stale because main has advanced")
    return run


def artifact_from_response(document: Any, expected_name: str) -> dict[str, Any]:
    document = _object(document, "artifact response")
    artifacts = document.get("artifacts")
    if not isinstance(artifacts, list):
        raise EvidenceError("artifact response has an unexpected shape")
    matches = [artifact for artifact in artifacts if isinstance(artifact, dict) and artifact.get("name") == expected_name]
    if len(matches) != 1:
        raise EvidenceError(f"expected exactly one artifact named {expected_name!r}, found {len(matches)}")
    return matches[0]


def receipt_from_artifact_zip(path: pathlib.Path) -> dict[str, Any]:
    try:
        archive = zipfile.ZipFile(path)
    except (OSError, zipfile.BadZipFile) as error:
        raise EvidenceError("review artifact is not a readable zip archive") from error
    with archive:
        files = []
        for info in archive.infolist():
            name = _safe_path(info.filename, "review artifact path").as_posix()
            file_type = (info.external_attr >> 16) & 0o170000
            if info.is_dir() or file_type not in {0, stat.S_IFREG}:
                raise EvidenceError(f"review artifact contains a non-regular entry: {name}")
            files.append((name, info))
        if len(files) != 1 or files[0][0] != "review-receipt.json":
            raise EvidenceError("review artifact must contain only review-receipt.json")
        try:
            value = json.loads(archive.read(files[0][1]))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise EvidenceError("review receipt is not valid JSON") from error
    return _object(value, "review receipt")


def artifact_file_from_zip(path: pathlib.Path, output: pathlib.Path, expected_name: str) -> None:
    try:
        archive = zipfile.ZipFile(path)
    except (OSError, zipfile.BadZipFile) as error:
        raise EvidenceError("artifact is not a readable zip archive") from error
    with archive:
        files = []
        for info in archive.infolist():
            name = _safe_path(info.filename, "artifact archive path").as_posix()
            file_type = (info.external_attr >> 16) & 0o170000
            if info.is_dir() or file_type not in {0, stat.S_IFREG}:
                raise EvidenceError(f"artifact archive contains a non-regular entry: {name}")
            files.append((name, info))
        if len(files) != 1 or files[0][0] != expected_name:
            raise EvidenceError(f"artifact archive must contain only {expected_name}")
        output.write_bytes(archive.read(files[0][1]))


def _gh_json(endpoint: str) -> Any:
    result = subprocess.run(
        ["gh", "api", endpoint], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )
    return json.loads(result.stdout)


def _gh_download(endpoint: str, output: pathlib.Path) -> str:
    with output.open("wb") as stream:
        subprocess.run(["gh", "api", endpoint], check=True, stdout=stream, stderr=subprocess.PIPE)
    return f"sha256:{hashlib.sha256(output.read_bytes()).hexdigest()}"


def _write_outputs(path: pathlib.Path, values: dict[str, Any]) -> None:
    with path.open("a", encoding="utf-8") as stream:
        for key, value in values.items():
            text = "" if value is None else str(value)
            if "\n" in text or "\r" in text:
                raise EvidenceError(f"output {key} is multiline")
            stream.write(f"{key}={text}\n")


def find_reuse(args: argparse.Namespace) -> int:
    expected = ReuseExpectation(
        repository=args.repository,
        source_sha=_exact_sha(args.source_sha, "current source SHA"),
        source_tree=_exact_sha(args.source_tree, "current source tree"),
        app_fingerprint=_digest(f"sha256:{args.app_fingerprint}", "current app fingerprint")[7:],
        current_run_id=args.current_run_id,
    )
    empty = {
        "reuse": "false", "source_run_id": None, "source_run_attempt": None,
        "source_artifact_id": None, "source_artifact_name": None, "source_artifact_digest": None,
    }
    try:
        response = _gh_json(
            f"repos/{expected.repository}/actions/workflows/ci.yml/runs"
            "?event=pull_request&status=completed&per_page=100"
        )
        runs = _object(response, "workflow-run response").get("workflow_runs")
        if not isinstance(runs, list):
            raise EvidenceError("workflow-run response has an unexpected shape")
        trees: dict[str, str] = {}
        for raw in runs:
            try:
                run = trusted_pr_run(raw, expected)
            except EvidenceError:
                continue
            sha = run["head_sha"]
            if sha not in trees:
                commit = _gh_json(f"repos/{expected.repository}/git/commits/{sha}")
                trees[sha] = _exact_sha(_object(commit.get("tree"), "commit tree").get("sha"), "commit tree")
        selected = select_exact_tree_run(runs, trees, expected)
        if selected is None:
            raise EvidenceError("no prior trusted pull-request run has the exact current Git tree")
        if selected.get("status") != "completed" or selected.get("conclusion") != "success":
            raise EvidenceError("newest exact-tree workflow run is not completed successfully")
        name = f"review-receipt-{selected['head_sha']}-{selected['run_attempt']}"
        artifacts = _gh_json(f"repos/{expected.repository}/actions/runs/{selected['id']}/artifacts?per_page=100")
        artifact = artifact_from_response(artifacts, name)
        with tempfile.TemporaryDirectory() as temporary:
            archive = pathlib.Path(temporary) / "receipt.zip"
            archive_digest = _gh_download(
                f"repos/{expected.repository}/actions/artifacts/{artifact.get('id')}/zip", archive
            )
            receipt = receipt_from_artifact_zip(archive)
        identity = validate_reuse_evidence(selected, artifact, receipt, expected, archive_digest)
    except (EvidenceError, OSError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"No reusable app evidence: {error}")
        _write_outputs(args.github_output, empty)
        return 0
    print(
        f"Reusing directly executed app evidence from run {identity['run_id']} "
        f"attempt {identity['run_attempt']} artifact {identity['artifact_id']}."
    )
    _write_outputs(args.github_output, {
        "reuse": "true",
        "source_run_id": identity["run_id"],
        "source_run_attempt": identity["run_attempt"],
        "source_artifact_id": identity["artifact_id"],
        "source_artifact_name": identity["artifact_name"],
        "source_artifact_digest": identity["artifact_digest"],
    })
    return 0


def create_pages(args: argparse.Namespace) -> int:
    manifest = create_pages_bundle(
        args.root.resolve(), args.output.resolve(), args.repository, args.source_sha, args.source_tree
    )
    print(f"Created deterministic Pages bundle with {len(manifest['files'])} files.")
    return 0


def consume_pages(args: argparse.Namespace) -> int:
    event = _object(json.loads(args.event_json.read_text()), "workflow_run event")
    run = _object(event.get("workflow_run"), "workflow_run event source")
    main = _gh_json(f"repos/{args.repository}/git/ref/heads/main")
    current_main = _object(main.get("object"), "main ref object").get("sha")
    run = validate_pages_source(run, repository=args.repository, current_main_sha=current_main)
    commit = _gh_json(f"repos/{args.repository}/git/commits/{run['head_sha']}")
    source_tree = _exact_sha(_object(commit.get("tree"), "Pages source commit tree").get("sha"), "Pages source tree")
    name = f"pages-site-{run['head_sha']}-{run['run_attempt']}"
    response = _gh_json(f"repos/{args.repository}/actions/runs/{run['id']}/artifacts?per_page=100")
    artifact = artifact_from_response(response, name)
    with tempfile.TemporaryDirectory() as temporary:
        archive = pathlib.Path(temporary) / "pages.zip"
        bundle = pathlib.Path(temporary) / "pages-payload.tar"
        archive_digest = _gh_download(f"repos/{args.repository}/actions/artifacts/{artifact.get('id')}/zip", archive)
        validate_artifact(artifact, run_id=run["id"], expected_name=name, archive_digest=archive_digest)
        artifact_file_from_zip(archive, bundle, "pages-payload.tar")
        verify_pages_bundle(
            bundle,
            args.output.resolve(),
            repository=args.repository,
            source_sha=run["head_sha"],
            source_tree=source_tree,
        )
    if args.github_output:
        _write_outputs(args.github_output, {
            "source_sha": run["head_sha"],
            "source_tree": source_tree,
            "source_run_id": run["id"],
            "source_artifact_id": artifact["id"],
            "source_artifact_digest": artifact["digest"],
        })
    print(f"Verified Pages artifact {artifact['id']} from source run {run['id']} at current main.")
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    reuse = commands.add_parser("find-reuse")
    reuse.add_argument("--repository", required=True)
    reuse.add_argument("--source-sha", required=True)
    reuse.add_argument("--source-tree", required=True)
    reuse.add_argument("--app-fingerprint", required=True)
    reuse.add_argument("--current-run-id", required=True, type=int)
    reuse.add_argument("--github-output", required=True, type=pathlib.Path)
    reuse.set_defaults(function=find_reuse)
    create = commands.add_parser("create-pages")
    create.add_argument("--root", required=True, type=pathlib.Path)
    create.add_argument("--output", required=True, type=pathlib.Path)
    create.add_argument("--repository", required=True)
    create.add_argument("--source-sha", required=True)
    create.add_argument("--source-tree", required=True)
    create.set_defaults(function=create_pages)
    consume = commands.add_parser("consume-pages")
    consume.add_argument("--event-json", required=True, type=pathlib.Path)
    consume.add_argument("--repository", required=True)
    consume.add_argument("--output", required=True, type=pathlib.Path)
    consume.add_argument("--github-output", type=pathlib.Path)
    consume.set_defaults(function=consume_pages)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        return args.function(args)
    except (EvidenceError, OSError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"workflow evidence failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
