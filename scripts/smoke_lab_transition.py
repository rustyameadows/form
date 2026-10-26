#!/usr/bin/env python3
"""LAB navigation/Undo acceptance against an explicitly disposable native library.

Launch LAB with LAB_LIBRARY_PATH and LAB_SOCKET_PATH first. No hardware requests.
"""
import json
import os
from pathlib import Path
from smoke_mcp import Client


def main():
    library = os.environ.get('LAB_LIBRARY_PATH')
    assert library and '.local/lab-transition/' in library, 'Use the isolated LAB transition fixture library.'
    client = Client()
    try:
        initialized = client.rpc('initialize', {'protocolVersion': '2025-11-25'})
        assert initialized['serverInfo']['name'] == 'lab'
        client.discover(['form_status', 'form_set_view', 'form_get_project'])
        status = client.call('form_status')
        assert status['application'] == 'LAB' and status['library_path'] == library
        assert status['primary_environments'] == ['form', 'function', 'fabricate']
        projects = client.call('form_list_projects')
        clock_project = next(p for p in projects if 'MERIDIAN' in p['name'])
        client.call('form_open_project', {'project_id': clock_project['id']})
        project = client.call('form_get_project')
        clock = next(o for o in project['objects'] if o['recipeID'] == 'deskClock')
        client.call('form_set_view', {'view': 'table', 'object_id': clock['id']})
        before = client.call('form_get_project')
        samples = []
        for view in ['function', 'fabricate', 'form', 'studio', 'function', 'form']:
            client.call('form_set_view', {'view': view})
            status = client.call('form_status')
            after = client.call('form_get_project')
            assert status['environment'] == view
            assert status['selected_objects'] == [clock['id']]
            for key in ['objects', 'history', 'materials']:
                assert after.get(key) == before.get(key), (view, key)
            for key in ['orientation', 'target', 'distance', 'projection', 'azimuth', 'elevation']:
                assert after['camera'].get(key) == before['camera'].get(key), (view, key)
            samples.append({'environment': view, 'surfaces': status['design_surfaces']})
        width = clock['parameters']['width']
        client.call('form_update_object', {'object_id': clock['id'], 'parameters': {'width': width + 1}})
        client.call('form_set_view', {'view': 'function'})
        client.call('form_undo')
        current = client.call('form_get_project')
        assert next(o for o in current['objects'] if o['id'] == clock['id'])['parameters']['width'] == width
        client.call('form_set_view', {'view': 'fabricate'})
        client.call('form_redo')
        current = client.call('form_get_project')
        assert next(o for o in current['objects'] if o['id'] == clock['id'])['parameters']['width'] == width + 1
        client.call('form_undo')
        client.call('form_open_print', {'object_id': clock['id']})
        setup = client.call('form_get_print_setup')
        assert setup['workspace_presented'] is True and setup['project_id'] == project['id']
        report = {'application': 'LAB', 'project_count': len(projects), 'project': project['name'],
                  'source_selection_camera_preserved': True, 'shared_undo_redo': True,
                  'native_print_preparation': True, 'navigation': samples}
        target = Path('.local/lab-transition/native-mcp-acceptance.json')
        target.write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report, indent=2))
    finally:
        client.close()


if __name__ == '__main__':
    main()
