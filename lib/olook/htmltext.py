"""HTML to readable plain text.

The reading pane renders text, not a browser engine, so an HTML-only message
has to be flattened. This is deliberately small: strip scripts and styles,
turn block elements into line breaks, keep link targets, unescape entities.
"""

import html
import re
from html.parser import HTMLParser

BLOCK = {
    "p", "div", "br", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6",
    "blockquote", "section", "article", "header", "footer", "table", "ul", "ol", "pre",
}
SKIP = {"script", "style", "head", "title", "meta", "link", "noscript"}


class _Flattener(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.chunks = []
        self.skip_depth = 0
        self.link = ""

    def handle_starttag(self, tag, attrs):
        if tag in SKIP:
            self.skip_depth += 1
            return
        if self.skip_depth:
            return
        if tag == "a":
            self.link = dict(attrs).get("href", "") or ""
        elif tag == "img":
            alt = dict(attrs).get("alt", "")
            if alt:
                self.chunks.append(f"[image: {alt}]")
        elif tag in ("hr",):
            self.chunks.append("\n" + "-" * 40 + "\n")
        elif tag == "li":
            self.chunks.append("\n  • ")
        elif tag in BLOCK:
            self.chunks.append("\n")

    def handle_endtag(self, tag):
        if tag in SKIP:
            self.skip_depth = max(0, self.skip_depth - 1)
            return
        if self.skip_depth:
            return
        if tag == "a" and self.link:
            target = self.link
            self.link = ""
            # Keep the URL only when the anchor text isn't already the URL.
            tail = "".join(self.chunks[-3:])
            if target.startswith("http") and target not in tail:
                self.chunks.append(f" <{target}>")
        elif tag in BLOCK:
            self.chunks.append("\n")

    def handle_data(self, data):
        if self.skip_depth:
            return
        self.chunks.append(re.sub(r"[ \t\r\f\v]+", " ", data))


def to_text(source):
    if not source:
        return ""
    parser = _Flattener()
    try:
        parser.feed(source)
        parser.close()
    except Exception:  # malformed markup shouldn't lose the message
        return re.sub(r"<[^>]+>", " ", html.unescape(source)).strip()
    text = "".join(parser.chunks)
    text = re.sub(r"[ \t]*\n[ \t]*", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def preview(text, limit=180):
    """One-line snippet for a message-list row."""
    flat = re.sub(r"\s+", " ", str(text or "")).strip()
    # Drop quoted replies and signature blocks from the snippet.
    flat = re.sub(r"^(>+\s*)+", "", flat)
    if len(flat) <= limit:
        return flat
    return flat[:limit - 1].rstrip() + "…"
