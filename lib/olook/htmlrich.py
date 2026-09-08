"""HTML for the reading pane.

Qt's rich text is not a browser: it understands a subset of HTML 4 and will
happily fetch any image URL it is handed. So mail HTML is rewritten before it
gets there — unknown and dangerous tags dropped, attributes reduced to the few
that matter, inline images pointed at the copies we already extracted, and
remote images removed rather than fetched, because a remote image in mail is
usually a tracking pixel.

`htmltext.to_text` stays the fallback for the plain-text view.
"""

import html
import re
from html.parser import HTMLParser

# Tags Qt's rich text renders, mapped to what we emit for them.
KEEP = {
    "p", "br", "b", "strong", "i", "em", "u", "s", "strike", "del", "sub", "sup",
    "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "pre",
    "code", "table", "thead", "tbody", "tr", "td", "th", "hr", "a", "img", "span",
    "div", "font", "center", "small", "big",
}
DROP_TREE = {"script", "style", "head", "title", "noscript", "object",
             "iframe", "applet", "form", "button", "select", "textarea",
             "svg", "video", "audio"}
# Dropped too, but these have no closing tag. Counting them the way the tree
# above is counted would leave the counter up for the rest of the message and
# swallow everything after the <meta> every mail carries in its head.
DROP_VOID = {"meta", "link", "base", "input", "embed", "source", "track",
             "param", "col"}
SELF_CLOSING = {"br", "hr", "img"}

# Attributes worth keeping: enough for structure and colour, nothing that can
# load or run anything.
ATTRS = {
    "a": ("href", "title"),
    "img": ("src", "alt", "width", "height"),
    "td": ("colspan", "rowspan", "align"),
    "th": ("colspan", "rowspan", "align"),
    "table": ("border", "cellpadding", "cellspacing", "width"),
    "font": ("color", "face"),
    "span": ("style",),
    "div": ("style", "align"),
    "p": ("style", "align"),
}
# Only colour-ish declarations survive from a style attribute; layout CSS is
# what makes mail HTML look broken in a rich-text widget.
STYLE_KEEP = re.compile(r"^(color|background-color|font-weight|font-style|"
                        r"text-decoration|text-align)$")

MAX_LENGTH = 400_000


class _Rewriter(HTMLParser):
    def __init__(self, images):
        super().__init__(convert_charrefs=True)
        self.images = images or {}
        self.out = []
        self.drop_depth = 0
        self.blocked_images = 0
        self.open_tags = []

    # ---------------------------------------------------------------- tags

    def handle_starttag(self, tag, attrs):
        if tag in DROP_VOID:
            return
        if tag in DROP_TREE:
            self.drop_depth += 1
            return
        if self.drop_depth:
            return
        if tag not in KEEP:
            return
        if tag == "img":
            self._image(dict(attrs))
            return
        # Mail HTML leaves list items and paragraphs open constantly; close
        # the previous one so the nesting Qt sees is the nesting intended.
        if tag in ("li", "p", "td", "th", "tr") and self.open_tags \
                and self.open_tags[-1] == tag:
            self.out.append(f"</{self.open_tags.pop()}>")
        rendered = self._attrs(tag, dict(attrs))
        self.out.append(f"<{tag}{rendered}>")
        if tag not in SELF_CLOSING:
            self.open_tags.append(tag)

    def handle_startendtag(self, tag, attrs):
        if tag in DROP_VOID or tag in DROP_TREE or self.drop_depth \
                or tag not in KEEP:
            return
        if tag == "img":
            self._image(dict(attrs))
            return
        self.out.append(f"<{tag}{self._attrs(tag, dict(attrs))}>")

    def handle_endtag(self, tag):
        if tag in DROP_VOID:
            return
        if tag in DROP_TREE:
            self.drop_depth = max(0, self.drop_depth - 1)
            return
        if self.drop_depth or tag not in KEEP or tag in SELF_CLOSING:
            return
        if tag in self.open_tags:
            # Close anything the message left dangling inside this element,
            # or Qt renders the rest of the mail inside a stray <b>.
            while self.open_tags:
                current = self.open_tags.pop()
                self.out.append(f"</{current}>")
                if current == tag:
                    break

    def handle_data(self, data):
        if self.drop_depth:
            return
        self.out.append(html.escape(data))

    # ------------------------------------------------------------ helpers

    def _attrs(self, tag, attrs):
        allowed = ATTRS.get(tag, ())
        parts = []
        for name in allowed:
            value = attrs.get(name)
            if not value:
                continue
            if name == "href" and not _safe_url(value):
                continue
            if name == "style":
                value = _clean_style(value)
                if not value:
                    continue
            parts.append(f' {name}="{html.escape(str(value), quote=True)}"')
        return "".join(parts)

    def _image(self, attrs):
        source = str(attrs.get("src") or "").strip()
        alt = str(attrs.get("alt") or "").strip()
        if source.lower().startswith("cid:"):
            local = self.images.get(source[4:].strip("<>"))
            if local:
                if not local.startswith(("file:", "data:")):
                    local = "file://" + local
                self.out.append(f'<img src="{html.escape(local, quote=True)}">')
                return
        elif source.lower().startswith("data:image/"):
            self.out.append(f'<img src="{html.escape(source, quote=True)}">')
            return
        # Anything remote: not fetched. A pixel nobody sees is the point.
        self.blocked_images += 1
        if alt:
            self.out.append(f"[{html.escape(alt)}]")

    def close_all(self):
        while self.open_tags:
            self.out.append(f"</{self.open_tags.pop()}>")


def _safe_url(value):
    lowered = str(value).strip().lower()
    return lowered.startswith(("http://", "https://", "mailto:", "tel:", "#"))


def _clean_style(value):
    kept = []
    for declaration in str(value).split(";"):
        name, _, setting = declaration.partition(":")
        name = name.strip().lower()
        setting = setting.strip()
        if setting and STYLE_KEEP.match(name) and "url(" not in setting.lower():
            kept.append(f"{name}:{setting}")
    return ";".join(kept)


def to_rich(source, images=None):
    """Return {"html": <safe rich text>, "blockedImages": n} for `source`."""
    text = str(source or "")
    if not text.strip():
        return {"html": "", "blockedImages": 0}
    if len(text) > MAX_LENGTH:
        text = text[:MAX_LENGTH]

    parser = _Rewriter(images)
    try:
        parser.feed(text)
        parser.close()
    except Exception:
        # Malformed markup should degrade to text, never lose the message.
        from . import htmltext
        return {"html": html.escape(htmltext.to_text(text)).replace("\n", "<br>"),
                "blockedImages": 0}
    parser.close_all()
    rendered = "".join(parser.out)
    rendered = re.sub(r"(?:\s*<br>\s*){3,}", "<br><br>", rendered)
    return {"html": rendered.strip(), "blockedImages": parser.blocked_images}
