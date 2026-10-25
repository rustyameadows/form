#!/usr/bin/env python3
"""Validate merchandise over the packaged MCP bridge in an isolated .local library.

Creates only a disposable study. No printer connections, hardware or inventory writes.
"""
import copy
import json
import math
import pathlib
import struct
import time
import xml.etree.ElementTree as ET
from smoke_mcp import Client, OUTPUT, ROOT


def main():
    c = Client()
    try:
        status = c.call('form_status')
        library = pathlib.Path(status['library_path']).resolve()
        assert library.is_relative_to((ROOT / '.local').resolve()), 'Use an isolated FORM_LIBRARY_PATH below .local.'
        c.discover(['form_textile_zones', 'form_update_object', 'form_export_artwork'])
        folder = OUTPUT / 'merchandise-smoke'
        folder.mkdir(parents=True, exist_ok=True)
        project = c.call('form_create_project', {'name': 'ORBITAL / Merchandise validation', 'template': 'merchandise'})
        tee = next(o for o in project['objects'] if o['recipeID'] == 'crewTee')
        cap = next(o for o in project['objects'] if o['recipeID'] == 'curvedCap')
        tote = next(o for o in project['objects'] if o['recipeID'] == 'canvasTote')
        front = next(o for o in project['objects'] if o['name'] == 'Tee / field-division direct art')
        cap_ink = next(o for o in project['objects'] if o['name'] == 'Cap / conforming NASA front art')
        before = c.call('form_get_project')
        zones = {o['recipeID']: c.call('form_textile_zones', {'object_id': o['id']}) for o in [tee, cap, tote]}
        assert c.call('form_get_project') == before, 'Reading zones mutated the project/history.'
        assert all(z['units'] == 'mm' and z['concept_dimensions'] for z in zones.values())
        assert all(z['allowed_processes'] == ['directPrint'] for z in zones['curvedCap']['zones'])
        for zone in zones['crewTee']['zones']:
            if zone['id'] == 'front':
                assert math.isclose(zone['width_mm'], 356.4) and zone['height_mm'] == 350

        # Reject complete rotated corners outside the physical zone and shrinking a live host.
        bad = copy.deepcopy(front['textile'])
        bad['attachment']['offset'] = {'x': 160, 'y': 0}
        bad['attachment']['rotation'] = 45
        c.call('form_update_object', {'object_id': front['id'], 'textile': bad}, expect_error=True)
        assert c.call('form_get_project') == before
        c.call('form_update_object', {'object_id': tee['id'], 'parameters': {'width': 360}}, expect_error=True)
        assert c.call('form_get_project') == before
        c.call('form_add_object', {'recipe_id': 'textilePatch', 'parameters': {'width': 50, 'depth': 30},
               'textile': {'kind': 'patch', 'process': 'wovenPatch', 'attachment': {'garmentID': cap['id'], 'zone': 'front'}}}, expect_error=True)
        assert c.call('form_get_project') == before

        c.call('form_set_view', {'view': 'table', 'object_id': cap['id']})
        time.sleep(.3)
        builds = c.call('form_status')['renderer']['geometry_builds']
        moved = [cap['position']['x'] + 40, cap['position']['y'], cap['position']['z']]
        c.call('form_update_object', {'object_id': cap['id'], 'position': moved})
        time.sleep(.15)
        assert c.call('form_status')['renderer']['geometry_builds'] == builds
        c.call('form_undo')
        assert c.call('form_get_project') == before
        shown = copy.deepcopy(tee['textile']); shown['laidFaceDown'] = True
        c.call('form_update_object', {'object_id': tee['id'], 'textile': shown})
        time.sleep(.15)
        assert c.call('form_status')['renderer']['geometry_builds'] == builds
        assert c.call('form_textile_zones', {'object_id': tee['id']})['showing_back']
        c.call('form_undo'); assert c.call('form_get_project') == before

        # Shared source edits preserve the region/placement objects, then Undo restores source.
        source_id = cap_ink['artworkSourceID']
        source = c.call('form_get_artwork', {'object_id': source_id})
        edited = copy.deepcopy(source); edited['elements'][0]['color'] = '#C7573B'
        c.call('form_set_artwork', {'object_id': source_id, 'artwork': edited})
        current = c.call('form_get_project')
        assert next(o for o in current['objects'] if o['id'] == cap_ink['id']) == cap_ink
        c.call('form_undo'); assert c.call('form_get_artwork', {'object_id': source_id}) == source

        variant = c.call('form_duplicate_object', {'object_id': tee['id'], 'mode': 'variant', 'material_id': 'jersey-navy'})
        c.call('form_update_object', {'object_id': tee['id'], 'parameters': {'width': 560}})
        current = c.call('form_get_project')
        assert next(o for o in current['objects'] if o['id'] == variant['id'])['parameters']['width'] == 560
        c.call('form_undo'); c.call('form_undo'); assert c.call('form_get_project') == before

        outputs = {}
        for fmt in ['svg', 'pdf', 'png']:
            path = folder / ('tee-print-240x200.' + fmt)
            result = c.call('form_export_artwork', {'object_id': front['id'], 'format': fmt, 'path': str(path), 'dpi': 72})
            data = path.read_bytes(); assert len(data) > 200
            if fmt == 'svg':
                svg = ET.fromstring(data)
                assert float(svg.attrib['width'].removesuffix('mm')) == 240
                assert float(svg.attrib['height'].removesuffix('mm')) == 200
            if fmt == 'png':
                assert struct.unpack('>II', data[16:24]) == (round(240 * 72 / 25.4), round(200 * 72 / 25.4))
            outputs[fmt] = result
        invalid_path = folder / 'garment-must-not-be-blank.svg'; invalid_path.unlink(missing_ok=True)
        c.call('form_export_artwork', {'object_id': tee['id'], 'format': 'svg', 'path': str(invalid_path)}, expect_error=True)
        assert not invalid_path.exists()
        assert c.call('form_get_project') == before
        c.call('form_open_project', {'project_id': project['id']})
        reopened = c.call('form_get_project')
        assert reopened['objects'] == before['objects'] and reopened['materials'] == before['materials']
        assert reopened['schemaVersion'] >= 34
        report = {'project_id': project['id'], 'zones': zones, 'outputs': outputs,
                  'status': c.call('form_status'), 'checks': ['read-only physical zones', 'rotated bounds',
                  'atomic host shrink rejection', 'curved rigid-process rejection', 'mesh reuse on host move and back display',
                  'source and variant sharing', 'Undo', 'physical SVG/PDF/PNG', 'blank garment export rejection', 'saved reopen']}
        (OUTPUT / 'merchandise-report.json').write_text(json.dumps(report, indent=2) + '\n')
        (OUTPUT / 'merchandise-baseline.json').write_text(json.dumps(reopened, indent=2) + '\n')
        print(json.dumps({'project_id': project['id'], 'checks': report['checks']}, indent=2))
    finally:
        c.close()


if __name__ == '__main__':
    main()
