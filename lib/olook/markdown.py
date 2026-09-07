"""A small Markdown to HTML converter.

Mail clients that send Markdown send it as multipart/alternative: the source
as text/plain for people whose client shows plain text, the rendering as
text/html for everyone else. This covers the Markdown people actually write in
email — headings, emphasis, lists, quotes, code, links, rules — and leaves
anything more exotic as literal text rather than pulling in a dependency the
rest of Olook does not need.
"""

import html
import re

_FENCE = re.compile(r"^\s*(```|~~~)\s*([\w+-]*)\s*$")
_HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
_RULE = re.compile(r"^\s*([-*_])(\s*\1){2,}\s*$")
_UL = re.compile(r"^(\s*)[-*+]\s+(.*)$")
_OL = re.compile(r"^(\s*)(\d+)[.)]\s+(.*)$")
_QUOTE = re.compile(r"^\s*>\s?(.*)$")

_CODE_SPAN = re.compile(r"`([^`]+)`")
_IMAGE = re.compile(r"!\[([^\]]*)\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
_LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
_BOLD = re.compile(r"(\*\*|__)(?=\S)(.+?)(?<=\S)\1", re.S)
_ITALIC = re.compile(r"(?<![\w*_])([*_])(?=\S)(.+?)(?<=\S)\1(?![\w*_])", re.S)
_STRIKE = re.compile(r"~~(?=\S)(.+?)(?<=\S)~~", re.S)
_AUTOLINK = re.compile(r"(?<![\"'>=])\b(https?://[^\s<>\"']+)")


def to_html(source):
    """Render `source` as an HTML fragment (no <html> wrapper)."""
    lines = str(source or "").replace("\r\n", "\n").replace("\r", "\n").split("\n")
    out = []
    index = 0
    while index < len(lines):
        line = lines[index]

        fence = _FENCE.match(line)
        if fence:
            index += 1
            block = []
            while index < len(lines) and not _FENCE.match(lines[index]):
                block.append(lines[index])
                index += 1
            index += 1  # closing fence
            out.append("<pre><code>" + html.escape("\n".join(block)) + "</code></pre>")
            continue

        if not line.strip():
            index += 1
            continue

        if _RULE.match(line):
            out.append("<hr>")
            index += 1
            continue

        heading = _HEADING.match(line)
        if heading:
            level = len(heading.group(1))
            out.append(f"<h{level}>{inline(heading.group(2))}</h{level}>")
            index += 1
            continue

        if _QUOTE.match(line):
            block = []
            while index < len(lines) and _QUOTE.match(lines[index]):
                block.append(_QUOTE.match(lines[index]).group(1))
                index += 1
            out.append("<blockquote>" + to_html("\n".join(block)) + "</blockquote>")
            continue

        if _UL.match(line) or _OL.match(line):
            items, ordered, index = _list(lines, index)
            tag = "ol" if ordered else "ul"
            out.append(f"<{tag}>" + "".join(f"<li>{inline(i)}</li>" for i in items)
                       + f"</{tag}>")
            continue

        block = []
        while index < len(lines) and lines[index].strip() \
                and not _FENCE.match(lines[index]) and not _HEADING.match(lines[index]) \
                and not _RULE.match(lines[index]) and not _QUOTE.match(lines[index]) \
                and not _UL.match(lines[index]) and not _OL.match(lines[index]):
            block.append(lines[index].strip())
            index += 1
        # A newline inside a paragraph is a line break: that is what people
        # mean when they write mail, whatever CommonMark says.
        out.append("<p>" + "<br>".join(inline(part) for part in block) + "</p>")

    return "\n".join(out)


def _list(lines, index):
    """Collect one run of list items; returns (items, ordered, next_index)."""
    ordered = _OL.match(lines[index]) is not None
    items = []
    while index < len(lines):
        line = lines[index]
        match = _OL.match(line) if ordered else _UL.match(line)
        if match:
            items.append(match.group(3) if ordered else match.group(2))
            index += 1
            continue
        # A plain indented line continues the item above it.
        if items and line.strip() and line[:1] in (" ", "\t"):
            items[-1] += " " + line.strip()
            index += 1
            continue
        break
    return items, ordered, index


def inline(text):
    """Inline markup for one line of already-block-parsed Markdown."""
    placeholders = []

    def keep(markup):
        placeholders.append(markup)
        return f"\x00{len(placeholders) - 1}\x00"

    # Code spans first: nothing inside them is markup.
    text = _CODE_SPAN.sub(lambda m: keep("<code>" + html.escape(m.group(1)) + "</code>"),
                          str(text or ""))
    text = _IMAGE.sub(
        lambda m: keep(f'<a href="{html.escape(m.group(2), quote=True)}">'
                       + html.escape(m.group(1) or m.group(2)) + "</a>"), text)
    text = _LINK.sub(
        lambda m: keep(f'<a href="{html.escape(m.group(2), quote=True)}">'
                       + html.escape(m.group(1)) + "</a>"), text)

    text = html.escape(text)
    text = _BOLD.sub(lambda m: f"<b>{m.group(2)}</b>", text)
    text = _ITALIC.sub(lambda m: f"<i>{m.group(2)}</i>", text)
    text = _STRIKE.sub(lambda m: f"<s>{m.group(1)}</s>", text)
    text = _AUTOLINK.sub(lambda m: f'<a href="{m.group(1)}">{m.group(1)}</a>', text)

    for position, markup in enumerate(placeholders):
        text = text.replace(f"\x00{position}\x00", markup)
    return text


def document(fragment, font_family=None):
    """Wrap a fragment in the minimal document a mail client expects."""
    family = font_family or "-apple-system, Segoe UI, Helvetica, Arial, sans-serif"
    return (
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head>"
        f"<body style=\"font-family:{family};font-size:14px;line-height:1.5\">"
        f"{fragment}</body></html>"
    )
