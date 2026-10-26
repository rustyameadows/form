#!/usr/bin/env python3
"""Exercise original declared garment blocks through an already-running packaged app.

Requires a disposable FORM_LIBRARY_PATH under repo/.local. No printer/device calls.
--read-only-block UUID only queries an existing block, preserving the active draft.
"""
import argparse
import copy
import json
import pathlib

from smoke_mcp import Client, OUTPUT, ROOT


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--read-only-block')
    args=parser.parse_args()
    c=Client()
    try:
        status=c.call('form_status');library=pathlib.Path(status['library_path']).resolve()
        assert library.is_relative_to((ROOT/'.local').resolve()), 'Use a disposable FORM_LIBRARY_PATH below repo/.local.'
        c.discover(['form_edit_artwork','form_export_artwork'])
        def edit(owner,operation,**extra):
            return c.call('form_edit_artwork',{'object_id':owner,'command':'garment_block','operation':operation,**extra})
        if args.read_only_block:
            before=c.call('form_get_project')
            block=next(b for b in before.get('garmentBlocks',[]) if b['id'].lower()==args.read_only_block.lower())
            owner=block['bindings'][0]['objectID']
            for op in ['list','get','report']:edit(owner,op,block_id=block['id'])
            assert c.call('form_get_project')==before
            print(json.dumps({'read_only_block':block['id'],'project_unchanged':True,'equipment_operations':0},indent=2))
            return
        studio=library/'Studio.json';studio_before=studio.read_bytes() if studio.exists() else None
        project=c.call('form_create_project',{'name':'FIELD / Declared garment sizes'})
        c.call('form_set_view',{'view':'canvas'})
        project=c.call('form_get_project')
        owner=next(o['id'] for o in project['objects'] if o.get('canvasWorkspace'))
        before=c.call('form_get_project')
        result=edit(owner,'create',block={'name':'FIELD / gathered skirt'})
        block=result['block'];block_id=block['id'];saved=c.call('form_get_project')
        assert len(block['bindings'])==9 and len(block['seams'])==6 and not result['conflicts']
        c.call('form_undo');assert c.call('form_get_project')==before
        c.call('form_redo');assert c.call('form_get_project')==saved
        for op in ['list','get','report']:edit(owner,op,block_id=block_id)
        assert c.call('form_get_project')==saved
        def artwork():return c.call('form_get_artwork',{'object_id':owner})
        original=artwork();by_id={e['id']:e for e in original['elements']}
        base=next(row for row in block['sizes'] if row['id']==block['baseSizeID'])
        refs=[r for r in block['bindings'] if r['sizeID']==base['id']]
        for ref in refs:
            e=by_id[ref['elementID']]
            if ref['role']!='elastic':
                assert (e['width'],e['height'])==(550,718)
                assert e['sewingPiece']['edgeAllowances']=={'0':0,'2':0}
                assert [g['offset'] for g in e['sewingPiece']['constructionGuides']]==[8,38,688,703,68,673]
        folder=OUTPUT/'garment-block-smoke';folder.mkdir(parents=True,exist_ok=True)
        def export(name,fmt,object_id=owner,ids=None):
            path=folder/(name+'.'+fmt)
            args={'object_id':object_id,'pattern_pieces':True,'format':fmt,'path':str(path)}
            if ids:args['element_ids']=ids
            report=c.call('form_export_artwork',args);assert path.stat().st_size>500
            return report,path.read_bytes()
        base_ids=[r['elementID'] for r in refs]
        metadata,svg_before=export('field-skirt-base','svg',ids=base_ids)
        export('field-skirt-base','pdf',ids=base_ids)
        export('field-skirt-three-sizes','pdf')
        (folder/'field-skirt-metadata.json').write_text(json.dumps(metadata,indent=2)+'\n')
        edit(owner,'configure',block_id=block_id,block={'grade':{'hip':44}})
        chart_only=c.call('form_get_project');assert chart_only['objects']==saved['objects']
        _,svg_after=export('chart-only-source','svg',ids=base_ids);assert svg_after==svg_before
        updated=edit(owner,'update',block_id=block_id)
        next_block=updated['block'];next_art=artwork()
        assert [r['elementID'] for r in next_block['bindings']]==[r['elementID'] for r in block['bindings']]
        for ref in block['bindings']:
            old=by_id[ref['elementID']];new=next(e for e in next_art['elements'] if e['id']==ref['elementID'])
            assert [n['id'] for n in old['path']['contours'][0]['nodes']]==[n['id'] for n in new['path']['contours'][0]['nodes']]
        valid=c.call('form_get_project')
        c.call('form_edit_artwork',{'object_id':owner,'command':'garment_block','operation':'update','block_id':block_id,'block':{'grade':{'hip':10000}}},expect_error=True)
        assert c.call('form_get_project')==valid
        # Existing independent artwork operations do not create new managed bindings.
        c.call('form_edit_artwork',{'object_id':owner,'command':'duplicate','element_ids':base_ids})
        assert c.call('form_get_project')['garmentBlocks']==valid['garmentBlocks']
        c.call('form_undo');assert c.call('form_get_project')==valid
        # Hand edits require a revision; ordinary Update must keep the actual source.
        edited=copy.deepcopy(next_art)
        first_ref=next_block['bindings'][0]
        changed=next(e for e in edited['elements'] if e['id']==first_ref['elementID'])
        changed['sewingPiece']['notes']='Keep this original hand-edited construction note.'
        c.call('form_set_artwork',{'object_id':owner,'artwork':edited})
        hand_edit=c.call('form_get_project')
        c.call('form_edit_artwork',{'object_id':owner,'command':'garment_block','operation':'update','block_id':block_id},expect_error=True)
        assert c.call('form_get_project')==hand_edit
        revision=edit(owner,'create_revision',block_id=block_id)['block']
        assert set(r['elementID'] for r in revision['bindings']).isdisjoint(r['elementID'] for r in next_block['bindings'])
        assert next(e for e in artwork()['elements'] if e['id']==first_ref['elementID'])==changed
        # Transfer the complete pristine base size; an incomplete size rejects atomically.
        target=c.call('form_add_object',{'recipe_id':'artboard','name':'Independent size source','parameters':{'width':1800,'depth':3000}})
        before_transfer=c.call('form_get_project')
        c.call('form_edit_artwork',{'object_id':owner,'command':'transfer','target_object_id':target['id'],
               'element_ids':[r['elementID'] for r in refs if r['role']!='elastic']},expect_error=True)
        assert c.call('form_get_project')==before_transfer
        c.call('form_edit_artwork',{'object_id':owner,'command':'transfer','target_object_id':target['id'],'element_ids':base_ids})
        moved=edit(owner,'get',block_id=block_id)['block']
        assert all(r['objectID']==target['id'] for r in moved['bindings'] if r['sizeID']==base['id'])
        objects=c.call('form_get_project')['objects']
        detached=next(row for row in moved['sizes'] if row['id']!=moved['baseSizeID'])
        edit(owner,'detach_size',block_id=block_id,size_id=detached['id'])
        assert c.call('form_get_project')['objects']==objects
        c.call('form_undo')
        saved=c.call('form_get_project')
        c.call('form_open_project',{'project_id':project['id']})
        reopened=c.call('form_get_project');assert reopened['garmentBlocks']==saved['garmentBlocks']
        assert reopened['objects']==saved['objects']
        assert (studio.read_bytes() if studio.exists() else None)==studio_before
        report={'project_id':project['id'],'block_id':block_id,'revision_id':revision['id'],
                'checks':['three editable sizes','full718mm sewing sides and explicit folds','source-ID stability',
                          'chart-only render preservation','atomic invalid/manual-edit rejection','independent duplicate/revision',
                          'complete-size transfer','metadata detach without source deletion','Undo/Redo/autosave/reopen',
                          'physical PDF/SVG and unchanged Studio library'],
                'physical_proof':str(folder),'equipment_operations':0,'verified_fit':False}
        (OUTPUT/'garment-block-smoke-report.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps(report,indent=2))
    finally:c.close()


if __name__=='__main__':main()
