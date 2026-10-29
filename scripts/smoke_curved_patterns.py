#!/usr/bin/env python3
"""Check editable curved sewing pieces through the real packaged FORM bridge.

Requires a disposable library below repo/.local. Creates projects/physical files;
never prints, communicates with equipment, or deducts stock.
"""
import copy
import json
import math
import pathlib
import re
import struct
import uuid
import xml.etree.ElementTree as ET

from smoke_mcp import Client, OUTPUT, ROOT, project_source


def uid():
    return str(uuid.uuid4()).upper()


def node(x, y):
    return {'id': uid(), 'anchor': {'x': x, 'y': y}}


def main():
    c = Client()
    try:
        status = c.call('form_status')
        library = pathlib.Path(status['library_path']).resolve()
        assert library.is_relative_to((ROOT / '.local').resolve()), 'Use a disposable FORM_LIBRARY_PATH below repo/.local.'
        c.discover(['form_edit_artwork', 'form_edit_path', 'form_export_artwork'])
        studio_path = library / 'Studio.json'
        studio_before = studio_path.read_bytes() if studio_path.exists() else None
        folder = OUTPUT / 'curved-pattern-smoke'; folder.mkdir(parents=True, exist_ok=True)
        project = c.call('form_create_project', {'name': 'FIELD / Measured rounded pouch'})
        frame = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'Rounded pouch / editable source',
                                        'parameters': {'width': 800, 'depth': 750}})
        owner = frame['id']
        args = {'object_id': owner, 'command': 'pattern_template', 'template': 'roundedPouch',
                'pattern_parameters': {'width': 280, 'height': 190, 'corner_radius': 40,
                                       'seam_allowance': 10, 'facing_height': 40, 'material_id': 'flight-nylon'}}
        before = c.call('form_get_project'); c.call('form_edit_artwork', args)
        source = c.call('form_get_artwork', {'object_id': owner})
        body, facing = source['elements']; source_nodes = body['path']['contours'][0]['nodes']
        assert body['width'] == 280 and body['height'] == 190 and facing['height'] == 40
        assert len(source_nodes) == 6 and any(n.get('outgoing') for n in source_nodes)
        assert body['path']['contours'][0]['id'] and len(source['sewingSeams']) == 7
        assert all(n['edgeID'] and n['endID'] for n in body['sewingPiece']['notches'])
        saved = c.call('form_get_project')
        c.call('form_undo'); assert project_source(c.call('form_get_project')) == project_source(before)
        c.call('form_redo'); assert project_source(c.call('form_get_project')) == project_source(saved)

        def export(fmt, target=owner, **extra):
            path = folder / (('rounded-pouch' if target == owner else 'holed-panel') + '.' + fmt)
            result = c.call('form_export_artwork', {'object_id': target, 'pattern_pieces': True,
                           'format': fmt, 'path': str(path), 'dpi': 72, **extra})
            data = path.read_bytes(); assert len(data) > 300
            return result, data

        outputs = {}
        for fmt in ['svg', 'pdf', 'png']:
            result, data = export(fmt); outputs[fmt] = result
            assert result['calibration_square_mm'] == 50 and result['mismatched_seams'] == result['uncertain_seams'] == 0
            panel = next(p for p in result['pieces'] if p['element_id'] == body['id'])
            assert (panel['cut_width_mm'], panel['cut_height_mm']) == (300, 210)
            assert panel['contour_tolerance_mm'] == 0.02 and len(panel['source_edges']) == 6
            assert sum(panel['edge_length_errors_mm']) <= 0.005 + 1e-8
            assert all(e['id'] and e['end_id'] and e['contour_id'] for e in panel['source_edges'])
            assert all(n['cut_opening_length_mm'] == 3 for n in panel['resolved_notches'])
            if fmt == 'svg':
                root = ET.fromstring(data)
                assert float(root.attrib['width'].removesuffix('mm')) == result['width_mm']
                metadata = json.loads(next(e for e in root.iter() if e.attrib.get('id') == 'form-sewing-pattern').text)
                assert metadata['pieces'][0]['source_edges'] == result['pieces'][0]['source_edges']
            if fmt == 'pdf':
                box = re.search(rb'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)', data)
                assert box and abs(float(box[1]) / (72 / 25.4) - result['width_mm']) < 0.001
                assert abs(float(box[2]) / (72 / 25.4) - result['height_mm']) < 0.001
            if fmt == 'png':
                expected = tuple(math.floor(result[k] * 72 / 25.4 + 0.5) for k in ['width_mm', 'height_mm'])
                assert struct.unpack('>II', data[16:24]) == expected
        assert c.call('form_get_artwork', {'object_id': owner}) == source

        # A topology change cannot silently retarget a guarded source seam or notch.
        base = {'object_id': owner, 'element_id': body['id']}
        for edit in [{'operation': 'insert', 'node_ids': [source_nodes[2]['id']], 't': 0.5}, {'operation': 'reverse'}]:
            c.call('form_edit_path', {**base, **edit}, expect_error=True)
            assert project_source(c.call('form_get_project')) == project_source(saved)
        # Normal curve/measurement edits stay editable, preserving original edge identity.
        c.call('form_edit_path', {**base, 'operation': 'transform', 'node_ids': [source_nodes[3]['id']],
               'matrix': {'a': 1, 'b': 0, 'c': 0, 'd': 1, 'tx': 0, 'ty': 4}})
        changed = c.call('form_get_artwork', {'object_id': owner})
        assert changed['elements'][0]['path']['contours'][0]['nodes'][3]['id'] == source_nodes[3]['id']
        assert changed['sewingSeams'] == source['sewingSeams']
        c.call('form_undo'); assert project_source(c.call('form_get_project')) == project_source(saved)
        cloned = c.call('form_edit_artwork', {'object_id': owner, 'command': 'duplicate', 'element_ids': [body['id'], facing['id']]})
        duplicate = c.call('form_get_artwork', {'object_id': owner})
        assert len(duplicate['sewingSeams']) == 14
        clone_body = next(e for e in duplicate['elements'] if e['id'] in cloned['selected_elements'] and e['kind'] == 'path')
        clone_ids = {n['id'] for n in clone_body['path']['contours'][0]['nodes']}
        assert all(n['edgeID'] in clone_ids and n['endID'] in clone_ids for n in clone_body['sewingPiece']['notches'])
        c.call('form_undo'); assert project_source(c.call('form_get_project')) == project_source(saved)

        destination = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'Source transfer check',
                                                'parameters': {'width': 800, 'depth': 750}})
        before_transfer = c.call('form_get_project')
        transfer = {'object_id': owner, 'command': 'transfer', 'target_object_id': destination['id'],
                    'offset_x': 0, 'offset_y': 0}
        c.call('form_edit_artwork', {**transfer, 'element_ids': [body['id']]}, expect_error=True)
        assert project_source(c.call('form_get_project')) == project_source(before_transfer)
        c.call('form_edit_artwork', {**transfer, 'element_ids': [body['id'], facing['id']]})
        moved = c.call('form_get_artwork', {'object_id': destination['id']})
        assert len(moved['sewingSeams']) == 7 and not c.call('form_get_artwork', {'object_id': owner})['elements']
        c.call('form_undo'); assert project_source(c.call('form_get_project')) == project_source(before_transfer)

        # Hole-aware physical outputs and layout collision/consumption use material regions.
        hole_frame = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'Actual hole / material region',
                                              'parameters': {'width': 400, 'depth': 300}})
        ring_id, insert_id = uid(), uid()
        ring = {'id': ring_id, 'kind': 'path', 'x': 0, 'y': 0, 'width': 120, 'height': 120,
                'text': '', 'fontSize': 14, 'color': '#43718A', 'fillEnabled': False,
                'stroke': {'color': '#43718A', 'width': 0.3},
                'path': {'width': 120, 'height': 120, 'evenOdd': True, 'contours': [
                    {'id': uid(), 'closed': True, 'nodes': [node(0, 0), node(120, 0), node(120, 120), node(0, 120)]},
                    {'id': uid(), 'closed': True, 'nodes': [node(30, 30), node(30, 90), node(90, 90), node(90, 30)]}]},
                'sewingPiece': {'name': 'Holed panel', 'seamAllowance': 5, 'materialID': 'flight-nylon'}}
        insert = {'id': insert_id, 'kind': 'rectangle', 'x': 160, 'y': 0, 'width': 20, 'height': 20,
                  'text': '', 'fontSize': 14, 'color': '#43718A',
                  'sewingPiece': {'name': 'Separate hole insert', 'seamAllowance': 0, 'materialID': 'flight-nylon'}}
        c.call('form_set_artwork', {'object_id': hole_frame['id'], 'artwork': {'background': '#FFFFFF', 'bleed': 0, 'elements': [ring, insert]}})
        hole_source = c.call('form_get_artwork', {'object_id': hole_frame['id']})
        hole_meta, _ = export('svg', hole_frame['id'])
        assert next(p for p in hole_meta['pieces'] if p['element_id'] == ring_id)['hole_count'] == 1
        layout = {'id': uid(), 'name': 'Keep the hole empty', 'materialID': 'flight-nylon', 'stockWidth': 250,
                  'margin': 0, 'spacing': 5, 'grain': 'unrestricted', 'placements': [
                    {'elementID': ring_id, 'copies': [1], 'x': 10, 'y': 10, 'rotation': 0},
                    {'elementID': insert_id, 'copies': [1], 'x': 65, 'y': 65, 'rotation': 0}]}
        def save_layout(value):
            c.call('form_edit_artwork', {'object_id': hole_frame['id'], 'command': 'cut_layout', 'layout_action': 'save', 'cutting_layout': value})
        def preflight():
            return c.call('form_export_artwork', {'object_id': hole_frame['id'], 'cut_layout': True, 'layout_preflight': True, 'format': 'pdf'})
        save_layout(layout); check = preflight()
        assert check['valid'] and 14770 < check['cut_area_mm2'] < 14800
        assert check['inventory_deducted'] is False
        bad = copy.deepcopy(layout); bad['placements'][1]['x'] = 30
        save_layout(bad); assert any(i['kind'] == 'collision' for i in preflight()['issues'])
        c.call('form_undo'); assert preflight()['valid']
        layout_path = folder / 'hole-aware-material-layout.pdf'
        c.call('form_export_artwork', {'object_id': hole_frame['id'], 'cut_layout': True,
               'include_fabric_preview': True, 'format': 'pdf', 'path': str(layout_path)})
        assert c.call('form_get_artwork', {'object_id': hole_frame['id']})['elements'] == hole_source['elements']
        stable = c.call('form_get_project')
        c.call('form_open_project', {'project_id': project['id']})
        reopened = c.call('form_get_project'); assert reopened['objects'] == stable['objects'] and reopened['schemaVersion'] >= 32
        assert (studio_path.read_bytes() if studio_path.exists() else None) == studio_before
        c.call('form_set_view', {'view': 'canvas', 'object_id': owner, 'element_ids': [body['id']], 'node_ids': [source_nodes[2]['id']]})
        report = {'project_id': project['id'], 'frame_id': owner, 'body_id': body['id'], 'facing_id': facing['id'],
                  'hole_frame_id': hole_frame['id'], 'exports': outputs, 'hole_preflight': check,
                  'checks': ['editable dimensioned cubic source', 'physical error bounds', 'guarded source identities',
                  'native shared Undo/Redo', 'subdivide/reverse atomic rollback', 'editable source node transform',
                  'duplicate endpoint remapping', 'partial seam transfer rejection and complete source transfer/Undo', 'real SVG/PDF/PNG', '50mm calibration', 'holes and empty material regions',
                  'hole-aware collision/area', 'source preserved', 'inventory unchanged', 'saved reopen']}
        (OUTPUT / 'curved-pattern-report.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps({k: v for k, v in report.items() if k not in ['exports', 'hole_preflight']}, indent=2))
    finally:
        c.close()


if __name__ == '__main__':
    main()
