#!/usr/bin/env python3
"""Shared sRGB palette, component/typography paint, metadata-only saves and output.

Run against an isolated FORM_LIBRARY_PATH. No model or printer calls.
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
        c.discover(['form_swatch'])
        status = c.call('form_status'); assert '/.local/' in status['library_path']
        project = c.call('form_create_project', {'name': 'CHROMA · A shared palette'})
        colors = {}
        for name, color in [('Ink', '#263C64'), ('Accent', '#D45A37'), ('Sand', '#E4D8A9'),
                            ('Paper', '#F9F7F0'), ('Sage', '#849381'), ('Night', '#353B3C')]:
            colors[name] = c.call('form_swatch', {'command': 'create', 'name': name, 'color': color})['swatch']['id']
        assert len(c.call('form_swatch', {'command': 'list'})['swatches']) == 6
        sheet = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'CHROMA / Collection sheet',
            'parameters': {'width': 200, 'depth': 140}})
        title = text(14, 12, 172, 15, 'CHROMA / 003', 27, 'Collection title')
        title['typography']['tracking'] = 2.5
        subtitle = text(14, 31, 172, 8, 'ONE PALETTE / MANY EDITIONS', 9)
        outer = shape('ellipse', 20, 50, 55, 55, '#D45A37', 'Outer seal')
        opening = shape('ellipse', 27, 57, 41, 41, '#D45A37', 'Seal opening')
        opening['gradient'] = {'kind': 'linear', 'start': {'x': 0, 'y': 0}, 'end': {'x': 1, 'y': 1},
            'stops': [{'id': str(uuid.uuid4()).upper(), 'offset': 0, 'color': '#D45A37'},
                      {'id': str(uuid.uuid4()).upper(), 'offset': 1, 'color': '#E4D8A9'}]}
        dot = shape('ellipse', 43.5, 73.5, 8, 8, name='Seal center')
        label = text(20, 110, 65, 8, 'PALETTE / A', 11, 'Seal label')
        label['typography'].update(fontName='Menlo-Regular', tracking=1.5)
        headline = text(104, 54, 82, 36, 'SHARED COLOR.\nREAL THINGS.', 20.5)
        body = text(104, 99, 82, 18, 'A palette moves through\nevery surface.', 10)
        footer = text(104, 123, 82, 10, 'COLOR / A', 13, 'Outlined palette signature')
        rule = shape('line', 14, 132, 172, 0.1, name='Collection rule')
        rule.update(fillEnabled=False, stroke={'color': '#263C64', 'width': 0.4})
        all_elements = [title, subtitle, outer, opening, dot, label, headline, body, footer, rule]
        c.call('form_set_artwork', {'object_id': sheet['id'], 'artwork': {'background': '#F9F7F0', 'bleed': 0, 'elements': all_elements}})
        def bind(object_id, ids, name, target='fill', **extra):
            return c.call('form_swatch', dict(command='assign', object_id=object_id,
                element_ids=ids, swatch_id=colors[name], target=target, **extra))
        bind(sheet['id'], [e['id'] for e in [title, subtitle, dot, label, headline, body, footer]], 'Ink')
        bind(sheet['id'], [], 'Paper', 'background')
        bind(sheet['id'], [rule['id']], 'Ink', 'stroke')
        bind(sheet['id'], [footer['id']], 'Accent', 'text_range', location=8, length=1)
        outlined = c.call('form_convert_to_paths', {'object_id': sheet['id'], 'element_ids': [footer['id']]})
        assert {e['fillSwatchID'] for e in outlined['elements']} == {colors['Ink'], colors['Accent']}
        ring = c.call('form_boolean_artwork', {'object_id': sheet['id'],
            'element_ids': [outer['id'], opening['id']], 'operation': 'subtract'})['selected_elements'][0]
        stop_ids = [s['id'] for s in opening['gradient']['stops']]
        bind(sheet['id'], [ring], 'Accent', 'gradient_stop', stop_id=stop_ids[0])
        bind(sheet['id'], [ring], 'Sand', 'gradient_stop', stop_id=stop_ids[1])
        made = c.call('form_component', {'command': 'create', 'object_id': sheet['id'],
            'element_ids': [ring, dot['id'], label['id']], 'name': 'CHROMA / Shared seal'})
        source_id, instance = made['source_object_id'], made['selected_elements'][0]
        card = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'CHROMA / Edition card',
            'parameters': {'width': 120, 'depth': 80}})
        card_title = text(68, 16, 42, 25, 'CHROMA\nEDITION / B', 15)
        card_note = text(68, 53, 42, 15, 'ONE SHARED\nCOLOR SYSTEM.', 8)
        c.call('form_set_artwork', {'object_id': card['id'], 'artwork': {'background': '#F9F7F0', 'bleed': 0,
            'elements': [card_title, card_note]}})
        bind(card['id'], [card_title['id'], card_note['id']], 'Ink'); bind(card['id'], [], 'Paper', 'background')
        second = c.call('form_component', {'command': 'insert', 'object_id': card['id'], 'source_object_id': source_id,
            'x': 12, 'y': 12, 'width': 45, 'height': 47})['selected_elements'][0]
        bind(card['id'], [second], 'Accent')
        bind(card['id'], [second], 'Ink', 'component_part', part_id=dot['id'])
        boxes = []
        for frame, name, material, width, depth, x in [(sheet, 'CHROMA / Clay edition', 'clay', 220, 160, -250),
                (card, 'CHROMA / Chalk edition', 'chalk', 140, 100, 50)]:
            box = c.call('form_add_object', {'recipe_id': 'box', 'name': name, 'material_id': material,
                'parameters': {'width': width, 'depth': depth, 'height': 18}, 'position': [x, 0, 0]})
            c.call('form_link_artwork', {'object_id': box['id'], 'source_object_id': frame['id'], 'fit': 'actual'})
            boxes.append(box)
        package = pathlib.Path(status['library_path']) / (project['id'] + '.form')
        def resources():
            return {o['id']: o['file'] for o in json.loads((package / 'Manifest.json').read_text())['objects']}
        def export(id, fmt='png', suffix=''):
            name = 'chroma-sheet' if id == sheet['id'] else 'chroma-card'
            path = OUTPUT / (name + suffix + '.' + fmt)
            c.call('form_export_artwork', {'object_id': id, 'format': fmt, 'dpi': 150, 'path': str(path)})
            return path.read_bytes()
        files = resources(); old = [export(sheet['id']), export(card['id'])]
        objects = copy.deepcopy(c.call('form_get_project')['objects'])
        c.call('form_swatch', {'command': 'update', 'swatch_id': colors['Accent'], 'color': '#849381'})
        assert resources() == files and c.call('form_get_project')['objects'] == objects
        assert [export(sheet['id'], suffix='-sage'), export(card['id'], suffix='-sage')] != old
        assert export(sheet['id'], suffix='-sage') != old[0] and export(card['id'], suffix='-sage') != old[1]
        c.call('form_undo')
        for frame in [sheet, card]:
            for fmt in ['svg', 'pdf', 'png', 'jpeg']: export(frame['id'], fmt)
        assert struct.unpack('>II', (OUTPUT / 'chroma-sheet.png').read_bytes()[16:24]) == (1181, 827)
        before = c.call('form_get_project')
        c.call('form_swatch', {'command': 'delete', 'swatch_id': colors['Accent']})
        assert export(sheet['id'], suffix='-deleted') == old[0]
        assert export(card['id'], suffix='-deleted') == old[1]
        c.call('form_undo'); assert c.call('form_get_project')['objects'] == before['objects']
        c.call('form_batch', {'operations': [
            {'name': 'form_swatch', 'arguments': {'command': 'update', 'swatch_id': colors['Accent'], 'color': '#000000'}},
            {'name': 'form_swatch', 'arguments': {'command': 'assign', 'object_id': sheet['id'],
                'element_ids': [str(uuid.uuid4())], 'swatch_id': colors['Accent']}}]}, expect_error=True)
        assert c.call('form_get_project') == before
        c.call('form_open_project', {'project_id': project['id']})
        assert c.call('form_get_project')['schemaVersion'] == 7
        assert c.call('form_get_project')['objects'] == objects
        # Six hundred elements; one third reference Accent and the rest retain Ink.
        perf = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'Palette performance',
            'parameters': {'width': 600, 'depth': 500}})
        elements = []
        for i in range(300):
            x, y = 8 + (i % 15) * 39, 8 + (i // 15) * 24
            link = colors['Accent'] if i % 3 == 0 else colors['Ink']
            t = text(x, y, 36, 12, f'COLOR / {i:03}', 11); t['fillSwatchID'] = link
            circle = shape('ellipse', x, y + 12, 6, 6); circle['fillSwatchID'] = link
            elements += [t, circle]
        c.call('form_set_artwork', {'object_id': perf['id'], 'artwork': {'background': '#F9F7F0', 'bleed': 0, 'elements': elements}})
        c.call('form_set_view', {'view': 'artwork', 'object_id': perf['id']}); time.sleep(0.5)
        perf_files = resources(); times = []
        for i in range(20):
            start = time.perf_counter()
            c.call('form_swatch', {'command': 'update', 'swatch_id': colors['Accent'], 'color': f'#D4{90+i:02X}37'})
            times.append((time.perf_counter() - start) * 1000)
            assert resources() == perf_files
        perf_status = c.call('form_status')
        c.call('form_swatch', {'command': 'update', 'swatch_id': colors['Accent'], 'color': '#D45A37'})
        c.call('form_delete_objects', {'object_ids': [perf['id']]})
        c.call('form_set_view', {'view': 'artwork', 'object_id': boxes[0]['id'], 'element_ids': [instance]})
        report = dict(project_id=project['id'], frame_id=sheet['id'], card_id=card['id'], source_id=source_id,
            instance_id=instance, card_instance_id=second, title_id=title['id'], ring_id=ring,
            dot_id=dot['id'], rule_id=rule['id'], stop_ids=stop_ids, swatches=colors,
            outlined_ids=[e['id'] for e in outlined['elements']], box_ids=[o['id'] for o in boxes],
            benchmark_elements=600, palette_update_median_ms=round(statistics.median(times),2),
            palette_update_p95_ms=round(sorted(times)[18],2), performance_status=perf_status,
            checks='tool discovery; six sRGB swatches; fills/strokes/gradient stops/background/text spans; linked component overrides; linked glyph outlines; metadata-only updates; pixel-identical delete/undo; batch rollback; physical exports; schema-7 reopen; 600-element palette edits',
            status=c.call('form_status'))
        (OUTPUT / 'swatches-baseline.json').write_text(json.dumps(c.call('form_get_project'), indent=2))
        (OUTPUT / 'swatches-report.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2))
    finally:
        c.close()


if __name__ == '__main__':
    main()
