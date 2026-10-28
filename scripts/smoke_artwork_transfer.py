#!/usr/bin/env python3
"""Guarded packaged MCP portable artwork transfer. Never accesses a pasteboard.

Set FORM_TRANSFER_TEST_LIBRARY to the exact disposable active library below
.local/validation. Run only after parent installs the candidate against it.
"""
import copy
import hashlib
import json
import os
import pathlib
import struct
import subprocess
import uuid
import zlib
from smoke_mcp import Client, ROOT, OUTPUT


class TransferClient(Client):
    def __init__(self):
        executable = os.environ.get('FORM_TRANSFER_MCP_BINARY')
        if executable:
            self.sequence = 0
            self.process = subprocess.Popen([executable], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        else:
            super().__init__()


def uid():
    return str(uuid.uuid4()).upper()


def png():
    def chunk(kind, payload):
        return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload) & 0xffffffff)
    pixels = b''.join(b'\0' + bytes([230, 118, 60, 255]) * 8 for _ in range(6))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 8, 6, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b'')


def main():
    expected = os.environ.get('FORM_TRANSFER_TEST_LIBRARY')
    assert expected, 'Set FORM_TRANSFER_TEST_LIBRARY to the exact disposable active library.'
    expected = pathlib.Path(expected).resolve()
    assert expected.is_relative_to(OUTPUT.resolve()) and 'transfer48' in expected.name, 'Use a dedicated transfer48 library under .local/validation.'
    client = TransferClient()
    try:
        status = client.call('form_status')
        assert pathlib.Path(status['library_path']).resolve() == expected, 'Active FORM library does not match the explicit disposable guard.'
        tools = client.discover(['form_edit_artwork', 'form_component', 'form_import_image'])
        schema = next(t for t in tools if t['name'] == 'form_edit_artwork')['inputSchema']
        assert {'transfer', 'transfer_export', 'transfer_import'}.issubset(schema['properties']['command']['enum'])
        output = OUTPUT / ('artwork-transfer-' + uuid.uuid4().hex[:8])
        output.mkdir()
        image_file = output / 'original.png'
        image_bytes = png()
        image_file.write_bytes(image_bytes)
        source = client.call('form_create_project', {'name': 'TRANSFER / Source', 'template': 'blank'})
        frame = client.call('form_add_object', {'recipe_id': 'artboard', 'name': 'Transfer source', 'parameters': {'width': 180, 'depth': 120}})
        group, mask, leaf, text = uid(), uid(), uid(), uid()
        elements = [
            {'id': group, 'kind': 'group', 'x': 15, 'y': 15, 'width': 70, 'height': 50, 'contentSize': {'x': 70, 'y': 50}, 'rotation': 17, 'text': '', 'color': '#FFFFFF', 'fontSize': 14},
            {'id': mask, 'kind': 'ellipse', 'parentID': group, 'x': 0, 'y': 0, 'width': 65, 'height': 45, 'text': '', 'color': '#FFFFFF', 'fontSize': 14},
            {'id': leaf, 'kind': 'rectangle', 'parentID': group, 'clipID': mask, 'x': 2, 'y': 3, 'width': 60, 'height': 40, 'name': 'Literal ' + group, 'text': '', 'color': '#D47745', 'fontSize': 14},
            {'id': text, 'kind': 'text', 'x': 10, 'y': 85, 'width': 160, 'height': 25, 'text': group, 'color': '#203A4A', 'fontSize': 18, 'typography': {'fontName': '.AppleSystemUIFont'}},
        ]
        client.call('form_set_artwork', {'object_id': frame['id'], 'artwork': {'background': '#FFFFFF', 'backgroundOpacity': 0, 'bleed': 3, 'elements': elements}})
        component = client.call('form_component', {'command': 'create', 'object_id': frame['id'], 'element_ids': [group], 'name': 'Portable mark'})
        client.call('form_text_style', {'command': 'create', 'object_id': frame['id'], 'element_ids': [text], 'name': 'Transfer heading', 'font_size': 18.0, 'typography': {'fontName': '.AppleSystemUIFont'}})
        client.call('form_import_image', {'object_id': frame['id'], 'path': str(image_file), 'x': 100, 'y': 10, 'width': 50, 'height': 38})
        before = client.call('form_get_project')
        bundle_file = output / 'complete.formart'
        exported = client.call('form_edit_artwork', {'command': 'transfer_export', 'object_id': frame['id'], 'transfer_path': str(bundle_file)})
        assert client.call('form_get_project') == before, 'Read-only export changed source/history/camera.'
        assert bundle_file.read_bytes().startswith(b'FORMART1') and hashlib.sha256(bundle_file.read_bytes()).hexdigest() == exported['sha256']
        client.call('form_edit_artwork', {'command': 'transfer_export', 'object_id': frame['id'], 'transfer_path': str(bundle_file)}, expect_error=True)
        assert client.call('form_get_project') == before
        source_art = next(o['artwork'] for o in before['objects'] if o['id'] == frame['id'])
        original_assets = [e['asset'] for e in source_art['elements'] if e['kind'] == 'image']
        for name in original_assets:
            (expected / (source['id'] + '.form') / 'Assets' / name).unlink()
        destination = client.call('form_create_project', {'name': 'TRANSFER / Destination', 'template': 'blank'})
        target = client.call('form_add_object', {'recipe_id': 'artboard', 'name': 'Transfer destination', 'parameters': {'width': 180, 'depth': 120}})
        baseline = client.call('form_get_project')
        args = {'command': 'transfer_import', 'object_id': target['id'], 'transfer_path': str(bundle_file), 'offset_x': 10, 'offset_y': 10}
        imported = client.call('form_edit_artwork', args)
        current = client.call('form_get_project')
        assert len(current['history']) == len(baseline['history']) + 1
        assert len(imported['added_component_objects']) == 1 and len(imported['imported_assets']) == 1
        art = next(o['artwork'] for o in current['objects'] if o['id'] == target['id'])
        assert next(e for e in art['elements'] if e['kind'] == 'text')['text'] == group, 'Literal UUID text was rewritten.'
        image = next(e for e in art['elements'] if e['kind'] == 'image')
        target_asset = expected / (destination['id'] + '.form') / 'Assets' / image['asset']
        assert target_asset.read_bytes() == image_bytes
        assert art['elements'][0]['component']['sourceObjectID'] != component['source_object_id']
        client.call('form_undo'); assert client.call('form_get_project') == baseline and target_asset.read_bytes() == image_bytes
        client.call('form_redo'); assert client.call('form_get_project') == current
        malformed = output / 'malformed.formart'; malformed.write_bytes(b'FORMART1\xff\xff\xff\xff')
        bad = dict(args, transfer_path=str(malformed))
        client.call('form_edit_artwork', bad, expect_error=True); assert client.call('form_get_project') == current
        client.call('form_batch', {'operations': [{'name': 'form_edit_artwork', 'arguments': args}]}, expect_error=True); assert client.call('form_get_project') == current
        client.call('form_open_project', {'project_id': destination['id']}); reopened = client.call('form_get_project')
        assert next(o['artwork'] for o in reopened['objects'] if o['id'] == target['id']) == art
        report = {'source_project_id': source['id'], 'destination_project_id': destination['id'], 'bundle': exported, 'import': imported, 'source_assets_deleted_before_import': True, 'original_image_sha256': hashlib.sha256(image_bytes).hexdigest(), 'clipboard_accessed': False, 'one_undo_redo_exact': True, 'invalid_input_and_batch_rollback_exact': True, 'reopen_source_exact': True, 'tool_count': len(tools)}
        (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps({'output': str(output), 'result': 'passed'}, indent=2))
    finally:
        client.close()


if __name__ == '__main__':
    main()
