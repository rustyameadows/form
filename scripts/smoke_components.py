#!/usr/bin/env python3
"""Reusable artwork, overrides, physical faces, persistence and saved-edit samples.

Run only against an isolated FORM_LIBRARY_PATH. No external models or hardware.
"""
import copy
import json
import pathlib
import statistics
import struct
import time
import uuid
from smoke_mcp import Client, OUTPUT


def shape(kind, x, y, w, h, color='#263C64', name=None):
    return dict(id=str(uuid.uuid4()).upper(), kind=kind, x=x, y=y, width=w, height=h,
                text='', color=color, fontSize=14, name=name or kind.title())


def text(x, y, w, h, value, size=12, name=None):
    e = shape('text', x, y, w, h, name=name)
    e.update(text=value, fontSize=size, typography={'fontName': 'HelveticaNeue-Medium'})
    return e


def main():
    c = Client()
    try:
        c.discover(['form_component', 'form_get_artwork'])
        status = c.call('form_status')
        assert '/.local/' in status['library_path'], 'Use an isolated validation library.'
        p = c.call('form_create_project', {'name': 'STRATA · Shared identity system'})
        sheet = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'STRATA / Field kit',
            'parameters': {'width': 200, 'depth': 140}})
        outer = shape('ellipse', 24, 52, 48, 48, '#D45A37', 'Outer orbit')
        opening = shape('ellipse', 30, 58, 36, 36, '#D45A37', 'Orbit opening')
        opening['gradient'] = {'kind': 'linear', 'start': {'x': 0, 'y': 0}, 'end': {'x': 1, 'y': 1},
            'stops': [{'id': str(uuid.uuid4()), 'offset': 0, 'color': '#D45A37'},
                      {'id': str(uuid.uuid4()), 'offset': 1, 'color': '#E4D8A9'}]}
        dot = shape('ellipse', 43, 71, 10, 10, '#263C64', 'Center point')
        label = text(24, 106, 60, 8, 'FIELD / 01', 12, 'Edition label')
        label['typography'].update(fontName='Menlo-Regular', tracking=1.5)
        title = text(14, 12, 175, 14, 'S T R A T A', 28, 'Studio wordmark')
        subtitle = text(14, 31, 175, 8, 'FIELD EQUIPMENT / COLLECTION 001', 9)
        note = text(110, 56, 76, 40, 'ONE MARK.\nMANY PLACES.', 22)
        footer = text(110, 105, 76, 15, 'A linked identity,\nmade to be your own.', 10)
        c.call('form_set_artwork', {'object_id': sheet['id'], 'artwork': {'background': '#F9F7F0', 'bleed': 0,
            'elements': [title, subtitle, outer, opening, dot, label, note, footer]}})
        ring = c.call('form_boolean_artwork', {'object_id': sheet['id'],
            'element_ids': [outer['id'], opening['id']], 'operation': 'subtract'})['selected_elements'][0]
        created = c.call('form_component', {'command': 'create', 'object_id': sheet['id'],
            'element_ids': [ring, dot['id'], label['id']], 'name': 'STRATA / Field emblem'})
        source_id = created['source_object_id']; first = created['selected_elements'][0]
        source_art = c.call('form_get_artwork', {'object_id': source_id})
        card = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'STRATA / Instrument card',
            'parameters': {'width': 120, 'depth': 80}})
        c.call('form_set_artwork', {'object_id': card['id'], 'artwork': {'background': '#E8EBE3', 'bleed': 0,
            'elements': [text(68, 15, 42, 25, 'STRATA\nFIELD KIT', 16),
                         text(68, 50, 42, 20, '02 / INSTRUMENTS\nA modular collection.', 8)]}})
        second = c.call('form_component', {'command': 'insert', 'object_id': card['id'],
            'source_object_id': source_id, 'x': 12, 'y': 12, 'width': 45, 'height': 46.5})['selected_elements'][0]
        c.call('form_component', {'command': 'override', 'object_id': card['id'], 'element_ids': [second],
            'color': '#263C64', 'overrides': [{'elementID': label['id'], 'text': 'FIELD / 02'},
                                           {'elementID': dot['id'], 'color': '#D45A37'}]})
        boxes = []
        for frame, name, material, width, depth, x in [(sheet, 'STRATA / Clay edition', 'clay', 220, 160, -250),
                (card, 'STRATA / Sage edition', 'sage', 140, 100, 50)]:
            box = c.call('form_add_object', {'recipe_id': 'box', 'name': name, 'material_id': material,
                'parameters': {'width': width, 'depth': depth, 'height': 18}, 'position': [x, 0, 0]})
            c.call('form_link_artwork', {'object_id': box['id'], 'source_object_id': frame['id'], 'fit': 'actual'})
            boxes.append(box)
        assert len(c.call('form_component', {'command': 'list'})['components']) == 1
        def art(id, resolved=False):
            return c.call('form_get_artwork', {'object_id': id, 'resolved': resolved})
        def export(id, fmt='png', suffix=''):
            filename = 'strata-kit' if id in (sheet['id'], boxes[0]['id']) else 'strata-card'
            path = OUTPUT / (filename + suffix + '.' + fmt)
            c.call('form_export_artwork', {'object_id': id, 'format': fmt, 'path': str(path), 'dpi': 150})
            return path.read_bytes()
        raw = art(card['id']); resolved = art(card['id'], True)
        assert len(resolved['elements']) > len(raw['elements'])
        assert next(e for e in resolved['elements'] if e.get('name') == 'Edition label')['text'] == 'FIELD / 02'
        assert next(e for e in resolved['elements'] if e.get('name') == 'Center point')['color'] == '#D45A37'
        baseline = c.call('form_get_project')
        package = pathlib.Path(status['library_path']) / (p['id'] + '.form')
        def resources():
            return {o['id']: o['file'] for o in json.loads((package / 'Manifest.json').read_text())['objects']}
        files = resources(); old = export(sheet['id'])
        changed = copy.deepcopy(next(e for e in source_art['elements'] if e['id'] == dot['id']))
        changed['width'] = 14
        c.call('form_edit_artwork', {'object_id': source_id, 'command': 'replace', 'elements': [changed]})
        assert export(sheet['id'], suffix='-edited') != old
        after = resources()
        assert after[source_id] != files[source_id]
        assert all(after[id] == files[id] for id in files if id != source_id)
        assert art(card['id']) == raw
        assert next(e for e in art(card['id'], True)['elements'] if e.get('name') == 'Center point')['width'] == 14
        c.call('form_undo'); assert art(source_id) == source_art
        before_detach = export(card['id'])
        c.call('form_component', {'command': 'detach', 'object_id': card['id'], 'element_ids': [second]})
        assert export(card['id'], suffix='-detached') == before_detach
        assert not any(e.get('component') for e in art(card['id'])['elements'])
        c.call('form_edit_artwork', {'object_id': source_id, 'command': 'replace', 'elements': [changed]})
        assert export(card['id'], suffix='-independent') == before_detach
        c.call('form_undo'); c.call('form_undo'); assert art(card['id']) == raw
        before = c.call('form_get_project')
        c.call('form_component', {'command': 'insert', 'object_id': source_id, 'source_object_id': source_id}, expect_error=True)
        assert c.call('form_get_project') == before
        c.call('form_batch', {'operations': [
            {'name': 'form_component', 'arguments': {'command': 'reset', 'object_id': card['id'], 'element_ids': [second]}},
            {'name': 'form_update_object', 'arguments': {'object_id': card['id'], 'parameters': {'width': -1}}}]}, expect_error=True)
        assert c.call('form_get_project') == before
        for frame in [sheet, card]:
            for fmt in ['svg', 'pdf', 'png', 'jpeg']: export(frame['id'], fmt)
        assert struct.unpack('>II', (OUTPUT / 'strata-kit.png').read_bytes()[16:24]) == (1181, 827)
        c.call('form_open_project', {'project_id': p['id']})
        assert c.call('form_get_project')['schemaVersion'] == 6
        assert art(card['id']) == raw and art(source_id) == source_art
        # Two hundred placements share one source; edits include real saves and transport.
        perf = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'Component performance',
            'parameters': {'width': 400, 'depth': 300}})
        for batch in range(2):
            c.call('form_batch', {'operations': [{'name': 'form_component', 'arguments': {
                'command': 'insert', 'object_id': perf['id'], 'source_object_id': source_id,
                'x': (i % 20) * 19, 'y': (i // 20) * 28, 'width': 16, 'height': 16.5}}
                for i in range(batch * 100, (batch + 1) * 100)]})
        c.call('form_set_view', {'view': 'artwork', 'object_id': perf['id']})
        times = []
        for i in range(20):
            changed['width'] = 10 + (i + 1) * 0.01
            start = time.perf_counter()
            c.call('form_edit_artwork', {'object_id': source_id, 'command': 'replace', 'elements': [changed]})
            times.append((time.perf_counter() - start) * 1000)
        changed['width'] = 10
        c.call('form_edit_artwork', {'object_id': source_id, 'command': 'replace', 'elements': [changed]})
        assert art(source_id) == source_art
        performance_status = c.call('form_status')
        c.call('form_delete_objects', {'object_ids': [perf['id']]})
        c.call('form_set_view', {'view': 'artwork', 'object_id': boxes[0]['id'], 'element_ids': [first]})
        report = dict(project_id=p['id'], frame_id=sheet['id'], card_id=card['id'], source_id=source_id,
            instance_id=first, card_instance_id=second, outer_id=outer['id'], dot_id=dot['id'], label_id=label['id'],
            box_ids=[b['id'] for b in boxes], benchmark_instances=200,
            saved_source_edit_median_ms=round(statistics.median(times), 2),
            saved_source_edit_p95_ms=round(sorted(times)[18], 2),
            checks='tool discovery; shared sources; size/color/text overrides; source-only resources; actual physical exports; detach equality and independence; atomic cycle/batch rejection; schema-6 reopen; 200-instance saved source edits',
            performance_status=performance_status, status=c.call('form_status'))
        (OUTPUT / 'components-baseline.json').write_text(json.dumps(c.call('form_get_project'), indent=2))
        (OUTPUT / 'components-report.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2))
    finally:
        c.close()


if __name__ == '__main__':
    main()
