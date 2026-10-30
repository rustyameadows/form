#!/usr/bin/env python3
"""Refine the seeded paper studies' editable artwork through one MCP batch.

No native app is launched. Existing layer IDs, stock, construction and finish
assignments are preserved. A second run makes no edits when the layout matches.
"""
import argparse
import copy
import hashlib
import json
import math
from pathlib import Path
import time

from validate_paper_packaging import CASES, ROOT, Session, element, stable


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()).hexdigest()


def write(path, value):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n'); temporary.replace(path)


def source(project):
    result = copy.deepcopy(project); result.get('camera', {}).pop('viewportAspect', None)
    return result


def non_artwork_source(project):
    result = source(project)
    result.pop('history', None); result.pop('updatedAt', None)
    for obj in result['objects']:
        obj.pop('artwork', None)
    return result


def same(a, b):
    if isinstance(a, (int, float)) and not isinstance(a, bool) and isinstance(b, (int, float)) and not isinstance(b, bool):
        return math.isclose(a, b, rel_tol=0, abs_tol=1e-8)
    if isinstance(a, dict) and isinstance(b, dict):
        # Codable fills optional/default typography and stroke properties. Only
        # the explicitly authored patch keys define this idempotent refinement.
        return set(b) <= set(a) and all(same(a[k], b[k]) for k in b)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    return a == b


def patch(identifier, **fields):
    return {'id': identifier, **fields}


class Refinement:
    def __init__(self, options):
        self.options = options
        self.seed = json.loads((options.output / 'report.json').read_text())
        require(len(self.seed.get('cases', [])) == 12 and self.seed.get('project_id'), 'The complete seeded report is required')
        self.rows = {row['case']: row for row in self.seed['cases']}
        self.session = Session(options.app, options.socket, options.output)
        self.session.report = copy.deepcopy(self.seed)
        self.folder = options.output / 'refinement'
        self.folder.mkdir(parents=True, exist_ok=True)
        existing = [int(p.name.split('-')[-1]) for p in self.folder.glob('attempt-*') if p.is_dir()]
        self.attempt = self.folder / f'attempt-{max(existing + [0])+1:03d}'
        self.attempt.mkdir()
        self.operations = []; self.frames = []; self.changed_ids = set()
        self.report = {'project_id': self.seed['project_id'], 'status': 'planned', 'scope': 'Editable artwork only; no stock, construction, finish, object or source-ID changes.'}

    def save(self):
        write(self.attempt / 'report.json', self.report)
        write(self.folder / 'report.json', self.report)

    def project(self):
        value = self.session.call('form_get_project')
        require(value['id'] == self.seed['project_id'], 'Another project is active; no artwork edits permitted')
        return value

    def frame(self, key, panel, side, desired):
        row = self.rows[key]
        context = dict(surface_id=panel, side=side)
        artwork = self.session.call('form_get_artwork', dict(object_id=row['object_id'], physical_frame=context))
        by_id = {e['id'].upper(): e for e in artwork['elements']}
        replace, add = [], []
        for wanted in desired:
            identifier = wanted['id'].upper()
            previous = by_id.get(identifier)
            if previous is None:
                value = dict(wanted)
                require({'kind', 'x', 'y', 'width', 'height', 'color', 'text', 'fontSize'} <= set(value), 'New artwork needs a complete editable element')
                add.append(value)
            else:
                changes = {k: v for k, v in wanted.items() if k != 'id'}
                if all(k in previous and same(previous[k], v) for k, v in changes.items()):
                    continue
                value = copy.deepcopy(previous); value.update(changes)
                replace.append(value)
            self.changed_ids.add(identifier)
        for command, values in [('replace', replace), ('add', add)]:
            if values:
                self.operations.append(dict(name='form_edit_artwork', arguments=dict(
                    object_id=row['object_id'], command=command, physical_frame=context, elements=values)))
        self.frames.append(dict(case=key, surface_id=panel, side=side,
                                desired_ids=[x['id'] for x in desired], replaced=len(replace), added=len(add)))

    def ids(self, key, side='inside', panel='front'):
        row = self.rows[key]
        if panel == 'front' and side == 'inside':
            return row['inside_artwork']
        if panel == 'front' and side == 'outside':
            return row['primary_artwork']
        return {name: stable(f'{key}-{side}-{panel}-{name}') for name in ['brand', 'title', 'rule', 'copy', 'seal']}

    def plan(self):
        self.operations = []; self.frames = []; self.changed_ids = set()
        # Postcard reverse: readable writing/address fields and a real stamp box.
        ids = self.ids('10'); ink = CASES[9][4]
        self.frame('10', 'front', 'inside', [
            patch(ids['brand'], kind='text', name='Postcard / heading', x=10, y=10, width=57, height=6, text='POST / CARD', fontSize=8),
            patch(ids['title'], kind='text', name='Postcard / message', x=10, y=27, width=55, height=22,
                  text='A note from\nthe open country.', fontSize=12),
            patch(ids['rule'], kind='rectangle', name='Postcard / divider', x=74, y=10, width=.32, height=85),
            patch(ids['copy'], kind='text', name='Postcard / imprint', x=10, y=90, width=58, height=5, text='FIELD  /  POSTAL STUDY', fontSize=6),
            patch(ids['seal'], kind='rectangle', name='Postcard / stamp zone', x=118, y=10, width=20, height=25,
                  fillEnabled=False, stroke=dict(color=ink, width=.35)),
            element('text', '10-inside-front-recipient', 84, 44, 53, 6, ink, 'Recipient', 8),
            element('text', '10-inside-front-postage', 119, 20, 18, 5, ink, 'POSTAGE', 5.5,
                    typography=dict(fontName='HelveticaNeue-Medium', alignment='center')),
            *[element('rectangle', f'10-inside-front-address-rule-{n}', 84, y, 53, .25, ink)
              for n, y in enumerate([56, 67, 78], 1)]])
        # Business card reverse: name, professional role and reserved .example contact.
        ids = self.ids('09')
        self.frame('09', 'front', 'inside', [
            patch(ids['brand'], name='Contact / name', x=8, y=10, width=69, height=6, text='MARA FIELD', fontSize=11),
            patch(ids['title'], name='Contact / role', x=8, y=20, width=69, height=5, text='DESIGNER / PAPER & OBJECTS', fontSize=7),
            patch(ids['rule'], name='Contact / rule', x=8, y=29, width=22, height=.3),
            patch(ids['copy'], name='Contact / details', x=8, y=37, width=69, height=10,
                  text='hello@studiofield.example\nstudiofield.example', fontSize=7.5)])
        # A small publisher imprint on the actual outside back, not another front design.
        ids = self.ids('11', 'outside', 'back')
        centered = dict(fontName='HelveticaNeue-Medium', alignment='center')
        self.frame('11', 'back', 'outside', [
            patch(ids['brand'], name='Publisher / FIELD', x=35, y=127, width=40, height=5, text='FIELD', fontSize=8, typography=centered),
            patch(ids['title'], name='Publisher / paper goods', x=35, y=135, width=40, height=4, text='PAPER GOODS', fontSize=5.8, typography=centered),
            patch(ids['rule'], name='Publisher / rule', x=47, y=142, width=16, height=.25),
            patch(ids['copy'], name='Publisher / note', x=22, y=147, width=66, height=3, text='Printed for small occasions.', fontSize=5.3, typography=centered),
            patch(ids['seal'], name='Publisher / mark', x=52, y=115, width=6, height=6)])
        ids = self.ids('11')
        self.frame('11', 'front', 'inside', [
            patch(ids['brand'], name='Greeting / heading', x=12, y=30, width=86, height=6, text='A SMALL JOY', fontSize=8),
            patch(ids['title'], name='Greeting / message', x=12, y=55, width=86, height=33, text='For you,\nwith love.', fontSize=24),
            patch(ids['rule'], name='Greeting / rule', x=40, y=98, width=30, height=.3),
            patch(ids['copy'], name='Greeting / wish', x=12, y=115, width=86, height=18,
                  text='Wishing you a day filled with\nlittle things worth keeping.', fontSize=9),
            patch(ids['seal'], name='Greeting / small mark', x=53.5, y=140, width=3, height=3)])
        # These folded panels declare readable 180-degree artwork orientation.
        # Use that real physical frame; do not guess a manual affine flip.
        for key in ['06', '07']:
            row = self.rows[key]; panel = next(p for p in row['inspection']['net']['panels'] if p['id'] == 'bottom-bond')
            width = max(p['x'] for p in panel['polygon']) - min(p['x'] for p in panel['polygon'])
            ink = CASES[int(key)-1][4]
            self.frame(key, 'bottom-bond', 'outside', [
                element('text', f'{key}-outside-bottom-bond-brand', 20, 22, width-40, 6, ink,
                        'FIELD / CORRESPONDENCE' if key == '06' else 'FIELD / GATHER', 8),
                element('text', f'{key}-outside-bottom-bond-imprint', 20, 33, width-40, 5, ink, 'PAPER GOODS / EDITABLE EDITION', 6.5),
                element('rectangle', f'{key}-outside-bottom-bond-rule', 20, 43, 36, .25, ink)])
        # The patterned liner is this envelope's inside feature. Retain all
        # canonical layer IDs for later editing, but hide the generic template.
        require(not any(f.get('side', 'outside') == 'inside' for f in self.rows['07']['finishes']),
                'Do not hide artwork targeted by an inside finish')
        self.frame('07', 'front', 'inside', [patch(identifier, hidden=True)
                                           for identifier in self.ids('07').values()])
        # Both faces share the real punched region; keep the existing brand IDs,
        # including the outside foil assignment, but place them below the hole.
        for side in ['outside', 'inside']:
            ids = self.ids('08', side)
            self.frame('08', 'front', side, [patch(ids['brand'], y=20)])

    def run(self):
        status = self.session.call('form_status')
        require(Path(status['library_path']).resolve() == (self.options.output / 'Library').resolve(), 'Wrong native library; no edits made')
        require(status['project_id'] == self.seed['project_id'], 'Seeded project must be active')
        before = self.project(); write(self.attempt / 'before-project.json', before)
        self.plan(); operations = copy.deepcopy(self.operations); changed_ids = set(self.changed_ids)
        self.report.update(frames=self.frames, operations=len(operations), changed_element_ids=sorted(changed_ids), before_sha256=fingerprint(source(before)),
                           helper_sha256=hashlib.sha256(self.session.helper.read_bytes()).hexdigest(), script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
        write(self.attempt / 'operations.json', operations); self.save()
        if not operations:
            self.report.update(status='already_applied', source_unchanged=True); self.save(); return
        after = None
        try:
            try:
                self.session.call('form_batch', dict(operations=operations))
            except Exception:
                actual = self.project()
                self.report['rejected_batch_source_exact'] = source(actual) == source(before)
                require(self.report['rejected_batch_source_exact'], 'Rejected batch changed source; unknown state preserved for review')
                raise
            after = self.project(); write(self.attempt / 'after-project.json', after)
            require(non_artwork_source(before) == non_artwork_source(after), 'Refinement changed non-artwork source, stock, geometry or finishes')
            old_objects = {x['id']: x for x in before['objects']}
            for current in after['objects']:
                old = old_objects[current['id']]
                a, b = old.get('artwork'), current.get('artwork')
                if a is None:
                    require(b is None, 'Refinement created an unexpected artwork source'); continue
                require({k: v for k, v in a.items() if k != 'elements'} == {k: v for k, v in b.items() if k != 'elements'}, 'Refinement changed frame/source metadata')
                prior = {e['id']: e for e in a['elements']}; now = {e['id']: e for e in b['elements']}
                require(set(prior) <= set(now), 'Refinement removed an existing source/finish target ID')
                require(all(now[i] == e for i, e in prior.items() if i.upper() not in changed_ids), 'Unrelated canonical artwork changed')
            self.plan()
            require(not self.operations, 'Refinement did not converge to an idempotent layout')
            self.report.update(status='passed', after_sha256=fingerprint(source(after)), idempotent_recheck=True,
                               all_existing_source_ids_retained=True, geometry_stock_finishes_unchanged=True,
                               mcp_batch_count=1, undo_contract='One public form_batch transaction')
            self.save()
        except Exception as error:
            self.report.update(status='failed', error=repr(error))
            if after is not None and source(self.project()) == source(after):
                self.session.call('form_undo')
                self.report['restored_source_exact'] = source(self.project()) == source(before)
            self.save(); raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=ROOT / 'build/LAB.app')
    parser.add_argument('--socket', default='/tmp/lab-paper-packaging-twelve-v2.sock')
    parser.add_argument('--output', type=Path, default=ROOT / '.local/validation/paper-packaging/twelve-round-two')
    options = parser.parse_args(); options.output = options.output.resolve()
    refinement = Refinement(options); refinement.run()
    print(json.dumps({'status': refinement.report['status'], 'report': str(refinement.folder / 'report.json')}))


if __name__ == '__main__':
    main()
