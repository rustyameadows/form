import copy,json,math,sys
from pathlib import Path
sys.path.insert(0,str(Path('scripts').resolve()))
from validate_paper_packaging import Session
from render_paper_packaging import geometry,camera
s=Session(Path('build/LAB-paper-packaging-release.app'),'/tmp/lab-paper-packaging-twelve-v2.sock',Path('.local/validation/paper-packaging/twelve-round-two'));s.report=json.loads((s.output/'report.json').read_text())
rows={r['case']:r for r in s.report['cases']};records=[]
folder=s.output/'case-details';folder.mkdir(exist_ok=True)
def capture(key,name,outward,opening=None,offset=0,edge=False):
 row=rows[key];original=s.call('form_get_project');obj=next(o for o in original['objects'] if o['id']==row['object_id']);prior=obj['parameters'].get('opening',0);saved=None
 try:
  if opening is not None:s.call('form_construction',dict(command='parameter',object_id=obj['id'],values=dict(opening=opening)))
  project=s.call('form_get_project');obj=next(o for o in project['objects'] if o['id']==row['object_id']);info=s.call('form_construction',dict(command='inspect',object_id=obj['id']));points,_=geometry(info,obj)
  for p in points:p[1]+=offset
  scene=s.call('form_studio_scene',dict(command='create',name=name));scene['instances']=[i for i in scene['instances'] if i.get('sourceObjectID')==obj['id']]
  scene['instances'][0]['positionMM']['y']+=offset
  scene.update(camera=camera(points,outward),pixels=dict(width=1800,height=1200),lighting='rim-v1',surface='Daylight')
  if edge:scene['camera']=dict(azimuth=0,elevation=.02,distance=.06,target=dict(x=obj['position']['x']/100,y=.0045,z=(obj['position']['z']+27.5)/100),projection='orthographic',viewportAspect=1.5)
  saved=s.call('form_studio_scene',dict(command='save',scene=scene))
  destination=folder/(name+'.render');result=s.call('form_export',dict(format='png',scene_id=saved['id'],path=str(destination)))
  records.append(dict(name=name,case=key,result=result,opening=opening,instance_lift_mm=offset,intentional_detail_crop=edge))
 finally:
  if saved:s.call('form_studio_scene',dict(command='delete',scene_id=saved['id']))
  if opening is not None:s.call('form_construction',dict(command='parameter',object_id=obj['id'],values=dict(opening=prior)))
  now=s.call('form_get_project');a=next(o for o in original['objects'] if o['id']==obj['id']);b=next(o for o in now['objects'] if o['id']==obj['id']);assert a==b
 (folder/'report.json').write_text(json.dumps(records,indent=2)+'\n')
capture('03','03-retaining-feet-underside',[.25,-1,.35],offset=1000)
capture('06','06-envelope-back',[.25,.4,-1])
capture('09','09-duplex-edge',[0,.02,1],edge=True)
capture('11','11-closed-cover',[-1,.45,.1],opening=0)
capture('11','11-open-inside',[-1,.4,.1],opening=100)
s.call('form_set_view',dict(view='table'));s.call('form_set_view',dict(view='fit'));print('Five actual-case detail captures; all source objects restored exactly')
