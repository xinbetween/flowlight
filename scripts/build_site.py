#!/usr/bin/env python3
"""Builds the static site in docs/ (GitHub Pages) from site/.

  site/site.css            shared stylesheet    → docs/assets/site.css
  site/partials/*.html     header and footer, included on every page
  site/pages/*.html        pages; a leading <!-- key: value --> block sets title, description, path, nav

Placeholders: {{root}} (relative path to the site root), {{repo}}, {{dmg}}, {{version}}, {{year}},
{{agents}}, {{providers}}, {{alerts}} (counted from the Swift source, so they can't drift),
{{current:<nav>}} (aria-current on the active nav link). Also writes sitemap.xml, robots.txt,
llms.txt, llms-full.txt and 404.html, and build/site-preview/index.html (self-contained home page).
"""
import os, re, sys, html, datetime, pathlib, hashlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SITE, OUT = ROOT / "site", ROOT / "docs"
DOMAIN = "https://flowlight.xinbetween.com"
REPO = os.environ.get("GITHUB_REPO", "xinbetween/flowlight")
DMG = f"https://github.com/{REPO}/releases/latest/download/Flowlight.dmg"
VERSION = re.search(r'MARKETING_VERSION:\s*"([^"]+)"', (ROOT / "project.yml").read_text()).group(1)


def counts():
    """Numbers the site quotes, read from the source that defines them.

    They were written by hand once and were wrong within two releases — the home page claimed 25 providers where
    the docs said 24 and the catalogue named 24. A count nobody has to remember to update can't drift.
    """
    catalog = (ROOT / "Shared/AgentCatalog.swift").read_text()
    providers = re.search(r"static let providers.*?= \[(.*?)\n    \]", catalog, re.S).group(1)
    engine = (ROOT / "Flowlight/Analysis/AnomalyEngine.swift").read_text()
    kinds = re.search(r"enum Kind: String.*?\{(.*?)\n    \}", engine, re.S).group(1)
    return {
        "agents": str(len(re.findall(r'KnownAgent\(name: "', catalog))),
        "providers": str(len({name for _, name in re.findall(r'\("([^"]+)",\s*"([^"]+)"\)', providers)})),
        "alerts": str(len(re.findall(r'case \w+ = "', kinds))),
    }


COUNTS = counts()
YEAR = str(datetime.date.today().year)
FONTS = ('<link rel="preconnect" href="https://fonts.googleapis.com">\n<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>\n'
         '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,500;12..96,700;12..96,800'
         '&family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans:wght@400;500;600&display=swap">')

def front_matter(text):
    m = re.match(r"\s*<!--(.*?)-->\s*", text, re.S)
    meta = dict(line.split(":", 1) for line in m.group(1).strip().splitlines() if ":" in line)
    return {k.strip(): v.strip() for k, v in meta.items()}, text[m.end():]

def fill(text, root, nav):
    text = re.sub(r"\{\{current:(\w+)\}\}", lambda m: ' aria-current="page"' if m.group(1) == nav else "", text)
    for k, v in {"root": root, "repo": REPO, "dmg": DMG, "version": VERSION, "year": YEAR, **COUNTS}.items():
        text = text.replace("{{%s}}" % k, v)
    # Screenshots keep their names across updates; a content hash makes caches fetch the new image.
    return re.sub(r'(assets/screenshots/[\w-]+\.png)"', lambda m: f'{m.group(1)}?v={asset_hash(m.group(1))}"', text)

def asset_hash(rel):
    return hashlib.sha256((OUT / rel).read_bytes()).hexdigest()[:8]

def document(meta, body, root, css_href, inline_css=None):
    title, desc, path = meta["title"], meta["description"], meta["path"]
    style = f"<style>{inline_css}</style>" if inline_css else f'<link rel="stylesheet" href="{css_href}">'
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>{html.escape(title)}</title>
<meta name="description" content="{html.escape(desc)}">
<link rel="canonical" href="{DOMAIN}{path}">
<meta property="og:title" content="{html.escape(title)}">
<meta property="og:description" content="{html.escape(desc)}">
<meta property="og:url" content="{DOMAIN}{path}">
<meta property="og:image" content="{DOMAIN}/assets/screenshots/agents.png">
<meta name="twitter:card" content="summary_large_image">
<link rel="icon" href="{root}assets/icon.png">
{FONTS}
{style}
</head>
<body>
{body}
</body>
</html>
"""

def build():
    css = (SITE / "site.css").read_text()
    header, footer = (SITE / "partials" / "header.html").read_text(), (SITE / "partials" / "footer.html").read_text()
    (OUT / "assets").mkdir(parents=True, exist_ok=True)
    (OUT / "assets" / "site.css").write_text(css)
    pages = []
    for src in sorted((SITE / "pages").glob("*.html")):
        meta, body = front_matter(src.read_text())
        depth = meta["path"].strip("/").count("/") + (1 if meta["path"].strip("/") else 0)
        root = "../" * depth if depth else ""
        full = fill(header + body + footer, root, meta.get("nav", ""))
        dest = OUT / meta["path"].strip("/") / "index.html" if meta["path"] != "/" else OUT / "index.html"
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(document(meta, full, root, f"{root}assets/site.css"))
        pages.append((meta, body))
        if meta["path"] == "/":
            # Self-contained preview for the claude.ai Artifact (no <html>/<head>; the host adds the skeleton).
            prev = ROOT / "build" / "site-preview"
            prev.mkdir(parents=True, exist_ok=True)
            pbody = fill(header + body + footer, "", "home")
            (prev / "index.html").write_text(f"<title>{meta['title']}</title>\n<meta name=\"description\" content=\"{html.escape(meta['description'])}\">\n{FONTS}\n<style>{css}</style>\n{pbody}")
        print(f"  {meta['path']:<12} → {dest.relative_to(ROOT)}")

    notfound = {"title": "Page not found · Flowlight", "description": "This page doesn't exist.", "path": "/404.html"}
    nf_body = fill(header + """<main id="main"><section class="page-head"><div class="wrap"><p class="eyebrow">404</p>
<h1>That page isn't here</h1><p class="lede">Try the <a href="/">home page</a>, the <a href="/docs/">docs</a> or the
<a href="/releases/">release notes</a>.</p></div></section></main>""" + footer, "/", "")
    (OUT / "404.html").write_text(document(notfound, nf_body, "/", "/assets/site.css"))

    urls = [DOMAIN + m["path"] for m, _ in pages]
    (OUT / "sitemap.xml").write_text('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        + "".join(f"  <url><loc>{u}</loc></url>\n" for u in urls) + "</urlset>\n")
    (OUT / "robots.txt").write_text(f"User-agent: *\nAllow: /\nSitemap: {DOMAIN}/sitemap.xml\n")

    # llms.txt: a short map; llms-full.txt: every page as plain text.
    def text_of(markup):
        markup = re.sub(r"<(script|style|svg)[\s\S]*?</\1>", "", markup)
        markup = re.sub(r"<br\s*/?>|</(p|li|h[1-6]|tr|div|pre|summary)>", "\n", markup)
        markup = re.sub(r"<[^>]+>", "", markup)
        markup = html.unescape(fill(markup, DOMAIN + "/", ""))
        return re.sub(r"\n\s*\n+", "\n\n", re.sub(r"[ \t]+", " ", markup)).strip()
    llms = [f"# Flowlight\n\n> Free, open-source (GPL-3.0) macOS network monitor. It attributes every TCP/UDP flow to the app that made it and the"
            f" domain it went to, keeps local history from second to year, and watches AI agents (including the tools and MCP servers they start)"
            f" with per-agent allowlists and rules for data leaving the Mac. It can also refuse, once asked: a rule blocks an app, a destination"
            f" or a URL for as long as you say, and a guardrail takes a tool away from an agent before its model is offered it."
            f" Current version: {VERSION}.\n",
            f"- [Download Flowlight.dmg]({DMG})", f"- [Source code](https://github.com/{REPO})"]
    llms += [f"- [{m['title']}]({DOMAIN}{m['path']}): {m['description']}" for m, _ in pages]
    llms += [f"- [Full text for LLMs]({DOMAIN}/llms-full.txt)"]
    (OUT / "llms.txt").write_text("\n".join(llms) + "\n")
    (OUT / "llms-full.txt").write_text("\n\n---\n\n".join(f"# {m['title']}\nURL: {DOMAIN}{m['path']}\n\n{text_of(b)}" for m, b in pages) + "\n")
    print(f"  + 404.html, sitemap.xml, robots.txt, llms.txt, llms-full.txt · version {VERSION}")

if __name__ == "__main__":
    build()
