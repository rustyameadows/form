#!/usr/bin/env python3
"""Native appearance, shared sources, physical outputs and bounded effect caches.

Run with an isolated FORM_LIBRARY_PATH. No model, network-printer or print calls.
"""
import copy
import json
import pathlib
import statistics
import time
import uuid
from smoke_mcp import Client, OUTPUT


def shape(kind, x, y, width, height, color, name=None):
    return dict(id=str(uuid.uuid4()).upper(), kind=kind, x=x, y=y, width=width, height=height,
                color=color, text='', fontSize=14, name=name or kind.title())


def text(x, y, width, height, value, size, face='HelveticaNeue-Medium', name=None):
    e = shape('text', x, y, width, height, '#263C64', name)
    e.update(text=value, fontSize=size, typography={'fontName': face})
    return e


def main():
    c = Client()
    try:
        assert len(c.rpc('tools/list')['tools']) == 50
        status = c.call('form_status'); assert '/.local/' in status['library_path']
        project = c.call('form_create_project', {'name': 'UMBRA · Light & matter'})
        ink = c.call('form_swatch', {'command': 'create', 'name': 'Ink', 'color': '#263C64'})['swatch']['id']
        sheet = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'UMBRA / Light held',
            'parameters': {'width': 200, 'depth': 140}})
        title = text(14, 12, 172, 25, 'Light, held.', 42, 'Georgia', 'Light held title')
        sub = text(14, 40, 172, 8, 'UMBRA / APPEARANCE STUDIES 001', 8.5, 'Menlo-Regular')
        sub['typography']['tracking'] = 1
        group = shape('group', 18, 60, 100, 60, '#263C64', 'Light & matter')
        group['contentSize'] = {'x': 100, 'y': 60}
        blue = shape('ellipse', 0, 0, 52, 52, '#224B9B', 'Cobalt light')
        orange = shape('ellipse', 29, 1, 52, 52, '#D45A37', 'Vermilion overlap')
        orange.update(blendMode='multiply', opacity=0.9)
        glow = shape('ellipse', 64, 32, 13, 13, '#DCCB83', 'Soft reflected light')
        glow.update(blur={'radius': 0.8}, blendMode='screen')
        ring = shape('ellipse', 11, 8, 37, 37, '#F4F0E7', 'Highlight contour')
        ring.update(fillEnabled=False, stroke={'color': '#F4F0E7', 'width': 0.45})
        for e in [blue, orange, glow, ring]: e['parentID'] = group['id']
        heading = text(132, 60, 54, 30, 'Soft edges.\nHard rules.', 18, 'Georgia-Bold')
        body = text(132, 99, 54, 24, 'Editable light,\nlayered color,\nshared surfaces.', 10)
        signature = text(14, 122, 100, 8, 'UMBRA / 001', 9, 'Menlo-Regular')
        rule = shape('line', 14, 132, 172, 0.1, '#263C64', 'Collection rule')
        rule.update(fillEnabled=False, stroke={'color': '#263C64', 'width': 0.25})
        c.call('form_set_artwork', {'object_id': sheet['id'], 'artwork': {'background': '#F4F0E7', 'bleed': 0,
            'elements': [title, sub, group, blue, orange, glow, ring, heading, body, signature, rule]}})
        c.call('form_appearance', {'object_id': sheet['id'], 'element_ids': [group['id']], 'values': {
            'shadow': {'x': 2, 'y': 3.5, 'blur': 1.2, 'opacity': 0.23, 'color': '#263C64'}}})
        c.call('form_swatch', {'command': 'assign', 'object_id': sheet['id'], 'element_ids': [group['id']],
            'target': 'shadow', 'swatch_id': ink})
        made = c.call('form_component', {'command': 'create', 'object_id': sheet['id'],
            'element_ids': [group['id']], 'name': 'UMBRA / Layered light'})
        source = made['source_object_id']; instance = made['selected_elements'][0]
        card = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'UMBRA / Field card',
            'parameters': {'width': 120, 'depth': 80}})
        c.call('form_set_artwork', {'object_id': card['id'], 'artwork': {'background': '#F4F0E7', 'bleed': 0,
            'elements': [text(12, 10, 96, 16, 'Light & matter.', 21, 'Georgia'),
                text(12, 65, 96, 8, 'A STUDY IN OVERLAP / 001', 7.5, 'Menlo-Regular')]}})
        definition = next(o for o in c.call('form_get_project')['objects'] if o['id'] == source)
        card_height = 56 * definition['parameters']['depth'] / definition['parameters']['width']
        second = c.call('form_component', {'command': 'insert', 'object_id': card['id'],
            'source_object_id': source, 'x': 32, 'y': 24, 'width': 56, 'height': card_height})['selected_elements'][0]
        boxes = []
        for frame, name, material, width, depth, x in [(sheet, 'UMBRA / Clay folio', 'clay', 220, 160, -250),
                (card, 'UMBRA / Graphite card', 'graphite', 140, 100, 50)]:
            box = c.call('form_add_object', {'recipe_id': 'box', 'name': name, 'material_id': material,
                'parameters': {'width': width, 'depth': depth, 'height': 18}, 'position': [x, 0, 0]})
            c.call('form_link_artwork', {'object_id': box['id'], 'source_object_id': frame['id'], 'fit': 'actual'})
            boxes.append(box)
        package = pathlib.Path(status['library_path']) / (project['id'] + '.form')
        def resources():
            return {o['id']: o['file'] for o in json.loads((package / 'Manifest.json').read_text())['objects']}
        def export(id, fmt='png', suffix=''):
            name = 'umbra-sheet' if id == sheet['id'] else 'umbra-card'
            path = OUTPUT / (name + suffix + '.' + fmt)
            c.call('form_export_artwork', {'object_id': id, 'format': fmt, 'dpi': 150, 'path': str(path)})
            return path.read_bytes()
        original = [export(sheet['id']), export(card['id'])]
        files = resources(); before = c.call('form_get_project')
        c.call('form_appearance', {'object_id': source, 'element_ids': [group['id']], 'values': {'shadow': {'x': 6, 'y': 7}}})
        changed = resources()
        assert {id for id in files if files[id] != changed[id]} == {source}
        assert export(sheet['id'], suffix='-shadow-edit') != original[0]
        assert export(card['id'], suffix='-shadow-edit') != original[1]
        c.call('form_undo'); assert c.call('form_get_project') == before
        c.call('form_batch', {'operations': [
            {'name': 'form_appearance', 'arguments': {'object_id': source, 'element_ids': [group['id']], 'values': {'blur': {'radius': 2}}}},
            {'name': 'form_appearance', 'arguments': {'object_id': source, 'element_ids': [group['id']], 'values': {'blur': {'radius': -1}}}}]}, expect_error=True)
        assert c.call('form_get_project') == before
        for frame in [sheet, card]:
            for fmt in ['svg', 'pdf', 'png', 'jpeg']: export(frame['id'], fmt)
        svg = (OUTPUT / 'umbra-sheet.svg').read_text()
        assert 'feGaussianBlur' in svg and 'feDropShadow' in svg and 'mix-blend-mode:multiply' in svg
        # Multi-color typography conversion must preserve one complete appearance.
        c.call('form_swatch', {'command': 'assign', 'object_id': sheet['id'], 'element_ids': [title['id']],
            'target': 'text_range', 'location': 7, 'length': 6, 'swatch_id': ink}, expect_error=True)
        # The title has twelve characters; color the final word using a new swatch.
        accent = c.call('form_swatch', {'command': 'create', 'name': 'Vermilion', 'color': '#D45A37'})['swatch']['id']
        c.call('form_swatch', {'command': 'assign', 'object_id': sheet['id'], 'element_ids': [title['id']],
            'target': 'text_range', 'location': 7, 'length': 4, 'swatch_id': accent})
        c.call('form_appearance', {'object_id': sheet['id'], 'element_ids': [title['id']], 'values': {
            'shadow': {'x': 0.7, 'y': 1, 'blur': 0.4, 'opacity': 0.2}, 'opacity': 0.8}})
        colored = c.call('form_get_project'); export(sheet['id'], suffix='-type-before')
        result = c.call('form_convert_to_paths', {'object_id': sheet['id'], 'element_ids': [title['id']]})
        wrapper = next(e for e in result['elements'] if e['kind'] == 'group')
        assert wrapper['shadow']['blur'] == 0.4 and wrapper['opacity'] == 0.8
        assert len(result['selected_elements']) == 1
        export(sheet['id'], suffix='-type-outlined')
        c.call('form_undo'); assert c.call('form_get_project') == colored
        for _ in range(3): c.call('form_undo')
        assert c.call('form_get_project') == before
        # Repeated source edits fan out to one hundred independent effect instances.
        perf = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'Appearance performance',
            'parameters': {'width': 600, 'depth': 450}})
        elements = []
        for i in range(100):
            e = shape('group', 8 + i % 10 * 58, 8 + i // 10 * 42, 45, 32, '#263C64')
            e['contentSize'] = {'x': 1, 'y': 1}
            e['component'] = {'sourceObjectID': source}; elements.append(e)
        # Native instance content size is validated against the source on expansion.
        source_object = next(o for o in c.call('form_get_project')['objects'] if o['id'] == source)
        for e in elements: e['contentSize'] = {'x': source_object['parameters']['width'], 'y': source_object['parameters']['depth']}
        c.call('form_set_artwork', {'object_id': perf['id'], 'artwork': {'background': '#F4F0E7', 'bleed': 0, 'elements': elements}})
        c.call('form_set_view', {'view': 'artwork', 'object_id': perf['id']}); time.sleep(0.5)
        perf_files = resources(); timings = []
        for i in range(20):
            start = time.perf_counter()
            c.call('form_appearance', {'object_id': source, 'element_ids': [group['id']], 'values': {'shadow': {'x': 2 + (i + 1) * 0.1}}})
            timings.append((time.perf_counter() - start) * 1000)
            current = resources()
            assert all(current[id] == path for id, path in perf_files.items() if id != source)
        performance = c.call('form_status')
        c.call('form_appearance', {'object_id': source, 'element_ids': [group['id']], 'values': {'shadow': {'x': 2}}})
        c.call('form_delete_objects', {'object_ids': [perf['id']]})
        c.call('form_open_project', {'project_id': project['id']})
        assert c.call('form_get_project')['schemaVersion'] == 8
        c.call('form_set_view', {'view': 'artwork', 'object_id': boxes[0]['id'], 'element_ids': [instance]})
        report = dict(project_id=project['id'], frame_id=sheet['id'], card_id=card['id'], source_id=source,
            instance_id=instance, card_instance_id=second, hero_id=group['id'], blue_id=blue['id'],
            orange_id=orange['id'], glow_id=glow['id'], title_id=title['id'], box_ids=[o['id'] for o in boxes],
            ink_id=ink, saved_edit_median_ms=round(statistics.median(timings), 2),
            saved_edit_p95_ms=round(sorted(timings)[18], 2), performance_status=performance,
            checks='50 tools; live blur/shadow/blending; shared shadow swatch; source-only revisions; linked physical outputs; typography outlines; rollback; physical SVG/PDF/PNG/JPEG; schema-8 reopen; 100 effect placements',
            status=c.call('form_status'))
        (OUTPUT / 'appearance-report.json').write_text(json.dumps(report, indent=2))
        (OUTPUT / 'appearance-baseline.json').write_text(json.dumps(c.call('form_get_project'), indent=2))
        print(json.dumps(report, indent=2))
    finally:
        c.close()


if __name__ == '__main__':
    main()
