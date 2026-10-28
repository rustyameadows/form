#!/usr/bin/env python3
"""Actual packaged font library/replacement flow in a disposable .local library."""
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
        library = pathlib.Path(c.call('form_status')['library_path']).resolve()
        assert library.is_relative_to((ROOT / '.local').resolve()), 'Use a disposable .local library.'
        c.discover(['form_list_fonts', 'form_replace_font', 'form_edit_artwork', 'form_story'])
        first = c.call('form_list_fonts', {'command': 'faces', 'limit': 2})
        second = c.call('form_list_fonts', {'command': 'faces', 'limit': 2, 'offset': 2})
        assert first['total'] > 100 and not ({f['id'] for f in first['faces']} & {f['id'] for f in second['faces']})
        target = c.call('form_list_fonts', {'command': 'faces', 'query': 'Georgia'})
        assert any(f['name'] == 'Georgia' for f in target['faces'])
        c.call('form_list_fonts', {'limit': True}, expect_error=True)
        project = c.call('form_create_project', {'name': 'FOUNDRY / Font library', 'template': 'fieldGuide'})
        story_id = project['textStories'][0]['id']; linked = project['textStories'][0]['frames'][0]
        missing = 'FORM Missing Face Validation'
        def text(value, y, name, size=16):
            return dict(id=str(uuid.uuid4()).upper(), kind='text', x=12, y=y, width=156, height=30,
                        text=value, color='#243C35', fontSize=size,
                        typography=dict(fontName=name, kerningMode='metrics'))
        sheet = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'Font assignment study', 'parameters': {'width': 180, 'depth': 230}})
        body = text('A😀B / Original words and explicit settings.', 54, missing, 18)
        body['typography'].update(features={'21': 0}, variations={'2003265652': 1.3})
        body['textRuns'] = [dict(location=8, length=8, typography=copy.deepcopy(body['typography']), fontSize=20, color='#A55A36')]
        glyph_text = text('Q / A recorded alternate stays explicit.', 142, 'HoeflerText-Regular', 22)
        elements = [text('FORM / FONT LIBRARY', 12, 'Menlo-Regular', 9),
                    text('A deliberate replacement', 26, 'Baskerville', 25), body,
                    text('One original source. Preserved words, axes and features.', 94, 'Georgia', 11),
                    glyph_text, text('180 × 230 MM / NATIVE FONT STUDY', 212, 'Menlo-Regular', 8)]
        c.call('form_set_artwork', {'object_id': sheet['id'], 'artwork': {'background': '#F5F1E6', 'bleed': 0, 'elements': elements}})
        c.call('form_edit_artwork', {'object_id': linked['objectID'], 'element_ids': [linked['elementID']],
                                   'command': 'font', 'font_name': missing})
        c.call('form_edit_artwork', {'object_id': linked['objectID'], 'element_ids': [linked['elementID']],
                                   'command': 'list', 'marker_font': missing})
        c.call('form_text_style', {'command': 'create', 'name': 'Missing-face style', 'font_size': 12,
                                  'typography': {'fontName': missing, 'features': {'21': 0}}})
        def get(): return c.call('form_get_project')
        def source(): return c.call('form_story', {'command': 'get', 'story_id': story_id})['story']
        package = library / (project['id'] + '.form')
        def refs(): return {o['id']: o['file'] for o in json.loads((package / 'Manifest.json').read_text())['objects']}
        usage = c.call('form_list_fonts', {'command': 'usage'})
        missing_entry = next(f for f in usage['fonts'] if f['font_name'] == missing)
        assert not missing_entry['available']
        assert {'text', 'rich_span', 'list_marker', 'text_style'}.issubset({u['kind'] for u in missing_entry['uses']})
        assert any(u.get('story_id') == story_id for u in missing_entry['uses'])
        baseline = get(); baseline_refs = refs(); story_words = source()['text']; identities = [i['id'] for i in source()['listItems']]
        preview = c.call('form_replace_font', {'from_font': missing, 'to_font': 'Georgia', 'dry_run': True})
        assert preview['replaced_assignments'] > 0 and get() == baseline and refs() == baseline_refs
        changed = c.call('form_replace_font', {'from_font': missing, 'to_font': 'Georgia'})
        saved = get()
        assert changed['replaced_assignments'] == preview['replaced_assignments']
        assert source()['text'] == story_words and [i['id'] for i in source()['listItems']] == identities
        assert {key for key in refs() if refs()[key] != baseline_refs[key]} == {sheet['id']}, 'Story and style changes must not rewrite bounded frame source files.'
        current_body = next(e for o in saved['objects'] if o['id'] == sheet['id'] for e in o['artwork']['elements'] if e['id'] == body['id'])
        assert current_body['text'] == body['text'] and current_body['typography']['fontName'] == 'Georgia'
        assert current_body['typography']['features'] == body['typography']['features']
        assert current_body['typography']['variations'] == body['typography']['variations']
        assert current_body['textRuns'][0]['location'] == body['textRuns'][0]['location']
        c.call('form_undo'); assert get() == baseline
        c.call('form_redo'); assert get() == saved
        c.call('form_replace_font', {'from_font': 'Georgia', 'to_font': 'FORM Missing Replacement'}, expect_error=True)
        assert get() == saved
        c.call('form_edit_artwork', {'object_id': sheet['id'], 'element_ids': [body['id']], 'command': 'font',
                                   'font_name': 'Baskerville', 'location': 2, 'length': 1}, expect_error=True)
        assert get() == saved
        options = c.call('form_font_features', {'font_name': 'HoeflerText-Regular', 'command': 'glyphs', 'query': 'Q.alt'})['glyphs']
        glyph = next(g['glyph'] for g in options if g['glyph'].get('glyphName') == 'Q.alt')
        c.call('form_edit_artwork', {'object_id': sheet['id'], 'element_ids': [glyph_text['id']], 'command': 'glyph',
                                   'location': 0, 'length': 1, 'glyph': glyph})
        exact_baseline = get()
        result = c.call('form_replace_font', {'from_font': 'HoeflerText-Regular', 'to_font': 'Georgia'})
        assert result['retained_exact_glyphs'] == 1 and result['warnings']
        replaced = get()
        before_glyph = next(e for o in exact_baseline['objects'] if o['id'] == sheet['id'] for e in o['artwork']['elements'] if e['id'] == glyph_text['id'])
        after_glyph = next(e for o in replaced['objects'] if o['id'] == sheet['id'] for e in o['artwork']['elements'] if e['id'] == glyph_text['id'])
        assert after_glyph['glyphOverrides'] == before_glyph['glyphOverrides'] and after_glyph['text'] == before_glyph['text']
        c.call('form_export_artwork', {'object_id': sheet['id'], 'format': 'pdf', 'path': str(OUTPUT / 'font-library-unresolved.pdf')}, expect_error=True)
        c.call('form_undo'); assert get() == exact_baseline
        exports = {}
        for fmt in ['pdf', 'png']:
            exports[fmt] = c.call('form_export_artwork', {'object_id': sheet['id'], 'format': fmt,
                'path': str(OUTPUT / ('font-library.' + fmt)), 'dpi': 144})
        c.call('form_open_project', {'project_id': project['id']})
        reopened = get()
        assert reopened['objects'] == exact_baseline['objects'] and reopened['textStories'] == exact_baseline['textStories']
        assert reopened['textStyles'] == exact_baseline['textStyles'] and reopened['schemaVersion'] == exact_baseline['schemaVersion'], 'Font UI preferences do not introduce a project schema.'
        preferences = library / 'FontPreferences.json'
        assert preferences.exists() and 'Georgia' in json.loads(preferences.read_text())['recent']
        c.call('form_set_view', {'view': 'canvas', 'object_id': sheet['id'], 'element_ids': [body['id']]})
        times = []
        for _ in range(20):
            start = time.perf_counter(); c.call('form_list_fonts', {'command': 'faces', 'query': 'Bold', 'limit': 50})
            times.append((time.perf_counter() - start) * 1000)
        report = dict(project_id=project['id'], sheet_id=sheet['id'], body_id=body['id'], story_id=story_id,
            missing_face=missing, catalog=first['renderer'], preferences=str(preferences), exports=exports,
            packaged_query_median_ms=round(statistics.median(times), 2), packaged_query_p95_ms=round(sorted(times)[18], 2),
            checks='Actual packaged discovery/paging; complete missing-face usage; explicit replacement/dry-run; original source/settings/list/style identity retention; immutable bounded frame files; one Undo/Redo; invalid target/range rejection; exact glyph preservation with explicit output failure; physical exports; reopen; isolated preferences.',
            performance_scope='20 saved bridge catalog queries on this installed font set; source tests independently measure cold index, visible row creation and a 200-object/800-span document.')
        (OUTPUT / 'font-library-report.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps({k: v for k, v in report.items() if k != 'exports'}, indent=2))
    finally:
        c.close()


if __name__ == '__main__':
    main()
