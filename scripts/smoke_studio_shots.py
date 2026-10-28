#!/usr/bin/env python3
"""Packaged Studio shots smoke; only a disposable repo/.local library is accepted.

No installation, model/network API, hardware, simulation or inventory operation.
"""
import copy
import hashlib
import json
import pathlib
import struct
import uuid
from smoke_mcp import Client, OUTPUT, ROOT


def main():
    c=Client()
    try:
        status=c.call('form_status');library=pathlib.Path(status['library_path']).resolve()
        assert library.is_relative_to((ROOT/'.local').resolve()), 'Use a disposable FORM_LIBRARY_PATH under repo/.local.'
        c.discover(['form_set_view','form_export'])
        studio=library/'Studio.json';studio_before=studio.read_bytes() if studio.exists() else None
        project=c.call('form_create_project',{'name':'ORBITAL / Saved Studio shots','template':'merchandise'})
        camera=copy.deepcopy(project['camera']);camera['viewportAspect']=1.5
        subjects=[o['id'] for o in project['objects'] if o['recipeID']!='artboard' and not o.get('canvasWorkspace')]
        def op(command,**values):return c.call('form_set_view',{'view':'studio','studio_command':command,**values})
        before=c.call('form_get_project')
        stable=lambda p:{k:v for k,v in p.items() if k!='camera'}
        shot=op('capture',name='Field collection',camera=camera,reference_aspect=1.5,lighting='soft-side-v1',surface='Daylight',visibility={'mode':'objects','objectIDs':subjects},width=1200,height=800)
        saved=c.call('form_get_project');assert saved['objects']==project['objects'];assert len(saved['history'])==len(project['history'])+1
        c.call('form_undo');assert stable(c.call('form_get_project'))==stable(before)
        c.call('form_redo');assert stable(c.call('form_get_project'))==stable(saved)
        assert op('get',shot_id=shot['id'])==shot;assert op('list')['result']==[shot]
        assert stable(c.call('form_get_project'))==stable(saved)
        op('recall',shot_id=shot['id']);assert c.call('form_get_project')['objects']==project['objects']
        folder=OUTPUT/'studio-shots-smoke';folder.mkdir(parents=True,exist_ok=True)
        destination=folder/(str(uuid.uuid4())+'.render')
        report=c.call('form_export',{'format':'png','shot_id':shot['id'],'path':str(destination),'width':800,'height':1200})
        image=pathlib.Path(report['path']);record_path=pathlib.Path(report['record']);png=image.read_bytes();record=json.loads(record_path.read_text())
        assert struct.unpack('>II',png[16:24])==(800,1200)
        assert record['png_sha256']==hashlib.sha256(png).hexdigest()
        assert set(record['included_object_ids'])==set(subjects)
        assert record['shot']['camera']==camera and record['shot']['referenceAspect']==1.5
        assert record['source_archived'] is False
        assert all(r['id'].startswith(('asset:','font:')) and not r['id'].startswith('font:/') for r in record['resources'])
        current=c.call('form_get_project');assert current['objects']==project['objects'] and current['history']==saved['history']
        before_pair=(png,record_path.read_bytes())
        c.call('form_export',{'format':'png','shot_id':shot['id'],'path':str(destination)},expect_error=True)
        assert (image.read_bytes(),record_path.read_bytes())==before_pair
        for extra in [{'width':True,'height':1200},{'width':8192,'height':8192},{'width':3000}]:
            bad=folder/(str(uuid.uuid4())+'.render')
            c.call('form_export',{'format':'png','shot_id':shot['id'],'path':str(bad),**extra},expect_error=True)
            assert not bad.exists()
        renamed=op('rename',shot_id=shot['id'],name='Field / portrait proof');assert renamed['id']==shot['id'] and renamed['revision']==2
        c.call('form_undo');assert op('get',shot_id=shot['id'])==shot
        c.call('form_set_view',{'view':'front'})
        assert op('get',shot_id=shot['id'])==shot
        # Legacy PNG still uses its exact old dimensions and creates no sidecar.
        legacy=folder/(str(uuid.uuid4())+'.png');c.call('form_export',{'format':'png','path':str(legacy)})
        assert struct.unpack('>II',legacy.read_bytes()[16:24])==(3000,2000)
        reopened=c.call('form_open_project',{'project_id':project['id']});assert reopened['studioPresentation']['shots']==[shot]
        assert (studio.read_bytes() if studio.exists() else None)==studio_before
        result={'project_id':project['id'],'shot_id':shot['id'],'png':str(image),'record':str(record_path),'decoded_pixels':[800,1200],'legacy_pixels':[3000,2000],'png_sha256':record['png_sha256'],'hardware_operations':0,'ordinary_library_writes':0}
        (OUTPUT/'studio-shots-smoke-report.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
    finally:c.close()

if __name__=='__main__':main()
