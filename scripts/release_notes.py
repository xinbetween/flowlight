#!/usr/bin/env python3
"""Prints the Markdown release notes for one version, read from site/pages/releases.html.

The notes are written once, on the releases page, and this turns that entry into what GitHub shows and what the
Software Update window reads. Keeping a second copy by hand is how every release from 0.6.5 on shipped with an
empty update window: the workflow fell back to generated notes, which are one "Full Changelog" link.

    scripts/release_notes.py 0.7.1
"""
import html, re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
REPO = "xinbetween/flowlight"


def entry(version):
    page = (ROOT / "site" / "pages" / "releases.html").read_text()
    sections = re.findall(r'<section class="release">(.*?)</section>', page, re.S)
    for body in sections:
        heading = re.search(r"<h2>([^<]+)</h2>", body)
        if heading and heading.group(1).strip() == version:
            return body
    raise SystemExit(f"No entry for {version} in site/pages/releases.html")


def markdown(body):
    items = re.findall(r"<li>(.*?)</li>", body, re.S)
    lines = []
    for item in items:
        text = re.sub(r"<a [^>]*>(.*?)</a>", r"\1", item, flags=re.S)
        text = re.sub(r"<strong>(.*?)</strong>", r"**\1**", text, flags=re.S)
        text = re.sub(r"<kbd>(.*?)</kbd>", r"`\1`", text, flags=re.S)
        text = re.sub(r"<[^>]+>", "", text)
        text = html.unescape(re.sub(r"\s+", " ", text)).strip()
        # The site links to its own pages; the notes are read where those are a click away anyway.
        text = re.sub(r"\s*(Read the documentation|How rules work|About Ask)\s*→\s*$", "", text).strip()
        if text:
            lines.append(f"- {text}")
    return lines


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: release_notes.py <version>")
    version = sys.argv[1]
    lines = markdown(entry(version))
    if not lines:
        raise SystemExit(f"The {version} entry has no list items to publish")
    out = [f"### What's new in {version}", ""] + lines + [
        "",
        "### Install",
        "",
        "Signed with Developer ID and notarized by Apple.",
        "",
        f"- `brew install --cask xinbetween/tap/flowlight`",
        f"- `Flowlight.dmg` — drag to Applications.",
        f"- `Flowlight-{version}.pkg` — installs to /Applications; offers to quit a running copy first.",
        "",
        "macOS 15 or later, Apple silicon and Intel.",
        "",
        f"Full changelog: https://github.com/{REPO}/releases",
    ]
    print("\n".join(out))


if __name__ == "__main__":
    main()
