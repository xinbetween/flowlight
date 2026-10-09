#!/usr/bin/env python3
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
KINDS = {"traffic", "llmMCP"}
SOURCES = {"builtIn", "installed"}
PUBLISHERS = {"official", "thirdParty"}
PROVIDERS = {"flowlight", "presidio", "bedrock", "lakera", "aporia", "noma", "prismaAIRS", "custom"}
CAPABILITIES = {"annotate", "suggestGuardrail"}
SEVERITIES = {"info", "low", "medium", "high"}
SECRET_RE = re.compile(r"(sk-[A-Za-z0-9_-]{8,}|bearer\s+\S+|api[_-]?key\s*[:=]|secret\s*[:=]|token\s*[:=])", re.I)


def load(name):
    return json.loads((ROOT / name).read_text())


def fail(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def require(condition, message):
    if not condition:
        fail(message)


def check_manifest(manifest):
    for key in ["id", "name", "version", "kind", "source", "publisher", "guardrailProvider", "description", "privacySummary", "capabilities"]:
        require(key in manifest, f"manifest missing {key}")
    require(manifest["kind"] in KINDS, "manifest kind must be traffic or llmMCP")
    require(manifest["source"] in SOURCES, "manifest source must be builtIn or installed")
    require(manifest["publisher"] in PUBLISHERS, "manifest publisher must be official or thirdParty")
    require(manifest["guardrailProvider"] in PROVIDERS, "unsupported guardrailProvider")
    require(set(manifest["capabilities"]).issubset(CAPABILITIES), "unsupported capability")
    require(len(manifest["privacySummary"]) <= 500, "privacySummary should stay concise")


def check_findings(findings):
    require(isinstance(findings, list), "findings.example.json must be an array")
    for i, finding in enumerate(findings):
        require(finding.get("severity") in SEVERITIES, f"finding {i} has unsupported severity")
        for key in ["title", "summary", "evidence"]:
            require(key in finding, f"finding {i} missing {key}")
        require(len(finding["title"]) <= 120, f"finding {i} title is too long")
        require(len(finding["summary"]) <= 500, f"finding {i} summary is too long")
        require(isinstance(finding["evidence"], list) and len(finding["evidence"]) <= 8, f"finding {i} evidence must be a short array")
        text = json.dumps(finding, ensure_ascii=False)
        require(not SECRET_RE.search(text), f"finding {i} appears to contain a secret-like value")
        for evidence in finding["evidence"]:
            require(len(evidence.get("label", "")) <= 80, f"finding {i} evidence label is too long")
            require(len(evidence.get("value", "")) <= 240, f"finding {i} evidence value is too long")


def main():
    check_manifest(load("manifest.json"))
    check_findings(load("findings.example.json"))
    print("ok")


if __name__ == "__main__":
    main()
