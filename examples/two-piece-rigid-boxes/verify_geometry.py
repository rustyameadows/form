#!/usr/bin/env python3
"""Independent physical face/contact inspection of emitted generic source data."""
from __future__ import annotations
import json, math
import generate_starter as g

def faces(poly,m,t):
 lower=[g.world(m,(x,-y,-t/2)) for x,y in poly]
 upper=[g.world(m,(x,-y,t/2)) for x,y in poly]
 return [lower,upper]+[[lower[i],lower[(i+1)%len(poly)],upper[(i+1)%len(poly)],upper[i]] for i in range(len(poly))]

def review(starter):
 d=starter['definition'];vs=g.resolve(d['parameters'],d['derived']);matrices,owners,calipers=g.pose_panels(d,vs)
 active={c['id'] for c in d['components'] if g.number(c['enabled'],vs)>.5}
 halfFaces={'base':[],'lid':[]};basePoints=[];bodyPoints=[]
 for panel in d['panels']:
  owner=owners[panel['id']]
  if owner['id'] not in active:continue
  poly=[g.pointnum(q,vs) for q in panel['polygon']];ff=faces(poly,matrices[panel['id']],calipers[panel['id']])
  for f in ff:
   if max(p[1] for p in f)-min(p[1] for p in f)<1e-6 and g.area([(q[0],q[2]) for q in f])>.001:
    halfFaces[owner['groupID']].append((panel['id'],f))
  if owner['groupID']=='base':
   points=sum(ff,[]);basePoints.extend(points)
   if owner['purpose']!='seating':bodyPoints.extend(points)
 # Wire crowns are real exterior material even without a covering/backing sheet.
 if vs['bwired']:
  # Supported source route is exactly perpendicular to the floor, so the
  # rectangular mitered crown reaches one full wire depth below its underside.
  basePoints.append((0,-vs['stapleWire'],0));bodyPoints.append((0,-vs['stapleWire'],0))
 size=lambda pts:[max(p[i] for p in pts)-min(p[i] for p in pts) for i in range(3)]
 overall=size(basePoints);body=size(bodyPoints)
 expected=[vs['baseOutsideW'],vs['baseOutsideH'],vs['baseOutsideD']]
 for actual,target in zip(overall,expected):assert abs(actual-target)<1e-6,('physical outside envelope',actual,target,starter['name'])
 assert abs(body[0]-vs['bfinishedW'])<1e-6 and abs(body[2]-vs['bfinishedD'])<1e-6
 targetY=vs['baseRim']-vs['overlap'] if vs['seatingMode'] else vs['baseRim']+vs['headspace']
 contacts=[]
 for aid,A in halfFaces['base']:
  if abs(A[0][1]-targetY)>1e-6:continue
  for bid,B in halfFaces['lid']:
   if abs(B[0][1]-targetY)>1e-6:continue
   a,b=[(p[0],p[2]) for p in A],[(p[0],p[2]) for p in B]
   contact=g.area(g.convex_intersection(a,b))
   if contact>.001:contacts.append(dict(base=aid,lid=bid,areaMM2=contact,yMM=targetY))
 assert contacts,('no actual closed seating faces',starter['name'],targetY)
 return dict(baseOutsideMM=overall,fitRegionXZ=[body[0],body[2]],seatingContactCount=len(contacts),seatingContactAreaMM2=sum(q['areaMM2'] for q in contacts),seatingContactPairs=contacts)

if __name__=='__main__':
 source=g.build();reports=[]
 for case in g.VARIANTS:
  s=g.with_values(source,case['values']);s['name']=case['name'];g.validate(s);reports.append(dict(id=case['id'],review=review(s)))
 # Deliberately combine maximum running clearance with overlap locking and hold
 # overall outside dimensions. Contact must persist; ledges must reach the rim.
 for id,changes in [('large-clearance-locked',dict(seatingMode=1,runningClearance=3,lidOverlap=12)),('outside-locked',dict(dimensionReference=1,seatingMode=1,runningClearance=2.5,lidOverlap=12)),('outside-shims',dict(dimensionReference=1,axialSpace=3))]:
  s=g.with_values(source,changes);s['name']=id;g.validate(s);reports.append(dict(id=id,review=review(s)))
 print(json.dumps(reports,indent=2))
