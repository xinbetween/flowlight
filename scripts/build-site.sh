#!/bin/zsh
# Builds the website into docs/ (GitHub Pages). See scripts/build_site.py.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/build_site.py
