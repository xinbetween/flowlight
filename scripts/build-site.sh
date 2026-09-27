#!/bin/zsh
# Builds the website into docs/ (GitHub Pages), then checks it. See scripts/build_site.py and check_site.py.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/build_site.py
python3 scripts/check_site.py
