#!/usr/bin/env python3
"""Plan or run the ordered public-MCP material review captures.

Default is file-only. Each child restores the original project, and a failed
child stops the sequence. Final captures are a separate explicit stage so a
diagnostic run cannot silently proceed past unresolved visual discrepancies.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def commands(stage, app, output):
    base = ['--app', str(app.resolve()), '--output', str(output.resolve())]
    diagnostic = base + ['--samples', '64', '--width', '1200', '--height', '900']
    final = base + ['--samples', '512', '--width', '3000', '--height', '2000']
    def command(script, arguments):
        return [sys.executable, str(ROOT/'scripts'/script)] + arguments
    if stage == 'diagnostics':
        return [
            command('author_cycles_curved_attachment.py', diagnostic + ['--apply']),
            command('author_cycles_materials.py', diagnostic + ['--apply', '--render', '--case', 'knit', '--view', 'grazing']),
            command('author_cycles_materials.py', diagnostic + ['--apply', '--render', '--case', 'cotton', '--case', 'vellum', '--view', 'whole']),
            command('author_cycles_details.py', diagnostic + ['--detail', 'satin-faces']),
        ]
    if stage == 'final':
        return [command('author_cycles_materials.py', final + ['--apply', '--render'])]
    return [command('author_cycles_details.py', final), command('author_cycles_optics.py', final)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', choices=('diagnostics', 'final', 'final-controls'), default='diagnostics')
    parser.add_argument('--apply', action='store_true', help='Execute the planned captures in the already-running ordinary app')
    parser.add_argument('--app', type=Path, default=ROOT/'build/LAB.app')
    parser.add_argument('--output', type=Path, default=ROOT/'.local/cycles-materials')
    parser.add_argument('--group', type=int, action='append', help='Run only these 1-based capture groups; useful for a reviewed partial restart')
    args = parser.parse_args()
    planned = commands(args.stage, args.app, args.output)
    if args.group:
        if len(set(args.group))!=len(args.group) or any(index<1 or index>len(planned) for index in args.group):parser.error('Choose unique existing 1-based capture groups')
        planned=[command for index,command in enumerate(planned,1) if index in args.group]
    corpus=json.loads((ROOT/'examples/cycles-materials/corpus.json').read_text())
    spacings={c['stitch_spacing_mm'] for c in corpus['cases'] if c['id'] in ('thread-matte','thread-lustrous')}
    if len(spacings)!=1:raise RuntimeError('Paired thread declarations differ')
    print(json.dumps(dict(stage=args.stage, apply_requested=args.apply, commands=planned,
                          visual_acceptance='pending', spacing_mm=next(iter(spacings)),
                          note='Run only the approved stage on the verified ordinary installation. Keep diagnostic and final stages separate, use current paired corpus settings, and retain all prior evidence. Completion does not establish visual acceptance.'), indent=2), flush=True)
    if args.apply:
        for index, command in enumerate(planned, 1):
            print(f'Capture group {index}/{len(planned)}', flush=True)
            subprocess.run(command, cwd=ROOT, check=True)


if __name__ == '__main__':
    main()
