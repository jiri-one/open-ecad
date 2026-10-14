#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for scripts/import_pdf.py using locally generated synthetic PDFs.

Run with a Python that has PyMuPDF 1.26.7 installed:
    python scripts/test_import_pdf.py
"""
import base64
import contextlib
import hashlib
import io
import json
import math
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

try:
    import pymupdf
except ImportError:  # pragma: no cover - environment dependent
    pymupdf = None

import import_pdf  # noqa: E402

SCRIPT = HERE / 'import_pdf.py'
WRAPPER = HERE / 'import_pdf.sh'


def run_cli(*args):
    """Run main() in-process; returns (exit_code, stdout, stderr)."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            code = import_pdf.main([str(a) for a in args])
        except SystemExit as exit_:  # argparse usage errors
            code = exit_.code
    return code, out.getvalue(), err.getvalue()


def png_bytes(width, height, pixel, alpha=False):
    samples = b''.join(bytes(pixel(x, y)) for y in range(height)
                       for x in range(width))
    cs = pymupdf.csRGB
    pix = pymupdf.Pixmap(cs, width, height, samples, 1 if alpha else 0)
    return pix.tobytes('png')


def set_content(doc, page, content: str):
    xref = doc.get_new_xref()
    doc.update_object(xref, '<<>>')
    doc.update_stream(xref, content.encode())
    page.set_contents(xref)


@unittest.skipIf(pymupdf is None, 'PyMuPDF is not installed')
class ConverterTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='oecad-pdf-test-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    # -- helpers ----------------------------------------------------------
    def path(self, name):
        return self.tmp / name

    def convert(self, pdf, **kwargs):
        out = self.path('out.oecad')
        report = self.path('report.json')
        result = import_pdf.convert(pdf, out, report, **kwargs)
        return json.loads(out.read_text()), result, out, report

    def synthetic_pdf(self, name='synthetic.pdf'):
        doc = pymupdf.open()
        # Page 1: non-default size with every primitive family.
        p1 = doc.new_page(width=400, height=300)
        shape = p1.new_shape()
        shape.draw_line((10, 20), (110, 20))
        shape.finish(color=(1, 0, 0), width=2, closePath=False)
        shape.draw_rect(pymupdf.Rect(20, 40, 120, 90))
        shape.finish(color=(0, 0, 1), fill=(0, 1, 0), width=1.5)
        shape.draw_bezier((150, 100), (180, 40), (220, 160), (260, 100))
        shape.finish(color=(0, 0, 0), width=1, dashes='[4 2] 0',
                     closePath=False)
        shape.draw_rect(pymupdf.Rect(300, 20, 380, 60))
        shape.finish(color=None, fill=(0.5, 0.5, 0.5), fill_opacity=0.5)
        shape.commit()
        p1.insert_text((30, 150), 'Hello PDF', fontsize=14)
        p1.insert_text((300, 250), 'Up', fontsize=10, rotate=90)
        pix_png = png_bytes(8, 4, lambda x, y: (255 * (x < 4), 0, 255,
                                                0 if x == 0 and y == 0 else 255),
                            alpha=True)
        p1.insert_image(pymupdf.Rect(30, 180, 130, 230), stream=pix_png)
        # Page 2: different size, plain line only.
        p2 = doc.new_page(width=210, height=297)
        p2.draw_line((0, 0), (210, 297), color=(0, 0, 0))
        # Page 3: invisible text must be dropped, visible kept.
        p3 = doc.new_page(width=300, height=200)
        p3.insert_text((20, 50), 'visible', fontsize=12)
        p3.insert_text((20, 80), 'hidden ocr', fontsize=12, render_mode=3)
        # A link with a JavaScript action: counted, never executed.
        link_page = doc[1]
        link_page.insert_link({'kind': pymupdf.LINK_URI,
                               'from': pymupdf.Rect(5, 5, 50, 50),
                               'uri': 'https://example.invalid/'})
        link_page = doc.reload_page(link_page)
        link_xref = link_page.get_links()[0]['xref']
        action = doc.get_new_xref()
        doc.update_object(
            action, '<</S/JavaScript/JS(this.print\\(\\))>>')
        doc.xref_set_key(link_xref, 'A', f'{action} 0 R')
        doc.set_toc([
            [1, 'Page tree', 1],
            [2, 'Group', 1],
            [3, 'Sheet one', 1],
            [3, 'Sheet two', 2],
            [3, 'Sheet three', 3],
            [1, 'Device tree', 1],
            [2, 'Device A', 1],
            [2, 'Device B', 2],
        ])
        target = self.path(name)
        doc.save(target)
        doc.close()
        return target

    def single_page_pdf(self, content, name='single.pdf', width=200,
                        height=100, setup=None):
        doc = pymupdf.open()
        page = doc.new_page(width=width, height=height)
        if setup:
            setup(doc, page)
        if content is not None:
            set_content(doc, page, content)
        target = self.path(name)
        doc.save(target)
        doc.close()
        return target


class PrimitiveTests(ConverterTestCase):
    def test_full_primitive_preservation(self):
        pdf = self.synthetic_pdf()
        project, report, out, report_path = self.convert(pdf)

        self.assertEqual(project['format'], 'open-ecad')
        self.assertEqual(project['formatVersion'], 3)
        self.assertEqual(report['output']['formatVersion'], 3)
        self.assertEqual(project['revision'], 0)
        self.assertEqual(project['description'],
                         'PDF graphic import; connectivity not reconstructed')
        digest = hashlib.sha256(pdf.read_bytes()).hexdigest()
        self.assertEqual(project['id'], f'project_{digest[:16]}')
        self.assertEqual([p['id'] for p in project['pages']],
                         ['page_001', 'page_002', 'page_003'])
        self.assertEqual({tuple(sorted(p)) for p in project['pages']},
                         {tuple(sorted(
                             ['id', 'name', 'number', 'width', 'height',
                              'showFrame', 'sourcePage', 'devices', 'wires',
                              'graphics']))})
        for page in project['pages']:
            self.assertEqual(page['devices'], [])
            self.assertEqual(page['wires'], [])
            self.assertIs(page['showFrame'], False)
        self.assertEqual(
            [(p['width'], p['height']) for p in project['pages']],
            [(400, 300), (210, 297), (300, 200)])

        p1 = project['pages'][0]['graphics']
        kinds = [g['kind'] for g in p1]
        self.assertEqual(kinds.count('path'), 4)
        self.assertEqual(kinds.count('text'), 2)
        self.assertEqual(kinds.count('image'), 1)

        # Source-record accounting from the independent PyMuPDF view.
        doc = pymupdf.open(pdf)
        for index, page_report in enumerate(report['pages']):
            page = doc[index]
            drawings = [d for d in page.get_drawings(extended=True)
                        if d['type'] in ('s', 'f', 'fs')]
            spans = [t for t in page.get_texttrace() if t['type'] in (0, 1)]
            self.assertEqual(page_report['source']['pathRecords'], len(drawings))
            self.assertEqual(page_report['paths'], len(drawings))
            self.assertEqual(page_report['texts'], len(spans))
            self.assertEqual(page_report['images'],
                             len(page.get_image_info(xrefs=True)))
            self.assertEqual(
                page_report['graphics'], len(project['pages'][index]['graphics']))
        doc.close()

        # Path geometry: line, rect (closed, 4 corners), cubic curve.
        paths = [g for g in p1 if g['kind'] == 'path']
        line = paths[0]
        self.assertEqual([s['verb'] for s in line['path']], ['M', 'L'])
        self.assertEqual(line['stroke'], '#FF0000')
        self.assertEqual(line['strokeWidth'], 2)
        self.assertEqual(line['position'], {'x': 10, 'y': 20})
        self.assertEqual(line['height'], 0)
        self.assertNotIn('fill', line)
        rect = paths[1]
        self.assertEqual([s['verb'] for s in rect['path']],
                         ['M', 'L', 'L', 'L', 'Z'])
        self.assertEqual(rect['fill'], '#00FF00')
        self.assertEqual(rect['stroke'], '#0000FF')
        self.assertEqual((rect['width'], rect['height']), (100, 50))
        self.assertEqual(rect['path'][-1].get('points', []), [])
        curve = paths[2]
        self.assertEqual([s['verb'] for s in curve['path']], ['M', 'C'])
        self.assertEqual(len(curve['path'][1]['points']), 3)
        self.assertEqual(curve['dash'], [4, 2])
        # Bounds include the control points (y from 40-ish..160-ish).
        self.assertLess(curve['position']['y'], 100)
        self.assertGreater(curve['height'], 20)
        translucent = paths[3]
        self.assertEqual(translucent['opacity'], 0.5)
        self.assertNotIn('stroke', translucent)
        # Defaults are not serialised.
        self.assertNotIn('strokeWidth', translucent)
        for path in paths:
            for segment in path['path']:
                for point in segment.get('points', []):
                    self.assertGreaterEqual(point['x'], -1e-3)
                    self.assertGreaterEqual(point['y'], -1e-3)
                    self.assertLessEqual(point['x'], path['width'] + 1e-3)
                    self.assertLessEqual(point['y'], path['height'] + 1e-3)

        texts = [g for g in p1 if g['kind'] == 'text']
        self.assertEqual(texts[0]['text'], 'Hello PDF')
        self.assertEqual(texts[0]['fontSize'], 14)
        self.assertNotIn('rotation', texts[0])
        self.assertEqual(texts[0]['fill'], '#000000')
        self.assertEqual(texts[1]['text'], 'Up')
        self.assertAlmostEqual(texts[1]['rotation'], 270)

        image = [g for g in p1 if g['kind'] == 'image'][0]
        png = base64.b64decode(image['imageData'], validate=True)
        self.assertEqual(png[:8], b'\x89PNG\r\n\x1a\n')
        self.assertEqual(png[25], 6)  # RGBA: transparency retained
        decoded = pymupdf.Pixmap(png)
        self.assertEqual((decoded.width, decoded.height), (8, 4))
        self.assertEqual(decoded.pixel(0, 0)[3], 0)
        self.assertEqual(decoded.pixel(7, 3)[3], 255)
        self.assertEqual((image['width'], image['height']), (100, 50))
        self.assertEqual(image['position'], {'x': 30, 'y': 180})

        # Invisible OCR text is not imported.
        p3 = project['pages'][2]['graphics']
        self.assertEqual([g['text'] for g in p3], ['visible'])
        self.assertEqual(report['pages'][2]['ignored']['invisibleTextSpans'], 1)

    def test_graphics_only_report_and_unique_ids(self):
        pdf = self.synthetic_pdf()
        project, report, out, report_path = self.convert(pdf)
        ids = [g['id'] for p in project['pages'] for g in p['graphics']]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertTrue(all(len(i) <= 128 for i in ids))
        self.assertEqual(report['importMode'], 'graphics')
        self.assertEqual(report['electricalConnectivity'], 'unverified')
        self.assertIs(report['semanticImport'], False)
        self.assertEqual(report['totals']['devices'], 0)
        self.assertEqual(report['totals']['wires'], 0)
        self.assertEqual(report['output']['devices'], 0)
        self.assertEqual(report['totals']['graphics'], len(ids))
        self.assertEqual(report['source']['sha256'],
                         hashlib.sha256(pdf.read_bytes()).hexdigest())
        self.assertEqual(report['output']['sha256'],
                         hashlib.sha256(out.read_bytes()).hexdigest())
        self.assertEqual(report['output']['bytes'], out.stat().st_size)
        self.assertEqual(len(report['pages']), 3)
        codes = {w['code'] for w in report['warnings']}
        self.assertIn('fontSubstitution', codes)
        # No absolute source path anywhere in either artifact.
        for artifact in (out.read_text(), report_path.read_text()):
            self.assertNotIn(str(self.tmp), artifact)
            self.assertNotIn(str(pdf), artifact)
        # Every graphic satisfies the mandatory shape of the shared schema.
        for page in project['pages']:
            for g in page['graphics']:
                self.assertIn(g['kind'], ('path', 'text', 'image'))
                self.assertEqual(set(g['position']), {'x', 'y'})
                self.assertGreaterEqual(g['width'], 0)
                self.assertGreaterEqual(g['height'], 0)
                if g['kind'] != 'path':
                    self.assertGreater(g['width'], 0)
                    self.assertGreater(g['height'], 0)

    def test_ignored_javascript_links_and_page_tree_names(self):
        pdf = self.synthetic_pdf()
        project, report, _, _ = self.convert(pdf)
        self.assertEqual([p['name'] for p in project['pages']],
                         ['Sheet one', 'Sheet two', 'Sheet three'])
        ignored = report['ignored']
        self.assertEqual(ignored['linkAnnotations'], 1)
        self.assertEqual(ignored['javaScriptActions'], 1)
        self.assertEqual(report['pages'][1]['ignored']['javaScriptActions'], 1)
        self.assertEqual(ignored['bookmarkEntriesTotal'], 8)
        self.assertEqual(ignored['bookmarkEntriesUsedForPageNames'], 3)
        self.assertEqual(ignored['bookmarkEntriesIgnored'], 5)
        self.assertNotIn('Device', json.dumps(project))

    def test_page_subset(self):
        pdf = self.synthetic_pdf()
        project, report, _, _ = self.convert(pdf, pages='3,1')
        self.assertEqual([p['sourcePage'] for p in project['pages']], [1, 3])
        self.assertEqual([p['id'] for p in project['pages']],
                         ['page_001', 'page_003'])
        self.assertEqual(report['source']['selectedPages'], [1, 3])
        self.assertEqual(report['source']['pageCount'], 3)
        project, _, _, _ = self.convert(pdf, pages='2-3')
        self.assertEqual([p['sourcePage'] for p in project['pages']], [2, 3])

    def test_deterministic_output(self):
        pdf = self.synthetic_pdf()
        first = self.path('a.oecad')
        second = self.path('b.oecad')
        r1 = import_pdf.convert(pdf, first, self.path('a.json'))
        r2 = import_pdf.convert(pdf, second, self.path('b.json'))
        self.assertEqual(first.read_bytes(), second.read_bytes())
        self.assertEqual(self.path('a.json').read_bytes(),
                         self.path('b.json').read_bytes())
        self.assertEqual(r1['output']['sha256'], r2['output']['sha256'])

    def test_paint_order_follows_pdf_stream(self):
        def setup(doc, page):
            page.insert_text((20, 40), 'under', fontsize=12)
            page.draw_rect(pymupdf.Rect(10, 10, 80, 60), color=None,
                           fill=(1, 1, 1))
            page.draw_line((0, 70), (100, 70))
        pdf = self.single_page_pdf(None, setup=setup)
        project, _, _, _ = self.convert(pdf)
        order = [g['kind'] for g in project['pages'][0]['graphics']]
        self.assertEqual(order, ['text', 'path', 'path'])
        self.assertEqual(project['pages'][0]['graphics'][1]['fill'], '#FFFFFF')

    def test_quad_and_winding(self):
        pdf = self.single_page_pdf(
            '10 10 m 60 20 l 50 60 l 5 40 l h f '   # quad (4 lines, closed)
            '100 10 50 30 re f '                    # rectangle, +1
            '100 90 50 -30 re f '                   # rectangle, -1
            '1 0 0 RG 0 0 m 10 10 l 20 0 l 30 10 l S')
        project, report, _, _ = self.convert(pdf)
        graphics = project['pages'][0]['graphics']
        self.assertEqual(len(graphics), 4)
        quad = graphics[0]['path']
        self.assertEqual([s['verb'] for s in quad], ['M', 'L', 'L', 'L', 'L'])
        first, last = quad[0]['points'][0], quad[-1]['points'][0]
        self.assertEqual(first, last)  # polygon returns to its start
        rect_ccw, rect_cw = graphics[1]['path'], graphics[2]['path']
        # Counter-clockwise on screen starts bottom-left; clockwise top-left.
        self.assertEqual(rect_ccw[0]['points'][0], {'x': 0, 'y': 30})
        self.assertEqual(rect_cw[0]['points'][0], {'x': 0, 'y': 0})
        self.assertEqual(rect_ccw[-1]['verb'], 'Z')
        self.assertEqual(len(graphics[3]['path']), 4)

    def test_disconnected_subpaths_emit_move(self):
        pdf = self.single_page_pdf(
            '10 10 m 20 10 l 50 50 m 60 50 l 70 60 l S')
        project, _, _, _ = self.convert(pdf)
        verbs = [s['verb'] for s in project['pages'][0]['graphics'][0]['path']]
        self.assertEqual(verbs, ['M', 'L', 'M', 'L', 'L'])

    def test_fill_stroke_opacity_split_and_defaults(self):
        def setup(doc, page):
            gs = doc.get_new_xref()
            doc.update_object(gs, '<</Type/ExtGState/CA 0.3/ca 0.8>>')
            res = int(doc.xref_get_key(page.xref, 'Resources')[1].split()[0])
            doc.xref_set_key(res, 'ExtGState', f'<</G {gs} 0 R>>')
        pdf = self.single_page_pdf(
            '/G gs 1 0 0 rg 0 0 1 RG 3 w 10 10 50 30 re B', setup=setup)
        project, report, _, _ = self.convert(pdf)
        graphics = project['pages'][0]['graphics']
        self.assertEqual(len(graphics), 2)
        self.assertEqual((graphics[0]['fill'], graphics[0]['opacity']),
                         ('#FF0000', 0.8))
        self.assertEqual((graphics[1]['stroke'], graphics[1]['opacity']),
                         ('#0000FF', 0.3))
        self.assertIn('fillStrokeSplit', {w['code'] for w in report['warnings']})

    def test_clipping_is_reported_not_claimed(self):
        pdf = self.single_page_pdf(
            'q 10 10 50 30 re W n 0 0 100 100 re f Q 5 5 5 5 re f')
        project, report, _, _ = self.convert(pdf)
        page = report['pages'][0]
        self.assertEqual(page['unsupported']['clipPaths'], 1)
        self.assertEqual(page['unsupported']['objectsImportedWithoutClip'], 1)
        self.assertIn('clipping', {w['code'] for w in page['warnings']})
        self.assertEqual(len(project['pages'][0]['graphics']), 2)

    def test_dash_phase_warning_and_even_odd_preserved(self):
        pdf = self.single_page_pdf(
            '[3 1] 2 d 0 0 m 50 0 l S '
            '10 10 40 40 re 20 20 10 10 re f*')
        project, report, _, _ = self.convert(pdf)
        codes = {w['code'] for w in report['warnings']}
        self.assertIn('dashPhase', codes)
        self.assertNotIn('evenOddFill', codes)
        self.assertTrue(project['pages'][0]['graphics'][1]['evenOdd'])

    def test_round_square_caps_and_bevel_joins_preserved(self):
        pdf = self.single_page_pdf(
            '1 J 1 j 0 0 m 40 20 l 50 0 l S '
            '2 J 2 j 60 0 m 80 20 l 90 0 l S')
        project, report, _, _ = self.convert(pdf)
        paths = project['pages'][0]['graphics']
        self.assertEqual([(p['lineCap'], p['lineJoin']) for p in paths],
                         [(1, 1), (2, 2)])
        self.assertFalse(report['warnings'])

    def test_page_rotation_and_cropbox_applied(self):
        def setup(doc, page):
            page.set_cropbox(pymupdf.Rect(20, 10, 180, 90))
            page.insert_text((60, 50), 'Rot', fontsize=10)
            page.draw_rect(pymupdf.Rect(30, 20, 70, 30))
            page.set_rotation(90)
        pdf = self.single_page_pdf(None, setup=setup)
        project, report, _, _ = self.convert(pdf)
        sheet = project['pages'][0]
        self.assertEqual((sheet['width'], sheet['height']), (80, 160))
        self.assertIn('pageRotation',
                      {w['code'] for w in report['pages'][0]['warnings']})
        doc = pymupdf.open(pdf)
        page = doc[0]
        span = page.get_texttrace()[0]
        words = pymupdf.Rect(span['bbox'])
        # Texttrace is in unrotated space; map it to the displayed page.
        words = words * page.rotation_matrix
        text = sheet['graphics'][0]
        self.assertEqual(text['kind'], 'text')
        self.assert_box_close(text, words)
        doc.close()

    def aabb(self, g):
        w, h = g['width'], g['height']
        angle = math.radians(g.get('rotation', 0))
        px, py = g['position']['x'], g['position']['y']
        pts = [(px + x * math.cos(angle) - y * math.sin(angle),
                py + x * math.sin(angle) + y * math.cos(angle))
               for x, y in ((0, 0), (w, 0), (0, h), (w, h))]
        xs, ys = [p[0] for p in pts], [p[1] for p in pts]
        return min(xs), min(ys), max(xs), max(ys)

    def assert_box_close(self, graphic, rect, delta=0.05):
        box = self.aabb(graphic)
        for got, want in zip(box, (rect.x0, rect.y0, rect.x1, rect.y1)):
            self.assertAlmostEqual(got, want, delta=delta)

    def test_text_rotation_geometry(self):
        def setup(doc, page):
            page.insert_text((50, 100), 'Horizontal', fontsize=12)
            page.insert_text((100, 150), 'Up90', fontsize=12, rotate=90)
            page.insert_text((150, 150), 'Down', fontsize=12, rotate=270)
            page.insert_text((200, 100), 'Flip', fontsize=12, rotate=180)
            page.insert_text((60, 250), 'Diagonal', fontsize=12,
                             morph=(pymupdf.Point(60, 250), pymupdf.Matrix(30)))
        pdf = self.single_page_pdf(None, width=300, height=300, setup=setup)
        project, _, _, _ = self.convert(pdf)
        doc = pymupdf.open(pdf)
        spans = doc[0].get_texttrace()
        graphics = project['pages'][0]['graphics']
        self.assertEqual(len(spans), len(graphics))
        for span, graphic in zip(spans, graphics):
            self.assertEqual(graphic['text'],
                             ''.join(chr(c[0]) for c in span['chars']))
            self.assert_box_close(graphic, pymupdf.Rect(span['bbox']), 0.2)
        self.assertEqual(
            [g.get('rotation', 0) for g in graphics[:4]], [0, 270, 90, 180])
        self.assertAlmostEqual(graphics[4]['rotation'], 330, delta=0.01)
        doc.close()

    def test_bold_flag_and_unicode_text(self):
        def setup(doc, page):
            page.insert_text((10, 30), 'ASCII only', fontsize=10,
                             fontname='helv')
            page.insert_text((10, 60), 'Bold line', fontsize=10,
                             fontname='hebo')
        pdf = self.single_page_pdf(None, setup=setup)
        project, report, _, _ = self.convert(pdf)
        graphics = project['pages'][0]['graphics']
        self.assertNotIn('bold', graphics[0])
        self.assertIs(graphics[1].get('bold'), True)
        self.assertEqual(sum(report['fonts'].values()), 2)

    def test_text_nul_and_split(self):
        pdf = self.single_page_pdf(None, setup=lambda d, p: p.insert_text(
            (10, 30), 'abcdefghijklmnopqrstuvwxyz', fontsize=10))
        limits = import_pdf.Limits(max_text=10)
        project, report, _, _ = self.convert(pdf, limits=limits)
        texts = [g['text'] for g in project['pages'][0]['graphics']]
        self.assertEqual(texts, ['abcdefghij', 'klmnopqrst', 'uvwxyz'])
        self.assertEqual(''.join(texts), 'abcdefghijklmnopqrstuvwxyz')
        self.assertIn('textSplit',
                      {w['code'] for w in report['pages'][0]['warnings']})
        # Split chunks stay contiguous on the baseline.
        graphics = project['pages'][0]['graphics']
        self.assertAlmostEqual(
            graphics[0]['position']['x'] + graphics[0]['width'],
            graphics[1]['position']['x'], delta=0.5)

    def test_sanitize_text_characters(self):
        span = {
            'dir': (1.0, 0.0), 'size': 10.0, 'ascender': 0.9,
            'descender': -0.2, 'flags': 0, 'font': 'F', 'color': (0, 0, 0),
            'opacity': 1.0, 'type': 0,
            'chars': tuple(
                (code, 0, (10 + i * 5.0, 50.0),
                 (10 + i * 5.0, 41.0, 15 + i * 5.0, 52.0))
                for i, code in enumerate((0x41, 0, 0x01, 0x1F600, 0x42))),
        }
        stats = import_pdf.PageStats(1, 'page_001', 'n', '1', 100, 100)
        ctx = import_pdf._Context(import_pdf.Limits(), pymupdf)
        counter = iter(range(1, 100))
        graphics = import_pdf._text_graphics(
            span, import_pdf._Matrix(), lambda: f'id{next(counter)}', stats, ctx)
        self.assertEqual(len(graphics), 1)
        self.assertEqual(graphics[0]['text'], 'A� \U0001F600B')
        self.assertNotIn('\x00', graphics[0]['text'])
        self.assertIn('unmappedTextCharacters', stats.warnings)
        self.assertIn('controlCharacters', stats.warnings)
        self.assertIn('nonBmpText', stats.warnings)
        encoded = json.dumps(graphics[0], ensure_ascii=True)
        self.assertEqual(json.loads(encoded)['text'], graphics[0]['text'])


class ImageTests(ConverterTestCase):
    COLORS = {(0, 0): (255, 0, 0), (1, 0): (0, 255, 0),
              (0, 1): (0, 0, 255), (1, 1): (255, 255, 0)}

    def quadrant_png(self):
        return png_bytes(20, 12, lambda x, y: self.COLORS[(x >= 10, y >= 6)])

    def image_pdf(self, content, rotation=0):
        png = self.quadrant_png()

        # Build with a placeholder, then replace the content stream.
        doc = pymupdf.open()
        page = doc.new_page(width=300, height=200)
        page.insert_image(pymupdf.Rect(0, 0, 10, 10), stream=png)
        name = page.get_images(full=True)[0][7]
        set_content(doc, page, content.replace('NAME', name))
        if rotation:
            page.set_rotation(rotation)
        target = self.path('image.pdf')
        doc.save(target)
        doc.close()
        return target

    def assert_pixels_match(self, pdf):
        project, report, _, _ = self.convert(pdf)
        graphic = project['pages'][0]['graphics'][0]
        self.assertEqual(graphic['kind'], 'image')
        decoded = pymupdf.Pixmap(base64.b64decode(graphic['imageData']))
        doc = pymupdf.open(pdf)
        page = doc[0]
        scale = 4
        rendered = page.get_pixmap(matrix=pymupdf.Matrix(scale, scale),
                                   alpha=False)
        angle = math.radians(graphic.get('rotation', 0))
        for u in (0.25, 0.75):
            for v in (0.25, 0.75):
                x, y = u * graphic['width'], v * graphic['height']
                px = graphic['position']['x'] + x * math.cos(angle) \
                    - y * math.sin(angle)
                py = graphic['position']['y'] + x * math.sin(angle) \
                    + y * math.cos(angle)
                want = decoded.pixel(int(u * decoded.width),
                                     int(v * decoded.height))[:3]
                got = rendered.pixel(int(px * scale), int(py * scale))[:3]
                for a, b in zip(got, want):
                    self.assertAlmostEqual(a, b, delta=24,
                                           msg=f'{(u, v)} {got} != {want}')
        doc.close()
        return graphic, report

    def test_image_orientations(self):
        cases = {
            'upright': 'q 100 0 0 60 50 80 cm /NAME Do Q',
            'rotated90': 'q 0 100 -60 0 150 20 cm /NAME Do Q',
            'rotated180': 'q -100 0 0 -60 200 120 cm /NAME Do Q',
            'mirror-x': 'q -100 0 0 60 200 80 cm /NAME Do Q',
            'mirror-y': 'q 100 0 0 -60 50 140 cm /NAME Do Q',
            'mirror-rotated': 'q 0 100 60 0 90 20 cm /NAME Do Q',
        }
        for label, content in cases.items():
            with self.subTest(label):
                graphic, report = self.assert_pixels_match(
                    self.image_pdf(content))
                self.assertGreater(graphic['width'], 0)
                if label.startswith('mirror'):
                    self.assertIn('imageMirrored', {
                        w['code'] for w in report['pages'][0]['warnings']})
                else:
                    self.assertNotIn('imageMirrored', {
                        w['code'] for w in report['pages'][0]['warnings']})

    def test_image_with_page_rotation(self):
        self.assert_pixels_match(
            self.image_pdf('q 100 0 0 60 50 80 cm /NAME Do Q', rotation=90))
        self.assert_pixels_match(
            self.image_pdf('q -100 0 0 60 200 80 cm /NAME Do Q', rotation=270))

    def test_image_total_limit(self):
        pdf = self.image_pdf('q 100 0 0 60 50 80 cm /NAME Do Q')
        project, report, _, _ = self.convert(
            pdf, limits=import_pdf.Limits(max_image_bytes=10))
        self.assertEqual(project['pages'][0]['graphics'], [])
        self.assertIn('imageTooLarge',
                      {w['code'] for w in report['pages'][0]['warnings']})
        self.assertEqual(report['pages'][0]['source']['imageRecords'], 1)
        self.assertEqual(report['pages'][0]['images'], 0)


class SafetyTests(ConverterTestCase):
    def assert_no_temp_files(self):
        leftovers = [p.name for p in self.tmp.iterdir()
                     if p.name.endswith('.tmp')]
        self.assertEqual(leftovers, [])

    def test_refuses_to_overwrite_input_and_aliases(self):
        pdf = self.synthetic_pdf()
        original = pdf.read_bytes()
        code, _, err = run_cli(pdf, pdf)
        self.assertEqual(code, 1)
        self.assertIn('input', err)
        self.assertEqual(pdf.read_bytes(), original)
        link = self.path('link.oecad')
        link.symlink_to(pdf)
        code, _, err = run_cli(pdf, link)
        self.assertEqual(code, 1)
        self.assertEqual(pdf.read_bytes(), original)
        self.assertTrue(link.is_symlink())
        hard = self.path('hard.oecad')
        os.link(pdf, hard)
        code, _, err = run_cli(pdf, hard)
        self.assertEqual(code, 1)
        self.assertEqual(pdf.read_bytes(), original)
        # Report may not alias the input or the output either.
        code, _, err = run_cli(pdf, self.path('o.oecad'), '--report', pdf)
        self.assertEqual(code, 1)
        self.assertEqual(pdf.read_bytes(), original)
        code, _, err = run_cli(pdf, self.path('same'), '--report',
                               self.path('same'))
        self.assertEqual(code, 1)
        self.assert_no_temp_files()

    def test_failure_does_not_clobber_existing_output(self):
        pdf = self.synthetic_pdf()
        out = self.path('existing.oecad')
        report = self.path('existing.json')
        out.write_text('KEEP ME')
        report.write_text('KEEP REPORT')
        for pages in ('9', '0', '2-1', 'x', ''):
            code, _, err = run_cli(pdf, out, '--pages', pages, '--report',
                                   report)
            self.assertEqual(code, 1, pages)
            self.assertNotIn('Traceback', err)
            self.assertEqual(out.read_text(), 'KEEP ME')
            self.assertEqual(report.read_text(), 'KEEP REPORT')
        # A limit tripped mid-conversion also leaves the old file intact.
        with self.assertRaises(import_pdf.UserError):
            import_pdf.convert(pdf, out, report,
                               limits=import_pdf.Limits(max_graphics=3))
        self.assertEqual(out.read_text(), 'KEEP ME')
        with self.assertRaises(import_pdf.UserError):
            import_pdf.convert(pdf, out, report,
                               limits=import_pdf.Limits(max_file_bytes=2000))
        self.assertEqual(out.read_text(), 'KEEP ME')
        self.assert_no_temp_files()

    def test_success_replaces_existing_output_atomically(self):
        pdf = self.synthetic_pdf()
        out = self.path('existing.oecad')
        out.write_text('OLD')
        code, stdout, _ = run_cli(pdf, out)
        self.assertEqual(code, 0)
        self.assertIn('graphics only', stdout)
        self.assertEqual(json.loads(out.read_text())['format'], 'open-ecad')
        self.assert_no_temp_files()
        mode = stat.S_IMODE(out.stat().st_mode)
        self.assertTrue(mode & stat.S_IRUSR and mode & stat.S_IWUSR)

    def test_user_errors_are_readable(self):
        out = self.path('o.oecad')
        cases = {}
        empty = self.path('empty.pdf')
        empty.write_bytes(b'')
        cases['empty'] = empty
        text = self.path('text.pdf')
        text.write_text('hello world')
        cases['nonpdf'] = text
        broken = self.path('broken.pdf')
        broken.write_bytes(b'%PDF-1.4\n1 0 obj<<>>endobj\ngarbage\n')
        cases['malformed'] = broken
        zero = self.path('zero.pdf')
        zero.write_bytes(
            b'%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n'
            b'2 0 obj<</Type/Pages/Kids[]/Count 0>>endobj\n'
            b'trailer<</Root 1 0 R>>\n%%EOF\n')
        cases['zero pages'] = zero
        doc = pymupdf.open()
        doc.new_page()
        encrypted = self.path('enc.pdf')
        doc.save(encrypted, encryption=pymupdf.PDF_ENCRYPT_AES_256,
                 user_pw='secret', owner_pw='owner')
        doc.close()
        cases['encrypted'] = encrypted
        cases['missing'] = self.path('missing.pdf')
        cases['directory'] = self.tmp
        for label, source in cases.items():
            with self.subTest(label):
                result = subprocess.run(
                    [sys.executable, '-I', str(SCRIPT), str(source), str(out)],
                    capture_output=True, text=True)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertNotIn('Traceback', result.stderr)
                self.assertIn('import_pdf: error:', result.stderr)
                self.assertFalse(out.exists())
        self.assert_no_temp_files()
        # Missing output directory.
        code, _, err = run_cli(self.synthetic_pdf(),
                               self.path('nodir') / 'x.oecad')
        self.assertEqual(code, 1)
        self.assertIn('directory', err)

    def test_encrypted_message(self):
        doc = pymupdf.open()
        doc.new_page()
        encrypted = self.path('enc.pdf')
        doc.save(encrypted, encryption=pymupdf.PDF_ENCRYPT_AES_256,
                 user_pw='secret', owner_pw='owner')
        doc.close()
        code, _, err = run_cli(encrypted, self.path('o.oecad'))
        self.assertEqual(code, 1)
        self.assertIn('encrypted', err)

    def test_input_is_not_modified_and_not_embedded(self):
        pdf = self.synthetic_pdf()
        before = hashlib.sha256(pdf.read_bytes()).hexdigest()
        stat_before = pdf.stat().st_mtime_ns
        project, report, out, _ = self.convert(pdf)
        self.assertEqual(hashlib.sha256(pdf.read_bytes()).hexdigest(), before)
        self.assertEqual(pdf.stat().st_mtime_ns, stat_before)
        self.assertNotIn(b'%PDF', out.read_bytes())
        self.assertNotIn('http', out.read_text().replace(
            'http://www.w3.org', ''))


class LimitTests(ConverterTestCase):
    def test_graphics_cap(self):
        pdf = self.synthetic_pdf()
        with self.assertRaisesRegex(import_pdf.UserError, 'graphics'):
            import_pdf.convert(pdf, self.path('o'),
                               limits=import_pdf.Limits(max_graphics=5))
        _, report, _, _ = self.convert(
            pdf, limits=import_pdf.Limits(max_graphics=10),
            pages='2-3')
        self.assertEqual(report['totals']['graphics'], 2)

    def test_page_cap(self):
        pdf = self.synthetic_pdf()
        with self.assertRaisesRegex(import_pdf.UserError, 'pages'):
            import_pdf.convert(pdf, self.path('o'),
                               limits=import_pdf.Limits(max_pages=2))
        self.convert(pdf, pages='1-2', limits=import_pdf.Limits(max_pages=2))

    def test_input_size_cap(self):
        pdf = self.synthetic_pdf()
        with self.assertRaisesRegex(import_pdf.UserError, 'limit'):
            import_pdf.convert(pdf, self.path('o'),
                               limits=import_pdf.Limits(max_file_bytes=100))

    def test_path_segment_cap(self):
        stroked = ' '.join(f'{10 + i} {10 + (i % 7)} l' for i in range(25))
        pdf = self.single_page_pdf(f'10 10 m {stroked} S')
        limits = import_pdf.Limits(max_path_segments=10)
        project, report, _, _ = self.convert(pdf, limits=limits)
        graphics = project['pages'][0]['graphics']
        self.assertGreater(len(graphics), 1)
        total = 0
        for g in graphics:
            self.assertLessEqual(len(g['path']), 10)
            self.assertEqual(g['path'][0]['verb'], 'M')
            total += sum(1 for s in g['path'] if s['verb'] == 'L')
        self.assertEqual(total, 25)
        self.assertIn('pathSplit',
                      {w['code'] for w in report['pages'][0]['warnings']})
        # Filled paths cannot be split safely: skipped and reported.
        pdf = self.single_page_pdf(f'10 10 m {stroked} f', name='fill.pdf')
        project, report, _, _ = self.convert(pdf, limits=limits)
        self.assertEqual(project['pages'][0]['graphics'], [])
        self.assertIn('pathTooLong',
                      {w['code'] for w in report['pages'][0]['warnings']})
        self.assertEqual(
            report['pages'][0]['unsupported']['oversizedFilledPaths'], 1)

    def test_coordinate_cap_object_skipped(self):
        pdf = self.single_page_pdf(
            '0 0 m 10 10 l S 0 0 m 150 10 l S', width=100, height=100)
        project, report, _, _ = self.convert(
            pdf, limits=import_pdf.Limits(max_coordinate=120))
        self.assertEqual(len(project['pages'][0]['graphics']), 1)
        self.assertIn('coordinateOutOfRange',
                      {w['code'] for w in report['pages'][0]['warnings']})

    def test_page_size_cap(self):
        pdf = self.single_page_pdf('0 0 m 10 10 l S', width=200, height=200)
        with self.assertRaisesRegex(import_pdf.UserError, 'size'):
            import_pdf.convert(pdf, self.path('o'),
                               limits=import_pdf.Limits(max_coordinate=100))

    def test_name_limits(self):
        def setup(doc, page):
            doc.set_toc([[1, 'tree', 1], [2, 'N' * 500, 1]])
            doc.set_metadata({'title': 'T' * 500})
        pdf = self.single_page_pdf('0 0 m 10 10 l S', setup=setup)
        project, _, _, _ = self.convert(pdf)
        self.assertLessEqual(len(project['name']), 200)
        self.assertLessEqual(len(project['pages'][0]['name']), 200)
        self.assertLessEqual(len(project['pages'][0]['number']), 32)

    def test_parse_pages(self):
        limits = import_pdf.Limits()
        self.assertEqual(import_pdf.parse_pages(None, 4, limits), [1, 2, 3, 4])
        self.assertEqual(import_pdf.parse_pages('1,3-4,3', 4, limits), [1, 3, 4])
        for bad in ('', ' ', '0', '5', '2-1', 'a', '1,,2', '-1', '1-', '1.5'):
            with self.assertRaises(import_pdf.UserError, msg=bad):
                import_pdf.parse_pages(bad, 4, limits)


class SheetTypeClassifierTests(unittest.TestCase):
    def assertTypes(self, expected, titles):
        for title in titles:
            self.assertEqual(import_pdf.classify_sheet_type(title), expected,
                             title)

    def test_generic_title_words(self):
        self.assertTypes('cabinetLayout', [
            'Výstavba rozvaděče', 'VÝSTAVBA ROZVADĚČŮ', 'Rozmístění přístrojů',
            'Montážní deska B', 'Cabinet layout', 'Panel layout – door',
            'Schaltschrankaufbau'])
        self.assertTypes('singleLine', [
            'Jednopólové schéma napájení', 'Přívod dílny - 1P',
            'Rozvodnice – 1P', 'Zásuvkové okruhy (1P)', 'Single-line diagram',
            'Übersicht einpolig'])
        self.assertTypes('multiLine', [
            'Vícepólové schéma', 'Multi-line schematic', 'Multiline',
            'Mehrpoliger Stromlaufplan'])
        self.assertTypes('form', [
            'Formulář', 'Kusovník', 'Seznam svorek', 'Obsah', 'Titulní list',
            'Bill of materials', 'Table of contents', 'Stückliste'])

    def test_ambiguous_or_untyped_titles_are_not_guessed(self):
        self.assertTypes(None, [
            '', 'Page 4', 'Ovládání ventilátoru', 'Schéma zapojení',
            'Jistič 1P', 'Q-1P', 'Obsahuje rezervu', 'Jednopólové a '
            'vícepólové schéma', 'Seznam a výstavba rozvaděče',
            'Kusovník – 1P'])


class SheetTypeImportTests(ConverterTestCase):
    def titled_pdf(self, titles):
        doc = pymupdf.open()
        for index, _ in enumerate(titles):
            doc.new_page(width=200, height=100).insert_text(
                (20, 50), f'Strana {index + 1}', fontsize=10)
        doc.set_toc([[1, 'Listy', 1]] + [
            [2, title, index + 1] for index, title in enumerate(titles)])
        target = self.path('typed.pdf')
        doc.save(target)
        doc.close()
        return target

    def test_types_only_confidently_named_pages(self):
        pdf = self.titled_pdf([
            'Rozmístění přístrojů', 'Přívod dílny - 1P', 'Ovládání čerpadla',
            'Seznam svorek', 'Seznam a výstavba rozvaděče'])
        project, report, _, _ = self.convert(pdf)
        self.assertEqual([page.get('type') for page in project['pages']],
                         ['cabinetLayout', 'singleLine', None, 'form', None])
        self.assertEqual([page['sheetType'] for page in report['pages']],
                         ['cabinetLayout', 'singleLine', None, 'form', None])
        self.assertEqual(report['sheetTypes'], {
            'source': 'bookmarkTitle',
            'classified': {'cabinetLayout': 1, 'form': 1, 'singleLine': 1},
            'unclassified': 2,
        })
        # Graphics are unaffected by the page type.
        self.assertEqual([len(page['graphics']) for page in project['pages']],
                         [1] * 5)

    def test_pages_without_bookmarks_stay_untyped(self):
        pdf = self.single_page_pdf('0 0 m 10 10 l S')
        project, report, _, _ = self.convert(pdf)
        self.assertNotIn('type', project['pages'][0])
        self.assertEqual(report['sheetTypes']['classified'], {})
        self.assertEqual(report['sheetTypes']['unclassified'], 1)


@unittest.skipUnless(shutil.which('bash'), 'bash is required')
class WrapperTests(ConverterTestCase):
    def run_wrapper(self, env_extra, *args):
        env = {k: v for k, v in os.environ.items()
               if k not in ('ECAD_PDF_PYTHON',)}
        env.update(env_extra)
        return subprocess.run(['bash', str(WRAPPER), *map(str, args)],
                              capture_output=True, text=True, env=env)

    def test_wrapper_uses_explicit_python(self):
        pdf = self.synthetic_pdf()
        out = self.path('wrapped.oecad')
        result = self.run_wrapper({'ECAD_PDF_PYTHON': sys.executable}, pdf, out)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(out.exists())

    def test_wrapper_reports_missing_python_without_installing(self):
        result = self.run_wrapper(
            {'ECAD_PDF_PYTHON': str(self.path('no-such-python'))},
            self.path('x.pdf'), self.path('x.oecad'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ECAD_PDF_PYTHON', result.stderr)
        self.assertNotIn('Traceback', result.stderr)

    def test_wrapper_forwards_errors(self):
        result = self.run_wrapper({'ECAD_PDF_PYTHON': sys.executable},
                                  self.path('nope.pdf'), self.path('x.oecad'))
        self.assertEqual(result.returncode, 1)
        self.assertIn('not found', result.stderr)


if __name__ == '__main__':
    unittest.main()
