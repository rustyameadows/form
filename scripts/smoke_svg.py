#!/usr/bin/env python3
"""Exercise editable SVG import over FORM's actual local MCP transport.

Run against a disposable FORM_LIBRARY_PATH. No models, network resources, or
printer commands are used. Native file-dialog/mouse checks are separate.
"""
import hashlib
import json
import pathlib
import re
import statistics
import struct
import time
import xml.etree.ElementTree as ET
from smoke_mcp import Client, OUTPUT, ROOT


def main():
    client = Client()
    fixture = ROOT / 'Tests/Fixtures/orbit-mark.svg'
    unsupported = ROOT / 'Tests/Fixtures/unsupported-effects.svg'
    try:
        assert len(client.rpc('tools/list')['tools']) == 42
        project = client.call('form_create_project', {'name': 'ORBIT · SVG import study'})
        package = pathlib.Path(client.call('form_status')['library_path']) / (project['id'] + '.form')
        before = client.call('form_get_project')
        assets_before = sorted(p.name for p in (package / 'Assets').iterdir())
        start = time.perf_counter()
        preview = client.call('form_import_svg', {'path': str(fixture), 'dry_run': True})
        cold_ms = (time.perf_counter() - start) * 1000
        assert abs(preview['width_mm']-120) < 1e-9 and abs(preview['height_mm']-80) < 1e-9, preview
        assert not preview['requires_review'], preview
        assert preview['embedded_images'] == 1
        assert client.call('form_get_project') == before
        assert sorted(p.name for p in (package / 'Assets').iterdir()) == assets_before
        warnings = client.call('form_import_svg', {'path': str(unsupported), 'dry_run': True})
        assert warnings['requires_review']
        client.call('form_import_svg', {'path': str(unsupported)}, expect_error=True)
        assert client.call('form_get_project') == before
        assert sorted(p.name for p in (package / 'Assets').iterdir()) == assets_before
        result = client.call('form_import_svg', {'path': str(fixture), 'name': 'ORBIT · Original artwork'})
        source_id = result['object_id']
        assert (package / 'Assets' / result['original_asset']).read_bytes() == fixture.read_bytes()
        source = next(o for o in client.call('form_get_project')['objects'] if o['id'] == source_id)
        art = source['artwork']
        assert art['backgroundOpacity'] == 0 and abs(art['imports'][0]['width']-120) < 1e-9
        images = [e for e in art['elements'] if e['kind'] == 'image']
        assert len(images) == 1 and (package / 'Assets' / images[0]['asset']).stat().st_size > 50
        box = client.call('form_add_object', {'recipe_id': 'box', 'name': 'ORBIT · Oak edition', 'material_id': 'oak', 'parameters': {'width': 160, 'depth': 110, 'height': 22}, 'position': [-200, 0, 0]})
        client.call('form_link_artwork', {'object_id': box['id'], 'source_object_id': source_id, 'fit': 'actual'})
        variant = client.call('form_duplicate_object', {'object_id': box['id'], 'mode': 'variant', 'material_id': 'graphite'})
        manifest_before = json.loads((package / 'Manifest.json').read_text())
        consumer_files = {r['id']: r['file'] for r in manifest_before['objects'] if r['id'] in [box['id'], variant['id']]}
        path = next(e for e in art['elements'] if e.get('name') == 'planet-disc')
        node = path['path']['contours'][0]['nodes'][0]['id']
        client.call('form_edit_path', {'object_id': source_id, 'element_id': path['id'], 'operation': 'transform', 'node_ids': [node], 'matrix': {'a': 1, 'b': 0, 'c': 0, 'd': 1, 'tx': .5, 'ty': .5}})
        manifest_after = json.loads((package / 'Manifest.json').read_text())
        assert {r['id']: r['file'] for r in manifest_after['objects'] if r['id'] in consumer_files} == consumer_files
        client.call('form_undo')
        assert client.call('form_get_artwork', {'object_id': source_id}) == art
        accepted = client.call('form_import_svg', {'path': str(unsupported), 'object_id': box['id'], 'allow_unsupported': True})
        assert accepted['object_id'] == source_id
        assert len(client.call('form_get_artwork', {'object_id': box['id']})['imports']) == 2
        client.call('form_undo')
        assert client.call('form_get_artwork', {'object_id': source_id}) == art
        exports = {}
        for fmt in ['svg', 'pdf', 'png', 'jpeg']:
            target = OUTPUT / ('orbit-import.' + fmt)
            exports[fmt] = client.call('form_export_artwork', {'object_id': source_id, 'format': fmt, 'path': str(target), 'dpi': 150})
            assert target.stat().st_size > 200
        editable_svg = OUTPUT / 'orbit-import-editable.svg'
        client.call('form_export_artwork', {'object_id': source_id, 'format': 'svg', 'path': str(editable_svg), 'outline_text': False})
        tree = ET.parse(OUTPUT / 'orbit-import.svg').getroot()
        assert abs(float(tree.attrib['width'][:-2])-120) < 1e-9 and abs(float(tree.attrib['height'][:-2])-80) < 1e-9
        assert any(e.tag.endswith('linearGradient') and 'gradientTransform' in e.attrib for e in tree.iter())
        assert any(e.tag.endswith('image') for e in tree.iter())
        pdf = (OUTPUT / 'orbit-import.pdf').read_bytes()
        box_match = re.search(rb'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)', pdf)
        assert box_match and abs(float(box_match[1]) - 120*72/25.4) < .1 and abs(float(box_match[2]) - 80*72/25.4) < .1
        png = (OUTPUT / 'orbit-import.png').read_bytes()
        assert struct.unpack('>II', png[16:24]) == (709, 472)
        # Import preflight on hundreds of actual native paths/texts; all runs are read-only.
        benchmark = OUTPUT / 'svg-import-benchmark.svg'
        shapes = ''.join(f'<rect x="{(i%40)*12}" y="{(i//40)*12}" width="9" height="9" class="ink"/>' for i in range(600))
        texts = ''.join(f'<text x="{(i%20)*24}" y="{200+(i//20)*20}" font-family="Arial" font-size="8">{i:03}</text>' for i in range(100))
        benchmark.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="240mm" height="140mm" viewBox="0 0 480 280"><style>.ink{fill:#263C64}</style>' + shapes + texts + '</svg>')
        unchanged = client.call('form_get_project')
        times = []
        for _ in range(6):
            start = time.perf_counter()
            report = client.call('form_import_svg', {'path': str(benchmark), 'dry_run': True})
            times.append((time.perf_counter()-start)*1000)
            assert not report['requires_review'] and report['paths'] == 600 and report['text_objects'] == 100, report
        assert client.call('form_get_project') == unchanged
        client.call('form_open_project', {'project_id': project['id']})
        reopened = client.call('form_get_project')
        assert reopened['schemaVersion'] == 4
        assert next(o for o in reopened['objects'] if o['id'] == source_id)['artwork'] == art
        assert next(o for o in reopened['objects'] if o['id'] == box['id'])['artworkSourceID'] == source_id
        wordmark = next(e for e in art['elements'] if e.get('name') == 'wordmark')
        client.call('form_set_view', {'view': 'artwork', 'object_id': box['id'], 'element_ids': [wordmark['id']]})
        report = {'project_id': project['id'], 'source_id': source_id, 'box_id': box['id'], 'variant_id': variant['id'], 'wordmark_id': wordmark['id'], 'tools': 42, 'original_sha256': hashlib.sha256(fixture.read_bytes()).hexdigest(), 'preflight': preview, 'cold_preflight_ms': round(cold_ms,2), 'benchmark_700_elements_median_ms': round(statistics.median(times),2), 'benchmark_700_elements_max_ms': round(max(times),2), 'exports': exports, 'checks': 'read-only preflight; explicit fidelity review; failure immutability; original/embedded assets; editable paths/text/groups/gradients/clips; linked physical sources; consumer immutable files; node edit/undo; actual-size exports; schema 4 reopen', 'status': client.call('form_status')}
        (OUTPUT / 'svg-import-report.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report,indent=2))
    finally:
        client.close()


if __name__ == '__main__':
    main()
