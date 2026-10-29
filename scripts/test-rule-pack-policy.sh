#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
temporary=$(mktemp -d "${TMPDIR:-/tmp}/flowlight-pack-policy.XXXXXX")
trap 'rm -rf "$temporary"' EXIT

python3 -I scripts/rule_pack_catalog.py validate rule-packs/official-source.json > "$temporary/valid-output"

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

echo "Rule-pack policy fixtures passed: reviewed collectors allowed, product and unreviewed hosts rejected."
