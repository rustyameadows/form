#!/usr/bin/env python3
"""Real MCP compound-path, cross-object node, export, and performance checks.

Launch FORM with an isolated FORM_LIBRARY_PATH first. No printer commands.
"""
import json
import pathlib
import statistics
import time
import uuid
from smoke_mcp import Client, OUTPUT


def uid():
    return str(uuid.uuid4()).upper()


def curve(x, y, name):
    return {'id': uid(), 'kind': 'path', 'name': name, 'x': x, 'y': y, 'width': 32, 'height': 24,
            'color': '#263C64', 'text': '', 'fontSize': 14, 'fillEnabled': False, 'stroke': {'color': '#263C64', 'width': .8, 'cap': 'round'},
            'path': {'width': 32, 'height': 24, 'evenOdd': False, 'contours': [{'closed': False, 'nodes': [
                {'id': uid(), 'anchor': {'x': 0, 'y': 15}, 'outgoing': {'x': 8, 'y': -4}},
                {'id': uid(), 'anchor': {'x': 32, 'y': 9}, 'incoming': {'x': 22, 'y': 28}}]}]}}


def main():
    c = Client()
    try:
        tools = c.rpc('tools/list')['tools']
        assert len(tools) == 42
        schema = next(t for t in tools if t['name'] == 'form_edit_path')['inputSchema']
        assert 'combine' in schema['properties']['operation']['enum']
        p = c.call('form_create_project', {'name': 'Contour atelier'})
        source = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'CONTOUR / 001', 'parameters': {'width': 200, 'depth': 140}})
        outer = {'id': uid(), 'kind': 'ellipse', 'name': 'Outer contour', 'x': 20, 'y': 30, 'width': 78, 'height': 78, 'color': '#D45A37'}
        inner = {'id': uid(), 'kind': 'ellipse', 'name': 'Inner contour', 'x': 37, 'y': 47, 'width': 44, 'height': 44, 'color': '#D45A37', 'gradient': {'kind': 'linear', 'start': {'x': 0, 'y': 0}, 'end': {'x': 1, 'y': 1}, 'stops': [{'id': uid(), 'offset': 0, 'color': '#D45A37'}, {'id': uid(), 'offset': 1, 'color': '#E4D8A9'}]}}
        a, b = curve(115, 47, 'Curve A'), curve(153, 65, 'Curve B')
        title = {'id': uid(), 'kind': 'text', 'name': 'Edition', 'x': 20, 'y': 12, 'width': 160, 'height': 10, 'text': 'CONTOUR / 001', 'color': '#263C64', 'fontSize': 19, 'typography': {'fontName': 'Arial-BoldMT', 'tracking': 2.5}}
        caption = {'id': uid(), 'kind': 'text', 'x': 20, 'y': 119, 'width': 160, 'height': 10, 'text': 'A STUDY IN CONNECTIONS.', 'color': '#263C64', 'fontSize': 10}
        for element in [outer, inner]:
            element.update(text='', fontSize=14)
        c.call('form_set_artwork', {'object_id': source['id'], 'artwork': {'background': '#F9F7F0', 'bleed': 0, 'elements': [title, outer, inner, a, b, caption]}})
        converted = c.call('form_convert_to_paths', {'object_id': source['id'], 'element_ids': [outer['id'], inner['id']], 'mode': 'shape'})['selected_elements']
        compound = c.call('form_edit_path', {'object_id': source['id'], 'element_ids': converted, 'operation': 'combine'})['selected_elements'][0]
        baseline = c.call('form_get_artwork', {'object_id': source['id']})
        assert next(e for e in baseline['elements'] if e['id'] == compound)['path']['evenOdd']
        c.call('form_edit_path', {'object_id': source['id'], 'element_id': compound, 'operation': 'release'})
        c.call('form_undo')
        assert c.call('form_get_artwork', {'object_id': source['id']}) == baseline
        box = c.call('form_add_object', {'recipe_id': 'box', 'name': 'Contour · Clay edition', 'material_id': 'clay', 'parameters': {'width': 220, 'depth': 160, 'height': 18}, 'position': [-250, 0, 0]})
        c.call('form_link_artwork', {'object_id': box['id'], 'source_object_id': source['id'], 'fit': 'actual'})
        variant = c.call('form_duplicate_object', {'object_id': box['id'], 'mode': 'variant', 'material_id': 'chalk'})
        package = pathlib.Path(c.call('form_status')['library_path']) / (p['id'] + '.form')
        before = json.loads((package / 'Manifest.json').read_text())
        files = {o['id']: o['file'] for o in before['objects'] if o['id'] in [box['id'], variant['id']]}
        endpoints = [a['path']['contours'][0]['nodes'][-1]['id'], b['path']['contours'][0]['nodes'][0]['id']]
        joined = c.call('form_edit_path', {'object_id': box['id'], 'element_ids': [a['id'], b['id']], 'operation': 'join', 'node_ids': endpoints})['selected_elements'][0]
        art = c.call('form_get_artwork', {'object_id': source['id']})
        assert len(next(e for e in art['elements'] if e['id'] == joined)['path']['contours'][0]['nodes']) == 4
        after = json.loads((package / 'Manifest.json').read_text())
        assert {o['id']: o['file'] for o in after['objects'] if o['id'] in files} == files
        c.call('form_undo'); assert c.call('form_get_artwork', {'object_id': source['id']}) == baseline
        c.call('form_redo'); assert c.call('form_get_artwork', {'object_id': variant['id']}) == art
        before = c.call('form_get_project')
        c.call('form_edit_path', {'object_id': source['id'], 'element_ids': [joined, compound], 'operation': 'join', 'node_ids': [uid(), endpoints[0]]}, expect_error=True)
        assert c.call('form_get_project') == before
        for fmt in ['svg', 'pdf', 'png']:
            c.call('form_export_artwork', {'object_id': source['id'], 'format': fmt, 'path': str(OUTPUT / ('contour-atelier.' + fmt)), 'dpi': 150})
        c.call('form_open_project', {'project_id': p['id']})
        assert c.call('form_get_artwork', {'object_id': box['id']}) == art
        perf = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'Node performance', 'parameters': {'width': 400, 'depth': 300}})
        paths = [curve((i % 10) * 36, (i // 10) * 8, f'Curve {i}') for i in range(300)]
        c.call('form_set_artwork', {'object_id': perf['id'], 'artwork': {'background': '#FFFFFF', 'elements': paths, 'bleed': 0}})
        node_ids = [n['id'] for e in paths for n in e['path']['contours'][0]['nodes']]
        times = []
        for i in range(20):
            start = time.perf_counter()
            c.call('form_edit_path', {'object_id': perf['id'], 'element_ids': [e['id'] for e in paths], 'node_ids': node_ids, 'operation': 'transform', 'matrix': {'tx': .1 if i % 2 == 0 else -.1, 'ty': 0}})
            times.append((time.perf_counter() - start) * 1000)
        c.call('form_delete_objects', {'object_ids': [perf['id']]})
        c.call('form_set_artwork', {'object_id': source['id'], 'artwork': baseline})
        c.call('form_set_view', {'view': 'artwork', 'object_id': box['id'], 'element_ids': [a['id'], b['id']], 'node_ids': []})
        report = {'project_id': p['id'], 'source_id': source['id'], 'box_id': box['id'], 'variant_id': variant['id'], 'compound_id': compound, 'curve_ids': [a['id'], b['id']], 'endpoint_ids': endpoints, 'benchmark_paths': 300, 'benchmark_nodes': 600, 'saved_edit_median_ms': round(statistics.median(times), 2), 'saved_edit_p95_ms': round(sorted(times)[18], 2), 'checks': 'shape conversion; compound holes; release/undo; separate endpoints; atomic rejection; shared sources and unchanged consumer files; physical exports; reopen; 300-path node edits', 'status': c.call('form_status')}
        (OUTPUT / 'compound-import-baseline.json').write_text(json.dumps(baseline, indent=2))
        (OUTPUT / 'compound-report.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2))
    finally:
        c.close()


if __name__ == '__main__':
    main()
