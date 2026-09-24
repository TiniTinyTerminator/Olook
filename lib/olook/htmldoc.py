"""A full HTML document for the reading pane's web view.

`htmlrich` flattens a message down to the subset Qt's rich text understands,
which throws away the stylesheet every newsletter keeps its layout in. A
browser engine does not need that, so this keeps the message's own markup —
style blocks, classes, tables, the lot — and removes only what can act:
scripts, event handlers, frames, forms, and anything that would fetch from the
network.

Remote images are stripped here and forbidden again by a Content-Security-
Policy the document carries with it, so a tracking pixel has to get past two
separate refusals. `htmlrich.to_rich` stays the fallback for a shell without
the web renderer.
"""

import html
import re
from html.parser import HTMLParser

# Dropped along with everything inside them.
DROP_TREE = {"script", "noscript", "iframe", "frameset", "object", "applet",
             "form", "button", "select", "textarea", "title", "template",
             "svg"}
# Dropped themselves, contents kept: their children become our body.
UNWRAP = {"html", "head", "body"}
# Dropped as well, but void: no closing tag ever comes to bring a drop counter
# back down, so counting these would swallow the rest of the message.
DROP_VOID = {"meta", "link", "base", "input", "embed", "frame", "param",
             "source", "track", "col"}

VOID = {"area", "br", "col", "hr", "img", "source", "track", "wbr"}

# A url() the message can reach off this machine, in CSS or a style attribute.
REMOTE_URL = re.compile(r"url\(\s*['\"]?\s*(?!data:|file:|cid:|#)[^)]*\)",
                        re.IGNORECASE)
AT_IMPORT = re.compile(r"@import[^;]*;", re.IGNORECASE)
# A url() naming a file on this machine, which a message never has cause to.
LOCAL_URL = re.compile(r"url\(\s*['\"]?\s*file:[^)]*\)", re.IGNORECASE)

def _csp(allow_remote):
    """The policy the document carries with it.

    Images are the only thing a message is ever allowed to fetch, and only
    once the reader has asked for them: everything else stays 'none' whatever
    the setting, so "show images" cannot quietly become "run scripts".
    """
    images = "file: data: https: http:" if allow_remote else "file: data:"
    return (f"default-src 'none'; img-src {images}; style-src 'unsafe-inline'; "
            "font-src data:; script-src 'none'; frame-src 'none'; "
            "object-src 'none'; form-action 'none'; base-uri 'none'")

# Enough to make an unstyled message readable without overriding one that
# styles itself. The paper colour matches the card the view sits on.
BASE_CSS = """
html { -webkit-text-size-adjust: 100%; }
/* A page that sizes itself to its viewport cannot be shown in a view that
   sizes itself to the page: each one grows the other, and the message runs on
   until it hits the height cap with nothing in it. Mail asks for this to make
   a background colour fill the window, which is not something it gets to do
   here anyway. Height comes from content, and only from content. */
html, body { height: auto !important; min-height: 0 !important;
             max-height: none !important; }
body { margin: 0; padding: 0; background: #fbfbf9; color: #16181d;
       font: 15px/1.5 system-ui, -apple-system, "Segoe UI", Cantarell, sans-serif;
       overflow-wrap: break-word; }
img { max-width: 100%; height: auto; border: 0; }
/* The reading pane scrolls the message; the view is sized to its content and
   must not grow a second scrollbar of its own. */
html { scrollbar-width: none; }
::-webkit-scrollbar { width: 0; height: 0; }
table { max-width: 100%; }
a { color: #2c5cc5; }
"""

MAX_LENGTH = 400_000


class _Rewriter(HTMLParser):
    def __init__(self, images, allow_remote=False):
        super().__init__(convert_charrefs=True)
        self.images = images or {}
        self.allow_remote = allow_remote
        self.out = []
        self.css = []
        self.drop_depth = 0
        self.in_style = False
        self.blocked_images = 0

    # ---------------------------------------------------------------- tags

    def handle_starttag(self, tag, attrs):
        if tag in DROP_TREE:
            self.drop_depth += 1
            return
        if self.drop_depth or tag in DROP_VOID or tag in UNWRAP:
            return
        if tag == "style":
            # Hoisted into the head we build, rather than escaped as text.
            self.in_style = True
            return
        if tag == "img":
            self._image(dict(attrs))
            return
        self._emit(tag, dict(attrs))

    def handle_startendtag(self, tag, attrs):
        if tag in DROP_TREE or self.drop_depth or tag in DROP_VOID \
                or tag in UNWRAP or tag == "style":
            return
        if tag == "img":
            self._image(dict(attrs))
            return
        self._emit(tag, dict(attrs))

    def handle_endtag(self, tag):
        if tag in DROP_TREE:
            self.drop_depth = max(0, self.drop_depth - 1)
            return
        if self.drop_depth or tag in DROP_VOID or tag in UNWRAP:
            return
        if tag == "style":
            self.in_style = False
            return
        if tag not in VOID:
            self.out.append(f"</{tag}>")

    def handle_data(self, data):
        if self.drop_depth:
            return
        if self.in_style:
            self.css.append(_clean_css(data, self.allow_remote))
            return
        self.out.append(html.escape(data))

    def handle_comment(self, data):
        # Conditional comments are Outlook's business, not ours.
        pass

    # ------------------------------------------------------------- helpers

    def _emit(self, tag, attrs, trusted_src=False):
        self.out.append(f"<{tag}{self._attrs(attrs, trusted_src)}>")

    def _attrs(self, attrs, trusted_src=False):
        parts = []
        for name, value in attrs.items():
            name = str(name).lower()
            if value is None:
                parts.append(f" {html.escape(name, quote=True)}")
                continue
            value = str(value)
            # Anything that runs, points off the machine, or picks its own
            # image source behind our back.
            if name.startswith("on") or name in ("srcset", "ping", "formaction"):
                continue
            if name == "src" and trusted_src:
                pass    # a file this client wrote itself; see _image
            elif name in ("src", "background") and not _safe_image(value):
                continue
            elif name in ("href", "action", "cite") and not _safe_url(value):
                continue
            if name == "style":
                value = _clean_css(value, self.allow_remote)
                if not value.strip():
                    continue
            parts.append(f' {html.escape(name, quote=True)}='
                         f'"{html.escape(value, quote=True)}"')
        return "".join(parts)

    def _image(self, attrs):
        source = str(attrs.get("src") or "").strip()
        lowered = source.lower()
        if lowered.startswith("cid:"):
            local = self.images.get(source[4:].strip("<>"))
            if local:
                if not local.startswith(("file:", "data:")):
                    local = "file://" + local
                attrs["src"] = local
                self._emit("img", attrs, trusted_src=True)
                return
        elif lowered.startswith("data:image/"):
            self._emit("img", attrs)
            return
        if self.allow_remote and lowered.startswith(("http://", "https://")):
            # Asked for. The count stays at zero so the reading pane stops
            # offering to do what it has already done.
            self._emit("img", attrs)
            return
        # Remote: the src goes, the box stays, so a layout built on image
        # widths does not collapse around the hole.
        self.blocked_images += 1
        attrs.pop("src", None)
        attrs.pop("srcset", None)
        self._emit("img", attrs)


def _safe_url(value):
    """Where a link in a message may point.

    Live links are fine to keep: the view hands them to the browser instead
    of following them, and the policy blocks a silent fetch. A file:// link
    is not -- it would hand a path on this machine to xdg-open on one click,
    and a sender has no business pointing at your files.
    """
    lowered = str(value).strip().lower()
    return lowered.startswith(("http://", "https://", "mailto:", "tel:", "#"))


def _safe_image(value):
    """An image source a message may name itself: inline data, or the web
    (which the CSP still blocks until pictures are allowed). Its own
    attachments are pointed at by cid: and resolved in _image."""
    lowered = str(value).strip().lower()
    return lowered.startswith(("data:image/", "http://", "https://"))


def _clean_css(text, allow_remote=False):
    # @import always goes: it pulls in a whole stylesheet, which is not an
    # image and is not what the reader agreed to.
    text = LOCAL_URL.sub("none", AT_IMPORT.sub("", str(text)))
    if allow_remote:
        return text
    return REMOTE_URL.sub("none", text)


def to_fragment(source, images=None, allow_remote=True):
    """Return the message's markup as a block that can sit inside another one.

    Same cleaning as `to_document`, without the document around it: this is
    for quoting an original inside a reply, where the reply is the document
    and the original is a passage in it. The message's own stylesheet comes
    along, because most of what makes mail look like itself is in there.

    Remote images are kept by default. They belong to the message being
    quoted and are going back to the person who sent them; what matters is
    that nothing fetches them while the reply is only being written.
    """
    text = str(source or "")
    if not text.strip():
        return ""
    if len(text) > MAX_LENGTH:
        text = text[:MAX_LENGTH]

    parser = _Rewriter(images, allow_remote)
    try:
        parser.feed(text)
        parser.close()
    except Exception:
        return ""

    body = "".join(parser.out).strip()
    if not body:
        return ""
    style = _clean_css("\n".join(parser.css), allow_remote)
    return (f"<style>{style}</style>" if style.strip() else "") + body


def to_document(source, images=None, allow_remote=False):
    """Return {"html": <full document>, "blockedImages": n} for `source`.

    With `allow_remote`, images the message points at over the network are
    kept and the policy lets them through. Everything else is unchanged: this
    turns on pictures, not scripts, frames or stylesheets.
    """
    text = str(source or "")
    if not text.strip():
        return {"html": "", "blockedImages": 0}
    if len(text) > MAX_LENGTH:
        text = text[:MAX_LENGTH]

    parser = _Rewriter(images, allow_remote)
    try:
        parser.feed(text)
        parser.close()
    except Exception:
        # Malformed markup is not a reason to lose the message; the rich-text
        # rendering is still there to fall back on.
        return {"html": "", "blockedImages": 0}

    body = "".join(parser.out).strip()
    if not body:
        return {"html": "", "blockedImages": 0}
    style = _clean_css("\n".join(parser.css), allow_remote)
    document = (
        '<!DOCTYPE html><html><head><meta charset="utf-8">'
        f'<meta http-equiv="Content-Security-Policy" content="{_csp(allow_remote)}">'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        f"<style>{BASE_CSS}</style>"
        + (f"<style>{style}</style>" if style.strip() else "")
        + f"</head><body>{body}</body></html>"
    )
    return {"html": document, "blockedImages": parser.blocked_images}
