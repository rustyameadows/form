#!/usr/bin/env python3
"""Exercise paper construction in a disposable native LAB. No hardware commands."""
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
    folder = ROOT / '.local/validation' / ('paper-construction-' + token)
    library = folder / 'Library'
    library.mkdir(parents=True)
    app = Path(os.environ.get('LAB_APP_PATH', ROOT / 'build/LAB-paper-candidate.app'))
    binary, helper = app / 'Contents/MacOS/LAB', app / 'Contents/MacOS/lab-mcp'
    socket = '/tmp/lab-paper-' + token + '.sock'
    env = dict(os.environ, LAB_LIBRARY_PATH=str(library), FORM_LIBRARY_PATH=str(library),
               LAB_SOCKET_PATH=socket, FORM_SOCKET_PATH=socket)
    report = {'app': str(app), 'models': {}, 'hardware_commands': []}
    process = None

    def call(name, args=None, fail=False):
        result = subprocess.run([str(helper), '--call', name, json.dumps(args or {})], env=env,
                                capture_output=True, text=True, timeout=90)
        if fail:
            assert result.returncode != 0, (name, result.stdout)
            return result.stderr
        assert result.returncode == 0, (name, args, result.stderr)
        return json.loads(result.stdout)

    def start(log):
        p = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log)
        deadline = time.monotonic() + 30
        while not Path(socket).exists():
            assert p.poll() is None, 'LAB exited before opening its bridge'
            assert time.monotonic() < deadline, 'Native bridge startup timeout'
            time.sleep(.1)
        assert Path(call('form_status')['library_path']).resolve() == library.resolve()
        return p

    def source(project):
        # Native resize updates viewport aspect without moving the saved camera pose.
        value = copy.deepcopy(project)
        value['camera'].pop('viewportAspect', None)
        return value

    def capture(object_id, name):
        call('form_set_view', {'view': 'perspective'})
        call('form_set_view', {'view': 'isolate', 'object_id': object_id})
        call('form_set_view', {'view': 'focus', 'object_id': object_id})
        path = folder / (name + '.png')
        call('form_export', {'format': 'png', 'path': str(path), 'object_id': object_id})
        assert struct.unpack('>II', path.read_bytes()[16:24]) == (3000, 2000)
        return str(path)

    with (folder / 'app.log').open('w') as log:
        try:
            process = start(log)
            for template, recipe in [('cyanotype', 'paperEnvelope'), ('cosmetics', 'tuckCarton')]:
                call('form_create_project', {'name': 'Sun studies / Envelope review' if template == 'cyanotype' else 'STILL / Carton review', 'template': template})
                initial = call('form_get_project')
                paper = next(o for o in initial['objects'] if o['recipeID'] == recipe)
                object_id = paper['id']
                inspected = call('form_paper', {'command': 'inspect', 'object_id': object_id})
                net = inspected['net']
                assert len(net['panels']) == (9 if template == 'cyanotype' else 13)
                assert len(net['folds']) == len(net['panels']) - 1
                for environment in ['form', 'function', 'fabricate']:
                    call('form_set_view', {'view': environment, 'object_id': object_id})
                    for representation in ['panels', 'dieline', 'sheet']:
                        call('form_paper', {'command': 'view', 'object_id': object_id,
                                           'representation': representation, 'split': True, 'panel_id': 'front'})
                        status = call('form_status')
                        assert status['environment'] == environment
                        assert status['paper_workspace']['representation'] == representation
                        actual = call('form_get_project')
                        if source(actual) != source(initial):
                            (folder / 'unexpected-view-before.json').write_text(json.dumps(initial, indent=2))
                            (folder / 'unexpected-view-after.json').write_text(json.dumps(actual, indent=2))
                            raise AssertionError((environment, representation, str(folder)))
                outside = copy.deepcopy(paper.get('artwork'))
                call('form_update_object', {'object_id': object_id, 'parameters': {'opening': 100}})
                opened = call('form_get_project')
                assert next(o for o in opened['objects'] if o['id'] == object_id)['artwork'] == outside
                open_png = capture(object_id, template + '-open')
                call('form_update_object', {'object_id': object_id, 'parameters': {'opening': 0, 'fold': 0}})
                flat_png = capture(object_id, template + '-flat')
                call('form_update_object', {'object_id': object_id, 'parameters': {'fold': 100}})
                closed_png = capture(object_id, template + '-closed')
                original = call('form_get_project')
                call('form_update_object', {'object_id': object_id, 'parameters': {'width': paper['parameters']['width'] + 8}})
                changed = call('form_get_project')
                edited = next(o for o in changed['objects'] if o['id'] == object_id)
                assert edited['artwork'] == outside
                assert edited['paperConstruction']['artworkReviewRequired'] is True
                call('form_undo')
                assert source(call('form_get_project')) == source(original)
                call('form_redo')
                assert source(call('form_get_project')) == source(changed)
                call('form_undo')
                call('form_paper', {'command': 'configure', 'object_id': object_id,
                                   'parameters': {'stock': -1}}, fail=True)
                assert source(call('form_get_project')) == source(original)
                layout = call('form_paper', {'command': 'layout', 'object_id': object_id,
                                             'sheet_width': 700, 'sheet_height': 1000, 'count': 3})
                assert len(layout['placements']) == 3 and layout['sheetCount'] > 0
                packet = folder / (template + '.paperjob')
                call('form_paper', {'command': 'export', 'object_id': object_id, 'format': 'packet',
                                   'path': str(packet), 'sheet_width': 700, 'sheet_height': 1000, 'count': 3})
                record = json.loads((packet / 'production.json').read_text())
                for name, digest in record['artifact_sha256'].items():
                    assert hashlib.sha256((packet / name).read_bytes()).hexdigest() == digest
                call('form_paper', {'command': 'export', 'object_id': object_id, 'format': 'packet',
                                   'path': str(packet)}, fail=True)
                assert source(call('form_get_project')) == source(original)
                report['models'][template] = {'project_id': initial['id'], 'object_id': object_id,
                    'panels': len(net['panels']), 'folds': len(net['folds']), 'cut_edges': len(net['cutEdges']),
                    'net_size_mm': net['size'], 'stock': inspected['definition']['stock'],
                    'sheet_count': layout['sheetCount'], 'prototypes': 3,
                    'renders': {'open': open_png, 'flat': flat_png, 'closed': closed_png},
                    'packet': str(packet), 'checks': ['purpose/view independence', 'semantic panel selection',
                    'top opening', 'full unfolding', 'source artwork physical preservation', 'Undo/Redo',
                    'invalid edit unchanged', 'actual PNG', 'physical layout', 'immutable packet hashes']}
            saved = call('form_get_project')
            saved_id = saved['id']
            originals = {str(p.relative_to(library)): hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in library.rglob('*') if p.is_file() and any(x in p.parts for x in ['Assets', 'Objects'])}
            process.terminate(); process.wait(timeout=15); process = None
            Path(socket).unlink(missing_ok=True)
            process = start(log)
            call('form_open_project', {'project_id': saved_id})
            assert source(call('form_get_project')) == source(saved)
            for name, digest in originals.items():
                assert hashlib.sha256((library / name).read_bytes()).hexdigest() == digest
            paper_id = report['models']['cosmetics']['object_id']
            call('form_set_view', {'view': 'function', 'object_id': paper_id})
            call('form_paper', {'command': 'view', 'object_id': paper_id, 'representation': 'dieline', 'split': True})
            report['restart_source_resources_verified'] = len(originals)
            report['renderer'] = call('form_status')['renderer']
            assert report['renderer']['renderer'] == 'RealityKit'
            assert not report['renderer'].get('renderer_issue')
            (folder / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
            print(json.dumps({'report': str(folder / 'report.json'), 'pid': process.pid,
                              'library': str(library), 'socket': socket}), flush=True)
            if os.environ.get('LAB_PAPER_REVIEW') == '1':
                # Root computer-use review owns this disposable app until Command-Q.
                process.wait()
        finally:
            if process is not None and process.poll() is None:
                process.terminate(); process.wait(timeout=15)
            Path(socket).unlink(missing_ok=True)


if __name__ == '__main__':
    main()
