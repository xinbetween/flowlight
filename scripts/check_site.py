#!/usr/bin/env python3
"""Checks the generated site for the ways it has actually broken.

Every rule here is a bug that shipped. The site is built from templates, translated by hand into nine
languages and regenerated on every release, so the failures are never syntax — they are a placeholder that
didn't render, a link to an anchor that exists in English only, a font that came back from a third party, a
roadmap still advertising what you can already download. None of that stops the build.

    python3 scripts/check_site.py        # after scripts/build_site.py
"""
import re, sys, pathlib, collections, json, subprocess, time

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "docs"
PAGES = sorted(OUT.rglob("index.html")) + [OUT / "404.html"]
# The nine translations, named by their string catalogues rather than guessed from directory names — "about"
# and "privacy" are pages, not languages.
LANGS = sorted(p.stem for p in (ROOT / "site/i18n").glob("*.json") if p.stem != "en")
OFFICIAL_PACK_REVIEWED_SOURCE = ROOT / "rule-packs/official-source.json"
OFFICIAL_PACK_SOURCE = ROOT / "site/packs/v1/official.json"
OFFICIAL_PACK_BUNDLED = ROOT / "Flowlight/Resources/RulePacks/official.json"
OFFICIAL_PACK_OUTPUT = OUT / "packs/v1/official.json"
OFFICIAL_PACK_PUBLIC_KEY = ROOT / "Flowlight/Resources/RulePacks/official-rule-packs-v1-public.pem"
OFFICIAL_PACK_KEY_ID = "flowlight-rule-packs-2026-01"
OFFICIAL_PACK_URL = "https://flowlight.xinbetween.com/packs/v1/official.json"
PAGES_WORKFLOW = ROOT / ".github/workflows/pages.yml"
PROJECT = (ROOT / "project.yml").read_text()
APP_VERSION = re.search(r'MARKETING_VERSION:\s*"([^"]+)"', PROJECT).group(1)

# Fetched by the browser to render the page. A <link> is only that for some values of rel — `alternate` and
# `canonical` are addresses for a crawler, and every translated page carries ten of them.
FETCHED_REL = {"stylesheet", "preload", "prefetch", "preconnect", "dns-prefetch", "modulepreload", "icon"}
TAG_OPEN = re.compile(r"<(link|script|img)\b([^>]*)>", re.I)
ATTR = re.compile(r'(\w[\w-]*)="([^"]*)"')
PLACEHOLDER = re.compile(r"\{\{[\w.:-]+\}\}")
ANCHOR = re.compile(r'href="([^"#]*)#([\w-]+)"')
IDS = re.compile(r'\bid="([\w-]+)"')
TAG = re.compile(r'<span class="tag">(\d+\.\d+(?:\.\d+)?)</span>')
IMG = re.compile(r'<img[^>]*src="([^"]*assets/screenshots/[^"]+)"([^>]*)>')
WH = re.compile(r'\b(width|height)="(\d+)"')
HELP_ANCHOR = re.compile(r'case \.(\w+): return "([\w-]+)"')
SIDEBAR = re.compile(r"enum SidebarItem[^{]*\{\s*case ([\w, ]+)")
ROW = re.compile(r"<tr><td>(?:<a[^>]*>)?([^<]+)(?:</a>)?</td><td>\u2318(.)</td>")
H1 = re.compile(r"<h1[ >]")
TITLE = re.compile(r"<title>([^<]+)</title>", re.I)
META = re.compile(r'<meta\s+(?:name|property)="([^"]+)"\s+content="([^"]*)"', re.I)
CANONICAL = re.compile(r'<link\s+rel="canonical"\s+href="([^"]+)"', re.I)
ALTERNATE = re.compile(r'<link\s+rel="alternate"\s+hreflang="([^"]+)"\s+href="([^"]+)"', re.I)
JSON_LD = re.compile(r'<script type="application/ld\+json">(.*?)</script>', re.S | re.I)


def version_key(text):
    return tuple(int(part) for part in text.split("."))


def problems():
    found = []

    # The public catalog is a signed app update channel, not an ordinary generated asset. The source served by
    # Pages and the committed docs copy must be byte-for-byte identical, and verification uses the public key
    # embedded in the app. The private key never belongs in this repository or in CI.
    if not OFFICIAL_PACK_SOURCE.is_file():
        found.append("site/packs/v1/official.json: signed catalog is missing — sign rule-packs/official-source.json offline")
    if not OFFICIAL_PACK_BUNDLED.is_file():
        found.append("Flowlight/Resources/RulePacks/official.json: bundled signed catalog is missing")
    if not OFFICIAL_PACK_OUTPUT.is_file():
        found.append("docs/packs/v1/official.json: generated signed catalog is missing — run scripts/build_site.py after signing")
    if OFFICIAL_PACK_SOURCE.is_file() and OFFICIAL_PACK_OUTPUT.is_file():
        source_bytes = OFFICIAL_PACK_SOURCE.read_bytes()
        if source_bytes != OFFICIAL_PACK_OUTPUT.read_bytes():
            found.append("docs/packs/v1/official.json: differs from site/packs/v1/official.json")
        if OFFICIAL_PACK_BUNDLED.is_file() and source_bytes != OFFICIAL_PACK_BUNDLED.read_bytes():
            found.append("Flowlight/Resources/RulePacks/official.json: differs from site/packs/v1/official.json")
        if not OFFICIAL_PACK_PUBLIC_KEY.is_file():
            found.append("Flowlight/Resources/RulePacks/official-rule-packs-v1-public.pem: public verification key is missing")
        else:
            catalog_tool = str(ROOT / "scripts/rule_pack_catalog.py")
            compared = subprocess.run(
                [sys.executable, "-I", catalog_tool, "compare",
                 str(OFFICIAL_PACK_REVIEWED_SOURCE), str(OFFICIAL_PACK_SOURCE)],
                cwd=ROOT, capture_output=True, text=True, timeout=30)
            if compared.returncode:
                detail = (compared.stderr or compared.stdout).strip().replace("\n", " ")
                found.append(f"site/packs/v1/official.json: reviewed source comparison failed: {detail}")
            verified = subprocess.run(
                [sys.executable, "-I", catalog_tool, "verify", str(OFFICIAL_PACK_SOURCE),
                 "--public-key", str(OFFICIAL_PACK_PUBLIC_KEY), "--expected-key-id", OFFICIAL_PACK_KEY_ID,
                 "--current-app-version", APP_VERSION, "--extension-protocol", "1",
                 "--now", str(int(time.time()))],
                cwd=ROOT, capture_output=True, text=True, timeout=30)
            if verified.returncode:
                detail = (verified.stderr or verified.stdout).strip().replace("\n", " ")
                found.append(f"site/packs/v1/official.json: signature verification failed: {detail}")

    # The app now consumes this endpoint. Keep the fixed source, privacy disclosure, documentation and release notes
    # tied together so a future refactor cannot silently create an undocumented outbound request or arbitrary source.
    verifier_source = (ROOT / "Flowlight/Analysis/RulePackCatalogVerifier.swift").read_text()
    if OFFICIAL_PACK_URL not in verifier_source:
        found.append("Flowlight/Analysis/RulePackCatalogVerifier.swift: fixed official feed URL is missing")
    source_pages = [ROOT / "README.md", ROOT / "SECURITY.md", ROOT / "site/pages/docs.html",
                    ROOT / "site/pages/privacy.html", ROOT / "site/pages/threat-model.html"]
    for path in source_pages:
        text = path.read_text().lower()
        if "official" not in text or not any(word in text for word in ("signed", "signature", "publisher")):
            found.append(f"{path.relative_to(ROOT)}: authenticated official rule-pack consumer is not documented")
    privacy_sources = [ROOT / "site/pages/privacy.html"] + [
        ROOT / f"site/pages/{lang}/privacy.html" for lang in LANGS
    ]
    for path in privacy_sources:
        if "flowlight.xinbetween.com" not in path.read_text():
            found.append(f"{path.relative_to(ROOT)}: official rule-pack request is missing from privacy table")
    docs_sources = [ROOT / "site/pages/docs.html"] + [
        ROOT / f"site/pages/{lang}/docs.html" for lang in LANGS
    ]
    for path in docs_sources:
        if 'id="managed-packs"' not in path.read_text():
            found.append(f"{path.relative_to(ROOT)}: #managed-packs subscription section is missing")
    stale_request_counts = ("Three requests", "Three smaller things", "Drei Anfragen", "Drei kleinere Dinge",
                            "Tres peticiones", "Tres cosas más pequeñas", "Trois requêtes", "Trois choses plus petites",
                            "Tre richieste", "Tre cose più piccole", "Três pedidos", "três coisas mais pequenas",
                            "リクエストは 3 つ", "요청은 세 가지", "떠나는 것이 세 가지",
                            "三个请求", "三個請求")
    for path in [ROOT / "site/pages/docs.html", ROOT / "site/pages/threat-model.html"] + [
            ROOT / f"site/pages/{lang}/docs.html" for lang in LANGS
    ] + [ROOT / f"site/pages/{lang}/threat-model.html" for lang in LANGS]:
        if any(phrase.casefold() in path.read_text().casefold() for phrase in stale_request_counts):
            found.append(f"{path.relative_to(ROOT)}: fixed outbound-request count is stale-prone")

    # 1. A placeholder that didn't render. `{{t:nav.threat-model}}` printed itself on all 51 pages because the
    #    pattern for {{t:}} didn't allow hyphens, and nothing noticed — it is valid HTML.
    for page in PAGES:
        for hit in set(PLACEHOLDER.findall(page.read_text())):
            found.append(f"{page.relative_to(ROOT)}: unrendered placeholder {hit}")

    # 2. A resource fetched from somewhere else. The privacy page explaining that Flowlight sends nothing
    #    anywhere loaded its fonts from Google, and the disclosure was the only thing that made it acceptable.
    for page in PAGES:
        for name, attrs in TAG_OPEN.findall(page.read_text()):
            attr = {k.lower(): v for k, v in ATTR.findall(attrs)}
            if name.lower() == "link":
                if not set(attr.get("rel", "").lower().split()) & FETCHED_REL:
                    continue
                url = attr.get("href", "")
            else:
                url = attr.get("src", "")
            if url.startswith(("http://", "https://", "//")):
                found.append(f"{page.relative_to(ROOT)}: <{name.lower()}> fetches {url} from a third party")

    # 3. An anchor that doesn't exist in the page it points at. The Coverage section was added to the English
    #    docs only, so every translated threat-model page linked to `#coverage` and landed at the top.
    ids = {page: set(IDS.findall(page.read_text())) for page in PAGES}
    for page in PAGES:
        for href, anchor in ANCHOR.findall(page.read_text()):
            target = page if not href else (OUT / href.lstrip("/") if href.startswith("/") else page.parent / href)
            if target.is_dir():
                target = target / "index.html"
            target = target.resolve()
            if target not in ids:
                continue          # an external or missing page; rule 4 covers the page itself
            if anchor not in ids[target]:
                found.append(f"{page.relative_to(ROOT)}: #{anchor} does not exist in {target.relative_to(OUT)}")

    # 4. A link to a page that isn't there.
    for page in PAGES:
        for href in re.findall(r'href="([^"#?]+)"', page.read_text()):
            if href.startswith(("http", "mailto:", "//")) or not href:
                continue
            target = OUT / href.lstrip("/") if href.startswith("/") else page.parent / href
            target = target.resolve()
            if target.is_dir():
                target = target / "index.html"
            if not target.exists():
                found.append(f"{page.relative_to(ROOT)}: link to {href} goes nowhere")

    # 5. "What's coming" still advertising what has already shipped — a roadmap entry tagged at or below the
    #    newest version on the releases page. It reads as a promise until someone notices it is a memory.
    releases = (ROOT / "site/pages/releases.html").read_text()
    shipped = re.findall(r"<h2>(\d+\.\d+(?:\.\d+)?)</h2>", releases)
    release_headers = re.findall(r"<header>(.*?)</header>", releases, re.S)
    latest = [match.group(1) for header in release_headers
              if 'class="tag">Latest</span>' in header
              if (match := re.search(r"<h2>(\d+\.\d+(?:\.\d+)?)</h2>", header))]
    if shipped:
        newest = max(shipped, key=version_key)
        if newest != APP_VERSION:
            found.append(f"site/pages/releases.html: newest release {newest} does not match app {APP_VERSION}")
        if latest != [APP_VERSION]:
            found.append(f"site/pages/releases.html: expected one Latest tag on {APP_VERSION}, found {latest}")
        for page in PAGES:
            text = page.read_text()
            start = text.find('id="roadmap"')
            if start < 0:
                continue
            for tag in set(TAG.findall(text[start:])):
                if version_key(tag) <= version_key(newest):
                    found.append(f"{page.relative_to(ROOT)}: roadmap still lists {tag}, "
                                 f"but {newest} has shipped")

    # 7. A section English has and a translation doesn't. This is how #coverage broke: the Coverage screen was
    #    documented in English, nine pages kept linking to an anchor that had never existed in their language,
    #    and each of them silently sent the reader to the top of the page. Rule 3 catches the dangling link
    #    only once something points at it; this catches the missing section itself.
    for english in PAGES:
        if OUT not in english.parents or english.parts[len(OUT.parts)] in LANGS:
            continue                                    # only compare against the English original
        relative = english.relative_to(OUT)
        en_ids = set(IDS.findall(english.read_text()))
        for lang in LANGS:
            translated = OUT / lang / relative
            if not translated.exists():
                continue                                # not translated at all is a choice, not a defect
            for missing in sorted(en_ids - set(IDS.findall(translated.read_text()))):
                found.append(f"{translated.relative_to(ROOT)}: no #{missing} section, but "
                             f"{relative} has one — the English page gained content this one didn't")

    # 8. A roadmap that promises less in translation. The entries are versioned commitments, so a translated
    #    home page listing four of them where English lists five is telling a different story, not a shorter one.
    home = OUT / "index.html"
    if home.exists():
        def entries(text):
            start = text.find('id="roadmap"')
            return text.count("<div><strong>", start, text.find("</section>", start)) if start >= 0 else None
        expected = entries(home.read_text())
        for lang in LANGS:
            translated = OUT / lang / "index.html"
            if not translated.exists():
                continue
            actual = entries(translated.read_text())
            if actual is not None and expected is not None and actual != expected:
                found.append(f"{translated.relative_to(ROOT)}: roadmap lists {actual} entries, "
                             f"English lists {expected}")

    # 9. A screen the documentation never covers. Every sidebar item carries a `helpAnchor`, and the Help
    #    button on that screen opens the docs at it — so an anchor with no section sends the reader to the top
    #    of a long page, which is how Coverage shipped: a new screen, a Help button, and nothing to land on.
    #    Read from the app's own source, so adding a screen is what triggers the check.
    nav = (ROOT / "Flowlight/App/AppNavigation.swift").read_text()
    body = nav[nav.find("var helpAnchor"):nav.find("var englishTitle")]
    docs_ids = set(IDS.findall((OUT / "docs/index.html").read_text()))
    for screen, anchor in HELP_ANCHOR.findall(body):
        if anchor not in docs_ids:
            found.append(f"docs/docs/index.html: no #{anchor} section, but the {screen} screen's Help "
                         f"button opens it — a new screen the documentation never got")

    # 12. A shortcut the documentation gets wrong. The sidebar's order *is* the shortcut — ⌘1 to ⌘0 by
    #     position — so inserting a screen silently renumbers every screen after it. The table said Inspect was
    #     ⌘5 long after it had become ⌘7, and four screens had been added without ever reaching the table.
    order = [c.strip() for c in SIDEBAR.search(nav).group(1).split(",") if c.strip()]
    titles = dict(HELP_ANCHOR.findall(nav[nav.find("var englishTitle"):nav.find("var title")]))
    docs_text = (OUT / "docs/index.html").read_text()
    rows = {name.strip(): key for name, key in ROW.findall(docs_text)}
    for index, screen in enumerate(order):
        title, key = titles.get(screen), "0" if index == 9 else str(index + 1)
        if title is None or index > 9:
            continue                      # past ⌘0 there is no shortcut to document
        if title not in rows:
            found.append(f"docs/docs/index.html: the views table never lists {title} (\u2318{key})")
        elif rows[title] != key:
            found.append(f"docs/docs/index.html: the views table gives {title} \u2318{rows[title]}, "
                         f"but the sidebar puts it at \u2318{key}")

    # 10. A screenshot nothing shows, or a screenshot that isn't there. Both happen while rearranging a page:
    #     the file outlives the <img> that referenced it, and nobody notices a megabyte being served for nothing.
    shots = OUT / "assets/screenshots"
    referenced = set()
    for page in PAGES:
        for src, _ in IMG.findall(page.read_text()):
            name = src.rsplit("/", 1)[-1].split("?")[0]
            referenced.add(name)
            if not (shots / name).exists():
                found.append(f"{page.relative_to(ROOT)}: screenshot {name} does not exist")
    for shot in sorted(shots.glob("*.png")):
        if shot.name not in referenced:
            found.append(f"{shot.relative_to(ROOT)}: no page shows this screenshot")

    # 11. A declared size that isn't the image's size. The width and height are there to reserve the space
    #     before the image loads; a re-capture at a different aspect ratio makes them a lie and the page jumps.
    for page in PAGES:
        for src, attrs in IMG.findall(page.read_text()):
            shot = shots / src.rsplit("/", 1)[-1].split("?")[0]
            if not shot.exists():
                continue
            raw = shot.read_bytes()[16:24]
            real = (int.from_bytes(raw[:4], "big"), int.from_bytes(raw[4:], "big"))
            declared = {k: int(v) for k, v in WH.findall(attrs)}
            if len(declared) == 2 and real[0] and abs(declared["width"] / declared["height"] - real[0] / real[1]) > 0.01:
                found.append(f"{page.relative_to(ROOT)}: {shot.name} is declared "
                             f"{declared['width']}x{declared['height']} but is {real[0]}x{real[1]}")

    # 6. One <h1> per page: zero is a page with no title for a reader or a crawler, two is a translation that
    #    duplicated a section while editing.
    for page in PAGES:
        count = len(H1.findall(page.read_text()))
        if count != 1:
            found.append(f"{page.relative_to(ROOT)}: {count} <h1> elements, expected 1")

    # 13. SEO metadata is generated centrally. Keeping its structural contract here means a template change cannot
    # quietly publish pages that look fine in a browser but have no usable search/social identity.
    expected_social = {"og:type", "og:site_name", "og:locale", "og:title", "og:description", "og:url", "og:image",
                       "og:image:type", "og:image:width", "og:image:height", "og:image:alt", "twitter:card",
                       "twitter:title", "twitter:description", "twitter:image", "twitter:image:alt"}
    indexed = [page for page in PAGES if page.name != "404.html"]
    canonicals = {}
    for page in PAGES:
        text = page.read_text()
        if not TITLE.search(text) or not TITLE.search(text).group(1).strip():
            found.append(f"{page.relative_to(ROOT)}: missing non-empty <title>")
        metadata = dict(META.findall(text))
        if not metadata.get("description", "").strip():
            found.append(f"{page.relative_to(ROOT)}: missing non-empty meta description")
        is_indexed = page in indexed
        canonical = CANONICAL.findall(text)
        if is_indexed:
            expected = "https://flowlight.xinbetween.com/" + ("" if page == OUT / "index.html" else str(page.relative_to(OUT).parent) + "/")
            if canonical != [expected]:
                found.append(f"{page.relative_to(ROOT)}: canonical must be exactly {expected}")
            canonicals[page] = expected
            missing = sorted(expected_social - set(metadata))
            if missing:
                found.append(f"{page.relative_to(ROOT)}: missing social metadata {', '.join(missing)}")
            elif metadata["og:url"] != expected or metadata["og:title"] != TITLE.search(text).group(1) or metadata["og:description"] != metadata["description"]:
                found.append(f"{page.relative_to(ROOT)}: Open Graph URL/title/description disagree with page metadata")
        elif canonical:
            found.append(f"{page.relative_to(ROOT)}: noindex page must not have a canonical URL")

        for raw in JSON_LD.findall(text):
            try:
                graph = json.loads(raw).get("@graph", [])
            except json.JSONDecodeError as error:
                found.append(f"{page.relative_to(ROOT)}: invalid JSON-LD: {error.msg}")
                continue
            kinds = {node.get("@type") for node in graph}
            if is_indexed and "WebPage" not in kinds:
                found.append(f"{page.relative_to(ROOT)}: JSON-LD has no WebPage node")
            is_home = page.name == "index.html" and (page.parent == OUT or page.parent.name in LANGS)
            if is_home and "SoftwareApplication" not in kinds:
                found.append(f"{page.relative_to(ROOT)}: home JSON-LD has no SoftwareApplication node")
            if not is_home and is_indexed and "BreadcrumbList" not in kinds:
                found.append(f"{page.relative_to(ROOT)}: page JSON-LD has no BreadcrumbList node")

        if is_indexed:
            alternates = dict(ALTERNATE.findall(text))
            if alternates and "x-default" not in alternates:
                found.append(f"{page.relative_to(ROOT)}: hreflang cluster has no x-default")
            for lang, href in alternates.items():
                if lang == "x-default":
                    continue
                target = next((candidate for candidate, url in canonicals.items() if url == href), None)
                if target is not None and lang not in dict(ALTERNATE.findall(target.read_text())):
                    found.append(f"{page.relative_to(ROOT)}: hreflang {lang} is not reciprocal")

    # 14. The sitemap names exactly the pages allowed to be indexed, and robots advertises that sitemap.
    sitemap = (OUT / "sitemap.xml").read_text()
    sitemap_urls = set(re.findall(r"<loc>([^<]+)</loc>", sitemap))
    if sitemap_urls != set(canonicals.values()):
        found.append("docs/sitemap.xml: URLs do not exactly match canonical indexable pages")
    robots = (OUT / "robots.txt").read_text()
    if "Sitemap: https://flowlight.xinbetween.com/sitemap.xml" not in robots:
        found.append("docs/robots.txt: missing or incorrect sitemap declaration")

    # 15. The home is intentionally static/lightweight. A loop here has previously caused real-machine jank.
    for source in sorted((ROOT / "site/pages").glob("**/index.html")):
        source_text = source.read_text()
        if re.search(r"\b(setInterval|setTimeout|requestAnimationFrame)\s*\(", source_text):
            found.append(f"{source.relative_to(ROOT)}: home page has recurring JavaScript animation")

    # 16. Pages occasionally needs redeploying without changing public bytes. A manual dispatch has no `before`
    # SHA, so it must compare with the signed catalog already being served rather than a guessed commit. Keep these
    # contracts scoped to the trigger, deploy job, and catalog-verification step so duplicate text elsewhere cannot
    # make a broken workflow look safe.
    pages_workflow = PAGES_WORKFLOW.read_text()
    trigger = pages_workflow.split("\npermissions:", 1)[0]
    deploy = pages_workflow.split("\n  deploy:\n", 1)[1] if "\n  deploy:\n" in pages_workflow else ""
    catalog_step = deploy.split("      - name: Verify the official rule-pack catalog\n", 1)[1] \
        if "      - name: Verify the official rule-pack catalog\n" in deploy else ""
    catalog_step = catalog_step.split("\n      - ", 1)[0]
    if not re.search(r"(?m)^  workflow_dispatch:\s*$", trigger):
        found.append(".github/workflows/pages.yml: manual Pages redeployment is unavailable")
    main_only = r"(?m)^    if: \$\{\{ github\.event_name == 'push' \|\| github\.ref == 'refs/heads/main' \}\}\s*$"
    if not re.search(main_only, deploy):
        found.append(".github/workflows/pages.yml: manual deployment is not restricted to main")
    gh_token = r"(?m)^          GH_TOKEN: \$\{\{ github\.token \}\}\s*$"
    live_url = r"(?m)^          LIVE_CATALOG_URL: https://flowlight\.xinbetween\.com/packs/v1/official\.json\s*$"
    deployment_lookup = r"(?s)gh api .*?/deployments\?environment=github-pages&per_page=20'.*?DEPLOYMENT_STATE=.*?/statuses.*?if \[ \"\$DEPLOYMENT_STATE\" = \"success\" \]"
    deployed_bytes = r"(?s)application/vnd\.github\.raw\+json.*?/contents/site/packs/v1/official\.json\?ref=\$DEPLOYED_REF.*?> \"\$PREVIOUS_CATALOG\""
    live_fallback = r"(?s)curl .*?--output \"\$PREVIOUS_CATALOG\" \"\$LIVE_CATALOG_URL\""
    baseline_verify = r"(?s)rule_pack_catalog\.py verify \"\$PREVIOUS_CATALOG\" .*?--expected-key-id flowlight-rule-packs-2026-01"
    baseline_compare = r"(?s)compare-previous site/packs/v1/official\.json \\\n\s+--previous \"\$PREVIOUS_CATALOG\""
    if (not re.search(gh_token, catalog_step)
            or not re.search(live_url, catalog_step)
            or not re.search(deployment_lookup, catalog_step)
            or not re.search(deployed_bytes, catalog_step)
            or not re.search(live_fallback, catalog_step)
            or not re.search(baseline_verify, catalog_step)
            or not re.search(baseline_compare, catalog_step)):
        found.append(".github/workflows/pages.yml: manual deployment does not verify the recorded or live catalog baseline")

    return found


def main():
    if not PAGES or not (OUT / "index.html").exists():
        print("docs/ has no built pages — run scripts/build_site.py first", file=sys.stderr)
        return 1
    found = problems()
    for problem in sorted(found):
        print(f"::error::{problem}" if "--ci" in sys.argv else problem)
    print(f"\n{len(PAGES)} pages checked, {len(found)} problem(s)")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
