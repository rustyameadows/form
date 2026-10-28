#!/usr/bin/env python3
"""Exercise physical tiled sewing PDFs through the real packaged FORM bridge.

Requires an already-running app with a disposable library below repo/.local.
Creates only validation projects/files. No printer dialog or equipment operation.
"""
import json
import pathlib
import re

from smoke_mcp import Client, OUTPUT, ROOT


def options(width=210, height=297, overlap=10, **margins):
    return {'sheetSize': {'x': width, 'y': height},
            'margins': {key: margins.get(key, 10) for key in ['top', 'right', 'bottom', 'left']},
            'overlap': overlap}


def main():
    client = Client()
    try:
        status = client.call('form_status')
        library = pathlib.Path(status['library_path']).resolve()
        assert library.is_relative_to((ROOT/'.local').resolve()), 'Use a disposable FORM_LIBRARY_PATH below repo/.local.'
        client.discover(['form_edit_artwork', 'form_export_artwork'])
        studio = library/'Studio.json'
        studio_before = studio.read_bytes() if studio.exists() else None
        folder = OUTPUT/'sewing-tiles-smoke'
        folder.mkdir(parents=True, exist_ok=True)
        project = client.call('form_create_project', {'name': 'FIELD / Tiled physical sewing pattern'})
        frame = client.call('form_add_object', {'recipe_id': 'artboard', 'name': 'Measured rounded pouch',
                           'parameters': {'width': 800, 'depth': 750}})
        owner = frame['id']
        client.call('form_edit_artwork', {'object_id': owner, 'command': 'pattern_template',
                    'template': 'roundedPouch', 'pattern_parameters': {'width': 280, 'height': 190, 'corner_radius': 40}})
        source = client.call('form_get_artwork', {'object_id': owner})
        before = client.call('form_get_project')
        a4 = options(overlap=12.5, left=13)
        client.call('form_edit_artwork', {'object_id': owner, 'command': 'pattern_tiles', 'tile_options': a4})
        saved = client.call('form_get_project')
        assert client.call('form_get_artwork', {'object_id': owner})['sewingTiles'] == a4
        client.call('form_undo')
        assert client.call('form_get_project') == before
        client.call('form_redo')
        assert client.call('form_get_project') == saved
        exports = {}
        source_pdf = folder/'authoritative-source.pdf'
        client.call('form_export_artwork', {'object_id': owner, 'pattern_pieces': True,
                    'format': 'pdf', 'path': str(source_pdf)})
        for name, override in [('a4-saved', True), ('letter', options(215.9, 279.4)),
                               ('landscape-custom', options(350, 250, 8, top=12, right=14))]:
            args = {'object_id': owner, 'pattern_pieces': True, 'pattern_tiles': override}
            preflight = client.call('form_export_artwork', {**args, 'format': 'preflight'})
            plan = preflight['tiled']
            assert plan['scale'] == 1 and plan['page_count'] == plan['tile_count']+1 <= 200
            assert plan['rows']*plan['columns'] == plan['tile_count']
            assert plan['calibration_square_mm'] == 50 and plan['calibration_rule_mm'] == 100
            path = folder/(name+'.pdf')
            result = client.call('form_export_artwork', {**args, 'format': 'pdf', 'path': str(path), 'dpi': 600})
            assert result['tiled'] == plan
            data = path.read_bytes()
            assert data.startswith(b'%PDF') and len(data)>1000
            boxes = re.findall(rb'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)', data)
            assert boxes and all(abs(float(w)/(72/25.4)-plan['sheet_width_mm'])<0.002 and
                                 abs(float(h)/(72/25.4)-plan['sheet_height_mm'])<0.002 for w,h in boxes)
            (folder/(name+'-metadata.json')).write_text(json.dumps(result, indent=2)+'\n')
            exports[name] = result
            assert client.call('form_get_project') == saved
        # Invalid or mixed requests cannot replace an approved file or edit source.
        target = folder/'approved.pdf'
        sentinel = b'Approved physical output'
        target.write_bytes(sentinel)
        for extra in [{'pattern_tiles': options(1, 2)}, {'pattern_tiles': {'overlap': 10}},
                      {'pattern_tiles': options(overlap=True)}, {'pattern_tiles': None},
                      {'format': 'svg'}, {'dpi': True}, {'roles': ['cut']}, {'ink_output': 'preview'}, {'cut_layout': True}]:
            client.call('form_export_artwork', {'object_id': owner, 'pattern_pieces': True,
                        'pattern_tiles': True, 'format': 'pdf', 'path': str(target), **extra}, expect_error=True)
            assert target.read_bytes() == sentinel
            assert client.call('form_get_project') == saved
        client.call('form_export_artwork', {'object_id': owner, 'pattern_tiles': True,
                    'format': 'pdf', 'path': str(target)}, expect_error=True)
        client.call('form_edit_artwork', {'object_id': owner, 'command': 'pattern_tiles',
                    'tile_options': options(overlap=41)}, expect_error=True)
        assert client.call('form_get_project') == saved
        client.call('form_edit_artwork', {'object_id': owner, 'command': 'pattern_tiles', 'tile_options': None})
        assert 'sewingTiles' not in client.call('form_get_artwork', {'object_id': owner})
        client.call('form_undo')
        assert client.call('form_get_project') == saved
        client.call('form_open_project', {'project_id': project['id']})
        reopened = client.call('form_get_artwork', {'object_id': owner})
        assert reopened['sewingTiles'] == a4
        assert reopened['elements'] == source['elements'] and reopened['sewingSeams'] == source['sewingSeams']
        assert (studio.read_bytes() if studio.exists() else None) == studio_before
        report = {'project_id': project['id'], 'source_object_id': owner, 'exports': exports,
                  'source_pdf': str(source_pdf), 'checks': ['actual-size A4/Letter/custom PDFs', 'preflight page plan',
                  'immutable one-shot overrides and physical source', 'saved options Undo/Redo/clear/reopen',
                  'invalid and mixed-selector rollback', 'approved-file preservation', 'unchanged Studio library'],
                  'equipment_operations': 0}
        (OUTPUT/'sewing-tiles-smoke-report.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report, indent=2))
    finally:
        client.close()


if __name__ == '__main__':
    main()
