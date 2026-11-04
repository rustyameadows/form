#!/usr/bin/env python3
"""Portable review of actual LAB renders; never infers visual acceptance.

Manufacturer photographs remain ordinary links. Actual LAB PNGs and render.json
records are copied into a self-contained report directory; no application calls.
Use --project when a moved .form package makes the checkpoint's old paths stale.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import html
import json
import os
from pathlib import Path
import shutil
from urllib.parse import quote, urlparse

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'examples/cycles-materials'
VIEWS = {'whole': 'Whole / both variants', 'close': 'Macro / surface detail', 'grazing': 'Grazing / edge and response'}
OUTCOMES = {'pending', 'needs_changes', 'accepted', 'failed'}


def read_json(path):
    if path.stat().st_size > 32 * 1024 * 1024:
        raise ValueError('JSON exceeds the 32 MiB report input budget: ' + str(path))
    return json.loads(path.read_text())


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def digest(path):
    if path.stat().st_size > 128 * 1024 * 1024:
        raise ValueError('Render artifact exceeds 128 MiB: ' + str(path))
    return hashlib.sha256(path.read_bytes()).hexdigest()


def artifact(attempt, key, project=None):
    relative = attempt.get('project_files', {}).get(key)
    if project and relative:
        rel = Path(relative)
        if rel.is_absolute() or '..' in rel.parts or not rel.parts or rel.parts[0] != 'Exports':
            raise ValueError('Expected a relative project Exports path')
        path = project / rel
    else:
        value = attempt.get(key)
        if not value:
            return None
        path = Path(value)
    return path if path.is_file() else None


def attempts(state):
    result = {}
    for case_id, case in state.get('cases', {}).items():
        for attempt in case.get('render_attempts', []):
            view, number = attempt.get('view'), attempt.get('attempt')
            if view not in VIEWS or not isinstance(number, int) or isinstance(number, bool) or number < 1:
                raise ValueError('Malformed render attempt identity')
            key = (case_id, view, number)
            if key in result:
                raise ValueError('Duplicate render attempt: ' + str(key))
            result[key] = attempt
    if len(result) > 1000:
        raise ValueError('The report supports at most 1000 attempts')
    return result


def prepare_observations(state, value, project=None):
    """Append empty pending records; preserve every human review verbatim."""
    value.setdefault('version', 1)
    value.setdefault('project_id', state.get('project_id'))
    rounds = value.setdefault('rounds', [])
    existing = {(r['case_id'], r['view'], r['attempt']): r for r in rounds}
    for key, attempt in attempts(state).items():
        if key in existing:
            review = existing[key]
            if review['outcome'] == 'pending' and not review['reviewer'] and not review['observations'] and not review.get('source_png_sha256'):
                png = artifact(attempt, 'png', project)
                if png:
                    review['source_png_sha256'] = digest(png)
            continue
        png = artifact(attempt, 'png', project)
        rounds.append(dict(case_id=key[0], view=key[1], attempt=key[2], outcome='pending',
                           source_png_sha256=digest(png) if png else None, reviewer='',
                           variant_indices=[], reference_urls=[], observations=[], discrepancies=[], next_change=''))
    return value


def validate_observations(state, value, project=None):
    if set(value) - {'version', 'project_id', 'rounds'} or value.get('version') != 1:
        raise ValueError('Use observations.schema.json version 1')
    if value.get('project_id') and value['project_id'] != state.get('project_id'):
        raise ValueError('Observation project ID differs from the rendered project')
    rounds = value.get('rounds')
    if not isinstance(rounds, list) or len(rounds) > 1000:
        raise ValueError('Use a bounded rounds array')
    known, result = attempts(state), {}
    required = {'case_id', 'view', 'attempt', 'outcome', 'source_png_sha256', 'reviewer',
                'variant_indices', 'reference_urls', 'observations', 'discrepancies', 'next_change'}
    for review in rounds:
        if not isinstance(review, dict) or not required <= set(review) or set(review) - required - {'reviewed_at'}:
            raise ValueError('A review has missing or unknown fields')
        key = (review['case_id'], review['view'], review['attempt'])
        if key not in known or key in result or review['outcome'] not in OUTCOMES:
            raise ValueError('A review needs one existing, uniquely identified render attempt: ' + str(key))
        for field in ('observations', 'discrepancies', 'reference_urls'):
            entries = review[field]
            maximum = 20 if field == 'reference_urls' else 40
            maximum_length = 4096 if field == 'reference_urls' else 4000
            if not isinstance(entries, list) or len(entries) > maximum or any(not isinstance(s, str) or not s.strip() or len(s) > maximum_length for s in entries):
                raise ValueError('Use bounded nonempty review strings: ' + field)
        for url in review['reference_urls']:
            if urlparse(url).scheme not in ('http', 'https'):
                raise ValueError('Reference URLs must be public HTTP(S) links')
        variants = review['variant_indices']
        if not isinstance(variants, list) or len(variants) > 2 or any(type(v) is not int or v not in (0, 1) for v in variants) or len(set(variants)) != len(variants):
            raise ValueError('Inspected variants must be distinct 0/1 indices')
        if not isinstance(review['reviewer'], str) or len(review['reviewer']) > 200 or not isinstance(review['next_change'], str) or len(review['next_change']) > 4000:
            raise ValueError('Reviewer and next_change must be bounded strings')
        sha = review['source_png_sha256']
        if sha is not None and (not isinstance(sha, str) or len(sha) != 64 or any(c not in '0123456789abcdef' for c in sha)):
            raise ValueError('Use a SHA256 hex digest or null for missing output')
        if 'reviewed_at' in review and (not isinstance(review['reviewed_at'], str) or len(review['reviewed_at']) > 100):
            raise ValueError('reviewed_at must be a bounded date string')
        claimed = review['outcome'] in ('accepted', 'needs_changes')
        if claimed:
            png = artifact(known[key], 'png', project)
            if known[key].get('state') != 'completed' or not png or review['source_png_sha256'] != digest(png):
                raise ValueError('A reviewed result must identify the exact completed LAB PNG: ' + str(key))
            if not review['reviewer'].strip() or not review['observations'] or not review['reference_urls'] or not variants:
                raise ValueError('Review decisions require explicit observations, reference URLs, variants and reviewer')
        if review['outcome'] == 'accepted' and (review['discrepancies'] or review['next_change'].strip()):
            raise ValueError('Acceptance cannot retain unresolved discrepancies or a proposed next change')
        if review['outcome'] == 'needs_changes' and (not review['discrepancies'] or not review['next_change'].strip()):
            raise ValueError('A revision review needs concrete discrepancies and next_change')
        result[key] = review
    return result


def case_status(case_id, records, reviews):
    latest = {}
    for key, record in records.items():
        if key[0] == case_id and (key[1] not in latest or key[2] > latest[key[1]][0][2]):
            latest[key[1]] = (key, record)
    covered = set()
    accepted = len(latest) == len(VIEWS)
    failed, needs_changes = False, False
    for key, record in latest.values():
        review = reviews.get(key)
        accepted &= record.get('state') == 'completed' and review is not None and review['outcome'] == 'accepted'
        if review:
            covered.update(review['variant_indices'])
            if review['outcome'] == 'needs_changes':
                needs_changes = True
            if review['outcome'] == 'failed':
                failed = True
        if record.get('state') in ('failed', 'cancelled'):
            failed = True
    return 'accepted' if accepted and covered == {0, 1} else 'failed' if failed else 'needs_changes' if needs_changes else 'pending'


def esc(value):
    return html.escape(str(value), quote=True)


def link(url, label):
    return f'<a href="{esc(url)}" target="_blank" rel="noopener noreferrer">{esc(label)}</a>' if urlparse(url).scheme in ('http', 'https') else esc(label)


def bullets(values):
    return '<ul>' + ''.join('<li>' + esc(x) + '</li>' for x in values) + '</ul>'


def copy_artifact(source, output, extension):
    sha = digest(source)
    destination = output.parent / 'assets' / (sha + extension)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists():
        shutil.copyfile(source, destination)
    elif digest(destination) != sha:
        raise ValueError('A content-addressed report asset was modified')
    return quote(os.path.relpath(destination, output.parent)), sha


def supplementary_reviews(output, inputs=()):
    manifest=output.with_name('supplementary-reviews.json')
    entries=read_json(manifest) if manifest.exists() else []
    for source in inputs:
        read_json(source)  # Validate bounded JSON; keep exact original bytes.
        href,sha=copy_artifact(source,output,'.json')
        record=dict(name=source.name,href=href,sha256=sha)
        if record not in entries:entries.append(record)
    if len(entries)>100:raise ValueError('Supplementary review records exceed the report bound')
    for entry in entries:
        sha=entry.get('sha256','')
        if len(sha)!=64 or any(c not in '0123456789abcdef' for c in sha) or entry.get('href')!='assets/'+sha+'.json':raise ValueError('Invalid supplementary review asset')
        if digest(output.parent/entry['href'])!=sha:raise ValueError('Supplementary review asset was changed')
    if inputs:write_json(manifest,entries)
    return entries


def build_report(corpus, state, observations, output, project=None, review_artifacts=()):
    records = attempts(state)
    if set(key[0] for key in records) - {case['id'] for case in corpus['cases']}:
        raise ValueError('Render state contains a case absent from this corpus')
    reviews = validate_observations(state, observations, project)
    statuses = {case['id']: case_status(case['id'], records, reviews) for case in corpus['cases']}
    accepted = sum(s == 'accepted' for s in statuses.values())
    notices=corpus.get('review_notices',[])
    if not isinstance(notices,list) or len(notices)>16 or any(not isinstance(n,str) or not 1<=len(n)<=4000 for n in notices):
        raise ValueError('Use at most16 bounded textual review notices')
    nav = ''.join(f'<a href="#{esc(c["id"])}">{esc(c["title"])} <span class="pill {statuses[c["id"]]}">{statuses[c["id"]].replace("_", " ")}</span></a>' for c in corpus['cases'])
    if output.with_name('optics.html').is_file():
        nav += '<a href="optics.html">Additional optical behavior controls</a>'
    for directory in sorted(output.parent.glob('native-round[0-9]*')):
        suffix=directory.name.removeprefix('native-round')
        if suffix.isdigit() and (directory/'index.html').is_file():
            nav += '<a href="'+esc(directory.name)+'/index.html">Native integration round '+esc(suffix)+'</a>'
    sections = []
    extra=supplementary_reviews(output,review_artifacts)
    if extra:
        rows=['<li><a href="'+esc(e['href'])+'">'+esc(e['name'])+'</a><small>Exact original record · SHA256 '+e['sha256']+'</small></li>' for e in extra]
        sections.append('<section><h2>Independent review and diagnostic records</h2><p>Original observations and mathematical diagnostics are retained separately from case acceptance. Image/program paths inside these records preserve their original context; corresponding portable artifacts are linked in this report and the optical controls.</p><ul>'+''.join(rows)+'</ul></section>')
    interrupted=[run for run in state.get('author_runs',[]) if run.get('authoring_failure')]
    if interrupted:
        entries=[]
        for run in interrupted:
            entries.append('<details><summary>Retained authoring interruption · '+esc(run['run_id'])+'</summary><pre>'+esc(json.dumps(run['authoring_failure'],indent=2))+'</pre></details>')
        sections.append('<section><h2>Retained authoring interruptions</h2><p>These attempts stopped before producing a render. No substitute image or successful capture is inferred.</p>'+''.join(entries)+'</section>')
    for case in corpus['cases']:
        case_id = case['id']
        links = [link(case['photo_url'], 'Original photograph' + (' · PDF pages ' + ', '.join(map(str, case['photo_pages'])) if case.get('photo_pages') else '')),
                 link(case['spec_url'], 'Manufacturer specification'), link(case['source_url'], 'Product/source page')]
        links += [link(url, 'Additional photograph ' + str(i + 1)) for i, url in enumerate(case.get('additional_photo_urls', []))]
        columns = []
        for view, title in VIEWS.items():
            candidates = sorted(((key, record) for key, record in records.items() if key[:2] == (case_id, view)), key=lambda pair: pair[0][2], reverse=True)
            cards = []
            for index, (key, record) in enumerate(candidates):
                review = reviews.get(key)
                outcome = review['outcome'] if review else 'pending'
                body = ''
                png = artifact(record, 'png', project)
                if png:
                    href, sha = copy_artifact(png, output, '.png')
                    body += f'<a href="{href}" target="_blank"><img loading="lazy" src="{href}" alt="Actual LAB render {esc(case_id)} {view} attempt {key[2]}"></a><small>LAB PNG · SHA256 {sha[:16]}…</small>'
                else:
                    body += '<p class="empty">No available LAB PNG for this attempt.</p>'
                if record.get('failure') or record.get('error'):
                    body += '<p class="failure">' + esc(record.get('failure') or record.get('error')) + '</p>'
                provenance = artifact(record, 'record', project)
                if provenance:
                    href, _ = copy_artifact(provenance, output, '.json')
                    body += '<p><a href="' + href + '">Actual render provenance</a></p>'
                    metadata = read_json(provenance)
                    settings = metadata.get('settings', {})
                    powers = [str(light.get('powerWatts')) + ' W' for light in settings.get('areaLights', [])]
                    body += '<p class="render-settings">' + esc(str(metadata.get('samples', '?')) + ' samples · ' + str(metadata.get('device', '?')) + ' · exposure ' + str(settings.get('exposure', '?')) + (' · key ' + ', '.join(powers) if powers else '')) + '</p>'
                if record.get('authored_reference'):
                    body += '<details><summary>Authored material for this attempt</summary><pre>' + esc(json.dumps(record['authored_reference'], indent=2)) + '</pre></details>'
                if record.get('authored_geometry'):
                    body += '<details><summary>Authored geometry for this attempt</summary><pre>' + esc(json.dumps(record['authored_geometry'], indent=2)) + '</pre></details>'
                if record.get('build_identity'):
                    body += '<details><summary>Installed build captured for this author run</summary><pre>' + esc(json.dumps(record['build_identity'], indent=2)) + '</pre></details>'
                if record.get('project_files'):
                    body += '<details><summary>Portable project files</summary><pre>' + esc(json.dumps(record['project_files'], indent=2)) + '</pre></details>'
                if review:
                    body += '<p><strong>Recorded review:</strong> ' + esc(outcome.replace('_', ' ')) + (' · ' + esc(review['reviewer']) if review['reviewer'] else '') + '</p>'
                    if review['variant_indices']:
                        body += '<p>Inspected variants: ' + ', '.join(str(v + 1) for v in review['variant_indices']) + '</p>'
                    if review['observations']:
                        body += '<strong>Observations</strong>' + bullets(review['observations'])
                    if review['discrepancies']:
                        body += '<strong>Discrepancies</strong>' + bullets(review['discrepancies'])
                    if review['next_change']:
                        body += '<p><strong>Next change:</strong> ' + esc(review['next_change']) + '</p>'
                    if review['reference_urls']:
                        body += '<p>Reviewed references: ' + ' · '.join(link(url, str(i + 1)) for i, url in enumerate(review['reference_urls'])) + '</p>'
                else:
                    body += '<p class="empty">No visual observations recorded. Render success is not acceptance.</p>'
                cards.append(f'<details class="attempt" {"open" if index == 0 else ""}><summary>Attempt {key[2]} · render {esc(record.get("state", "unknown"))} · review <span class="pill {outcome}">{outcome.replace("_", " ")}</span></summary>{body}</details>')
            columns.append('<div class="view"><h3>' + esc(title) + '</h3>' + (''.join(cards) or '<p class="empty">No render attempts yet.</p>') + '</div>')
        photo_review = case.get('photograph_review', {})
        reviewed = ['Observed reference ' + name + ': ' + str(value) for name, value in photo_review.items() if name not in ('reviewed_utc', 'method')]
        sections.append(f'<section id="{esc(case_id)}"><h2>{esc(case["title"])} <span class="pill {statuses[case_id]}">{statuses[case_id].replace("_", " ")}</span></h2>'
                        + '<p class="sources">' + ' · '.join(links) + '</p><p><strong>Current authored specification:</strong> ' + esc(case['specification']) + '</p>'
                        + '<h3>Preserved variants</h3>' + bullets(case['geometry_variants'])
                        + '<details><summary>Original photograph inspection and acceptance criteria</summary>' + bullets(reviewed)
                        + '<strong>Acceptance criteria</strong>' + bullets(case['review']) + '</details><div class="views">' + ''.join(columns) + '</div></section>')
    summary = dict(version=1, generated_at=datetime.now(timezone.utc).isoformat(), project_id=state.get('project_id'), accepted_cases=accepted, total_cases=len(corpus['cases']), cases=statuses, attempts=len(records), review_records=len(reviews), explicit_reviews=sum(bool(r['reviewer'] and r['observations']) for r in reviews.values()))
    document = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>LAB material review</title><style>' + CSS + '</style></head><body><header><p class="eyebrow">LAB · physical material evidence</p><h1>Material review</h1><p>' + str(accepted) + ' / ' + str(len(corpus['cases'])) + ' cases accepted from explicit recorded reviews. ' + str(len(records)) + ' render attempts.</p><p>Actual LAB images and failures are shown below. Manufacturer photographs are linked, never copied into this report. Optical estimates remain estimates.</p>' + bullets(notices) + '<nav>' + nav + '</nav></header><main>' + ''.join(sections) + '</main><footer>Acceptance requires the latest whole, macro and grazing outputs, both material/geometry variants, exact image hashes and explicit reference comparisons. Missing observations remain pending.</footer></body></html>'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(document)
    write_json(output.with_suffix('.summary.json'), summary)
    write_json(output.parent / 'observations.json', observations)
    return summary


CSS = '''*{box-sizing:border-box}body{margin:0;background:#f5f3ee;color:#252b28;font:15px/1.55 system-ui,sans-serif}header,main,footer{max-width:1560px;margin:auto;padding:32px}h1{font-size:40px;line-height:1.15;margin:6px 0 18px}h2{font-size:25px}h3{font-size:16px}.eyebrow{letter-spacing:.12em;text-transform:uppercase;font-size:12px}a{color:#265d78;text-underline-offset:3px}nav{display:flex;flex-wrap:wrap;gap:8px 18px}nav a{text-decoration:none}section{margin-bottom:34px;border-top:1px solid #b9bdb7;padding-top:16px}.sources{font-size:13px}.views{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:18px}.view{min-width:0}.attempt{background:white;border:1px solid #d7dbd4;border-radius:8px;margin:12px 0;padding:12px}summary{cursor:pointer;font-weight:600;padding:4px 0}img{width:100%;height:auto;margin-top:12px;background:#e3e5e0}small{display:block;color:#6c746e;font-size:10px;overflow-wrap:anywhere}.pill{display:inline-block;border-radius:20px;padding:2px 8px;font-size:11px;background:#e4e8e4;font-weight:500;vertical-align:middle}.accepted{background:#d7eddc;color:#285a32}.failed{background:#f4d8d2;color:#8c2d25}.needs_changes{background:#f8e8bd;color:#76571d}.empty{color:#717971;font-style:italic}.failure{color:#952f25;white-space:pre-wrap}pre{font:11px/1.5 monospace;white-space:pre-wrap;overflow-wrap:anywhere}ul{padding-left:22px}footer{font-size:12px;color:#68716b;border-top:1px solid #cdd1ca}@media(max-width:1000px){.views{grid-template-columns:1fr}header,main,footer{padding:20px}}'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', type=Path, default=ROOT / '.local/cycles-materials/state.json')
    parser.add_argument('--corpus', type=Path, default=SOURCE / 'corpus.json')
    parser.add_argument('--observations', type=Path)
    parser.add_argument('--prepare-observations', action='store_true', help='Append empty pending records for new attempts; never write observations or acceptance')
    parser.add_argument('--output', type=Path, help='HTML output, preferably <project.form>/Exports/material-review/index.html')
    parser.add_argument('--project', type=Path, help='Current .form package path for resolving portable render paths after a move')
    parser.add_argument('--review-artifact', type=Path, action='append', default=[], help='Retain a bounded original JSON review/diagnostic and its exact hash in the portable report')
    args = parser.parse_args()
    state = read_json(args.state) if args.state.exists() else {'cases': {}, 'project_id': None}
    corpus = read_json(args.corpus)
    observations_path = args.observations or args.state.parent / 'observations.json'
    observations = read_json(observations_path) if observations_path.exists() else {'version': 1, 'project_id': state.get('project_id'), 'rounds': []}
    if args.prepare_observations:
        observations = prepare_observations(state, observations, args.project)
        validate_observations(state, observations, args.project)
        write_json(observations_path, observations)
    output = (args.output or args.state.parent / 'report/index.html').resolve()
    summary = build_report(corpus, state, observations, output, args.project, args.review_artifact)
    print(json.dumps({'report': str(output), **summary}))


if __name__ == '__main__':
    main()
