#!/usr/bin/env python3
"""Record deterministic screenshot provenance for website and App Store assets."""

import argparse
import hashlib
import json
import pathlib
import struct


def png_size(path: pathlib.Path) -> tuple[int, int]:
    header = path.read_bytes()[:24]
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise ValueError(f"{path} is not a PNG with an IHDR header")
    return struct.unpack(">II", header[16:24])


def load_entries(path: pathlib.Path) -> dict[str, dict]:
    if not path.exists():
        return {}
    document = json.loads(path.read_text())
    if document.get("schema") != 1 or not isinstance(document.get("screenshots"), dict):
        raise ValueError(f"{path} has an unsupported screenshot manifest shape")
    return document["screenshots"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=pathlib.Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--replace", action="store_true")
    parser.add_argument("files", nargs="+")
    args = parser.parse_args()

    manifest = args.directory / "manifest.json"
    entries = {} if args.replace else load_entries(manifest)
    for name in args.files:
        if pathlib.Path(name).name != name or not name.endswith(".png"):
            raise ValueError(f"unsafe screenshot name: {name}")
        image = args.directory / name
        data = image.read_bytes()
        width, height = png_size(image)
        entries[name] = {
            "version": args.version,
            "sha256": hashlib.sha256(data).hexdigest(),
            "width": width,
            "height": height,
        }

    document = {"schema": 1, "screenshots": dict(sorted(entries.items()))}
    temporary = manifest.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    temporary.replace(manifest)
    print(f"Recorded {len(args.files)} screenshot(s) for Flowlight {args.version} in {manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
