#!/usr/bin/env python3
"""Independently inspect the fixture exported by smoke_production_inks.py.

Requires pypdf, Pillow and Poppler's pdftoppm. Reads the supplied report/output
directory and renders only into a temporary folder; no FORM or device connection.
Usage: python scripts/verify_production_inks.py [production-inks-smoke-report.json]
"""
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile

from PIL import Image
from pypdf import PdfReader


def verify(report_path):
    report_path = pathlib.Path(report_path).resolve()
    report = json.loads(report_path.read_text())
    outputs = report['exports']
    composite_path = pathlib.Path(outputs['composite']['path'])
    plates_path = pathlib.Path(outputs['plates']['path'])
    composite = PdfReader(composite_path)
    assert len(composite.pages) == 1
    page = composite.pages[0]
    spaces = page['/Resources']['/ColorSpace']
    profile = spaces['/Process'][1].get_object()
    assert spaces['/Process'][0] == '/ICCBased' and profile['/N'] == 4
    assert hashlib.sha256(profile.get_data()).hexdigest() == report['profile']['sha256']
    spots = [value for value in spaces.values() if value[0] == '/Separation']
    assert {str(value[1]) for value in spots} == {'/FORM Orange', '/FORM Varnish'}
    for value in spots:
        transform = value[3].get_object()
        assert transform['/FunctionType'] == 2 and list(transform['/C0']) == [0] * 4
        expected = [0, .65, 1, .05] if value[1] == '/FORM Orange' else [0] * 4
        assert list(transform['/C1']) == expected and transform['/N'] == 1
    content = page.get_contents().get_data()
    assert b'/Process cs 0.1 0.45 0.8 0.2 scn' in content
    knockout = page['/Resources']['/ExtGState']['/KO']
    assert knockout['/OP'].value is False and knockout['/op'].value is False
    assert knockout['/OPM'] == 0
    for document, count in [(composite, 1), (PdfReader(plates_path), 6)]:
        assert len(document.pages) == count
        for output_page in document.pages:
            assert abs(float(output_page.trimbox.width) - 180 * 72 / 25.4) < 1e-8
            assert abs(float(output_page.trimbox.height) - 120 * 72 / 25.4) < 1e-8
            assert abs(float(output_page.mediabox.width) - 186 * 72 / 25.4) < 1e-8
            assert abs(float(output_page.mediabox.height) - 126 * 72 / 25.4) < 1e-8

    with tempfile.TemporaryDirectory(prefix='form-ink-proof-') as temporary:
        folder = pathlib.Path(temporary)
        for source, name in [(composite_path, 'composite'), (plates_path, 'plate')]:
            subprocess.run(['pdftoppm', '-r', '144', '-png', str(source), str(folder / name)], check=True)
        with Image.open(folder / 'composite-1.png') as rendered:
            preview = rendered.convert('RGB')
        plates = []
        for index in range(1, 7):
            with Image.open(folder / f'plate-{index}.png') as rendered:
                plates.append(rendered.convert('RGB'))

        def sample(image, x, y):
            return image.getpixel((round((x + 3) * 144 / 25.4), round((y + 3) * 144 / 25.4)))

        def coverage(index, x, y, tint):
            actual = sample(plates[index], x, y)[0]
            assert abs(actual - round((1 - tint) * 255)) <= 1, (index, x, y, tint, actual)

        for index, tint in enumerate([0, .25, .5, .75, 1]):
            coverage(4, 24 + index * 31, 35, tint)
        coverage(0, 15, 80, 1)
        coverage(0, 30, 80, 0)
        coverage(4, 30, 80, .5)
        coverage(0, 90, 80, 0)
        coverage(5, 90, 80, 1)
        for index, tint in enumerate([.1, .45, .8, .2]):
            coverage(index, 120, 80, tint)
        assert min(sample(preview, 90, 80)) >= 253
    return {'reader': 'pypdf + Poppler + Pillow', 'profile_sha256': report['profile']['sha256'],
            'spot_names': ['FORM Orange', 'FORM Varnish'], 'ink_map_pages': 6,
            'trim_mm': [180, 120], 'bleed_mm': 3,
            'checks': ['real ICCBased/Separation resources', 'unchanged raw CMYK',
                       '0/25/50/75/100 tints', 'normal knockout', 'white-alternate named ink']}


if __name__ == '__main__':
    default = pathlib.Path(__file__).resolve().parents[1] / '.local/validation/production-inks-smoke-report.json'
    print(json.dumps(verify(sys.argv[1] if len(sys.argv) > 1 else default), indent=2))
