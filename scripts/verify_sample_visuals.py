#!/usr/bin/env python3
"""Capture shipped examples and check authored-paper artwork through native tools.

Uses a new private library/socket by default. --session attaches only to an
explicit existing validation session. No printer/solver/hardware commands run.
Pixel checks establish conversion recovery and material channels; saved images
also need human layout, camera and type-orientation review.
"""
import argparse,hashlib,json,math,os,re,subprocess,sys,time,uuid
from pathlib import Path
from PIL import Image,ImageChops

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
from smoke_mcp import Client


def digest(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def mask(path,kind):
 r,g,b=Image.open(path).convert('RGB').split()
 threshold=lambda image,n:image.point(lambda value:255 if value>n else 0)
 if kind=='blue':parts=[threshold(ImageChops.subtract(b,r),25),threshold(ImageChops.subtract(b,g),12),r.point(lambda value:255 if value<180 else 0)]
 elif kind=='orange':parts=[threshold(ImageChops.subtract(r,g),15),threshold(ImageChops.subtract(g,b),8)]
 elif kind=='red':parts=[threshold(ImageChops.subtract(r,g),25),threshold(ImageChops.subtract(r,b),25)]
 elif kind=='green':parts=[threshold(ImageChops.subtract(g,r),10),threshold(ImageChops.subtract(g,b),10)]
 elif kind=='purple':parts=[threshold(ImageChops.subtract(r,g),15),threshold(ImageChops.subtract(b,g),15)]
 else:raise ValueError(kind)
 result=parts[0]
 for part in parts[1:]:result=ImageChops.multiply(result,part)
 return result

def pixels(image):return image.histogram()[255]
def element(kind,x,y,width,height,color,text='',font_size=14):
 return dict(id=str(uuid.uuid4()),kind=kind,x=x,y=y,width=width,height=height,color=color,text=text,fontSize=font_size)

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--app',type=Path,default=ROOT/'build/LAB.app');p.add_argument('--output',type=Path,required=True);p.add_argument('--session',type=Path);p.add_argument('--skip-sweep',action='store_true');p.add_argument('--keep-app',action='store_true');a=p.parse_args();out=a.output.resolve();assert out.is_relative_to(ROOT/'.local/validation');out.mkdir(parents=True,exist_ok=False);owned=None;client=None;success=False
 if a.session:
  session=json.loads(a.session.read_text());library=Path(session['library']).resolve();assert library.is_relative_to(ROOT/'.local/validation');app=Path(session['app']);socket=session['socket']
 else:
  app=a.app.resolve();library=out/'Library';library.mkdir();socket='/tmp/lab-visual-'+uuid.uuid4().hex[:16]+'.sock';session={}
 os.environ.update(LAB_LIBRARY_PATH=str(library),FORM_LIBRARY_PATH=str(library),LAB_SOCKET_PATH=socket,FORM_SOCKET_PATH=socket,LAB_MCP_PATH=str(app/'Contents/MacOS/lab-mcp'))
 report=dict(app=str(app),app_sha256=digest(app/'Contents/MacOS/LAB'),helper_sha256=digest(app/'Contents/MacOS/lab-mcp'),library=str(library),socket=socket,cases=[],sample_overviews=[],hardware_commands=[],inside_orientation='Inspect the asymmetric inside marker; channel presence alone does not prove upright type.')
 def save():(out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
 try:
  if not a.session:
   with (out/'app.log').open('w') as log:owned=subprocess.Popen([str(app/'Contents/MacOS/LAB')],env=os.environ,stdout=log,stderr=log,start_new_session=a.keep_app)
   deadline=time.monotonic()+30
   while not Path(socket).exists():
    assert owned.poll() is None,'Owned app exited before bridge';assert time.monotonic()<deadline,'Bridge startup timeout';time.sleep(.1)
   report['owned_pid']=owned.pid
  else:report['attached_validation_pid']=session['pid']
  client=Client();assert Path(client.call('form_status')['library_path']).resolve()==library;save()
  def capture(name,oid,camera,visibility=None,width=1000,height=1000):
   shot=client.call('form_set_view',dict(view='studio',studio_command='capture',name=name,camera=camera,reference_aspect=camera.get('viewportAspect',1),lighting='soft-side-v1',surface='Daylight',visibility=visibility or dict(mode='objects',objectIDs=[oid]),width=width,height=height))
   rendered=client.call('form_export',dict(format='png',shot_id=shot['id'],path=str(out/(name+'.render'))));image=Image.open(rendered['path']);assert image.size==(width,height)
   record=dict(case=name,object_id=oid,shot=shot,render=rendered,sha256=digest(rendered['path']));report['cases'].append(record);save();return rendered['path']
  def flat_camera(obj,net,inside=False):return dict(azimuth=math.radians(obj.get('rotation',0))+(math.pi if inside else 0),elevation=(-1 if inside else 1)*math.pi/2,distance=max(net['size']['x'],net['size']['y'])*1.16/72,target={axis:obj['position'][axis]/100 for axis in ['x','y','z']},projection='orthographic',viewportAspect=1)
  client.call('form_create_project',dict(name='Native cyanotype conversion pixel audit',template='cyanotype'));project=client.call('form_get_project');obj=next(o for o in project['objects'] if o['recipeID']=='paperEnvelope');oid=obj['id'];original=obj['artwork'];(out/'pristine-project.json').write_text(json.dumps(project,indent=2)+'\n');yaw=math.radians(obj.get('rotation',0));target=dict(x=obj['position']['x']/100,y=obj['position']['y']/100+obj['parameters']['height']/200,z=obj['position']['z']/100);cameras={side:dict(azimuth=yaw+(0 if side=='front' else math.pi),elevation=.05,distance=4.7,target=target,projection='orthographic',viewportAspect=1) for side in ['front','back']};pictures={}
  for phase in ['pristine','converted']:
   if phase=='converted':report['conversion']=client.call('form_construction',dict(command='convert',object_id=oid))
   for side,camera in cameras.items():pictures[phase+'-'+side]=capture(phase+'-'+side,oid,camera)
  current=next(o for o in client.call('form_get_project')['objects'] if o['id']==oid);assert current['artwork']==original;assert current['position']==obj['position'] and current['rotation']==obj['rotation'];report['source_and_placement_preserved']=True;report['conversion_pixel_checks']={}
  for side in ['front','back']:
   before,after=mask(pictures['pristine-'+side],'blue'),mask(pictures['converted-'+side],'blue');counts=[pixels(before),pixels(after)];intersection=pixels(ImageChops.multiply(before,after));union=pixels(ImageChops.lighter(before,after));iou=intersection/union if union else 0;assert min(counts)>1000 and iou>.995,(side,counts,iou);report['conversion_pixel_checks'][side]=dict(blue_pixels=counts,mask_iou=iou)
  net=client.call('form_paper',dict(command='inspect',object_id=oid))['net'];client.call('form_update_object',dict(object_id=oid,parameters=dict(fold=0,opening=0)));outside=capture('flat-outside',oid,flat_camera(obj,net));blank=capture('flat-inside-blank',oid,flat_camera(obj,net,True));assert pixels(mask(blank,'blue'))==0
  inside=client.call('form_paper',dict(command='ensure_inside',object_id=oid))['inside_source_id']
  client.call('form_set_artwork',dict(object_id=inside,artwork=dict(background='#F7F5EF',backgroundOpacity=0,bleed=0,elements=[])))
  markers=[element('rectangle',25,45,60,50,'#DB7330'),element('text',30,57,50,25,'#202020','INSIDE R',18)]
  frame=dict(surface_id='front',side='inside')
  client.call('form_edit_artwork',dict(object_id=oid,physical_frame=frame,command='add',elements=markers))
  registered=client.call('form_get_artwork',dict(object_id=inside))
  readable=client.call('form_get_artwork',dict(object_id=oid,physical_frame=frame))
  assert all(e.get('affine',{}).get('a',1)<0 for e in registered['elements'])
  assert all(abs(e.get('affine',{}).get('a',1)-1)<1e-9 for e in readable['elements'])
  assert {uuid.UUID(e['id']) for e in registered['elements']}=={uuid.UUID(e['id']) for e in markers},(registered['elements'],markers)
  report['inside_physical_frame']=dict(source_object_id=inside,frame=frame,registered_source_reflected_once=True,readable_frame_roundtrip=True)
  inside_image=capture('flat-inside-marker',oid,flat_camera(obj,net,True))
  outside_after=capture('flat-outside-after-inside',oid,flat_camera(obj,net))
  assert pixels(mask(inside_image,'orange'))>1000
  assert pixels(mask(outside_after,'orange'))==0
  assert pixels(ImageChops.difference(mask(outside,'blue'),mask(outside_after,'blue')))==0
  assert next(o for o in client.call('form_get_project')['objects'] if o['id']==oid)['artwork']==original
  report['inside_outside_channels_preserved']=True
  client.call('form_create_project',dict(name='Arbitrary construction color audit',template='blank'));definition=client.call('form_construction',dict(command='capabilities'))['example'];new=client.call('form_construction',dict(command='create',name='Unregistered source',definition=definition));newid=new['object_id'];newnet=new['net'];colors=['#254F91','#C54131','#31945C','#773D94'];elements=[]
  for panel,color in zip(newnet['panels'],colors):
   xs=[v['x'] for v in panel['polygon']];ys=[v['y'] for v in panel['polygon']];elements.append(element('rectangle',min(xs)+2,min(ys)+2,max(xs)-min(xs)-4,max(ys)-min(ys)-4,color))
  client.call('form_set_artwork',dict(object_id=newid,artwork=dict(background='#FFFFFF',backgroundOpacity=0,bleed=0,elements=elements)));client.call('form_update_object',dict(object_id=newid,parameters=dict(fold=0)));newobj=next(o for o in client.call('form_get_project')['objects'] if o['id']==newid);assert newobj['recipeID'].startswith('construction-');picture=capture('new-authored-outside',newid,flat_camera(newobj,newnet));counts={color:pixels(mask(picture,color)) for color in ['blue','red','green','purple']};assert min(counts.values())>1000,counts;report['arbitrary_source_color_pixels']=counts
  if not a.skip_sweep:
   templates=re.findall(r'\bid\s*:\s*"([^"]+)"',(ROOT/'Sources/FormCore/StudyTemplates.swift').read_text());report['template_registry']=templates
   for template in templates:
    client.call('form_create_project',dict(name='Native sample visual audit / '+template,template=template));project=client.call('form_get_project');(out/(template+'-source.json')).write_text(json.dumps(project,indent=2)+'\n');physical=[o for o in project['objects'] if not o.get('canvasWorkspace')];assert physical;picture=capture('sample-'+template,physical[0]['id'],project['camera'],dict(mode='project',objectIDs=[]),1200,900);report['sample_overviews'].append(dict(template=template,project_id=project['id'],physical_objects=len(physical),image=picture,source_artwork_objects=sum(bool(o.get('artwork') or o.get('artworkSourceID')) for o in physical)));save()
   assert len(report['sample_overviews'])==len(templates)
  report['core_pixel_checks_passed']=True;report['human_visual_review_required']=True;save();success=True;print(json.dumps(dict(report=str(out/'report.json'),native_captures=len(report['cases']),core_pixel_checks_passed=True,samples=len(report['sample_overviews'])),indent=2))
 except Exception as error:report['error']=str(error);save();raise
 finally:
  if client:client.close()
  if owned and (not a.keep_app or not success) and owned.poll() is None:
   owned.terminate()
   try:owned.wait(timeout=10)
   except subprocess.TimeoutExpired:owned.kill();owned.wait(timeout=5)
  if owned and (not a.keep_app or not success):Path(socket).unlink(missing_ok=True)

if __name__=='__main__':main()
