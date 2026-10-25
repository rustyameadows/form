#!/usr/bin/env python3
"""Image assets, crop/adjustments, physical DPI, replacement, output and saved edits.

Use an isolated running FORM_LIBRARY_PATH. Sources are rendered locally in FORM;
no external images, models, printer connections or print commands are involved.
"""
import copy
import hashlib
import json
import pathlib
import statistics
import time
import uuid
from smoke_mcp import Client, OUTPUT


def shape(kind, x, y, width, height, color='#263C64', name=None):
    return dict(id=str(uuid.uuid4()).upper(), kind=kind, x=x, y=y, width=width, height=height,
                color=color, text='', fontSize=14, name=name or kind.title())


def text(x, y, width, height, value, size, face='HelveticaNeue-Medium'):
    e = shape('text', x, y, width, height, name=value)
    e.update(text=value, fontSize=size, typography={'fontName': face})
    return e


def main():
    c = Client()
    try:
        status = c.call('form_status'); assert '/.local/' in status['library_path']
        assert len(c.rpc('tools/list')['tools']) == 50
        source = OUTPUT / 'image-light-source.png'; replacement = OUTPUT / 'image-light-replacement.png'
        c.call('form_create_project', {'name': 'LUMEN / Raster sources', 'template': 'lamps'})
        c.call('form_set_view', {'view': 'studio'}); c.call('form_set_view', {'view': 'fit'})
        c.call('form_export', {'format': 'png', 'path': str(source)})
        source_project = c.call('form_get_project')
        lamp = next(o for o in source_project['objects'] if o['recipeID'] == 'lamp')
        c.call('form_update_object', {'object_id': lamp['id'], 'material_id': 'clay'})
        c.call('form_export', {'format': 'png', 'path': str(replacement)})
        p = c.call('form_create_project', {'name': 'LUMEN · From scene to surface'})
        sheet = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'LUMEN / Made of light',
            'parameters': {'width': 200, 'depth': 240}})
        group = shape('group', 14, 66, 172, 118, name='Photographic window')
        group['contentSize'] = {'x': 172, 'y': 118}
        mask = shape('rectangle', 0, 0, 172, 118, name='Soft-corner image mask')
        mask.update(parentID=group['id'], cornerRadius=3)
        rule = shape('line', 14, 229, 172, 0.1); rule.update(fillEnabled=False, stroke={'color': '#263C64', 'width': .25})
        c.call('form_set_artwork', {'object_id': sheet['id'], 'artwork': {'background': '#F4F0E7', 'bleed': 0,
            'elements': [text(14, 12, 172, 28, 'Made of light.', 34, 'Georgia'),
                text(14, 47, 172, 8, 'LUMEN / OBJECT STUDIES 001', 8.5, 'Menlo-Regular'), group, mask,
                text(14, 197, 100, 28, 'Shape. Shade.\nA quieter glow.', 19, 'Georgia'),
                text(128, 198, 58, 24, 'Three forms.\nOne warm collection.\nDesigned in FORM.', 9), rule]}})
        made = c.call('form_import_image', {'object_id': sheet['id'], 'parent_id': group['id'],
            'path': str(source), 'x': 0, 'y': 0, 'width': 172, 'height': 118, 'name': 'LUMEN / Studio photograph'})
        image_id = made['selected_elements'][0]
        def art(id): return c.call('form_get_artwork', {'object_id': id})
        e = next(e for e in art(sheet['id'])['elements'] if e['id'] == image_id)
        e['clipID'] = mask['id']
        c.call('form_edit_artwork', {'object_id': sheet['id'], 'command': 'replace', 'elements': [e]})
        crop = {'x': .16, 'y': .10, 'width': (172 / 118 / 1.5) * .8, 'height': .8}
        c.call('form_edit_image', {'object_id': sheet['id'], 'element_ids': [image_id], 'crop': crop,
            'adjustments': {'saturation': .82, 'contrast': 1.05, 'brightness': .015}})
        c.call('form_appearance', {'object_id': sheet['id'], 'element_ids': [group['id']],
            'values': {'shadow': {'x': 0, 'y': 2, 'blur': 1.4, 'opacity': .16}}})
        card = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'LUMEN / Edition card',
            'parameters': {'width': 120, 'depth': 80}})
        circle = shape('ellipse', 10, 18, 52, 52, name='Circular photograph mask')
        c.call('form_set_artwork', {'object_id': card['id'], 'artwork': {'background': '#EEE9DD', 'bleed': 0,
            'elements': [text(10, 5, 100, 9, 'FORM / LUMEN', 10, 'Menlo-Regular'), circle,
                text(69, 22, 42, 40, 'Small\nmoments.\nSoft light.', 17, 'Georgia'),
                text(10, 73, 100, 5, 'A COLLECTION IN LIGHT / 001', 6.5, 'Menlo-Regular')]}})
        second = c.call('form_import_image', {'object_id': card['id'], 'path': str(source),
            'x': 10, 'y': 18, 'width': 52, 'height': 52})['selected_elements'][0]
        e = next(e for e in art(card['id'])['elements'] if e['id'] == second); e['clipID'] = circle['id']
        c.call('form_edit_artwork', {'object_id': card['id'], 'command': 'replace', 'elements': [e]})
        c.call('form_edit_image', {'object_id': card['id'], 'element_ids': [second],
            'crop': {'x': .30, 'y': .15, 'width': .5, 'height': .75}, 'adjustments': {'saturation': 0}})
        boxes = []
        for frame, name, material, width, depth, x in [(sheet, 'LUMEN / Clay folio', 'clay', 220, 260, -250),
                (card, 'LUMEN / Graphite card', 'graphite', 140, 100, 90)]:
            box = c.call('form_add_object', {'recipe_id': 'box', 'name': name, 'material_id': material,
                'parameters': {'width': width, 'depth': depth, 'height': 18}, 'position': [x, 0, 0]})
            c.call('form_link_artwork', {'object_id': box['id'], 'source_object_id': frame['id'], 'fit': 'fit'})
            boxes.append(box)
        package = pathlib.Path(status['library_path']) / (p['id'] + '.form')
        assets = package / 'Assets'
        def hashes(): return {f.name: hashlib.sha256(f.read_bytes()).hexdigest() for f in assets.iterdir()}
        original_hashes = hashes()
        assert all(value == hashlib.sha256(source.read_bytes()).hexdigest() for value in original_hashes.values())
        raw = c.call('form_image_info', {'object_id': sheet['id']})['images'][0]
        physical = c.call('form_image_info', {'object_id': boxes[0]['id']})['images'][0]
        assert raw['original']['width'] == 3000 and raw['original']['height'] == 2000
        factor = min(220 / 200, 260 / 240)
        assert abs(raw['effective_dpi'] / factor - physical['effective_dpi']) < 1e-6
        def export(id, fmt='png', suffix=''):
            name = 'lumen-sheet' if id == sheet['id'] else 'lumen-card'
            path = OUTPUT / (name + suffix + '.' + fmt)
            c.call('form_export_artwork', {'object_id': id, 'format': fmt, 'dpi': 150, 'path': str(path)})
            return path.read_bytes()
        before = c.call('form_get_project'); original = export(sheet['id'])
        resources = {o['id']: o['file'] for o in json.loads((package / 'Manifest.json').read_text())['objects']}
        c.call('form_edit_image', {'object_id': boxes[0]['id'], 'element_ids': [image_id], 'crop': {'x': .20}})
        after = {o['id']: o['file'] for o in json.loads((package / 'Manifest.json').read_text())['objects']}
        assert {id for id in resources if resources[id] != after[id]} == {sheet['id']}
        assert export(sheet['id'], suffix='-cropped') != original; assert hashes() == original_hashes
        c.call('form_undo'); assert c.call('form_get_project') == before
        old = next(e for e in art(sheet['id'])['elements'] if e['id'] == image_id)
        c.call('form_import_image', {'object_id': sheet['id'], 'element_id': image_id, 'path': str(replacement)})
        new = next(e for e in art(sheet['id'])['elements'] if e['id'] == image_id)
        assert {k: v for k, v in old.items() if k not in ['asset', 'imageCrop']} == {k: v for k, v in new.items() if k not in ['asset', 'imageCrop']}
        assert (assets / old['asset']).read_bytes() == source.read_bytes()
        assert (assets / new['asset']).read_bytes() == replacement.read_bytes()
        assert export(sheet['id'], suffix='-replaced') != original
        c.call('form_undo'); assert c.call('form_get_project') == before
        owned = c.call('form_import_image', {'object_id': card['id'], 'path': str(assets / old['asset']),
            'x': 60, 'y': 40, 'width': 40, 'anchor': 'center'})
        placed = next(e for e in art(card['id'])['elements'] if e['id'] == owned['selected_elements'][0])
        assert placed['asset'] == old['asset'] and placed['name'].endswith(' copy')
        assert abs(placed['x'] - 40) < 1e-9 and abs(placed['y'] - (40 - 40 / 1.5 / 2)) < 1e-9
        c.call('form_undo'); assert c.call('form_get_project') == before
        saved_files = hashes()
        c.call('form_import_image', {'object_id': sheet['id'], 'element_id': str(uuid.uuid4()), 'path': str(source)}, expect_error=True)
        assert hashes() == saved_files and c.call('form_get_project') == before
        c.call('form_batch', {'operations': [
            {'name': 'form_edit_image', 'arguments': {'object_id': sheet['id'], 'element_ids': [image_id], 'adjustments': {'saturation': 0}}},
            {'name': 'form_edit_image', 'arguments': {'object_id': sheet['id'], 'element_ids': [image_id], 'crop': {'x': .99}}}]}, expect_error=True)
        assert c.call('form_get_project') == before
        for frame in [sheet, card]:
            for fmt in ['svg', 'pdf', 'png', 'jpeg']: export(frame['id'], fmt)
        svg = (OUTPUT / 'lumen-sheet.svg').read_text()
        assert 'feColorMatrix type="matrix"' in svg and 'data:image/png;base64,' in svg
        perf = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'Image performance', 'parameters': {'width': 600, 'depth': 450}})
        tiles = []
        for i in range(100):
            e = shape('image', 8 + i % 10 * 58, 8 + i // 10 * 42, 46, 32)
            e.update(asset=old['asset'], imageCrop={'x': .1, 'y': .1, 'width': .7, 'height': .7},
                imageAdjustments={'saturation': .82, 'contrast': 1.05, 'brightness': .015})
            tiles.append(e)
        c.call('form_set_artwork', {'object_id': perf['id'], 'artwork': {'background': '#F4F0E7', 'bleed': 0, 'elements': tiles}})
        c.call('form_set_view', {'view': 'artwork', 'object_id': perf['id']}); time.sleep(.5)
        timings = []
        for i in range(20):
            start = time.perf_counter()
            c.call('form_edit_image', {'object_id': perf['id'], 'element_ids': [e['id'] for e in tiles], 'crop': {'x': .1 + (i + 1) * .005}})
            timings.append((time.perf_counter() - start) * 1000)
        performance = c.call('form_status')
        assert all(hashes()[name] == digest for name, digest in original_hashes.items())
        c.call('form_delete_objects', {'object_ids': [perf['id']]})
        c.call('form_open_project', {'project_id': p['id']})
        assert c.call('form_get_project')['schemaVersion'] == 9
        c.call('form_set_view', {'view': 'artwork', 'object_id': boxes[0]['id'], 'element_ids': [image_id]})
        report = dict(project_id=p['id'], frame_id=sheet['id'], card_id=card['id'], image_id=image_id,
            card_image_id=second, group_id=group['id'], mask_id=mask['id'], box_ids=[o['id'] for o in boxes],
            source_asset=old['asset'], source_path=str(source), replacement_path=str(replacement),
            raw_info=raw, physical_info=physical, saved_edit_median_ms=round(statistics.median(timings), 2),
            saved_edit_p95_ms=round(sorted(timings)[18], 2), performance_status=performance,
            checks='50 tools; original asset bytes; live crop/adjustments; physical DPI; clipping; replacement preserves layout; source-only persistence; invalid import and batch rollback; physical exports; schema-9 reopen; 100 image saved edits')
        (OUTPUT / 'images-report.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2))
    finally:
        c.close()


if __name__ == '__main__':
    main()
