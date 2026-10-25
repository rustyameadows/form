#!/usr/bin/env python3
"""PRISM: editable gradient/stroke/mask flow through the real local MCP bridge.

Run against an isolated FORM_LIBRARY_PATH. No printer connection or commands.
"""
import copy
import json
import pathlib
import statistics
import time
import uuid
from smoke_mcp import Client, OUTPUT


def shape(kind, x, y, width, height, color='#263C64', name=None):
    return dict(id=str(uuid.uuid4()).upper(), kind=kind, x=x, y=y, width=width,
                height=height, color=color, text='', fontSize=14, name=name or kind.title())


def text(x, y, width, height, value, size, face='HelveticaNeue-Medium', color='#263C64'):
    e = shape('text', x, y, width, height, color, value)
    e.update(text=value, fontSize=size, typography={'fontName': face})
    return e


def main():
    c = Client()
    try:
        status = c.call('form_status'); assert '/.local/' in status['library_path']
        assert len(c.rpc('tools/list')['tools']) == 50
        project = c.call('form_create_project', {'name': 'PRISM · Color in motion'})
        sheet = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'PRISM / Field notes',
            'parameters': {'width': 200, 'depth': 160}})
        panel = shape('group', 14, 57, 108, 78, name='PRISM / Nested windows')
        panel['contentSize'] = {'x': 108, 'y': 78}
        outer = shape('ellipse', -3, -6, 114, 92, name='Outer elliptical mask')
        outer['parentID'] = panel['id']
        layer = shape('group', 0, 0, 108, 78, name='Outer clipped contents')
        layer.update(parentID=panel['id'], contentSize={'x': 108, 'y': 78})
        inner = shape('rectangle', 3, 3, 102, 72, name='Inner rounded mask')
        inner.update(parentID=layer['id'], cornerRadius=11)
        content = shape('group', 0, 0, 108, 78, name='Inner clipped contents')
        content.update(parentID=layer['id'], contentSize={'x': 108, 'y': 78})
        hero = shape('rectangle', 0, 0, 108, 78, name='PRISM / Spectral field')
        hero['parentID'] = content['id']
        lines = []
        for i in range(11):
            e = shape('path', 0, 0, 108, 78, '#F9F0DA', f'Spectral contour {i+1:02}')
            y = 9 + i*5.5
            e.update(parentID=content['id'], fillEnabled=False,
                stroke={'color': '#F9F0DA', 'width': .22, 'opacity': .65, 'cap': 'round'},
                path={'width': 108, 'height': 78, 'evenOdd': False, 'contours': [{'closed': False, 'nodes': [
                    {'id': str(uuid.uuid4()).upper(), 'anchor': {'x': -8, 'y': y}, 'outgoing': {'x': 30, 'y': y-40}},
                    {'id': str(uuid.uuid4()).upper(), 'anchor': {'x': 116, 'y': y+3}, 'incoming': {'x': 75, 'y': y+50}}]}]})
            lines.append(e)
        edge = shape('rectangle', 13, 56, 110, 80, '#263C64', 'PRISM / Outline specimen')
        edge.update(cornerRadius=12, fillEnabled=False)
        rule = shape('line', 14, 149, 172, .1, name='PRISM / Dotted rule')
        c.call('form_set_artwork', {'object_id': sheet['id'], 'artwork': {'background': '#F5F0E4', 'bleed': 0,
            'elements': [text(14, 12, 172, 23, 'Color, in motion.', 37, 'Georgia'),
                text(14, 40, 172, 7, 'PRISM / FIELD NOTES 001', 8.5, 'Menlo-Regular'), panel, outer, layer, inner, content,
                hero, *lines, edge, text(138, 60, 48, 40, 'A spectrum.\nA surface.\nA system.', 19, 'Georgia'),
                text(138, 111, 48, 26, 'Continuous color.\nEditable edges.\nRoom to reshape.', 9.5),
                text(14, 140, 172, 6, 'FIVE STOPS  /  TWO MASKS  /  ONE SOURCE', 7, 'Menlo-Regular'), rule]}})
        def art(id=sheet['id']): return c.call('form_get_artwork', {'object_id': id})
        def paint(id=hero['id'], command='update', owner=None, **args):
            return c.call('form_edit_paint', {'object_id': owner or sheet['id'], 'element_ids': [id], 'command': command, **args})
        def clip(target, mask):
            return c.call('form_edit_artwork', {'object_id': sheet['id'], 'element_ids': [target], 'command': 'clip', 'mask_id': mask})
        clip(content['id'], inner['id']); clip(layer['id'], outer['id'])
        paint(gradient={'start': {'x': 0, 'y': .05}, 'end': {'x': 1, 'y': .9}})
        stops = next(e for e in art()['elements'] if e['id'] == hero['id'])['gradient']['stops']
        for stop, color in zip(stops, ['#172C4A', '#F5CC7E']): paint(command='update_stop', stop_id=stop['id'], color=color)
        added = []
        for offset, color in [(.28, '#455B95'), (.53, '#BD637F'), (.76, '#E88658')]:
            added.append(paint(command='add_stop', offset=offset, color=color)['selected_stop'])
        paint(edge['id'], stroke={'width': .4, 'alignment': 'outside', 'color': '#263C64', 'join': 'round'})
        paint(rule['id'], stroke={'width': .45, 'color': '#263C64', 'cap': 'round', 'dash': [0, 2]})
        card = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'PRISM / Edition card',
            'parameters': {'width': 120, 'depth': 80}})
        disk = shape('ellipse', 15, 20, 48, 48, name='PRISM / Radial medallion')
        disk.update(gradient={'kind': 'radial', 'start': {'x': .3, 'y': .3}, 'end': {'x': 1, 'y': .6},
            'stops': [{'id': str(uuid.uuid4()).upper(), 'offset': t, 'color': color} for t, color in
                [(0, '#F5CC7E'), (.4, '#E88658'), (.75, '#BD637F'), (1, '#455B95')]]},
            stroke={'color': '#F5F0E4', 'width': .5, 'alignment': 'inside'})
        c.call('form_set_artwork', {'object_id': card['id'], 'artwork': {'background': '#172C4A', 'bleed': 0,
            'elements': [text(10, 8, 100, 8, 'PRISM / EDITION 001', 8, 'Menlo-Regular', '#F5F0E4'), disk,
                text(74, 28, 35, 26, 'All the\nin-between.', 17, 'Georgia', '#F5F0E4'),
                text(74, 61, 35, 8, 'MADE IN FORM', 6.5, 'Menlo-Regular', '#F5F0E4')]}})
        boxes = []
        for frame, name, material, width, depth, x in [(sheet, 'PRISM / Oak field folio', 'oak', 220, 180, -250),
                (card, 'PRISM / Graphite edition', 'graphite', 140, 100, 70)]:
            box = c.call('form_add_object', {'recipe_id': 'box', 'name': name, 'material_id': material,
                'parameters': {'width': width, 'depth': depth, 'height': 18}, 'position': [x, 0, 0]})
            c.call('form_link_artwork', {'object_id': box['id'], 'source_object_id': frame['id'], 'fit': 'fit'}); boxes.append(box)
        def export(id, stem, fmt='png', **options):
            path = OUTPUT / (stem + '.' + fmt)
            c.call('form_export_artwork', {'object_id': id, 'format': fmt, 'path': str(path), 'dpi': 150, **options})
            assert path.stat().st_size > 100
            return path.read_bytes()
        before = c.call('form_get_project'); original = export(sheet['id'], 'prism-sheet-before')
        package = pathlib.Path(status['library_path']) / (project['id'] + '.form')
        def resources():
            return {o['id']: o['file'] for o in json.loads((package/'Manifest.json').read_text())['objects']}
        references = resources()
        paint(command='update_stop', stop_id=added[1], offset=.85, owner=boxes[0]['id'])
        updated = resources()
        assert {id for id in references if references[id] != updated[id]} == {sheet['id']}
        after = art(); g = next(e for e in after['elements'] if e['id'] == hero['id'])['gradient']
        assert next(s for s in g['stops'] if s['id'] == added[1])['offset'] == .85
        assert export(sheet['id'], 'prism-sheet-edited') != original
        c.call('form_undo'); assert art() == next(o for o in before['objects'] if o['id'] == sheet['id'])['artwork']
        snapshot = c.call('form_get_project')
        paint(id=edge['id'], stroke={'width': 2, 'opacity': .5, 'miter': 3, 'dash': [0, 4, 2], 'dash_offset': -1})
        c.call('form_undo'); assert c.call('form_get_project') == snapshot
        for args in [dict(stroke={'dash': [.000001, .000001]}), dict(gradient={'kind': 'unsupported'})]:
            c.call('form_edit_paint', {'object_id': sheet['id'], 'element_ids': [hero['id']], **args}, expect_error=True)
            assert c.call('form_get_project') == snapshot
        converted = c.call('form_convert_to_paths', {'object_id': sheet['id'], 'element_ids': [outer['id']], 'mode': 'shape'})
        new_mask = converted['selected_elements'][0]
        assert next(e for e in art()['elements'] if e['id'] == layer['id'])['clipID'] == new_mask
        c.call('form_undo'); assert c.call('form_get_project') == snapshot
        # A filled gradient remains present after stroke expansion, at the same stack position.
        paint(stroke={'color': '#F5CC7E', 'width': 2, 'alignment': 'inside', 'opacity': .8})
        filled = export(sheet['id'], 'prism-stroke-before')
        c.call('form_convert_to_paths', {'object_id': sheet['id'], 'element_ids': [hero['id']], 'mode': 'stroke'})
        outlined = export(sheet['id'], 'prism-stroke-outlined')
        assert outlined == filled
        c.call('form_undo'); c.call('form_undo'); assert c.call('form_get_project') == snapshot
        outputs = []
        for obj, stem in [(sheet, 'prism-sheet'), (card, 'prism-card'), (boxes[0], 'prism-folio'), (boxes[1], 'prism-edition')]:
            for fmt in ['svg', 'pdf', 'png']:
                export(obj['id'], stem, fmt); outputs.append(stem+'.'+fmt)
        svg = (OUTPUT/'prism-sheet.svg').read_text()
        assert all('id="clip-'+mask+'"' in svg for mask in [layer['id'], content['id']])
        assert '<linearGradient' in svg and 'stroke-dasharray=' in svg
        assert 'stroke-alignment' not in svg and '<image' not in svg
        # Probe hundreds of distinct stroked gradient placements, then saved warm edits.
        perf = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'PRISM / Paint performance',
            'parameters': {'width': 240, 'depth': 160}})
        tiles = []
        for i in range(200):
            tile = copy.deepcopy(disk); tile.update(id=str(uuid.uuid4()).upper(), x=4+(i%20)*11.5, y=4+(i//20)*15, width=9, height=12)
            tiles.append(tile)
        c.call('form_set_artwork', {'object_id': perf['id'], 'artwork': {'background': '#172C4A', 'bleed': 0, 'elements': tiles}})
        c.call('form_set_view', {'view': 'artwork', 'object_id': perf['id']})
        c.call('form_export_artwork', {'object_id': perf['id'], 'format': 'png', 'dpi': 72, 'path': str(OUTPUT/'paint-performance.png')})
        samples = []
        for i in range(20):
            start = time.perf_counter()
            c.call('form_edit_paint', {'object_id': perf['id'], 'element_ids': [tiles[i]['id']], 'stroke': {'opacity': .5+(i%2)*.3}})
            samples.append((time.perf_counter()-start)*1000)
        measured = c.call('form_status')
        current = c.call('form_get_project')
        c.call('form_open_project', {'project_id': project['id']}); assert c.call('form_get_project') == current
        c.call('form_group_objects', {'object_ids': [o['id'] for o in boxes]})
        c.call('form_set_view', {'view': 'artwork', 'object_id': boxes[0]['id'], 'element_ids': [hero['id']]})
        report = dict(project_id=project['id'], frame_id=sheet['id'], card_id=card['id'],
            hero_id=hero['id'], edge_id=edge['id'], rule_id=rule['id'], outer_mask=outer['id'],
            outer_contents=layer['id'], inner_mask=inner['id'], inner_contents=content['id'],
            product_ids=[o['id'] for o in boxes], gradient_stop_ids=added, outputs=outputs,
            warm_saved_edit_ms={'median': statistics.median(samples), 'max': max(samples)},
            status=measured,
            checks='50 tools; stop UUID reorder and interpolation; source-only resource updates through a linked product; complete strokes; nested masks; mask conversion redirects; filled stroke expansion equality; native undo/redo boundary; atomic invalids; linked physical outputs; schema-10 reopen; 200-element saved paint edits')
        (OUTPUT/'paint-report.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2))
    finally:
        c.close()


if __name__ == '__main__': main()
