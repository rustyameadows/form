#!/usr/bin/env python3
"""Author independent Dispatch designs and five genuine Studio compositions.

All document edits use public MCP commands in an owned disposable app/library.
The exported .form is copied only after public save/reopen and process cleanup;
no project JSON is written behind the app. No normal user library is accessed.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import time
import uuid
import zlib

from render_paper_packaging import camera, geometry
from validate_paper_packaging import ROOT, Session


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def bounds(points):
    return ([min(p[i] for p in points) for i in range(3)],
            [max(p[i] for p in points) for i in range(3)])


def source_object(package):
    values = [json.loads(path.read_text()) for path in (package / 'Objects').glob('*.json')]
    matches = [value for value in values if 'Dispatch / Shipping carton' in value.get('name', '')]
    if len(matches) != 1:
        raise ValueError('Choose a saved package with exactly one Dispatch shipping source.')
    source = matches[0]
    assert source['paperConstruction']['kind'] == 'authored'
    assert source.get('artworkSourceID') is None
    assert source['paperConstruction'].get('insideArtworkSourceID') is None
    assert all(not e.get('asset') and not e.get('component') and not e.get('storyFrame')
               for e in source['artwork']['elements']), 'Use portable artwork transfer for external source dependencies.'
    return source


def alternate_artwork(source):
    art = copy.deepcopy(source['artwork'])
    art.update(background='#21478D', backgroundOpacity=1)
    for element in art['elements']:
        element['color'] = '#F4EBD8'
        name = element.get('name', '')
        if name.endswith('-brand'):
            element.update(text='DISPATCH  /  B', x=16, y=12, width=220, height=10, fontSize=18)
        elif name.endswith('-title'):
            element.update(text='NIGHT\nSHIFT', x=16, y=34, width=170, height=82, fontSize=95)
            element.setdefault('typography', {})['fontName'] = 'HelveticaNeue-Bold'
        elif name.endswith('-copy'):
            element.update(text='STUDIO SHIPPING SERIES  /  002\nHANDLE WITH CARE',
                           x=16, y=137, width=175, height=12, fontSize=9)
        elif name.endswith('-rule'):
            element.update(x=225, y=16, width=9, height=84, color='#F1D783')
        elif name.endswith('-seal'):
            element.update(kind='text', text='02', x=200, y=115, width=40, height=30, fontSize=50,
                           typography=dict(fontName='HelveticaNeue-Bold', alignment='left'))
            element.pop('sides', None); element.pop('starInset', None)
    return art


def occurrence(source, number, position, rotation=0):
    return dict(id=str(uuid.uuid4()).upper(), name=f'{source["name"]} / {number}',
                sourceObjectID=source['id'], positionMM=dict(zip(('x', 'y', 'z'), position)),
                rotationDegrees=rotation, visible=True)


def scene_definitions(a, b, height, ground_y):
    stack = lambda source: [occurrence(source, i + 1, [0, ground_y + i * height, 0]) for i in range(5)]
    a_stack = stack(a)
    cluster = [occurrence(a, i + 1, [x, ground_y + i * height, z], angle)
               for i, (x, z, angle) in enumerate([
                   (-75, 15, -12), (-40, -20, 7), (15, 25, -8), (50, -15, 14), (80, 10, -4)])]
    return [
        ('01 / Dispatch A / Five aligned', a_stack, [.4, .2, 1]),
        ('02 / Dispatch A / Reverse view', copy.deepcopy(a_stack), [-.55, .28, -1]),
        ('03 / Dispatch B / Five aligned', stack(b), [.4, .2, 1]),
        ('04 / Dispatch A / Offset cluster', cluster, [.6, .3, 1]),
        ('05 / Dispatch A and B / Design pair', [
            occurrence(a, 1, [-175, ground_y, 0]), occurrence(b, 1, [175, ground_y, 0], -18)
        ], [.3, .28, 1]),
    ]


def scene_points(instances, objects, inspections):
    result = []
    for instance in instances:
        source = copy.deepcopy(objects[instance['sourceObjectID']])
        source['position'] = instance['positionMM']; source['rotation'] = instance['rotationDegrees']
        points, _ = geometry(inspections[source['id']], source)
        result.extend(points)
    return result


def verify_png(path, width, height):
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    assert struct.unpack('>II', data[16:24]) == (width, height)
    position = 8; kinds = []
    while position < len(data):
        length = struct.unpack('>I', data[position:position + 4])[0]
        kind = data[position + 4:position + 8]
        payload = data[position + 8:position + 8 + length]
        crc = struct.unpack('>I', data[position + 8 + length:position + 12 + length])[0]
        assert zlib.crc32(kind + payload) & 0xffffffff == crc
        kinds.append(kind); position += length + 12
        if kind == b'IEND':
            break
    assert position == len(data) and b'IDAT' in kinds and kinds[-1] == b'IEND'
    return hashlib.sha256(data).hexdigest()


def private_app(original, work):
    target = work / 'LAB-dispatch-private.app'
    shutil.copytree(original, target)
    info = target / 'Contents/Info.plist'
    with info.open('rb') as stream:
        values = plistlib.load(stream)
    values['CFBundleIdentifier'] += '.dispatchFixture' + uuid.uuid4().hex[:12]
    with info.open('wb') as stream:
        plistlib.dump(values, stream)
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(target)], check=True, capture_output=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(target)], check=True, capture_output=True)
    return target


def stop(process, socket):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait(timeout=10)
    Path(socket).unlink(missing_ok=True)


def launch(session):
    """Own the process even if startup fails before returning a handle."""
    socket = session.env['LAB_SOCKET_PATH']
    with (session.output / 'native-app.log').open('ab') as log:
        process = subprocess.Popen([str(session.app / 'Contents/MacOS/LAB')], env=session.env,
                                   stdout=log, stderr=log)
    try:
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError('Private LAB exited before opening its bridge.')
            if Path(socket).exists():
                try:
                    result = subprocess.run([str(session.helper), '--call', 'form_status', '{}'],
                        env=session.env, capture_output=True, text=True, timeout=2)
                    if result.returncode == 0:
                        status = json.loads(result.stdout)
                        assert Path(status['library_path']).resolve() == (session.output / 'Library').resolve()
                        return process
                except (subprocess.TimeoutExpired, json.JSONDecodeError):
                    pass
            time.sleep(.15)
        raise TimeoutError('Private LAB bridge did not become ready within 45 seconds.')
    except BaseException:
        stop(process, socket)
        raise


def create_design(session, source, label, position, alternate=False):
    created = session.call('form_construction', dict(command='create',
        definition=copy.deepcopy(source['paperConstruction']['authored']), name=label,
        material_id=source['materialID'], position=position))
    object_id = created['object_id']
    artwork = alternate_artwork(source) if alternate else copy.deepcopy(source['artwork'])
    session.call('form_set_artwork', dict(object_id=object_id, artwork=artwork))
    construction = copy.deepcopy(source['paperConstruction'])
    if alternate:
        for finish in construction.get('finishes', []):
            if finish.get('color'):
                finish['color'] = '#F4EBD8'
            finish['name'] = 'Off-white print / B'
    session.call('form_paper', dict(command='configure', object_id=object_id, definition=construction))
    return object_id


def run(options):
    app, source_package, output = options.app.resolve(), options.source.resolve(), options.output.resolve()
    if output.exists():
        raise ValueError('Output already exists; choose a fresh directory. No example is overwritten.')
    work = options.work.resolve() if options.work else ROOT / '.local/validation' / ('dispatch-studio-' + uuid.uuid4().hex[:12])
    allowed = (ROOT / '.local/validation').resolve()
    if not work.is_relative_to(allowed) or work.exists():
        raise ValueError('Use a new disposable --work directory under .local/validation.')
    assert (app / 'Contents/MacOS/LAB').is_file()
    source = source_object(source_package)
    output.mkdir(parents=True); work.mkdir(parents=True)
    native = private_app(app, work)
    socket = '/tmp/lab-dispatch-' + uuid.uuid4().hex + '.sock'
    session = Session(native, socket, work)
    session.env.update(FORM_LIBRARY_PATH=session.env['LAB_LIBRARY_PATH'], FORM_SOCKET_PATH=socket)
    process = None
    report = dict(status='running', work=str(work), project_id=None, source_package=str(source_package),
                  original_app=str(app), original_executable_sha256=digest(app / 'Contents/MacOS/LAB'),
                  private_executable_sha256=digest(native / 'Contents/MacOS/LAB'),
                  private_helper_sha256=digest(native / 'Contents/MacOS/lab-mcp'),
                  bundle_isolation='Private bundle identifier, ad-hoc signature, unique library and socket; executable signature bytes may differ.',
                  scenes=[], scope='Saved Studio occurrences of two independent editable constructions; no revisions or linked variants.')
    report_path = work / 'dispatch-report.json'
    def checkpoint():
        report_path.write_text(json.dumps(report, indent=2) + '\n')
    checkpoint()
    try:
        process = launch(session)
        report['owned_initial_pid'] = process.pid
        project = session.call('form_create_project', dict(name='Dispatch / Studio compositions', template='blank'))
        report['project_id'] = project['id']; checkpoint()
        a_id = create_design(session, source, 'Dispatch / Design A', [-350, 0, 0])
        b_id = create_design(session, source, 'Dispatch / Design B', [350, 0, 0], alternate=True)
        project = session.call('form_get_project')
        objects = {obj['id']: obj for obj in project['objects']}
        a, b = objects[a_id], objects[b_id]
        assert a['designID'] != b['designID'] and a['id'] != b['id']
        for obj in (a, b):
            assert obj['relationship'] == 'original' and obj.get('parentIterationID') is None
            assert obj.get('artworkSourceID') is None
        assert a['artwork'] == source['artwork'], 'Design A must preserve the exact accepted original artwork.'
        assert a['paperConstruction']['authored'] == b['paperConstruction']['authored'] == source['paperConstruction']['authored']
        assert a['paperConstruction']['stock'] == source['paperConstruction']['stock']
        assert a['artwork'] != b['artwork']

        # Exercise actual public source editing, then restore through one Undo.
        changed = copy.deepcopy(next(e for e in b['artwork']['elements'] if e['kind'] == 'text'))
        changed['text'] = 'Independent B source probe'
        session.call('form_edit_artwork', dict(command='replace', object_id=b_id, elements=[changed]))
        edited = session.call('form_get_project')
        assert next(o for o in edited['objects'] if o['id'] == a_id) == a
        assert next(o for o in edited['objects'] if o['id'] == b_id)['artwork'] != b['artwork']
        session.call('form_undo')
        assert session.call('form_get_project') == project
        report['independent_artwork_edit_undo_exact'] = True

        inspections = {key: session.call('form_construction', dict(command='inspect', object_id=key)) for key in (a_id, b_id)}
        local = copy.deepcopy(a); local['position'] = dict(x=0, y=0, z=0); local['rotation'] = 0
        points, _ = geometry(inspections[a_id], local)
        low, high = bounds(points); height = high[1] - low[1]
        assert height > 0
        report['source_ids'] = dict(A=a_id, B=b_id)
        report['physical_bounds_mm'] = dict(minimum=low, maximum=high, stack_pitch=height)
        report['stack_review'] = 'Nominal stock-slab extents touch at each horizontal layer. No load, crushing or friction simulation is claimed.'
        initial_objects, table_camera = copy.deepcopy(project['objects']), copy.deepcopy(project['camera'])
        saved_scenes = []
        for index, (name, instances, outward) in enumerate(scene_definitions(a, b, height, -low[1]), 1):
            scene = session.call('form_studio_scene', dict(command='create', name=name))
            scene.update(instances=instances, camera=camera(scene_points(instances, objects, inspections), outward),
                         pixels=dict(width=1800, height=1200), lighting='soft-side-v1', surface='Daylight')
            scene = session.call('form_studio_scene', dict(command='save', scene=scene)); saved_scenes.append(scene)
            if index <= 3:
                assert len(instances) == 5 and len({i['sourceObjectID'] for i in instances}) == 1
                assert len({i['id'] for i in instances}) == 5
                assert len({(i['positionMM']['x'], i['positionMM']['z'], i['rotationDegrees']) for i in instances}) == 1
                for first, second in zip(instances, instances[1:]):
                    assert abs(second['positionMM']['y'] - first['positionMM']['y'] - height) < 1e-8
            destination = output / 'renders' / (f'{index:02d}-' + ['aligned-a', 'reverse-a', 'aligned-b', 'offset-cluster', 'design-pair'][index - 1] + '.render')
            destination.parent.mkdir(exist_ok=True)
            exported = session.call('form_export', dict(format='png', scene_id=scene['id'], path=str(destination)))
            record = json.loads(Path(exported['record']).read_text())
            image = Path(exported['path'])
            image_hash = verify_png(image, 1800, 1200)
            assert record['png_sha256'] == image_hash and record['scene'] == scene
            current = session.call('form_get_project')
            assert current['objects'] == initial_objects and current['camera'] == table_camera
            report['scenes'].append(dict(name=name, scene_id=scene['id'], instances=len(instances),
                source_ids=sorted({i['sourceObjectID'] for i in instances}),
                image=str(image.relative_to(output)), png_sha256=image_hash,
                record=str(Path(exported['record']).relative_to(output)), framing_warnings=record.get('framing_warnings', [])))
            checkpoint()
        assert len({s['png_sha256'] for s in report['scenes']}) == 5
        accepted = session.call('form_get_project')
        assert accepted['studioPresentation']['scenes'] == saved_scenes
        # Opening through the public API flushes current accepted data before
        # loading it. Restart then proves the same app-authored package reopens.
        session.call('form_open_project', dict(project_id=project['id']))
        stop(process, socket); process = None
        process = launch(session)
        report['owned_restart_pid'] = process.pid
        session.call('form_open_project', dict(project_id=project['id']))
        reopened = session.call('form_get_project')
        assert reopened['objects'] == initial_objects and reopened['studioPresentation']['scenes'] == saved_scenes
        assert reopened['camera'] == table_camera
        report['reopen_objects_scenes_camera_exact'] = True
        stop(process, socket); process = None
        package = output / 'Dispatch — Studio compositions.form'
        shutil.copytree(work / 'Library' / (project['id'] + '.form'), package)
        report['package'] = package.name
        report['package_files'] = [{ 'path': str(path.relative_to(output)), 'sha256': digest(path)}
                                   for path in sorted(package.rglob('*')) if path.is_file()]
        report['status'] = 'passed'; checkpoint()
        (output / 'validation.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(dict(status='passed', project_id=project['id'], output=str(output), report=str(report_path))))
    except BaseException as error:
        report['status'] = 'failed'; report['error'] = str(error); checkpoint(); raise
    finally:
        stop(process, socket)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=Path(os.environ.get('LAB_APP_PATH', ROOT / 'build/LAB.app')))
    parser.add_argument('--source', type=Path, default=ROOT / 'examples/paper-packaging/Field — Twelve paper studies.form')
    parser.add_argument('--output', type=Path, default=ROOT / 'examples/studio-compositions')
    parser.add_argument('--work', type=Path)
    run(parser.parse_args())


if __name__ == '__main__':
    main()
