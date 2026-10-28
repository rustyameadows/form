#!/usr/bin/env python3
"""One real graphic-design workflow for the specification's fifteen criteria.

Disposable local studio only. No model calls, slicing, printers or equipment.
Native follow-up acceptance is recorded separately.
"""
import copy
import json
import pathlib
import re
import struct
import uuid

from smoke_mcp import ROOT, OUTPUT, Client
from smoke_font_features import text


def uid():
    return str(uuid.uuid4()).upper()


def shape(kind, x, y, w, h, color, **extra):
    return dict(id=uid(), kind=kind, x=x, y=y, width=w, height=h,
                text='', fontSize=14, color=color, **extra)


def main():
    c = Client()
    try:
        status = c.call('form_status')
        library = pathlib.Path(status['library_path']).resolve()
        assert library.is_relative_to((ROOT / '.local').resolve()), 'Use a disposable studio.'
        c.discover(['form_edit_artwork', 'form_edit_path', 'form_font_features',
                    'form_convert_to_paths', 'form_link_artwork'])
        project = c.call('form_create_project', {'name': 'AFFINITIES / Measured composition', 'template': 'blank'})
        face = c.call('form_font_features', {'font_name': 'Baskerville'})
        assert not face['missing']
        assert any(f['id'] == 1 for f in face['features'])
        variable = c.call('form_font_features', {'font_name': 'Skia'})
        assert not variable['missing'] and variable['axes']
        sheet = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'AFFINITIES / 8 × 10 in',
            'parameters': {'width': 203.2, 'depth': 254}})
        sid = sheet['id']
        title = text(18, 35, 172, 33, 'Affinities.', 67, featureSelections={'1': [2, 4, 20]},
                     kerningMode='metrics', tracking=-0.3, leading=70,
                     pairKerning={'0': -0.6})
        title['name'] = 'Editable display wordmark'
        subtitle = text(18, 74, 170, 13, 'A study in light, shape and time.', 14, leading=18)
        subtitle['name'] = 'Composition subtitle'
        mask = shape('ellipse', 47, 99, 110, 110, '#1E3D37', name='Circular geometric mask')
        gradient = shape('rectangle', 40, 94, 125, 120, '#BE643F', name='Warm light',
            gradient={'kind': 'linear', 'start': {'x': 0, 'y': 0}, 'end': {'x': 1, 'y': 1},
                'stops': [{'id': uid(), 'offset': 0, 'color': '#B65336'},
                          {'id': uid(), 'offset': 1, 'color': '#E8CC91'}]})
        anchors = [(0, 39), (57, 10), (125, 34), (125, 75), (0, 75)]
        nodes = [dict(id=uid(), anchor={'x': x, 'y': y}) for x, y in anchors]
        nodes[0]['outgoing'] = {'x': 24, 'y': 1}
        nodes[1]['incoming'] = {'x': 31, 'y': 7}
        nodes[1]['outgoing'] = {'x': 83, 'y': 13}
        nodes[2]['incoming'] = {'x': 107, 'y': 49}
        wave = shape('path', 40, 128, 125, 75, '#23483E', name='Editable curved landscape',
            path={'width': 125, 'height': 75, 'evenOdd': False,
                  'contours': [{'id': uid(), 'closed': True, 'nodes': nodes}]},
            stroke={'color': '#183B34', 'width': 0.3, 'join': 'round'})
        axis = text(146, 212, 40, 19, '01', 40, 'Skia', '#B65336',
                    variations={'2003265652': 1.8, '2003072104': 1.12},
                    kerningMode='metrics')
        footer = text(20, 240, 168, 7, 'FORM / MATERIAL STUDIES                         203.2 × 254 MM',
                      7, 'Menlo-Regular', '#254237', tracking=0.3)
        elements = [
            text(18, 13, 150, 7, 'FORM / OBJECTS & THEIR RELATIONSHIPS', 7.5, 'Menlo-Regular', tracking=0.8),
            text(169, 13, 20, 7, 'No. 001', 7.5, 'Menlo-Regular'), title, subtitle,
            mask, gradient, wave,
            text(18, 215, 117, 13, 'One object. A thousand possible forms.', 11.5, leading=15), axis, footer,
            shape('line', 18, 25, 168, 0.1, '#8B9A87', stroke={'color': '#8B9A87', 'width': 0.2}),
            shape('line', 18, 234, 168, 0.1, '#8B9A87', stroke={'color': '#8B9A87', 'width': 0.2})]
        c.call('form_set_artwork', {'object_id': sid, 'artwork': {'background': '#F3EFE3', 'unit': 'in',
            'bleed': 3, 'snapEnabled': True, 'gridSpacing': 5,
            'guides': [{'id': uid(), 'axis': 'x', 'position': 18},
                       {'id': uid(), 'axis': 'x', 'position': 186},
                       {'id': uid(), 'axis': 'y', 'position': 25}], 'elements': elements}})

        def get(): return c.call('form_get_project')
        def art(oid=sid): return c.call('form_get_artwork', {'object_id': oid})
        def edit(command, ids, **extra):
            return c.call('form_edit_artwork', {'object_id': sid, 'command': command, 'element_ids': ids, **extra})
        edit('align', [elements[0]['id'], footer['id']], mode='left')
        assert next(e for e in art()['elements'] if e['id'] == footer['id'])['x'] == 18
        edit('clip', [gradient['id'], wave['id']], mask_id=mask['id'])
        grouped = edit('group', [mask['id'], gradient['id'], wave['id']])
        group = grouped['selected_elements'][0]
        edit('transform', [group], rotation=-6)
        before_curve = get()
        c.call('form_edit_path', {'object_id': sid, 'element_id': wave['id'],
            'operation': 'transform', 'node_ids': [nodes[1]['id']],
            'matrix': {'a': 1, 'b': 0, 'c': 0, 'd': 1, 'tx': 0, 'ty': -0.8}})
        assert get()['objects'] != before_curve['objects']
        c.call('form_undo'); assert get() == before_curve

        alternate = c.call('form_duplicate_object', {'object_id': sid, 'mode': 'iteration',
            'name': 'AFFINITIES / Outlined alternate'})
        alt_art = art(alternate['id']); alt_art['background'] = '#DFE5D7'
        c.call('form_set_artwork', {'object_id': alternate['id'], 'artwork': alt_art})
        outlined = c.call('form_convert_to_paths', {'object_id': alternate['id'], 'element_ids': [title['id']]})
        assert outlined['elements'] and all(e['kind'] == 'path' for e in outlined['elements'])
        assert next(e for e in art(alternate['id'])['elements'] if e['id'] == title['id'])['hidden']

        box = c.call('form_add_object', {'recipe_id': 'box', 'name': 'AFFINITIES / Oak edition',
            'material_id': 'oak', 'parameters': {'width': 203.2, 'depth': 254, 'height': 12, 'corner': 2},
            'position': [270, 0, 0]})
        c.call('form_link_artwork', {'object_id': box['id'], 'source_object_id': sid})
        linked_variant = c.call('form_duplicate_object', {'object_id': box['id'], 'mode': 'variant',
            'name': 'AFFINITIES / Graphite edition', 'material_id': 'graphite'})
        package = library / (project['id'] + '.form')
        def refs(): return {r['id']: r['file'] for r in json.loads((package / 'Manifest.json').read_text())['objects']}
        old_refs = refs(); original_words = title['text']
        final_title = next(e for e in art()['elements'] if e['id'] == title['id'])
        final_title['typography']['pairKerning'] = {'0': -0.8}
        edit('replace', [title['id']], elements=[final_title])
        assert {k for k in old_refs if refs()[k] != old_refs[k]} == {sid}
        assert art(box['id']) == art(linked_variant['id']) == art()
        assert next(e for e in art()['elements'] if e['id'] == title['id'])['text'] == original_words

        folder = OUTPUT / 'design-acceptance'; folder.mkdir(parents=True, exist_ok=True)
        exports = {}
        for name, oid in [('composition', sid), ('outlined-alternate', alternate['id']), ('physical-face', box['id'])]:
            for fmt in ('pdf', 'svg', 'png'):
                path = folder / (name + '.' + fmt)
                result = c.call('form_export_artwork', {'object_id': oid, 'format': fmt,
                    'path': str(path), 'dpi': 150})
                assert abs(result['width_mm'] - 203.2) < 1e-9
                assert abs(result['height_mm'] - 254) < 1e-9
                if fmt == 'png': assert struct.unpack('>II', path.read_bytes()[16:24]) == (1200, 1500)
                if fmt == 'pdf':
                    match = re.search(rb'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)', path.read_bytes())
                    assert match and abs(float(match[1]) - 576) < .01 and abs(float(match[2]) - 720) < .01
                exports[name + '.' + fmt] = result
        saved = get()
        c.call('form_open_project', {'project_id': project['id']})
        reopened = get()
        assert reopened['objects'] == saved['objects'] and reopened['history'] == saved['history']
        c.call('form_set_view', {'view': 'split', 'object_id': sid, 'element_ids': [title['id']]})
        report = {'project_id': project['id'], 'sheet_id': sid, 'title_id': title['id'], 'subtitle_id': subtitle['id'],
            'wave_id': wave['id'], 'group_id': group, 'alternate_id': alternate['id'], 'box_id': box['id'],
            'variant_id': linked_variant['id'], 'exports': exports,
            'checks': 'Exact 8 × 10 inch frame; installed faces; rich leading/tracking/weight/alignment; supported ligatures and real variable axes; independent pair spacing; editable curve nodes; guides/numeric alignment; transformed group/member edit; fill/stroke/gradient/geometric masks; independent alternate; editable outlined copy with hidden source; linked physical faces/variant; source-only update; actual physical output; saved reopen.',
            'native_acceptance_pending': True}
        (OUTPUT / 'design-acceptance-report.json').write_text(json.dumps(report, indent=2))
        print(json.dumps({k: v for k, v in report.items() if k != 'exports'}, indent=2))
    finally:
        c.close()


if __name__ == '__main__':
    main()
