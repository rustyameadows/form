#!/usr/bin/env python3
"""Exercise physical fabric repeats over the packaged stdio MCP bridge.

Requires the running FORM app to use a disposable library below this repo's
.local directory. Creates a new study only. Never connects to or sends printers.
"""
import copy
import json
import math
import pathlib
import re
import struct
import time
import uuid
import xml.etree.ElementTree as ET

from smoke_mcp import Client, OUTPUT, ROOT


def main():
    c = Client()
    try:
        status = c.call('form_status')
        library = pathlib.Path(status['library_path']).resolve()
        assert library.is_relative_to((ROOT / '.local').resolve()), 'Use an isolated FORM_LIBRARY_PATH below .local.'
        c.discover(['form_update_object', 'form_export_artwork'])
        folder = OUTPUT / 'fabric-pattern-smoke'
        folder.mkdir(parents=True, exist_ok=True)
        project = c.call('form_create_project', {'name': 'ORBITAL / Printed flight fabric', 'template': 'flightJacket'})
        garment = next(o for o in project['objects'] if o['recipeID'] == 'bomberJacket' and o['materialID'] == 'flight-nylon')
        independent = copy.deepcopy(project['objects'])
        tile = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'Flight fabric / motif tile',
                                         'parameters': {'width': 40, 'depth': 40}})
        tile_id = tile['id']
        art = {'background': '#F4E9D0', 'backgroundOpacity': 0, 'bleed': 0,
               'canvasPosition': {'x': -80, 'y': -80}, 'elements': []}
        for kind, x, y, w, h, color in [('star', 12, 9, 16, 16, '#D78045'),
                                       ('ellipse', 6, 29, 3, 3, '#E6D6B4'),
                                       ('ellipse', 30, 4, 3, 3, '#E6D6B4')]:
            art['elements'].append({'id': str(uuid.uuid4()).upper(), 'kind': kind, 'x': x, 'y': y,
                                    'width': w, 'height': h, 'color': color, 'fontSize': 14, 'text': ''})
        c.call('form_set_artwork', {'object_id': tile_id, 'artwork': art})
        source_art = c.call('form_get_artwork', {'object_id': tile_id})
        pattern = {'sourceObjectID': tile_id, 'repeatMode': 'straight', 'scale': 1.25,
                   'spacing': {'x': 4, 'y': 4}, 'offset': {'x': 12, 'y': 7}, 'rotation': 15,
                   'outputWidth': 300, 'outputLength': 200, 'includeTileBackground': False}

        def apply(value):
            return c.call('form_update_object', {'object_id': garment['id'], 'fabric_pattern': value})

        def export(fmt, name, dpi=150):
            path = folder / (name + '.' + fmt)
            result = c.call('form_export_artwork', {'object_id': garment['id'],
                'fabric_pattern_material': 'flight-nylon', 'format': fmt, 'path': str(path), 'dpi': dpi})
            assert path.stat().st_size > 200 and result['source_object_id'] == tile_id
            assert result['width_mm'] == 300 and result['height_mm'] == 200
            return result, path.read_bytes()

        mode_outputs = {}
        for mode, expected in [('straight', (54, 54)), ('halfDrop', (108, 54)),
                               ('brick', (54, 108)), ('mirror', (108, 108))]:
            pattern['repeatMode'] = mode
            apply(pattern)
            result, data = export('svg', mode)
            assert (result['repeat_width_mm'], result['repeat_height_mm']) == expected
            svg = ET.fromstring(data)
            assert float(svg.attrib['width'].removesuffix('mm')) == 300
            assert float(svg.attrib['height'].removesuffix('mm')) == 200
            repeated = next(e for e in svg.iter() if e.tag.endswith('pattern'))
            assert repeated.attrib['patternUnits'] == 'userSpaceOnUse'
            assert tuple(float(repeated.attrib[k]) for k in ('width', 'height')) == expected
            mode_outputs[mode] = result
        pattern['repeatMode'] = 'halfDrop'
        colorway_id = str(uuid.uuid4()).upper()
        pattern['colorways'] = [{'id': colorway_id, 'name': 'Solar / midnight', 'baseColor': '#233748',
                                 'replacements': {'#D78045': '#EDC86A', '#E6D6B4': '#F3EAD2'}}]
        pattern['activeColorwayID'] = colorway_id
        apply(pattern)
        _, colored = export('svg', 'solar-midnight')
        assert b'#EDC86A' in colored and b'#233748' in colored
        assert c.call('form_get_artwork', {'object_id': tile_id}) == source_art
        assert [o for o in c.call('form_get_project')['objects'] if o['id'] != tile_id] == independent

        # Invalid references, deleting a linked tile, and mixed export intents are atomic.
        baseline = c.call('form_get_project')
        bad = copy.deepcopy(pattern); bad['sourceObjectID'] = str(uuid.uuid4()).upper()
        c.call('form_batch', {'operations': [
            {'name': 'form_update_object', 'arguments': {'object_id': garment['id'], 'parameters': {'width': 700}}},
            {'name': 'form_update_object', 'arguments': {'object_id': garment['id'], 'fabric_pattern': bad}},
        ]}, expect_error=True)
        assert c.call('form_get_project') == baseline
        c.call('form_delete_objects', {'object_ids': [tile_id]}, expect_error=True)
        assert c.call('form_get_project') == baseline
        rejected_path = folder / 'must-not-exist.svg'
        rejected_path.unlink(missing_ok=True)
        c.call('form_export_artwork', {'object_id': garment['id'], 'fabric_pattern_material': 'flight-nylon',
               'roles': ['print'], 'format': 'svg', 'path': str(rejected_path)}, expect_error=True)
        assert not rejected_path.exists()
        changed = copy.deepcopy(pattern); changed['scale'] = 1.6
        apply(changed); c.call('form_undo'); assert c.call('form_get_project') == baseline

        # The live renderer updates dependent garment texture, not unrelated decoration resources.
        c.call('form_set_view', {'view': 'table', 'object_id': garment['id']})
        time.sleep(0.25)
        builds_before = c.call('form_status')['renderer']['geometry_builds']
        export_only = copy.deepcopy(pattern); export_only['outputLength'] = 500
        export_only['colorways'].append({'id': str(uuid.uuid4()).upper(), 'name': 'Unused', 'baseColor': '#AA2244'})
        apply(export_only); time.sleep(0.15)
        assert c.call('form_status')['renderer']['geometry_builds'] == builds_before, 'Output-only edits rebuilt the Table.'
        apply(pattern); time.sleep(0.15)
        builds_before = c.call('form_status')['renderer']['geometry_builds']
        edited = copy.deepcopy(source_art); edited['elements'][0]['rotation'] = 17
        edited['elements'][0]['color'] = '#B55D52'
        c.call('form_set_artwork', {'object_id': tile_id, 'artwork': edited}); time.sleep(0.15)
        builds_after = c.call('form_status')['renderer']['geometry_builds']
        assert builds_after > builds_before, 'Editing the tile did not invalidate its live garment texture.'
        _, modified = export('svg', 'edited-source')
        assert modified != colored and b'#B55D52' in modified
        assert [o for o in c.call('form_get_project')['objects'] if o['id'] != tile_id] == independent
        c.call('form_undo'); assert c.call('form_get_artwork', {'object_id': tile_id}) == source_art

        outputs = {}
        for fmt in ['svg', 'pdf', 'png', 'jpeg']:
            result, data = export(fmt, 'flight-yardage', dpi=72); outputs[fmt] = result
            if fmt == 'png':
                assert data.startswith(b'\x89PNG\r\n\x1a\n')
                assert struct.unpack('>II', data[16:24]) == (math.ceil(300 * 72 / 25.4), math.ceil(200 * 72 / 25.4))
            if fmt == 'pdf':
                box = re.search(rb'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)', data)
                assert box and abs(float(box[1]) - 300 * 72 / 25.4) < 0.01
                assert abs(float(box[2]) - 200 * 72 / 25.4) < 0.01
        saved = c.call('form_get_project')
        c.call('form_open_project', {'project_id': project['id']})
        reopened = c.call('form_get_project')
        assert reopened['objects'] == saved['objects'] and reopened['materials'] == saved['materials']
        assert reopened['schemaVersion'] >= 21
        c.call('form_set_view', {'view': 'table', 'object_id': garment['id']})
        report = {'project_id': project['id'], 'garment_id': garment['id'], 'tile_id': tile_id,
                  'schema_version': reopened['schemaVersion'], 'modes': mode_outputs, 'outputs': outputs,
                  'source_edit_geometry_builds': builds_after - builds_before,
                  'status': c.call('form_status'), 'checks': ['four physical repeats', 'colorway source independence',
                  'invalid batch rollback', 'linked source deletion rejection', 'mixed-role rejection', 'Undo',
                  'output-only edits reuse geometry', 'linked tile invalidates geometry', 'physical SVG/PDF/PNG/JPEG', 'save/reopen']}
        (OUTPUT / 'fabric-pattern-report.json').write_text(json.dumps(report, indent=2) + '\n')
        (OUTPUT / 'fabric-pattern-baseline.json').write_text(json.dumps(reopened, indent=2) + '\n')
        print(json.dumps({k: v for k, v in report.items() if k not in ['status', 'outputs', 'modes']}, indent=2))
    finally:
        c.close()


if __name__ == '__main__':
    main()
