#!/usr/bin/env python3
"""Exercise the packaged Canvas/Table flow in a disposable local library."""
import copy
import json
import pathlib
import statistics
import time
import uuid
from smoke_mcp import Client, OUTPUT, ROOT


def main():
    c = Client()
    try:
        status = c.call('form_status')
        assert pathlib.Path(status['library_path']).resolve().is_relative_to((ROOT / '.local').resolve())
        project = c.call('form_create_project', {'name': 'FIELD / Connected design surfaces'})
        workspace = c.call('form_add_object', {'recipe_id': 'artboard', 'canvas_workspace': True})
        wid = workspace['id']
        baseline = c.call('form_get_project')
        assert c.call('form_add_object', {'recipe_id': 'artboard', 'canvas_workspace': True})['id'] == wid
        assert c.call('form_get_project') == baseline
        element_id = str(uuid.uuid4()).upper()
        art = copy.deepcopy(workspace['artwork'])
        art['elements'] = [{'id': element_id, 'kind': 'text', 'x': -150, 'y': -80,
                            'width': 90, 'height': 25, 'text': 'FIELD NOTES',
                            'fontSize': 28, 'color': '#274D43'}]
        c.call('form_set_artwork', {'object_id': wid, 'artwork': art})
        original_elements = c.call('form_get_artwork', {'object_id': wid})['elements']
        frame = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'Product face',
                                         'parameters': {'width': 180, 'depth': 120}})
        fid = frame['id']
        frame_art = copy.deepcopy(frame.get('artwork') or {'background': '#E9E4D7', 'bleed': 0, 'elements': []})
        frame_art['canvasPosition'] = {'x': -180, 'y': -100}
        c.call('form_set_artwork', {'object_id': fid, 'artwork': frame_art})
        clock = c.call('form_add_object', {'recipe_id': 'clock', 'name': 'Linked object',
                                         'position': [240, 0, 0]})
        c.call('form_link_artwork', {'object_id': clock['id'], 'source_object_id': fid, 'fit': 'fit'})
        before = c.call('form_get_project')
        moved = c.call('form_edit_artwork', {'command': 'transfer', 'object_id': wid,
                       'target_object_id': fid, 'element_ids': [element_id]})
        assert moved['target_object_id'] == fid
        assert not c.call('form_get_artwork', {'object_id': wid})['elements']
        transferred = c.call('form_get_artwork', {'object_id': fid})['elements'][0]
        transform = transferred.get('affine', {})
        assert transferred['x'] + transform.get('tx', 0) == 30
        assert transferred['y'] + transform.get('ty', 0) == 20
        assert c.call('form_get_artwork', {'object_id': clock['id']})['elements'][0] == transferred
        after = c.call('form_get_project')
        c.call('form_undo'); assert c.call('form_get_project') == before
        c.call('form_redo'); assert c.call('form_get_project') == after
        c.call('form_edit_artwork', {'command': 'transfer', 'object_id': fid,
               'target_object_id': wid, 'element_ids': [element_id]})
        returned = c.call('form_get_artwork', {'object_id': wid})['elements'][0]
        transform = returned.pop('affine', {})
        assert transform.get('tx', 0) == 0 and transform.get('ty', 0) == 0
        assert returned == original_elements[0]
        assert not c.call('form_get_artwork', {'object_id': clock['id']})['elements']
        # Origin changes preserve geometry and Undo across the same command path.
        before_origin = c.call('form_get_project')
        c.call('form_edit_artwork', {'object_id': wid, 'element_ids': [element_id],
                                   'command': 'origin', 'origin': {'x': 0, 'y': 1}})
        assert c.call('form_get_artwork', {'object_id': wid})['elements'][0]['transformOrigin'] == {'x': 0, 'y': 1}
        c.call('form_undo'); assert c.call('form_get_project') == before_origin
        for view in ['canvas', 'split', 'canvas_window', 'table', 'split', 'canvas']:
            c.call('form_set_view', {'view': view, **({'object_id': wid, 'element_ids': [element_id]} if view != 'table' else {})})
            state = c.call('form_status')['design_surfaces']
            expected = 'split' if view == 'split' else 'detached' if view == 'canvas_window' else 'single'
            if view == 'table' and state['canvas_window_open']:
                expected = 'detached'
            assert state['layout'] == expected, (view, state)
        outputs = {}
        for fmt in ['svg', 'pdf', 'png', 'jpeg']:
            result = c.call('form_export_artwork', {'object_id': wid, 'element_ids': [element_id],
                'format': fmt, 'dpi': 300, 'path': str(OUTPUT / ('field-notes-selection.' + fmt))})
            outputs[fmt] = result
        # Hundreds of loose elements exercise ordinary edits, not a special benchmark path.
        many = copy.deepcopy(art)
        many['elements'] += [{'id': str(uuid.uuid4()).upper(), 'kind': 'rectangle',
            'x': (i % 25) * 12 - 240, 'y': (i // 25) * 12 - 180,
            'width': 8, 'height': 8, 'color': '#C96543', 'text': '', 'fontSize': 14} for i in range(500)]
        c.call('form_set_artwork', {'object_id': wid, 'artwork': many})
        timings = []
        for _ in range(8):
            start = time.monotonic()
            c.call('form_edit_artwork', {'object_id': wid, 'element_ids': [element_id],
                                       'command': 'transform', 'translate_x': 1})
            timings.append((time.monotonic() - start) * 1000)
        saved = c.call('form_get_project')
        c.call('form_open_project', {'project_id': project['id']})
        reopened = c.call('form_get_project')
        assert reopened['objects'] == saved['objects']
        report = {'project_id': project['id'], 'workspace_id': wid, 'frame_id': fid,
                  'product_id': clock['id'], 'element_id': element_id, 'loose_elements': 501,
                  'median_edit_ms': statistics.median(timings), 'max_edit_ms': max(timings),
                  'outputs': outputs, 'status': c.call('form_status')}
        (OUTPUT / 'canvas-report.json').write_text(json.dumps(report, indent=2))
        print(json.dumps({k: v for k, v in report.items() if k not in ['outputs', 'status']}, indent=2))
    finally:
        c.close()


if __name__ == '__main__':
    main()
