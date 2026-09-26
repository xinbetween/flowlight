#!/usr/bin/env python3
"""Builds the static site in docs/ (GitHub Pages) from site/.

  site/site.css            shared stylesheet    → docs/assets/site.css
  site/partials/*.html     header and footer, included on every page
  site/pages/*.html        English pages; a leading <!-- key: value --> block sets title, description, path, nav
  site/pages/<lang>/*.html translations of those pages, same file name, served under /<lang>/
  site/i18n/<lang>.json    the strings in the header, footer and 404 page, keyed the same in every language

English stays at the root, so every URL that is already indexed keeps working. A translation of
site/pages/docs.html placed at site/pages/ja/docs.html is published at /ja/docs/, and adding a language
means adding those files — nothing here lists the languages.

Placeholders: {{root}} (relative path to the site root, for assets), {{link:<page>}} (relative link to that
page in the current language, falling back to English where there is no translation), {{t:<key>}} (a string
from site/i18n), {{langpicker}}, {{repo}}, {{dmg}}, {{version}}, {{year}}, {{agents}}, {{providers}},
{{alerts}} (counted from the Swift source, so they can't drift), {{current:<nav>}} (aria-current on the
active nav link). Also writes sitemap.xml, robots.txt, llms.txt, llms-full.txt and 404.html, and
build/site-preview/index.html (self-contained home page).
"""
import os, re, sys, html, json, datetime, pathlib, hashlib, subprocess

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

GLOBE = ('<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" aria-hidden="true">'
         '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.5 2.6 2.5 15.4 0 18M12 3c-2.5 2.6-2.5 15.4 0 18"/></svg>')


# ---- Languages and their strings -------------------------------------------------------------------------
#
# The set of languages is the set of directories under site/pages/, and each one's own name is a string in its
# own file. Nothing in this script names a language, so adding one is adding files.

def languages():
    extra = sorted(p.name for p in (SITE / "pages").iterdir()
                   if p.is_dir() and not p.name.startswith(".") and any(p.glob("*.html")))
    return ["en"] + extra


def strings(langs):
    table = {}
    for lang in langs:
        path = SITE / "i18n" / f"{lang}.json"
        if not path.exists():
            if lang == "en":
                sys.exit("site/i18n/en.json is missing: it holds the English header, footer and 404 strings.")
            sys.exit(f"site/pages/{lang}/ exists but site/i18n/{lang}.json does not. "
                     f"Copy site/i18n/en.json, translate the values, and keep the keys.")
        table[lang] = json.loads(path.read_text())
    missing = {lang: sorted(set(table["en"]) - set(v)) for lang, v in table.items()}
    for lang, keys in missing.items():
        if keys:
            print(f"  ! {lang}: {len(keys)} string(s) not translated, English used: {', '.join(keys)}")
    # The copy button's two labels end up inside a JavaScript string literal in the footer.
    for lang, v in table.items():
        for key in ("copy.copy", "copy.copied"):
            if '"' in v.get(key, ""):
                sys.exit(f'site/i18n/{lang}.json: {key} cannot contain a double quote.')
    return table


# ---- Paths and links -------------------------------------------------------------------------------------

def up(path):
    """The relative path from a published page back to the site root: the {{root}} every page already uses."""
    return "../" * len([s for s in path.strip("/").split("/") if s])


def href(frm, to):
    """A relative href from one published page to another, by way of the site root.

    Going through the root rather than computing the shortest path keeps the English pages byte-for-byte what
    they were when every link was written as {{root}}docs/, and it is the same arithmetic in every language.
    """
    return up(frm) + (to.strip("/") + "/" if to.strip("/") else "")


def localized(path, lang):
    return path if lang == "en" else f"/{lang}" + path


def front_matter(text):
    m = re.match(r"\s*<!--(.*?)-->\s*", text, re.S)
    meta = dict(line.split(":", 1) for line in m.group(1).strip().splitlines() if ":" in line)
    return {k.strip(): v.strip() for k, v in meta.items()}, text[m.end():]


def fill(text, ctx):
    text = re.sub(r"\{\{current:(\w+)\}\}", lambda m: ' aria-current="page"' if m.group(1) == ctx["nav"] else "", text)
    text = re.sub(r"\{\{t:([\w.]+)\}\}", lambda m: ctx["strings"][m.group(1)], text)
    # On its own line in the header, so a site in one language has no blank line where it would go.
    pick = ctx.get("langpicker", "")
    text = re.sub(r"\n[ \t]*\{\{langpicker\}\}", ("\n    " + pick) if pick else "", text)
    text = re.sub(r"\{\{link:([\w-]+)\}\}", lambda m: ctx["links"][m.group(1)], text)
    for k, v in {"root": ctx["root"], "repo": REPO, "dmg": DMG, "version": VERSION, "year": YEAR, **COUNTS}.items():
        text = text.replace("{{%s}}" % k, v)
    # Screenshots keep their names across updates; a content hash makes caches fetch the new image.
    return re.sub(r'(assets/screenshots/[\w-]+\.png)"', lambda m: f'{m.group(1)}?v={asset_hash(m.group(1))}"', text)


def last_changed(path):
    """The date of the commit that last touched a file, falling back to its mtime outside a checkout."""
    try:
        out = subprocess.run(["git", "log", "-1", "--format=%cs", "--", str(path)],
                             cwd=ROOT, capture_output=True, text=True, timeout=10)
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except Exception:
        pass
    return datetime.date.fromtimestamp(pathlib.Path(path).stat().st_mtime).isoformat()

def asset_hash(rel):
    return hashlib.sha256((OUT / rel).read_bytes()).hexdigest()[:8]

def structured_data(meta, body, lang="en", docs_url=f"{DOMAIN}/docs/#install"):
    """JSON-LD for one page.

    Only things that are true: no ratings, no review counts, no author names the repository can't back up.
    Invented structured data is both a Google penalty and a lie told in a machine-readable format.
    """
    path, title, desc = meta["path"], meta["title"], meta["description"]
    home = DOMAIN + localized("/", lang)
    tag = "" if lang == "en" else f"-{lang}"
    site = {"@type": "WebSite", "@id": f"{DOMAIN}/#website{tag}", "url": home, "name": "Flowlight",
            "inLanguage": lang, "publisher": {"@id": f"{DOMAIN}/#publisher"}}
    publisher = {"@type": "Organization", "@id": f"{DOMAIN}/#publisher", "name": "xinbetween",
                 "url": f"{DOMAIN}/", "logo": f"{DOMAIN}/assets/icon.png",
                 "sameAs": [f"https://github.com/{REPO}"]}
    graph = [site, publisher]

    if path == localized("/", lang):
        graph.append({
            "@type": "SoftwareApplication", "@id": f"{DOMAIN}/#app{tag}", "name": "Flowlight",
            "description": desc, "url": home, "applicationCategory": "SecurityApplication",
            "applicationSubCategory": "Network monitor", "operatingSystem": "macOS 15 or later",
            "softwareVersion": VERSION, "downloadUrl": DMG, "installUrl": docs_url,
            "image": f"{DOMAIN}/assets/social-card.png", "screenshot": f"{DOMAIN}/assets/screenshots/agents.png",
            "license": "https://www.gnu.org/licenses/gpl-3.0.html",
            "isAccessibleForFree": True, "publisher": {"@id": f"{DOMAIN}/#publisher"},
            "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD",
                       "availability": "https://schema.org/InStock"},
        })
    else:
        graph.append({"@type": "BreadcrumbList", "itemListElement": [
            {"@type": "ListItem", "position": 1, "name": "Flowlight", "item": home},
            {"@type": "ListItem", "position": 2, "name": title, "item": f"{DOMAIN}{path}"}]})

    faq = faq_entries(body)
    if faq:
        graph.append({"@type": "FAQPage", "@id": f"{DOMAIN}{path}#faq", "mainEntity": [
            {"@type": "Question", "name": q,
             "acceptedAnswer": {"@type": "Answer", "text": a}} for q, a in faq]})

    return ('<script type="application/ld+json">'
            + json.dumps({"@context": "https://schema.org", "@graph": graph}, ensure_ascii=False)
            + "</script>")

def faq_entries(markup):
    """The questions and answers already on the page, read back out of its own markup.

    Written from the page rather than kept in a second list, because a second list is a list that goes stale.
    """
    block = re.search(r'<h2 id="faq".*?<dl>(.*?)</dl>', markup, re.S)
    if not block:
        return []
    pairs = re.findall(r"<dt>(.*?)</dt>\s*<dd>(.*?)</dd>", block.group(1), re.S)
    return [(plain(q), plain(a)) for q, a in pairs]

def plain(markup):
    text = re.sub(r"<[^>]+>", "", markup)
    return html.unescape(re.sub(r"\s+", " ", text)).strip()

def document(meta, body, root, css_href, inline_css=None, index=True, lang="en", locale="en", alt="",
             docs_url=f"{DOMAIN}/docs/#install"):
    title, desc, path = meta["title"], meta["description"], meta["path"]
    style = f"<style>{inline_css}</style>" if inline_css else f'<link rel="stylesheet" href="{css_href}">'
    # A page that isn't a destination shouldn't be one in search results either.
    robots = "" if index else '<meta name="robots" content="noindex, follow">\n'
    canonical = f'<link rel="canonical" href="{DOMAIN}{path}">\n' if index else ""
    return f"""<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>{html.escape(title)}</title>
<meta name="description" content="{html.escape(desc)}">
{robots}{canonical}{alt}<meta property="og:type" content="website">
<meta property="og:site_name" content="Flowlight">
<meta property="og:locale" content="{locale}">
<meta property="og:title" content="{html.escape(title)}">
<meta property="og:description" content="{html.escape(desc)}">
<meta property="og:url" content="{DOMAIN}{path}">
<meta property="og:image" content="{DOMAIN}/assets/social-card.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="Flowlight — application-aware network monitoring for macOS, with focused visibility into AI agents">
<meta name="twitter:card" content="summary_large_image">
<meta name="theme-color" content="#f4f5f8" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#0d0f16" media="(prefers-color-scheme: dark)">
<link rel="icon" href="{root}assets/icon.png">
<link rel="apple-touch-icon" href="{root}assets/apple-touch-icon.png">
{FONTS}
{style}
{structured_data(meta, body, lang, docs_url)}
</head>
<body>
{body}
</body>
</html>
"""


def picker(langs, table, current, targets):
    """The language menu for one page.

    A language whose translation of this page doesn't exist yet links to its home page rather than being hidden:
    the reader asked for that language, and its home page is the nearest true answer.
    """
    if len(langs) < 2:
        return ""
    label = table[current].get("nav.language", table["en"]["nav.language"])
    items = []
    for lang in langs:
        name = table[lang].get("lang.name", lang)
        code = table[lang].get("lang.html", lang)
        if lang == current:
            items.append(f'<span lang="{code}" aria-current="true">{name}</span>')
        else:
            items.append(f'<a href="{targets[lang]}" hreflang="{code}" lang="{code}">{name}</a>')
    here_name = table[current].get("lang.name", current)
    # A chevron rather than the disclosure marker browsers draw: it has to read as one more item in the nav.
    chevron = ('<svg class="lang-chevron" viewBox="0 0 12 12" aria-hidden="true">'
               '<path d="M3 4.5 6 7.5 9 4.5" fill="none" stroke="currentColor" stroke-width="1.5" '
               'stroke-linecap="round" stroke-linejoin="round"/></svg>')
    return (f'<details class="lang">\n'
            f'      <summary aria-label="{label}" title="{label}">{GLOBE}'
            f'<span class="lang-name">{here_name}</span>{chevron}</summary>\n'
            f'      <div class="lang-menu">{"".join(items)}</div>\n'
            f'    </details>')


def build():
    css = (SITE / "site.css").read_text()
    header, footer = (SITE / "partials" / "header.html").read_text(), (SITE / "partials" / "footer.html").read_text()
    (OUT / "assets").mkdir(parents=True, exist_ok=True)
    (OUT / "assets" / "site.css").write_text(css)

    langs = languages()
    table = strings(langs)
    order = ["en"] + sorted((l for l in langs if l != "en"), key=lambda l: table[l].get("lang.name", l))

    # Every page, in every language it exists in, keyed by the English file it translates.
    english = {src.stem: front_matter(src.read_text()) + (src,) for src in sorted((SITE / "pages").glob("*.html"))}
    sources = {}          # (stem, lang) → (meta, body, source file)
    for stem, (meta, body, src) in english.items():
        sources[(stem, "en")] = (dict(meta, source=src, path=meta["path"]), body, src)
    for lang in langs[1:]:
        for src in sorted((SITE / "pages" / lang).glob("*.html")):
            if src.stem not in english:
                sys.exit(f"{src.relative_to(ROOT)} translates no page: site/pages/{src.stem}.html does not exist.")
            meta, body = front_matter(src.read_text())
            base = english[src.stem][0]
            meta = dict(base, **meta)                       # title and description from the translation, nav from English
            meta["path"] = localized(base["path"], lang)    # never from the translation, so it can't be wrong
            meta["source"] = src
            sources[(src.stem, lang)] = (meta, body, src)

    def where(stem, lang):
        """The published path of a page in a language, falling back to English."""
        return sources[(stem, lang if (stem, lang) in sources else "en")][0]["path"]

    pages = []
    for lang in order:
        for stem in english:
            if (stem, lang) not in sources:
                continue
            meta, body, src = sources[(stem, lang)]
            path = meta["path"]
            root = up(path)
            links = {s: href(path, where(s, lang)) for s in english}
            links["home"] = links["index"]
            here = picker(order, table, lang, {l: href(path, elsewhere(sources, english, stem, l)) for l in order})
            ctx = {"root": root, "nav": meta.get("nav", ""), "links": links, "langpicker": here,
                   "strings": Strings(table, lang)}
            alt = alternates(english, sources, stem) if any((stem, l) in sources for l in langs[1:]) else ""
            full = fill(header + body + footer, ctx)
            dest = OUT / path.strip("/") / "index.html" if path != "/" else OUT / "index.html"
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(document(meta, full, root, f"{root}assets/site.css", lang=table[lang].get("lang.html", lang),
                                     locale=table[lang].get("lang.locale", lang), alt=alt,
                                     docs_url=f"{DOMAIN}{where('docs', lang) if 'docs' in english else '/docs/'}#install"))
            pages.append((meta, body, lang))
            if path == "/":
                # Self-contained preview for the claude.ai Artifact (no <html>/<head>; the host adds the skeleton).
                prev = ROOT / "build" / "site-preview"
                prev.mkdir(parents=True, exist_ok=True)
                pbody = fill(header + body + footer, dict(ctx, nav="home"))
                (prev / "index.html").write_text(f"<title>{meta['title']}</title>\n<meta name=\"description\" content=\"{html.escape(meta['description'])}\">\n{FONTS}\n<style>{css}</style>\n{pbody}")
            print(f"  {path:<16} → {dest.relative_to(ROOT)}")

    # The 404 is served for any unknown URL, in any language directory, so it stays English at the site root
    # with absolute links — a relative one would resolve against the URL that didn't exist.
    nf = Strings(table, "en")
    notfound = {"title": nf["notfound.page.title"], "description": nf["notfound.page.description"], "path": "/404.html"}
    nf_ctx = {"root": "/", "nav": "", "strings": nf,
              "links": {s: localized(english[s][0]["path"], "en") for s in english},
              "langpicker": picker(order, table, "en", {l: localized("/", l) for l in order})}
    nf_ctx["links"]["home"] = nf_ctx["links"]["index"]
    nf_body = fill(header + """<main id="main"><section class="page-head"><div class="wrap"><p class="eyebrow">404</p>
<h1>{{t:notfound.title}}</h1><p class="lede">{{t:notfound.lede}}</p></div></section></main>""" + footer, nf_ctx)
    (OUT / "404.html").write_text(document(notfound, nf_body, "/", "/assets/site.css", index=False))

    # lastmod comes from the commit that last touched each page's source, so it says something true even when
    # a rebuild touches every file. Google reads lastmod and ignores changefreq and priority, so neither is here.
    entries = "".join(
        f"  <url><loc>{DOMAIN}{m['path']}</loc><lastmod>{last_changed(m['source'])}</lastmod></url>\n"
        for m, _, _ in pages)
    (OUT / "sitemap.xml").write_text('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        + entries + "</urlset>\n")
    (OUT / "robots.txt").write_text(f"User-agent: *\nAllow: /\nSitemap: {DOMAIN}/sitemap.xml\n")

    # llms.txt: a short map; llms-full.txt: every page as plain text. Both English: a model reading them can
    # read English, and the localized pages say the same things.
    english_pages = [(m, b) for m, b, lang in pages if lang == "en"]
    def text_of(markup):
        markup = re.sub(r"<(script|style|svg)[\s\S]*?</\1>", "", markup)
        markup = re.sub(r"<br\s*/?>|</(p|li|h[1-6]|tr|div|pre|summary)>", "\n", markup)
        markup = re.sub(r"<[^>]+>", "", markup)
        markup = html.unescape(fill(markup, {"root": DOMAIN + "/", "nav": "", "strings": nf,
                                             "links": {s: DOMAIN + english[s][0]["path"] for s in english} | {"home": DOMAIN + "/"}}))
        return re.sub(r"\n\s*\n+", "\n\n", re.sub(r"[ \t]+", " ", markup)).strip()
    llms = [f"# Flowlight\n\n> Free, open-source (GPL-3.0) application-aware network monitor for macOS, with focused visibility into"
            f" AI agents. It attributes observed TCP and UDP activity to the application that made it and records the destination, protocol and"
            f" byte counts, keeping local history from second to year. Recognized AI agents are listed by name along with the tools and MCP"
            f" servers they start, under per-agent allowlists. It can also refuse, once asked: a rule blocks an application, a destination or a"
            f" URL for as long as you specify, and a guardrail withholds a tool from an agent before its model is offered it. Runs on macOS 15"
            f" or later; capture is by a sampler or a Network Extension. Current version: {VERSION}.\n",
            f"- [Download Flowlight.dmg]({DMG})", f"- [Source code](https://github.com/{REPO})"]
    llms += [f"- [{m['title']}]({DOMAIN}{m['path']}): {m['description']}" for m, _ in english_pages]
    llms += [f"- [Full text for LLMs]({DOMAIN}/llms-full.txt)"]
    (OUT / "llms.txt").write_text("\n".join(llms) + "\n")
    (OUT / "llms-full.txt").write_text("\n\n---\n\n".join(f"# {m['title']}\nURL: {DOMAIN}{m['path']}\n\n{text_of(b)}" for m, b in english_pages) + "\n")
    print(f"  + 404.html, sitemap.xml, robots.txt, llms.txt, llms-full.txt · version {VERSION} · "
          f"{len(pages)} pages in {len(order)} language(s)")


class Strings(dict):
    """The strings for one language, falling back to English for anything not translated yet."""
    def __init__(self, table, lang):
        super().__init__(table["en"] | table[lang])


def elsewhere(sources, english, stem, lang):
    """Where a reader who picks a language from this page should land: the same page in that language, that
    language's home page when this one isn't translated yet, and the English page when neither exists."""
    for key in ((stem, lang), ("index", lang)):
        if key in sources:
            return sources[key][0]["path"]
    return english[stem][0]["path"]


def alternates(english, sources, stem):
    """hreflang for every language this page exists in, plus x-default pointing at the English one."""
    out = []
    for (s, lang), (meta, _, _) in sources.items():
        if s == stem:
            out.append((lang, meta["path"]))
    out.sort(key=lambda p: (p[0] != "en", p[0]))
    lines = [f'<link rel="alternate" hreflang="{lang}" href="{DOMAIN}{path}">' for lang, path in out]
    lines.append(f'<link rel="alternate" hreflang="x-default" href="{DOMAIN}{english[stem][0]["path"]}">')
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    build()
