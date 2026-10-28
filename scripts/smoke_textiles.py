#!/usr/bin/env python3
"""Validate the decorated bomber and authored stitch source through the local FORM app.

Use an isolated FORM_LIBRARY_PATH. Generates local files only; never connects to equipment.
"""
import copy
import json
import pathlib
import statistics
import time
from smoke_mcp import Client, OUTPUT, ROOT


def main():
    c=Client()
    try:
        status=c.call('form_status');library=pathlib.Path(status['library_path'])
        assert library.resolve().is_relative_to((ROOT/'.local').resolve()),'Use an isolated validation library.'
        p=c.call('form_create_project',{'name':'ORBITAL / Textile foundation','template':'flightJacket'})
        c.discover(['form_add_object', 'form_update_object'])
        jackets=[o for o in p['objects'] if o['recipeID']=='bomberJacket'];assert len(jackets)==2
        attached=[o for o in p['objects'] if o.get('textile',{}).get('attachment')];assert len(attached)==8
        sheets=[o for o in p['objects'] if o['recipeID']=='artboard'];assert len(sheets)==3
        digitized=[o for o in p['objects'] if o.get('textile',{}).get('embroidery')];assert len(digitized)==5
        assert all(not o['textile']['measurementsVerified'] for o in jackets)
        patch=next(o for o in attached if o['name'].startswith('Mission patch / left chest'))
        label=next(o for o in attached if o['recipeID']=='textileLabel')
        source=next(o for o in sheets if o['id']==patch['artworkSourceID'])
        package=library/(p['id']+'.form')
        def files():return {o['id']:o['file'] for o in json.loads((package/'Manifest.json').read_text())['objects']}
        baseline=c.call('form_get_project');old=files()
        art=copy.deepcopy(source['artwork']);art['elements'][0]['stroke']['color']='#E7BA71'
        c.call('form_set_artwork',{'object_id':patch['id'],'artwork':art})
        assert {k for k in old if files()[k]!=old[k]}=={source['id']}
        assert c.call('form_get_artwork',{'object_id':patch['id']})==art
        c.call('form_undo');assert c.call('form_get_project')==baseline
        metadata=copy.deepcopy(patch['textile']);metadata['attachment']['offset']={'x':18,'y':24}
        c.call('form_update_object',{'object_id':patch['id'],'textile':metadata})
        changed=c.call('form_get_project');assert next(o for o in changed['objects'] if o['id']==patch['id'])['textile']==metadata
        c.call('form_undo');assert c.call('form_get_project')==baseline
        bad=copy.deepcopy(metadata);bad['attachment']['garmentID']='00000000-0000-0000-0000-000000000001'
        c.call('form_batch',{'operations':[
            {'name':'form_update_object','arguments':{'object_id':jackets[0]['id'],'parameters':{'width':700}}},
            {'name':'form_update_object','arguments':{'object_id':patch['id'],'textile':bad}}]},expect_error=True)
        assert c.call('form_get_project')==baseline
        c.call('form_delete_objects',{'object_ids':[jackets[0]['id']]})
        detached=c.call('form_get_project')
        for obj in detached['objects']:
            a=obj.get('textile',{}).get('attachment');assert not a or a['garmentID']!=jackets[0]['id']
        c.call('form_undo');assert c.call('form_get_project')==baseline
        outputs={}
        for item,name in [(patch,'orbital-mission-patch'),(label,'orbital-sewn-label')]:
            for fmt in ['svg','pdf','png','jpeg']:
                outputs[name+'-'+fmt]=c.call('form_export_artwork',{'object_id':item['id'],'format':fmt,'dpi':300,'path':str(OUTPUT/(name+'.'+fmt))})
        c.call('form_open_project',{'project_id':p['id']})
        reopened=c.call('form_get_project');assert reopened['objects']==baseline['objects'];assert reopened['schemaVersion']>=17
        # Needle programs derive from saved intent; meshes/textures never replace source.
        needle_outputs={}
        for item in digitized:
            check=c.call('form_export_artwork',{'object_id':item['id'],'format':'preflight','embroidery_format':'preflight'})
            assert check['stitches']>1000 and check['underlay_stitches']>0
            assert check['tie_in_stitches']==0 and check['tie_off_stitches']==0
            assert len(check['thread_sequence'])==4 and check['verified_sew_out'] is False
        loose_patch=next(o for o in digitized if o['name']=='Mission patch / standalone')
        for fmt in ['dst','svg','json']:
            needle_outputs[fmt]=c.call('form_export_artwork',{'object_id':loose_patch['id'],'format':fmt,'embroidery_format':fmt,'path':str(OUTPUT/('orbital-mission-needle.'+fmt))})
        assert c.call('form_get_project')==reopened
        report={'project_id':p['id'],'jacket_ids':[o['id'] for o in jackets],'patch_id':patch['id'],'label_id':label['id'],
            'schema_version':reopened['schemaVersion'],'objects':len(reopened['objects']),'attached_decorations':len(attached),'source_resources':len(sheets),
            'digitized_placements':len(digitized),'outputs':outputs,'needle_outputs':needle_outputs,
            'limitations':['Generic concept measurements','Presentation blank, no garment cutting patterns or calibrated fit','Generated stitches and local DST are not a physically verified sew-out','Outer merrow-style border remains a construction appearance study'],'equipment_operations':0}
        (OUTPUT/'textile-report.json').write_text(json.dumps(report,indent=2));(OUTPUT/'textile-baseline.json').write_text(json.dumps(reopened,indent=2))
        print(json.dumps({k:v for k,v in report.items() if k!='outputs'},indent=2))
    finally:c.close()


if __name__=='__main__':main()
