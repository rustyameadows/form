#!/usr/bin/env python3
"""Packaged collection45 acceptance in a disposable .local FORM library.

No hardware/model calls, purchases or inventory deductions. Leaves the original
NASA collection open for the parent's separate native computer-use acceptance.
"""
import copy
import hashlib
import json
import pathlib
import time
import uuid
from smoke_mcp import Client, OUTPUT, ROOT


def identity():
    return str(uuid.uuid4()).upper()


def stable_builds(c):
    previous=None
    for _ in range(20):
        value=c.call('form_status')['renderer']['geometry_builds']
        if value==previous:
            return value
        previous=value
        time.sleep(.15)
    return previous


def check_packet(path):
    manifest=json.loads((path/'Manifest.json').read_bytes())
    assert manifest['schema']==45 and not manifest['machine_contacted'] and not manifest['inventory_deducted']
    for name,meta in manifest['files'].items():
        assert not name.startswith('/') and all(p not in ('','.','..') for p in name.split('/'))
        data=(path/name).read_bytes();assert len(data)==meta['bytes'] and hashlib.sha256(data).hexdigest()==meta['sha256']
    return manifest


def main():
    c=Client()
    try:
        library=pathlib.Path(c.call('form_status')['library_path']).resolve()
        assert library.is_relative_to((ROOT/'.local').resolve()), 'Use a disposable .local validation library.'
        tools=c.discover(['form_production_job','form_textile_stock','form_get_project','form_undo','form_redo'])
        tool=next(t for t in tools if t['name']=='form_production_job')
        assert 'collection' in tool['inputSchema']['properties']['kind']['enum'], 'Build the collection45 app before running this workflow.'
        p=c.call('form_create_project',{'name':'ORBITAL / Collection production acceptance','template':'flightJacket'})
        def project(): return c.call('form_get_project')
        def call(command,**args): return c.call('form_production_job',dict(kind='collection',command=command)|args)
        roots=[o for o in p['objects'] if o.get('textile',{}).get('kind')=='garment']
        spares=[o for o in p['objects'] if o.get('textile',{}).get('kind') in ('patch','label') and not o.get('textile',{}).get('attachment')]
        patch=next(o for o in spares if o['textile']['kind']=='patch');label=next(o for o in spares if o['textile']['kind']=='label')
        plan=dict(id=identity(),name='ORBITAL / Collection production',runs=[
            dict(id=identity(),objectID=roots[0]['id'],quantity=12,includeAttachments=True),
            dict(id=identity(),objectID=roots[1]['id'],quantity=8,includeAttachments=True),
            dict(id=identity(),objectID=patch['id'],quantity=6,includeAttachments=False),
            dict(id=identity(),objectID=label['id'],quantity=4,includeAttachments=False)],
            notes='Illustrative run declarations. Supplier data, stock, prices and manufacturing consumption are not inferred.')
        before=project();builds=stable_builds(c)
        preview=call('preflight',definition=plan)['preflight']
        assert sum(o['quantity'] for o in preview['occurrences'])==110
        assert sum(o['quantity'] for o in preview['occurrences'] if o.get('parentID'))==80
        assert not preview.get('completeTotal') and preview['unknowns']
        assert project()==before and stable_builds(c)==builds
        saved=call('save_plan',definition=plan)['plan'];after=project()
        assert after['schemaVersion']>=45 and after['objects']==before['objects'] and after['camera']==before['camera']
        c.call('form_undo');assert project()==before
        c.call('form_redo');assert project()==after
        bad=copy.deepcopy(saved);bad['runs'][0]['quantity']=True
        c.call('form_production_job',dict(kind='collection',command='save_plan',definition=bad),expect_error=True);assert project()==after
        bad=copy.deepcopy(saved);bad['runs'].append(copy.deepcopy(bad['runs'][0]))
        c.call('form_production_job',dict(kind='collection',command='preflight',definition=bad),expect_error=True);assert project()==after
        stock=dict(id=identity(),name='Validation-only declared trim',category='trim',unit='m',available='0.15',unitPrice='1',currency='USD',supplier='Manual test declaration')
        c.call('form_textile_stock',{'command':'save_supply','supply':stock});assert project()==after
        saved['extras']=[dict(id=identity(),name=' =VALIDATION(1,2)',quantity='0.1',unit='m',unitPrice='2.5',currency='USD',supplier='\t@DECLARED',sku='A,"B"'),
                         dict(id=identity(),name='Independent currency declaration',quantity='2',unit='piece',unitPrice='1.125',currency='EUR')]
        saved['rules']=[dict(rowID='extra/'+saved['extras'][0]['id'],stock=dict(supply=stock))]
        updated=call('save_plan',definition=saved)['plan'];priced=project()
        preview=call('preflight',plan_id=updated['id'])['preflight']
        assert preview['knownSubtotals']=={'USD':'0.25','EUR':'2.25'} and not preview.get('completeTotal')
        assert preview['stock'][0]['knownDemand']=='0.1' and preview['stock'][0]['status']=='sufficient'
        invalid=copy.deepcopy(updated);invalid['extras'][0]['unitPrice']='0.25x'
        c.call('form_production_job',dict(kind='collection',command='save_plan',definition=invalid),expect_error=True);assert project()==priced
        invalid=copy.deepcopy(updated);invalid['extras'][0]['unitPrice']='0.1234567890123'
        c.call('form_production_job',dict(kind='collection',command='save_plan',definition=invalid),expect_error=True);assert project()==priced
        newer=dict(stock,available='0',unitPrice='99');c.call('form_textile_stock',{'command':'save_supply','supply':newer})
        c.call('form_textile_stock',{'command':'remove_supply','stock_id':stock['id']});assert project()==priced
        assert call('preflight',plan_id=updated['id'])['preflight']['stock'][0]['available']=='0.15'
        capture=call('create',plan_id=updated['id']);job=capture['job'];captured=project()
        assert captured['objects']==priced['objects'] and captured['camera']==priced['camera']
        c.call('form_undo');assert project()==priced
        c.call('form_redo');assert project()==captured
        builds_after=stable_builds(c);assert builds_after==builds,'Collection-only records rebuilt the 3D source.'
        reopened=c.call('form_open_project',{'project_id':p['id']})
        assert reopened['collectionProduction']['captures'][0]['revisionDigest']==job['revisionDigest']
        assert call('get',job_id=job['id'])['current_source']=='matches'
        out=OUTPUT/('collection45-'+identity());out.mkdir()
        folder=out/'NASA';call('export',job_id=job['id'],format='folder',path=str(folder));manifest=check_packet(folder)
        assert b"' =VALIDATION" in (folder/'BOM.csv').read_bytes()
        original_files={name:(folder/name).read_bytes() for name in manifest['files']}
        original_files['Manifest.json']=(folder/'Manifest.json').read_bytes()
        # Preserve the source for the final native acceptance after demonstrating
        # that archived exports survive actual deletion and saved reopen.
        c.call('form_delete_objects',{'object_ids':[o['id'] for o in reopened['objects']]})
        deleted=project();c.call('form_open_project',{'project_id':p['id']})
        assert call('get',job_id=job['id'])['current_source']=='missing'
        archived=out/'After-source-deletion';call('export',job_id=job['id'],format='folder',path=str(archived))
        assert all((archived/name).read_bytes()==data for name,data in original_files.items())
        call('export',job_id=job['id'],format='zip',path=str(out/'Collection.zip'))
        assert project()['objects']==deleted['objects']
        # A project open clears domain Undo, so restore the source explicitly as
        # a separate reviewed project copy rather than pretending deletion Undo
        # survives a reopen. The original immutable capture stays exportable.
        visible=c.call('form_create_project',{'name':'ORBITAL / Collection native review','template':'flightJacket'})
        native_roots=[o for o in visible['objects'] if o.get('textile',{}).get('kind')=='garment']
        native_spares=[o for o in visible['objects'] if o.get('textile',{}).get('kind') in ('patch','label') and not o.get('textile',{}).get('attachment')]
        native_patch=next(o for o in native_spares if o['textile']['kind']=='patch');native_label=next(o for o in native_spares if o['textile']['kind']=='label')
        native_plan=dict(id=identity(),name='ORBITAL / Native collection review',runs=[dict(id=identity(),objectID=o['id'],quantity=q,includeAttachments=attached) for o,q,attached in [(native_roots[0],12,True),(native_roots[1],8,True),(native_patch,6,False),(native_label,4,False)]])
        native_saved=call('save_plan',definition=native_plan)['plan']
        report=dict(archive_project_id=p['id'],native_project_id=visible['id'],native_plan_id=native_saved['id'],plan_id=updated['id'],job_id=job['id'],path=str(out),
                    files_verified=len(manifest['files']),physical_occurrences=110,attached_details=80,
                    actual_geometry_builds_before=builds,actual_geometry_builds_after=builds_after,hardware_contacted=False,inventory_deducted=False,
                    checks='Explicit quantities; strict/atomic save; source-only geometry/camera; supply snapshots; exact decimal mixed-currency subtotals; one Undo; saved reopen; formula-safe CSV; immutable export after source deletion; ZIP',
                    native_acceptance_pending=True)
        (out/'smoke-report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
    finally:
        c.close()


if __name__=='__main__':
    main()
