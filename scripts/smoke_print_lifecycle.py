#!/usr/bin/env python3
"""Project-scoped print preparation and real local Orca cancellation.

Use an isolated running FORM_LIBRARY_PATH. No printer connection or print jobs.
"""
import json
import pathlib
import struct
import subprocess
import time
import uuid
from smoke_mcp import Client, OUTPUT


def worker(directory):
    processes = subprocess.check_output(['ps', '-axo', 'pid=,args='], text=True)
    matches = [int(line.strip().split(None, 1)[0]) for line in processes.splitlines()
               if '/Contents/MacOS/OrcaSlicer ' in line and directory in line]
    return matches


def alive(pid):
    return subprocess.run(['ps', '-p', str(pid), '-o', 'pid='], capture_output=True).returncode == 0


def main():
    c = Client()
    report = {}
    try:
        status = c.call('form_status'); assert '/.local/' in status['library_path']
        c.discover(['form_slice', 'form_cancel_slice'])
        assert c.call('form_get_print_setup')['printer_status']['connected'] is False
        a = c.call('form_create_project', {'name': 'Print lifecycle / First project'})
        cube = c.call('form_add_object', {'recipe_id': 'box', 'name': 'First / 20 × 30 × 25 mm',
            'parameters': {'width': 20, 'depth': 30, 'height': 25, 'corner': 2}})
        b = c.call('form_create_project', {'name': 'Print lifecycle / Second project'})
        block = c.call('form_add_object', {'recipe_id': 'box', 'name': 'Second / 55 × 35 × 16 mm',
            'parameters': {'width': 55, 'depth': 35, 'height': 16, 'corner': 0}})
        c.call('form_open_project', {'project_id': a['id']})
        first = c.call('form_open_print', {'object_id': cube['id']})
        assert first['prepared_project_id'] == a['id'] and first['workspace_presented']
        assert all(abs(x-y) < .02 for x, y in zip(first['mesh_size_mm'], [20, 30, 25]))
        assert first['engine_available'], 'The official local Orca engine is required.'
        c.call('form_slice')
        deadline = time.monotonic()+180
        while True:
            complete = c.call('form_get_slice_status')
            if not complete['busy']: break
            assert time.monotonic() < deadline
            time.sleep(.15)
        assert complete['validation_error'] is None and complete['layers'] > 0, complete
        assert complete['prepared_project_id'] == a['id'] and complete['object_id'] == cube['id']
        directory = pathlib.Path(complete['output_directory'])
        stl = (directory/'model.stl').read_bytes(); count = struct.unpack_from('<I', stl, 80)[0]
        assert len(stl) == 84+50*count
        points = [struct.unpack_from('<fff', stl, 84+t*50+12+n*12) for t in range(count) for n in range(3)]
        sizes = [max(p[i] for p in points)-min(p[i] for p in points) for i in range(3)]
        assert all(abs(x-y) < .02 for x, y in zip(sizes, [20, 30, 25]))
        assert (directory/'plate_1.gcode').stat().st_size > 100 and (directory/'prepared.3mf').is_file()
        report['completed_first_slice'] = complete
        c.call('form_open_project', {'project_id': b['id']})
        reset = c.call('form_get_print_setup')
        for key in ['prepared_project_id', 'object_id', 'mesh_size_mm', 'job_id', 'output_directory']:
            assert reset[key] is None, (key, reset)
        assert not reset['workspace_presented'] and not reset['busy'] and reset['layers'] == 0
        report['after_completed_project_switch'] = reset
        c.call('form_set_view', {'view': 'print_object', 'object_id': block['id']})
        current = c.call('form_get_print_setup')
        assert current['object_id'] == block['id'] and current['prepared_project_id'] == b['id']
        assert all(abs(x-y) < .02 for x, y in zip(current['mesh_size_mm'], [55, 35, 16]))
        c.call('form_open_project', {'project_id': str(uuid.uuid4())}, expect_error=True)
        assert c.call('form_get_print_setup') == current
        c.call('form_open_print', {'object_id': 'malformed'}, expect_error=True)
        assert c.call('form_get_print_setup') == current
        c.call('form_set_print_options', {'scalePercent': 150})
        assert abs(c.call('form_get_print_setup')['mesh_size_mm'][0]-82.5) < .02
        c.call('form_undo')
        restored = c.call('form_get_print_setup')
        assert restored['configuration']['scalePercent'] == 100 and abs(restored['mesh_size_mm'][0]-55) < .02
        c.call('form_redo')
        assert c.call('form_get_print_setup')['configuration']['scalePercent'] == 150
        c.call('form_undo')
        c.call('form_update_object', {'object_id': block['id'], 'parameters': {'width': 70}})
        assert abs(c.call('form_get_print_setup')['mesh_size_mm'][0]-70) < .02
        c.call('form_undo'); assert abs(c.call('form_get_print_setup')['mesh_size_mm'][0]-55) < .02
        # Start substantial real local work, then switch projects immediately.
        tall = c.call('form_add_object', {'recipe_id': 'cylinder', 'name': 'Cancellation / local layers',
            'parameters': {'diameter': 120, 'height': 220}})
        c.call('form_open_print', {'object_id': tall['id']})
        c.call('form_set_print_options', {'layerHeight': .08, 'infillPercent': 25})
        running = c.call('form_slice'); assert running['busy']
        pids = worker(running['output_directory']); assert pids, 'Expected a live owned Orca worker.'
        c.call('form_open_project', {'project_id': a['id']})
        after = c.call('form_get_print_setup')
        assert after['prepared_project_id'] is None and after['job_id'] is None
        assert not after['busy'] and not after['workspace_presented'] and after['layers'] == 0
        deadline = time.monotonic()+10
        while any(alive(pid) for pid in pids):
            assert time.monotonic() < deadline, 'The previous local slice did not exit.'
            time.sleep(.05)
        c.call('form_open_print', {'object_id': cube['id']})
        settled = c.call('form_get_print_setup')
        time.sleep(.5)
        assert c.call('form_get_print_setup') == settled, 'Late results changed the new workspace.'
        assert pathlib.Path(running['output_directory']).is_relative_to(pathlib.Path(status['library_path'])/(b['id']+'.form'))
        assert pathlib.Path(complete['output_directory']).is_relative_to(pathlib.Path(status['library_path'])/(a['id']+'.form'))
        report.update(first_project=a['id'], first_object=cube['id'], second_project=b['id'],
            second_object=block['id'], cancellation_object=tall['id'], cancelled_worker_pids=pids,
            cancelled_job=running, after_running_project_switch=after, settled_new_workspace=settled,
            binary_stl_size_mm=sizes, binary_stl_triangles=count,
            print_jobs_sent=0, printer_connections_attempted=0,
            checks='Real official local slice; exact unseen rounded-box dimensions; completed/running project switches; owned-worker exit; no late result; fresh current-object preparation; failed-open preservation; geometry edit/Undo; scale-setting Undo/Redo; project-scoped output paths; no hardware commands')
        for result in [complete, running, after, settled]:
            assert result['print_commands_enabled'] is False and not result['printer_status']['connected']
        (OUTPUT/'print-lifecycle-report.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2))
    finally:
        c.close()


if __name__ == '__main__': main()
