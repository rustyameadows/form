#!/usr/bin/env python3
"""Independent, read-only construction packet audit (stdlib, no LAB or MCP).

Default inputs are sibling construction-packets/* folders containing Manifest.json.
Reports go to proofs/packet-audit.json, outside the immutable packets. Checks source
expressions with a whitelisted AST interpreter, source/contour equivalence by
vertical material slices, independent polygon packing separation, and actual
PDF stroked-path coordinates in points. Reports are written outside packets.
Visual quality and manufacturing/tool performance require separate review.
"""
import argparse
import ast
import collections
import copy
import hashlib
import json
import math
import operator
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET
import zlib

HERE = Path(__file__).resolve().parent
EPS = 2e-5
PDF_EPS_MM = 0.001
UNIT = 72 / 25.4
NS = '{http://www.w3.org/2000/svg}'
NUMBER = r'[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?'


def read_json(path):
    return json.loads(path.read_text())


def numeric_equal(a, b, tolerance=EPS):
    if isinstance(a, bool) or isinstance(b, bool):
        return a == b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return math.isfinite(a) and math.isfinite(b) and abs(a-b) <= tolerance
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(numeric_equal(a[k], b[k], tolerance) for k in a)
    if isinstance(a, (tuple, list)) and isinstance(b, (tuple, list)):
        return len(a) == len(b) and all(numeric_equal(x, y, tolerance) for x, y in zip(a, b))
    return a == b


class Expressions:
    """No Python eval: numeric constants, names, arithmetic, and known math calls."""
    funcs = {'min': min, 'max': max, 'abs': abs, 'sqrt': math.sqrt, 'sin': math.sin,
             'cos': math.cos, 'tan': math.tan, 'floor': math.floor, 'ceil': math.ceil,
             'round': lambda x: math.floor(x+0.5), 'pow': pow, 'clamp': lambda x, lo, hi: max(lo, min(hi, x))}
    binary = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul,
              ast.Div: operator.truediv, ast.Mod: operator.mod, ast.Pow: operator.pow}

    def __init__(self, definition, overrides):
        self.values = {p['name']: float(overrides.get(p['name'], p['value'])) for p in definition['parameters']}
        self.values.update(fold=100.0, opening=0.0, explosion=0.0, pi=math.pi)
        pending = dict(definition.get('derived', {}))
        while pending:
            progress = False
            for name, expression in list(pending.items()):
                try:
                    self.values[name] = self.number(expression)
                except KeyError:
                    continue
                del pending[name]
                progress = True
            if not progress:
                raise ValueError('Unresolved/cyclic source aliases: '+', '.join(pending))

    def number(self, value):
        if isinstance(value, (float, int)):
            result = float(value)
        else:
            if isinstance(value, dict):
                value = value['expression']
            node = ast.parse(str(value).replace('^', '**'), mode='eval').body
            result = float(self.node(node))
        if not math.isfinite(result):
            raise ValueError('Nonfinite source scalar')
        return result

    def node(self, node):
        if isinstance(node, ast.Constant) and type(node.value) in (float, int):
            return node.value
        if isinstance(node, ast.Name):
            return self.values[node.id]
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub)):
            value = self.node(node.operand)
            return -value if isinstance(node.op, ast.USub) else value
        if isinstance(node, ast.BinOp) and type(node.op) in self.binary:
            a, b = self.node(node.left), self.node(node.right)
            if isinstance(node.op, ast.Pow) and abs(b) > 100:
                raise ValueError('Excessive source exponent')
            return self.binary[type(node.op)](a, b)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in self.funcs and not node.keywords:
            return self.funcs[node.func.id](*(self.node(a) for a in node.args))
        raise ValueError('Unsupported/non-numeric source expression: '+ast.dump(node))

    def polygon(self, points):
        return [(self.number(p['x']), self.number(p['y'])) for p in points]


def cut_lattice(value):
    # Production CFormClipper input contract: std::llround(mm*1000),
    # then exact integer polygon operations. Keep the audit's tolerance strict.
    return (math.floor(value*1000+0.5) if value >= 0 else math.ceil(value*1000-0.5))/1000


def points(values):
    return [(p['x'], p['y']) for p in values]


def segments(polygon):
    return list(zip(polygon, polygon[1:]+polygon[:1]))


def bounds(polygons):
    coords = [p for polygon in polygons for p in polygon]
    xs, ys = zip(*coords)
    return {'x': min(xs), 'y': min(ys), 'width': max(xs)-min(xs), 'height': max(ys)-min(ys)}


def intervals(polygons, x):
    crossing = []
    for polygon in polygons:
        for a, b in segments(polygon):
            if (a[0] <= x < b[0]) or (b[0] <= x < a[0]):
                crossing.append(a[1]+(b[1]-a[1])*(x-a[0])/(b[0]-a[0]))
    crossing.sort()
    if len(crossing) % 2:
        raise ValueError('Odd polygon scanline crossing')
    return [(a, b) for a, b in zip(crossing[::2], crossing[1::2]) if b-a > EPS]


def union_intervals(values):
    result = []
    for a, b in sorted(values):
        if result and a <= result[-1][1]+EPS:
            result[-1] = (result[-1][0], max(b, result[-1][1]))
        else:
            result.append((a, b))
    return result


def material_slices(shapes, x):
    # Each shape is an outer panel with zero or more holes; shapes are unioned.
    return union_intervals([pair for shape in shapes for pair in intervals(shape, x)])


def equivalent_material(source_shapes, cut_polygons, tolerance=EPS):
    all_polygons = [p for shape in source_shapes for p in shape]+cut_polygons
    xs = set(p[0] for polygon in all_polygons for p in polygon)
    edges = [edge for polygon in all_polygons for edge in segments(polygon)]
    # Include intersections, so ordering cannot change inside an audited slab.
    for index, (a, b) in enumerate(edges):
        for c, d in edges[index+1:]:
            den = (b[0]-a[0])*(d[1]-c[1])-(b[1]-a[1])*(d[0]-c[0])
            if abs(den) < 1e-12:
                continue
            t = ((c[0]-a[0])*(d[1]-c[1])-(c[1]-a[1])*(d[0]-c[0]))/den
            u = ((c[0]-a[0])*(b[1]-a[1])-(c[1]-a[1])*(b[0]-a[0]))/den
            if 0 < t < 1 and 0 < u < 1:
                xs.add(a[0]+t*(b[0]-a[0]))
    xs = sorted(xs)
    area = 0.0
    for left, right in zip(xs, xs[1:]):
        if right-left < tolerance:
            continue
        lengths = []
        for f in (0.25, 0.75):
            x = left+(right-left)*f
            a, b = material_slices(source_shapes, x), intervals(cut_polygons, x)
            if not numeric_equal(a, b, tolerance):
                return False, None
            lengths.append(sum(hi-lo for lo, hi in b))
        area += (right-left)*sum(lengths)/2
    return True, area


def transformed(polygons, transform):
    t = transform
    return [[(t['a']*x+t['c']*y+t['tx'], t['b']*x+t['d']*y+t['ty']) for x, y in polygon] for polygon in polygons]


def inside(polygons, point):
    x, y = point
    return any(a+EPS < y < b-EPS for a, b in intervals(polygons, x+1e-9))


def point_distance(point, edge):
    a, b = edge
    den = (b[0]-a[0])**2+(b[1]-a[1])**2
    t = 0 if den == 0 else max(0, min(1, ((point[0]-a[0])*(b[0]-a[0])+(point[1]-a[1])*(b[1]-a[1]))/den))
    return math.hypot(point[0]-a[0]-t*(b[0]-a[0]), point[1]-a[1]-t*(b[1]-a[1]))


def separation(a, b):
    ea = [edge for p in a for edge in segments(p)]
    eb = [edge for p in b for edge in segments(p)]
    distance = math.inf
    for p, q in ea:
        for r, s in eb:
            den = (q[0]-p[0])*(s[1]-r[1])-(q[1]-p[1])*(s[0]-r[0])
            if abs(den) > 1e-12:
                t = ((r[0]-p[0])*(s[1]-r[1])-(r[1]-p[1])*(s[0]-r[0]))/den
                u = ((r[0]-p[0])*(q[1]-p[1])-(r[1]-p[1])*(q[0]-p[0]))/den
                if EPS < t < 1-EPS and EPS < u < 1-EPS:
                    return True, 0
            distance = min(distance, point_distance(p, (r, s)), point_distance(q, (r, s)), point_distance(r, (p, q)), point_distance(s, (p, q)))
    overlap = any(inside(b, p) for polygon in a for p in polygon) or any(inside(a, p) for polygon in b for p in polygon)
    return overlap, distance


def svg(path):
    root = ET.parse(path).getroot()
    box = [float(n) for n in root.attrib['viewBox'].split()]
    w, h = root.attrib['width'], root.attrib['height']
    if not w.endswith('mm') or not h.endswith('mm'):
        raise ValueError('SVG is not in physical millimeters: '+str(path))
    if not numeric_equal([float(w[:-2]), float(h[:-2])], box[2:]):
        raise ValueError('SVG viewport scales its millimeter geometry: '+str(path))
    return root, box


def svg_polygons(value):
    pattern = r'[MLZmlz]|'+NUMBER
    if re.sub(pattern, '', value).strip(' ,\t\n\r'):
        raise ValueError('Unsupported non-linear nominal SVG path')
    tokens = re.findall(pattern, value)
    polygons, current, command, index = [], [], None, 0
    while index < len(tokens):
        token = tokens[index]
        if token in 'MmLlZz':
            command = token
            index += 1
            if token in 'Zz':
                if current:
                    polygons.append(current)
                    current = []
                continue
        if command not in ('M', 'L'):
            raise ValueError('Unsupported non-linear nominal SVG path')
        if command == 'M' and current:
            polygons.append(current)
            current = []
        current.append((float(tokens[index]), float(tokens[index+1])))
        command = 'L'
        index += 2
    if current:
        polygons.append(current)
    return polygons


def physical_stock(stock):
    result = copy.deepcopy(stock)
    result.pop('grain', None)
    result.pop('sheetSizeMM', None)
    for ply in result.get('plies', []):
        ply.pop('id', None)
    return result


def resolved_stock(component, fallback, ex):
    stock = copy.deepcopy(component.get('stock', fallback))
    if 'stockThickness' in component:
        prior = sum(p['thicknessMM'] for p in stock.get('plies', [])) or stock['thicknessMM']
        thickness = ex.number(component['stockThickness'])
        stock['thicknessMM'] = thickness
        for ply in stock.get('plies', []):
            ply['thicknessMM'] *= thickness/prior
    return stock


# CoreGraphics uses ordinary indirect page/content objects, Flate streams and
# straight stroked patterns. This independent reader audits their coordinates.
PDF_TOKEN = re.compile(rb'%[^\r\n]*|\((?:\\[\s\S]|[^\\)])*\)|<[^>]*>|/[^\s\[\]()<>]+|'+NUMBER.encode()+rb'|[A-Za-z*]+|[\[\]]')


def matrix_product(a, b):
    return (a[0]*b[0]+a[2]*b[1], a[1]*b[0]+a[3]*b[1], a[0]*b[2]+a[2]*b[3], a[1]*b[2]+a[3]*b[3], a[0]*b[4]+a[2]*b[5]+a[4], a[1]*b[4]+a[3]*b[5]+a[5])


def pdf_strokes(content):
    matrix = (1, 0, 0, 1, 0, 0)
    saved, operands, strokes, path = [], [], [], []
    current = []
    def convert(x, y):
        return (matrix[0]*x+matrix[2]*y+matrix[4], matrix[1]*x+matrix[3]*y+matrix[5])
    for match in PDF_TOKEN.finditer(content):
        token = match[0]
        if token[:1] in (b'(', b'<', b'/', b'%', b'[', b']'):
            continue
        try:
            operands.append(float(token))
            continue
        except ValueError:
            pass
        if token == b'q':
            saved.append(matrix)
        elif token == b'Q':
            matrix = saved.pop()
        elif token == b'cm':
            matrix = matrix_product(matrix, operands[-6:])
        elif token == b'm':
            if current:
                path.append(current)
            current = [convert(*operands[-2:])]
        elif token == b'l':
            current.append(convert(*operands[-2:]))
        elif token == b're':
            if current:
                path.append(current)
            x, y, w, h = operands[-4:]
            current = [convert(x, y), convert(x+w, y), convert(x+w, y+h), convert(x, y+h)]
        elif token == b'h':
            if current:
                path.append(current)
                current = []
        elif token in (b'S', b's', b'B', b'B*', b'b', b'b*'):
            if current:
                path.append(current)
            if path:
                strokes.append(path)
            path, current = [], []
        elif token in (b'n', b'f', b'F', b'f*'):
            path, current = [], []
        elif token in (b'c', b'v', b'y'):
            # Curves are not permitted for these nominal straight cut fixtures.
            current.extend([convert(*operands[-2:])])
        operands = []
    return strokes


def pdf_pages(path):
    data = path.read_bytes()
    objects = {int(m[1]): m[2] for m in re.finditer(rb'(?m)^(\d+) 0 obj\s*(.*?)\s*endobj', data, re.S)}
    catalog = next(v for v in objects.values() if re.search(rb'/Type\s*/Catalog\b', v))
    root = int(re.search(rb'/Pages\s+(\d+)\s+0\s+R', catalog)[1])
    result = []
    def visit(key, inherited_box=None):
        value = objects[key]
        found = re.search(rb'/MediaBox\s*\[([^]]+)\]', value)
        box = [float(n) for n in re.findall(NUMBER.encode(), found[1])] if found else inherited_box
        if re.search(rb'/Type\s*/Pages\b', value):
            kids = re.search(rb'/Kids\s*\[([^]]+)\]', value, re.S)[1]
            for child in re.findall(rb'(\d+)\s+0\s+R', kids):
                visit(int(child), box)
            return
        references = re.search(rb'/Contents\s*(\[[^]]+\]|\d+\s+0\s+R)', value, re.S)
        streams = []
        for reference in re.findall(rb'(\d+)\s+0\s+R', references[1]):
            source = objects[int(reference)]
            header, raw = re.split(rb'stream\r?\n', source, maxsplit=1)
            length = re.search(rb'/Length\s+(\d+)(?:\s+0\s+R)?', header)
            if length is None:
                raise ValueError('PDF content stream needs a declared byte length')
            declared = int(length[1])
            if re.search(rb'/Length\s+\d+\s+0\s+R', header):
                declared = int(objects[declared].strip())
            raw = raw[:declared]
            if b'/FlateDecode' in source.split(b'stream', 1)[0]:
                raw = zlib.decompress(raw)
            streams.append(raw)
        result.append({'width': (box[2]-box[0])/UNIT, 'height': (box[3]-box[1])/UNIT, 'strokes': pdf_strokes(b'\n'.join(streams))})
    visit(root)
    return result


def contour_key(polygons, tolerance=PDF_EPS_MM):
    # Closed straight paths may start at any vertex or reverse winding. A
    # coordinate multiset also permits CoreGraphics' rectangle optimization.
    return sorted(tuple(sorted((round(x/tolerance), round(y/tolerance)) for x, y in p)) for p in polygons)


class Audit:
    def __init__(self, packet):
        self.packet = packet
        self.errors, self.checks = [], collections.Counter()
        self.summary = {}

    def check(self, condition, message, kind):
        self.checks[kind] += 1
        if not condition:
            self.errors.append(message)
        return condition

    def json(self, name):
        return read_json(self.packet/name)

    def run(self):
        manifest = self.json('Manifest.json')
        listed = set()
        for file in manifest['files']:
            name = file['path']
            target = self.packet/name
            safe = not Path(name).is_absolute() and '..' not in Path(name).parts and name not in listed and not target.is_symlink() and target.resolve().is_relative_to(self.packet.resolve())
            listed.add(name)
            if not self.check(safe, 'Unsafe/duplicate manifest file: '+name, 'manifest'):
                continue
            payload = target.read_bytes()
            self.check(len(payload) == file['bytes'] and hashlib.sha256(payload).hexdigest() == file['sha256'], 'Artifact hash/length mismatch: '+name, 'manifest')
        actual = {p.relative_to(self.packet).as_posix() for p in self.packet.rglob('*') if p.is_file()}
        self.check(actual == listed | {'Manifest.json'}, 'Packet has unlisted/missing files', 'manifest')
        source_bytes = (self.packet/'Source.json').read_bytes()
        self.check(hashlib.sha256(source_bytes).hexdigest() == manifest['source_digest'], 'Source snapshot digest mismatch', 'source')
        snapshot = json.loads(source_bytes)
        objects = {o['id']: o for o in snapshot['project']['objects']}
        owner = objects[snapshot['ownerID']]
        self.check(owner['id'] == manifest['object_id'] and snapshot['project']['id'] == manifest['project_id'], 'Captured source/project identity mismatch', 'source')
        source = owner['paperConstruction']
        definition, pieces = source['authored'], self.json('Cut-list.json')
        ex = Expressions(definition, owner.get('parameters', {}))
        production = definition['production']
        quantity = production['quantity']
        self.check(quantity == manifest['production_quantity'], 'Production quantity mismatch', 'quantities')
        panels = {p['id']: p for p in definition['panels']}
        children = collections.defaultdict(list)
        for hinge in definition['hinges']:
            children[hinge['parentPanelID']].append(hinge['childPanelID'])
        components = {c['id']: c for c in definition['components']}
        active = {k: c for k, c in components.items() if ex.number(c.get('enabled', 1)) > 0.5}
        by_id = {p['id']: p for p in pieces}
        self.check(len(by_id) == len(pieces) and set(by_id) == set(active), 'Cut piece identities differ from active source components', 'source')
        areas = {}
        for piece in pieces:
            pid, component = piece['id'], active[piece['id']]
            ids, todo = [], [component['rootPanelID']]
            while todo:
                panel = todo.pop()
                if panel in ids:
                    raise ValueError('Source tree cycle/duplicate: '+pid)
                ids.append(panel)
                todo.extend(children[panel])
            self.check(set(ids) == set(piece['panelIDs']) and piece['rootPanelID'] == component['rootPanelID'], 'Physical tree membership mismatch: '+pid, 'source')
            polygons = [ex.polygon(panels[p]['polygon']) for p in ids]
            box = bounds(polygons)
            self.check(numeric_equal(box, piece['bounds']), 'Physical canonical cut bounds mismatch: '+pid, 'source')
            def local(poly):
                return [(x-box['x'], y-box['y']) for x, y in poly]
            def cut_local(poly):
                return [(cut_lattice(x), cut_lattice(y)) for x, y in local(poly)]
            shapes = [[cut_local(ex.polygon(panels[p]['polygon']))]+[cut_local(ex.polygon(h['polygon'])) for h in panels[p].get('cutouts', [])] for p in ids]
            contours = [points(p) for p in piece['cutContours']]
            same, area = equivalent_material(shapes, contours)
            self.check(same and area is not None and area > 0, 'Cut contours do not equal source material/corner reliefs/slots: '+pid, 'source_contours')
            areas[pid] = area or 0
            expected_stock = resolved_stock(component, source['stock'], ex)
            self.check(numeric_equal(expected_stock, piece['stock']), 'Resolved stock/caliper/plies mismatch: '+pid, 'stocks')
            self.check(piece['quantity'] == component.get('quantity', 1), 'Piece quantity mismatch: '+pid, 'quantities')
            for side in ('front', 'back'):
                self.check(piece.get(side) == component.get(side), 'Canonical artwork source crop mismatch: '+pid+'/'+side, 'registration')
                if component.get(side):
                    self.check(component[side]['sourceObjectID'] in objects, 'Missing captured canonical source: '+pid+'/'+side, 'registration')
            if piece['purpose'] == 'board' and len(ids) == 1:
                self.check(not any(g['role'] in ('score', 'groove') for g in piece['guides']), 'Independent board gained a fictitious score/groove: '+pid, 'guides')
            expected_guides = {}
            for hinge in definition['hinges']:
                if hinge['childPanelID'] in ids:
                    expected_guides[hinge['id']] = (production.get('foldRoles', {}).get(hinge['id'], 'fold'), local(ex.polygon([hinge['start'], hinge['end']])))
            for guide in production.get('guides', []):
                if guide['componentID'] == pid:
                    expected_guides[guide['id']] = (guide['role'], ex.polygon(guide['points']))
            self.check(set(expected_guides) == {g['id'] for g in piece['guides']}, 'Pattern guide identity mismatch: '+pid, 'guides')
            for guide in piece['guides']:
                role, coordinates = expected_guides[guide['id']]
                self.check(guide['role'] == role and numeric_equal(points(guide['points']), coordinates), 'Pattern guide role/coordinates mismatch: '+guide['id'], 'guides')
        physical_count = sum(p['quantity']*quantity for p in pieces)
        self.check(physical_count == manifest['physical_cut_count'], 'Manifest physical cut total mismatch', 'quantities')
        self.audit_svgs(manifest, pieces, objects)
        self.audit_layouts(production, pieces, areas, quantity)
        self.audit_schedules(definition, ex, active, by_id, quantity, manifest)
        self.audit_order(production, active, definition)
        self.audit_pdfs(pieces)
        self.summary.update(piece_count=len(pieces), physical_cut_count=physical_count, source_digest=manifest['source_digest'], files=len(listed), bytes=sum(f['bytes'] for f in manifest['files']))
        return self.result()

    def audit_svgs(self, manifest, pieces, objects):
        piece_map = {p['id']: p for p in pieces}
        locations = {}
        svgs = {}
        for path in self.packet.rglob('*.svg'):
            root, box = svg(path)
            svgs[path.relative_to(self.packet).as_posix()] = (root, box)
            cut = root.find('.//'+NS+'g[@id="cut"]')
            if cut is not None:
                pid = cut.attrib['data-piece-id']
                locations[pid] = path.parent
                piece = piece_map[pid]
                margin = 5 if manifest['registration_marks_enabled'] else 0
                self.check(numeric_equal(box, [-margin, -margin, piece['bounds']['width']+2*margin, piece['bounds']['height']+2*margin]), 'Piece SVG physical extent mismatch: '+pid, 'svg_scale')
                drawn = svg_polygons(cut.find(NS+'path').attrib['d'])
                self.check(numeric_equal(drawn, [points(c) for c in piece['cutContours']]), 'Piece SVG cut coordinates mismatch: '+pid, 'svg_contours')
                roles = [g.attrib.get('data-role') for g in root.iter()]
                self.check(('registration' in roles) == manifest['registration_marks_enabled'], 'Registration guide setting mismatch: '+pid, 'registration')
        self.check(set(locations) == set(piece_map), 'Per-piece SVG set incomplete', 'svg_scale')
        records = self.json('Finish-assignments.json')
        expected_finishes = {(p['id'], 'front' if f['side'] == 'outside' else 'reverse', f['id']) for p in pieces for f in p.get('finishes', []) if f['enabled']}
        actual_finishes = {(r['piece_id'], r['side'], r['assignment']['id']) for r in records}
        self.check(expected_finishes.issubset(actual_finishes), 'A declared enabled piece finish has no registered mask', 'registration')
        for record in records:
            declared = piece_map[record['piece_id']].get('finishes', [])
            if declared:
                self.check(record['assignment'] in declared, 'Finish mask assignment differs from canonical source', 'registration')
        for piece in pieces:
            folder = locations[piece['id']]
            for label, side in [('front', 'front'), ('reverse', 'back')]:
                art = folder/(label+'-artwork.svg')
                if not art.exists():
                    # Inherited owner artwork is legal even without an explicit face.
                    self.check(not piece.get(side), 'Explicit source artwork SVG missing: '+piece['id']+'/'+label, 'registration')
                    continue
                root, box = svg(art)
                bleed = manifest['print_bleed_mm']
                self.check(numeric_equal(box, [-bleed, -bleed, piece['bounds']['width']+2*bleed, piece['bounds']['height']+2*bleed]), 'Artwork physical frame mismatch: '+piece['id']+'/'+label, 'registration')
                self.check(not any(e.attrib.get('data-role') in ('score', 'groove', 'fold', 'turnIn', 'registration') for e in root.iter()), 'Technical path leaked into ordinary print SVG', 'registration')
                clip = root.find('.//'+NS+'clipPath[@id="piece-print-print-boundary"]/'+NS+'path')
                if bleed == 0 and clip is not None:
                    expected = [points(c) for c in piece['cutContours']]
                    face = piece.get(side)
                    if label == 'reverse' and face:
                        source = objects[face['sourceObjectID']]
                        if not ('paperConstruction' in source and face.get('sourceSide') == 'inside'):
                            expected = [[(piece['bounds']['width']-x, y) for x, y in p] for p in expected]
                    same, _ = equivalent_material([expected], svg_polygons(clip.attrib['d']))
                    self.check(same, 'Print clipping loses piece shape or independent reverse registration: '+piece['id']+'/'+label, 'registration')
        for record in records:
            root, box = svgs[record['file']]
            folder = self.packet/record['file']
            art_root, art_box = svg(folder.parent/(record['side']+'-artwork.svg'))
            self.check(numeric_equal(box, art_box), 'Finish mask physical registration mismatch: '+record['file'], 'registration')
            targets = set(record['assignment']['elementIDs'])
            mask_layers = {e.attrib.get('id', '')[6:]: e for e in root.iter() if e.attrib.get('id', '').startswith('layer-')}
            self.check(targets.issubset(mask_layers), 'Finish mask target ID absent: '+record['file'], 'registration')
            common = {e.attrib.get('id'): e for e in art_root.iter() if e.attrib.get('id')}
            for element in root.iter():
                key = element.attrib.get('id')
                if key in common and key.startswith('layer-'):
                    self.check(element.attrib.get('transform') == common[key].attrib.get('transform'), 'Mask/print canonical transform mismatch: '+str(key), 'registration')
        self.summary['svg_count'] = len(svgs)
        self.summary['finish_mask_count'] = len(records)

    def audit_layouts(self, production, pieces, areas, quantity):
        report = self.json('Material-layouts.json')
        self.check(not any(i['severity'] == 'error' for i in report['issues']), 'Saved material layout has blocking issues', 'layouts')
        pieces = {p['id']: p for p in pieces}
        seen = collections.defaultdict(list)
        batch_keys = set()
        placements_by_page = []
        for batch in report['batches']:
            fmt = batch['format']
            source_format = next(m for m in production['materials'] if m['id'] == fmt['id'])
            self.check(numeric_equal(source_format, fmt), 'Exported material format differs from source: '+fmt['id'], 'layouts')
            key = (fmt['id'], json.dumps(physical_stock(batch['stock']), sort_keys=True))
            self.check(key not in batch_keys, 'Same actual stock was spuriously split into duplicate batches', 'stocks')
            batch_keys.add(key)
            page_groups = collections.defaultdict(list)
            for placement in batch['placements']:
                piece = pieces[placement['pieceID']]
                seen[piece['id']].append(placement['copy'])
                self.check(piece['id'] in fmt['componentIDs'] and numeric_equal(physical_stock(piece['stock']), physical_stock(batch['stock'])), 'Mixed actual material/caliper in batch: '+piece['id'], 'stocks')
                raw = [points(c) for c in piece['cutContours']]
                contours = transformed(raw, placement['transform'])
                box = bounds(contours)
                self.check(numeric_equal(box, placement['bounds']), 'Placement bounds do not match actual transformed contour: '+piece['id'], 'layouts')
                t = placement['transform']
                self.check(abs(t['a']*t['d']-t['b']*t['c']-1) < EPS and abs(t['a']**2+t['b']**2-1) < EPS and abs(t['c']**2+t['d']**2-1) < EPS, 'Layout altered physical size or mirrored stock: '+piece['id'], 'layouts')
                self.check(box['x'] >= fmt['marginMM']-EPS and box['y'] >= fmt['marginMM']-EPS and box['x']+box['width'] <= fmt['widthMM']-fmt['marginMM']+EPS and box['y']+box['height'] <= fmt['lengthMM']-fmt['marginMM']+EPS, 'Placed contour violates material margins: '+piece['id'], 'layouts')
                angle, grain = placement['rotationDegrees'], piece['stock']['grain']
                if fmt['grain'] != 'unrestricted' and grain != 'unknown':
                    expected = 90 if grain == 'parallelWidth' else 0
                    delta = (angle-expected) % (180 if fmt['grain'] == 'bidirectional' else 360)
                    self.check(min(delta, 360-delta) < EPS, 'Placement violates declared grain/warp direction: '+piece['id'], 'layouts')
                if not fmt['allowRotation']:
                    self.check(abs(angle) < EPS, 'Rotation present where forbidden: '+piece['id'], 'layouts')
                page_groups[placement['sheetIndex']].append((placement, contours))
            self.check(set(page_groups) == set(range(batch['sheetCount'])), 'Layout page indices/count mismatch', 'layouts')
            area = sum(areas[p['pieceID']] for p in batch['placements'])
            self.check(abs(area-batch['cutAreaMM2']) < max(EPS, area*1e-7), 'Layout material area does not equal independent contours', 'layouts')
            for index in range(batch['sheetCount']):
                placed = page_groups[index]
                for j, (_, a) in enumerate(placed):
                    for _, b in placed[j+1:]:
                        ba, bb = bounds(a), bounds(b)
                        gapx = max(ba['x']-bb['x']-bb['width'], bb['x']-ba['x']-ba['width'], 0)
                        gapy = max(ba['y']-bb['y']-bb['height'], bb['y']-ba['y']-ba['height'], 0)
                        if math.hypot(gapx, gapy) >= fmt['spacingMM']+EPS:
                            continue
                        overlap, distance = separation(a, b)
                        self.check(not overlap and distance+EPS >= fmt['spacingMM'], 'Actual material contours overlap or violate spacing: '+batch['id'], 'contour_spacing')
                height = batch['usedLengthMM'] if fmt['surface'] == 'roll' else fmt['lengthMM']
                page_record = {'batch_id': batch['id'], 'sheet_index': index, 'width': fmt['widthMM'], 'height': height, 'contours': [c for _, c in placed], 'key_pages': []}
                placements_by_page.append(page_record)
                candidates = []
                for file in self.packet.glob('Layouts/*/sheet-%03d-nominal-cut.svg' % (index+1)):
                    root, box = svg(file)
                    metadata = root.find(NS+'metadata').text or ''
                    if 'stockDigest='+batch['stockDigest']+';' in metadata and 'formatID='+fmt['id']+';' in metadata:
                        candidates.append((root, box, file))
                self.check(len(candidates) == 1, 'Missing/ambiguous material layout SVG: '+batch['id'], 'svg_scale')
                if candidates:
                    root, box, layout_file = candidates[0]
                    self.check(numeric_equal(box, [0, 0, fmt['widthMM'], height]), 'Material SVG physical stock extent mismatch', 'svg_scale')
                    groups = {(g.attrib['data-piece-id'], int(g.attrib['data-copy'])): g for g in root.findall(NS+'g') if 'data-piece-id' in g.attrib and g.find(NS+'path') is not None}
                    labels = {(g.attrib['data-piece-id'], int(g.attrib['data-copy'])): g for g in root.findall(NS+'g') if g.attrib.get('data-role') == 'placement-label'}
                    self.check(set(labels) == set(groups) if production.get('labels', True) else not labels, 'Material layout placement labels missing or present while disabled', 'layout_labels')
                    keyed = {}
                    for identity, label in labels.items():
                        text = ''.join(label.itertext()).strip()
                        if 'data-key' in label.attrib:
                            key_number = int(label.attrib['data-key'])
                            self.check(key_number > 0 and key_number not in keyed and text == str(key_number), 'Placement key is missing/duplicated or is not the visible numeric label', 'layout_labels')
                            keyed[key_number] = {'key': key_number, 'piece_id': identity[0], 'copy': identity[1]}
                        else:
                            self.check(text == identity[0]+' / copy '+str(identity[1]), 'Visible unkeyed placement identity is truncated or changed', 'layout_labels')
                        placement = next(p for p, _ in placed if (p['pieceID'], p['copy']) == identity)
                        font = float(label.find(NS+'text').attrib['font-size'])
                        self.check(font >= 2.6-EPS, 'Placement identity was shrunk below readable type instead of using a key', 'layout_labels')
                        transform = [float(n) for n in re.findall(NUMBER, label.attrib['transform'])]
                        tx, ty, angle = transform
                        cos, sin = math.cos(math.radians(angle)), math.sin(math.radians(angle))
                        # Courier label contract uses a conservative .65em per
                        # ASCII glyph. Include descent instead of testing only
                        # the baseline; detect the actual16x4mm truncation case.
                        width = sum(font*(0.65 if ord(c)<128 else 1.1) for c in text)
                        corners = [(tx+cos*x-sin*y, ty+sin*x+cos*y) for x, y in [(0,0),(width,0),(width,font*1.2),(0,font*1.2)]]
                        label_box, slot = bounds([corners]), placement['bounds']
                        self.check(label_box['x'] >= slot['x']-EPS and label_box['y'] >= slot['y']-EPS and label_box['x']+label_box['width'] <= slot['x']+slot['width']+EPS and label_box['y']+label_box['height'] <= slot['y']+slot['height']+EPS, 'Placement label cannot fit its physical slot; use an annotation-only key: '+identity[0], 'layout_label_fit')
                    key_entries = {}
                    companions = sorted(layout_file.parent.glob('sheet-%03d-label-key-*.svg' % (index+1)))
                    for key_file in companions:
                        key_root, key_box = svg(key_file)
                        self.check(numeric_equal(key_box,[0,0,210,297]), 'Label key SVG must be a separate A4 annotation page', 'layout_keys')
                        metadata = key_root.find(NS+'metadata').text or ''
                        self.check('annotationOnly=true' in metadata and 'nominalCutSheet=false' in metadata and 'batchID='+batch['id']+';' in metadata and 'sheetIndex='+str(index)+';' in metadata, 'Label key companion is not explicitly identified as annotation-only for this stock sheet', 'layout_keys')
                        self.check(not any(g.find(NS+'path') is not None and 'data-piece-id' in g.attrib for g in key_root.iter(NS+'g')), 'Cut geometry leaked onto annotation key page', 'layout_keys')
                        entries = []
                        for entry in key_root.findall(NS+'g'):
                            if entry.attrib.get('data-role') != 'label-key-entry':
                                continue
                            record = {'key':int(entry.attrib['data-key']),'piece_id':entry.attrib['data-piece-id'],'copy':int(entry.attrib['data-copy'])}
                            self.check(record['key'] not in key_entries, 'Repeated stock-label key entry', 'layout_keys')
                            key_entries[record['key']] = record
                            entries.append(record)
                            visible = ''.join(entry.itertext())
                            expected = str(record['key'])+' '+record['piece_id']+' / copy '+str(record['copy'])
                            self.check(''.join(visible.split()) == ''.join(expected.split()), 'Full identity/copy is missing or truncated in SVG key legend', 'layout_keys')
                            for text_node in entry.findall(NS+'text'):
                                self.check(float(text_node.attrib['font-size']) >= 2.6 and 15-EPS <= float(text_node.attrib['x']) <= 195 and 45 <= float(text_node.attrib['y']) <= 282, 'Key legend text is too small or outside readable page bounds', 'layout_keys')
                        page_record['key_pages'].append(entries)
                    self.check(key_entries == keyed and (not companions if not production.get('labels',True) else True), 'Numbered placements do not have exactly matching full-ID companion keys', 'layout_keys')
                    self.check(len(groups) == len(placed), 'Layout SVG placement count mismatch', 'svg_contours')
                    for placement, contours in placed:
                        group = groups[(placement['pieceID'], placement['copy'])]
                        drawn = svg_polygons(group.find(NS+'path').attrib['d'])
                        self.check(numeric_equal(drawn, contours), 'Actual layout SVG is not the saved physical contour transform: '+placement['pieceID'], 'svg_contours')
        for pid, piece in pieces.items():
            self.check(sorted(seen[pid]) == list(range(1, piece['quantity']*quantity+1)), 'Missing/duplicated physical cut copies: '+pid, 'quantities')
        self.layout_pages = placements_by_page
        self.summary['material_batches'] = len(report['batches'])
        self.summary['material_pages'] = len(placements_by_page)

    def audit_schedules(self, definition, ex, active, pieces, quantity, manifest):
        panel_piece = {p: piece['id'] for piece in pieces.values() for p in piece['panelIDs']}
        joins = {j['id']: j for j in definition['joins'] if j['firstPanelID'] in panel_piece and j['secondPanelID'] in panel_piece and ex.number(j.get('enabled', 1)) > 0.5}
        tape = self.json('Tape-schedule.json')
        staples = self.json('Staple-schedule.json')
        expected_tape, expected_staples, expected_glue = {}, {}, {}
        for record in definition.get('jointAttachments', []):
            if ex.number(record.get('enabled', 1)) <= 0.5:
                continue
            self.check(record['joinID'] in joins, 'Enabled attachment has no active physical joint: '+record['id'], 'attachments')
            if record.get('adhesive'):
                expected_glue[record['id']] = (record, record['adhesive'])
            if record.get('tape'):
                expected_tape[record['id']] = (record, record['tape'])
            for staple in record.get('staples', []):
                count = int(math.floor(ex.number(staple.get('count', 1))+0.5))
                for i in range(count):
                    expected_staples[staple['id']+':'+str(i)] = (record, staple, i, count)
        glue = self.json('Adhesive-regions.json')
        self.check({g['id'] for g in glue} == set(expected_glue), 'Adhesive schedule identities differ from enabled source', 'attachments')
        for row in glue:
            record, declaration = expected_glue[row['id']]
            self.check(row['jointID'] == record['joinID'] and numeric_equal(row['thicknessMM'], ex.number(declaration['thicknessMM'])) and numeric_equal(row['coverage'], ex.number(declaration.get('coverage', 1))), 'Adhesive identity/physical bond or coverage mismatch', 'attachments')
        self.check({t['id'] for t in tape} == set(expected_tape), 'Tape schedule identities differ from enabled source', 'attachments')
        self.check({s['id'] for s in staples} == set(expected_staples) and len(staples) == len(expected_staples), 'Fastener instance count/identities differ from enabled source', 'attachments')
        for row in tape:
            record, declaration = expected_tape[row['id']]
            self.check(row['componentID'] in pieces and row['jointID'] == record['joinID'], 'Tape is not an actual cut piece/target joint', 'attachments')
            piece = pieces[row['componentID']]
            self.check(numeric_equal(row['stock'], piece['stock']) and row['quantity'] == piece['quantity'], 'Tape stock/cut quantity mismatch', 'attachments')
            for key in ('widthMM', 'lengthMM', 'overlapMM', 'endOffsetStartMM', 'endOffsetEndMM', 'bondThicknessMM'):
                self.check(numeric_equal(row[key], ex.number(declaration.get(key, 0))), 'Tape scalar mismatch: '+row['id']+'/'+key, 'attachments')
            for target in ('firstTarget', 'secondTarget'):
                self.check(row[target]['panelID'] in panel_piece and row[target]['componentID'] == panel_piece[row[target]['panelID']], 'Tape target owner mismatch', 'attachments')
        for row in staples:
            record, declaration, index, count = expected_staples[row['id']]
            self.check(row['jointID'] == record['joinID'] and row['definitionID'] == declaration['id'] and row['instanceIndex'] == index and row['definitionCount'] == count, 'Fastener source/instance metadata mismatch', 'attachments')
            for key in ('entryPanelID', 'receivingPanelID'):
                self.check(row[key] == declaration[key] and row[key] in panel_piece, 'Fastener entry/receiving material mismatch', 'attachments')
            for key in ('crownWidthMM', 'wireWidthMM', 'wireDepthMM', 'legLengthMM'):
                self.check(numeric_equal(row[key], ex.number(declaration[key])), 'Fastener physical size mismatch: '+row['id']+'/'+key, 'attachments')
            self.check(len(row['legMaterialIntervals']) == 2 and all(any(v['panelID'] == row['receivingPanelID'] and max(0, min(v['exitMM'], row['legLengthMM'])-max(v['entryMM'], 0))+EPS >= row['minimumReceivingDepthMM'] for v in leg) for leg in row['legMaterialIntervals']), 'Both physical fastener legs must engage declared receiving material: '+row['id'], 'attachments')
            self.check(all(v['panelID'] in panel_piece for leg in row['legMaterialIntervals'] for v in leg), 'Fastener interval references absent material', 'attachments')
            self.check(all(math.isfinite(v) for p in row['pointsMM'] for v in p.values()) and len(row['pointsMM']) >= 4, 'Fastener installed wire path is missing/nonfinite', 'attachments')
            path = row['pointsMM']
            if row['termination'] == 'buried' and len(path) == 4:
                lengths = [math.dist(tuple(a[k] for k in ('x', 'y', 'z')), tuple(b[k] for k in ('x', 'y', 'z'))) for a, b in zip(path, path[1:])]
                self.check(numeric_equal(lengths, [row['legLengthMM'], row['crownWidthMM'], row['legLengthMM']]), 'Actual installed U path differs from physical wire dimensions', 'attachments')
            self.check(len(row.get('receivingEntryBoundaries', [])) == 2 and len(row.get('receivingThroughExitBoundaries', [])) == 2, 'Both receiver entry/through-exit boundaries must be explicit', 'attachments')
            self.check(row['tool'] == declaration['tool'] and row['installation']['order'] == declaration['installation']['order'], 'Fastener tool/install metadata mismatch', 'attachments')
        physical_tape_cuts = sum(pieces[pid]['quantity'] for pid in {t['componentID'] for t in tape})
        self.check(manifest['total_staple_count'] == len(staples)*quantity and manifest['total_tape_cut_count'] == physical_tape_cuts*quantity, 'Manifest attachment production counts mismatch', 'quantities')
        for row in tape+staples+self.json('Adhesive-regions.json'):
            self.check(row['jointID'] in joins, 'Schedule references disabled joint', 'attachments')
            if 'installation' in row:
                self.check(set(row['installation']['presentComponentIDs']).issubset(active), 'Installation schedule includes disabled/nonexistent material: '+row['id'], 'attachments')
        self.summary.update(staples=len(staples), tape_cuts=physical_tape_cuts, tape_contact_records=len(tape))

    def audit_order(self, production, active, definition):
        steps = self.json('Assembly-order.json')
        source = {s['id']: s for s in production['steps']}
        ids, prior = {s['id'] for s in steps}, set()
        expected = [s['id'] for s in production['steps'] if not s['componentIDs'] or set(s['componentIDs']).intersection(active)]
        self.check([s['id'] for s in steps] == expected, 'Required active source assembly step missing/duplicated/reordered', 'assembly_order')
        joins = {j['id']: j for j in definition['joins']}
        for step in steps:
            self.check(step['id'] in source and step['title'] == source[step['id']]['title'] and step['instructions'] == source[step['id']]['instructions'], 'Assembly instructions are not source-authored', 'assembly_order')
            self.check(set(step['componentIDs']).issubset(active), 'Disabled part leaked into assembly instructions: '+step['id'], 'assembly_order')
            self.check(set(step['after']).issubset(prior), 'Assembly dependency missing/out of order: '+step['id'], 'assembly_order')
            self.check(set(step['after']) == set(source[step['id']].get('after', [])).intersection(ids), 'Assembly dependency changed beyond disabled-step filtering', 'assembly_order')
            self.check(set(step['jointIDs']).issubset(joins), 'Assembly step references absent joint', 'assembly_order')
            prior.add(step['id'])
        self.summary['assembly_steps'] = len(steps)

    def audit_pdfs(self, pieces):
        pages = pdf_pages(self.packet/'Actual-size-pattern-proofs.pdf')
        self.check(len(pages) == len(pieces), 'Pattern PDF page count mismatch', 'pdf_scale')
        for page, piece in zip(pages, pieces):
            w, h = max(160, piece['bounds']['width']+20), max(65, piece['bounds']['height']+36)
            self.check(numeric_equal([page['width'], page['height']], [w, h], PDF_EPS_MM), 'Pattern PDF physical MediaBox mismatch: '+piece['id'], 'pdf_scale')
            expected = [[(x+10, y+22) for x, y in points(contour)] for contour in piece['cutContours']]
            matches = []
            for stroke in page['strokes']:
                actual = [[(x/UNIT, page['height']-y/UNIT) for x, y in polygon] for polygon in stroke]
                if len(actual) == len(expected) and numeric_equal(bounds(actual), bounds(expected), PDF_EPS_MM):
                    same, _ = equivalent_material([expected], actual, PDF_EPS_MM)
                    if same:
                        matches.append(actual)
            self.check(bool(matches), 'Pattern PDF actual stroked geometry is not 1:1 mm: '+piece['id'], 'pdf_paths')
        layouts = pdf_pages(self.packet/'Material-layout-proofs.pdf')
        manifest = self.json('Manifest.json')
        index = manifest.get('material_layout_pdf_pages')
        expected_index = []
        for stock in self.layout_pages:
            expected_index.append({'role':'actualSizeStock','batch_id':stock['batch_id'],'sheet_index':stock['sheet_index'],'width_mm':stock['width'],'height_mm':stock['height'],'annotation_only':False})
            for key_page, entries in enumerate(stock['key_pages']):
                expected_index.append({'role':'labelKey','batch_id':stock['batch_id'],'sheet_index':stock['sheet_index'],'key_page_index':key_page,'width_mm':210,'height_mm':297,'annotation_only':True,'entries':entries})
        if index is None:
            # Captured older packet versions predate separate annotation pages.
            index = [{'page':i+1,**entry} for i,entry in enumerate(expected_index)]
        self.check(len(layouts) == len(expected_index) == len(index), 'Material PDF page/classification count mismatch', 'pdf_scale')
        for number, (page, expected, declared) in enumerate(zip(layouts,expected_index,index),1):
            self.check(declared.get('page') == number and numeric_equal({k:declared.get(k) for k in expected},expected), 'Material PDF stock/annotation page classification differs from its physical sheet/key records', 'pdf_page_roles')
            w,h = expected['width_mm'],expected['height_mm']
            self.check(numeric_equal([page['width'],page['height']],[w,h],PDF_EPS_MM), 'Material PDF physical stock or annotation MediaBox mismatch', 'pdf_scale')
            if expected['role'] == 'labelKey':
                self.check(expected['annotation_only'] and numeric_equal([w,h],[210,297]), 'Legend page must never be counted as physical cutting stock', 'pdf_page_roles')
                continue
            stock = next(s for s in self.layout_pages if s['batch_id']==expected['batch_id'] and s['sheet_index']==expected['sheet_index'])
            remaining = list(page['strokes'])
            for contours in stock['contours']:
                matched = False
                for i, stroke in enumerate(remaining):
                    actual = [[(x/UNIT,page['height']-y/UNIT) for x,y in p] for p in stroke]
                    if len(actual)==len(contours) and numeric_equal(bounds(actual),bounds(contours),PDF_EPS_MM):
                        same,_=equivalent_material([contours],actual,PDF_EPS_MM)
                        if same:
                            matched=True
                            remaining.pop(i)
                            break
                self.check(matched,'Material PDF actual contour placement/scale mismatch','pdf_paths')
        self.summary['material_pdf_annotation_pages'] = sum(x['role']=='labelKey' for x in expected_index)
        assembly = pdf_pages(self.packet/'Assembly-and-sections.pdf')
        self.check(all(numeric_equal([p['width'], p['height']], [210, 297], PDF_EPS_MM) for p in assembly), 'Assembly reference/instruction PDF page extent mismatch', 'pdf_scale')
        self.summary.update(pattern_pdf_pages=len(pages), assembly_pdf_pages=len(assembly))

    def result(self):
        return {'packet': str(self.packet), 'passed': not self.errors, 'checks': dict(self.checks), 'summary': self.summary, 'errors': self.errors,
                'limits': ['Read-only artifact/source audit; visual PDF and actual app render review remain separate.', 'Prototype stock/allowance declarations are not physical fabrication validation.', 'Independent PDF path interpreter covers the emitted CoreGraphics straight cut/proof contract, not arbitrary third-party PDFs.']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('packets', nargs='*', type=Path)
    parser.add_argument('--report', type=Path, default=HERE/'proofs'/'packet-audit.json')
    args = parser.parse_args()
    packets = args.packets or sorted(p for p in (HERE/'construction-packets').glob('*') if p.is_dir() and (p/'Manifest.json').is_file())
    if not packets:
        parser.error('No packet folders with Manifest.json under construction-packets; pass explicit packet folders to audit another capture.')
    if any(args.report.resolve().is_relative_to(packet.resolve()) for packet in packets):
        parser.error('Audit reports must be outside captured packet folders; packets are immutable.')
    results = []
    for packet in packets:
        audit = Audit(packet.resolve())
        try:
            result = audit.run()
        except Exception as error:
            audit.errors.append(type(error).__name__+': '+str(error))
            result = audit.result()
        results.append(result)
        print(('PASS' if result['passed'] else 'FAIL')+' '+packet.name+' '+str(sum(result['checks'].values()))+' checks')
        for error in result['errors']:
            print('  '+error)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps({'passed': all(r['passed'] for r in results), 'packets': results}, indent=2)+'\n')
    print('Report: '+str(args.report.resolve()))
    return 0 if all(r['passed'] for r in results) else 1


if __name__ == '__main__':
    sys.exit(main())
