#!/usr/bin/env python3
"""Render the editable twelve-case project through LAB's public native MCP tools."""
import argparse
import copy
import hashlib
import json
import math
from pathlib import Path
from validate_paper_packaging import ROOT, Session


def normalized(v):
    length = math.sqrt(sum(x*x for x in v))
    return [x/length for x in v]


def rotated(v, degrees):
    a=math.radians(degrees);c=math.cos(a);s=math.sin(a)
    return [c*v[0]+s*v[2],v[1],-s*v[0]+c*v[2]]


def geometry(inspection, obj):
    matrices={p['panelID']:p['flatToWorld'] for p in inspection['poses']}
    position=obj['position'];translation=[position[k] for k in ['x','y','z']]
    angle=obj.get('rotation',0)
    points=[]
    stock=obj.get('paperConstruction',{}).get('stock',{})
    caliper=sum(p['thicknessMM'] for p in stock.get('plies',[])) or stock.get('thicknessMM',.2)
    for panel in inspection['net']['panels']:
        m=matrices[panel['id']]
        for p in panel['polygon']:
            for z in [-caliper/2,caliper/2]:
                v=[m[r*4]*p['x']-m[r*4+1]*p['y']+m[r*4+2]*z+m[r*4+3] for r in range(3)]
                v=rotated(v,angle)
                points.append([v[i]+translation[i] for i in range(3)])
    return points, matrices


def camera(points, outward, margin=1.25, aspect=1.5):
    n=normalized(outward);azimuth=math.atan2(n[0],n[2]);elevation=math.asin(n[1])
    right=[math.cos(azimuth),0,-math.sin(azimuth)]
    up=[-math.sin(azimuth)*math.sin(elevation),math.cos(elevation),-math.cos(azimuth)*math.sin(elevation)]
    low=[min(p[i] for p in points) for i in range(3)];high=[max(p[i] for p in points) for i in range(3)]
    target=[(low[i]+high[i])/2 for i in range(3)]
    distance=10
    for p in points:
        delta=[p[i]-target[i] for i in range(3)]
        dot=lambda v:sum(delta[i]*v[i] for i in range(3))
        distance=max(distance,dot(n)+margin*max(abs(dot(up)),abs(dot(right))/aspect)/math.tan(math.radians(39/2)))
    return dict(azimuth=azimuth,elevation=elevation,distance=distance/100,
                target=dict(zip(['x','y','z'],[v/100 for v in target])),projection='perspective',viewportAspect=aspect)


def render(session, name, subject_ids, points, outward, lighting='soft-side-v1'):
    scenes=session.call('form_studio_scene',dict(command='list'))
    scene=next((s for s in scenes if s['name']==name),None)
    if scene is None: scene=session.call('form_studio_scene',dict(command='create',name=name))
    # Source selection/placement is explicit and uses the same native object renderer.
    project=session.call('form_get_project');objects={o['id']:o for o in project['objects']}
    prior={i.get('sourceObjectID'):i for i in scene['instances']}
    import uuid
    scene['instances']=[]
    for source_id in subject_ids:
        obj=objects[source_id]
        instance=copy.deepcopy(prior.get(source_id) or dict(id=str(uuid.uuid4()).upper(),name=obj['name'],sourceObjectID=source_id,visible=True))
        instance.update(positionMM=obj['position'],rotationDegrees=obj.get('rotation',0),visible=True)
        scene['instances'].append(instance)
    scene.update(camera=camera(points,outward),pixels=dict(width=1800,height=1200),lighting=lighting,surface='Daylight')
    saved=session.call('form_studio_scene',dict(command='save',scene=scene))
    parent=session.output/'renders'
    parent.mkdir(parents=True,exist_ok=True)
    path=parent/(name+'.render')
    if path.exists():
        path=parent/(name+'-'+str(len(list(parent.glob(name+'*.render'))))+'.render')
    result=session.call('form_export',dict(format='png',scene_id=saved['id'],path=str(path)))
    pngs=list(path.rglob('*.png')) if path.is_dir() else ([path] if path.suffix=='.png' else [])
    return dict(name=name,scene_id=saved['id'],lighting=lighting,result=result,
                images=[dict(path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in pngs])


def run(session, only=None):
    session.report=json.loads((session.output/'report.json').read_text())
    session.call('form_open_project',dict(project_id=session.report['project_id']))
    project=session.call('form_get_project');objects={o['id']:o for o in project['objects']}
    records=session.report.get('renders',[])
    all_points=[];all_ids=[]
    for row in session.report['cases']:
        inspection=session.call('form_construction',dict(command='inspect',object_id=row['object_id']))
        points,matrices=geometry(inspection,objects[row['object_id']]);all_points+=points
        subjects=[row['object_id']]
        for extra in ['contents_object_id','liner_object_id']:
            if row.get(extra):subjects.append(row[extra])
        all_ids+=subjects
        if only and row['case'] not in only:continue
        primary={'04':'lid-floor','05':'front-cover','11':'front'}.get(row['case'],'front')
        m=matrices[primary]
        normal=rotated([m[2],m[6],m[10]],objects[row['object_id']].get('rotation',0))
        # A slightly oblique view of the actual primary surface avoids edge-on cards.
        outward=[normal[0]+.22,normal[1]+.38,normal[2]+.25]
        if row['case']=='04':outward=[.25,1.2,1]
        if row['case']=='05':outward=[.4,1.1,1.2]
        if row['case']=='11':outward=[normal[0]+.2,normal[1]+.5,normal[2]-.4]
        if row['case']=='07':outward=[.3,.6,1] # open envelope/liner, not its front exterior
        record=render(session,row['case']+'-study',subjects,points,outward)
        records=[r for r in records if r['name']!=record['name']]+[record]
        session.report['renders']=records;session.save()
    if not only:
        record=render(session,'00-twelve-studies',all_ids,all_points,[.12,1,1.12])
        records=[r for r in records if r['name']!=record['name']]+[record]
    # Turn the real parametric sheet for reverse-side evidence, then restore it.
    # Temporary scenes are removed because their sources deliberately return to the front pose.
    for row in session.report['cases']:
        if row['case'] not in {'08','09','10','12'} or (only and row['case'] not in only):continue
        obj=objects[row['object_id']];prior=obj['parameters'].get('turn',0)
        temporary=None
        try:
            session.call('form_construction',dict(command='parameter',object_id=obj['id'],values=dict(turn=180)))
            current=session.call('form_get_project');turned=next(o for o in current['objects'] if o['id']==obj['id'])
            inspection=session.call('form_construction',dict(command='inspect',object_id=obj['id']))
            points,matrices=geometry(inspection,turned)
            record=render(session,row['case']+'-reverse',[obj['id']],points,[-.22,1,-.3])
            temporary=record['scene_id'];record['source_pose']=dict(turn=180);record['temporary_scene']=True
            records=[r for r in records if r['name']!=record['name']]+[record]
        finally:
            if temporary:session.call('form_studio_scene',dict(command='delete',scene_id=temporary))
            session.call('form_construction',dict(command='parameter',object_id=obj['id'],values=dict(turn=prior)))
    session.report['renders']=records;session.save()
    session.call('form_set_view',dict(view='table'))
    session.call('form_set_view',dict(view='fit'))
    print(json.dumps(dict(rendered=len(records),report=str(session.output/'report.json'))))


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--app',type=Path,default=ROOT/'build/LAB.app')
    parser.add_argument('--socket',default='/tmp/lab-paper-packaging-twelve.sock')
    parser.add_argument('--output',type=Path,default=ROOT/'.local/validation/paper-packaging/twelve-round-one')
    parser.add_argument('--only',nargs='*')
    options=parser.parse_args();run(Session(options.app,options.socket,options.output),options.only)
