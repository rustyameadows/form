#!/usr/bin/env python3
"""Packaged native MCP HTV/DTF capture/Undo/reopen/export acceptance.

Only a disposable FORM_LIBRARY_PATH below this repository's .local is allowed.
No printer/cutter/RIP call, upload, press recipe, or stock deduction is made.
"""
import json
import pathlib
import uuid
import zipfile
from smoke_mcp import Client, OUTPUT, ROOT
from verify_decoration_handoff import verify_packet


def main():
    c = Client()
    try:
        library = pathlib.Path(c.call('form_status')['library_path']).resolve()
        assert library.is_relative_to((ROOT / '.local').resolve()), 'Use a disposable .local validation library.'
        tools = c.discover(['form_production_job', 'form_color_profile', 'form_swatch', 'form_undo', 'form_redo'])
        project = c.call('form_create_project', {'name': 'ORBITAL / Transfer preparation', 'template': 'merchandise'})
        tee = next(o for o in project['objects'] if o['name'] == 'Tee / field-division direct art')
        cap = next(o for o in project['objects'] if o['name'] == 'Cap / conforming NASA front art')
        prefix = 'decoration-' + uuid.uuid4().hex[:10]
        def job(command, **args):
            return c.call('form_production_job', dict(kind='decoration', command=command) | args)
        original = c.call('form_get_project')
        # The existing omitted-kind embroidery API is unchanged.
        assert c.call('form_production_job', {'command': 'list'})['jobs'] == []
        assert job('list')['jobs'] == []
        htv = dict(process='htv', mirror=True, weedMargin=4.25)
        report = job('preflight', object_id=tee['id'], preparation=htv, quantity=12)
        assert report['can_export'] and report['target']['surface'] == 'planar'
        assert [report['width_mm'], report['height_mm']] == [240, 200]
        assert c.call('form_get_project') == original
        htv['layerMaterials'] = [dict(paintKey=r['paint_key'], name='Operator-selected material ' + str(i + 1))
                                 for i, r in enumerate(report['material_regions'])]
        result = job('create', object_id=tee['id'], preparation=htv, quantity=12,
                     name='NASA / mirrored carrier-side HTV', notes='Material selection is a declaration; verify supplier instructions.')
        captured = c.call('form_get_project')
        assert captured['schemaVersion'] >= 38 and captured['objects'] == original['objects'] and captured['camera'] == original['camera']
        assert result['machine_contacted'] is False and result['inventory_deducted'] is False
        htv_job = result['job']
        c.call('form_undo'); assert c.call('form_get_project') == original
        c.call('form_redo'); assert c.call('form_get_project') == captured
        bad = dict(htv, weedMargin=51)
        c.call('form_production_job', dict(kind='decoration', command='create', object_id=tee['id'], preparation=bad), expect_error=True)
        assert c.call('form_get_project') == captured
        dtf = dict(process='dtf', mirror=False, dpi=300, whitePolicy='showThrough', includeUnderbaseReference=True)
        result = job('create', object_id=tee['id'], preparation=dtf, quantity=2, name='NASA / transparent DTF handoff')
        dtf_job = result['job']
        curved = job('preflight', object_id=cap['id'], preparation=dtf)
        assert curved['target']['surface'] == 'cylindricalBand' and not curved['target']['measured_application_compensation']
        # A separate physical source exercises real process-CMYK delivery and
        # explicit alternate conversion while retaining original named ink.
        color_frame = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'Transfer / declared ink', 'parameters': {'width': 100, 'depth': 80}})
        mark = dict(id=str(uuid.uuid4()).upper(), kind='rectangle', x=10, y=10, width=60, height=40, text='', fontSize=12, color='#D46A32')
        c.call('form_set_artwork', {'object_id': color_frame['id'], 'artwork': {'background': '#FFFFFF', 'backgroundOpacity': 0, 'bleed': 0, 'elements': [mark]}})
        profile = next(p for p in c.call('form_color_profile')['profiles'] if p['model'] == 'CMYK' and 'Generic' in p['name'])
        c.call('form_color_profile', {'command': 'set', 'object_id': color_frame['id'], 'profile_path': profile['path']})
        reference = c.call('form_get_artwork', {'object_id': color_frame['id']})['outputColorProfile']
        declaration = dict(kind='spot', components=dict(cyan=.1, magenta=.4, yellow=.8, black=.2), tint=.5, spotName='Original transfer orange', profile=reference)
        swatch = c.call('form_swatch', {'command': 'create', 'name': 'Transfer orange 50%', 'print_ink': declaration})['swatch']
        c.call('form_swatch', {'command': 'assign', 'object_id': color_frame['id'], 'element_ids': [mark['id']], 'swatch_id': swatch['id']})
        process_options = dict(process='dtf', colorDelivery='profiledProcess', dpi=127, convertSpotAlternates=False)
        assert job('preflight', object_id=color_frame['id'], preparation=process_options)['can_export'] is False
        process_options['convertSpotAlternates'] = True
        prior = c.call('form_get_project')
        process_job = job('create', object_id=color_frame['id'], preparation=process_options, name='Original spots / explicit process handoff')['job']
        after = c.call('form_get_project')
        assert after['objects'] == prior['objects'] and after['swatches'] == prior['swatches']
        reports = {}
        packet_folders = []
        for label, item in [('htv', htv_job), ('dtf', dtf_job), ('process', process_job)]:
            folder = OUTPUT / (prefix + '-' + label)
            before = c.call('form_get_project')
            out = job('export', job_id=item['id'], format='folder', path=str(folder))
            assert c.call('form_get_project') == before
            reports[label] = verify_packet(folder)
            assert reports[label]['packet_digest'] == out['packet_digest']
            packet_folders.append((item, folder))
        # Actual source modifications do not regenerate archived physical bytes.
        art = c.call('form_get_artwork', {'object_id': tee['id']})
        text = next(e for e in art['elements'] if e['kind'] == 'text')
        # A transform changes source without rewriting rich spans or source words.
        c.call('form_edit_artwork', {'object_id': tee['id'], 'command': 'transform', 'element_ids': [text['id']], 'translate_x': .5})
        assert job('get', job_id=dtf_job['id'])['current_source'] == 'changed'
        c.call('form_undo')
        assert job('get', job_id=dtf_job['id'])['current_source'] == 'matches'
        c.call('form_delete_objects', {'object_ids': [tee['id']]})
        c.call('form_open_project', {'project_id': project['id']})
        assert job('get', job_id=dtf_job['id'])['current_source'] == 'missing'
        archive = OUTPUT / (prefix + '.zip')
        before = c.call('form_get_project')
        job('export', job_id=dtf_job['id'], format='zip', path=str(archive))
        assert c.call('form_get_project') == before
        with zipfile.ZipFile(archive) as z:
            assert z.testzip() is None
            for name in z.namelist():
                assert '..' not in pathlib.PurePosixPath(name).parts and not name.startswith('/')
            for name, data in ((n, (packet_folders[1][1] / n).read_bytes()) for n in json.loads((packet_folders[1][1] / 'Manifest.json').read_text())['files']):
                assert z.read('Decoration/' + name) == data
        removed = c.call('form_get_project'); job('remove', job_id=htv_job['id']); c.call('form_undo'); assert c.call('form_get_project') == removed
        result = dict(project_id=project['id'], tee_id=tee['id'], cap_id=cap['id'], htv_job=htv_job['id'], dtf_job=dtf_job['id'],
                      packet=str(archive), reports=reports, tools=len(tools), native_acceptance_pending=True,
                      machine_contacted=False, inventory_deducted=False,
                      checks='Physical SVG/PNG; actual merchandise zones; explicit mirror/weed/white; immutable hashes; one Undo; rejected options; source change/deletion/reopen; unchanged embroidery default')
        (OUTPUT / 'decoration-preparation-report.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
    finally:
        c.close()


if __name__ == '__main__':
    main()
