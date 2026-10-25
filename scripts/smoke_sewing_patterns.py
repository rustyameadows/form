#!/usr/bin/env python3
"""Exercise editable sewing pieces through the real packaged FORM MCP bridge.

The running app must use an isolated library below this repository's .local.
Creates a new study and physical files only; never sends work to equipment.
"""
import copy
import json
import math
import pathlib
import re
import struct
import uuid
import xml.etree.ElementTree as ET

from smoke_mcp import Client, OUTPUT, ROOT


def main():
    c = Client()
    try:
        status = c.call('form_status')
        library = pathlib.Path(status['library_path']).resolve()
        assert library.is_relative_to((ROOT / '.local').resolve()), 'Use a disposable FORM_LIBRARY_PATH below .local.'
        assert len(c.rpc('tools/list')['tools']) == 50
        folder = OUTPUT / 'sewing-pattern-smoke'; folder.mkdir(parents=True, exist_ok=True)
        project = c.call('form_create_project', {'name': 'FIELD / Everyday tote cutting study'})
        workspace = c.call('form_add_object', {'recipe_id': 'artboard', 'canvas_workspace': True})
        owner = workspace['id']
        c.call('form_edit_artwork', {'object_id': owner, 'command': 'pattern_template', 'template': 'tote'})
        art = c.call('form_get_artwork', {'object_id': owner})
        assert len(art['elements']) == 2 and len(art['sewingSeams']) == 3
        body, handle = art['elements']
        assert (body['width'], body['height']) == (340, 380)
        assert (handle['width'], handle['height']) == (120, 600)
        assert body['sewingPiece']['cutQuantity'] == handle['sewingPiece']['cutQuantity'] == 2
        assert len(body['sewingPiece']['notches']) == 2
        baseline = c.call('form_get_project')

        def export(fmt, name='everyday-tote', ids=None):
            path = folder / (name + '.' + fmt)
            args = {'object_id': owner, 'pattern_pieces': True, 'format': fmt, 'dpi': 72, 'path': str(path)}
            if ids is not None: args['element_ids'] = ids
            result = c.call('form_export_artwork', args)
            assert path.stat().st_size > 200 and result['calibration_square_mm'] == 50
            return result, path.read_bytes()

        initial, svg_data = export('svg')
        assert initial['mismatched_seams'] == 0 and len(initial['seams']) == 3
        pieces = {p['element_id']: p for p in initial['pieces']}
        assert (pieces[body['id']]['cut_width_mm'], pieces[body['id']]['cut_height_mm']) == (360, 420)
        assert (pieces[handle['id']]['cut_width_mm'], pieces[handle['id']]['cut_height_mm']) == (120, 640)
        svg = ET.fromstring(svg_data)
        assert float(svg.attrib['width'].removesuffix('mm')) == initial['width_mm']
        metadata = next(e for e in svg.iter() if e.attrib.get('id') == 'form-sewing-pattern')
        assert json.loads(metadata.text)['cutting_template'] is True
        assert all(any(e.attrib.get('id') == 'form-role-' + role for e in svg.iter()) for role in ['cut', 'stitch', 'guide'])
        assert c.call('form_get_project') == baseline, 'Derived export changed the editable document.'

        # Physical allowances stay millimeters after a nonuniform source transform.
        c.call('form_edit_artwork', {'object_id': owner, 'command': 'transform', 'element_ids': [body['id']], 'scale_x': 1.2})
        scaled, _ = export('svg', 'scaled-panel')
        panel = next(p for p in scaled['pieces'] if p['element_id'] == body['id'])
        assert abs(panel['edge_lengths_mm'][0] - 408) < 1e-7
        assert abs(panel['cut_width_mm'] - 428) < 1e-7
        assert panel['seam_allowances_mm'] == [30, 10, 10, 10]
        spec = copy.deepcopy(body['sewingPiece']); spec['seamAllowance'] = 12
        c.call('form_edit_artwork', {'object_id': owner, 'command': 'pattern_piece', 'element_ids': [body['id']], 'piece': spec})
        wider, _ = export('svg', 'scaled-panel-allowance')
        panel = next(p for p in wider['pieces'] if p['element_id'] == body['id'])
        assert abs(panel['cut_width_mm'] - 432) < 1e-7 and abs(panel['cut_height_mm'] - 422) < 1e-7
        c.call('form_undo'); c.call('form_undo'); assert c.call('form_get_project') == baseline

        invalid = copy.deepcopy(spec); invalid['notches'][0]['depth'] = 100
        c.call('form_batch', {'operations': [
            {'name': 'form_edit_artwork', 'arguments': {'object_id': owner, 'command': 'transform', 'element_ids': [body['id']], 'translate_x': 20}},
            {'name': 'form_edit_artwork', 'arguments': {'object_id': owner, 'command': 'pattern_piece', 'element_ids': [body['id']], 'piece': invalid}},
        ]}, expect_error=True)
        assert c.call('form_get_project') == baseline
        folded = copy.deepcopy(body['sewingPiece']); folded['onFoldEdge'] = 0
        c.call('form_edit_artwork', {'object_id': owner, 'command': 'pattern_piece', 'element_ids': [body['id']], 'piece': folded})
        fold_result, fold_svg = export('svg', 'cut-on-fold')
        panel = next(p for p in fold_result['pieces'] if p['element_id'] == body['id'])
        assert panel['on_fold_edge'] == 0 and panel['seam_allowances_mm'][0] == 0
        fold_root = ET.fromstring(fold_svg)
        production = json.loads(next(e for e in fold_root.iter() if e.attrib.get('id') == 'form-production').text)
        assert next(p for p in production['role_pages'] if p['role'] == 'cut')['elements'] == 4
        c.call('form_undo'); assert c.call('form_get_project') == baseline
        mismatch = {'id': str(uuid.uuid4()).upper(), 'name': 'Deliberate length check',
                    'first': {'elementID': body['id'], 'edge': 1, 'copy': 1},
                    'second': {'elementID': handle['id'], 'edge': 1, 'copy': 1}, 'tolerance': 1}
        c.call('form_edit_artwork', {'object_id': owner, 'command': 'seam_pair', 'seam': mismatch})
        checked, _ = export('svg', 'seam-mismatch')
        assert checked['mismatched_seams'] == 1
        check = next(s for s in checked['seams'] if s['id'] == mismatch['id'])
        assert abs(check['difference_mm'] - 220) < 1e-7 and check['matches'] is False

        # A seam crossing owners cannot silently lose the other half of its reference.
        destination = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'Tote / editable pattern frame',
                           'parameters': {'width': 800, 'depth': 750}})
        before_transfer = c.call('form_get_project')
        c.call('form_edit_artwork', {'object_id': owner, 'command': 'transfer', 'target_object_id': destination['id'],
               'element_ids': [body['id']], 'offset_x': 20, 'offset_y': 25}, expect_error=True)
        assert c.call('form_get_project') == before_transfer
        # Remove the deliberate mismatch; move the complete source, preserving its three cut-copy joins.
        c.call('form_edit_artwork', {'object_id': owner, 'command': 'seam_pair', 'seam': None, 'seam_id': mismatch['id']})
        before_move = c.call('form_get_project')
        c.call('form_edit_artwork', {'object_id': owner, 'command': 'transfer', 'target_object_id': destination['id'],
               'element_ids': [body['id'], handle['id']], 'offset_x': 20, 'offset_y': 25})
        owner = destination['id']
        moved_art = c.call('form_get_artwork', {'object_id': owner})
        assert len(moved_art['sewingSeams']) == 3
        assert not c.call('form_get_artwork', {'object_id': workspace['id']})['elements']
        c.call('form_undo'); assert c.call('form_get_project') == before_move; c.call('form_redo')

        before_group = c.call('form_get_project')
        grouped = c.call('form_edit_artwork', {'object_id': owner, 'command': 'group', 'element_ids': [body['id'], handle['id']]})
        c.call('form_edit_artwork', {'object_id': owner, 'command': 'ungroup', 'element_ids': grouped['selected_elements']})
        grouped_metrics, _ = export('svg', 'ungrouped')
        assert grouped_metrics['mismatched_seams'] == 0
        c.call('form_undo'); c.call('form_undo'); assert c.call('form_get_project') == before_group
        duplicated = c.call('form_edit_artwork', {'object_id': owner, 'command': 'duplicate', 'element_ids': [body['id'], handle['id']]})
        assert len(c.call('form_get_artwork', {'object_id': owner})['sewingSeams']) == 6
        c.call('form_edit_artwork', {'object_id': owner, 'command': 'delete', 'element_ids': duplicated['selected_elements']})
        assert len(c.call('form_get_artwork', {'object_id': owner})['sewingSeams']) == 3
        c.call('form_undo'); c.call('form_undo'); assert c.call('form_get_project') == before_group

        outputs = {}
        for fmt in ['svg', 'pdf', 'png', 'jpeg']:
            result, data = export(fmt); outputs[fmt] = result
            if fmt == 'png':
                expected = tuple(math.floor(result[k] * 72 / 25.4 + 0.5) for k in ['width_mm', 'height_mm'])
                assert struct.unpack('>II', data[16:24]) == expected
            if fmt == 'pdf':
                box = re.search(rb'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)', data)
                assert box and abs(float(box[1]) / (72 / 25.4) - result['width_mm']) < 0.001
                assert abs(float(box[2]) / (72 / 25.4) - result['height_mm']) < 0.001
        saved = c.call('form_get_project')
        c.call('form_open_project', {'project_id': project['id']})
        reopened = c.call('form_get_project')
        assert reopened['objects'] == saved['objects'] and reopened['schemaVersion'] >= 24
        c.call('form_set_view', {'view': 'canvas', 'object_id': owner, 'element_ids': [body['id']]})
        report = {'project_id': project['id'], 'workspace_id': workspace['id'], 'frame_id': owner,
                  'body_id': body['id'], 'handle_id': handle['id'], 'schema_version': reopened['schemaVersion'],
                  'outputs': outputs, 'status': c.call('form_status'),
                  'checks': ['editable tote template', 'cut quantities and physical allowances', 'nonuniform source transform',
                  'invalid batch rollback', 'length mismatch diagnostics', 'partial seam transfer rejection', 'complete transfer/Undo',
                  'group/ungroup', 'duplicate/delete seam identities', 'SVG manufacturing layers/metadata', 'PDF millimeters',
                  'PNG physical DPI', 'calibration square', 'saved reopen']}
        (OUTPUT / 'sewing-pattern-report.json').write_text(json.dumps(report, indent=2) + '\n')
        (OUTPUT / 'sewing-pattern-baseline.json').write_text(json.dumps(reopened, indent=2) + '\n')
        print(json.dumps({k: v for k, v in report.items() if k not in ['outputs', 'status']}, indent=2))
    finally:
        c.close()


if __name__ == '__main__':
    main()
