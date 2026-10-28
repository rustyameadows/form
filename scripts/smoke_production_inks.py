#!/usr/bin/env python3
"""Real packaged CMYK/spot workflow. Only a disposable .local library is allowed.

Never prints, sends to a device, installs profiles, or downloads ink libraries.
The parent acceptance run also inspects/renders the exported PDFs independently.
"""
import copy
import hashlib
import json
import pathlib
import re
import statistics
import time
import uuid
from smoke_mcp import Client, OUTPUT, ROOT


def element(kind, x, y, width, height, **values):
    return dict(id=str(uuid.uuid4()).upper(), kind=kind, x=x, y=y, width=width,
                height=height, text='', fontSize=12, color='#243C35') | values


def main():
    c = Client()
    try:
        status = c.call('form_status')
        library = pathlib.Path(status['library_path']).resolve()
        assert library.is_relative_to((ROOT / '.local').resolve()), 'Use a disposable .local validation library.'
        tools = c.discover(['form_swatch', 'form_color_profile', 'form_export_artwork', 'form_export_publication'])
        profiles = c.call('form_color_profile')['profiles']
        chosen = next(p for p in profiles if p['model'] == 'CMYK' and 'Generic' in p['name'])
        project = c.call('form_create_project', {'name': 'COLOR / Declared production inks'})
        sheet = c.call('form_add_object', {'recipe_id': 'artboard', 'name': 'COLOR / Opaque colorants',
            'parameters': {'width': 180, 'depth': 120}})
        title = element('text', 12, 5, 156, 9, text='FORM / COLORANTS IN PRACTICE', fontSize=15,
                        typography={'fontName': 'Georgia'})
        cards = [element('rectangle', 12 + i*31, 25, 25, 22) for i in range(5)]
        cyan = element('rectangle', 12, 68, 63, 30)
        orange = element('rectangle', 22, 74, 40, 18)
        white_base = element('rectangle', 83, 68, 16, 30)
        white = element('rectangle', 87, 72, 8, 22)
        mixed = element('rectangle', 107, 68, 32, 30)
        glyph = element('text', 150, 68, 22, 33, text='O', fontSize=48,
                        typography={'fontName': 'Georgia', 'frameMode': 'point'})
        note = element('text', 12, 108, 156, 8, text='180 × 120 MM / 3 MM BLEED / NORMAL KNOCKOUT / UNSCREENED MAPS',
                       fontSize=7, typography={'fontName': 'Menlo-Regular'})
        elements = [title] + cards + [cyan, orange, white_base, white, mixed, glyph, note]
        c.call('form_set_artwork', {'object_id': sheet['id'], 'artwork': {
            'background': '#FFFFFF', 'backgroundOpacity': 0, 'bleed': 3, 'elements': elements}})
        product = c.call('form_add_object', {'recipe_id': 'box', 'name': 'COLOR / Linked source',
            'parameters': {'width': 180, 'depth': 120, 'height': 8}, 'position': [210, 0, 0]})
        c.call('form_link_artwork', {'object_id': product['id'], 'source_object_id': sheet['id']})
        c.call('form_color_profile', {'command': 'set', 'object_id': sheet['id'], 'profile_path': chosen['path']})
        def art(): return c.call('form_get_artwork', {'object_id': sheet['id']})
        reference = art()['outputColorProfile']
        package = library / (project['id'] + '.form')
        assert hashlib.sha256((package/'Assets'/reference['asset']).read_bytes()).hexdigest() == reference['sha256']
        def refs():
            return {o['id']: o['file'] for o in json.loads((package/'Manifest.json').read_text())['objects']}
        source = art()
        def words(value): return [(e['id'], e['text'], e.get('typography'), e.get('textRuns')) for e in value['elements']]
        def ink(kind, components, name=None, tint=1):
            result = dict(kind=kind, components=dict(zip(['cyan','magenta','yellow','black'], components)), profile=reference, tint=tint)
            if name is not None: result['spotName'] = name
            return result
        def create(name, declaration):
            return c.call('form_swatch', {'command': 'create', 'name': name, 'print_ink': declaration})['swatch']
        def assign(swatch, items, **args):
            return c.call('form_swatch', {'command': 'assign', 'swatch_id': swatch['id'], 'object_id': sheet['id'],
                'element_ids': [e['id'] for e in items], **args})
        baseline = c.call('form_get_project'); files = refs()
        spots = [create('Orange %d%%' % percent, ink('spot', [0, .65, 1, .05], 'FORM Orange', percent/100))
                 for percent in [0, 25, 50, 75, 100]]
        assert refs() == files, 'Palette declarations must not rewrite unchanged object source files.'
        assert art() == source
        for swatch, card in zip(spots, cards): assign(swatch, [card])
        process = create('Process cyan', ink('process_cmyk', [1, 0, 0, 0]))
        four = create('Raw four components', ink('process_cmyk', [.1, .45, .8, .2]))
        varnish = create('White alternate', ink('spot', [0, 0, 0, 0], 'FORM Varnish'))
        assign(process, [cyan, white_base]); assign(spots[2], [orange]); assign(varnish, [white])
        assign(four, [mixed]); assign(spots[4], [glyph])
        assert words(art()) == words(source)
        saved = c.call('form_get_project')
        c.call('form_swatch', {'command': 'update', 'swatch_id': four['id'],
            'print_ink': ink('process_cmyk', [.125, .45, .8, .2])})
        changed = c.call('form_get_project')
        assert changed['objects'] == saved['objects'] and changed.get('textStyles') == saved.get('textStyles')
        c.call('form_undo'); assert c.call('form_get_project') == saved
        c.call('form_swatch', {'command': 'update', 'swatch_id': four['id'], 'color': '#123456'}, expect_error=True)
        c.call('form_swatch', {'command': 'delete', 'swatch_id': spots[4]['id']}, expect_error=True)
        c.call('form_swatch', {'command': 'detach', 'object_id': sheet['id'], 'element_ids': [glyph['id']]}, expect_error=True)
        c.call('form_swatch', {'command': 'create', 'name': 'Conflict', 'print_ink': ink('spot', [0, .1, 1, .05], 'FORM Orange')}, expect_error=True)
        c.call('form_batch', {'operations': [
            {'name': 'form_swatch', 'arguments': {'command': 'update', 'swatch_id': four['id'], 'name': 'Must roll back'}},
            {'name': 'form_swatch', 'arguments': {'command': 'create', 'name': 'Reserved', 'print_ink': ink('spot', [0,0,0,0], 'None')}}]}, expect_error=True)
        assert c.call('form_get_project') == saved
        missing = copy.deepcopy(four['printInk']); missing['profile']['sha256'] = 'b'*64; missing['profile']['asset'] = 'icc-'+'b'*64+'.icc'
        c.call('form_swatch', {'command': 'update', 'swatch_id': four['id'], 'print_ink': missing}, expect_error=True)
        assert c.call('form_get_project') == saved
        def export(label, mode=None, fmt='pdf', **args):
            values = dict(object_id=product['id'], format=fmt, path=str(OUTPUT/('production-ink-'+label+'.'+fmt))) | args
            if mode is not None: values['ink_output'] = mode
            return c.call('form_export_artwork', values)
        guarded = OUTPUT/'production-ink-guard.pdf'; guarded.write_bytes(b'EXISTING DESTINATION')
        c.call('form_export_artwork', {'object_id':product['id'],'format':'pdf','path':str(guarded)}, expect_error=True)
        assert guarded.read_bytes() == b'EXISTING DESTINATION'
        report = export('preflight', 'preflight')
        assert report['can_export_composite'] and report['can_export_plates']
        assert report['colorants'] == ['Cyan','Magenta','Yellow','Black','FORM Orange','FORM Varnish']
        outputs = {mode: export(mode, mode) for mode in ['composite','plates','preview']}
        composite = pathlib.Path(outputs['composite']['path']).read_bytes()
        assert b'/Separation /FORM#20Orange' in composite and b'/Separation /FORM#20Varnish' in composite
        assert b'/ICCBased' in composite and b'/N 4' in composite
        assert b'/Process cs 0.1 0.45 0.8 0.2 scn' in composite and b'/OP false /op false /OPM 0' in composite
        assert len(re.findall(rb'/Type /Page\b', pathlib.Path(outputs['plates']['path']).read_bytes())) == 6
        assert outputs['preview']['ink_declarations_encoded'] is False and outputs['preview']['color_space'] == 'sRGB'
        raster = export('raster-preview', fmt='png', dpi=100)
        assert raster['ink_output'] == 'preview' and raster['ink_declarations_encoded'] is False
        assert c.call('form_get_project') == saved
        unsupported = art(); unsupported['elements'][1]['opacity'] = .5
        c.call('form_set_artwork', {'object_id': sheet['id'], 'artwork': unsupported})
        assert export('unsupported', 'preflight')['can_export'] is False
        blocked = OUTPUT/'production-ink-unsupported.pdf'; blocked.write_bytes(b'KEEP')
        c.call('form_export_artwork', {'object_id':product['id'],'format':'pdf','ink_output':'composite','path':str(blocked)}, expect_error=True)
        assert blocked.read_bytes() == b'KEEP'
        c.call('form_undo'); assert c.call('form_get_project') == saved
        c.call('form_swatch', {'command':'update','swatch_id':spots[4]['id'],'print_ink':None})
        c.call('form_swatch', {'command':'detach','object_id':sheet['id'],'element_ids':[glyph['id']]})
        assert words(art()) == words(source)
        c.call('form_undo');c.call('form_undo');assert c.call('form_get_project') == saved
        times=[]
        for i in range(12):
            begin=time.perf_counter()
            c.call('form_swatch', {'command':'update','swatch_id':four['id'],'print_ink':ink('process_cmyk',[.1+((i+1)%2)*.025,.45,.8,.2])})
            times.append((time.perf_counter()-begin)*1000)
        # Explicitly restore the raw components used by the output proof.
        c.call('form_swatch', {'command':'update','swatch_id':four['id'],'print_ink':four['printInk']})
        before_reopen=c.call('form_get_project')
        c.call('form_open_project', {'project_id':project['id']})
        reopened=c.call('form_get_project')
        assert reopened['schemaVersion'] >= 35 and reopened['objects'] == saved['objects']
        assert reopened['swatches'] == before_reopen['swatches']
        assert 'requiresInkOutput' not in json.dumps(reopened)
        c.call('form_set_view', {'view':'artwork','object_id':sheet['id'],'element_ids':[mixed['id']]})
        result=dict(project_id=project['id'],sheet_id=sheet['id'],product_id=product['id'],four_component_swatch=four['id'],
            spot_swatch=spots[4]['id'],profile=reference,exports=outputs,preflight=report,tools=len(tools),
            palette_edit_median_ms=round(statistics.median(times),2),palette_edit_p95_ms=round(sorted(times)[-2],2),
            performance_scope='12 saved palette updates on one linked physical color card; not a press/RIP benchmark.',
            checks='Real packaged MCP; raw CMYK; real spot resources; white alternate; tint0; explicit preview; atomic rejection/Undo; no default flattening; source/link preservation; portable profile; schema35 reopen',
            native_acceptance_pending=True)
        (OUTPUT/'production-inks-smoke-report.json').write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps(result,indent=2))
    finally: c.close()


if __name__ == '__main__': main()
