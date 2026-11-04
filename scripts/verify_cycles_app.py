#!/usr/bin/env python3
"""Exercise the ordinary running LAB renderer through its packaged MCP helper.

Requires an explicitly selected disposable review project/shot/material. Changes
to optical values are undone and verified; no manufacturing operation is sent.
This intentionally terminates one identified render helper, never LAB itself.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import uuid

from cycles_project_reads import ProjectReader


def verify_runtime_provenance(record, app):
    """Compare portable export identities with this actual signed installation."""
    def identity(relative, maximum=1_073_741_824):
        path = app / relative
        assert path.is_file() and path.stat().st_size <= maximum, relative
        digest = hashlib.sha256()
        count = 0
        with path.open('rb') as stream:
            for block in iter(lambda: stream.read(1_048_576), b''):
                count += len(block)
                assert count <= maximum, relative
                digest.update(block)
        return dict(sha256=digest.hexdigest(), size_bytes=count)

    runtime = record['runtime_provenance']
    assert runtime['version'] == 1
    application, renderer = runtime['application'], runtime['renderer']
    for value, relative in [(application['executable'], 'Contents/MacOS/LAB'),
                            (renderer['helper'], 'Contents/Helpers/lab-cycles-render')]:
        assert value == identity(relative), 'Export runtime binary differs: '+relative
    metadata = [
        (application['packaged_build'], 'Contents/Resources/LABBuild.json'),
        (renderer['engine_provenance'], 'Contents/Resources/ThirdPartyNotices/Cycles/LAB-CYCLES-PROVENANCE.json'),
        (renderer['display_transform'], 'Contents/Resources/Cycles/LAB-sRGB-v1.json')]
    for value, relative in metadata:
        expected = identity(relative, 2_097_152)
        assert value['status'] == 'available', 'Installed metadata must be identified: '+relative
        assert all(value[key] == expected[key] for key in expected), 'Export metadata differs: '+relative
    build = json.loads((app / metadata[0][1]).read_text())
    engine = json.loads((app / metadata[1][1]).read_text())
    display = json.loads((app / metadata[2][1]).read_text())
    # LABBuild identifies the build before packaging/signing; its embedded
    # executable checksums are deliberately not compared with signed binaries.
    assert application['packaged_build']['metadata'] == build
    assert renderer['engine_provenance']['source_commit'] == engine['source_commit'] == record['engine_revision']
    assert renderer['engine_provenance']['dependency_commit'] == engine['dependency_commit']
    assert renderer['engine_provenance']['protocol_version'] == engine['protocol_version'] == 1
    assert renderer['display_transform']['id'] == display['id'] == record['display_transform'] == 'LAB-sRGB-v1'
    assert display['loadedByRenderer'] is False
    assert engine['source_inputs']['Native/LabCycles/LAB-sRGB-v1.json'] == renderer['display_transform']['sha256']
    return dict(status='passed', app_sha256=application['executable']['sha256'],
                helper_sha256=renderer['helper']['sha256'], packaged_build_id=build['build_id'],
                engine_provenance_sha256=renderer['engine_provenance']['sha256'],
                display_transform_sha256=renderer['display_transform']['sha256'])


class Check:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        self.helper = args.app.resolve() / 'Contents/MacOS/lab-mcp'
        self.renderer = args.app.resolve() / 'Contents/Helpers/lab-cycles-render'
        self.jobs = []
        self.evidence = {}

    def call(self, name, arguments=None, error=False):
        request = dict(jsonrpc='2.0', id=1, method='tools/call', params=dict(name=name, arguments=arguments or {}))
        result = subprocess.run([str(self.helper)], input=json.dumps(request)+'\n', text=True, capture_output=True, timeout=240, check=True)
        envelope = json.loads(result.stdout)
        if 'error' in envelope:
            raise RuntimeError(envelope['error'])
        value = envelope['result']
        with (self.output / 'operations.jsonl').open('a') as stream:
            stream.write(json.dumps(dict(time=time.time(), request=request, response=value))+'\n')
        if bool(value.get('isError')) != error:
            raise RuntimeError(f'{name}: unexpected error state: {value}')
        if error:
            return value
        content = next(c['text'] for c in value['content'] if c['type'] == 'text')
        return json.loads(content)

    def protected_project(self):
        return ProjectReader(self.call).snapshot(protect=True, scalar_sections=('studioPresentation',))

    def current_project_id(self):
        response = self.call('form_get_project', dict(view='summary', offset=0, limit=1))
        _, metadata = ProjectReader.envelope(response, 'summary')
        return metadata['id']

    def open_project(self, project_id):
        response = self.call('form_open_project', dict(project_id=project_id, view='summary', offset=0, limit=1))
        _, metadata = ProjectReader.envelope(response, 'summary')
        if metadata['id'] != project_id:
            raise RuntimeError('Opened project identity differs from the explicit target')

    def start(self, label, samples=4096, denoise=False):
        destination = self.output / (label+'.render')
        value = self.call('form_render', dict(command='start', project_id=self.args.project_id,
            target='shot', shot_id=self.args.shot_id, path=str(destination), pixels=dict(width=640, height=480),
            settings=dict(device='metal', samples=samples, noiseThreshold=0, denoise=denoise)))
        self.jobs.append(value['job_id'])
        return value

    def wait(self, value, predicate, timeout=90):
        deadline = time.monotonic()+timeout
        while not predicate(value):
            if time.monotonic() > deadline:
                raise RuntimeError('Render status deadline exceeded: '+str(value))
            time.sleep(.1)
            value = self.call('form_render', dict(command='status', job_id=value['job_id']))
        return value

    def terminal(self, value):
        return self.wait(value, lambda item: item['state'] not in ('preparing', 'rendering'), 180)

    def rendering(self, value):
        value = self.wait(value, lambda item: item['state'] not in ('preparing', 'rendering') or item.get('sample', 0) > 0)
        if value['state'] != 'rendering':
            raise RuntimeError('Expected an active sampled render: '+str(value))
        return value

    def verify_result(self, value):
        assert value['state'] == 'completed', value
        result = self.call('form_render', dict(command='result', job_id=value['job_id']))
        record = json.loads(Path(result['record']).read_text())
        for key in ('png', 'exr'):
            data = Path(result[key]).read_bytes()
            assert hashlib.sha256(data).hexdigest() == record[key+'_sha256']
        assert Path(result['png']).read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
        assert Path(result['exr']).read_bytes()[:4] == b'v/1\x01'
        assert record['device'] == 'metal' and record['display_transform'] == 'LAB-sRGB-v1'
        assert record['denoiser'] != 'none'
        self.evidence['runtime_provenance'] = verify_runtime_provenance(record, self.args.app.resolve())
        return result

    def run(self):
        self.call('form_list_recipes')
        before = self.protected_project()
        assert before['id'] == self.args.project_id, 'Open the explicit review project before running.'
        material = next(m for m in before['materials'] if m['id'] == self.args.material_id)
        self.evidence['capabilities'] = self.call('form_render', dict(command='capabilities'))
        try:
            job = self.start('cancel-immediately')
            self.evidence['initial_state'] = job
            cancelled = self.call('form_render', dict(command='cancel', job_id=job['job_id']))
            assert cancelled['state'] == 'cancelled'
            assert not (self.output/'cancel-immediately.render').exists()
            self.evidence['cancel_immediately'] = cancelled

            job = self.rendering(self.start('helper-crash'))
            processes = subprocess.check_output(['/bin/ps', '-axo', 'pid=,args='], text=True)
            matches = []
            for line in processes.splitlines():
                parts = line.strip().split(None, 1)
                if len(parts) == 2 and parts[1].startswith(str(self.renderer)+' '):
                    matches.append((int(parts[0]), parts[1]))
            assert len(matches) == 1, 'Expected exactly one identified bundled render helper.'
            pid, command = matches[0]
            os.kill(pid, signal.SIGKILL)
            failed = self.terminal(job)
            assert failed['state'] == 'failed' and not (self.output/'helper-crash.render').exists()
            self.evidence['helper_crash'] = dict(pid=pid, command=command, result=failed)
            assert self.current_project_id() == before['id']

            recovered = self.verify_result(self.terminal(self.start('recovered', samples=32, denoise=True)))
            self.evidence['recovery'] = recovered
            destination = Path(recovered['png']).parent
            original_hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in destination.iterdir() if p.is_file()}
            rejection = self.call('form_render', dict(command='start', project_id=self.args.project_id,
                target='shot', shot_id=self.args.shot_id, path=str(destination)), error=True)
            assert original_hashes == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in destination.iterdir() if p.is_file()}
            self.evidence['destination_preserved'] = rejection

            if self.args.switch_project_id:
                job = self.rendering(self.start('project-change'))
                try:
                    self.open_project(self.args.switch_project_id)
                    assert self.current_project_id() == self.args.switch_project_id
                    invalidated = self.terminal(job)
                    assert invalidated['state'] == 'failed' and not (self.output/'project-change.render').exists()
                    self.evidence['project_change'] = invalidated
                finally:
                    self.open_project(self.args.project_id)
                    assert self.current_project_id() == self.args.project_id

            if self.args.missing_asset:
                asset = self.args.missing_asset.resolve(strict=True)
                assert asset.parent.name == 'Assets' and asset.parent.parent.name == self.args.project_id+'.form', 'Only a review-project asset may be temporarily moved.'
                original_hash = hashlib.sha256(asset.read_bytes()).hexdigest()
                held = asset.with_name(asset.name+'.validation-held-'+str(uuid.uuid4()))
                asset.rename(held)
                try:
                    value = self.terminal(self.start('missing-asset', samples=8))
                    assert value['state'] == 'failed' and not (self.output/'missing-asset.render').exists()
                    self.evidence['missing_asset'] = dict(asset=asset.name, sha256=original_hash, result=value)
                finally:
                    held.rename(asset)
                    assert hashlib.sha256(asset.read_bytes()).hexdigest() == original_hash

            job = self.rendering(self.start('source-edit'))
            edited = False
            try:
                new_roughness = .23 if material['roughness'] != .23 else .63
                self.call('form_material', dict(command='update', material_id=material['id'], patch=dict(roughness=new_roughness)))
                edited = True
                invalidated = self.terminal(job)
                assert invalidated['state'] == 'failed' and not (self.output/'source-edit.render').exists()
                self.evidence['source_invalidated'] = invalidated
                self.call('form_undo')
                edited = False
                restored = ProjectReader(self.call).snapshot()
                assert restored['materials'] == before['materials']
                self.call('form_redo')
                edited = True
                redone = ProjectReader(self.call).snapshot()
                assert next(m for m in redone['materials'] if m['id'] == material['id'])['roughness'] == new_roughness
            finally:
                if edited:
                    self.call('form_undo')

            after = self.protected_project()
            fields = ('objects', 'materials', 'recipes', 'notes', 'camera', 'studioPresentation')
            matches = {field: after.get(field) == before.get(field) for field in fields}
            assert all(matches.values()), matches
            self.evidence['project_preserved'] = matches
            self.evidence['status'] = 'passed'
        except BaseException as error:
            self.evidence['status'] = 'failed'
            self.evidence['error'] = str(error)
            raise
        finally:
            for identifier in self.jobs:
                try:
                    self.call('form_render', dict(command='cancel', job_id=identifier))
                except Exception:
                    pass
            (self.output/'report.json').write_text(json.dumps(self.evidence, indent=2)+'\n')
        print(json.dumps(self.evidence, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--project-id', required=True)
    parser.add_argument('--shot-id', required=True)
    parser.add_argument('--material-id', required=True)
    parser.add_argument('--switch-project-id', help='Optional existing project to open briefly during a render; the review project is restored.')
    parser.add_argument('--missing-asset', type=Path, help='Optional review-project Assets file to move temporarily, then restore exactly.')
    parser.add_argument('--output', type=Path, required=True)
    Check(parser.parse_args()).run()
