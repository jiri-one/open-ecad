#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline PDF -> Open ECAD graphics converter.

Converts the visible vector paths, text and raster images of selected PDF pages
into native Open ECAD (format version 2) page graphics. The import is purely
graphical: no devices or wires are created and electrical connectivity is NOT
reconstructed. Nothing is executed, fetched or uploaded; PDF JavaScript, links
and bookmarks are only counted, never evaluated.

This optional converter depends on PyMuPDF (AGPL-3.0), which is installed
separately; see scripts/import_pdf_requirements.txt.
"""
from __future__ import annotations

import argparse
import base64
import bisect
import hashlib
import json
import math
import os
import re
import stat
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

PINNED_PYMUPDF = '1.26.7'
TOOL_VERSION = 1
FORMAT_VERSION = 2
DESCRIPTION = 'PDF graphic import; connectivity not reconstructed'
MAX_DASH_VALUES = 64
MAX_IMAGE_DIMENSION = 16384
MAX_IMAGE_PIXELS = 64 * 1024 * 1024
PLACEHOLDER = '�'

WARNING_TEXT = {
    'fontSubstitution': (
        'Original fonts are not embedded in the output; text is drawn with the editor font '
        'scaled to the source text box.'),
    'strokeOnlyText': 'Stroke-only text is imported as filled text.',
    'verticalWriting': 'Vertical writing mode is imported as horizontal text.',
    'bidiText': 'Bidirectional text is imported in content-stream order.',
    'unmappedTextCharacters': (
        'Characters without a Unicode mapping were replaced by U+FFFD.'),
    'controlCharacters': 'Control characters in text were replaced by spaces.',
    'nonBmpText': 'Text contains characters outside the BMP (kept as-is).',
    'textSplit': 'Text spans longer than the text limit were split.',
    'degenerateText': 'Text with unusable direction or size was skipped.',
    'clipping': (
        'Clipping paths are not supported; clipped objects are imported '
        'without their clip.'),
    'transparencyGroups': (
        'Transparency groups and blend modes are not represented.'),
    'mixedLineCaps': (
        'Different start, end or dash caps on one path were approximated '
        'by a single cap style.'),
    'dashPhase': 'Dash phase offsets are not represented and were dropped.',
    'dashInvalid': 'Unusable dash patterns were imported as solid lines.',
    'pathSplit': 'Stroked paths over the segment limit were split.',
    'pathTooLong': (
        'Filled paths over the segment limit cannot be split and were '
        'skipped.'),
    'coordinateOutOfRange': (
        'Objects with coordinates outside the supported range were skipped.'),
    'fillStrokeSplit': (
        'Paths with different fill and stroke opacity were imported as two '
        'objects.'),
    'unsupportedPaint': (
        'Shadings, patterns or other paints without a colour are not '
        'imported.'),
    'shadingResources': (
        'The page declares shading or pattern resources that are not '
        'imported.'),
    'imageMask': 'Stencil image masks are not imported.',
    'inlineImage': 'Inline images are not extracted and were skipped.',
    'imageUnreadable': 'Images that could not be decoded were skipped.',
    'imageTooLarge': 'Images over the size limits were skipped.',
    'imageSkewed': (
        'Skewed images were approximated by a rotated rectangle.'),
    'imageMirrored': (
        'Mirrored images were flipped explicitly in the embedded PNG.'),
    'imageMaskIgnored': (
        'Explicit /Mask or colour-key masks are not applied to images.'),
    'imageOrder': 'Image paint order could not be determined exactly.',
    'layers': 'Optional-content layer membership is not preserved.',
    'pageRotation': 'Page rotation was applied to all coordinates.',
    'pymupdfVersion': 'PyMuPDF differs from the pinned version.',
    'mupdfWarnings': 'MuPDF reported warnings while reading the page.',
    'unsupportedOperations': (
        'Some paint operations are not supported and were skipped.'),
}


class UserError(Exception):
    """Readable failure caused by the input, options or environment."""


@dataclass(frozen=True)
class Limits:
    max_pages: int = 1024
    max_graphics: int = 500000
    max_path_segments: int = 10000
    max_total_path_segments: int = 4000000
    max_file_bytes: int = 128 * 1024 * 1024
    max_coordinate: float = 1e6
    max_text: int = 8192
    max_id: int = 128
    max_project_name: int = 200
    max_sheet_name: int = 200
    max_number: int = 32
    max_image_bytes: int = 16 * 1024 * 1024
    max_total_image_bytes: int = 64 * 1024 * 1024

    def to_json(self) -> dict:
        return {
            'maxPages': self.max_pages,
            'maxGraphics': self.max_graphics,
            'maxPathSegments': self.max_path_segments,
            'maxTotalPathSegments': self.max_total_path_segments,
            'maxFileBytes': self.max_file_bytes,
            'maxCoordinate': self.max_coordinate,
            'maxTextUtf16Units': self.max_text,
            'maxIdLength': self.max_id,
            'maxProjectNameLength': self.max_project_name,
            'maxSheetNameLength': self.max_sheet_name,
            'maxSheetNumberLength': self.max_number,
            'maxImageBytes': self.max_image_bytes,
            'maxTotalImageBytes': self.max_total_image_bytes,
        }


# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

def _load_pymupdf():
    try:
        import pymupdf  # type: ignore
    except ImportError as error:
        raise UserError(
            'PyMuPDF is not installed for this Python. Install it explicitly '
            'with "python -m pip install -r scripts/import_pdf_requirements.txt" '
            'in a dedicated virtual environment (this tool never installs '
            'packages itself).') from error
    return pymupdf


def _num(value: float):
    """Round to four decimals; integral values become ints (-0 -> 0)."""
    rounded = round(value, 4)
    if rounded == 0:
        return 0
    if rounded == int(rounded) and abs(rounded) < 1e15:
        return int(rounded)
    return rounded


def _utf16_len(text: str) -> int:
    return sum(2 if ord(c) > 0xFFFF else 1 for c in text)


def _truncate_utf16(text: str, limit: int) -> str:
    total = 0
    for index, char in enumerate(text):
        total += 2 if ord(char) > 0xFFFF else 1
        if total > limit:
            return text[:index]
    return text


_CONTROL_RE = re.compile('[\x00-\x1f\x7f-\x9f  ]')


def _clean_label(text: str, limit: int) -> str:
    text = _CONTROL_RE.sub(' ', text or '')
    text = re.sub(r' {2,}', ' ', text).strip()
    return _truncate_utf16(text, limit)


def _hex_color(color) -> str | None:
    if color is None:
        return None
    values = [min(1.0, max(0.0, float(c))) for c in color]
    if len(values) == 1:
        values = values * 3
    elif len(values) == 4:  # naive CMYK; PyMuPDF normally supplies RGB
        c, m, y, k = values
        values = [(1 - c) * (1 - k), (1 - m) * (1 - k), (1 - y) * (1 - k)]
    if len(values) != 3:
        return None
    return '#' + ''.join(f'{int(round(v * 255)):02X}' for v in values)


def _opacity(value) -> float:
    if value is None:
        return 1.0
    return min(1.0, max(0.0, round(float(value), 4)))


def _parse_dashes(text) -> tuple[list[float], float]:
    match = re.match(r'\s*\[(.*?)\]\s*([-+0-9.eE]*)', text or '')
    if not match:
        return [], 0.0
    try:
        values = [float(v) for v in match.group(1).split()]
        phase = float(match.group(2)) if match.group(2) else 0.0
    except ValueError:
        return [], 0.0
    return values, phase


def parse_pages(spec: str | None, page_count: int, limits: Limits) -> list[int]:
    """Return sorted unique 1-based page numbers; raises UserError."""
    if spec is None:
        selected = list(range(1, page_count + 1))
    else:
        selected_set: set[int] = set()
        if not spec.strip():
            raise UserError('--pages must not be empty.')
        for part in spec.split(','):
            part = part.strip()
            match = re.fullmatch(r'(\d+)(?:\s*-\s*(\d+))?', part)
            if not match:
                raise UserError(
                    f'Invalid page selection "{part}"; use e.g. 1,3-5.')
            first = int(match.group(1))
            last = int(match.group(2)) if match.group(2) else first
            if first < 1 or last < first:
                raise UserError(f'Invalid page range "{part}".')
            if last > page_count:
                raise UserError(
                    f'Page {last} is outside the document '
                    f'(1-{page_count}).')
            selected_set.update(range(first, last + 1))
        selected = sorted(selected_set)
    if len(selected) > limits.max_pages:
        raise UserError(
            f'{len(selected)} pages selected; the limit is {limits.max_pages}. '
            'Use --pages to import a subset.')
    return selected


# --------------------------------------------------------------------------
# Output plumbing
# --------------------------------------------------------------------------

class _HashingWriter:
    def __init__(self, fd: int, max_bytes: int):
        self._file = os.fdopen(fd, 'wb')
        self._hash = hashlib.sha256()
        self.size = 0
        self._max = max_bytes

    def write(self, text: str) -> None:
        data = text.encode('utf-8')
        self.size += len(data)
        if self.size > self._max:
            raise UserError(
                f'Output would exceed the {self._max} byte file limit. '
                'Use --pages to import fewer pages.')
        self._hash.update(data)
        self._file.write(data)

    def finish(self) -> str:
        self._file.flush()
        os.fsync(self._file.fileno())
        self._file.close()
        return self._hash.hexdigest()

    def abort(self) -> None:
        try:
            self._file.close()
        except OSError:
            pass


def _same_file(a: Path, b: Path) -> bool:
    try:
        if os.path.realpath(a) == os.path.realpath(b):
            return True
        if a.exists() and b.exists():
            return os.path.samefile(a, b)
    except OSError:
        pass
    return False


def _check_paths(source: Path, output: Path, report: Path | None) -> None:
    try:
        st = source.stat()
    except FileNotFoundError:
        raise UserError(f'Input file not found: {source.name}') from None
    except OSError as error:
        raise UserError(f'Cannot read input file: {error.strerror}') from None
    if not stat.S_ISREG(st.st_mode):
        raise UserError('Input must be a regular file.')
    for label, target in (('output', output), ('report', report)):
        if target is None:
            continue
        if _same_file(source, target):
            raise UserError(
                f'The {label} path refers to the input file; refusing to '
                'overwrite it.')
        if target.is_dir():
            raise UserError(f'The {label} path is a directory.')
        if not target.parent.is_dir():
            raise UserError(
                f'The {label} directory does not exist: {target.parent}')
    if report is not None and _same_file(output, report):
        raise UserError('The report path must differ from the output path.')


def _new_temp(target: Path) -> tuple[int, str]:
    try:
        return tempfile.mkstemp(
            dir=str(target.parent), prefix=f'.{target.name}.', suffix='.tmp')
    except OSError as error:
        raise UserError(
            f'Cannot create a temporary file next to {target.name}: '
            f'{error.strerror}') from None


def _target_mode(target: Path) -> int:
    try:
        return stat.S_IMODE(target.stat().st_mode)
    except OSError:
        mask = os.umask(0)
        os.umask(mask)
        return 0o666 & ~mask


# --------------------------------------------------------------------------
# Per-page conversion state
# --------------------------------------------------------------------------

@dataclass
class PageStats:
    source_page: int
    page_id: str
    name: str
    number: str
    width: float
    height: float
    rotation: int = 0
    paths: int = 0
    texts: int = 0
    images: int = 0
    path_segments: int = 0
    source_path_records: int = 0
    source_text_spans: int = 0
    source_images: int = 0
    unsupported: dict = field(default_factory=dict)
    ignored: dict = field(default_factory=dict)
    warnings: dict = field(default_factory=dict)  # code -> count
    mupdf_messages: list = field(default_factory=list)

    @property
    def graphics(self) -> int:
        return self.paths + self.texts + self.images

    def warn(self, code: str, count: int = 1) -> None:
        self.warnings[code] = self.warnings.get(code, 0) + count

    def bump(self, table: dict, key: str, count: int = 1) -> None:
        table[key] = table.get(key, 0) + count

    def to_json(self) -> dict:
        return {
            'sourcePage': self.source_page,
            'pageId': self.page_id,
            'name': self.name,
            'number': self.number,
            'width': _num(self.width),
            'height': _num(self.height),
            'rotation': self.rotation,
            'graphics': self.graphics,
            'paths': self.paths,
            'texts': self.texts,
            'images': self.images,
            'pathSegments': self.path_segments,
            'devices': 0,
            'wires': 0,
            'source': {
                'pathRecords': self.source_path_records,
                'textSpans': self.source_text_spans,
                'imageRecords': self.source_images,
            },
            'unsupported': dict(sorted(self.unsupported.items())),
            'ignored': dict(sorted(self.ignored.items())),
            'warnings': [
                {'code': code, 'message': WARNING_TEXT.get(code, code),
                 'count': count}
                for code, count in sorted(self.warnings.items())
            ],
            'mupdfMessages': self.mupdf_messages,
        }


class _Context:
    def __init__(self, limits: Limits, pymupdf):
        self.limits = limits
        self.mu = pymupdf
        self.total_graphics = 0
        self.total_segments = 0
        self.total_image_bytes = 0
        self.fonts: dict[str, int] = {}
        self.image_cache: dict = {}


class _Matrix:
    """Affine map x' = a x + c y + e, y' = b x + d y + f."""

    def __init__(self, a=1.0, b=0.0, c=0.0, d=1.0, e=0.0, f=0.0):
        self.a, self.b, self.c, self.d, self.e, self.f = a, b, c, d, e, f
        self.identity = (a, b, c, d, e, f) == (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)

    def point(self, x, y):
        if self.identity:
            return x, y
        return (self.a * x + self.c * y + self.e,
                self.b * x + self.d * y + self.f)

    def vector(self, x, y):
        if self.identity:
            return x, y
        return self.a * x + self.c * y, self.b * x + self.d * y


# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------

def _absolute_segments(items, close_path, matrix: _Matrix):
    """Flatten PyMuPDF path items to [(verb, [(x, y), ...])] in page space.

    Returns (segments, subpath_count), or (None, 0) for unknown items.
    Discontinuities start a
    new subpath with M. PyMuPDF reports `re`/`qu` items for closed
    rectangles/quads; they are emitted with their recorded winding.
    """
    segments: list[tuple[str, list]] = []
    current = None
    subpaths = 0

    def move(p):
        nonlocal current, subpaths
        segments.append(('M', [p]))
        current = p
        subpaths += 1

    def same(p, q):
        return q is not None and abs(p[0] - q[0]) < 1e-9 \
            and abs(p[1] - q[1]) < 1e-9

    for item in items:
        kind = item[0]
        if kind == 'l':
            p1 = matrix.point(item[1].x, item[1].y)
            p2 = matrix.point(item[2].x, item[2].y)
            if not same(p1, current):
                move(p1)
            segments.append(('L', [p2]))
            current = p2
        elif kind == 'c':
            p1 = matrix.point(item[1].x, item[1].y)
            c1 = matrix.point(item[2].x, item[2].y)
            c2 = matrix.point(item[3].x, item[3].y)
            p2 = matrix.point(item[4].x, item[4].y)
            if not same(p1, current):
                move(p1)
            segments.append(('C', [c1, c2, p2]))
            current = p2
        elif kind == 're':
            r = item[1]
            # Orientation +1: bottom-left, bottom-right, top-right, top-left
            # (counter-clockwise on screen); -1: the clockwise order from the
            # top-left corner. This is the winding PyMuPDF recorded.
            if item[2] >= 0:
                corners = [(r.x0, r.y1), (r.x1, r.y1), (r.x1, r.y0),
                           (r.x0, r.y0)]
            else:
                corners = [(r.x0, r.y0), (r.x1, r.y0), (r.x1, r.y1),
                           (r.x0, r.y1)]
            corners = [matrix.point(x, y) for x, y in corners]
            move(corners[0])
            for corner in corners[1:]:
                segments.append(('L', [corner]))
            segments.append(('Z', []))
            current = corners[0]
        elif kind == 'qu':
            q = item[1]
            # PyMuPDF records the polygon ul -> ll -> lr -> ur -> ul.
            corners = [matrix.point(p.x, p.y) for p in (q.ul, q.ll, q.lr, q.ur)]
            move(corners[0])
            for corner in corners[1:] + [corners[0]]:
                segments.append(('L', [corner]))
            current = corners[0]
        else:
            return None, 0
    if close_path and segments:
        segments.append(('Z', []))
    return segments, subpaths


def _split_segments(segments, cap):
    """Split a stroke-only path into chunks of at most `cap` segments."""
    chunks = []
    chunk: list = []
    current = None
    start = None
    for verb, points in segments:
        need_move = verb != 'M' and not chunk
        if len(chunk) + (2 if need_move else 1) > cap:
            chunks.append(chunk)
            chunk = []
            need_move = verb != 'M'
        if need_move and current is not None:
            chunk.append(('M', [current]))
        chunk.append((verb, points))
        if verb == 'M':
            current = start = points[0]
        elif verb == 'Z':
            current = start
        else:
            current = points[-1]
    if chunk:
        chunks.append(chunk)
    return chunks


def _path_graphic(gid, segments, stroke, fill, stroke_width, opacity, dash,
                  max_coord):
    xs: list[float] = []
    ys: list[float] = []
    for _, points in segments:
        for x, y in points:
            xs.append(x)
            ys.append(y)
    if not xs:
        return None
    left, top = min(xs), min(ys)
    right, bottom = max(xs), max(ys)
    position = (round(left, 4), round(top, 4))
    if max(abs(position[0]), abs(position[1]), abs(right), abs(bottom)) \
            > max_coord or not all(map(math.isfinite, xs + ys)):
        return 'range'
    px, py = position
    path = []
    for verb, points in segments:
        entry = {'verb': verb}
        if points:
            entry['points'] = [
                {'x': _num(x - px), 'y': _num(y - py)} for x, y in points]
        path.append(entry)
    graphic = {
        'id': gid,
        'kind': 'path',
        'position': {'x': _num(px), 'y': _num(py)},
        'width': _num(right - left),
        'height': _num(bottom - top),
        'path': path,
    }
    if stroke:
        graphic['stroke'] = stroke
    if fill:
        graphic['fill'] = fill
    if stroke and stroke_width != 1:
        graphic['strokeWidth'] = _num(stroke_width)
    if opacity != 1:
        graphic['opacity'] = _num(opacity)
    if dash:
        graphic['dash'] = [_num(v) for v in dash]
    return graphic


# --------------------------------------------------------------------------
# Text
# --------------------------------------------------------------------------

_BOLD_RE = re.compile(r'bold|black|heavy|demi', re.IGNORECASE)


def _text_graphics(span, matrix: _Matrix, new_id, stats: PageStats,
                   ctx: _Context):
    chars = span['chars']
    if not chars:
        return []
    dx, dy = matrix.vector(*span['dir'])
    norm = math.hypot(dx, dy)
    size = float(span['size'])
    if norm < 1e-9 or not size > 0 or not math.isfinite(size):
        stats.warn('degenerateText')
        return []
    angle = math.degrees(math.atan2(dy, dx))
    snapped = round(angle / 90) * 90
    if abs(angle - snapped) < 1e-3:
        angle = snapped
    rad = math.radians(angle)
    dx, dy = math.cos(rad), math.sin(rad)
    if angle in (0, 90, 180, 270, -90, -180):
        dx, dy = round(dx), round(dy)
    ux, uy = dy, -dx  # glyph "up" direction on screen
    rotation = angle % 360.0

    asc = float(span.get('ascender') or 0)
    desc = float(span.get('descender') or 0)
    above = size * asc / (asc - desc) if asc - desc > 0 and asc > 0 \
        else size * 0.8
    above = min(max(above, 0.0), size)

    bold = bool(int(span.get('flags', 0)) & 16) \
        or bool(_BOLD_RE.search(span.get('font', '')))
    color = _hex_color(span.get('color')) or '#000000'
    if span.get('wmode'):
        stats.warn('verticalWriting')
    if span.get('bidi_lvl'):
        stats.warn('bidiText')
    if span.get('layer'):
        stats.warn('layers')
    if span.get('type') == 1:
        stats.warn('strokeOnlyText')
    font = span.get('font') or 'unknown'

    # Resolve characters and page-space origins/advances.
    resolved = []
    for code, _glyph, origin, bbox in chars:
        if code == 0 or code == 0xFFFD or 0xD800 <= code <= 0xDFFF \
                or code > 0x10FFFF:
            char = PLACEHOLDER
            stats.warn('unmappedTextCharacters')
        elif code < 0x20 or 0x7F <= code <= 0x9F or code in (0x2028, 0x2029):
            char = ' '
            stats.warn('controlCharacters')
        else:
            char = chr(code)
            if code > 0xFFFF:
                stats.warn('nonBmpText')
        ox, oy = matrix.point(*origin)
        cx, cy = matrix.point((bbox[0] + bbox[2]) / 2, (bbox[1] + bbox[3]) / 2)
        advance = 2 * ((cx - ox) * dx + (cy - oy) * dy)
        resolved.append((char, ox, oy, advance))

    # Split by UTF-16 length so every text object respects the limit.
    chunks = []
    current: list = []
    units = 0
    for entry in resolved:
        u = _utf16_len(entry[0])
        if current and units + u > ctx.limits.max_text:
            chunks.append(current)
            current, units = [], 0
        current.append(entry)
        units += u
    if current:
        chunks.append(current)
    if len(chunks) > 1:
        stats.warn('textSplit', len(chunks) - 1)

    result = []
    for chunk in chunks:
        text = ''.join(c[0] for c in chunk)
        if not text.strip():
            stats.bump(stats.ignored, 'blankTextSpans')
            continue
        first, last = chunk[0], chunk[-1]
        length = (last[1] - first[1]) * dx + (last[2] - first[2]) * dy \
            + last[3]
        if not length > 0:
            length = size * 0.5 * len(chunk)
        px = first[1] + ux * above
        py = first[2] + uy * above
        if max(abs(px), abs(py), abs(length)) > ctx.limits.max_coordinate:
            stats.bump(stats.unsupported, 'textOutOfRange')
            stats.warn('coordinateOutOfRange')
            continue
        graphic = {
            'id': new_id(),
            'kind': 'text',
            'position': {'x': _num(px), 'y': _num(py)},
            'width': _num(max(length, 0.0001)),
            'height': _num(max(size, 0.0001)),
        }
        if round(rotation, 4) % 360 != 0:
            graphic['rotation'] = _num(rotation)
        graphic['fill'] = color
        if _opacity(span.get('opacity')) != 1:
            graphic['opacity'] = _num(_opacity(span.get('opacity')))
        graphic['text'] = text
        if round(size, 4) != 12:
            graphic['fontSize'] = _num(size)
        if bold:
            graphic['bold'] = True
        result.append(graphic)
        ctx.fonts[font] = ctx.fonts.get(font, 0) + 1
    return result


# --------------------------------------------------------------------------
# Images
# --------------------------------------------------------------------------

def _flip_rows(pix, mu):
    stride = pix.stride
    samples = bytes(pix.samples)
    rows = [samples[i:i + stride] for i in range(0, len(samples), stride)]
    flipped = b''.join(reversed(rows))
    return mu.Pixmap(pix.colorspace, pix.width, pix.height, flipped, pix.alpha)


def _image_graphic(doc, page, info, smask_by_xref, matrix, new_id, stats,
                   ctx: _Context):
    mu = ctx.mu
    limits = ctx.limits
    xref = info.get('xref') or 0
    if not xref:
        stats.warn('inlineImage')
        stats.bump(stats.unsupported, 'inlineImages')
        return None
    ta, tb, tc, td, te, tf = (float(v) for v in info['transform'])
    base = _Matrix(ta, tb, tc, td, te, tf)
    ox, oy = matrix.point(*base.point(0, 0))
    xx, xy = matrix.vector(ta, tb)
    yx, yy = matrix.vector(tc, td)
    flipped = False
    if xx * yy - xy * yx < 0:
        # Mirrored placement: flip the pixel rows so the frame is a pure
        # rotation (plus scale) that the editor can express.
        ox, oy = ox + yx, oy + yy
        yx, yy = -yx, -yy
        flipped = True
        stats.warn('imageMirrored')
    width = math.hypot(xx, xy)
    height = math.hypot(yx, yy)
    if not (width > 0 and height > 0):
        stats.bump(stats.unsupported, 'degenerateImages')
        return None
    if abs(xx * yx + xy * yy) > 1e-3 * width * height:
        stats.warn('imageSkewed')
    rotation = math.degrees(math.atan2(xy, xx))
    snapped = round(rotation / 90) * 90
    if abs(rotation - snapped) < 1e-3:
        rotation = snapped
    rotation %= 360.0
    if max(abs(ox), abs(oy), width, height) > limits.max_coordinate:
        stats.warn('coordinateOutOfRange')
        stats.bump(stats.unsupported, 'imageOutOfRange')
        return None

    key = (xref, flipped)
    encoded = ctx.image_cache.get(key)
    if encoded is None:
        try:
            pix = mu.Pixmap(doc, xref)
            if pix.colorspace is None or pix.colorspace.n not in (1, 3):
                alpha = pix.alpha
                pix = mu.Pixmap(mu.csRGB, pix)
                if alpha and not pix.alpha:
                    pix = mu.Pixmap(pix, 1)
            smask = smask_by_xref.get(xref, 0)
            if smask and not pix.alpha:
                mask = mu.Pixmap(doc, smask)
                if (mask.width, mask.height) != (pix.width, pix.height):
                    mask = mu.Pixmap(mask, pix.width, pix.height)
                pix = mu.Pixmap(pix, mask)
            elif info.get('has-mask') and not pix.alpha:
                stats.warn('imageMaskIgnored')
            if (pix.width > MAX_IMAGE_DIMENSION
                    or pix.height > MAX_IMAGE_DIMENSION
                    or pix.width * pix.height > MAX_IMAGE_PIXELS):
                stats.warn('imageTooLarge')
                stats.bump(stats.unsupported, 'oversizedImages')
                return None
            if flipped:
                pix = _flip_rows(pix, mu)
            png = pix.tobytes('png')
        except Exception:  # damaged image data; report and continue
            stats.warn('imageUnreadable')
            stats.bump(stats.unsupported, 'unreadableImages')
            return None
        if len(png) > limits.max_image_bytes:
            stats.warn('imageTooLarge')
            stats.bump(stats.unsupported, 'oversizedImages')
            return None
        encoded = (base64.b64encode(png).decode('ascii'), len(png))
        if len(ctx.image_cache) >= 4:
            ctx.image_cache.pop(next(iter(ctx.image_cache)))
        ctx.image_cache[key] = encoded
    data, size = encoded
    if ctx.total_image_bytes + size > limits.max_total_image_bytes:
        stats.warn('imageTooLarge')
        stats.bump(stats.unsupported, 'imagesOverTotalLimit')
        return None
    ctx.total_image_bytes += size
    graphic = {
        'id': new_id(),
        'kind': 'image',
        'position': {'x': _num(ox), 'y': _num(oy)},
        'width': _num(width),
        'height': _num(height),
    }
    if rotation != 0:
        graphic['rotation'] = _num(rotation)
    graphic['imageData'] = data
    return graphic


# --------------------------------------------------------------------------
# JavaScript / link / bookmark accounting (static counts only)
# --------------------------------------------------------------------------

_JS_ACTION_RE = re.compile(r'/S\s*/JavaScript\b')
_REF_RE = re.compile(r'(\d+)\s+0\s+R')


def _count_js(doc, xref: int, seen: set, depth: int = 0) -> int:
    if depth > 8 or xref in seen or not 0 < xref < doc.xref_length():
        return 0
    seen.add(xref)
    try:
        text = doc.xref_object(xref, compressed=True)
    except Exception:
        return 0
    total = len(_JS_ACTION_RE.findall(text))
    for match in re.finditer(r'/(?:A|Next)\s+(\d+)\s+0\s+R', text):
        total += _count_js(doc, int(match.group(1)), seen, depth + 1)
    for match in re.finditer(r'/Next\s*\[([^\]]*)\]', text):
        for ref in _REF_RE.finditer(match.group(1)):
            total += _count_js(doc, int(ref.group(1)), seen, depth + 1)
    return total


def _document_javascript(doc) -> dict:
    result = {'openActionOrAdditionalActions': 0, 'namedScripts': 0}
    try:
        catalog = doc.pdf_catalog()
        text = doc.xref_object(catalog, compressed=True)
    except Exception:
        return result
    result['openActionOrAdditionalActions'] = len(
        re.findall(r'/(?:OpenAction|AA)\b', text))
    match = re.search(r'/JavaScript\s+(\d+)\s+0\s+R', text)
    pending = [int(match.group(1))] if match else []
    visited = 0
    while pending and visited < 1000:
        node = pending.pop()
        visited += 1
        try:
            body = doc.xref_object(node, compressed=True)
        except Exception:
            continue
        for kid in re.finditer(r'/Kids\s*\[([^\]]*)\]', body):
            pending.extend(int(r.group(1)) for r in _REF_RE.finditer(kid.group(1)))
        for names in re.finditer(r'/Names\s*\[([^\]]*)\]', body):
            result['namedScripts'] += len(
                re.findall(r'\)\s*\d+\s+0\s+R', names.group(1)))
    return result


def _annotation_xrefs(doc, page) -> list[int]:
    try:
        kind, value = doc.xref_get_key(page.xref, 'Annots')
    except Exception:
        return []
    if kind == 'xref':
        try:
            value = doc.xref_object(int(value.split()[0]), compressed=True)
        except Exception:
            return []
    elif kind != 'array':
        return []
    return [int(m.group(1)) for m in _REF_RE.finditer(value)]


def _page_ignored(doc, page, stats: PageStats) -> None:
    """Count (never follow or run) links, annotations and JavaScript."""
    links = 0
    other = 0
    js = 0
    additional = 0
    for xref in _annotation_xrefs(doc, page):
        try:
            text = doc.xref_object(xref, compressed=True)
        except Exception:
            continue
        subtype = re.search(r'/Subtype\s*/(\w+)', text)
        if subtype and subtype.group(1) == 'Link':
            links += 1
        else:
            other += 1
        js += len(_JS_ACTION_RE.findall(text))
        if re.search(r'/AA\b', text):
            additional += 1
        for match in re.finditer(r'/A\s+(\d+)\s+0\s+R', text):
            js += _count_js(doc, int(match.group(1)), set())
    stats.ignored['linkAnnotations'] = links
    stats.ignored['javaScriptActions'] = js
    if other:
        stats.ignored['otherAnnotations'] = other
    if additional:
        stats.ignored['additionalActionDictionaries'] = additional
    try:
        if re.search(r'/AA\b', doc.xref_object(page.xref, compressed=True)):
            stats.ignored['pageAdditionalActions'] = 1
    except Exception:
        pass


# --------------------------------------------------------------------------
# Bookmarks (page tree only)
# --------------------------------------------------------------------------

def _page_names(doc) -> tuple[dict[int, str], int]:
    """Names for pages from the FIRST top-level bookmark tree only.

    Returns ({page: title}, total_bookmark_entries). In the supported source
    the first tree is the sheet tree; later trees (device lists etc.) are
    deliberately ignored. A page is named by its first leaf entry.
    """
    try:
        toc = doc.get_toc(simple=True)
    except Exception:
        return {}, 0
    names: dict[int, str] = {}
    first_root = None
    for index, (level, _title, _page) in enumerate(toc):
        if level == 1:
            first_root = index
            break
    if first_root is None:
        return names, len(toc)
    end = len(toc)
    for index in range(first_root + 1, len(toc)):
        if toc[index][0] <= 1:
            end = index
            break
    for index in range(first_root + 1, end):
        level, title, page = toc[index]
        is_leaf = index + 1 >= end or toc[index + 1][0] <= level
        if is_leaf and page >= 1 and page not in names:
            names[page] = title
    return names, len(toc)


# --------------------------------------------------------------------------
# Page conversion
# --------------------------------------------------------------------------

_PAINT_KINDS = {'fill-path', 'stroke-path', 'fill-text', 'stroke-text',
                'fill-image', 'fill-imgmask'}
_QUIET_KINDS = {'ignore-text', 'fill-text', 'stroke-text', 'fill-path',
                'stroke-path', 'fill-image'}


def _page_matrix(page) -> _Matrix:
    m = page.rotation_matrix
    return _Matrix(m.a, m.b, m.c, m.d, m.e, m.f)


def _convert_page(doc, page, number: int, name: str, page_id: str,
                  ctx: _Context, out: _HashingWriter, first_page: bool
                  ) -> PageStats:
    mu = ctx.mu
    limits = ctx.limits
    rect = page.rect
    width, height = float(rect.width), float(rect.height)
    if not (0 < width <= limits.max_coordinate
            and 0 < height <= limits.max_coordinate):
        raise UserError(f'Page {number} has an unsupported size.')
    stats = PageStats(
        source_page=number, page_id=page_id, name=name, number=str(number),
        width=width, height=height, rotation=int(page.rotation))
    matrix = _page_matrix(page)
    if page.rotation:
        stats.warn('pageRotation')

    bboxlog = page.get_bboxlog()
    painted = sum(1 for kind, _ in bboxlog if kind in _PAINT_KINDS)
    if ctx.total_graphics + painted > limits.max_graphics:
        raise UserError(
            f'Page {number} would exceed the {limits.max_graphics} graphics '
            'limit. Use --pages to import fewer pages.')
    for kind, _ in bboxlog:
        if kind not in _QUIET_KINDS:
            stats.bump(stats.unsupported, kind)
    if any(k not in _QUIET_KINDS and k != 'fill-imgmask'
           for k, _ in bboxlog):
        stats.warn('unsupportedOperations')

    try:
        for key in ('Resources/Shading', 'Resources/Pattern'):
            if doc.xref_get_key(page.xref, key)[0] != 'null':
                stats.warn('shadingResources')
                break
    except Exception:
        pass

    drawings = page.get_drawings(extended=True)
    traces = page.get_texttrace()
    image_infos = page.get_image_info(xrefs=True)
    smask_by_xref = {}
    try:
        for entry in page.get_images(full=True):
            smask_by_xref[entry[0]] = entry[1]
    except Exception:
        pass

    # Build the painter-ordered event list.
    events = []  # (seqno, order, kind, payload)
    clip_entries = 0
    group_entries = 0
    path_levels: list[tuple[int, int]] = []
    for drawing in drawings:
        kind = drawing.get('type')
        if kind == 'clip':
            clip_entries += 1
            continue
        if kind == 'group':
            group_entries += 1
            continue
        if kind not in ('s', 'f', 'fs'):
            stats.bump(stats.unsupported, f'drawing:{kind}')
            continue
        seq = drawing.get('seqno')
        if seq is None:
            seq = len(bboxlog) + len(events)
        stats.source_path_records += 1
        path_levels.append((seq, drawing.get('level') or 0))
        events.append((seq, 0, 'path', drawing))
    path_levels.sort()
    level_keys = [seq for seq, _ in path_levels]
    for trace in traces:
        ttype = trace.get('type')
        if ttype == 3:
            stats.bump(stats.ignored, 'invisibleTextSpans')
            continue
        if ttype not in (0, 1):
            stats.bump(stats.ignored, 'clipOnlyTextSpans')
            continue
        stats.source_text_spans += 1
        events.append((trace['seqno'], 1, 'text', trace))

    image_slots = [(i, b[0], b[1]) for i, b in enumerate(bboxlog)
                   if b[0] in ('fill-image', 'fill-imgmask')]
    used_slots: set[int] = set()
    for info in image_infos:
        bbox = info.get('bbox')
        best = None
        for slot in image_slots:
            if slot[0] in used_slots:
                continue
            diff = max(abs(slot[2][k] - bbox[k]) for k in range(4))
            if diff < 1.0 and (best is None or diff < best[0]):
                best = (diff, slot)
        if best is None:
            seq = len(bboxlog) + len(events)
            stats.warn('imageOrder')
            kind = 'fill-image'
        else:
            used_slots.add(best[1][0])
            seq, kind = best[1][0], best[1][1]
        stats.source_images += 1
        if kind == 'fill-imgmask':
            stats.warn('imageMask')
            stats.bump(stats.unsupported, 'imageMasks')
            continue
        events.append((seq, 2, 'image', info))
    events.sort(key=lambda e: (e[0], e[1]))

    if clip_entries:
        stats.bump(stats.unsupported, 'clipPaths', clip_entries)
    if group_entries:
        stats.bump(stats.unsupported, 'transparencyGroups', group_entries)
        stats.warn('transparencyGroups', group_entries)

    counter = 0

    def new_id() -> str:
        nonlocal counter
        counter += 1
        return f'g_{number:03d}_{counter:06d}'

    clipped_objects = 0

    out.write(('' if first_page else ',') + '{')
    head = {
        'id': page_id, 'name': name, 'number': str(number),
        'width': _num(width), 'height': _num(height), 'showFrame': False,
        'sourcePage': number,
    }
    out.write(json.dumps(head, separators=(',', ':'), ensure_ascii=True)[1:-1])
    out.write(',"devices":[],"wires":[],"graphics":[')
    first_graphic = True

    def emit(graphic) -> None:
        nonlocal first_graphic
        ctx.total_graphics += 1
        if ctx.total_graphics > limits.max_graphics:
            raise UserError(
                f'More than {limits.max_graphics} graphics; use --pages to '
                'import fewer pages.')
        out.write(('' if first_graphic else ',') + json.dumps(
            graphic, separators=(',', ':'), ensure_ascii=True))
        first_graphic = False

    for seq, _order, kind, payload in events:
        if kind == 'text':
            idx = bisect.bisect_left(level_keys, seq) - 1
            if clip_entries and idx >= 0 and path_levels[idx][1] > 0:
                clipped_objects += 1
            for graphic in _text_graphics(payload, matrix, new_id, stats, ctx):
                emit(graphic)
                stats.texts += 1
            continue
        if kind == 'image':
            graphic = _image_graphic(
                doc, page, payload, smask_by_xref, matrix, new_id, stats, ctx)
            if graphic is not None:
                emit(graphic)
                stats.images += 1
            continue

        d = payload
        if (d.get('level') or 0) > 0:
            clipped_objects += 1
        if d.get('layer'):
            stats.warn('layers')
        segments, subpaths = _absolute_segments(
            d['items'], d.get('closePath'), matrix)
        if segments is None or not segments:
            stats.bump(stats.unsupported, 'unknownPathItems')
            continue
        dtype = d['type']
        stroke = _hex_color(d.get('color')) if dtype in ('s', 'fs') else None
        fill = _hex_color(d.get('fill')) if dtype in ('f', 'fs') else None
        if stroke is None and fill is None:
            stats.bump(stats.unsupported, 'colorlessPaints')
            stats.warn('unsupportedPaint')
            continue
        stroke_opacity = _opacity(d.get('stroke_opacity'))
        fill_opacity = _opacity(d.get('fill_opacity'))
        width_value = float(d.get('width') or 0) if stroke else 1.0
        dash: list[float] = []
        line_cap = 0
        line_join = 0
        if stroke:
            dash_values, phase = _parse_dashes(d.get('dashes'))
            if dash_values:
                if (len(dash_values) > MAX_DASH_VALUES
                        or any(v < 0 or not math.isfinite(v)
                               for v in dash_values)
                        or not any(v > 0 for v in dash_values)):
                    stats.warn('dashInvalid')
                else:
                    dash = dash_values
                    if phase:
                        stats.warn('dashPhase')
            caps = d.get('lineCap') or (0,)
            line_cap = int(max(caps))
            line_join = int(d.get('lineJoin') or 0)
            if len(set(caps)) > 1:
                stats.warn('mixedLineCaps')

        # (stroke, fill, opacity) layers in PDF paint order: fill then stroke.
        layers = []
        if dtype == 'fs' and abs(stroke_opacity - fill_opacity) > 1e-4:
            layers.append((None, fill, fill_opacity))
            layers.append((stroke, None, stroke_opacity))
            stats.warn('fillStrokeSplit')
        elif dtype == 'f':
            layers.append((None, fill, fill_opacity))
        elif dtype == 's':
            layers.append((stroke, None, stroke_opacity))
        else:
            layers.append((stroke, fill, stroke_opacity))
        for layer_stroke, layer_fill, opacity in layers:
            parts = [segments]
            if len(segments) > limits.max_path_segments:
                if layer_fill:
                    stats.bump(stats.unsupported, 'oversizedFilledPaths')
                    stats.warn('pathTooLong')
                    continue
                parts = _split_segments(segments, limits.max_path_segments)
                stats.warn('pathSplit')
            for part in parts:
                ctx.total_segments += len(part)
                if ctx.total_segments > limits.max_total_path_segments:
                    raise UserError(
                        'Too many path segments in total; use --pages to '
                        'import fewer pages.')
                graphic = _path_graphic(
                    new_id(), part, layer_stroke, layer_fill, width_value,
                    opacity, dash, limits.max_coordinate)
                if graphic == 'range' or graphic is None:
                    stats.bump(stats.unsupported, 'pathsOutOfRange')
                    stats.warn('coordinateOutOfRange')
                    continue
                if layer_stroke and line_cap:
                    graphic['lineCap'] = line_cap
                if layer_stroke and line_join:
                    graphic['lineJoin'] = line_join
                if layer_fill and d.get('even_odd'):
                    graphic['evenOdd'] = True
                emit(graphic)
                stats.paths += 1
                stats.path_segments += len(part)

    out.write(']}')
    if clipped_objects or clip_entries:
        stats.bump(stats.unsupported, 'objectsImportedWithoutClip',
                   clipped_objects)
        stats.warn('clipping', max(clipped_objects, clip_entries))
    if stats.texts:
        stats.warn('fontSubstitution', stats.texts)
    _page_ignored(doc, page, stats)
    messages = mu.TOOLS.mupdf_warnings(reset=True)
    if messages:
        lines = [m for m in messages.splitlines() if m.strip()]
        stats.warn('mupdfWarnings', len(lines))
        stats.mupdf_messages = lines[:10]
    return stats


# --------------------------------------------------------------------------
# Public conversion API
# --------------------------------------------------------------------------

def convert(input_path, output_path, report_path=None, pages: str | None = None,
            limits: Limits = Limits()) -> dict:
    """Convert and return the report dict. Raises UserError on bad input."""
    source = Path(input_path)
    output = Path(output_path)
    report_target = Path(report_path) if report_path else None
    _check_paths(source, output, report_target)

    size = source.stat().st_size
    if size == 0:
        raise UserError('The input file is empty.')
    if size > limits.max_file_bytes:
        raise UserError(
            f'The input is {size} bytes; the limit is {limits.max_file_bytes}.')
    try:
        data = source.read_bytes()
    except OSError as error:
        raise UserError(f'Cannot read input file: {error.strerror}') from None
    if len(data) > limits.max_file_bytes:
        raise UserError('The input grew while reading; refusing to continue.')
    if b'%PDF-' not in data[:1024]:
        raise UserError('The input is not a PDF file (missing %PDF- header).')
    digest = hashlib.sha256(data).hexdigest()

    mu = _load_pymupdf()
    mu.TOOLS.mupdf_display_errors(False)
    mu.TOOLS.mupdf_warnings(reset=True)
    try:
        doc = mu.open(stream=data, filetype='pdf')
    except Exception as error:
        raise UserError(f'The PDF could not be opened: {error}') from None
    del data
    try:
        return _convert_document(
            mu, doc, source, output, report_target, pages, limits, digest, size)
    finally:
        doc.close()


def _convert_document(mu, doc, source, output, report_target, pages_spec,
                      limits, digest, source_size):
    if doc.needs_pass or doc.is_encrypted:
        raise UserError('The PDF is encrypted; decrypt it first. '
                        'Passwords are not accepted by this tool.')
    if not doc.is_pdf:
        raise UserError('The input is not a PDF document.')
    page_count = doc.page_count
    if page_count < 1:
        raise UserError('The PDF contains no pages.')
    selected = parse_pages(pages_spec, page_count, limits)

    names, bookmark_total = _page_names(doc)
    title = _clean_label((doc.metadata or {}).get('title') or '',
                         limits.max_project_name)
    stem = source.stem
    project_name = title or _clean_label(stem, limits.max_project_name) \
        or 'PDF import'
    project_id = f'project_{digest[:16]}'
    document_js = _document_javascript(doc)

    ctx = _Context(limits, mu)
    version_ok = mu.version[0] == PINNED_PYMUPDF
    page_stats: list[PageStats] = []

    fd, temp_name = _new_temp(output)
    writer = _HashingWriter(fd, limits.max_file_bytes)
    report_fd = report_temp = None
    try:
        header = {
            'format': 'open-ecad', 'formatVersion': FORMAT_VERSION,
            'id': project_id, 'name': project_name,
            'description': DESCRIPTION, 'revision': 0,
        }
        writer.write(json.dumps(
            header, separators=(',', ':'), ensure_ascii=True)[:-1]
            + ',"pages":[')
        for position, number in enumerate(selected):
            page = doc[number - 1]
            fallback = f'Page {number}'
            name = _clean_label(names.get(number, ''), limits.max_sheet_name) \
                or fallback
            page_id = f'page_{number:03d}'
            try:
                stats = _convert_page(
                    doc, page, number, name, page_id, ctx, writer,
                    position == 0)
            except UserError:
                raise
            except Exception as error:
                raise UserError(
                    f'Page {number} could not be read: '
                    f'{type(error).__name__}: {error}') from None
            if not version_ok:
                stats.warn('pymupdfVersion')
            page_stats.append(stats)
        writer.write(']}')
        output_sha = writer.finish()
        output_bytes = writer.size
    except BaseException:
        writer.abort()
        _unlink(temp_name)
        raise

    report = _build_report(
        mu, source, digest, source_size, page_count, selected, doc,
        project_id, project_name, limits, page_stats, ctx, names,
        bookmark_total, document_js, output_sha, output_bytes, version_ok)

    try:
        if report_target is not None:
            report_fd, report_temp = _new_temp(report_target)
            with os.fdopen(report_fd, 'wb') as handle:
                handle.write((json.dumps(
                    report, indent=2, ensure_ascii=True) + '\n').encode())
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(report_temp, _target_mode(report_target))
        os.chmod(temp_name, _target_mode(output))
        os.replace(temp_name, output)
        temp_name = None
        if report_target is not None:
            os.replace(report_temp, report_target)
            report_temp = None
    except OSError as error:
        raise UserError(f'Could not write output: {error.strerror}') from None
    finally:
        if temp_name:
            _unlink(temp_name)
        if report_temp:
            _unlink(report_temp)
    return report


def _unlink(path: str | None) -> None:
    if path:
        try:
            os.unlink(path)
        except OSError:
            pass


def _build_report(mu, source, digest, source_size, page_count, selected, doc,
                  project_id, project_name, limits, page_stats, ctx, names,
                  bookmark_total, document_js, output_sha, output_bytes,
                  version_ok) -> dict:
    totals = {'graphics': 0, 'paths': 0, 'texts': 0, 'images': 0,
              'pathSegments': 0}
    ignored: dict[str, int] = {}
    warnings: dict[str, dict] = {}
    for stats in page_stats:
        totals['graphics'] += stats.graphics
        totals['paths'] += stats.paths
        totals['texts'] += stats.texts
        totals['images'] += stats.images
        totals['pathSegments'] += stats.path_segments
        for key, value in stats.ignored.items():
            ignored[key] = ignored.get(key, 0) + value
        for code, count in stats.warnings.items():
            entry = warnings.setdefault(
                code, {'code': code, 'message': WARNING_TEXT.get(code, code),
                       'count': 0, 'pages': []})
            entry['count'] += count
            if len(entry['pages']) < 50:
                entry['pages'].append(stats.source_page)
    used_names = sum(1 for s in page_stats if s.source_page in names)
    ignored.setdefault('linkAnnotations', 0)
    ignored.setdefault('javaScriptActions', 0)
    ignored['documentJavaScriptNamedScripts'] = document_js['namedScripts']
    ignored['documentOpenActionOrAdditionalActions'] = \
        document_js['openActionOrAdditionalActions']
    ignored['bookmarkEntriesTotal'] = bookmark_total
    ignored['bookmarkEntriesUsedForPageNames'] = used_names
    ignored['bookmarkEntriesIgnored'] = max(0, bookmark_total - used_names)
    return {
        'tool': {
            'name': 'import_pdf.py', 'version': TOOL_VERSION,
            'pymupdf': mu.version[0], 'mupdf': mu.version[1],
            'pymupdfPinned': PINNED_PYMUPDF, 'pymupdfMatchesPin': version_ok,
        },
        'importMode': 'graphics',
        'electricalConnectivity': 'unverified',
        'semanticImport': False,
        'notes': [
            'Vector paths, visible text and images were imported as '
            'editable drawing graphics only.',
            'No devices or wires were created; electrical connectivity was '
            'not reconstructed and must not be assumed.',
            'PDF JavaScript, links and bookmark trees were not executed, '
            'followed or imported; they are only counted.',
        ],
        'source': {
            'fileName': source.name,
            'sha256': digest,
            'bytes': source_size,
            'pageCount': page_count,
            'selectedPages': list(selected),
            'title': _clean_label((doc.metadata or {}).get('title') or '', 200),
            'pdfFormat': (doc.metadata or {}).get('format') or '',
        },
        'output': {
            'format': 'open-ecad', 'formatVersion': FORMAT_VERSION,
            'projectId': project_id, 'projectName': project_name,
            'bytes': output_bytes, 'sha256': output_sha,
            'pages': len(page_stats), 'devices': 0, 'wires': 0,
        },
        'totals': {**totals, 'devices': 0, 'wires': 0,
                   'imagePngBytes': ctx.total_image_bytes},
        'limits': limits.to_json(),
        'ignored': dict(sorted(ignored.items())),
        'fonts': dict(sorted(ctx.fonts.items())),
        'warnings': sorted(warnings.values(), key=lambda w: w['code']),
        'pages': [s.to_json() for s in page_stats],
    }


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog='import_pdf.py',
        description='Convert PDF page graphics (paths, text, images) into an '
                    'Open ECAD .oecad file. Graphics only: no devices or '
                    'wires are created and connectivity is not inferred.')
    parser.add_argument('input', help='source PDF (never modified)')
    parser.add_argument('output', help='destination .oecad (written atomically)')
    parser.add_argument('--pages', metavar='RANGE',
                        help='1-based pages to import, e.g. 1,3-5 '
                             '(default: all)')
    parser.add_argument('--report', metavar='FILE',
                        help='write a machine-readable JSON import report')
    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    try:
        report = convert(args.input, args.output, args.report, args.pages)
    except UserError as error:
        print(f'import_pdf: error: {error}', file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print('import_pdf: interrupted; no output was changed.',
              file=sys.stderr)
        return 130
    except Exception as error:  # last resort: no traceback for users
        if os.environ.get('ECAD_PDF_DEBUG'):
            raise
        print(f'import_pdf: internal error: {type(error).__name__}: {error}',
              file=sys.stderr)
        return 70
    totals = report['totals']
    print(f"Imported {report['output']['pages']} page(s): "
          f"{totals['graphics']} graphics ({totals['paths']} paths, "
          f"{totals['texts']} texts, {totals['images']} images) -> "
          f"{args.output}")
    print('Mode: graphics only; no devices/wires; electrical connectivity '
          'unverified.')
    if report['warnings']:
        print(f"{len(report['warnings'])} warning type(s); see the report for "
              'details.' if args.report else
              f"{len(report['warnings'])} warning type(s); use --report for "
              'details.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
