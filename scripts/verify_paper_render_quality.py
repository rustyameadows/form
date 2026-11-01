#!/usr/bin/env python3
"""Compare native paper finishes through an already-running disposable LAB.

Example (launch the ordinary app with this library/socket separately):
  python3 scripts/verify_paper_render_quality.py --app build/LAB.app \
    --socket /tmp/lab-quality.sock --output .local/validation/paper-quality

The expected library defaults to OUTPUT/Library; --library can name a different
explicit disposable .local library. No app launch, project-file writes, private
MCP commands, network model calls or equipment operations occur here. Pillow is
used only to decode/compare exported PNGs. Actual visual review remains required.
"""
import argparse
import copy
import hashlib
import html
import json
from pathlib import Path
import struct
import time
import xml.etree.ElementTree as ET

from PIL import Image, ImageChops, ImageStat
from validate_paper_packaging import ROOT, Session, element, stable
from render_paper_packaging import camera, geometry


def require(value, message):
    if not value:
        raise AssertionError(message)


def digest(value):
    data = json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()
    return hashlib.sha256(data).hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n')


def protected_sources(project):
    values = copy.deepcopy(project['objects'])
    for obj in values:
        obj.get('paperConstruction', {}).pop('finishes', None)
    return values


def artwork(side):
    """Same physical-coordinate specimen with deliberately asymmetric masks."""
    ink = '#253E3B'
    name = 'paper-quality-' + side
    elements = [
        element('text', name+'-title', 6, 5, 84, 10, ink,
                'SOURCE / ' + side.upper(), 18),
        element('text', name+'-small', 6, 19, 83, 9, ink,
                'Small editable type: Aa Bb 0123456789\nFine lettering follows the original source.', 5),
        element('text', name+'-caption', 6, 53, 84, 6, ink,
                '96 x 64 MM / NATIVE SOURCE / NO IMAGE MODEL', 6),
        # Different, off-center masks distinguish registration on the two faces.
        element('rectangle', name+'-blind', 67 if side == 'outside' else 14,
                34 if side == 'outside' else 39, 17, 9, ink),
    ]
    # TypographyEngine lays out in points inside millimeter frames. Explicit
    # leading keeps complete lines well inside each frame at the installed face.
    for text, leading in zip(elements[:3], [22, 7, 8]):
        text['typography']['leading'] = leading
    for i, width in enumerate([.05, .075, .1, .15, .2, .3]):
        elements.append(element('rectangle', name+'-rule-'+str(i), 6, 33+i*2.5, 42, width, ink))
    return elements


class Comparison:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        require(not (self.output/'paper-render-quality.json').exists(), 'Choose a fresh evidence output folder.')
        self.session = Session(args.app, args.socket, self.output)
        expected = (args.library or self.output/'Library').resolve()
        require('.local' in expected.parts, 'The explicitly expected library must be disposable under a .local directory.')
        require(self.session.helper.is_file(), 'The explicit app must contain its packaged lab-mcp helper.')
        self.session.env['LAB_LIBRARY_PATH'] = str(expected)
        status = self.session.call('form_status')
        require(Path(status['library_path']).resolve() == expected,
                f'Bridge library mismatch: expected {expected}, got {status["library_path"]}. No project was created.')
        self.report = dict(version=1, app=str(args.app.resolve()), socket=args.socket,
            library=str(expected), captures=[], pixels=[args.width, args.height],
            created_unix=time.time(), source_changes='Finish assignments only after authoring.',
            visual_review='Required: inspect lettering, shoulders, contour continuity and reverse registration.',
            physical_process_verified=False, external_model_calls=0, hardware_operations=0)
        self.object_id = None
        self.finish_ids = [stable('paper-quality-finish-'+side) for side in ['outside', 'inside']]
        self.baseline = None
        self.baseline_geometry = None

    def call(self, tool_name, **arguments):
        return self.session.call(tool_name, arguments)

    def save(self):
        write(self.output/'paper-render-quality.json', self.report)

    def inspect_geometry(self):
        data = self.call('form_construction', command='inspect', object_id=self.object_id)
        return {'net': data['net'], 'poses': data['poses']}

    def check_sources(self):
        current = self.call('form_get_project')
        require(current['id'] == self.report['project_id'], 'The active project changed during comparison.')
        require(protected_sources(current) == protected_sources(self.baseline),
                'Artwork, stock, parameters, dimensions or source ownership changed during rendering.')
        require(self.inspect_geometry() == self.baseline_geometry, 'Resolved physical net/poses changed with appearance.')
        return current

    def author(self):
        project = self.call('form_create_project', name='Native / Paper source and finish comparison', template='blank')
        self.report['project_id'] = project['id']
        definition = json.loads((ROOT/'examples/paper-packaging/09-duplex-business-card.json').read_text())
        for parameter in definition['parameters']:
            parameter['value'] = {'width': 96, 'height': 64, 'stock': .8, 'turn': 90}[parameter['name']]
        definition['name'] = 'Authored paper finish specimen'
        made = self.call('form_construction', command='create', definition=definition,
                        name='Source / paper finish comparison', position=[0, 45, 0])
        self.object_id = made['object_id']; self.report['object_id'] = self.object_id
        self.call('form_paper', command='configure', object_id=self.object_id,
            stock=dict(name='Cotton / unmeasured visual specimen', thicknessMM=.8, grain='parallelHeight',
                verified=False, profile=dict(texture='cotton', color='#EEE6D5', roughness=.92,
                    textureScaleMM=1.2, textureDepthMM=.035, opacity=1)))
        inside = self.call('form_paper', command='ensure_inside', object_id=self.object_id)['inside_source_id']
        self.report['inside_source_id'] = inside
        self.targets = {}
        self.specimen_artworks = {}
        for side, owner in [('outside', self.object_id), ('inside', inside)]:
            self.session.clear_art(owner)
            values = artwork(side)
            self.specimen_artworks[side] = values
            self.call('form_edit_artwork', command='add', object_id=self.object_id, elements=values,
                      physical_frame=dict(surface_id='front', side=side))
            # Caption is a constant printed control; the other source elements get the finish.
            self.targets[side] = [e['id'] for e in values if not e['name'].endswith('-caption')]
        self.verify_type_outlines()
        project = self.call('form_get_project')
        obj = next(o for o in project['objects'] if o['id'] == self.object_id)
        inspected = self.call('form_construction', command='inspect', object_id=self.object_id)
        points, _ = geometry(inspected, obj)
        self.shots = []
        views = [('front', [0, 0, 1]), ('grazing', [1, .28, .25]), ('reverse', [0, .15, -1])]
        for name, outward in views:
            state = camera(points, outward, margin=1.12, aspect=self.args.width/self.args.height)
            shot = self.call('form_set_view', view='studio', studio_command='capture', name='Paper / '+name,
                camera=state, reference_aspect=self.args.width/self.args.height,
                lighting='soft-side-v1', surface='Daylight',
                visibility=dict(mode='objects', objectIDs=[self.object_id]),
                width=self.args.width, height=self.args.height)
            self.shots.append((name, shot))
        self.baseline = self.call('form_get_project')
        self.baseline_geometry = self.inspect_geometry()
        self.report.update(physical_dimensions_mm=[96, 64, .8], source_sha256=digest(self.baseline['objects']),
            protected_source_sha256=digest(protected_sources(self.baseline)),
            geometry_sha256=digest(self.baseline_geometry), shots=[s for _, s in self.shots])
        write(self.output/'authored-source.json', self.baseline)
        self.save()

    def verify_type_outlines(self):
        """Reject empty/clipped title or type fixtures before native comparisons."""
        records = []
        for side in ['outside', 'inside']:
            path = self.output/(side+'-source.svg')
            self.call('form_paper', command='export', object_id=self.object_id,
                      format='svg', inside=side == 'inside', path=str(path))
            root = ET.parse(path).getroot()
            groups = {node.attrib.get('id'): node for node in root.iter()}
            for source in self.specimen_artworks[side]:
                if source['kind'] != 'text':
                    continue
                group = groups.get('layer-'+source['id'].upper())
                require(group is not None, 'Export lost source text identity: '+source['name'])
                paths = [node for node in group.iter() if node.tag.rsplit('}', 1)[-1] == 'path'
                         and node.attrib.get('d', '').strip()]
                require(paths, 'Native typography produced no glyph outlines: '+source['name'])
                records.append(dict(side=side, element_id=source['id'], font_size_points=source['fontSize'],
                    frame_mm=[source['width'], source['height']], leading_points=source['typography']['leading'],
                    native_glyph_paths=len(paths)))
        self.report['native_source_typography'] = records

    def set_finish(self, kind, depth, height, foil=False):
        for side, identifier in zip(['outside', 'inside'], self.finish_ids):
            self.call('form_paper', command='set_finish', object_id=self.object_id,
                finish=dict(id=identifier, name='Controlled '+side+' finish', kind=kind, side=side,
                    elementIDs=self.targets[side], depthMM=depth, heightMM=height,
                    color='#C49B48' if foil else None, roughness=.18 if foil else .92,
                    metallic=1 if foil else 0, opacity=1, enabled=True))

    def capture(self, variant, name, shot):
        before = self.check_sources()
        folder = self.output/(variant+'-'+name+'.render')
        require(not folder.exists(), 'Refusing to replace an existing render folder.')
        result = self.call('form_export', format='png', shot_id=shot['id'], path=str(folder))
        image = Path(result['path']); record_path = Path(result['record'])
        png = image.read_bytes(); record = json.loads(record_path.read_text())
        require(png[:8] == b'\x89PNG\r\n\x1a\n', 'Native export was not PNG.')
        require(struct.unpack('>II', png[16:24]) == (self.args.width, self.args.height), 'Output pixel dimensions changed.')
        png_hash = hashlib.sha256(png).hexdigest()
        require(record['png_sha256'] == png_hash, 'Render record does not identify the exported PNG.')
        require(record['shot'] == shot and record['included_object_ids'] == [self.object_id],
                'Renderer used a different camera, framing, lighting or source selection.')
        decoded = Image.open(image).convert('RGB')
        row = dict(variant=variant, view=name, path=str(image), record=str(record_path), png_sha256=png_hash,
            decoded_rgb_sha256=hashlib.sha256(decoded.tobytes()).hexdigest(),
            protected_source_sha256=digest(protected_sources(before)),
            finish_assignments=next(o for o in before['objects'] if o['id']==self.object_id)['paperConstruction']['finishes'],
            design_sha256=record['design_sha256'], framing_warnings=record.get('framing_warnings', []))
        if variant != 'flat':
            reference = next(r for r in self.report['captures'] if r['variant']=='flat' and r['view']==name)
            with Image.open(reference['path']) as original:
                difference = ImageChops.difference(decoded, original.convert('RGB'))
            row['changed_pixels_bounds'] = difference.getbbox()
            row['mean_rgb_difference_0_255'] = sum(ImageStat.Stat(difference).mean)/3
            require(row['changed_pixels_bounds'] is not None, f'{variant}/{name} pixels are identical to flat control.')
        self.report['captures'].append(row); self.check_sources(); self.save()

    def gallery(self):
        cells = []
        for row in self.report['captures']:
            relative = Path(row['path']).relative_to(self.output)
            label = row['variant']+' / '+row['view']
            cells.append(f'<figure><a href="{html.escape(str(relative))}"><img src="{html.escape(str(relative))}"></a>'
                         f'<figcaption>{html.escape(label)}</figcaption></figure>')
        page = '<!doctype html><meta charset="utf-8"><title>Native paper finish comparison</title>'
        page += '<style>body{font:14px -apple-system,sans-serif;background:#e9e7e2;margin:24px}main{display:grid;grid-template-columns:repeat(3,1fr);gap:16px}figure{margin:0;background:white;padding:10px;border-radius:10px}img{width:100%;height:auto}figcaption{padding:8px}h1{font-size:20px}</style>'
        page += '<h1>Native paper finish comparison</h1><p>Each row: fixed front, grazing and reverse cameras. Rows: flat, letterpress, emboss, foil. Click an image for full pixel detail. Visual review is required.</p><main>'+''.join(cells)+'</main>'
        (self.output/'index.html').write_text(page)

    def run(self):
        try:
            self.author()
            variants = [('flat', 'letterpress', 0, 0, False), ('letterpress', 'letterpress', .06, 0, False),
                        ('emboss', 'emboss', 0, .12, False), ('foil', 'foil', 0, .015, True)]
            for name, kind, depth, height, foil in variants:
                self.set_finish(kind, depth, height, foil)
                for view, shot in self.shots:
                    self.capture(name, view, shot)
            self.report['completed'] = True
        except Exception as error:
            self.report.update(completed=False, error=str(error))
            raise
        finally:
            # Preserve the authored specimen exactly; only presentation/history/exports remain.
            if self.baseline is not None:
                current = self.call('form_get_project')
                require(current['id'] == self.report['project_id'], 'Project changed; refusing cleanup on another project.')
                owner = next(o for o in current['objects'] if o['id'] == self.object_id)
                existing = {f['id'] for f in owner['paperConstruction'].get('finishes', [])}
                for identifier in self.finish_ids:
                    if identifier in existing:
                        self.call('form_paper', command='remove_finish', object_id=self.object_id, finish_id=identifier)
                current = self.check_sources()
                require(current['objects'] == self.baseline['objects'], 'Cleanup did not restore exact authored sources.')
                self.report['restored_source_sha256'] = digest(current['objects'])
            self.save()
        self.gallery()
        print(json.dumps(dict(project_id=self.report['project_id'], captures=len(self.report['captures']),
            report=str(self.output/'paper-render-quality.json'), gallery=str(self.output/'index.html')), indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--socket', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--width', type=int, choices=[2400, 3072], default=3072)
    parser.add_argument('--height', type=int, default=2048)
    args = parser.parse_args()
    require(64 <= args.height <= 8192 and args.width*args.height <= 16_777_216,
            'Choose bounded native output pixels.')
    Comparison(args).run()


if __name__ == '__main__':
    main()
