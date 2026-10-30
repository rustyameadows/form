#!/usr/bin/env python3
"""Check the seeded twelve-case native paper project through public MCP only.

Read <output>/report.json from validate_paper_packaging.py. Checkpoints and raw
evidence go under <output>/checks/<round>/; project files are never edited here.
No app is launched or stopped. Run only after the seeder has completed.
"""
import argparse
import copy
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import time
import uuid
import xml.etree.ElementTree as ET

from validate_paper_packaging import CASES, ROOT, Session


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def source(project):
    result = copy.deepcopy(project)
    # Native resize derives this camera property; no other source is excluded.
    result.get('camera', {}).pop('viewportAspect', None)
    return result


def sha_file(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    stage = path.with_suffix(path.suffix + '.tmp')
    stage.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n')
    stage.replace(path)


def require(value, message):
    if not value:
        raise AssertionError(message)


def obj(project, object_id):
    return next(o for o in project['objects'] if o['id'].upper() == object_id.upper())


def canonical_artworks(project, object_id):
    physical = obj(project, object_id)
    owner = physical
    seen = set()
    while owner.get('artworkSourceID'):
        require(owner['id'] not in seen, 'Cyclic canonical artwork owner')
        seen.add(owner['id'])
        owner = obj(project, owner['artworkSourceID'])
    result = {'outside_owner': owner['id'], 'outside': owner.get('artwork')}
    paper = physical['paperConstruction']
    if paper.get('insideArtworkSourceID'):
        inside = obj(project, paper['insideArtworkSourceID'])
        result.update(inside_owner=inside['id'], inside=inside.get('artwork'),
                      inside_source_parameters=inside['parameters'])
    else:
        result.update(inside_owner=None, inside=paper.get('insideArtwork'))
    return result


def expression_shape(definition):
    result = copy.deepcopy(definition)
    for parameter in result.get('parameters', []):
        parameter.pop('value', None)
    return result


def tag(element):
    return element.tag.rsplit('}', 1)[-1]


def svg_extent(path):
    root = ET.parse(path).getroot()
    require(tag(root) == 'svg', f'Not SVG: {path}')
    def mm(key):
        value = root.attrib[key]
        require(value.endswith('mm'), f'{path}: {key} lacks physical mm units')
        return float(value[:-2])
    return root, [mm('width'), mm('height')], [float(x) for x in root.attrib['viewBox'].replace(',', ' ').split()]


def close_values(actual, expected, description, tolerance=1e-7):
    require(len(actual) == len(expected) and all(math.isclose(a, b, rel_tol=0, abs_tol=tolerance)
            for a, b in zip(actual, expected)), f'{description}: {actual} != {expected}')


def xml_by_id(root, identifier):
    return next((e for e in root.iter() if e.attrib.get('id') == identifier), None)


def drawable_count(root):
    if tag(root) in {'defs', 'clipPath', 'filter', 'mask'}:
        return 0
    return int(tag(root) in {'path', 'text', 'rect', 'ellipse', 'circle', 'polygon', 'polyline', 'image', 'line'}) + sum(
        drawable_count(child) for child in root)


def verify_pdf(path, sheet_size):
    binary = shutil.which('pdfinfo') or ('/opt/homebrew/bin/pdfinfo' if Path('/opt/homebrew/bin/pdfinfo').exists() else None)
    require(binary is not None, 'pdfinfo is required to verify physical PDF sheet boxes; no size claim was inferred')
    completed = subprocess.run([binary, str(path)], text=True, capture_output=True, timeout=30, check=True)
    match = re.search(r'^Page size:\s*([\d.]+) x ([\d.]+) pts', completed.stdout, re.M)
    pages = re.search(r'^Pages:\s*(\d+)', completed.stdout, re.M)
    require(match and pages, f'PDF media box/page metadata unavailable: {path}')
    actual = [float(match[1]), float(match[2])]
    close_values(actual, [x * 72 / 25.4 for x in sheet_size], f'{path.name} page size', tolerance=.025)
    require(int(pages[1]) == 1, 'Single-copy proof unexpectedly has multiple sheets')
    return {'page_size_pt': actual, 'pages': int(pages[1]), 'tool': binary}


class Checker:
    def __init__(self, options):
        self.options = options
        self.seed_path = options.output / 'report.json'
        self.seed = json.loads(self.seed_path.read_text())
        require(self.seed.get('project_id') and len(self.seed.get('cases', [])) == len(CASES),
                'Seed report must contain all twelve project/case IDs before checks start')
        for i, row in enumerate(self.seed['cases']):
            require(row['case'] == f'{i+1:02d}' and row['definition_file'] == CASES[i][0] and row.get('inspection'),
                    f'Incomplete or mismatched seeded case {i+1}')
        require(self.seed['cases'][2].get('template') and self.seed['cases'][3].get('contents_object_id') and self.seed['cases'][4].get('contents_object_id')
                and self.seed['cases'][6].get('liner_object_id'), 'Seeder did not complete its template/contents/liner steps')
        self.session = Session(options.app, options.socket, options.output)
        # Session saves this on unexpected MCP errors. Never replace the seeder
        # report with Session's empty constructor report.
        self.session.report = copy.deepcopy(self.seed)
        self.folder = options.output / 'checks' / options.round
        self.report_path = self.folder / 'report.json'
        self.report = json.loads(self.report_path.read_text()) if self.report_path.exists() else {
            'version': 1, 'round': options.round, 'project_id': self.seed['project_id'], 'cases': {},
            'scope': 'MCP source/Undo/persistence/process-file checks; no native visual or press-accuracy claim.'}
        require(self.report['project_id'] == self.seed['project_id'], 'Existing checkpoint belongs to another project')
        self.folder.mkdir(parents=True, exist_ok=True)

    def save(self):
        write_json(self.report_path, self.report)

    def call(self, name, args=None, expected_failure=False):
        return self.session.call(name, args, expected_failure=expected_failure)

    def project(self):
        result = self.call('form_get_project')
        require(result['id'] == self.seed['project_id'], 'Another project became active; no further edits are allowed')
        return result

    def paper(self, command, row, **args):
        return self.call('form_paper', dict(command=command, object_id=row['object_id'], **args))

    def recover(self):
        pending = self.report.get('pending')
        if not pending:
            return
        before = json.loads(Path(pending['before']).read_text())
        current = source(self.project())
        if current == source(before):
            self.report.setdefault('recoveries', []).append(dict(case=pending['case'], outcome='already_restored'))
        elif pending.get('after') and Path(pending['after']).exists() and current == source(json.loads(Path(pending['after']).read_text())):
            self.call('form_undo')
            require(source(self.project()) == source(before), 'Guarded recovery Undo did not restore its recorded baseline')
            self.report.setdefault('recoveries', []).append(dict(case=pending['case'], outcome='guarded_undo_restored'))
        else:
            raise RuntimeError('Interrupted edit does not match its recorded before/after state. Preserve the project and review pending checkpoint; no blind Undo performed.')
        self.report.pop('pending', None)
        self.save()

    def temporary(self, row, directory, label, mutate, verify, exercise_redo=False):
        before = self.project()
        before_file, after_file = directory / (label + '-before.json'), directory / (label + '-after.json')
        write_json(before_file, before)
        self.report['pending'] = dict(case=row['case'], label=label, before=str(before_file), after=None)
        self.save()
        after = None
        try:
            mutate()
            after = self.project()
            write_json(after_file, after)
            require(source(after) != source(before), f'{label}: expected real source change did not occur')
            self.report['pending']['after'] = str(after_file)
            self.save()
            result = verify(before, after)
            self.call('form_undo')
            require(source(self.project()) == source(before), f'{label}: Undo failed exact accepted-state restoration')
            if exercise_redo:
                self.call('form_redo')
                require(source(self.project()) == source(after), f'{label}: Redo failed exact edited-state restoration')
                self.call('form_undo')
                require(source(self.project()) == source(before), f'{label}: final Undo failed restoration')
            self.report.pop('pending', None)
            self.save()
            return result
        finally:
            # Recover only an exact recorded edit. A human/external change is
            # never undone to make this harness appear successful.
            if self.report.get('pending') and after is not None:
                try:
                    current = source(self.project())
                    if current == source(after):
                        self.call('form_undo')
                        require(source(self.project()) == source(before), f'{label}: failure cleanup did not restore source')
                        self.report['pending']['cleanup'] = 'restored_after_failed_assertion'
                    elif current != source(before):
                        self.report['pending']['cleanup'] = 'unknown_state_preserved'
                except Exception as cleanup:
                    self.report['pending']['cleanup_error'] = repr(cleanup)
                self.save()

    def schema(self):
        request = {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}
        completed = subprocess.run([str(self.session.helper)], input=json.dumps(request) + '\n', env=self.session.env,
                                   text=True, capture_output=True, timeout=30, check=True)
        data = json.loads(completed.stdout)
        tools = {tool['name']: tool['inputSchema'] for tool in data['result']['tools']}
        paper = tools['form_paper']['properties']
        require({'inspect', 'appearance', 'configure', 'set_finish', 'remove_finish', 'template_inspect'} <= set(paper['command']['enum']),
                'Packaged form_paper schema lacks required commands')
        require({'contents_object_id', 'interior_id', 'clearance_mm', 'bleed_mm', 'handoff', 'finish', 'stock'} <= set(paper),
                'Packaged form_paper schema lacks required physical/process fields')
        require('parameter' in tools['form_construction']['properties']['command']['enum'], 'Construction parameter API absent')
        write_json(self.folder / 'tools-list.json', data)
        return {'packaged_tools_sha256': sha_file(self.folder / 'tools-list.json'),
                'repository_catalog_sha256': sha_file(ROOT / 'Sources/FormCore/MCP.swift')}

    def inspect(self, row, directory):
        before = self.project()
        report = self.paper('inspect', row)
        appearance = self.paper('appearance', row)
        require(source(self.project()) == source(before), 'Read-only inspections changed source/history')
        require(len(report['net']['panels']) == row['expected_panels'], 'Saved panel count changed')
        require(appearance['manufacturingVerified'] is False and appearance['reliefRepresentation'] == 'surfaceShading',
                'Appearance inspection overstates manufacturing geometry/approval')
        require(not any(f['assignment']['enabled'] and (f['missingElementIDs'] or not f.get('sourceRevision'))
                        for f in appearance['finishes']), 'Seeded enabled finish source is missing')
        write_json(directory / 'inspect.json', report)
        write_json(directory / 'appearance.json', appearance)
        return report, appearance

    def width_edit(self, row, directory, inspected):
        definition = inspected['definition']['authored']
        width = next(p for p in definition['parameters'] if p['name'] == 'width')
        old = width['value']
        delta = min(max(1, abs(old) * .03), (width['maximum'] - old) / 2)
        if delta <= 0:
            delta = -min(max(1, abs(old) * .03), (old - width['minimum']) / 2)
        require(delta != 0, 'Width has no bounded editable value')
        value = old + delta
        def mutate():
            self.call('form_construction', dict(command='parameter', object_id=row['object_id'], values={'width': value}))
        def verify(before, after):
            a, b = obj(before, row['object_id']), obj(after, row['object_id'])
            require(math.isclose(b['parameters']['width'], value), 'Width edit did not reach authored source')
            require(canonical_artworks(before, row['object_id']) == canonical_artworks(after, row['object_id']),
                    'Dimension edit stretched/rewrote canonical artwork, type or inside source dimensions')
            require(a['paperConstruction'].get('finishes') == b['paperConstruction'].get('finishes'), 'Dimension edit retargeted finishes')
            require(a['paperConstruction']['stock'] == b['paperConstruction']['stock'], 'Width edit changed stock/caliper')
            require(expression_shape(a['paperConstruction']['authored']) == expression_shape(b['paperConstruction']['authored']),
                    'Dimension edit rewrote construction expressions')
            require([o for o in before['objects'] if o.get('designID') != a['designID']] ==
                    [o for o in after['objects'] if o.get('designID') != a['designID']], 'Width edit changed an unrelated object')
            changed = self.paper('inspect', row)
            require(changed['net'] != inspected['net'], 'Parameter edit changed metadata without regenerating geometry')
            require([p['id'] for p in changed['net']['panels']] == [p['id'] for p in inspected['net']['panels']], 'Width edit lost stable panel IDs')
            write_json(directory / 'width-inspect.json', changed)
            result = {'old_width_mm': old, 'edited_width_mm': value, 'artwork_and_finish_ids_retained': True,
                      'expressions_unchanged': True, 'undo_redo_restore': True}
            if row['case'] == '03':
                template = self.paper('template_inspect', row)
                require(template['geometry_review_required'] is True, 'Edited supplier geometry was not marked stale')
                rejected = directory / 'stale-template-must-not-exist.svg'
                self.call('form_paper', dict(command='export', object_id=row['object_id'], format='svg',
                          path=str(rejected), handoff='registered_original', count=1,
                          sheet_width=changed['net']['size']['x'] + 40, sheet_height=changed['net']['size']['y'] + 40), expected_failure=True)
                require(not rejected.exists(), 'Stale template handoff published a file')
                result['stale_template_rejected'] = True
            return result
        return self.temporary(row, directory, 'width', mutate, verify, exercise_redo=True)

    def rejected_edits(self, row):
        before = source(self.project())
        failures = []
        for arguments in [dict(command='configure', stock={'profile': {'roughness': -0.1}}),
                          dict(command='set_finish', finish={'kind': 'foil', 'elementIDs': [str(uuid.uuid4())]})]:
            arguments['object_id'] = row['object_id']
            failures.append(self.call('form_paper', arguments, expected_failure=True))
            require(source(self.project()) == before, 'Rejected stock/finish changed accepted source/history')
        return {'requests': failures, 'unchanged_after_each_rejection': True}

    def validate_geometry(self, row, directory, inspected):
        """Finite one-at-a-time cases, not a proof of the continuous range.

        The engine checks authored requirements before constructing geometry.
        A named requirement rejection stays visible and is never counted as
        passed geometry or a manufactured object.
        """
        before = source(self.project())
        pinned = self.call('form_construction', dict(command='inspect', object_id=row['object_id']))
        definition = inspected['definition']['authored']
        solid_ids = {value['id'] for value in definition.get('solidChecks', [])}
        connection_ids = {value['id'] for value in definition.get('connections', [])}
        declarations = [{'name': 'default', 'values': {}}]
        aliases = []
        for parameter in definition['parameters']:
            if parameter['name'] not in ['width', 'height', 'depth']:
                continue
            for label, value in [('minimum', parameter['minimum']), ('default', parameter['value']), ('maximum', parameter['maximum'])]:
                name = parameter['name'] + '.' + label
                if value == parameter['value']:
                    aliases.append({'name': name, 'alias_of': 'default', 'value_mm': value})
                else:
                    declarations.append({'name': name, 'values': {parameter['name']: value}})
        records = []
        unexpected = []
        for case in declarations:
            report = self.call('form_construction', dict(command='validate_cases', object_id=row['object_id'], cases=[case]))
            write_json(directory / ('validation-' + case['name'] + '-raw.json'), report)
            require(source(self.project()) == before, 'Read-only geometry/exact validation changed accepted source')
            require(report['source_revision'] == pinned['revision'], 'Parameter evidence is not pinned to the current source')
            require(len(report['cases']) == 1 and report['cases'][0]['name'] == case['name'], 'Case outcome was omitted/replaced')
            result = report['cases'][0]
            geometry = bool(result.get('size_mm') and result.get('panels') and result.get('resolved_panels') == result.get('panels'))
            if result.get('outcome') in ['budget_exceeded', 'cancelled', 'superseded', 'not_run'] or report.get('interruption'):
                classification = 'interrupted_not_accepted'
            elif not result['passed'] and result.get('requirement_id') and not geometry:
                classification = 'authored_constraint_rejected'
            elif not geometry:
                classification = 'geometry_failed'
            elif not all(value['passed'] for value in result.get('connection_checks', [])):
                classification = 'declared_connection_failed'
            elif not all(value['passed'] for value in result.get('solid_checks', [])):
                classification = 'declared_solid_check_failed'
            elif result['passed']:
                classification = 'geometry_and_declared_checks_passed' if solid_ids or connection_ids else 'geometry_only_passed'
            else:
                classification = 'failed_other'
            if geometry:
                require(result['panels'] == row['expected_panels'], 'Finite case lost stable panel topology')
                require(all(math.isfinite(x) and x > 0 for x in result['size_mm']), 'Finite case has invalid physical size')
                if result['passed']:
                    require({x['id'] for x in result.get('solid_checks', [])} == solid_ids, 'Declared solid measurements omitted from a passing report')
                    require({x['id'] for x in result.get('connection_checks', [])} == connection_ids, 'Declared connection measurements omitted from a passing report')
            entry = {'request': case, 'classification': classification, 'geometry_passed': geometry,
                     'declared_solid_checks': len(solid_ids), 'declared_connection_checks': len(connection_ids), 'report': report}
            records.append(entry)
            write_json(directory / ('validation-' + case['name'] + '.json'), entry)
            if classification not in ['geometry_only_passed', 'geometry_and_declared_checks_passed', 'authored_constraint_rejected'] or (
                    case['name'] == 'default' and classification == 'authored_constraint_rejected'):
                unexpected.append(case['name'])
        summary = {'cases': records, 'default_aliases': aliases,
                   'declared_solid_check_ids': sorted(solid_ids), 'declared_connection_check_ids': sorted(connection_ids),
                   'geometry_passes': sum(r['classification'] in ['geometry_only_passed', 'geometry_and_declared_checks_passed'] for r in records),
                   'conditional_requirement_rejections': sum(r['classification'] == 'authored_constraint_rejected' for r in records),
                   'unexpected_failures': unexpected, 'continuous_range_proven': False,
                   'manufacturing_coverage': 'Only explicitly declared solid/connection checks were evaluated; geometry-only passes are not manufacturing checks.'}
        write_json(directory / 'parameter-validation.json', summary)
        require(not unexpected, 'Finite construction cases failed: ' + ', '.join(unexpected))
        return summary

    def packet(self, row, directory, inspected):
        destination = directory / 'production.packet'
        net = inspected['net']
        sheet = [net['size']['x'] + 40, net['size']['y'] + 40]
        arguments = dict(format='packet', path=str(destination), bleed_mm=3, sheet_width=sheet[0],
                         sheet_height=sheet[1], margin=10, gap=6, count=1, handoff='registered_original' if row['case'] == '03' else 'separate')
        response = self.paper('export', row, **arguments)
        record = json.loads((destination / 'production.json').read_text())
        require(record['object_id'] == row['object_id'] and record['bleed_mm'] == 3, 'Packet has wrong owner/bleed')
        require(record['hardware_commands'] == [] and record['vendor_handoff_approved'] is False, 'Packet claims unverified hardware/approval')
        require(record['appearance']['manufacturingVerified'] is False, 'Packet claims verified manufacture')
        for name, expected in record['artifact_sha256'].items():
            require(sha_file(destination / name) == expected, f'Packet asset hash differs: {name}')
        expected_extent = [net['size']['x'] + 6, net['size']['y'] + 6]
        expected_box = [-3, -3] + expected_extent
        names = ['outside-artwork.svg', 'cut-crease.svg']
        if (destination / 'inside-artwork.svg').exists():
            names.append('inside-artwork.svg')
        names += [plate['file'] for plate in record['finishing_plates']]
        roots = {}
        for name in names:
            root, extent, box = svg_extent(destination / name)
            close_values(extent, expected_extent, name + ' physical extent')
            close_values(box, expected_box, name + ' common origin')
            roots[name] = root
        cut_root = roots['cut-crease.svg']
        cut_edges = [e for e in net['cutEdges'] if e.get('cutoutID')]
        for edge in cut_edges:
            path = xml_by_id(cut_root, edge['id'])
            require(path is not None and path.attrib.get('data-cut-kind') == edge['cutoutKind'], 'Actual cutout edge missing from cut output')
            coordinates = [float(x) for x in re.findall(r'[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?', path.attrib['d'])]
            close_values(coordinates, [edge['start']['x'], edge['start']['y'], edge['end']['x'], edge['end']['y']], 'Cutout edge geometry')
        active = [f for f in inspected['definition'].get('finishes', []) if f['enabled']]
        require({p['assignment']['id'] for p in record['finishing_plates']} == {f['id'] for f in active}, 'Enabled finish plate set differs')
        for plate in record['finishing_plates']:
            require(plate['manufacturing_tooling_verified'] is False, 'Mask plate claims verified tooling')
            artwork = xml_by_id(roots[plate['file']], 'artwork')
            require(artwork is not None and drawable_count(artwork) > 0, 'Declared finish produced an empty plate')
            for identifier in plate['assignment']['elementIDs']:
                require(xml_by_id(artwork, 'layer-' + identifier.upper()) is not None, 'Mask lost canonical target identity')
        blind_foil_absences = []
        for side, name in [('outside', 'outside-artwork.svg'), ('inside', 'inside-artwork.svg')]:
            if name not in roots:
                continue
            ink = {identifier for f in active if f['side'] == side and f['kind'] in ['flatInk', 'letterpress', 'screenPrint'] for identifier in f['elementIDs']}
            isolated = {identifier for f in active if f['side'] == side and f['kind'] in ['foil', 'emboss', 'deboss'] for identifier in f['elementIDs']} - ink
            for identifier in isolated:
                require(xml_by_id(roots[name], 'layer-' + identifier.upper()) is None,
                        'Blind/foil-only target was also exported as ordinary printed ink')
                blind_foil_absences.append({'side': side, 'element_id': identifier})
        pdfs = {name: verify_pdf(destination / name, sheet) for name in ['sheet-proof.pdf', 'inside-sheet-proof.pdf'] if (destination / name).exists()}
        result = {'path': str(destination), 'response': response, 'svg_files_with_common_extent': names,
                  'extent_mm': expected_extent, 'viewBox': expected_box, 'actual_cutout_edges_verified': len(cut_edges),
                  'finish_plates_verified': len(active), 'artifact_hashes_verified': len(record['artifact_sha256']), 'pdfs': pdfs}
        result['production_record_sha256'] = sha_file(destination / 'production.json')
        result['blind_foil_omitted_from_ordinary_ink'] = blind_foil_absences
        if row['case'] == '03':
            result['template'] = self.template(row, destination)
        return result

    def template(self, row, packet):
        inspected = self.paper('template_inspect', row)
        reference = inspected['template']
        original = (self.options.output / 'supplier-fixture.svg').read_bytes()
        require(hashlib.sha256(original).hexdigest() == reference['originalSHA256'], 'Retained template hash differs from input fixture')
        require((packet / 'manufacturer-original.svg').read_bytes() == original, 'Original supplier bytes changed in packet')
        original_root = ET.fromstring(original)
        registered_root = ET.parse(packet / 'manufacturer-registered-artwork.svg').getroot()
        for channel in reference['channels']:
            a = copy.deepcopy(xml_by_id(original_root, channel['elementID']))
            b = copy.deepcopy(xml_by_id(registered_root, channel['elementID']))
            require(a is not None and b is not None, 'Supplier technical channel missing')
            a.tail = b.tail = None
            require(ET.tostring(a) == ET.tostring(b), 'Supplier technical channel was rewritten')
        artwork = xml_by_id(registered_root, 'lab-registered-artwork')
        require(artwork is not None, 'Registered handoff omitted artwork')
        values = [float(x) for x in re.findall(r'[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?', artwork.attrib['transform'])]
        m = reference['canonicalToTemplate']
        close_values(values, [m[x] for x in ['a', 'b', 'c', 'd', 'tx', 'ty']], 'Canonical supplier registration')
        require(inspected['original_verified'] is True and inspected['geometry_review_required'] is False, 'Restored template was not current')
        seeded = row['template']['template']
        require(reference['instructions'] == seeded['instructions'] and reference.get('vendor') == seeded.get('vendor')
                and reference.get('revision') == seeded.get('revision'), 'Retained supplier instructions/provenance changed')
        clean_path = packet.parent / 'supplier-registered-artwork-only.svg'
        net = row['inspection']['net']
        self.paper('export', row, format='svg', path=str(clean_path), handoff='artwork_only', bleed_mm=3, count=1,
                   sheet_width=net['size']['x'] + 40, sheet_height=net['size']['y'] + 40)
        clean = ET.parse(clean_path).getroot()
        require(xml_by_id(clean, 'lab-registered-artwork') is not None, 'Clean supplier file lost registration')
        require(all(xml_by_id(clean, c['elementID']) is None for c in reference['channels']), 'Technical/instruction supplier layers leaked into artwork-only output')
        return {'original_sha256': reference['originalSHA256'], 'original_bytes_exact': True,
                'technical_channels_unchanged': len(reference['channels']), 'registration_verified': values,
                'instructions_exact': True, 'clean_artwork_path': str(clean_path), 'clean_artwork_has_no_supplier_technical_layers': True}

    def missing_target(self, row, directory, appearance, inspected):
        finish = next((f for f in appearance['finishes'] if f['assignment']['enabled']), None)
        if finish is None:
            return {'status': 'not_applicable', 'reason': 'No enabled finish in this seeded case; invalid-target authoring is independently rejected.'}
        identifier = finish['assignment']['elementIDs'][0]
        def mutate():
            self.call('form_edit_artwork', dict(command='delete', object_id=finish['sourceObjectID'], element_ids=[identifier]))
        def verify(before, after):
            report = self.paper('appearance', row)
            require(any(identifier in f['missingElementIDs'] for f in report['finishes']), 'Deleted target was silently retargeted/erased')
            destination = directory / 'missing-target-must-not-exist.packet'
            failed = self.call('form_paper', dict(command='export', object_id=row['object_id'], format='packet', path=str(destination),
                       bleed_mm=3, count=1, sheet_width=inspected['net']['size']['x'] + 40,
                       sheet_height=inspected['net']['size']['y'] + 40), expected_failure=True)
            require(not destination.exists(), 'Missing enabled finish published a partial packet')
            write_json(directory / 'missing-target-inspect.json', report)
            return {'status': 'passed', 'missing_id': identifier, 'rejection': failed, 'restored_by_undo': True}
        return self.temporary(row, directory, 'missing-target', mutate, verify)

    def contents(self, row, directory):
        if row['case'] not in ['04', '05']:
            return {'status': 'not_applicable'}
        before = source(self.project())
        interior = 'base-interior' if row['case'] == '04' else 'tray-interior'
        clearance = row.get('contents_clearance_mm', 1)
        result = self.paper('preflight', row, contents_object_id=row['contents_object_id'], interior_id=interior, clearance_mm=clearance)
        fit = result['contents_fit']
        require(fit['contentsObjectID'] == row['contents_object_id'] and fit['passed'] is True and fit['containmentPassed'] is True,
                'Actual modeled contents do not fit the declared ' + row['case'] + ' cavity')
        require(fit.get('sourceRevision') and fit.get('contentsRevision') and fit['clearanceMM'] == clearance, 'Fit lacks source/revision/physical-clearance evidence')
        require(source(self.project()) == before, 'Modeled contents preflight changed source')
        write_json(directory / 'modeled-contents-fit.json', result)
        return {'status': 'passed', 'result': result}

    def case(self, row):
        key = row['case']
        previous = self.report['cases'].get(key, {})
        if previous.get('status') == 'passed' and not self.options.redo:
            require(previous['restored_source_sha256'] == digest(source(self.project())), 'Cached case source differs; start a new --round')
            packet = Path(previous['packet']['path'])
            require(sha_file(packet / 'production.json') == previous['packet']['production_record_sha256'], 'Cached packet record changed')
            for name, expected in json.loads((packet / 'production.json').read_text())['artifact_sha256'].items():
                require(sha_file(packet / name) == expected, 'Cached packet artifact changed: ' + name)
            return
        attempt = max([int(p.name.split('-')[-1]) for p in (self.folder / key).glob('attempt-*') if p.is_dir()] + [0]) + 1
        directory = self.folder / key / f'attempt-{attempt:03d}'
        directory.mkdir(parents=True, exist_ok=False)
        state = {'status': 'running', 'name': row['name'], 'object_id': row['object_id'], 'directory': str(directory), 'started_at': time.time()}
        history = previous.get('attempts', []) + ([{k: v for k, v in previous.items() if k != 'attempts'}] if previous else [])
        state['attempts'] = history
        self.report['cases'][key] = state; self.save()
        before = source(self.project())
        try:
            inspected, appearance = self.inspect(row, directory)
            state['width_edit'] = self.width_edit(row, directory, inspected); self.save()
            state['invalid_edits'] = self.rejected_edits(row); self.save()
            state['parameter_validation'] = self.validate_geometry(row, directory, inspected); self.save()
            state['packet'] = self.packet(row, directory, inspected); self.save()
            state['missing_target'] = self.missing_target(row, directory, appearance, inspected); self.save()
            state['contents'] = self.contents(row, directory); self.save()
            before_reopen = self.project()
            appearance_before = self.paper('appearance', row)
            self.call('form_open_project', dict(project_id=self.seed['project_id']))
            reopened = self.project()
            require(source(reopened) == source(before_reopen), 'Save/reopen changed persisted project/source/appearance')
            require(self.paper('appearance', row) == appearance_before, 'Save/reopen changed stock/finish/source reports')
            write_json(directory / 'reopened-project.json', reopened)
            require(source(reopened) == before, 'Case did not preserve the accepted seeded project')
            state.update(status='passed', restored_source_sha256=digest(source(reopened)), reopen_exact=True, ended_at=time.time())
        except Exception as error:
            state.update(status='failed', error=repr(error), ended_at=time.time())
            self.report['status'] = 'failed'
            self.save(); write_json(directory / 'report.json', state)
            raise
        self.save(); write_json(directory / 'report.json', state)

    def run(self):
        status = self.call('form_status')
        require(Path(status['library_path']).resolve() == (self.options.output / 'Library').resolve(), 'Wrong native library; no checks were run')
        require(status['project_id'] == self.seed['project_id'], 'Seeded project must be active before checks')
        self.report['status'] = 'running'
        self.report['provenance'] = {'app': str(self.options.app.resolve()), 'executable_sha256': sha_file(self.options.app / 'Contents/MacOS/LAB'),
            'helper_sha256': sha_file(self.session.helper), 'checker_sha256': sha_file(Path(__file__)),
            'seeder_sha256': sha_file(ROOT / 'scripts/validate_paper_packaging.py'), 'seed_report_sha256': sha_file(self.seed_path),
            'definitions': {row['definition_file']: sha_file(ROOT / 'examples/paper-packaging' / row['definition_file']) for row in self.seed['cases']}}
        self.report['schemas'] = self.schema(); self.save(); self.recover()
        for row in self.seed['cases']:
            if not self.options.cases or row['case'] in self.options.cases:
                self.case(row)
        self.report['status'] = 'passed' if all(self.report['cases'].get(row['case'], {}).get('status') == 'passed' for row in self.seed['cases']) else 'partial'
        self.save()
        print(json.dumps({'status': self.report['status'], 'cases_passed': sum(c.get('status') == 'passed' for c in self.report['cases'].values()), 'report': str(self.report_path)}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=ROOT / 'build/LAB.app')
    parser.add_argument('--socket', default='/tmp/lab-paper-packaging-twelve.sock')
    parser.add_argument('--output', type=Path, default=ROOT / '.local/validation/paper-packaging/twelve-round-one')
    parser.add_argument('--round', default='round-one')
    parser.add_argument('--cases', type=lambda value: set(value.split(',')))
    parser.add_argument('--redo', action='store_true', help='Preserve and rerun selected case attempts')
    options = parser.parse_args()
    require(re.fullmatch(r'[A-Za-z0-9_-]+', options.round), 'Use a simple round name')
    options.output = options.output.resolve()
    Checker(options).run()


if __name__ == '__main__':
    main()
