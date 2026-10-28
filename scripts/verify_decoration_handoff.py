#!/usr/bin/env python3
"""Independently check a FORM decoration packet using Python's standard library.

Checks file hashes/classification, physical SVG/PNG dimensions and CMYK resources.
This checks digital handoff integrity, not cutter/RIP/press compatibility.
"""
import hashlib
import json
import math
import pathlib
import re
import struct
import xml.etree.ElementTree as ET
import zlib


def sha(data):
    return hashlib.sha256(data).hexdigest()


def png_info(data):
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    pos, result = 8, {}
    while pos < len(data):
        length, = struct.unpack('>I', data[pos:pos + 4])
        kind, payload = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + length]
        checksum, = struct.unpack('>I', data[pos + 8 + length:pos + 12 + length])
        assert zlib.crc32(kind + payload) & 0xffffffff == checksum
        if kind == b'IHDR':
            width, height, bits, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', payload)
            result.update(width=width, height=height, bit_depth=bits, color_type=color, interlace=interlace)
        if kind == b'pHYs':
            x, y, unit = struct.unpack('>IIB', payload)
            assert unit == 1 and x > 0 and y > 0, 'PNG must carry a physical density.'
            result.update(dpi_x=x * .0254, dpi_y=y * .0254,
                          width_mm=result['width'] * 1000 / x, height_mm=result['height'] * 1000 / y)
        pos += 12 + length
        if kind == b'IEND':
            break
    assert 'dpi_x' in result and result['color_type'] in (4, 6), 'Use an alpha-bearing physical PNG.'
    return result


def svg_info(data):
    root = ET.fromstring(data)
    ns = {'s': 'http://www.w3.org/2000/svg'}
    assert root.tag == '{http://www.w3.org/2000/svg}svg'
    assert root.attrib['width'].endswith('mm') and root.attrib['height'].endswith('mm')
    width, height = float(root.attrib['width'][:-2]), float(root.attrib['height'][:-2])
    bounds = [float(n) for n in root.attrib['viewBox'].split()]
    assert bounds == [0, 0, width, height]
    assert root.find('.//s:text', ns) is None, 'Cut text must be outlined.'
    assert root.find('.//s:image', ns) is None
    paths = root.findall('.//s:path', ns)
    assert paths and all(p.attrib.get('d') for p in paths)
    for path in paths:
        commands = path.attrib['d']
        assert len(re.findall('[Mm]', commands)) == len(re.findall('[Zz]', commands)), 'Every cut/reference contour must be closed.'
    return dict(width_mm=width, height_mm=height, paths=len(paths))


def verify_packet(folder):
    folder = pathlib.Path(folder)
    manifest = json.loads((folder / 'Manifest.json').read_bytes())
    assert manifest['kind'] == 'decoration'
    for name in ['white_channel_generated', 'screening_generated', 'thermal_recipe_generated', 'machine_contacted', 'inventory_deducted']:
        assert manifest[name] is False
    assert manifest['equipment_compatibility'] == 'unverified'
    for name, entry in manifest['files'].items():
        path = pathlib.PurePosixPath(name)
        assert not path.is_absolute() and '..' not in path.parts
        data = (folder / name).read_bytes()
        assert len(data) == entry['bytes'] and sha(data) == entry['sha256'], name
    canonical = dict(manifest)
    expected = canonical.pop('packet_digest')
    # Match Foundation JSONSerialization's compact sorted-key UTF-8/slash escaping.
    encoded = json.dumps(canonical, sort_keys=True, separators=(',', ':'), ensure_ascii=False).replace('/', '\\/').encode()
    assert sha(encoded) == expected
    revision = json.loads((folder / 'Revision.json').read_bytes())
    source = json.loads((folder / 'Source.json').read_bytes())
    assert sha((folder / 'Revision.json').read_bytes()) == manifest['revision_digest']
    assert sha((folder / 'Source.json').read_bytes()) == manifest['source_digest'] == revision['sourceDigest']
    assert revision['jobID'] == manifest['job_id']
    options = revision['options']
    actual = {}
    for file in revision['files']:
        name, role = file['name'], file['role']
        data = (folder / name).read_bytes()
        assert sha(data) == file['digest'] and len(data) == file['bytes']
        if name.endswith('.svg') and role != 'source':
            actual[name] = svg_info(data)
            padding = options['weedMargin'] if name.startswith('Cut-') else 0
            assert math.isclose(actual[name]['width_mm'], revision['width'] + 2 * padding)
            assert math.isclose(actual[name]['height_mm'], revision['height'] + 2 * padding)
        if name.endswith('.png') and role != 'source':
            actual[name] = png_info(data)
            assert abs(actual[name]['width_mm'] - revision['width']) < .03
            assert abs(actual[name]['height_mm'] - revision['height']) < .03
        if name == 'Color-Process.pdf':
            assert b'/ICCBased' in data and b'/N 4' in data
            assert b'/Separation' not in data and b'/DeviceN' not in data
    return dict(process=options['process'], packet_digest=expected, files=len(manifest['files']),
                source_objects=len(source['objects']), physical_files=actual,
                scope='Digital hashes/physical dimensions; no physical-machine, material or thermal validation.')


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=pathlib.Path)
    print(json.dumps(verify_packet(parser.parse_args().folder), indent=2))
