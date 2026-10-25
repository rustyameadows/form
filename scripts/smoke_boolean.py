#!/usr/bin/env python3
"""Live boolean, region division, linked surfaces, and cache checks over real MCP.

Use a disposable FORM_LIBRARY_PATH. No printer commands or external resources.
"""
import copy
import json
import pathlib
import statistics
import struct
import time
import uuid
from smoke_mcp import Client, OUTPUT


def uid():
    return str(uuid.uuid4()).upper()


def shape(kind, x, y, w, h, color='#263C64', name=None):
    return dict(id=uid(), kind=kind, x=x, y=y, width=w, height=h,
                color=color, text='', fontSize=14, name=name or kind.title())


def artwork(c, id):
    return c.call('form_get_artwork', {'object_id': id})


def replace(c, id, element):
    return c.call('form_edit_artwork', {'object_id': id, 'command': 'replace', 'elements': [element]})


def main():
    c = Client()
    try:
        assert len(c.rpc('tools/list')['tools']) == 50
        project = c.call('form_create_project', {'name': 'Aperture · Live boolean study'})
        source = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'APERTURE / 002', 'parameters': {'width': 200, 'depth': 140}})
        a = shape('ellipse', 20, 34, 82, 82, '#D45A37', 'Aperture outer')
        b = shape('ellipse', 39, 23, 65, 65, '#D45A37', 'Aperture opening')
        b['gradient'] = dict(kind='linear', start=dict(x=0, y=0), end=dict(x=1, y=1), stops=[dict(id=uid(), offset=0, color='#D45A37'), dict(id=uid(), offset=1, color='#E4D8A9')])
        circles = [shape('ellipse', x, y, 34, 34, '#263C64', f'Petal {i+1}') for i, (x, y) in enumerate([(123, 50), (148, 50), (135.5, 29)])]
        dividers = [shape('rectangle', 124, 96, 30, 18, '#D45A37', 'Divide A'), shape('rectangle', 144, 101, 30, 18, '#263C64', 'Divide B')]
        title = shape('text', 20, 12, 160, 10); title.update(text='APERTURE / 002', fontSize=19, typography={'fontName': 'Arial-BoldMT', 'tracking': 2.5})
        caption = shape('text', 20, 124, 160, 10); caption.update(text='BOUNDARIES, STILL IN MOTION.', fontSize=10)
        c.call('form_set_artwork', {'object_id': source['id'], 'artwork': {'background': '#F9F7F0', 'bleed': 0, 'elements': [title, a, b] + circles + dividers + [caption]}})
        result = c.call('form_batch', {'operations': [
            {'name': 'form_boolean_artwork', 'arguments': {'object_id': source['id'], 'element_ids': [a['id'], b['id']], 'operation': 'subtract'}},
            {'name': 'form_boolean_artwork', 'arguments': {'object_id': source['id'], 'element_ids': [e['id'] for e in circles], 'operation': 'union'}},
            {'name': 'form_boolean_artwork', 'arguments': {'object_id': source['id'], 'element_ids': [e['id'] for e in dividers], 'operation': 'divide'}}]})['results']
        aperture, trefoil = result[0]['selected_elements'][0], result[1]['selected_elements'][0]
        assert result[0]['elements'][0]['booleanOperation'] == 'subtract'
        assert len(result[2]['selected_elements']) == 3
        baseline = artwork(c, source['id'])
        box = c.call('form_add_object', {'recipe_id': 'box', 'name': 'Aperture · Clay edition', 'material_id': 'clay', 'parameters': {'width': 220, 'depth': 160, 'height': 18}, 'position': [-250, 0, 0]})
        c.call('form_link_artwork', {'object_id': box['id'], 'source_object_id': source['id'], 'fit': 'actual'})
        variant = c.call('form_duplicate_object', {'object_id': box['id'], 'mode': 'variant', 'material_id': 'graphite'})
        package = pathlib.Path(c.call('form_status')['library_path']) / (project['id'] + '.form')
        def consumers():
            return {o['id']: o['file'] for o in json.loads((package / 'Manifest.json').read_text())['objects'] if o['id'] in [box['id'], variant['id']]}
        files = consumers()
        def export(fmt, suffix=''):
            return c.call('form_export_artwork', {'object_id': source['id'], 'format': fmt, 'path': str(OUTPUT / ('aperture-live' + suffix + '.' + fmt)), 'dpi': 150})
        export('png')
        old = (OUTPUT / 'aperture-live.png').read_bytes()
        builds = c.call('form_status')['boolean_geometry']['geometry_builds']
        cutter = copy.deepcopy(next(e for e in baseline['elements'] if e['id'] == b['id'])); cutter['width'] = 54
        replace(c, box['id'], cutter); export('png', '-edited')
        assert (OUTPUT / 'aperture-live-edited.png').read_bytes() != old
        assert consumers() == files
        build_delta = c.call('form_status')['boolean_geometry']['geometry_builds'] - builds
        assert 0 <= build_delta <= 1  # Identical geometry from a prior run can already be cached.
        c.call('form_undo'); assert artwork(c, source['id']) == baseline
        c.call('form_boolean_artwork', {'object_id': box['id'], 'element_ids': [aperture], 'operation': 'intersect', 'mode': 'update'})
        c.call('form_undo'); assert artwork(c, source['id']) == baseline
        flat = c.call('form_boolean_artwork', {'object_id': box['id'], 'element_ids': [aperture], 'mode': 'flatten'})
        assert flat['elements'][0]['kind'] == 'path' and 'booleanOperation' not in flat['elements'][0]
        assert next(e for e in artwork(c, source['id'])['elements'] if e['id'] == aperture)['hidden']
        export('png', '-flattened')
        c.call('form_undo'); assert artwork(c, source['id']) == baseline
        released = c.call('form_boolean_artwork', {'object_id': source['id'], 'element_ids': [aperture], 'mode': 'release'})
        assert set(released['selected_elements']) == {a['id'], b['id']}
        c.call('form_undo'); assert artwork(c, source['id']) == baseline
        # Unrelated foreground artwork must stay above creation, flatten, release,
        # flat compatibility mode, and divided pieces.
        stack = [shape('rectangle', 1, 1, 8, 8), shape('ellipse', 4, 1, 8, 8),
                 shape('rectangle', 5, 3, 2, 2, '#FFFFFF', 'Foreground overlay')]
        c.call('form_edit_artwork', {'object_id': source['id'], 'command': 'add', 'elements': stack})
        def below_overlay(ids):
            roots = [e['id'] for e in artwork(c, source['id'])['elements'] if not e.get('parentID')]
            assert all(roots.index(id) < roots.index(stack[-1]['id']) for id in ids)
        grouped = c.call('form_boolean_artwork', {'object_id': source['id'], 'element_ids': [e['id'] for e in stack[:2]], 'operation': 'union'})
        group_id = grouped['selected_elements'][0]; below_overlay([group_id])
        flattened = c.call('form_boolean_artwork', {'object_id': source['id'], 'element_ids': [group_id], 'mode': 'flatten'})
        below_overlay(flattened['selected_elements']); c.call('form_undo')
        released = c.call('form_boolean_artwork', {'object_id': source['id'], 'element_ids': [group_id], 'mode': 'release'})
        below_overlay(released['selected_elements']); c.call('form_undo'); c.call('form_undo')
        for mode in ['path', 'divide']:
            stack_result = c.call('form_boolean_artwork', {'object_id': source['id'], 'element_ids': [e['id'] for e in stack[:2]], 'operation': 'union', 'mode': mode})
            below_overlay(stack_result['selected_elements']); c.call('form_undo')
        c.call('form_undo'); assert artwork(c, source['id']) == baseline
        # Batch graphics mutations must roll back as a unit before the outer save.
        temp = [shape('rectangle', 1, 1, 5, 5), shape('ellipse', 3, 1, 5, 5)]
        c.call('form_edit_artwork', {'object_id': source['id'], 'command': 'add', 'elements': temp})
        before = c.call('form_get_project')
        c.call('form_batch', {'operations': [
            {'name': 'form_boolean_artwork', 'arguments': {'object_id': source['id'], 'element_ids': [e['id'] for e in temp], 'operation': 'union'}},
            {'name': 'form_update_object', 'arguments': {'object_id': box['id'], 'parameters': {'width': -1}}}]}, expect_error=True)
        assert c.call('form_get_project') == before
        c.call('form_undo'); assert artwork(c, source['id']) == baseline
        for fmt in ['svg', 'pdf', 'png', 'jpeg']: export(fmt)
        assert struct.unpack('>II', (OUTPUT / 'aperture-live.png').read_bytes()[16:24]) == (1181, 827)
        c.call('form_open_project', {'project_id': project['id']})
        assert c.call('form_get_project')['schemaVersion'] == 5
        assert artwork(c, variant['id']) == baseline
        # One hundred live groups. Repeated definitions share bounded cached paths.
        perf = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'Live geometry performance', 'parameters': {'width': 400, 'depth': 300}})
        operands, operations = [], []
        for i in range(100):
            x, y = (i % 10) * 38, (i // 10) * 28
            pair = [shape('rectangle', x, y, 24, 20), shape('ellipse', x + 10, y + 4, 18, 18)]
            operands += pair
            operations.append({'name': 'form_boolean_artwork', 'arguments': {'object_id': perf['id'], 'element_ids': [e['id'] for e in pair], 'operation': 'union'}})
        c.call('form_set_artwork', {'object_id': perf['id'], 'artwork': {'background': '#FFFFFF', 'bleed': 0, 'elements': operands}})
        c.call('form_batch', {'operations': operations})
        c.call('form_set_view', {'view': 'artwork', 'object_id': perf['id']})
        perf_art = artwork(c, perf['id'])
        edited = copy.deepcopy(next(e for e in perf_art['elements'] if e['id'] == operands[0]['id']))
        times = []
        for i in range(20):
            edited['width'] = 24.1 if i % 2 == 0 else 24.0
            start = time.perf_counter(); replace(c, perf['id'], edited)
            times.append((time.perf_counter() - start) * 1000)
        c.call('form_delete_objects', {'object_ids': [perf['id']]})
        c.call('form_set_view', {'view': 'artwork', 'object_id': box['id'], 'element_ids': [aperture]})
        report = {'project_id': project['id'], 'source_id': source['id'], 'box_id': box['id'], 'variant_id': variant['id'], 'aperture_id': aperture, 'cutter_id': b['id'], 'outer_id': a['id'], 'trefoil_id': trefoil, 'divide_ids': result[2]['selected_elements'], 'benchmark_live_groups': 100, 'saved_edit_median_ms': round(statistics.median(times), 2), 'saved_edit_p95_ms': round(sorted(times)[18], 2), 'checks': 'live group operands; Divide regions; atomic graphics batches and rollback; dynamic operand edits; scoped cache invalidation; unchanged consumer files; operation change; flatten/release/undo; physical exports; schema 5 reopen', 'status': c.call('form_status')}
        (OUTPUT / 'boolean-baseline.json').write_text(json.dumps(baseline, indent=2))
        (OUTPUT / 'boolean-report.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2))
    finally:
        c.close()


if __name__ == '__main__':
    main()
