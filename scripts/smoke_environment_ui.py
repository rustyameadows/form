#!/usr/bin/env python3
"""Verify linked Studio compositions/media in an isolated native LAB. No hardware."""
import copy
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    token = uuid.uuid4().hex[:12]
    folder = ROOT / '.local/validation' / ('environment-ui-' + token)
    library = folder / 'Library'
    library.mkdir(parents=True)
    app = Path(os.environ.get('LAB_APP_PATH', ROOT / 'build/LAB-ui-candidate.app'))
    binary, helper = app / 'Contents/MacOS/LAB', app / 'Contents/MacOS/lab-mcp'
    socket = '/tmp/lab-ui-' + token + '.sock'
    env = dict(os.environ, LAB_LIBRARY_PATH=str(library), FORM_LIBRARY_PATH=str(library),
               LAB_SOCKET_PATH=socket, FORM_SOCKET_PATH=socket)
    process = None
    seconds, fps = (6, 24) if os.environ.get('LAB_UI_LONG_VIDEO') == '1' else (1, 12)

    def call(name, args=None, fail=False):
        p = subprocess.run([str(helper), '--call', name, json.dumps(args or {})], env=env,
                           capture_output=True, text=True,
                           timeout=660 if name == 'form_export' and (args or {}).get('format') == 'mp4' else 180)
        if fail:
            assert p.returncode != 0, (name, p.stdout)
            return p.stderr
        assert p.returncode == 0, (name, args, p.stderr)
        return json.loads(p.stdout)

    def start(log):
        p = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log)
        deadline = time.monotonic() + 30
        while not Path(socket).exists():
            assert p.poll() is None and time.monotonic() < deadline
            time.sleep(.1)
        assert Path(call('form_status')['library_path']).resolve() == library.resolve()
        return p

    with (folder / 'app.log').open('w') as log:
        try:
            process = start(log)
            call('form_create_project', {'name': 'STILL / Retail composition', 'template': 'cosmetics'})
            source = call('form_get_project')
            carton = next(o for o in source['objects'] if o['recipeID'] == 'tuckCarton')
            scene = call('form_studio_scene', {'command': 'create', 'name': 'Retail shelf 01'})
            for instance in scene['instances']:
                instance['positionMM'] = {'x': -80 if instance['sourceObjectID'] == carton['id'] else 160, 'y': 0, 'z': 0}
            original_instance = next(i for i in scene['instances'] if i['sourceObjectID'] == carton['id'])
            for number, x in [(2, 0), (3, 80)]:
                instance = copy.deepcopy(original_instance)
                instance.update(id=str(uuid.uuid4()).upper(), name='Carton ' + str(number), positionMM={'x': x, 'y': 0, 'z': 0})
                scene['instances'].append(instance)
            scene['instances'].append({'id': str(uuid.uuid4()).upper(), 'name': 'Shelf / presentation prop',
                'prop': {'widthMM': 500, 'heightMM': 20, 'depthMM': 180, 'color': '#DED8CB'},
                'positionMM': {'x': 0, 'y': -20, 'z': 0}, 'rotationDegrees': 0, 'visible': True})
            scene['camera'].update(azimuth=.55, elevation=.35, distance=5, target={'x': .4, 'y': .7, 'z': 0})
            scene['camera'].pop('orientation', None)
            scene['pixels'] = {'width': 900, 'height': 600}
            scene['motion'].update(seconds=seconds, fps=fps, orbitDegrees=30)
            scene = call('form_studio_scene', {'command': 'save', 'scene': scene})
            saved = call('form_get_project')
            assert saved['objects'] == source['objects'] and saved['camera'] == source['camera']
            call('form_undo')
            assert len(call('form_get_project')['studioPresentation']['scenes'][0]['instances']) == 2
            call('form_redo')
            assert call('form_get_project')['studioPresentation']['scenes'] == [scene]
            bad = copy.deepcopy(scene)
            bad['instances'][0]['positionMM']['unexpected'] = 1
            call('form_studio_scene', {'command': 'save', 'scene': bad}, fail=True)
            assert call('form_get_project')['studioPresentation']['scenes'] == [scene]
            outputs = {}
            durations = {}
            for kind, suffix in [('png', 'render'), ('mp4', 'motion')]:
                dest = folder / ('retail.' + suffix)
                started = time.monotonic()
                result = call('form_export', {'format': kind, 'scene_id': scene['id'], 'path': str(dest)})
                durations[kind] = time.monotonic() - started
                record = json.loads(Path(result['record']).read_text())
                data = Path(result['path']).read_bytes()
                assert record[kind + '_sha256'] == hashlib.sha256(data).hexdigest()
                if kind == 'png':
                    assert struct.unpack('>II', data[16:24]) == (900, 600)
                else:
                    assert record['frames'] == seconds * fps and record['seconds'] == seconds and record['codec'] == 'H.264'
                call('form_export', {'format': kind, 'scene_id': scene['id'], 'path': str(dest)}, fail=True)
                assert Path(result['path']).read_bytes() == data
                outputs[kind] = result
            after = call('form_get_project')
            assert after['objects'] == source['objects'] and after['history'] == saved['history']
            project_id = source['id']
            process.terminate(); process.wait(timeout=15); process = None
            Path(socket).unlink(missing_ok=True)
            process = start(log)
            call('form_open_project', {'project_id': project_id})
            reopened = call('form_get_project')
            assert reopened['objects'] == saved['objects']
            assert reopened['studioPresentation']['scenes'] == [scene]
            call('form_set_view', {'view': 'studio'})
            report = {'project_id': project_id, 'scene_id': scene['id'], 'instances': len(scene['instances']),
                'design_objects_preserved': True, 'saved_scene_restart': True, 'outputs': outputs,
                'export_seconds': durations, 'video': {'seconds': seconds, 'fps': fps, 'frames': seconds * fps},
                'checks': ['strict invalid fields', 'independent copies', 'source camera unchanged',
                           'scene Undo/Redo', 'PNG/MP4 actual outputs and hashes', 'existing destinations preserved'],
                'hardware_commands': []}
            (folder / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
            print(json.dumps({'report': str(folder / 'report.json'), 'pid': process.pid,
                              'library': str(library), 'socket': socket}), flush=True)
            if os.environ.get('LAB_UI_REVIEW') == '1':
                process.wait()
        finally:
            if process is not None and process.poll() is None:
                process.terminate(); process.wait(timeout=15)
            Path(socket).unlink(missing_ok=True)


if __name__ == '__main__':
    main()
