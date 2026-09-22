#!/bin/zsh
# Wraps site/page.html (head part, then "<!-- /head -->", then body) into docs/index.html for GitHub Pages.
# Set GITHUB_REPO=owner/flowlight to point the download and source links at a fork.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="${GITHUB_REPO:-xinbetween/flowlight}"
OWNER="${REPO%%/*}"
python3 - "$REPO" "$OWNER" <<'PY'
import sys
repo, owner = sys.argv[1], sys.argv[2]
page = open("site/page.html").read().replace("YOUR_GITHUB_USER/flowlight", repo).replace("YOUR_GITHUB_USER", owner)
head, body = page.split("<!-- /head -->", 1)
html = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta property="og:title" content="Flowlight: every app, every domain, every agent">
<meta property="og:description" content="Free, open-source macOS network monitor with AI agent oversight.">
<meta property="og:image" content="https://flowlight.xinbetween.com/assets/screenshots/agents.png">
<meta property="og:url" content="https://flowlight.xinbetween.com/">
<link rel="canonical" href="https://flowlight.xinbetween.com/">
<link rel="icon" href="assets/icon.png">
{head.strip()}
</head>
<body>
{body.strip()}
</body>
</html>
"""
open("docs/index.html", "w").write(html)
print(f"docs/index.html written ({len(html)//1024} KB) for {repo}")
PY
