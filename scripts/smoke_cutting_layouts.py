#!/usr/bin/env python3
"""Validate saved material layouts over the packaged FORM stdio bridge.

Requires an isolated app library below this repo's .local. Creates a fresh study
and exports physical files; never deducts stock or communicates with equipment.
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
        tools = c.rpc('tools/list')['tools']; names = {t['name'] for t in tools}
        assert len(names) == len(tools) and {'form_edit_artwork', 'form_export_artwork', 'form_get_project'} <= names
        studio_path = library / 'Studio.json'
        studio_before = studio_path.read_bytes() if studio_path.exists() else None
        folder = OUTPUT / 'cutting-layout-smoke'; folder.mkdir(parents=True, exist_ok=True)
        project = c.call('form_create_project', {'name': 'FIELD / Physical material layout'})
        frame = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'Tote / material cutting sources',
                                         'parameters': {'width': 800, 'depth': 750}})
        owner = frame['id']
        c.call('form_edit_artwork', {'object_id': owner, 'command': 'pattern_template', 'template': 'tote'})
        art = c.call('form_get_artwork', {'object_id': owner})
        body, handle = art['elements']
        source_elements = copy.deepcopy(art['elements']); source_seams = copy.deepcopy(art['sewingSeams'])
        tile = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'Layout fabric / physical tile',
                                        'parameters': {'width': 40, 'depth': 40}})
        motif = {'background': '#FFFFFF', 'backgroundOpacity': 0, 'bleed': 0, 'elements': [
            {'id': str(uuid.uuid4()).upper(), 'kind': 'star', 'x': 12, 'y': 9, 'width': 16, 'height': 16,
             'text': '', 'fontSize': 14, 'color': '#DB814A'},
            {'id': str(uuid.uuid4()).upper(), 'kind': 'ellipse', 'x': 6, 'y': 29, 'width': 3, 'height': 3,
             'text': '', 'fontSize': 14, 'color': '#E1D5B8'}]}
        c.call('form_set_artwork', {'object_id': tile['id'], 'artwork': motif})
        c.call('form_update_object', {'object_id': tile['id'], 'material_id': 'flight-nylon',
               'fabric_pattern': {'sourceObjectID': tile['id'], 'repeatMode': 'halfDrop', 'scale': 1.25,
                                  'spacing': {'x': 4, 'y': 4}, 'offset': {'x': 0, 'y': 0}}})
        materials_before = copy.deepcopy(c.call('form_get_project')['materials'])
        c.call('form_set_view', {'view': 'table', 'object_id': owner}); time.sleep(0.2)
        builds_before = c.call('form_status')['renderer']['geometry_builds']
        options = {'id': str(uuid.uuid4()).upper(), 'name': 'Flight nylon / tote material layout',
                   'materialID': 'flight-nylon', 'stockWidth': 1400, 'surface': 'roll', 'stock': 'singleLayer',
                   'grain': 'bidirectional', 'margin': 10, 'spacing': 5, 'maximumLength': 5000,
                   'fabricOrigin': {'x': 13, 'y': -7}, 'costPerSquareMeter': 12.5, 'costCurrency': 'USD'}

        def edit(value, action='save'):
            c.call('form_edit_artwork', {'object_id': owner, 'command': 'cut_layout',
                                       'layout_action': action, 'cutting_layout': value})

        def check(path=None):
            args = {'object_id': owner, 'cut_layout': True, 'layout_preflight': True, 'format': 'pdf'}
            if path is not None: args['path'] = str(path)
            return c.call('form_export_artwork', args)

        before = c.call('form_get_project')
        started = time.monotonic(); edit(options, 'plan'); plan_ms = (time.monotonic() - started) * 1000
        planned = c.call('form_get_artwork', {'object_id': owner})['sewingLayout']
        first = check(); assert first['valid'] and len(first['placements']) == 4
        assert first['required_length_mm'] == 660 and first['working_width_mm'] == 1400
        assert first['inventory_deducted'] is False and first['cost_currency'] == 'USD'
        assert abs(first['allocated_area_mm2'] - 924000) < 1e-7
        assert abs(first['estimated_cost'] - 11.55) < 1e-7
        assert sum(len(p['copies']) for p in first['placements']) == 4
        saved = c.call('form_get_project')
        c.call('form_undo'); assert c.call('form_get_project') == before
        c.call('form_redo'); assert c.call('form_get_project') == saved
        edit(options, 'plan')
        assert c.call('form_get_artwork', {'object_id': owner})['sewingLayout']['placements'] == planned['placements']
        time.sleep(0.15)
        assert c.call('form_status')['renderer']['geometry_builds'] == builds_before, 'Layout-only metadata rebuilt the 3D source.'

        # Saving manual poses must not call the planner or fit contours into available stock.
        manual = copy.deepcopy(planned); manual['placements'][0]['y'] += 35
        edit(manual)
        assert c.call('form_get_artwork', {'object_id': owner})['sewingLayout']['placements'] == manual['placements']
        assert check()['valid']
        c.call('form_undo')
        collision = copy.deepcopy(planned)
        collision['placements'][1]['x'] = collision['placements'][0]['x']
        collision['placements'][1]['y'] = collision['placements'][0]['y']
        edit(collision); invalid = check(); assert not invalid['valid']
        assert any(i['kind'] == 'collision' for i in invalid['issues'])
        rejected = folder / 'invalid-must-not-exist.svg'; rejected.unlink(missing_ok=True)
        c.call('form_export_artwork', {'object_id': owner, 'cut_layout': True, 'format': 'svg', 'path': str(rejected)}, expect_error=True)
        assert not rejected.exists()
        c.call('form_undo'); assert check()['valid']
        unknown = copy.deepcopy(planned); unknown.pop('stockWidth', None)
        edit(unknown); unknown_before = c.call('form_get_project')
        c.call('form_edit_artwork', {'object_id': owner, 'command': 'cut_layout', 'layout_action': 'plan'}, expect_error=True)
        assert c.call('form_get_project') == unknown_before
        assert any(i['kind'] == 'stock' for i in check()['issues'])
        c.call('form_undo')

        # Two ordinary cut copies share a placement on two-ply stock; no quantity is changed.
        folded = copy.deepcopy(planned); folded['stock'] = 'foldedPair'
        edit(folded, 'plan'); fold = check()
        assert fold['valid'] and fold['working_width_mm'] == 700 and fold['stock_layers'] == 2
        assert len(fold['placements']) == 2 and all(p['copies'] == [1, 2] for p in fold['placements'])
        assert fold['fabric_preview_ply'] == 'Upper/right half of the open stock'
        c.call('form_undo')
        sheet = copy.deepcopy(planned); sheet['surface'] = 'sheet'; sheet['sheetLength'] = 800
        edit(sheet, 'plan'); sheet_check = check()
        assert sheet_check['valid'] and sheet_check['consumed_length_mm'] == 800
        assert sheet_check['allocated_area_mm2'] == 1120000
        c.call('form_undo')

        outputs = {}
        for fmt in ['svg', 'pdf', 'png', 'jpeg']:
            path = folder / ('tote-material-layout.' + fmt)
            result = c.call('form_export_artwork', {'object_id': owner, 'cut_layout': True,
                            'include_fabric_preview': True, 'format': fmt, 'path': str(path), 'dpi': 72})
            outputs[fmt] = result; data = path.read_bytes(); assert len(data) > 300
            assert result['width_mm'] == 1400 and result['height_mm'] == 660
            if fmt == 'svg':
                svg = ET.fromstring(data); assert float(svg.attrib['width'].removesuffix('mm')) == 1400
                assert float(svg.attrib['height'].removesuffix('mm')) == 660
                metadata = json.loads(next(e for e in svg.iter() if e.attrib.get('id') == 'form-cutting-layout').text)
                assert metadata['stock_origin_mm'] == {'x': 0, 'y': 0}
                assert metadata['fabric_origin_mm'] == {'x': 13, 'y': -7}
                assert any(e.attrib.get('id') == 'form-role-fabric-reference' for e in svg.iter())
            if fmt == 'pdf':
                box = re.search(rb'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)', data)
                assert box and abs(float(box[1]) / (72 / 25.4) - 1400) < 0.001
                assert abs(float(box[2]) / (72 / 25.4) - 660) < 0.001
            if fmt == 'png':
                assert struct.unpack('>II', data[16:24]) == (math.ceil(1400 * 72 / 25.4), math.ceil(660 * 72 / 25.4))
        absent = folder / 'preflight-must-not-exist.pdf'; absent.unlink(missing_ok=True)
        assert check(absent)['valid']; assert not absent.exists()
        final_art = c.call('form_get_artwork', {'object_id': owner})
        assert final_art['elements'] == source_elements and final_art['sewingSeams'] == source_seams
        assert c.call('form_get_project')['materials'] == materials_before
        assert (studio_path.read_bytes() if studio_path.exists() else None) == studio_before
        stable = c.call('form_get_project')
        c.call('form_open_project', {'project_id': project['id']})
        reopened = c.call('form_get_project')
        assert reopened['objects'] == stable['objects'] and reopened['materials'] == stable['materials']
        assert reopened['schemaVersion'] >= 27
        c.call('form_set_view', {'view': 'canvas', 'object_id': owner, 'element_ids': [body['id']]})
        report = {'project_id': project['id'], 'source_id': owner, 'body_id': body['id'], 'handle_id': handle['id'],
                  'tile_id': tile['id'], 'schema_version': reopened['schemaVersion'], 'plan_ms': round(plan_ms, 2),
                  'preflight': first, 'folded_preflight': fold, 'sheet_preflight': sheet_check, 'outputs': outputs,
                  'checks': ['bounded deterministic plan', 'stable physical copy identities', 'Undo/Redo', 'manual poses retained',
                  'exact invalid overlap blocks export', 'missing width not guessed', 'folded two-ply quantities',
                  'sheet allocation', 'declared cost and waste', 'zero layout-only 3D rebuilds', 'actual SVG/PDF/PNG/JPEG',
                  'global fabric origin metadata', 'preflight writes no file', 'source geometry/seams/materials/inventory unchanged', 'saved reopen']}
        (OUTPUT / 'cutting-layout-report.json').write_text(json.dumps(report, indent=2) + '\n')
        (OUTPUT / 'cutting-layout-baseline.json').write_text(json.dumps(reopened, indent=2) + '\n')
        print(json.dumps({k: v for k, v in report.items() if k not in ['outputs', 'preflight', 'folded_preflight', 'sheet_preflight']}, indent=2))
    finally:
        c.close()


if __name__ == '__main__':
    main()
