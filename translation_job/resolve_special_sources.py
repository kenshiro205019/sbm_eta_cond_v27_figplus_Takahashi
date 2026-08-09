from __future__ import annotations

import html
import json
import re
import sys
from collections import deque
from pathlib import Path
from urllib.parse import parse_qs, quote_plus, unquote, urljoin, urlparse

import fitz
import requests
from bs4 import BeautifulSoup

S = requests.Session()
S.headers.update({"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/150 Safari/537.36"})


def get(url: str, timeout: int = 35) -> requests.Response:
    err = None
    for _ in range(3):
        try:
            r = S.get(url, timeout=timeout, allow_redirects=True)
            r.raise_for_status()
            return r
        except Exception as exc:
            err = exc
    raise RuntimeError(f"GET failed {url}: {err!r}")


def normalise(url: str) -> str:
    url = html.unescape(url).replace("\\/", "/")
    if url.startswith("//"):
        url = "https:" + url
    p = urlparse(url)
    q = parse_qs(p.query)
    if "duckduckgo.com" in p.netloc and q.get("uddg"):
        return unquote(q["uddg"][0])
    if "google." in p.netloc and p.path == "/url" and q.get("q"):
        return q["q"][0]
    return url


def links(base: str, text: str) -> list[str]:
    soup = BeautifulSoup(text, "html.parser")
    out: list[str] = []
    for tag in soup.find_all(True):
        for attr in ("href", "src", "data", "data-src", "content"):
            v = tag.get(attr)
            if isinstance(v, str) and v.strip():
                u = normalise(urljoin(base, v.strip()))
                if u.startswith("http"):
                    out.append(u)
    for m in re.finditer(r"https?:\\?/\\?/[^\"'<>\\s]+", text):
        out.append(normalise(m.group(0)))
    return list(dict.fromkeys(out))


def web_search(query: str) -> list[str]:
    out: list[str] = []
    for u in (
        f"https://html.duckduckgo.com/html/?q={quote_plus(query)}",
        f"https://www.google.com/search?q={quote_plus(query)}&num=30",
        f"https://www.bing.com/search?q={quote_plus(query)}&count=30",
    ):
        try:
            r = get(u)
            out.extend(links(r.url, r.text))
        except Exception as exc:
            print("SEARCH_ERROR", u, repr(exc), flush=True)
    return list(dict.fromkeys(out))


def inspect(content: bytes) -> tuple[int, str]:
    d = fitz.open(stream=content, filetype="pdf")
    text = " ".join(d[i].get_text("text") for i in range(min(3, d.page_count)))
    return d.page_count, re.sub(r"\s+", " ", text).lower()


def candidate_pdf_urls(seed_urls: list[str], keyword_re: re.Pattern[str], max_pages: int = 300) -> list[str]:
    q = deque(seed_urls)
    seen: set[str] = set()
    pdfs: list[str] = []
    while q and len(seen) < max_pages:
        u = normalise(q.popleft())
        if not u.startswith("http") or u in seen:
            continue
        seen.add(u)
        low = u.lower()
        if ".pdf" in low:
            pdfs.append(u)
            continue
        if not keyword_re.search(low) and len(seen) > len(seed_urls) + 60:
            continue
        try:
            r = get(u)
        except Exception as exc:
            print("PAGE_ERROR", u, repr(exc), flush=True)
            continue
        ctype = r.headers.get("content-type", "").lower()
        if "pdf" in ctype or r.content.lstrip().startswith(b"%PDF"):
            pdfs.append(r.url)
            continue
        if "html" in ctype or "xml" in ctype or r.text.lstrip().startswith("<"):
            for v in links(r.url, r.text):
                lv = v.lower()
                if ".pdf" in lv:
                    pdfs.append(v)
                elif keyword_re.search(lv):
                    q.append(v)
    return list(dict.fromkeys(pdfs))


def resolve_whitepaper(out: Path) -> dict:
    seeds: list[str] = []
    for api in (
        "https://cablecraft.com/wp-json/wp/v2/media?search=lost%20motion&per_page=100",
        "https://cablecraft.com/wp-json/wp/v2/search?search=lost%20motion&per_page=100",
        "https://cablecraft.com/wp-json/wp/v2/pages?search=lost%20motion&per_page=100",
        "https://cablecraft.com/wp-json/wp/v2/posts?search=lost%20motion&per_page=100",
    ):
        try:
            data = get(api).json()
            if isinstance(data, list):
                for item in data:
                    for k in ("source_url", "link", "url"):
                        if item.get(k):
                            seeds.append(item[k])
                    rendered = ((item.get("content") or {}).get("rendered") or "")
                    seeds.extend(links(item.get("link") or api, rendered))
        except Exception as exc:
            print("WP_ERROR", api, repr(exc), flush=True)
    seeds += [
        "https://cablecraft.com/controls-and-cables-engineering-resources/white-papers/accounting-for-lost-motion/",
        "https://cablecraft.com/controls-and-cables-engineering-resources/white-papers/",
        "https://cablecraft.com/wp-sitemap.xml",
        "https://cablecraft.com/sitemap_index.xml",
    ]
    for query in (
        'site:cablecraft.com "Accounting for Lost Motion" pdf',
        'site:cablecraft.com/wp-content/uploads "lost motion" pdf',
        '"accounting-for-lost-motion-cable-suppliers-whitepaper.pdf"',
        'Cablecraft accounting lost motion white paper filetype:pdf',
    ):
        seeds.extend(web_search(query))
    candidates = candidate_pdf_urls(list(dict.fromkeys(seeds)), re.compile(r"cablecraft|lost|motion|white.?paper|account"))
    best = None
    for u in candidates:
        try:
            r = get(u, 60)
            if not r.content.lstrip().startswith(b"%PDF") and "pdf" not in r.headers.get("content-type", "").lower():
                continue
            pages, text = inspect(r.content)
            score = (100 if pages == 5 else 0)
            score += 45 if "lost motion" in text else 0
            score += 25 if "accounting" in text else 0
            score += 25 if "cablecraft" in text else 0
            score += sum(v for k, v in (("lost", 15), ("motion", 15), ("account", 10), ("white", 5)) if k in r.url.lower())
            score += max(0, 20 - int(abs(len(r.content) - 348147) / 50000))
            print("WHITE", score, pages, len(r.content), r.url, text[:180], flush=True)
            row = (score, r.url, r.content, pages, text)
            if best is None or score > best[0]:
                best = row
        except Exception as exc:
            print("WHITE_CANDIDATE_ERROR", u, repr(exc), flush=True)
    if best is None or best[0] < 150:
        raise RuntimeError(f"Whitepaper not resolved, best={None if best is None else best[:2]}")
    score, url, content, pages, text = best
    path = out / "accounting-for-lost-motion-cable-suppliers-whitepaper.pdf"
    path.write_bytes(content)
    return {"name": path.name, "url": url, "score": score, "pages": pages, "bytes": len(content), "sample": text[:400]}


def resolve_schaeffler(out: Path) -> dict:
    seeds = [
        "https://www.schaeffler.com/en/search/?q=ewellix%20roller%20screw",
        "https://www.schaeffler.us/us/search/?q=ewellix%20roller%20screw",
        "https://www.schaeffler.com/sitemap.xml",
        "https://www.schaeffler.com/sitemap_index.xml",
        "https://www.ewellix.com/en/search?search=roller%20screw",
        "https://www.ewellix.com/en/products/roller-screws",
    ]
    for query in (
        '"schaeffler_ewellix_roller_screw_en.pdf"',
        'Schaeffler Ewellix roller screw filetype:pdf',
        'site:schaeffler.com ewellix "roller screw" pdf',
        'site:ewellix.com "roller screw" filetype:pdf',
        '"Ewellix" "roller screw" PDF',
    ):
        seeds.extend(web_search(query))
    candidates = candidate_pdf_urls(list(dict.fromkeys(seeds)), re.compile(r"ewellix|roller|screw|schaeffler"), 400)
    best = None
    for u in candidates:
        try:
            r = get(u, 60)
            if not r.content.lstrip().startswith(b"%PDF") and "pdf" not in r.headers.get("content-type", "").lower():
                continue
            pages, text = inspect(r.content)
            score = 100 if pages == 1 else 0
            score += 55 if "roller screw" in text or "roller screws" in text else 0
            score += 40 if "ewellix" in text else 0
            score += 25 if "schaeffler" in text else 0
            score += sum(v for k, v in (("ewellix", 20), ("roller", 15), ("screw", 15), ("schaeffler", 10)) if k in r.url.lower())
            score += max(0, 20 - int(abs(len(r.content) - 1319760) / 200000))
            print("SCHAEFFLER", score, pages, len(r.content), r.url, text[:180], flush=True)
            row = (score, r.url, r.content, pages, text)
            if best is None or score > best[0]:
                best = row
        except Exception as exc:
            print("SCHAEFFLER_CANDIDATE_ERROR", u, repr(exc), flush=True)
    if best is None or best[0] < 170:
        raise RuntimeError(f"Schaeffler PDF not resolved, best={None if best is None else best[:2]}")
    score, url, content, pages, text = best
    path = out / "schaeffler_ewellix_roller_screw_en.pdf"
    path.write_bytes(content)
    return {"name": path.name, "url": url, "score": score, "pages": pages, "bytes": len(content), "sample": text[:400]}


def main() -> int:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "resolved_sources")
    out.mkdir(parents=True, exist_ok=True)
    rows = [resolve_whitepaper(out), resolve_schaeffler(out)]
    (out / "resolution_manifest.json").write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(rows, ensure_ascii=False, indent=2), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
