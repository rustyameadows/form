#!/usr/bin/env python3
"""Validate the native AFFINITIES template via the packaged local MCP bridge.

Requires a disposable FORM_LIBRARY_PATH below this repo's .local directory.
No font installation, printer communication, hardware or external model calls.
"""
import copy
import json
import pathlib
import struct
import xml.etree.ElementTree as ET
from smoke_mcp import ROOT, OUTPUT, Client


def uuids(value):
    import uuid
    if isinstance(value, str):
        try:
            return {str(uuid.UUID(value)).upper()}
        except ValueError:
            return set()
    if isinstance(value, list):
        return set().union(*(uuids(item) for item in value))
    if isinstance(value, dict):
        return set().union(*(uuids(k) | uuids(v) for k, v in value.items()))
    return set()


def main():
    c = Client()
    try:
        status = c.call('form_status')
        library = pathlib.Path(status['library_path']).resolve()
        assert library.is_relative_to((ROOT / '.local').resolve()), 'Use an isolated .local studio.'
        tools = c.discover(['form_create_project', 'form_edit_artwork', 'form_export_artwork'])
        schema = next(t for t in tools if t['name'] == 'form_create_project')['inputSchema']
        assert 'affinities' in schema['properties']['template']['enum']
        p = c.call('form_create_project', {'name': 'AFFINITIES / Native study validation', 'template': 'affinities'})
        source = next(o for o in p['objects'] if o['name'] == 'AFFINITIES / 8 × 10 in')
        alternate = next(o for o in p['objects'] if o['name'] == 'AFFINITIES / Outlined alternate')
        editions = [o for o in p['objects'] if o['recipeID'] == 'box']
        assert source['parameters']['width'] == 203.2 and source['parameters']['depth'] == 254
        assert len(editions) == 2 and all(o['artworkSourceID'] == source['id'] for o in editions)
        assert len({o['designID'] for o in editions}) == 1
        title = next(e for e in source['artwork']['elements'] if e.get('name') == 'Editable display wordmark')
        assert title['kind'] == 'text' and title['fontSize'] == 67 and title['typography']['fontName'] == 'Baskerville'
        hidden = next(e for e in alternate['artwork']['elements'] if e.get('name') == 'Editable display wordmark · editable source')
        assert hidden['hidden'] and hidden['typography']['fontName'] == 'Baskerville'
        paths = [e for e in alternate['artwork']['elements'] if e.get('name') == 'Editable display wordmark · outlines']
        assert paths and all(e['kind'] == 'path' for e in paths)
        assert sum(len(contour['nodes']) for e in paths for contour in e['path']['contours']) > 150
        assigned = c.call('form_list_fonts', {'command': 'usage'})
        before = c.call('form_get_project')
        changed = copy.deepcopy(title); changed['fontSize'] = 69
        c.call('form_edit_artwork', {'object_id': source['id'], 'command': 'replace', 'elements': [changed]})
        current = c.call('form_get_project')
        assert next(o for o in current['objects'] if o['id'] == alternate['id']) == alternate
        assert [o for o in current['objects'] if o['id'] != source['id']] == [o for o in before['objects'] if o['id'] != source['id']]
        for edition in editions:
            assert c.call('form_get_artwork', {'object_id': edition['id']}) == c.call('form_get_artwork', {'object_id': source['id']})
        c.call('form_undo')
        restored = c.call('form_get_project')
        assert restored['objects'] == before['objects'] and restored['history'] == before['history']
        outputs = {}; folder = OUTPUT / 'affinities-study'; folder.mkdir(parents=True, exist_ok=True)
        for fmt in ['svg', 'pdf', 'png']:
            path = folder / ('composition.' + fmt)
            result = c.call('form_export_artwork', {'object_id': source['id'], 'format': fmt, 'path': str(path), 'dpi': 150})
            assert result['width_mm'] == 203.2 and result['height_mm'] == 254
            if fmt == 'svg':
                svg = ET.fromstring(path.read_bytes())
                assert float(svg.attrib['width'].removesuffix('mm')) == 203.2
                assert float(svg.attrib['height'].removesuffix('mm')) == 254
            if fmt == 'png':
                assert struct.unpack('>II', path.read_bytes()[16:24]) == (1200, 1500)
            outputs[fmt] = result
        another = c.call('form_create_project', {'name': 'AFFINITIES / Fresh identifiers', 'template': 'affinities'})
        assert p['id'] != another['id'] and uuids(p['objects']).isdisjoint(uuids(another['objects']))
        c.call('form_open_project', {'project_id': p['id']})
        reopened = c.call('form_get_project')
        assert reopened['objects'] == before['objects'] and reopened['history'] == before['history']
        c.call('form_set_view', {'view': 'split', 'object_id': source['id'], 'element_ids': [title['id']]})
        report = {'project_id': p['id'], 'source_id': source['id'], 'alternate_id': alternate['id'],
                  'edition_ids': [o['id'] for o in editions], 'font_usage': assigned, 'exports': outputs,
                  'checks': ['discovery', 'exact frame', 'retained font assignments', 'real recorded outlines with hidden source',
                             'source-only linked updates', 'independent alternate', 'Undo', 'fresh identifiers', 'physical exports', 'saved reopen']}
        (OUTPUT / 'affinities-study-report.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps({'project_id': p['id'], 'checks': report['checks']}, indent=2))
    finally:
        c.close()


if __name__ == '__main__':
    main()
