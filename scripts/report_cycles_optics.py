#!/usr/bin/env python3
"""Portable optical controls from actual LAB outputs and explicit observations.

These controls can establish a specific optical behavior. They never accept the
eight manufacturer-reference material cases, which have their own review report.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path

from report_cycles_materials import ROOT, artifact, bullets, copy_artifact, digest, esc, read_json, write_json


def attempts(state):
    result = {}
    for diagnostic, group in state.get('diagnostics', {}).items():
        if not isinstance(diagnostic, str) or not 1 <= len(diagnostic) <= 100:
            raise ValueError('Use a bounded diagnostic name')
        for entry in group.get('render_attempts', []):
            key = (diagnostic, entry.get('view'), entry.get('attempt'))
            if not isinstance(key[1], str) or not 1 <= len(key[1]) <= 100 or type(key[2]) is not int or key[2] < 1 or key in result:
                raise ValueError('Use a unique named view and positive attempt')
            result[key] = entry
    if len(result) > 1000:
        raise ValueError('Optical evidence is bounded to 1000 attempts')
    return result


def prepare(state, observations, project=None):
    observations.setdefault('version', 1)
    observations.setdefault('project_id', state.get('project_id'))
    rounds = observations.setdefault('rounds', [])
    existing = {(r['diagnostic'], r['view'], r['attempt']) for r in rounds}
    for key, entry in attempts(state).items():
        if key in existing:
            continue
        png = artifact(entry, 'png', project)
        rounds.append(dict(diagnostic=key[0], view=key[1], attempt=key[2], outcome='pending',
                           source_png_sha256=digest(png) if png else None, reviewer='',
                           observations=[], discrepancies=[], next_change=''))
    return observations


def validate(state, observations, project=None):
    if set(observations) - {'version', 'project_id', 'rounds'} or observations.get('version') != 1:
        raise ValueError('Use optics-observations.schema.json version 1')
    if observations.get('project_id') != state.get('project_id'):
        raise ValueError('Optical observations must identify the same project')
    rounds = observations.get('rounds')
    if not isinstance(rounds, list) or len(rounds) > 1000:
        raise ValueError('Use a bounded rounds array')
    known, result = attempts(state), {}
    required = {'diagnostic', 'view', 'attempt', 'outcome', 'source_png_sha256', 'reviewer', 'observations', 'discrepancies', 'next_change'}
    for review in rounds:
        if not isinstance(review, dict) or not required <= set(review) or set(review) - required - {'reviewed_at'}:
            raise ValueError('An optical review has missing or unknown fields')
        key = (review['diagnostic'], review['view'], review['attempt'])
        if key not in known or key in result or review['outcome'] not in ('pending', 'passed', 'needs_changes', 'failed'):
            raise ValueError('An optical review must identify one existing render')
        for field in ('observations', 'discrepancies'):
            value = review[field]
            if not isinstance(value, list) or len(value) > 40 or any(not isinstance(s, str) or not s.strip() or len(s) > 4000 for s in value):
                raise ValueError('Use bounded nonempty observation strings')
        if not isinstance(review['reviewer'], str) or len(review['reviewer']) > 200 or not isinstance(review['next_change'], str) or len(review['next_change']) > 4000:
            raise ValueError('Reviewer and next change must be bounded strings')
        if 'reviewed_at' in review and (not isinstance(review['reviewed_at'], str) or len(review['reviewed_at']) > 100):
            raise ValueError('Use a bounded review date string')
        if review['outcome'] in ('passed', 'needs_changes'):
            png = artifact(known[key], 'png', project)
            if known[key].get('state') != 'completed' or not png or review['source_png_sha256'] != digest(png):
                raise ValueError('The review must identify the exact completed LAB PNG')
            if not review['reviewer'].strip() or not review['observations']:
                raise ValueError('A decision requires a reviewer and actual observations')
        if review['outcome'] == 'passed' and (review['discrepancies'] or review['next_change'].strip()):
            raise ValueError('A passed control cannot retain an unresolved discrepancy')
        if review['outcome'] == 'needs_changes' and (not review['discrepancies'] or not review['next_change'].strip()):
            raise ValueError('A revision must identify its discrepancy and next change')
        result[key] = review
    return result


def build(state, observations, output, project=None):
    records, reviews = attempts(state), validate(state, observations, project)
    sections = []
    for comparison in state.get('thread_density_reviews',[]):
        rows=[]
        for record in comparison['records']:
            cells=[esc(record['case_id'])+' / variant '+str(record['variant']+1)]
            for phase in ('before','after'):
                program=record[phase];relative=Path(program['project_file'])
                if relative.is_absolute() or '..' in relative.parts or relative.parts[0]!='Exports':raise ValueError('Needle program must be a portable Exports path')
                path=project/relative if project else Path(program['tool_result']['path'])
                if not path.is_file() or digest(path)!=program['sha256']:raise ValueError('Needle program evidence is missing or changed')
                href,_=copy_artifact(path,output,'.json');result=program['tool_result']
                cells.append('<a href="'+href+'">'+str(result['commands'])+' commands / '+str(result['stitches'])+' stitches</a><small>Geometry SHA256 '+esc(program['geometry_sha256'])+'</small>')
            cells.append('<small>Before: '+esc(record['baseline_object_id'])+'<br>After: '+esc(record['active_object_id'])+'</small>')
            rows.append('<tr>'+''.join('<td>'+c+'</td>' for c in cells)+'</tr>')
        sections.append('<section><h2>Editable paired thread density comparison</h2><p>Authored satin/fill spacing '+esc(comparison['before_spacing_mm'])+' → '+esc(comparison['after_spacing_mm'])+' mm. Separate baseline objects remain editable and spatially separated. Underlay, ties, diameter, color and optics stay fixed; actual exported needle geometry matches between matte/lustrous after ignoring region UUIDs only. Commands use LAB’s declared 0.1 mm coordinate grid. The denser spacing is an artist comparison outside manufacturer recommendations, not a verified sew-out.</p><table><thead><tr><th>Case</th><th>Before</th><th>After</th><th>Editable object IDs</th></tr></thead><tbody>'+''.join(rows)+'</tbody></table></section>')
    for comparison in state.get('thread_tie_reviews',[]):
        rows=[]
        for record in comparison['records']:
            cells=[esc(record['case_id'])+' / variant '+str(record['variant']+1)]
            for phase in ('before','after'):
                program=record[phase];relative=Path(program['project_file'])
                if relative.is_absolute() or '..' in relative.parts or relative.parts[0]!='Exports':raise ValueError('Needle program must be a portable Exports path')
                path=project/relative if project else Path(program['tool_result']['path'])
                if not path.is_file() or digest(path)!=program['sha256']:raise ValueError('Needle program evidence is missing or changed')
                href,_=copy_artifact(path,output,'.json');result=program['tool_result']
                cells.append('<a href="'+href+'">'+str(result['commands'])+' commands / '+str(result['stitches'])+' stitches</a><small>Tie-in '+str(result['tie_in_stitches'])+' / tie-off '+str(result['tie_off_stitches'])+'<br>Geometry SHA256 '+esc(program['geometry_sha256'])+'</small>')
            cells.append('<small>'+esc(record['active_object_id'])+'<br>Unchanged non-tie geometry SHA256 '+esc(record['non_tie_geometry_sha256'])+'</small>')
            rows.append('<tr>'+''.join('<td>'+c+'</td>' for c in cells)+'</tr>')
        sections.append('<section><h2>Controlled paired tie reduction</h2><p>Backtracking repeats '+esc(comparison['before_repeats'])+' → '+esc(comparison['after_repeats'])+'; both tie-in and tie-off remain enabled at '+esc(comparison['tie_length_mm'])+' mm length. Spacing stays '+esc(comparison['spacing_mm'])+' mm. Every non-tie command is unchanged, and matte/lustrous command geometry matches. Complete editable before/after definitions are retained in these exported programs and project history. This is an artist visual comparison, not a sew-out or validated manufacturing recommendation.</p><table><thead><tr><th>Case</th><th>Before</th><th>After</th><th>Editable object / unchanged commands</th></tr></thead><tbody>'+''.join(rows)+'</tbody></table></section>')
    for diagnostic in state.get('diagnostics', {}):
        cards = []
        for key, entry in sorted(records.items(), key=lambda x: (x[0][1], -x[0][2])):
            if key[0] != diagnostic:
                continue
            review = reviews.get(key)
            outcome = review['outcome'] if review else 'pending'
            body = '<h3>' + esc(key[1]) + ' / attempt ' + str(key[2]) + '</h3><p>Render ' + esc(entry.get('state', 'unknown')) + ' · review <strong>' + esc(outcome) + '</strong></p>'
            png = artifact(entry, 'png', project)
            if png:
                href, sha = copy_artifact(png, output, '.png')
                body += '<a href="' + href + '"><img loading="lazy" src="' + href + '" alt="Actual LAB optical control"></a><small>Exact LAB PNG · SHA256 ' + sha + '</small>'
            if entry.get('failure') or entry.get('error'):
                body += '<p>' + esc(entry.get('failure') or entry.get('error')) + '</p>'
            record = artifact(entry, 'record', project)
            if record:
                href, _ = copy_artifact(record, output, '.json')
                body += '<p><a href="' + href + '">Render provenance</a></p>'
            if entry.get('build_identity'):
                body += '<details><summary>Installed build captured for this author run</summary><pre>' + esc(json.dumps(entry['build_identity'], indent=2)) + '</pre></details>'
            if review:
                body += '<p>Reviewer: ' + esc(review['reviewer'] or 'Not recorded') + '</p>' + bullets(review['observations'])
                if review['discrepancies']:
                    body += '<strong>Discrepancies</strong>' + bullets(review['discrepancies'])
                if review['next_change']:
                    body += '<p><strong>Next change:</strong> ' + esc(review['next_change']) + '</p>'
            else:
                body += '<p>No visual observations recorded.</p>'
            cards.append('<article>' + body + '</article>')
        sections.append('<section><h2>' + esc(diagnostic) + '</h2><div class="cards">' + ''.join(cards) + '</div></section>')
    body = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>LAB optical controls</title><style>body{font:16px system-ui;background:#f3f1eb;color:#282b28;margin:0 auto;padding:32px;max-width:1500px}a{color:#376343}h1,h2{font-weight:550}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(340px,1fr));gap:20px}article{padding:18px;background:#fff;border:1px solid #ddd;border-radius:10px}img{width:100%;height:auto}small{display:block;font-size:10px;word-break:break-all}li{margin:.5em 0}pre{white-space:pre-wrap;overflow-wrap:anywhere;font-size:11px}</style></head><body><h1>Optical behavior controls</h1><p><a href="index.html">Eight material reference cases</a></p><p>Actual editable LAB scenes compare optical behavior under controlled changes. A passed control does not establish manufacturer material fidelity. Failed and superseded iterations remain visible.</p>' + ''.join(sections) + '</body></html>'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(body)
    summary = dict(version=1, generated_at=datetime.now(timezone.utc).isoformat(), attempts=len(records), explicit_reviews=sum(bool(r['reviewer'] and r['observations']) for r in reviews.values()))
    write_json(output.with_suffix('.observations.json'), observations)
    write_json(output.with_suffix('.summary.json'), summary)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', type=Path, default=ROOT/'.local/cycles-materials/state.json')
    parser.add_argument('--observations', type=Path, default=ROOT/'.local/cycles-materials/optics-observations.json')
    parser.add_argument('--output', type=Path, default=ROOT/'.local/cycles-materials/report/optics.html')
    parser.add_argument('--project', type=Path)
    parser.add_argument('--prepare-observations', action='store_true')
    args = parser.parse_args()
    state = read_json(args.state)
    observations = read_json(args.observations) if args.observations.exists() else dict(version=1, project_id=state.get('project_id'), rounds=[])
    if args.prepare_observations:
        observations = prepare(state, observations, args.project)
        write_json(args.observations, observations)
    print(build(state, observations, args.output, args.project))


if __name__ == '__main__':
    main()
