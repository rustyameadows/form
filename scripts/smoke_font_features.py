#!/usr/bin/env python3
"""FOUNDRY: simultaneous font features, native text metadata and physical output.

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


def text(x, y, w, h, value, size, face='Baskerville', color='#283830', **type_options):
    return dict(id=str(uuid.uuid4()).upper(), kind='text', x=x, y=y, width=w, height=h,
        text=value, name=value.replace('\n', ' / '), fontSize=size, color=color,
        typography=dict(fontName=face, **type_options))


def main():
    c = Client()
    try:
        status = c.call('form_status'); assert '/.local/' in status['library_path']
        c.discover(['form_font_features'])
        details = c.call('form_font_features', {'font_name': 'Baskerville'})
        ligatures = next(f for f in details['features'] if f['id'] == 1)
        assert not ligatures['exclusive']
        assert {2, 4, 20}.issubset({s['id'] for s in ligatures['selectors']})
        project = c.call('form_create_project', {'name': 'FOUNDRY · The character of type'})
        sheet = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'FOUNDRY / 8 × 10 in specimen',
            'parameters': {'width': 203.2, 'depth': 254}})
        title = text(16, 29, 174, 31, 'Affinities.', 67, featureSelections={'1': [2, 4, 20]})
        combined = text(16, 94, 171, 26, 'fi  fl  ct  st', 55, featureSelections={'1': [2, 4, 20]})
        separate = text(16, 145, 171, 26, 'fi  fl  ct  st', 55, featureSelections={'1': [3, 5, 21]})
        variable = text(16, 203, 80, 23, 'Axis', 42, 'Skia', '#B75B3E',
            variations={'2003265652': 1.8, '2003072104': 1.12}, featureSelections={'1': [2, 4, 11]})
        mixed = text(104, 204, 82, 14, '0123 / 4567', 24, features={'21': 0})
        mixed['textRuns'] = [dict(location=0, length=4, typography=dict(fontName='Baskerville',
            features={'21': 0}, featureSelections={'1': [2, 4, 20]}), fontSize=24, color='#B75B3E')]
        elements = [text(16, 13, 130, 6, 'FORM / TYPE ATELIER', 8, 'Menlo-Regular', tracking=1.2),
            text(165, 13, 25, 6, 'No. 011', 8, 'Menlo-Regular'), title,
            text(16, 66, 165, 12, 'One face. Many voices.\nA study in the details that bring letters together.', 12),
            text(16, 85, 170, 6, '01 / IN COMPANY', 7.5, 'Menlo-Regular', '#B75B3E', tracking=1), combined,
            text(16, 124, 171, 8, 'Common + additional + historical ligatures. Independently on.', 9),
            text(16, 136, 170, 6, '02 / INDIVIDUALLY', 7.5, 'Menlo-Regular', '#B75B3E', tracking=1), separate,
            text(16, 175, 171, 8, 'The same characters. Each ligature explicitly off.', 9),
            text(16, 193, 80, 6, '03 / VARIABLE FORM', 7.5, 'Menlo-Regular', tracking=.6), variable,
            text(104, 193, 82, 6, '04 / NUMERAL VOICES', 7.5, 'Menlo-Regular', tracking=.6), mixed,
            text(104, 222, 82, 8, 'Old-style figures. Character-level color.', 8.5),
            text(16, 239, 174, 6, 'BASKERVILLE + SKIA / EDITABLE TYPE / REAL DIMENSIONS', 7, 'Menlo-Regular', tracking=.4)]
        for y in [22, 81, 132, 188, 234]:
            elements.append(dict(id=str(uuid.uuid4()).upper(), kind='line', x=16, y=y, width=171.2,
                height=.1, text='', color='#99A195', fontSize=14,
                stroke=dict(color='#99A195', width=.18)))
        c.call('form_set_artwork', {'object_id': sheet['id'], 'artwork': dict(background='#F3F0E5',
            bleed=0, unit='in', elements=elements)})
        box = c.call('form_add_object', {'recipe_id': 'box', 'name': 'FOUNDRY / Oak specimen',
            'material_id': 'oak', 'parameters': {'width': 203.2, 'depth': 254, 'height': 12, 'corner': 2},
            'position': [-250, 0, 0]})
        c.call('form_link_artwork', {'object_id': box['id'], 'source_object_id': sheet['id']})
        variant = c.call('form_duplicate_object', {'object_id': box['id'], 'mode': 'variant', 'material_id': 'graphite'})
        def art(): return c.call('form_get_artwork', {'object_id': sheet['id']})
        def replace(e, owner=None):
            return c.call('form_edit_artwork', {'object_id': owner or sheet['id'], 'command': 'replace', 'elements': [e]})
        def export(suffix='', fmt='png'):
            path = OUTPUT / ('foundry-sheet'+suffix+'.'+fmt)
            return c.call('form_export_artwork', {'object_id': sheet['id'], 'format': fmt, 'path': str(path), 'dpi': 150})
        before = c.call('form_get_project')
        package = pathlib.Path(status['library_path'])/(project['id']+'.form')
        resources = lambda: {o['id']: o['file'] for o in json.loads((package/'Manifest.json').read_text())['objects']}
        old_resources = resources()
        edited = copy.deepcopy(title); edited['typography']['featureSelections'] = {'1': [3, 4, 20]}
        replace(edited, box['id'])
        assert {k for k in old_resources if old_resources[k] != resources()[k]} == {sheet['id']}
        assert c.call('form_get_artwork', {'object_id': variant['id']}) == art()
        c.call('form_undo'); assert c.call('form_get_project')['objects'] == before['objects']
        bad = copy.deepcopy(title); bad['typography']['featureSelections'] = {'1': [2, 3]}
        c.call('form_batch', {'operations': [
            {'name': 'form_edit_artwork', 'arguments': {'object_id': sheet['id'], 'command': 'replace', 'elements': [edited]}},
            {'name': 'form_edit_artwork', 'arguments': {'object_id': sheet['id'], 'command': 'replace', 'elements': [bad]}}]}, expect_error=True)
        assert c.call('form_get_project') == before
        exports = {fmt: export(fmt=fmt) for fmt in ['svg', 'pdf', 'png', 'jpeg']}
        png = (OUTPUT/'foundry-sheet.png').read_bytes()
        assert struct.unpack('>II', png[16:24]) == (1200, 1500)
        svg = (OUTPUT/'foundry-sheet.svg').read_text()
        assert 'width="203.2mm"' in svg and '<text ' not in svg and '<path ' in svg
        outlined = c.call('form_convert_to_paths', {'object_id': sheet['id'], 'element_ids': [combined['id']]})
        assert outlined['elements'] and all(e['kind'] == 'path' for e in outlined['elements'])
        assert next(e for e in art()['elements'] if e['id'] == combined['id'])['hidden']
        export('-outlined')
        c.call('form_undo'); assert c.call('form_get_project')['objects'] == before['objects']
        c.call('form_open_project', {'project_id': project['id']})
        assert c.call('form_get_project')['schemaVersion'] == 11
        assert c.call('form_get_project')['objects'] == before['objects']
        perf = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'Typography benchmark',
            'parameters': {'width': 500, 'depth': 500}})
        perf_art = dict(background='#F3F0E5', bleed=0, elements=[text(10+(i%10)*49, 10+(i//10)*24,
            47, 20, 'fi ct st / '+str(i), 20, featureSelections={'1': [2, 4, 20]}) for i in range(200)])
        c.call('form_set_artwork', {'object_id': perf['id'], 'artwork': perf_art})
        c.call('form_set_view', {'view': 'artwork', 'object_id': perf['id']})
        times=[]
        for i in range(20):
            for e in perf_art['elements']:
                e['typography']['featureSelections']['1'] = [2+i%2, 4, 20+(i//2)%2]
            start=time.perf_counter()
            c.call('form_set_artwork', {'object_id': perf['id'], 'artwork': perf_art})
            times.append((time.perf_counter()-start)*1000)
        perf_status = c.call('form_status')
        c.call('form_delete_objects', {'object_ids': [perf['id']]})
        c.call('form_set_view', {'view': 'artwork', 'object_id': box['id'], 'element_ids': [combined['id']]})
        report = dict(project_id=project['id'], sheet_id=sheet['id'], box_id=box['id'], variant_id=variant['id'],
            title_id=title['id'], combined_id=combined['id'], separate_id=separate['id'], variable_id=variable['id'],
            mixed_id=mixed['id'], tools=50, exports=exports,
            benchmark_texts=200, saved_edit_median_ms=round(statistics.median(times),2),
            saved_edit_p95_ms=round(sorted(times)[18],2), performance_status=perf_status,
            checks='Real installed capabilities; simultaneous features; source-only immutable updates; linked faces; invalid-pair batch rollback; rich spans; variable axes; editable outlines/recovery; physical outputs; schema-11 reopen; 200-text edits',
            status=c.call('form_status'))
        (OUTPUT/'font-features-report.json').write_text(json.dumps(report,indent=2)+'\n')
        (OUTPUT/'font-features-baseline.json').write_text(json.dumps(c.call('form_get_project'),indent=2)+'\n')
        print(json.dumps(report,indent=2))
    finally:c.close()


if __name__ == '__main__': main()
