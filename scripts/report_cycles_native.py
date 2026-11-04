#!/usr/bin/env python3
"""Make a portable page from retained, actual native LAB validation captures."""
import argparse
import html
import json
from pathlib import Path
from urllib.parse import quote


def report(directory: Path):
    record = json.loads((directory / 'report.json').read_text())
    captures = record.get('captures', [])
    if not captures:
        captures=[(Path(name).stem,Path(name).stem.replace('-', ' ')) for name in record.get('native_captures', [])
                  if Path(name).name==name and Path(name).suffix=='.png']
    if not captures:
        captures=[(Path(name).stem,Path(name).stem.replace('-', ' ')) for name in record.get('evidence_files', {})
                  if Path(name).name==name and Path(name).suffix=='.png']
    cards = []
    for name, caption in captures:
        if Path(name).name != name:
            raise ValueError('Capture names must identify local files.')
        if (directory / (name + '.png')).exists():
            link = quote(name, safe='')
            accessibility=f' <a href="{link}.txt">Accessibility capture</a>' if (directory/(name+'.txt')).is_file() else ''
            cards.append(f'<figure><a href="{link}.png"><img loading="lazy" src="{link}.png" alt="{html.escape(caption)}"></a>'
                         f'<figcaption>{html.escape(caption)}{accessibility}</figcaption></figure>')
    limitations = ''.join(f'<li>{html.escape(item)}</li>' for item in record.get('limitations', []))
    document = '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>LAB native rendering validation</title><style>
body{font:16px/1.5 -apple-system,BlinkMacSystemFont,sans-serif;margin:32px;color:#222;background:#f7f7f5}
main{max-width:1500px;margin:auto}h1{font-size:30px}a{color:#a32d68}code{overflow-wrap:anywhere}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,550px),1fr));gap:24px}
figure{margin:0;background:white;border:1px solid #ddd;border-radius:10px;overflow:hidden}img{width:100%;display:block}figcaption{padding:16px}
pre{font-size:13px;white-space:pre-wrap;background:white;border:1px solid #ddd;padding:20px;border-radius:8px}
</style><main><a href="../index.html">Material review</a><h1>Native rendering validation</h1>
<p>These are retained screenshots, accessibility captures, checks and failures from the single ordinary LAB installation. Recorded outcomes are shown explicitly; material reference acceptance is assessed separately.</p>
'''
    executable=record.get('executableSHA256')
    if not executable and record.get('installation'):
        path=directory/record['installation']
        if path.is_file():executable=json.loads(path.read_text()).get('sha256',{}).get('Contents/MacOS/LAB')
    if executable:document += '<p>Installed executable SHA-256: <code>' + html.escape(executable) + '</code>.</p>'
    if record.get('status'):document += '<p>Recorded status: <strong>'+html.escape(record['status'])+'</strong>.</p>'
    for field in ('installation','source_test_matrix','original_project_preservation'):
        value=record.get(field)
        if isinstance(value,str) and not Path(value).is_absolute() and (directory/value).is_file():
            document+='<p><a href="'+quote(value)+'">'+html.escape(field.replace('_',' '))+'</a></p>'
    document += '<p><a href="report.json">Complete record, checks and evidence hashes</a></p><ul>' + limitations + '</ul>'
    document += '<div class="grid">' + ''.join(cards) + '</div><h2>Recorded checks</h2><pre>'
    document += html.escape(json.dumps(record.get('checks',record), indent=2)) + '</pre></main></html>\n'
    (directory / 'index.html').write_text(document)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    report(parser.parse_args().directory)
