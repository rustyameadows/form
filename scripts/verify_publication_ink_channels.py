#!/usr/bin/env python3
"""Inspect painted PDF operators on declared black-only physical sheet sides.

This checks the actual exported PDF, including invoked Form XObjects. It does
not infer ink from a screenshot or claim press calibration/PDF-X certification.
Requires pypdf; page numbers are one-based physical PDF sides.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path

from pypdf import PdfReader
from pypdf.generic import ContentStream


def resolve(value):
    return value.get_object() if hasattr(value, 'get_object') else value


def color_space(name, resources):
    value = resolve(resources.get('/ColorSpace', {})).get(name, name) if isinstance(name, str) else name
    value = resolve(value)
    if isinstance(value, str):
        return {'/DeviceCMYK': 'cmyk', '/DeviceGray': 'gray', '/DeviceRGB': 'rgb'}.get(value, str(value))
    if value and value[0] == '/ICCBased':
        return {1: 'gray', 3: 'rgb', 4: 'cmyk'}.get(int(resolve(value[1]).get('/N', 0)), 'unknown ICC')
    if value and value[0] == '/CalGray':
        return 'gray'
    return str(value[0]) if value else 'unknown'


def inspect_side(reader, page, number):
    result = {'side': number, 'paint_operations': 0, 'cmyk_operations': 0,
              'gray_operations': 0, 'images': 0, 'issues': []}
    initial = {'fill': ('gray', [0.0]), 'stroke': ('gray', [0.0]), 'text_mode': 0}

    def issue(message):
        if message not in result['issues']:
            result['issues'].append(message)

    def paint(state, channel):
        result['paint_operations'] += 1
        space, values = state[channel]
        try:
            channels = [float(value) for value in values]
        except (ValueError, TypeError):
            issue(f'{channel} has a pattern or nonnumeric color: {space} {values}')
            return
        if space == 'cmyk' and len(channels) == 4:
            result['cmyk_operations'] += 1
            if any(value != 0 for value in channels[:3]):
                issue(f'{channel} paints chromatic CMYK: {channels}')
        elif space == 'gray' and len(channels) == 1:
            result['gray_operations'] += 1
        else:
            issue(f'{channel} paints {space}, not explicit K-only CMYK or gray: {channels}')

    def walk(stream, resources, inherited, active):
        state, saved = copy.deepcopy(inherited), []
        for operands, operator in ContentStream(stream, reader).operations:
            if operator == b'q':
                saved.append(copy.deepcopy(state))
            elif operator == b'Q':
                if saved:
                    state = saved.pop()
                else:
                    issue('Unbalanced graphics state')
            elif operator in (b'cs', b'CS'):
                channel = 'fill' if operator == b'cs' else 'stroke'
                state[channel] = (color_space(operands[0], resources), [])
            elif operator in (b'k', b'K', b'rg', b'RG', b'g', b'G'):
                channel = 'fill' if operator.islower() else 'stroke'
                space = 'cmyk' if operator.lower() == b'k' else 'rgb' if operator.lower() == b'rg' else 'gray'
                state[channel] = (space, list(operands))
            elif operator in (b'sc', b'scn', b'SC', b'SCN'):
                channel = 'fill' if operator.islower() else 'stroke'
                state[channel] = (state[channel][0], list(operands))
            elif operator == b'Tr':
                state['text_mode'] = int(operands[0])
            elif operator in (b'f', b'f*', b'F', b'B', b'B*', b'b', b'b*'):
                paint(state, 'fill')
                if operator in (b'B', b'B*', b'b', b'b*'):
                    paint(state, 'stroke')
            elif operator in (b'S', b's'):
                paint(state, 'stroke')
            elif operator in (b'Tj', b'TJ', b"'", b'"'):
                mode = state['text_mode'] % 4
                if mode in (0, 2):
                    paint(state, 'fill')
                if mode in (1, 2):
                    paint(state, 'stroke')
            elif operator == b'Do':
                reference = resolve(resources.get('/XObject', {}))[operands[0]]
                xobject = resolve(reference)
                key = (getattr(reference, 'idnum', None), getattr(reference, 'generation', None), id(xobject))
                if key in active:
                    issue('Recursive Form XObject')
                    continue
                if xobject.get('/Subtype') == '/Form':
                    nested = resolve(xobject.get('/Resources', resources))
                    group = resolve(xobject.get('/Group', {}))
                    if '/CS' in group and color_space(group['/CS'], nested) not in ('gray', 'cmyk'):
                        issue('Invoked transparency group uses a chromatic blending space')
                    walk(xobject, nested, state, active | {key})
                elif xobject.get('/Subtype') == '/Image':
                    result['images'] += 1
                    mask = xobject.get('/ImageMask', False)
                    if getattr(mask, 'value', mask) is True:
                        paint(state, 'fill')
                    else:
                        issue('Black-only side contains a raster image; vector-only issue acceptance requires inspecting or replacing it')
            elif operator in (b'sh', b'INLINE IMAGE'):
                issue('Black-only side contains a shading or inline image requiring explicit ink inspection')

    walk(page.get_contents(), resolve(page['/Resources']), initial, set())
    if result['paint_operations'] == 0:
        issue('No paint operations found on a declared printed side')
    result['passed'] = not result['issues']
    return result


def audit(path, sides, expected_profile=None, media_mm=None):
    reader = PdfReader(path)
    if any(side < 1 or side > len(reader.pages) for side in sides):
        raise ValueError('A declared black-only side is outside this PDF')
    result = {'pdf': str(path.resolve()), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
              'pdf_sides': len(reader.pages), 'black_only_sides': sides,
              'results': [inspect_side(reader, reader.pages[side - 1], side) for side in sides]}
    intents = []
    for reference in resolve(reader.trailer['/Root']).get('/OutputIntents', []):
        intent = resolve(reference)
        profile = resolve(intent.get('/DestOutputProfile'))
        intents.append({'identifier': str(intent.get('/OutputConditionIdentifier', '')),
                        'embedded_profile_sha256': hashlib.sha256(profile.get_data()).hexdigest() if profile else None})
    result['output_intents'] = intents
    result['profile_matches'] = expected_profile is None or any(i['embedded_profile_sha256'] == expected_profile for i in intents)
    result['media_matches'] = media_mm is None or all(
        abs(float(page.mediabox.width) - media_mm[0] * 72 / 25.4) < 0.001 and
        abs(float(page.mediabox.height) - media_mm[1] * 72 / 25.4) < 0.001 and
        list(page.trimbox) == list(page.mediabox) and list(page.bleedbox) == list(page.mediabox)
        for page in reader.pages)
    result['passed'] = bool(sides) and result['profile_matches'] and result['media_matches'] and all(side['passed'] for side in result['results'])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pdf', type=Path)
    parser.add_argument('--black-sides', required=True, help='Comma-separated one-based physical PDF sides')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--expected-profile-sha256')
    parser.add_argument('--media-mm', help='Exact width,height of every physical side, with matching trim and bleed boxes')
    args = parser.parse_args()
    sides = sorted(set(int(value) for value in args.black_sides.split(',')))
    media = [float(value) for value in args.media_mm.split(',')] if args.media_mm else None
    if media is not None and len(media) != 2:
        parser.error('--media-mm requires width,height')
    result = audit(args.pdf, sides, args.expected_profile_sha256, media)
    rendered = json.dumps(result, indent=2)
    if args.output:
        args.output.write_text(rendered + '\n')
    print(rendered)
    raise SystemExit(0 if result['passed'] else 1)


if __name__ == '__main__':
    main()
