#!/usr/bin/env python3
"""Independent before/after geometry proof for the source-only corner repair.

Pass a pre-repair portable starter. This never opens LAB or changes project data.
It supplements, rather than substitutes for, the actual app render comparison.
"""
from __future__ import annotations
import argparse, copy, importlib.util, json, math
from pathlib import Path

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('construction_source',HERE/'generate_starter.py')
source=importlib.util.module_from_spec(spec);spec.loader.exec_module(source)

def close(a,b,message):
 assert len(a)==len(b) and all(abs(x-y)<1e-7 for x,y in zip(a,b)),(message,a,b)

def points(definition,values):
 matrices,owners,thickness=source.pose_panels(definition,values)
 return {q['id']:[source.world(matrices[q['id']],(x,-y,z))
   for x,y in [source.pointnum(p,values) for p in q['polygon']]
   for z in [-thickness[q['id']]/2,thickness[q['id']]/2]] for q in definition['panels']},matrices,owners

def bounds(points):
 return [min(p[i] for p in points) for i in range(3)]+[max(p[i] for p in points) for i in range(3)]

def verify(before):
 after=source.build();report=[]
 assert before['stock']==after['stock'] and before['artworkSources']==after['artworkSources']
 repaired,patch=source.repair_cross_corner_bridges(before['definition'])
 assert repaired==after['definition'],'Repair must reproduce authored geometry without modifying any unrelated fields'
 assert source.repair_cross_corner_bridges(repaired)[1]['changedPanels']==0,'Repair must be idempotent'
 edited=copy.deepcopy(before['definition'])
 target=next(p for p in edited['panels'] if p['id']==patch['panelIDs'][0]);target['polygon'][0]['x']='123'
 try:source.repair_cross_corner_bridges(edited)
 except ValueError:pass
 else:raise AssertionError('Repair overwrote a user-edited corner')
 changed=set(patch['panelIDs']);tabs={p for p in changed if 'corner overlap' in p}
 for case in source.VARIANTS+[dict(id='outside-held',values=dict(dimensionReference=1)),dict(id='maximum-clearance-locked',values=dict(seatingMode=1,runningClearance=3,lidOverlap=12))]:
  old=source.with_values(before,case['values']);new=source.with_values(after,case['values'])
  source.validate(new)
  oldD,newD=old['definition'],new['definition'];v=source.resolve(newD['parameters'],newD['derived'])
  assert source.resolve(oldD['parameters'],oldD['derived'])==v,'Held dimensions changed'
  oldPolys={p['id']:[source.pointnum(x,v) for x in p['polygon']] for p in oldD['panels']}
  newPolys={p['id']:[source.pointnum(x,v) for x in p['polygon']] for p in newD['panels']}
  for c in newD['components']:
   ids=[id for id in oldPolys if id==c['id'] or id.startswith(c['id']+'/')]
   def flat_bounds(polys):
    pts=[p for id in ids for p in polys[id]]
    return [min(p[i] for p in pts) for i in range(2)]+[max(p[i] for p in pts) for i in range(2)]
   close(flat_bounds(oldPolys),flat_bounds(newPolys),c['id']+' flat source crop')
  for id in changed-tabs:
   retained=source.area(source.convex_intersection(oldPolys[id],newPolys[id]))
   assert abs(retained-source.area(oldPolys[id]))<1e-7,(id,'parent material removed')
  maxError=0
  for opening,explosion in [(0,0),(12,0),(65,73),(100,0)]:
   posed=source.resolve(newD['parameters'],newD['derived'],pose=dict(opening=opening,explosion=explosion))
   oldPts,_,oldOwners=points(oldD,posed);newPts,matrices,owners=points(newD,posed)
   for id in oldPts:
    if id in changed-tabs:continue
    for a,b in zip(oldPts[id],newPts[id]):
     error=math.dist(a,b);assert error<1e-7,(id,'previous folded geometry moved',error);maxError=max(maxError,error)
   for c in newD['components']:
    ids=[id for id in oldPts if owners[id]['id']==c['id']]
    close(bounds([p for id in ids for p in oldPts[id]]),bounds([p for id in ids for p in newPts[id]]),c['id']+' physical envelope')
   # The same hinge line now belongs to both actual parent and tab material.
   for hinge in newD['hinges']:
    if hinge['childPanelID'] not in tabs:continue
    assert source.number(hinge['layerOffsetMM'],posed)==0
    for key in ['start','end']:
     x,y=source.pointnum(hinge[key],posed)
     a=source.world(matrices[hinge['parentPanelID']],(x,-y,0));b=source.world(matrices[hinge['childPanelID']],(x,-y,0))
     close(a,b,hinge['id']+' connected material hinge')
  report.append(dict(id=case['id'],unchangedTabAndOtherGeometryErrorMM=maxError,activePieces=sum(source.number(c['enabled'],v)>.5 for c in newD['components']),posesChecked=4))
 return dict(changedPanels=patch['changedPanels'],changedHinges=patch['changedHinges'],retainedFaces=len(after['definition']['panels']),retainedPieces=len(after['definition']['components']),cases=report)

if __name__=='__main__':
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('baseline',type=Path);args=parser.parse_args()
 print(json.dumps(verify(json.loads(args.baseline.read_text())),indent=2))
