#!/usr/bin/env python3
"""Original CASK/COLLECT construction data, expressed only with LAB's public generic schema.

No app internals, live app, private storage, image service, printing or hardware.
Running emits the portable starter and independent option-case source snapshots.
"""
from __future__ import annotations
import argparse, ast, copy, hashlib, json, math, operator, uuid
from pathlib import Path
NS=uuid.UUID('df042f12-c046-4de7-a2f8-72c7d467d0cc')
HERE=Path(__file__).resolve().parent
ROOT=HERE.parent.parent
OUT=ROOT/'Sources/FormCore/Resources/ConstructionStarters/two-piece-setup.json'
def uid(s): return str(uuid.uuid5(NS,s)).upper()
def p(x=0,y=0): return dict(x=x,y=y)
def v(x=0,y=0,z=0): return dict(x=x,y=y,z=z)
def e(s): return str(s)
def add(a,b): return f'({a})+({b})'
def rect(x,y,w,h): return [p(x,y),p(add(x,w),y),p(add(x,w),add(y,h)),p(x,add(y,h))]
def eq(a,b): return f'max(0,1-abs(({a})-({b})))'
def inherit(global_,local): return f'{global_}*(1-clamp({local}+1,0,1))+{local}*clamp({local}+1,0,1)'
def profile(color,texture='cotton',scale=.75,depth=.012,roughness=.9):
 return dict(texture=texture,color=color,roughness=roughness,textureScaleMM=scale,textureDepthMM=depth,opacity=1)
def stock(name,t,color,texture='cotton',**extra):
 return dict(name=name,thicknessMM=t,grain='parallelWidth',verified=False,
  notes='Declared prototype caliper and appearance. Verify actual stock, adhesive, fold allowance and tool settings on physical samples.',
  profile=profile(color,texture,1 if texture=='linen' else .8,.035 if texture=='linen' else .012),**extra)
BOARD=stock('Recycled greyboard',2,'#AEA58F','recycled')
PAPER=stock('Uncoated oat covering paper',.16,'#E7DFCE','laid',gsm=130)
CLOTH=stock('Paper-backed deep spruce bookcloth',.24,'#244747','linen')
CLOTH['plies']=[dict(id=uid('cloth/backing'),name='Paper backing',color='#D8CDB6',thicknessMM=.08,profile=profile('#D8CDB6')),
 dict(id=uid('cloth/face'),name='Woven face',color='#244747',thicknessMM=.16,profile=profile('#244747','linen',.9,.035))]
LINER=stock('Warm ivory lining paper',.15,'#F1E5CA','cotton',gsm=120)
TAPE=stock('Gummed kozo reinforcement tape',.12,'#CDBA91','laid',gsm=100)
BACKING=stock('Crown-leveling paperboard backing',.35,'#C7BDA8','recycled')

class Source:
 def __init__(self):
  self.params=[];self.aliases={};self.panels=[];self.hinges=[];self.components=[];self.joins=[];self.attach=[];self.guides=[];self.roles={};self.controls=[];self.requirements=[];self.pieces={}
 def A(self,n,s):
  assert n not in self.aliases,n
  self.aliases[n]=s;return n
 def param(self,n,value,lo,hi,label,group,unit='mm',choices=None,help=None,visible=None,step=None):
  self.params.append(dict(name=n,value=value,minimum=lo,maximum=hi,unit=unit))
  c=dict(parameter=n,label=label,group=group,step=step or (1 if choices else .1))
  if choices is not None:c['choices']=[dict(label=l,value=i) for i,l in choices]
  if help:c['help']=help
  if visible is not None:c['visibleWhen']=visible
  self.controls.append(c);return n
 def require(self,id,lhs,relation,rhs,message):self.requirements.append(dict(id=id,lhs=lhs,relation=relation,rhs=rhs,message=message))
 def piece(self,id,name,half,purpose,material,caliper,enabled=1,front=None,finishes=None):
  i=len(self.components);sx=f'5+{i%6}*atlasW';sy=f'5+{i//6}*atlasH'
  c=dict(id=id,name=name,rootPanelID=id,anchor=p(sx,sy),position=v(),rotationDegrees=v(),groupID=half,stock=copy.deepcopy(material),stockThickness=caliper,quantity=1,purpose=purpose,enabled=enabled)
  if front:c['front']=front
  if finishes:c['finishes']=finishes
  self.components.append(c);o=Piece(self,c,sx,sy);self.pieces[id]=o;return o
 def join(self,id,a,b,enabled=1,kind='bond',notes=''):
  self.joins.append(dict(id=id,name=id.replace('-',' ').title(),firstPanelID=a,secondPanelID=b,kind=kind,overlapMM=0,notes=notes,enabled=enabled));return id

class Piece:
 def __init__(self,s,c,sx,sy):self.s=s;self.c=c;self.sx=sx;self.sy=sy;self.ids=[]
 def point(self,x,y):return p(add(self.sx,x),add(self.sy,y))
 def polygon(self,id,points,role='body',cutouts=None):
  full=self.c['id'] if not self.ids else self.c['id']+'/'+id
  panel=dict(id=full,name=self.c['name']+' · '+id,role=role,polygon=[self.point(q['x'],q['y']) for q in points])
  if cutouts:panel['cutouts']=[dict(id=f'{full}/slot-{i}',kind='slot',polygon=[self.point(q['x'],q['y']) for q in poly]) for i,poly in enumerate(cutouts)]
  self.s.panels.append(panel);self.ids.append(full);return full
 def rect(self,id,x,y,w,h,**kw):return self.polygon(id,rect(x,y,w,h),**kw)
 def pose(self,anchor,position,rotation=v()):
  self.c['anchor']=self.point(anchor['x'],anchor['y']);self.c['position']=position;self.c['rotationDegrees']=rotation
 def hinge(self,parent,child,start,end,angle,role='fold',offset=0):
  id=child+'/bend';self.s.hinges.append(dict(id=id,parentPanelID=parent,childPanelID=child,start=self.point(start['x'],start['y']),end=self.point(end['x'],end['y']),angleDegrees=angle,layerOffsetMM=offset));self.s.roles[id]=role
  self.s.guides.append(dict(id=id+'/guide',componentID=self.c['id'],role=role,points=[start,end],closed=False,label='Turn in' if role=='turnIn' else 'Fold / no score implied'))
 def region(self,points,side='outside',edge=None):
  r=dict(polygon=[self.point(q['x'],q['y']) for q in points],side=side)
  if edge is not None:r=dict(polygon=points,side=side,edgeIndex=edge)
  return r

def build():
 s=Source()
 choices=lambda *names:list(enumerate(names))
 s.param('width',180,80,320,'Length','dimensions',help='Held usable inside or finished outside length, according to Dimension reference.')
 s.param('depth',130,65,240,'Width','dimensions')
 s.param('height',55,25,140,'Height','dimensions')
 s.param('dimensionReference',0,0,1,'Dimension reference','dimensions','',choices( 'Finished usable inside','Finished outside'))
 s.param('runningClearance',.6,.15,3,'Lid clearance · per side','dimensions',help='Total opposed clearance is twice this value; separate from axial headspace and insert clearance.')
 s.param('lidDepth',28,15,100,'Lid finished skirt depth','dimensions')
 s.param('seatingMode',0,0,1,'Lid seating','dimensions','',choices('Top seated / axial gap','Overlap locked / physical stop ledges'))
 s.param('axialSpace',0,0,20,'Axial headspace / rim shim','dimensions',visible='1-seatingMode',help='Positive space creates four physical rim shims. Zero seats the lid ceiling on the base rim.')
 s.param('lidOverlap',15,5,70,'Locked overlap','dimensions',visible='seatingMode',help='The lid rim seats on four physical exterior stop ledges. Incompatible depth/overlap is rejected.')
 s.param('seatLand',1,.5,3,'Stop land beyond lid rim','dimensions',visible='seatingMode',help='The physical ledges reach past the actual finished lid-wall footprint by this amount. They remain below the sliding-fit region.')
 s.param('tolerance',.2,.01,1,'Declared dimensional tolerance','dimensions',help='A prototype process allowance, not a prediction of compression or sliding force.')
 s.param('linkedBoards',1,0,1,'Linked board calipers','boards','',choices('Independent','Use common board'))
 s.param('boardMM',2,.8,4,'Common board caliper','boards',visible='linkedBoards')
 s.param('floorArrangement',0,0,1,'Common floor arrangement','boards','',choices('Floor beneath walls','Floor between walls'))
 s.param('wallSpan',0,0,1,'Common spanning walls','boards','',choices('Front / back span ends','Side walls span ends'))
 s.param('jointMethod',1,0,3,'Common joint method','joints','',choices('Adhesive','Inside tape','Board staples','Tape + board staples'))
 s.param('retainedGlue',1,0,1,'Retain board adhesive','joints','',choices('No additional adhesive','Explicit adhesive + reinforcement'))
 s.param('jointBond',.03,0,.3,'Board adhesive effective layer','joints')
 s.param('tapeWidth',7,4,14,'Tape width · across both faces','joints')
 s.param('tapeEnd',8,2,20,'Tape end setback','joints')
 s.param('tapeMM',.12,.05,.4,'Tape caliper','joints')
 s.param('tapeBond',.03,0,.2,'Tape bond layer','joints')
 s.param('stapleCount',3,1,6,'Staples per selected seam','joints','',step=1)
 s.param('stapleCrown',8,4,15,'Staple crown width','joints')
 s.param('stapleWire',.35,.2,.7,'Rectangular wire width / depth','joints')
 s.param('stapleLeg',8,4,14,'Staple leg length','joints')
 s.param('stapleEnd',14,8,25,'Staple seam-end setback','joints',help='Distance from seam end to crown end. The finite floor-entry edge margin is separately declared as 0.1 mm.')
 s.param('stapleEdge',.15,.05,.5,'Receiving edge clearance','joints')
 s.param('toolAccess',24,10,60,'Driver access depth','joints')
 s.param('covering',1,0,2,'Common covering','covering','',choices('Uncovered board','Paper wrap','Backed fabric wrap'))
 s.param('pattern',0,0,1,'Common covering pattern','covering','',choices('Complete cross wrap','Wall band + face patch'))
 s.param('paperMM',.16,.08,.35,'Cover paper caliper','covering')
 s.param('clothMM',.24,.12,.6,'Backed fabric total caliper','covering',help='Paper backing and woven face remain physical plies. This scalar preserves their authored ratio; individual ply controls can change it.')
 s.param('coverBond',.04,.01,.2,'Cover adhesive layer','covering')
 s.param('fabricTurnInExtra',4,0,8,'Fabric extra turn-in','covering')
 s.param('cornerTab',7,4,12,'Overlapped corner tab','covering')
 s.param('seamOverlap',10,5,20,'Visible band seam overlap','covering')
 s.param('lining',0,0,3,'Common interior lining','lining','',choices('None','Floor / top only','Walls only','Full interior'))
 s.param('linerMM',.15,.06,.4,'Lining paper caliper','lining')
 s.param('linerBond',.03,.01,.2,'Lining adhesive layer','lining')
 s.param('linerSetback',.8,.4,3,'Liner edge setback','lining',help='Lining stops short of turn-ins and tape; it never erases either physical layer.')
 s.param('insert',0,0,1,'Removable fitted insert','lining','',choices('None','Fitted apertured board'))
 s.param('insertClearance',1,.5,4,'Insert clearance · per side','lining',visible='insert')
 s.param('insertMM',1,.6,3,'Insert board caliper','lining',visible='insert')
 for h,title in [('b','Base'),('l','Lid')]:
  for suffix,default,low,high,label,group,options in [
   ('FloorMM',2,.8,4,'floor / top board','boards',None),('WallMM',2,.8,4,'wall board','boards',None),
   ('FloorArrangement',-1,-1,1,'floor arrangement','boards',[(-1,'Common'),(0,'Beneath walls'),(1,'Between walls')]),
   ('WallSpan',-1,-1,1,'spanning walls','boards',[(-1,'Common'),(0,'Front / back span'),(1,'Sides span')]),
   ('Joint',-1,-1,3,'joint override','joints',[(-1,'Common'),(0,'Adhesive'),(1,'Tape'),(2,'Staples'),(3,'Tape + staples')]),
   ('Cover',-1,-1,2,'covering override','covering',[(-1,'Common'),(0,'Uncovered'),(1,'Paper'),(2,'Fabric')]),
   ('Pattern',-1,-1,1,'pattern override','covering',[(-1,'Common'),(0,'Complete cross'),(1,'Band + patch')]),
   ('Lining',-1,-1,3,'lining override','lining',[(-1,'Common'),(0,'None'),(1,'Floor / top'),(2,'Walls'),(3,'Full')])]:
   s.param(h+suffix,default,low,high,title+' '+label,group,'' if options else 'mm',options,visible='1-linkedBoards' if suffix.endswith('MM') else None)
  s.param(h+'Seam',.28,.15,.75,title+' band seam · fraction of front','covering','ratio',help='Moves the actual overlapping seam along the front face, retaining one continuous wall band and its source artwork.')
  for edge,label in [('n','Front'),('e','Right'),('s','Back'),('w','Left')]:
   s.param(h+'Turn'+edge.upper(),10,6,22,title+' '+label.lower()+' turn-in','covering')
   s.param(h+'Joint'+edge.upper(),-1,-1,3,title+' '+label.lower()+' seam method','joints','',[(-1,'Use half / common'),(0,'Glue'),(1,'Tape'),(2,'Staples'),(3,'Tape + staples')])
  A=lambda n,x:s.A(h+n,x)
  A('f',f'linkedBoards*boardMM+(1-linkedBoards)*{h}FloorMM');A('t',f'linkedBoards*boardMM+(1-linkedBoards)*{h}WallMM')
  A('arr',inherit('floorArrangement',h+'FloorArrangement'));A('span',inherit('wallSpan',h+'WallSpan'))
  A('method',inherit('jointMethod',h+'Joint'));A('cover',inherit('covering',h+'Cover'));A('pattern',inherit('pattern',h+'Pattern'));A('lining',inherit('lining',h+'Lining'))
  A('on',f'clamp({h}cover,0,1)');A('skin',f'{eq(h+"cover",1)}*paperMM+{eq(h+"cover",2)}*clothMM')
  A('lf',f'{eq(h+"lining",1)}+{eq(h+"lining",3)}');A('lw',f'{eq(h+"lining",2)}+{eq(h+"lining",3)}')
  for edge in 'nesw':
   A('m'+edge,inherit(h+'method',h+'Joint'+edge.upper()))
   A('tape'+edge,f'{eq(h+"m"+edge,1)}+{eq(h+"m"+edge,3)}')
   A('wire'+edge,f'{eq(h+"m"+edge,2)}+{eq(h+"m"+edge,3)}')
  A('taped',f'max(max({h}tapen,{h}tapee),max({h}tapes,{h}tapew))')
  A('wired',f'max(max({h}wiren,{h}wiree),max({h}wires,{h}wirew))')
  A('innerBuild',f'max({h}lw*(linerMM+linerBond),max({h}on*({h}skin+coverBond),{h}taped*(tapeMM+tapeBond)))')
  A('floorBuild',f'max({h}lf*(linerMM+linerBond),{h}taped*(tapeMM+tapeBond))')
  A('outerBuild',f'{h}on*2*({h}skin+coverBond)')
  A('outerW',f'{h}on*({h}skin+coverBond)*(2-{h}pattern)')
  A('outerFront',f'{h}on*({h}skin+coverBond)*(1+{h}pattern)')
  A('outerBack',f'{h}on*({h}skin+coverBond)')
  A('bottomBuild',f'{h}wired*stapleWire+{h}on*({h}skin+coverBond)*(1+{h}pattern)')
  A('pad',f'{h}wired*stapleWire')
  A('bottom',f'(1-{h}arr)*{h}f')
  A('turnMax',f'max(max({h}TurnN,{h}TurnE),max({h}TurnS,{h}TurnW))+{eq(h+"cover",2)}*fabricTurnInExtra')
  if h=='b':
   A('iw',f'width+2*{h}innerBuild-dimensionReference*2*({h}innerBuild+{h}t+{h}outerW+seatingMode*stopReach)')
   A('id',f'depth+2*{h}innerBuild-dimensionReference*(2*{h}innerBuild+2*{h}t+{h}outerFront+{h}outerBack+2*seatingMode*stopReach)')
   A('usableH',f'height-dimensionReference*({h}bottomBuild+{h}f+{h}floorBuild+(1-seatingMode)*axialSpace)')
  else:
   A('iw',f'bfinishedW+2*runningClearance+2*{h}innerBuild');A('id',f'bfinishedD+2*runningClearance+2*{h}innerBuild')
   A('usableH',f'lidDepth-{h}bottomBuild-{h}f-{h}floorBuild')
  A('ow',f'{h}iw+2*{h}t');A('od',f'{h}id+2*{h}t')
  A('uw',f'{h}iw-2*{h}innerBuild');A('ud',f'{h}id-2*{h}innerBuild')
  A('finishedW',f'{h}ow+2*{h}outerW');A('finishedD',f'{h}od+{h}outerFront+{h}outerBack')
  A('top',f'{h}f+{h}floorBuild+{h}usableH-{h}on*({h}skin+coverBond)')
  A('wallH',f'{h}top-{h}bottom')
  A('floorW',f'{h}ow-2*{h}arr*{h}t');A('floorD',f'{h}od-2*{h}arr*{h}t')
  A('frontW',f'{h}ow-2*{h}span*{h}t');A('sideW',f'{h}id+2*{h}span*{h}t')
  A('linerBottom',f'max(linerSetback,{h}taped*(tapeWidth/2+tapeBond+tapeMM))')
  A('linerTop',f'linerSetback+{h}on*{h}turnMax')
  A('linerW',f'{h}iw-2*linerSetback');A('linerD',f'{h}id-2*linerSetback')
  A('linerH',f'{h}top-{h}f-{h}linerBottom-{h}linerTop')
  A('lineFloorW',f'{h}iw-2*{h}linerBottom');A('lineFloorD',f'{h}id-2*{h}linerBottom')
  s.require(h+'-positive-cavity',f'min(min({h}uw,{h}ud),{h}usableH)','>',6,title+' needs positive finished usable space after its actual lining / tape / turn-ins.')
  s.require(h+'-positive-liner',h+'linerH','>',1,title+' wall liner needs room between tape and turn-ins; reduce setbacks / turn-ins or increase depth.')
  s.require(h+'-supported-staple-route',f'{h}wired*{h}arr','==',0,title+' staples require floor beneath walls; the inset-floor arrangement has no accepted receiving route.')
  s.require(h+'-wire-edge',f'{h}wired*{h}t/2','>=',f'{h}wired*(stapleWire/2+stapleEdge)',title+' wall caliper is insufficient for the configured wire plus receiving-edge clearance.')
  s.require(h+'-buried-leg',f'(stapleLeg-{h}f-stapleWire/2)*{h}wired','>=',f'2*{h}wired',title+' staple legs must engage at least 2 mm of wall after passing through the floor.')
  s.require(h+'-buried-end',f'(stapleLeg+stapleWire/2)*{h}wired','<',f'({h}f+{h}wallH)*{h}wired+1',title+' staple legs must terminate inside the receiving wall.')
 s.A('stopReach','runningClearance+linnerBuild+lt+lon*(coverBond+lskin/2)+seatLand')
 s.A('baseOutsideW','bfinishedW+2*seatingMode*stopReach')
 s.A('baseOutsideD','bfinishedD+2*seatingMode*stopReach')
 s.A('baseRim','bf+bfloorBuild+busableH')
 s.A('baseOutsideH','bbottomBuild+baseRim+(1-seatingMode)*axialSpace')
 s.A('baseEnvelopeZ','(bouterFront-bouterBack)/2')
 s.A('seatNmin','lid/2-(bod/2+bon*(bskin/2+coverBond))-abs(baseEnvelopeZ)')
 s.A('seatNmax','lid/2-(bid/2-bon*(bskin/2+coverBond))+abs(baseEnvelopeZ)')
 s.A('seatEmin','liw/2-(bow/2+bon*(bskin/2+coverBond))')
 s.A('seatEmax','liw/2-(biw/2-bon*(bskin/2+coverBond))')
 s.A('seatNtape','clamp(ceil(seatNmax-tapeBond-tapeMM/2),0,1)*clamp(ceil(tapeBond+tapeMM/2+tapeWidth/2-seatNmin),0,1)')
 s.A('seatEtape','clamp(ceil(seatEmax-tapeBond-tapeMM/2),0,1)*clamp(ceil(tapeBond+tapeMM/2+tapeWidth/2-seatEmin),0,1)')
 s.A('seatLiner','llf*clamp(ceil(max(seatNmax,seatEmax)-llinerBottom),0,1)')
 s.A('lidSeatBuild','max(max(max(ltapen,ltapes)*seatNtape,max(ltapee,ltapew)*seatEtape)*(tapeMM+tapeBond),seatLiner*(linerMM+linerBond))')
 s.A('lidSeatDepth','lfloorBuild+lusableH-lidSeatBuild')
 s.A('headspace','(1-seatingMode)*axialSpace+seatingMode*(lidSeatDepth-lidOverlap)')
 s.A('overlap','lidSeatDepth-headspace')
 s.A('reveal','busableH-overlap')
 s.A('lidSeatY','baseRim+headspace+lf+lidSeatBuild')
 s.A('lidSeparateX','(bfinishedW+lfinishedW)/2+45')
 s.A('lidLift','(lidDepth+25)*clamp(opening/25,0,1)')
 s.A('lidSide','clamp((opening-25)/40,0,1)')
 s.A('lidTurn','clamp((opening-65)/20,0,1)')
 s.A('lidLower','clamp((opening-85)/15,0,1)')
 s.A('lidPoseY','(lidSeatY+lidLift)*(1-lidLower)+(lbottomBuild-bbottomBuild)*lidLower')
 s.A('shimOn','(1-seatingMode)*clamp(ceil(headspace),0,1)')
 s.A('stopOn','seatingMode')
 s.require('nonzero-shim-caliper','(1-seatingMode)*axialSpace','>=','.1*(1-seatingMode)*clamp(ceil(axialSpace),0,1)','A positive physical rim shim needs at least 0.1 mm headspace; choose zero for direct rim seating.')
 s.require('seating-no-negative-headspace','headspace','>=',0,'Locked lid overlap exceeds the available lid interior depth. Reduce overlap or increase lid depth.')
 s.require('lid-positive-overlap','overlap','>',2,'The seated lid needs at least 2 mm of overlap. Reduce headspace or increase skirt depth.')
 s.require('lid-not-floor-contact','reveal','>',2,'The lid skirt reaches the base floor. Reduce lid depth / overlap, or increase base height.')
 # Keep discrete choices integral even when a client sends a raw scalar.
 for q in s.params:
  if q['unit']=='':s.require('choice-'+q['name'],q['name'],'==','round('+q['name']+')','Choose a declared integer option for '+q['name']+'.')
 # Pattern-neutral dimensions for the two physical covering stocks.
 for h in 'bl':
  for k,skin in [('p','paperMM'),('c','clothMM')]:
   z=h+k;A=lambda n,x:s.A(z+n,x)
   A('W',f'{h}ow+2*coverBond+{skin}');A('D',f'{h}od+2*coverBond+{skin}')
   A('R',f'{h}t+2*coverBond+{skin}');A('H',f'{h}top+{h}pad+2*coverBond+{skin}')
   A('BH',f'{h}top+{h}pad+3*coverBond+2*{skin}')
   for edge in 'nesw':A('T'+edge,f'{h}Turn{edge.upper()}'+('' if k=='p' else '+fabricTurnInExtra'))
   A('X',f'{z}H+{z}R+{z}Tw');A('Y',f'{z}H+{z}R+{z}Tn')
   A('CW',f'{z}W+2*{z}H+2*{z}R+{z}Tw+{z}Te');A('CH',f'{z}D+2*{z}H+2*{z}R+{z}Tn+{z}Ts')
   A('BW',f'2*({z}W+{z}D)+seamOverlap');A('BY',f'{z}R+max(max({z}Tn,{z}Te),max({z}Ts,{z}Tw))')
   A('BHeight',f'{z}BY+{z}BH+max(max({z}Tn,{z}Te),max({z}Ts,{z}Tw))')
  # Canonical source dimensions and cap region anchors choose active material and pattern.
  for n in ['W','D','X','Y','CW','CH','BW','BY','BHeight']:
   s.A(h+'a'+n,f'{eq(h+"cover",2)}*{h}c{n}+(1-{eq(h+"cover",2)})*{h}p{n}')
  s.A(h+'artW',f'(1-{h}pattern)*{h}aCW+{h}pattern*({h}aBW+20+{h}aW)')
  s.A(h+'artH',f'(1-{h}pattern)*{h}aCH+{h}pattern*max({h}aBHeight,{h}aD)')
  s.A(h+'capX',f'(1-{h}pattern)*{h}aX+{h}pattern*({h}aBW+20)');s.A(h+'capY',f'(1-{h}pattern)*{h}aY')
 s.A('atlasW','max(max(bpCW,lpCW),max(max(bcCW,lcCW),max(max(bpBW,lpBW),max(bcBW,lcBW))))+30')
 s.A('atlasH','max(max(bpCH,lpCH),max(bcCH,lcCH))+30')
 # Actual independent boards. No fictitious hinges between boards.
 boards={};boardpieces={}
 for h,title in [('b','Base'),('l','Lid')]:
  floor=s.piece(h+'-floor',title+' floor / top','base' if h=='b' else 'lid','board',BOARD,h+'f')
  pid=floor.rect('Floor',0,0,h+'floorW',h+'floorD')
  floor.pose(p(0,0),v(f'-{h}floorW/2',f'{h}f/2-explosion*.15',f'-{h}floorD/2'),v(-90,0,0));boards[h+'floor']=pid;boardpieces[h+'floor']=floor
  for edge,name,dim,rot,x,z in [
   ('n','Front','frontW',0,f'-{h}frontW/2',f'({h}id+{h}t)/2+explosion*.22'),
   ('e','Right','sideW',90,f'({h}iw+{h}t)/2+explosion*.22',f'{h}sideW/2'),
   ('s','Back','frontW',180,f'{h}frontW/2',f'-({h}id+{h}t)/2-explosion*.22'),
   ('w','Left','sideW',-90,f'-({h}iw+{h}t)/2-explosion*.22',f'-{h}sideW/2')]:
   o=s.piece(h+'-'+edge,title+' '+name+' wall','base' if h=='b' else 'lid','board',BOARD,h+'t');pid=o.rect(name,0,0,h+dim,h+'wallH')
   o.pose(p(0,h+'wallH'),v(x,h+'bottom',z),v(0,rot,0));boards[h+edge]=pid;boardpieces[h+edge]=o
 # Complete connected cross patterns, each 17 faces / one physical cut piece.
 covers={};patches={}
 for h,title in [('b','Base'),('l','Lid')]:
  for k,material,skin,mode in [('p',PAPER,'paperMM',1),('c',CLOTH,'clothMM',2)]:
   z=h+k;group='base' if h=='b' else 'lid';enabled=f'{eq(h+"cover",mode)}*(1-{h}pattern)'
   face=dict(sourceObjectID=uid(h+'/cover-source'),sourceSide='outside',sourceOriginMM=p())
   o=s.piece(h+'-cross-'+k,title+' '+('paper' if k=='p' else 'backed fabric')+' complete wrap',group,'covering',material,skin,enabled,face)
   X,Y,W,D,H,R=[z+n for n in ['X','Y','W','D','H','R']]
   cap=o.rect('Exterior face',X,Y,W,D);o.pose(p(X,Y),v(f'-{W}/2',f'-{h}pad-coverBond-{skin}/2-explosion*.32',f'{D}/2'),v(90,0,0))
   faces={'cap':cap};local={}
   for edge in 'nesw':
    T=z+'T'+edge
    if edge in 'ns':
     north=edge=='n';y0=f'{Y}-{H}' if north else f'{Y}+{D}';yb=Y if north else f'{Y}+{D}';yo=f'{Y}-{H}' if north else f'{Y}+{D}+{H}';yr=f'{yo}-{R}' if north else f'{yo}+{R}';yt=f'{yr}-{T}' if north else f'{yr}+{T}'
     # Keep the cap/rim fold edges at their original width. Only the relieved
     # middle of each end wing reaches the corner-tab plane. This actual
     # material bridge replaces the former detached layer-offset hinge.
     shoulder=f'({skin}+coverBond)'
     wing=o.polygon(edge+' outer wall',[
      p(X,y0),p(f'{X}+{W}',y0),p(f'{X}+{W}+{shoulder}',f'{y0}+2'),
      p(f'{X}+{W}+{shoulder}',f'{y0}+{H}-2'),p(f'{X}+{W}',f'{y0}+{H}'),
      p(X,f'{y0}+{H}'),p(f'{X}-{shoulder}',f'{y0}+{H}-2'),p(f'{X}-{shoulder}',f'{y0}+2')])
     a=p(X,yb);b=p(f'{X}+{W}',yb);angle=-90 if north else 90
     traverse=o.polygon(edge+' rim traversal',[p(X,yo),p(f'{X}+{W}',yo),p(f'{X}+{W}-{R}',yr),p(f'{X}+{R}',yr)])
     turn=o.polygon(edge+' inside turn-in',[p(f'{X}+{R}',yr),p(f'{X}+{W}-{R}',yr),p(f'{X}+{W}-{R}',yt),p(f'{X}+{R}',yt)])
     o.hinge(cap,wing,a,b,angle);o.hinge(wing,traverse,p(X,yo),p(f'{X}+{W}',yo),angle,'turnIn');o.hinge(traverse,turn,p(f'{X}+{R}',yr),p(f'{X}+{W}-{R}',yr),angle,'turnIn')
     local[edge]=(X,y0,W,H)
     # Four relieved actual corner overlaps. No printed simulation of a tab.
     for left in [True,False]:
      xx=f'{X}-{shoulder}' if left else f'{X}+{W}+{shoulder}';dx='-cornerTab' if left else 'cornerTab'
      ta=f'{y0}+2';tb=f'{y0}+{H}-2'
      points=[p(xx,ta),p(add(xx,dx),f'{ta}+2'),p(add(xx,dx),f'{tb}-2'),p(xx,tb)]
      tab=o.polygon(edge+(' left' if left else ' right')+' corner overlap',points,'glue');o.hinge(wing,tab,p(xx,ta),p(xx,tb),90 if left else -90,'seam')
    else:
     west=edge=='w';x0=f'{X}-{H}' if west else f'{X}+{W}';xb=X if west else f'{X}+{W}';xo=f'{X}-{H}' if west else f'{X}+{W}+{H}';xr=f'{xo}-{R}' if west else f'{xo}+{R}';xt=f'{xr}-{T}' if west else f'{xr}+{T}'
     wing=o.rect(edge+' outer wall',x0,Y,H,D);angle=90 if west else -90
     traverse=o.polygon(edge+' rim traversal',[p(xo,Y),p(xo,f'{Y}+{D}'),p(xr,f'{Y}+{D}-{R}'),p(xr,f'{Y}+{R}')])
     turn=o.polygon(edge+' inside turn-in',[p(xr,f'{Y}+{R}'),p(xr,f'{Y}+{D}-{R}'),p(xt,f'{Y}+{D}-{R}'),p(xt,f'{Y}+{R}')])
     o.hinge(cap,wing,p(xb,Y),p(xb,f'{Y}+{D}'),angle);o.hinge(wing,traverse,p(xo,Y),p(xo,f'{Y}+{D}'),angle,'turnIn');o.hinge(traverse,turn,p(xr,f'{Y}+{R}'),p(xr,f'{Y}+{D}-{R}'),angle,'turnIn')
     local[edge]=(x0,Y,H,D)
    faces[edge]=wing
   covers[(h,k,'cross')]=(o,faces,local)
   # Alternate physical wall band + separate exterior cap patch.
   enabled=f'{eq(h+"cover",mode)}*{h}pattern'
   o=s.piece(h+'-band-'+k,title+' '+('paper' if k=='p' else 'fabric')+' wall band',group,'covering',material,skin,enabled,face)
   BY,BH=z+'BY',z+'BH';offset=0;prev=None;faces={};local={}
   seam=f'{W}*{h}Seam'
   for edge,width_ in [('n',f'{W}-({seam})'),('e',D),('s',W),('w',D),('nTail',seam)]:
    xx=e(offset);wall=o.rect(edge+' outer wall',xx,BY,width_,BH);faces[edge]=wall;local[edge]=(xx,BY,width_,BH)
    if prev:o.hinge(prev,wall,p(xx,BY),p(xx,f'{BY}+{BH}'),-90,'seam')
    T=z+'T'+('n' if edge=='nTail' else edge)
    rim=o.polygon(edge+' rim traversal',[p(xx,BY),p(add(xx,width_),BY),p(f'({xx})+{width_}-{R}',f'{BY}-{R}'),p(f'({xx})+{R}',f'{BY}-{R}')])
    turn=o.rect(edge+' inside turn-in',f'({xx})+{R}',f'{BY}-{R}-{T}',f'{width_}-2*{R}',T)
    bottom=o.polygon(edge+' bottom turn-under',[p(xx,f'{BY}+{BH}'),p(add(xx,width_),f'{BY}+{BH}'),p(f'({xx})+{width_}-{T}',f'{BY}+{BH}+{T}'),p(f'({xx})+{T}',f'{BY}+{BH}+{T}')])
    o.hinge(wall,rim,p(xx,BY),p(add(xx,width_),BY),-90,'turnIn');o.hinge(rim,turn,p(f'({xx})+{R}',f'{BY}-{R}'),p(f'({xx})+{width_}-{R}',f'{BY}-{R}'),-90,'turnIn');o.hinge(wall,bottom,p(xx,f'{BY}+{BH}'),p(add(xx,width_),f'{BY}+{BH}'),90,'turnIn')
    prev=wall;offset=f'({xx})+{width_}'
   flap=o.rect('Visible seam overlap',offset,f'{BY}+2','seamOverlap',f'{BH}-4',role='glue');o.hinge(prev,flap,p(offset,f'{BY}+2'),p(offset,f'{BY}+{BH}-2'),0,'seam',f'-({skin}+coverBond)')
   o.pose(p(0,f'{BY}+{BH}'),v(f'-{W}/2+({seam})',f'-{h}pad-2*coverBond-1.5*{skin}-explosion*.32',f'{D}/2'))
   covers[(h,k,'band')]=(o,faces,local)
   patch=s.piece(h+'-patch-'+k,title+' exterior '+('paper' if k=='p' else 'fabric')+' face patch',group,'covering',material,skin,enabled,dict(sourceObjectID=uid(h+'/cover-source'),sourceSide='outside',sourceOriginMM=p(f'{h}capX',f'{h}capY')))
   pid=patch.rect('Exterior patch',0,0,W,D);patch.pose(p(0,0),v(f'-{W}/2',f'-{h}pad-coverBond-{skin}/2-explosion*.4',f'{D}/2'),v(90,0,0));patches[(h,k)]=(patch,pid)
 # Independent actual liners, deliberately stopping short of tape and turn-ins.
 liners={}
 for h,title in [('b','Base'),('l','Lid')]:
  group='base' if h=='b' else 'lid'
  floorX=f'2*({h}linerW+{h}linerD)+20'
  o=s.piece(h+'-liner-floor',title+' floor / top lining',group,'lining',LINER,'linerMM',h+'lf',dict(sourceObjectID=uid(h+'/liner-source'),sourceSide='outside',sourceOriginMM=p(floorX,0)))
  pid=o.rect('Lining',0,0,h+'lineFloorW',h+'lineFloorD');o.pose(p(0,0),v(f'-{h}lineFloorW/2',f'{h}f+linerBond+linerMM/2+explosion*.3',f'-{h}lineFloorD/2'),v(-90,0,0));liners[h+'floor']=(o,pid)
  offset=0
  for edge,width_,rot,x,z in [('n',h+'linerW',180,f'{h}linerW/2',f'{h}id/2-linerBond-linerMM/2'),('e',h+'linerD',-90,f'{h}iw/2-linerBond-linerMM/2',f'-{h}linerD/2'),('s',h+'linerW',0,f'-{h}linerW/2',f'-{h}id/2+linerBond+linerMM/2'),('w',h+'linerD',90,f'-{h}iw/2+linerBond+linerMM/2',f'{h}linerD/2')]:
   o=s.piece(h+'-liner-'+edge,title+' '+edge.upper()+' wall lining',group,'lining',LINER,'linerMM',h+'lw',dict(sourceObjectID=uid(h+'/liner-source'),sourceSide='outside',sourceOriginMM=p(offset,0)))
   pid=o.rect('Lining',0,0,width_,h+'linerH');o.pose(p(0,h+'linerH'),v(x,f'{h}f+{h}linerBottom+explosion*.3',z),v(0,rot,0));liners[h+edge]=(o,pid);offset=f'({offset})+{width_}'
 # Physical floor-corner tape strips, supported underside-to-wall staple routes,
 # and explicit optional board adhesive on the real cut receiving edge.
 for h,title in [('b','Base'),('l','Lid')]:
  group='base' if h=='b' else 'lid';floor=boardpieces[h+'floor'];fp=boards[h+'floor']
  present=[h+'-floor']+[h+'-'+edge for edge in 'nesw']
  for edge,turn,dim in [('n',0,'iw'),('e',90,'id'),('s',180,'iw'),('w',-90,'id')]:
   wall=boardpieces[h+edge];wp=boards[h+edge];wallL=h+('frontW' if edge in 'ns' else 'sideW');L=f'{h}{dim}-2*tapeEnd';half='tapeWidth/2'
   id=h+'-floor-'+edge;jid=s.join(id,fp,wp,kind='floor-to-wall-edge',notes='Actual separate floor and wall; selected method and board arrangement remain explicit.')
   tape=s.piece(h+'-tape-'+edge,title+' '+edge.upper()+' inside seam tape',group,'tape',TAPE,'tapeMM',h+'tape'+edge)
   tf=tape.rect('Floor contact',0,0,L,half);tw=tape.rect('Wall contact',0,half,L,half);tape.hinge(tf,tw,p(0,half),p(L,half),-90)
   joint=f'{h}id/2-tapeBond-tapeMM/2' if edge in 'ns' else f'{h}iw/2-tapeBond-tapeMM/2'
   if edge=='n':tx,tz=f'-({L})/2',joint
   elif edge=='e':tx,tz=joint,f'({L})/2'
   elif edge=='s':tx,tz=f'({L})/2',f'-({joint})'
   else:tx,tz=f'-({joint})',f'-({L})/2'
   tape.pose(p(0,half),v(tx,f'{h}f+tapeBond+tapeMM/2+explosion*.12',tz),v(-90,turn,0))
   # Targets slightly inside the strip outline, retaining declared bond gap.
   reach=f'{h}{"id" if edge in "ns" else "iw"}/2-tapeBond-tapeMM/2';near=f'({reach})-tapeWidth/2+.25';far=f'({reach})-.25'
   if edge=='n':floorRegion=rect(f'{h}floorW/2-({L})/2+.25',f'{h}floorD/2+({near})',f'({L})-.5','tapeWidth/2-.5')
   elif edge=='s':floorRegion=rect(f'{h}floorW/2-({L})/2+.25',f'{h}floorD/2-({far})',f'({L})-.5','tapeWidth/2-.5')
   elif edge=='e':floorRegion=rect(f'{h}floorW/2+({near})',f'{h}floorD/2-({L})/2+.25','tapeWidth/2-.5',f'({L})-.5')
   else:floorRegion=rect(f'{h}floorW/2-({far})',f'{h}floorD/2-({L})/2+.25','tapeWidth/2-.5',f'({L})-.5')
   y0=f'{h}wallH-({h}f-{h}bottom+tapeBond+tapeMM/2+tapeWidth/2-.25)'
   wallRegion=rect(f'({wallL}-({L}))/2+.25',y0,f'({L})-.5','tapeWidth/2-.5')
   install=dict(order=2,stage='Inside tape after board fastening; before cover and lining',presentComponentIDs=present+[tape.c['id']])
   s.attach.append(dict(id=id+'/tape',joinID=jid,enabled=h+'tape'+edge,tape=dict(componentID=tape.c['id'],firstRegion=floor.region(floorRegion),secondRegion=wall.region(wallRegion,'inside'),lengthAxis='x',widthMM='tapeWidth',lengthMM=L,overlapMM=0,endOffsetStartMM=0,endOffsetEndMM=0,side='inside',bondThicknessMM='tapeBond',installation=install)))
   span=f'{wallL}-2*stapleEnd-stapleCrown';first=f'-({span})/2*min(1,stapleCount-1)'
   if edge=='n':ax,ay,crown,spacing=f'{h}floorW/2+({first})',f'{h}floorD/2+({h}id+{h}t)/2',p(1,0),p(1,0)
   elif edge=='s':ax,ay,crown,spacing=f'{h}floorW/2-({first})',f'{h}floorD/2-({h}id+{h}t)/2',p(-1,0),p(-1,0)
   elif edge=='e':ax,ay,crown,spacing=f'{h}floorW/2+({h}iw+{h}t)/2',f'{h}floorD/2-({first})',p(0,-1),p(0,-1)
   else:ax,ay,crown,spacing=f'{h}floorW/2-({h}iw+{h}t)/2',f'{h}floorD/2+({first})',p(0,1),p(0,1)
   staple=dict(id=id+'/wire',entryPanelID=fp,receivingPanelID=wp,anchor=floor.point(ax,ay),entrySide='inside',crownDirection=crown,driveDirection=v(0,0,1),crownWidthMM='stapleCrown',wireWidthMM='stapleWire',wireDepthMM='stapleWire',legLengthMM='stapleLeg',count='stapleCount',spacingMM=f'({span})/max(1,stapleCount-1)',spacingDirection=spacing,endMarginMM=.1,minimumReceivingDepthMM=2,minimumEdgeDistanceMM='stapleEdge',maximumJointGapMM=.2,termination='buried',tool='Declared narrow-nose board-edge stitcher; physical trial required',toolAccessMM='toolAccess',toolClearanceMM=.5,installation=dict(order=1,stage='Bare board underside into wall bottom edge, before tape / covering / lining',presentComponentIDs=present))
   s.attach.append(dict(id=id+'/staples',joinID=jid,enabled=h+'wire'+edge,staples=[staple]))
   s.require(id+'-spacing',f'({span})*{h}wire{edge}','>=',f'max(0,stapleCount-1)*(stapleCrown+stapleWire)*{h}wire{edge}',title+' seam is too short for the selected staple count / crown / end margins.')
   # For underneath-floor arrangement, the horizontal floor face contacts the
   # actual wall bottom cut edge. Inset floor adhesive is declared separately
   # by its cut-edge to wall face contact below.
   coreStrip=f'{h}t';contactL=f'min({wallL},{h}{dim})-.8'
   if edge=='n':glueFloor=rect(f'{h}floorW/2-({contactL})/2',f'{h}floorD/2+{h}id/2+.1',contactL,f'{coreStrip}-.2')
   elif edge=='s':glueFloor=rect(f'{h}floorW/2-({contactL})/2',f'{h}floorD/2-{h}id/2-{coreStrip}+.1',contactL,f'{coreStrip}-.2')
   elif edge=='e':glueFloor=rect(f'{h}floorW/2+{h}iw/2+.1',f'{h}floorD/2-({contactL})/2',f'{coreStrip}-.2',contactL)
   else:glueFloor=rect(f'{h}floorW/2-{h}iw/2-{coreStrip}+.1',f'{h}floorD/2-({contactL})/2',f'{coreStrip}-.2',contactL)
   glueEnabled=f'(1-{h}arr)*max(retainedGlue,{eq(h+"m"+edge,0)})'
   edgeRegion=rect(f'({wallL}-({contactL}))/2',.1,contactL,f'{h}t-.2')
   s.attach.append(dict(id=id+'/glue',joinID=jid,enabled=glueEnabled,adhesive=dict(identity='PVA board-edge bond / prototype allowance',thicknessMM='jointBond',coverage=.9,firstRegion=floor.region(glueFloor),secondRegion=wall.region(edgeRegion,edge=2))))
 # Real crown leveling backing, slotted around all possible crown positions.
 for h,title in [('b','Base'),('l','Lid')]:
  o=s.piece(h+'-crown-backing',title+' crown-leveling backing','base' if h=='b' else 'lid','backing',BACKING,'stapleWire',f'{h}wired*{h}on')
  slots=[]
  for edge in 'nesw':
   along=f'{h}frontW-2*stapleEnd+stapleWire+.4' if edge in 'ns' else f'{h}sideW-2*stapleEnd+stapleWire+.4';cross='stapleWire+.4'
   if edge in 'ns':
    yy=f'{h}od/2'+('+' if edge=='n' else '-')+f'({h}id+{h}t)/2-({cross})/2';slots.append(rect(f'({h}ow-({along}))/2',yy,along,cross))
   else:
    xx=f'{h}ow/2'+('+' if edge=='e' else '-')+f'({h}iw+{h}t)/2-({cross})/2';slots.append(rect(xx,f'({h}od-({along}))/2',cross,along))
  o.rect('Slotted backing',0,0,h+'ow',h+'od',cutouts=slots);o.pose(p(0,0),v(f'-{h}ow/2','-stapleWire/2-explosion*.24',f'{h}od/2'),v(90,0,0))
 # Actual stop surfaces, never an unsupported floating lid.
 for edge in 'nesw':
  side=edge in 'ew';long='biw' if not side else 'bid';tx='-6' if not side else ('biw/2' if edge=='e' else '-biw/2-bt');tz=('bid/2' if edge=='n' else '-bid/2-bt') if not side else '-6'
  o=s.piece('rim-shim-'+edge,'Rim shim '+edge.upper(),'base','seating',BOARD,'max(.1,headspace)','shimOn')
  o.rect('Seat',0,0,12 if not side else 'bt','bt' if not side else 12);o.pose(p(0,0),v(tx,'baseRim+max(.1,headspace)/2',tz),v(-90,0,0))
  o=s.piece('overlap-stop-'+edge,'Exterior overlap stop '+edge.upper(),'base','seating',BOARD,1,'stopOn')
  x='-8' if not side else ('bow/2+bouterW' if edge=='e' else '-bow/2-bouterW-stopReach');z=('bod/2+bouterFront' if edge=='n' else '-bod/2-bouterBack-stopReach') if not side else 'baseEnvelopeZ-8'
  o.rect('Physical stop',0,0,16 if not side else 'stopReach','stopReach' if not side else 16);o.pose(p(0,0),v(x,'baseRim-overlap-.5',z),v(-90,0,0))
 insert=s.piece('removable-insert','Removable apertured insert','base','insert',BOARD,'insertMM','insert',dict(sourceObjectID=uid('insert/source'),sourceSide='outside',sourceOriginMM=p()))
 insert.rect('Insert',0,0,'buw-2*insertClearance','bud-2*insertClearance',cutouts=[rect('(buw-2*insertClearance)/2-22','(bud-2*insertClearance)/2-15',44,30)])
 insert.pose(p(0,0),v('-buw/2+insertClearance','bf+bfloorBuild+insertMM/2+explosion*.5','-bud/2+insertClearance'),v(-90,0,0))
 return finish(s,covers,patches,liners)

def element(key,kind,x,y,w,h,text='',color='#243F39',size=10,**extra):
 q=dict(id=uid(key),name=key.rsplit('/',1)[-1],kind=kind,x=x,y=y,width=w,height=h,text=text,color=color,fontSize=size)
 if kind=='text':q['typography']=dict(fontName='HelveticaNeue',leading=size*1.2)
 q.update(extra);return q

def art(elements):return dict(background='#FFFFFF',backgroundOpacity=0,bleed=0,elements=elements,unit='mm')

def finish(s,covers,patches,liners):
 # Register actual bonded side faces on each retained covering alternative.
 for (h,k,pattern),(o,faces,local) in covers.items():
  skin='paperMM' if k=='p' else 'clothMM';z=h+k;enabled=o.c['enabled']
  for edge in 'nesw':
   board=s.pieces[h+'-'+edge];wallL=h+('frontW' if edge in 'ns' else 'sideW');cW=f'{wallL}-2*cornerTab-4';cH=f'{h}wallH-4'
   boardRegion=board.region(rect(f'({wallL}-({cW}))/2',2,cW,cH))
   if pattern=='cross':
    X,Y,W,D,H=[z+n for n in ['X','Y','W','D','H']]
    low=f'{h}bottom+2+{h}pad+coverBond+{skin}/2';high=f'{h}top-2+{h}pad+coverBond+{skin}/2'
    if edge=='n':poly=rect(f'{X}+({W}-({cW}))/2',f'{Y}-({high})',cW,cH)
    elif edge=='s':poly=rect(f'{X}+({W}-({cW}))/2',f'{Y}+{D}+({low})',cW,cH)
    elif edge=='w':poly=rect(f'{X}-({high})',f'{Y}+({D}-({cW}))/2',cH,cW)
    else:poly=rect(f'{X}+{W}+({low})',f'{Y}+({D}-({cW}))/2',cH,cW)
   else:
    xx,yy,ww,hh=local[edge]
    if edge=='n':
     cW=f'({ww})-4';boardRegion=board.region(rect(f'{wallL}/2+{z}W*{h}Seam/2-({cW})/2',2,cW,cH))
    poly=rect(f'({xx})+({ww}-({cW}))/2',f'{yy}+coverBond+{skin}/2+2',cW,cH)
   jid=s.join(o.c['id']+'-bond-'+edge,board.ids[0],faces[edge],enabled,notes='Cover adhesive contact is on actual side stock; corner overlaps remain separate physical panels.')
   s.attach.append(dict(id=jid+'/adhesive',joinID=jid,enabled=enabled,adhesive=dict(identity='Covering PVA / effective dry bond assumption',thicknessMM='coverBond',coverage=.95,firstRegion=boardRegion,secondRegion=o.region(poly,'inside'))))
  if pattern=='band':
   board=s.pieces[h+'-n'];wallL=h+'frontW';xx,yy,ww,hh=local['nTail'];cw=f'({ww})-4';ch=f'{h}wallH-4'
   first=board.region(rect(f'{wallL}/2-({z}W-{z}W*{h}Seam)/2-({cw})/2',2,cw,ch))
   second=o.region(rect(f'({xx})+2',f'{yy}+coverBond+{skin}/2+2',cw,ch),'inside')
   jid=s.join(o.c['id']+'-bond-front-tail',board.ids[0],faces['nTail'],enabled)
   s.attach.append(dict(id=jid+'/adhesive',joinID=jid,enabled=enabled,adhesive=dict(identity='Cover PVA on front segment before visible overlap',thicknessMM='coverBond',coverage=.95,firstRegion=first,secondRegion=second)))
  # Complete cross has its own cap; the band uses the separate patch.
  if pattern=='cross':capPiece=o;capID=faces['cap'];originX=z+'X';originY=z+'Y'
  else:capPiece,capID=patches[(h,k)];originX=originY=0
  W,D=z+'W',z+'D';cw=f'{h}floorW-30';cd=f'{h}floorD-30'
  for onpad in [False,True]:
   target=s.pieces[h+'-crown-backing'] if onpad else s.pieces[h+'-floor'];targetID=target.ids[0]
   enabled2=f'({enabled})*'+(h+'wired' if onpad else f'(1-{h}wired)')
   first=target.region(rect(15,15,cw,cd),'outside' if onpad else 'inside')
   second=capPiece.region(rect(f'({originX})+({W}-({cw}))/2',f'({originY})+({D}-({cd}))/2',cw,cd),'inside')
   jid=s.join(capPiece.c['id']+'-cap-bond-'+('backing' if onpad else 'board'),targetID,capID,enabled2)
   s.attach.append(dict(id=jid+'/adhesive',joinID=jid,enabled=enabled2,adhesive=dict(identity='Face covering PVA / actual backing contact',thicknessMM='coverBond',coverage=.95,firstRegion=first,secondRegion=second)))
 # Declare actual liner bonds, with glue contact stopping at the piece setbacks.
 for key,(o,pid) in liners.items():
  h=key[0];edge=key[1:];target=s.pieces[h+'-floor'] if edge=='floor' else s.pieces[h+'-'+edge]
  enabled=o.c['enabled'];firstSide='outside' if edge=='floor' else 'inside'
  if edge=='floor':
   w,d=h+'lineFloorW',h+'lineFloorD';first=target.region(rect(f'({h}floorW-{w})/2+.2',f'({h}floorD-{d})/2+.2',f'{w}-.4',f'{d}-.4'),firstSide);second=o.region(rect(.2,.2,f'{w}-.4',f'{d}-.4'),'inside')
  else:
   W=h+('linerW' if edge in 'ns' else 'linerD');wallL=h+('frontW' if edge in 'ns' else 'sideW')
   first=target.region(rect(f'({wallL}-{W})/2+.2',f'{h}wallH-({h}f-{h}bottom+{h}linerBottom+{h}linerH)+.2',f'{W}-.4',f'{h}linerH-.4'),firstSide)
   second=o.region(rect(.2,.2,f'{W}-.4',f'{h}linerH-.4'),'inside')
  jid=s.join(o.c['id']+'-bond',target.ids[0],pid,enabled)
  s.attach.append(dict(id=jid+'/adhesive',joinID=jid,enabled=enabled,adhesive=dict(identity='Lining PVA; regions stop short of tape and turn-ins',thicknessMM='linerBond',coverage=.9,firstRegion=first,secondRegion=second)))
 # Inset-floor bonds have a different physical route/formula from a floor below.
 for h in 'bl':
  floor=s.pieces[h+'-floor']
  for edge,index,dim in [('n',2,'iw'),('e',1,'id'),('s',0,'iw'),('w',3,'id')]:
   wall=s.pieces[h+'-'+edge];wallL=h+('frontW' if edge in 'ns' else 'sideW');length=f'{h}{dim}-.8'
   enabled=f'{h}arr*max(retainedGlue,{eq(h+"m"+edge,0)})'
   first=floor.region(rect(.4,.1,length,f'{h}f-.2'),edge=index)
   second=wall.region(rect(f'({wallL}-({length}))/2',f'{h}wallH-{h}f+.1',length,f'{h}f-.2'),'inside')
   jid=h+'-floor-'+edge
   s.attach.append(dict(id=jid+'/inset-glue',joinID=jid,enabled=enabled,adhesive=dict(identity='PVA floor cut-edge to wall inside face',thicknessMM='jointBond',coverage=.9,firstRegion=first,secondRegion=second)))
 # Source-authored positions and physical artwork region anchors retain type size.
 values=resolve(s.params,s.aliases)
 sources=[]
 for h,title in [('b','Base'),('l','Lid')]:
  x,y,W,D=[values[h+n] for n in ['capX','capY','aW','aD']]
  capEls=[element(h+'/cap/edition','text',x+14,y+14,78,5,'CASK / COLLECT     01',size=7),
   element(h+'/cap/title','text',x+(W-112)/2,y+(D-17)/2,112,17,'CASK',size=32),
   element(h+'/cap/rule','rectangle',x+(W-46)/2,y+(D-17)/2+25,46,.25),
   element(h+'/cap/detail','text',x+(W-105)/2,y+(D-17)/2+30,105,8,'A place for small collections.',size=8),
   element(h+'/cap/seal','ellipse',x+W-28,y+D-28,11,11,'',color='#A98D56')]
  # Lid cap is top-facing after its group turns over. The base underside print is intentionally discreet.
  if h=='b':capEls[1]['text']='COLLECT';capEls[1]['fontSize']=22
  region=dict(id=h+'-cap',name=title+' exterior face',origin=p(h+'capX',h+'capY'),size=p(h+'aW',h+'aD'),anchors=[dict(elementIDs=[q['id'] for q in capEls],horizontal=.5,vertical=.5)])
  a=art(capEls);sources.append(dict(id=uid(h+'/cover-source'),name=title+' covering · canonical artwork',width=h+'artW',height=h+'artH',artwork=a,artworkRegions=[region]))
  # The same masks survive paper/fabric and cross/band alternatives.
  if h=='l':
   finishes=[dict(id=uid('lid/foil'),name='Satin champagne foil title',kind='foil',side='outside',elementIDs=[uid('l/cap/title')],color='#B89C61',depthMM=0,heightMM=.015,roughness=.26,metallic=.88,opacity=1,enabled=True),
    dict(id=uid('lid/emboss'),name='Blind raised collection seal',kind='emboss',side='outside',elementIDs=[uid('l/cap/seal')],color='#E1D5B9',depthMM=0,heightMM=.08,roughness=.7,metallic=0,opacity=1,enabled=True)]
   for (hh,kk,pattern),(o,_,_) in covers.items():
    if hh==h and pattern=='cross':o.c['finishes']=copy.deepcopy(finishes)
   for (hh,kk),(o,_) in patches.items():
    if hh==h:o.c['finishes']=copy.deepcopy(finishes)
  floorX=2*(values[h+'linerW']+values[h+'linerD'])+20
  fw,fd=values[h+'lineFloorW'],values[h+'lineFloorD']
  els=[element(h+'/liner/label','text',floorX+12,14,100,7,'COLLECT / KEEP / RETURN',size=7),
   element(h+'/liner/serial','text',floorX+12,fd-18,100,5,'CASK   —   FIELD ARCHIVE 01',size=6)]
  sources.append(dict(id=uid(h+'/liner-source'),name=title+' lining · canonical artwork',width=f'2*({h}linerW+{h}linerD)+20+{h}lineFloorW',height=f'max({h}linerH,{h}lineFloorD)',artwork=art(els),artworkRegions=[dict(id=h+'-lining-floor',name=title+' interior floor / top',origin=p(f'2*({h}linerW+{h}linerD)+20',0),size=p(h+'lineFloorW',h+'lineFloorD'),anchors=[dict(elementIDs=[q['id'] for q in els],horizontal=0,vertical=0)])]))
 sources.append(dict(id=uid('insert/source'),name='Removable insert · canonical artwork',width='buw-2*insertClearance',height='bud-2*insertClearance',artwork=art([element('insert/label','text',8,8,90,6,'CASK / OBJECT REGISTER',size=6)])))
 # Visibility is authored source metadata, shared by native and MCP review.
 anyTape='max(btaped,ltaped)';anyWire='max(bwired,lwired)';anyCover='max(bon,lon)'
 paperOn=f'max({eq("bcover",1)},{eq("lcover",1)})';clothOn=f'max({eq("bcover",2)},{eq("lcover",2)})'
 anyBand='max(bon*bpattern,lon*lpattern)';anyLiner='clamp(max(blining,llining),0,1)'
 for c in s.controls:
  n=c['parameter']
  if n in ['tapeWidth','tapeEnd','tapeMM','tapeBond']:c['visibleWhen']=anyTape
  elif n.startswith('staple') or n=='toolAccess':c['visibleWhen']=anyWire
  elif n=='paperMM':c['visibleWhen']=paperOn
  elif n in ['clothMM','fabricTurnInExtra']:c['visibleWhen']=clothOn
  elif n in ['coverBond','pattern']:c['visibleWhen']=anyCover
  elif n=='cornerTab':c['visibleWhen']='max(bon*(1-bpattern),lon*(1-lpattern))'
  elif n=='seamOverlap':c['visibleWhen']=anyBand
  elif n in ['linerMM','linerBond','linerSetback']:c['visibleWhen']=anyLiner
  elif n in ['bSeam','lSeam']:c['visibleWhen']=n[0]+'on*'+n[0]+'pattern'
  elif n.startswith(('bTurn','lTurn')):c['visibleWhen']=n[0]+'on'
  elif n in ['bPattern','lPattern']:c['visibleWhen']=n[0]+'on'
 groupTitles=[('dimensions','Dimensions & finished fit'),('boards','Independent boards'),('joints','Joints, tape & board staples'),('covering','Covering & physical turn-ins'),('lining','Lining & optional insert')]
 measurements=[]
 for id,label,expression,group in [
 ('inside-w','Base usable length','buw','dimensions'),('inside-d','Base usable width','bud','dimensions'),('inside-h','Base usable height','busableH','dimensions'),
 ('outside-w','Base finished outside length','baseOutsideW','dimensions'),('outside-d','Base finished outside width','baseOutsideD','dimensions'),('outside-h','Base finished outside height','baseOutsideH','dimensions'),
 ('stop-reach','Physical overlap-stop projection','stopReach','dimensions'),('fit-body-w','Base finished overlap-region length','bfinishedW','dimensions'),('fit-body-d','Base finished overlap-region width','bfinishedD','dimensions'),('lid-clear-w','Lid minimum clear length','luw','dimensions'),('lid-clear-d','Lid minimum clear width','lud','dimensions'),('total-running','Total opposed running clearance','2*runningClearance','dimensions'),
 ('overlap','Actual seated overlap','overlap','dimensions'),('axial','Axial headspace / actual stop height','headspace','dimensions'),('reveal','Base reveal below lid rim','reveal','dimensions'),
 ('base-floor-w','Raw base floor cut length','bfloorW','boards'),('base-floor-d','Raw base floor cut width','bfloorD','boards'),('base-wall-h','Raw base wall height','bwallH','boards'),
 ('lid-top-w','Raw lid top cut length','lfloorW','boards'),('lid-top-d','Raw lid top cut width','lfloorD','boards'),('lid-wall-h','Raw lid wall height','lwallH','boards'),
 ('base-inside-build','Base maximum local inward build','binnerBuild','covering'),('lid-inside-build','Lid maximum local inward build','linnerBuild','covering'),
 ('lid-relief','Additional peak decorative lid relief','.08','covering')]:measurements.append(dict(id=id,label=label,expression=expression,unit='mm',group=group))
 poses=[dict(id=id,name=name,openingPercent=o,explosionPercent=x) for id,name,o,x in [('closed','Closed / seated',0,0),('lift','Partially lifted',12,0),('removed','Removed lid / both interiors',100,0),('exploded','Exploded subassemblies',65,100)]]
 formats=[]
 for purpose,name,w,l,surface,grain,rotate in [('board','Board stock',700,1000,'sheet','bidirectional',True),('covering','Covering stock / paper and fabric partitioned by actual stock',1400,2000,'roll','directional',True),('lining','Lining paper stock',700,1000,'sheet','directional',True),('tape','Reinforcement tape master stock',500,2000,'roll','directional',True),('backing','Crown-leveling backing stock',700,1000,'sheet','bidirectional',True),('seating','Rim shim / stop stock',700,1000,'sheet','bidirectional',True),('insert','Optional insert stock',700,1000,'sheet','bidirectional',True)]:
  ids=[q['id'] for q in s.components if q['purpose']==purpose]
  formats.append(dict(id=purpose,name=name,componentIDs=ids,surface=surface,widthMM=w,lengthMM=l,marginMM=10,spacingMM=3,grain=grain,allowRotation=rotate,wasteAllowanceFraction=.08))
 steps=[]
 for id,title,purposes,joints,instructions in [
 ('cut','Cut independent stock',['board','backing','seating','insert'],[], 'Cut separate boards, selected backing and physical seating parts at their nominal contours. Grain and all quantities come from each piece. No score or groove is implied on independent boards. Retain printed source registration.'),
 ('boards','Assemble supported board joints',['board'],[q['id'] for q in s.joins if q['kind']=='floor-to-wall-edge'],'Dry assemble the selected floor and spanning-wall arrangement. Apply only the declared board glue regions. Where selected, drive the configured staples from the bare floor underside into the actual wall bottom edges. Inspect receiving depth and both leg paths. Do not substitute a carton or publication stapler. Tool settings require a physical sample.'),
 ('tape','Apply actual inside seam tape',['tape'],[],'Apply each selected strip across the two scheduled floor/wall contact regions. Fold the physical strip; use its own length, width, caliper and effective bond. Tape remains visible when the interior is unlined.'),
 ('backing','Level covered staple crowns',['backing'],[],'For a covered stapled half, add the actual slotted backing sheet around the crowns. Slots cover the retained placement envelope; changing staple placement updates this piece. The backing plus crown build remains in exterior dimensions. Bare stapled halves retain exposed crowns.'),
 ('cover','Apply covering pattern and overlaps',['covering'],[],'Use exactly the selected complete cross wrap or wall band plus separate face patch. Apply declared side and cap adhesive regions. Cross: cover exterior face, fold four wings, overlap relieved corner tabs, traverse the actual board edge, then turn in. Band: apply cap patch first, wrap four walls, retain the explicit overlapping visible seam, and fold rim / bottom turn-ins. Paper and backed fabric use independent stock/caliper/allowances.'),
 ('lining','Apply only selected lining regions',['lining'],[],'Apply independent floor/top and wall liners. They stop short of actual tape and covering turn-ins; none / floor / walls / full are independent for each half. Disabling removes pieces and build without erasing retained source configuration.'),
 ('seat','Install physical seating stops and check fit',['seating','insert'],[],'For axial space, bond the four measured rim shims; for overlap-locked seating, bond the four exterior stop ledges below the sliding region. At zero headspace the lid ceiling seats on the base rim. Review declared per-side finished clearance, overlap and reveal before inserting any optional loose insert. Test real compression and sliding force physically.')]:
  steps.append(dict(id=id,title=title,componentIDs=[q['id'] for q in s.components if q['purpose'] in purposes],jointIDs=joints,after=[steps[-1]['id']] if steps else [],instructions=instructions))
 # Each optional step names only its own physical option; exporting one
 # half/material/mode never emits instructions for a different retained option.
 common={q['id']:q for q in steps}
 common['backing']['after']=['boards','tape']
 steps=[common[k] for k in ['cut','boards','tape','backing']]
 for h,title in [('b','Base'),('l','Lid')]:
  for k,material in [('p','paper'),('c','backed fabric')]:
   for pattern in ['cross','band']:
    ids=[h+'-cross-'+k] if pattern=='cross' else [h+'-band-'+k,h+'-patch-'+k]
    instructions=('Apply the declared exterior-face and side adhesive regions. Fold four outer wings, then the four relieved corner tabs, the actual caliper traversals and the independent edge turn-ins. Keep the corner tabs beneath the adjacent side covering; they remain real local double layers.' if pattern=='cross' else 'Apply the separate exterior face patch first. Wrap the continuous five-segment wall band around the four boards; the front face is split at the adjustable seam position. Retain its physical overlapping seam flap, turn rim strips and inner flaps in, then overlap the bottom flaps over the face-patch border. The local recessed centre remains physical.')
    steps.append(dict(id=h+'-cover-'+k+'-'+pattern,title=title+' · '+material+' · '+('complete cross wrap' if pattern=='cross' else 'wall band and face patch'),componentIDs=ids,jointIDs=[q['id'] for q in s.joins if any(q['id'].startswith(id+'-') for id in ids)],after=['boards','tape','backing'],instructions='After the selected tape and any crown-leveling backing: '+instructions+' Use this piece’s own stock/caliper, orientation, corner relief and adhesive assumption.'))
  for region,ids in [('floor',[h+'-liner-floor']),('walls',[h+'-liner-'+e for e in 'nesw'])]:
   steps.append(dict(id=h+'-line-'+region,title=title+' · '+('floor / top liner' if region=='floor' else 'wall liners'),componentIDs=ids,jointIDs=[id+'-bond' for id in ids],after=['boards','tape','backing']+[h+'-cover-'+k+'-'+pattern for k in ['p','c'] for pattern in ['cross','band']],instructions='After this half’s selected covering: apply the declared adhesive regions and independent '+region+' lining pieces. Respect their actual tape setback, turn-in setback, caliper and face orientation. No omitted lining is implied by this step.'))
 for id,title,ids,instructions in [
  ('rim-shims','Axial headspace · physical rim shims',['rim-shim-'+e for e in 'nesw'],'Bond the four dimensioned shims on the base rim. Their actual top faces establish the selected axial headspace against the local lid ceiling layer. Do not float the lid independently.'),
  ('overlap-stops','Locked overlap · physical stop ledges',['overlap-stop-'+e for e in 'nesw'],'Bond the four dimensioned ledges on the finished base exterior below the sliding region. The lowest lid rim seats on their upper faces. Review overlap and reveal in the closed section.'),
  ('insert-fit','Optional removable insert',['removable-insert'],'Place this independent apertured insert after lining. Its per-side clearance is distinct from lid running clearance; confirm actual contents on a physical sample.')]:
  steps.append(dict(id=id,title=title,componentIDs=ids,jointIDs=[],after=['boards'],instructions=instructions))
 assumptions=[
 'Original CASK / COLLECT project-authored example, using generic independently stocked cut-piece hinge trees. Every separate board is one actual piece; covering hinges are physical folds, not board scores.',
 'Material appearance, dry adhesive layers, calipers, backed-fabric ply ratio, turn-in allowances and wire tool access are declared prototype assumptions. Stock/vendor strength, moisture, compression and sliding force require physical samples.',
 'Finished usable space is bounded by the largest actual inward local tape / lining / turn-in buildup. Liners deliberately stop short of tape and turn-ins; they do not silently stack through those pieces.',
 'Lid clear span is derived from the base finished side envelope over the overlap region plus twice the per-side running clearance. Exterior seating ledges below that region do not enlarge the sliding opening.',
 'Cross-wrap neutral-line edge allowance is board caliper plus two bond layers and one covering caliper. The two side faces carry corner tabs and therefore double build; front/back carry one layer. Band mode has one front seam overlap; its asymmetric finished envelope shifts the closed lid centre. All local buildups remain actual geometry.',
 'Band-and-patch mode applies the exterior face patch first, then overlaps bottom turn-under flaps. The central patch is locally recessed by one covering/bond layer; no imaginary air layer flattens it.',
 'Staple route accepted here: separate floor below walls, driven from floor underside into vertical wall bottom edges. Buried termination is intentional. Inset floor plus staples rejects rather than reinterpreting the receiving route.',
 'Wire crown buildup is retained. Covered stapled halves contain a real slotted leveling backing with thickness equal to the wire depth. Four retained vent/clearance slots support per-seam method switching.',
 'A lid is one coherent parent group. Closed, raised, fully removed and exploded views share the same accepted dimensions and canonical artwork. Presentation does not change fit or cutting files.',
 'Seating is physical: zero axial space is actual ceiling/rim contact; positive top-seat space creates rim shims; locked overlap creates exterior stop ledges. Conflicting locked depth/headspace rejects.',
 'Finish relief adds up to 0.08 mm above the lid exterior cap. The lid finished skirt-depth control excludes this local decorative peak; exact physical envelope reports it separately.',
 'All production cut channels are actual-size nominal design geometry. No kerf or blade compensation is silently applied. Technical guides and staple placement marks are not cutting or punching commands.',
 'Repacking stock changes material sheet placement only. It never changes canonical artwork, finish-mask IDs, source dimensions, source anchors, folded geometry or saved options.'
 ]
 definition=dict(version=4,name='CASK / COLLECT · separate-board setup assembly',parameters=s.params,derived=s.aliases,size=p('6*atlasW',f'{math.ceil(len(s.components)/6)}*atlasH'),stockThickness='bf',panels=s.panels,hinges=s.hinges,joins=s.joins,rootPanelID='b-floor',requirements=s.requirements,components=s.components,
  groups=[dict(id='base',name='Base subassembly',position=v(0,'explosion*.45',0),rotationDegrees=v()),dict(id='lid',name='Removable lid subassembly',position=v('lidSeparateX*lidSide','lidPoseY+explosion*.45','baseEnvelopeZ*(1-lidSide)'),rotationDegrees=v('180*(1-lidTurn)',0,0))],
  jointAttachments=s.attach,interiors=[dict(id='base-usable',name='Finished usable base interior',componentID='b-floor',origin=v('(bfloorW-buw)/2','-(bfloorD-bud)/2','bf/2+bfloorBuild'),size=v('buw','busableH','bud'),rotationDegrees=v(90,0,0),opening=dict(axis='y',width='buw',height='bud',origin=p()))],
  controls=dict(groups=[dict(id=id,title=title) for id,title in groupTitles],parameters=s.controls,measurements=measurements,dimensionReferenceParameter='dimensionReference',poses=poses),
  production=dict(version=1,materials=formats,steps=steps,assumptions=assumptions,guides=s.guides,views=[dict(id=id,title=name,projection='isometric',openingPercent=o,explosionPercent=x) for id,name,o,x in [('closed','Closed / finished fit',0,0),('raised','Partially lifted lid',12,0),('removed','Removed lid / interior',100,0),('exploded','Exploded independent stock',65,100)]]+[dict(id='section-x',title='Closed length section / actual layers',projection='front',openingPercent=0,explosionPercent=0,sectionAxis='x',sectionOffsetMM=0),dict(id='section-z',title='Closed width section / actual layers',projection='side',openingPercent=0,explosionPercent=0,sectionAxis='z',sectionOffsetMM=0)],foldRoles=s.roles,quantity=1,labels=True,registrationMarks=True,bleedMM=0,declaredKerfMM=0,processNotes='Nominal design packet; physical print bleed, cutter compensation and stapler adjustment require explicit production settings. No machine commands are issued.'))
 return dict(kind='constructionStarter',version=1,id='two-piece-setup',name='CASK / COLLECT · two-piece setup box',summary='Independent base and lid boards, real paper / backed-fabric cross or band patterns, optional lining, actual tape and supported board staples. All controls, fit assumptions and production files share this editable source.',symbol='shippingbox',ownerID=uid('owner'),definition=definition,stock=copy.deepcopy(BOARD),artwork=art([]),artworkSources=sources)

# A small independent numerical interpreter verifies emitted data; no Swift/app work.
FUNCTIONS={n:getattr(math,n) for n in ['sqrt','sin','cos','tan','asin','acos','atan','floor','ceil']}
FUNCTIONS.update(min=min,max=max,abs=abs,round=round,pow=pow,hypot=math.hypot,atan2=math.atan2,clamp=lambda x,a,b:min(b,max(a,x)))
def number(raw,values):
 if isinstance(raw,(int,float)):return raw
 tree=ast.parse(raw,mode='eval')
 def read(node):
  if isinstance(node,ast.Expression):return read(node.body)
  if isinstance(node,ast.Constant) and isinstance(node.value,(int,float)):return node.value
  if isinstance(node,ast.Name):return values[node.id]
  if isinstance(node,ast.UnaryOp) and isinstance(node.op,(ast.UAdd,ast.USub)):return read(node.operand)*(1 if isinstance(node.op,ast.UAdd) else -1)
  if isinstance(node,ast.BinOp) and type(node.op) in {ast.Add,ast.Sub,ast.Mult,ast.Div}:return {ast.Add:operator.add,ast.Sub:operator.sub,ast.Mult:operator.mul,ast.Div:operator.truediv}[type(node.op)](read(node.left),read(node.right))
  if isinstance(node,ast.Call) and isinstance(node.func,ast.Name) and node.func.id in FUNCTIONS:return FUNCTIONS[node.func.id](*map(read,node.args))
  raise ValueError('Not a CAD scalar: '+raw)
 return read(tree)
def resolve(parameters,aliases,changes=None,pose=None):
 values={q['name']:q['value'] for q in parameters};values.update(changes or {});values.update(dict(fold=100,opening=0,explosion=0));values.update(pose or {})
 pending=aliases.copy()
 for _ in range(len(pending)+1):
  for key,raw in list(pending.items()):
   try:values[key]=number(raw,values)
   except KeyError:continue
   if not math.isfinite(values[key]):raise ValueError('Nonfinite '+key)
   del pending[key]
  if not pending:return values
 raise ValueError('Unresolved / cyclic aliases: '+', '.join(pending))

VARIANTS=[
 dict(id='01-paper-tape-unlined',name='01 / Oat paper · taped · unlined',values={}),
 dict(id='02-paper-independent-lining',name='02 / Paper · lined base · lid top lining',values=dict(bLining=3,lLining=1,bPattern=1,lPattern=0)),
 dict(id='03-fabric-contrasting-lining',name='03 / Backed spruce cloth · ivory lining',values=dict(covering=2,lining=3,pattern=0,bTurnN=12,bTurnE=12,bTurnS=12,bTurnW=12,lTurnN=8,lTurnE=8,lTurnS=8,lTurnW=8,lidDepth=32)),
 dict(id='04a-board-staples-uncovered',name='04A / Bare board · actual through-floor staples',values=dict(jointMethod=2,covering=0,lining=0,lidDepth=27)),
 dict(id='04b-board-staples-covered',name='04B / Covered crowns · real slotted backing',values=dict(jointMethod=3,covering=1,lining=3,lidDepth=31,lTurnN=8,lTurnE=8,lTurnS=8,lTurnW=8)),
 dict(id='05-mixed-partial-overlap',name='05 / Oat base · cloth lid · shallow overlap',values=dict(bCover=1,lCover=2,bLining=0,lLining=1,seatingMode=1,lidOverlap=11,lidDepth=29,bPattern=1,lPattern=1)),
 dict(id='06-independent-deep-lid',name='06 / Independent board stocks · deeper lid',values=dict(width=220,depth=155,height=78,linkedBoards=0,bFloorMM=2.8,bWallMM=2.1,lFloorMM=1.6,lWallMM=1.3,lidDepth=48,runningClearance=.85,bCover=2,lCover=1,bLining=1,lLining=3,bFloorArrangement=1,bWallSpan=1,jointMethod=0))
]

def resized_stock(material,caliper):
 """Match the native scalar-caliper edit without replacing stock identity or appearance."""
 result=copy.deepcopy(material)
 previous=sum(q['thicknessMM'] for q in result['plies']) if 'plies' in result else result['thicknessMM']
 assert previous>0 and .01<=caliper<=20
 result['thicknessMM']=caliper
 if 'plies' in result:
  for ply in result['plies']:ply['thicknessMM']*=caliper/previous
 return result

def with_values(starter,changes):
 result=copy.deepcopy(starter)
 before=resolve(starter['definition']['parameters'],starter['definition']['derived'])
 for q in result['definition']['parameters']:
  if q['name'] in changes:q['value']=changes[q['name']]
 after=resolve(result['definition']['parameters'],result['definition']['derived'])
 result['stock']=resized_stock(result['stock'],number(result['definition']['stockThickness'],after))
 for source in result['artworkSources']:
  byID={q['id']:q for q in source['artwork']['elements']}
  for region in source.get('artworkRegions',[]):
   oldOrigin=pointnum(region['origin'],before);newOrigin=pointnum(region['origin'],after)
   oldSize=pointnum(region['size'],before);newSize=pointnum(region['size'],after)
   for anchor in region.get('anchors',[]):
    dx=newOrigin[0]-oldOrigin[0]+anchor['horizontal']*(newSize[0]-oldSize[0]);dy=newOrigin[1]-oldOrigin[1]+anchor['vertical']*(newSize[1]-oldSize[1])
    for id in anchor['elementIDs']:
     byID[id]['x']+=dx;byID[id]['y']+=dy
 apply_secondary_ink(result['definition'],result['artworkSources'])
 return result

def apply_secondary_ink(definition,sources):
 """Author readable small ink on cloth; retain source/layer IDs and all layout.

 `sources` may be portable starter sources or live remapped canonical sources.
 The source UUID comes from the actual component mapping, never a fixed UUID.
 This is an explicit data-authoring choice, not app-side automatic recoloring.
 """
 values=resolve(definition['parameters'],definition['derived']);changed=[]
 byID={q['id']:q for q in sources}
 for h in 'bl':
  component=next(c for c in definition['components'] if c['id']==h+'-cross-c')
  sourceID=component['front']['sourceObjectID'];source=byID.get(sourceID)
  if not source:continue
  region=next((r for r in source.get('artworkRegions',[]) if r['id']==h+'-cap'),None)
  if not region:raise ValueError('Missing cap artwork region on '+sourceID)
  ids={id for anchor in region.get('anchors',[]) for id in anchor['elementIDs']}
  ink='#D5D0BA' if values[h+'cover']==2 else '#243F39'
  secondary=[q for q in source['artwork']['elements'] if q['id'] in ids and
    (q.get('text') in ['CASK / COLLECT     01','A place for small collections.'] or q.get('kind')=='rectangle')]
  if len(secondary)!=3:raise ValueError('Expected three secondary cap ink elements on '+sourceID)
  for q in secondary:
   if q['color']!=ink:q['color']=ink;changed.append(q['id'])
 return changed

def repair_cross_corner_bridges(definition):
 """Guarded project-data repair for an already imported/remapped construction.

 Only corner polygons and their hinge placement change. The former offset's
 displaced tab plane becomes a connected tapered part of its parent wing;
 child-tab world geometry, cap/rim edges and finished envelopes stay fixed.
 The corresponding production fold guides follow the relocated hinge line.
 All UUIDs, artwork mappings, stocks, choices, joins and masks are retained.
 Input must match the authored legacy or repaired geometry exactly: hand-edited
 source geometry is rejected rather than overwritten. Apply via the public
 configure command with the current expected_revision, then preview normally.
 """
 template=build()['definition'];candidate=copy.deepcopy(definition)
 targetPanels={q['id']:q for q in template['panels']};targetHinges={q['id']:q for q in template['hinges']}
 panels={q['id']:q for q in candidate['panels']};hinges={q['id']:q for q in candidate['hinges']}
 targetGuides={q['id']:q for q in template['production']['guides']};guides={q['id']:q for q in candidate['production']['guides']}
 changedPanels=[];changedHinges=[];changedGuides=[]
 def replace(row,expected,desired,fields):
  current={k:row[k] for k in fields}
  if current==desired:return False
  if current!=expected:raise ValueError('Refusing to overwrite modified corner geometry: '+row['id'])
  for k,value in desired.items():row[k]=copy.deepcopy(value)
  return True
 for index,component in enumerate(template['components']):
  id=component['id']
  if '-cross-' not in id:continue
  if id not in {c['id'] for c in candidate['components']}:raise ValueError('Missing authored wrap '+id)
  h,k=id[0],id[-1];z=h+k;X,Y,W,H=[z+n for n in ['X','Y','W','H']]
  skin='paperMM' if k=='p' else 'clothMM'
  sx=f'5+{index%6}*atlasW';sy=f'5+{index//6}*atlasH'
  point=lambda x,y:p(add(sx,x),add(sy,y))
  for edge in 'ns':
   y0=f'{Y}-{H}' if edge=='n' else f'{Y}+{z}D'
   wingID=id+'/'+edge+' outer wall';old=[point(q['x'],q['y']) for q in rect(X,y0,W,H)]
   if replace(panels[wingID],dict(polygon=old),dict(polygon=targetPanels[wingID]['polygon']),['polygon']):changedPanels.append(wingID)
   for left in [True,False]:
    tabID=id+'/'+edge+(' left' if left else ' right')+' corner overlap';hingeID=tabID+'/bend'
    xx=X if left else f'{X}+{W}';dx='-cornerTab' if left else 'cornerTab';ta=f'{y0}+2';tb=f'{y0}+{H}-2'
    old=[point(xx,ta),point(add(xx,dx),f'{ta}+2'),point(add(xx,dx),f'{tb}-2'),point(xx,tb)]
    if replace(panels[tabID],dict(polygon=old),dict(polygon=targetPanels[tabID]['polygon']),['polygon']):changedPanels.append(tabID)
    fields=['start','end','layerOffsetMM'];expected=dict(start=point(xx,ta),end=point(xx,tb),layerOffsetMM=f'-({skin}+coverBond)')
    desired={f:targetHinges[hingeID][f] for f in fields}
    if replace(hinges[hingeID],expected,desired,fields):changedHinges.append(hingeID)
    guideID=hingeID+'/guide'
    if replace(guides[guideID],dict(points=[p(xx,ta),p(xx,tb)]),dict(points=targetGuides[guideID]['points']),['points']):changedGuides.append(guideID)
 return candidate,dict(panelIDs=changedPanels,hingeIDs=changedHinges,guideIDs=changedGuides,changedPanels=len(changedPanels),changedHinges=len(changedHinges),changedGuides=len(changedGuides))

def variant_starter(id):
 source=build();case=next(q for q in VARIANTS if q['id']==id)
 source=with_values(source,case['values']);source['id']=case['id'];source['name']=case['name'];return source

def add_variant(call,id,position=(0,0,0)):
 """Caller owns current project and ordinary LAB app. Exactly one public edit."""
 return call('form_construction',dict(command='add_starter',starter=variant_starter(id),position=list(position)))

def main():
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--check',action='store_true',help='Validate all source cases without writing any file.')
 parser.add_argument('--snapshots',action='store_true',help='Also emit full working snapshots; not required for normal regeneration.')
 args=parser.parse_args()
 starter=build();validate(starter);reports=[]
 for case in VARIANTS:
  candidate=with_values(starter,case['values']);candidate['id']=case['id'];candidate['name']=case['name'];report=validate(candidate)
  if args.snapshots and not args.check:
   snapshots=HERE/'variants';snapshots.mkdir(exist_ok=True)
   (snapshots/(case['id']+'.json')).write_text(json.dumps(candidate,indent=2,ensure_ascii=False)+'\n')
  reports.append(dict(**case,measurements=report))
 data=json.dumps(starter,indent=2,ensure_ascii=False)+'\n'
 if not args.check:
  OUT.parent.mkdir(parents=True,exist_ok=True);OUT.write_text(data)
  (HERE/'variants.json').write_text(json.dumps(reports,indent=2,ensure_ascii=False)+'\n')
 print(json.dumps(dict(resource=str(OUT),sha256=hashlib.sha256(data.encode()).hexdigest(),bytes=len(data.encode()),parameters=len(starter['definition']['parameters']),aliases=len(starter['definition']['derived']),panels=len(starter['definition']['panels']),pieces=len(starter['definition']['components']),variants=len(reports),check_only=args.check),indent=2))

def pointnum(q,values):return (number(q['x'],values),number(q['y'],values))
def area(poly):return abs(sum(a[0]*b[1]-b[0]*a[1] for a,b in zip(poly,poly[1:]+poly[:1])))/2
def cross(a,b,c):return (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])
def distance(p,a,b):
 dx,dy=b[0]-a[0],b[1]-a[1];n=dx*dx+dy*dy
 t=max(0,min(1,((p[0]-a[0])*dx+(p[1]-a[1])*dy)/n)) if n else 0
 return math.hypot(p[0]-a[0]-t*dx,p[1]-a[1]-t*dy)
def onboundary(p,poly):return min(distance(p,a,b) for a,b in zip(poly,poly[1:]+poly[:1]))<1e-6
def convex_intersection(subject,clip):
 # All emitted panels are convex; independently clip their actual coordinates.
 sign=1 if sum(a[0]*b[1]-b[0]*a[1] for a,b in zip(clip,clip[1:]+clip[:1]))>0 else -1
 out=subject
 for a,b in zip(clip,clip[1:]+clip[:1]):
  inp,out=out,[]
  if not inp:break
  prev=inp[-1];dp=sign*cross(a,b,prev)
  for cur in inp:
   dc=sign*cross(a,b,cur)
   if dc>=-1e-8:
    if dp < -1e-8:
     t=dp/(dp-dc);out.append((prev[0]+t*(cur[0]-prev[0]),prev[1]+t*(cur[1]-prev[1])))
    out.append(cur)
   elif dp>=-1e-8:
    t=dp/(dp-dc);out.append((prev[0]+t*(cur[0]-prev[0]),prev[1]+t*(cur[1]-prev[1])))
   prev,dp=cur,dc
 return out

def mm(a,b):return [[sum(a[r][k]*b[k][c] for k in range(4)) for c in range(4)] for r in range(4)]
def ident():return [[int(i==j) for j in range(4)] for i in range(4)]
def trans(x=0,y=0,z=0):
 m=ident();m[0][3],m[1][3],m[2][3]=x,y,z;return m
def rotation(x=0,y=0,z=0):
 def axis(x,y,z,angle):
  a=math.radians(angle);c=math.cos(a);si=math.sin(a);t=1-c
  return [[t*x*x+c,t*x*y-si*z,t*x*z+si*y,0],[t*x*y+si*z,t*y*y+c,t*y*z-si*x,0],[t*x*z-si*y,t*y*z+si*x,t*z*z+c,0],[0,0,0,1]]
 return mm(axis(0,0,1,z),mm(axis(0,1,0,y),axis(1,0,0,x)))
def world(m,q):return tuple(sum(m[r][i]*q[i] for i in range(3))+m[r][3] for r in range(3))
def inverse(m,q):return tuple(sum(m[i][r]*(q[i]-m[i][3]) for i in range(3)) for r in range(3))
def dot(a,b):return sum(x*y for x,y in zip(a,b))
def sub(a,b):return tuple(x-y for x,y in zip(a,b))
def cross3(a,b):return (a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0])
def unit(a):return tuple(x/math.sqrt(dot(a,a)) for x in a)
def pose_panels(d,values):
 groups={}
 for group in d['groups']:
  pos=[number(group['position'][k],values) for k in 'xyz'];rot=[number(group['rotationDegrees'][k],values) for k in 'xyz']
  groups[group['id']]=mm(trans(*pos),rotation(*rot))
 matrices={};owners={};thickness={}
 for c in d['components']:
  a=pointnum(c['anchor'],values);pos=[number(c['position'][k],values) for k in 'xyz'];rot=[number(c['rotationDegrees'][k],values) for k in 'xyz']
  matrices[c['rootPanelID']]=mm(groups[c['groupID']],mm(trans(*pos),mm(rotation(*rot),trans(-a[0],a[1],0))));owners[c['rootPanelID']]=c
 for _ in range(len(d['panels'])):
  change=False
  for h in d['hinges']:
   if h['parentPanelID'] not in matrices or h['childPanelID'] in matrices:continue
   a,b=pointnum(h['start'],values),pointnum(h['end'],values);dx,dy=b[0]-a[0],a[1]-b[1];n=math.hypot(dx,dy);x,y=dx/n,dy/n
   angle=math.radians(number(h['angleDegrees'],values));co,si=math.cos(angle),math.sin(angle);t=1-co
   r=[[t*x*x+co,t*x*y,si*y,0],[t*x*y,t*y*y+co,-si*x,0],[-si*y,si*x,co,0],[0,0,0,1]]
   hinge=mm(trans(a[0],-a[1],0),mm(r,mm(trans(-a[0],a[1],0),trans(0,0,-number(h.get('layerOffsetMM',0),values)))))
   matrices[h['childPanelID']]=mm(matrices[h['parentPanelID']],hinge);owners[h['childPanelID']]=owners[h['parentPanelID']];change=True
  if not change:break
 assert len(matrices)==len(d['panels'])
 for id,c in owners.items():thickness[id]=number(c['stockThickness'],values)
 return matrices,owners,thickness

def validate_contact_geometry(starter,values):
 d=starter['definition'];matrices,owners,thickness=pose_panels(d,values)
 polys={q['id']:[pointnum(x,values) for x in q['polygon']] for q in d['panels']};joins={q['id']:q for q in d['joins']}
 active={c['id'] for c in d['components'] if number(c['enabled'],values)>.5}
 def region(raw,id):
  pts=[pointnum(q,values) for q in raw['polygon']];t=thickness[id];m=matrices[id]
  if 'edgeIndex' in raw:
   poly=polys[id];i=raw['edgeIndex'];a,b=poly[i],poly[(i+1)%len(poly)];n=math.dist(a,b)
   assert all(0<=x<=n+1e-7 and 0<=y<=t+1e-7 for x,y in pts),(id,'edge target outside caliper',pts,t)
   return [world(m,(a[0]+(b[0]-a[0])*x/n,-a[1]-(b[1]-a[1])*x/n,y-t/2)) for x,y in pts]
  assert abs(area(convex_intersection(pts,polys[id]))-area(pts))<.01,(id,'face target outside material')
  return [world(m,(x,-y,t/2*(1 if raw['side']=='outside' else -1))) for x,y in pts]
 checks=dict(adhesive=0,tape=0,staples=0)
 for a in d['jointAttachments']:
  if number(a.get('enabled',1),values)<.5:continue
  j=joins[a['joinID']];first,second=j['firstPanelID'],j['secondPanelID']
  assert owners[first]['id'] in active and owners[second]['id'] in active
  if 'adhesive' in a:
   glue=a['adhesive'];A,B=region(glue['firstRegion'],first),region(glue['secondRegion'],second)
   normal=unit(cross3(sub(A[1],A[0]),sub(A[2],A[0])));sep=max(abs(dot(sub(q,A[0]),normal)) for q in B);limit=number(glue['thicknessMM'],values)+.020001
   assert sep<=limit,(a['id'],'disconnected adhesive faces',sep,limit)
   drop=max(range(3),key=lambda i:abs(normal[i]));project=lambda q:tuple(q[i] for i in range(3) if i!=drop)
   intersection=convex_intersection([project(q) for q in A],[project(q) for q in B]);assert area(intersection)>.001,(a['id'],'no physical adhesive overlap')
   checks['adhesive']+=1
  if 'tape' in a:
   tape=a['tape'];strip=tape['componentID'];assert strip in active
   targets=[region(tape['firstRegion'],first),region(tape['secondRegion'],second)]
   ids=[id for id,c in owners.items() if c['id']==strip]
   for target in targets:
    covered=False
    for id in ids:
     local=[inverse(matrices[id],pt) for pt in target];project=[(q[0],-q[1]) for q in local]
     if max(abs(q[2]) for q in local)>thickness[id]/2+number(tape['bondThicknessMM'],values)+.020001:continue
     if max(q[2] for q in local)-min(q[2] for q in local)>.02:continue
     if abs(area(convex_intersection(project,polys[id]))-area(project))<.01:covered=True
    assert covered,(a['id'],'actual strip does not cover region',target)
   checks['tape']+=1
 return checks

def validate(starter):
 d=starter['definition'];values=resolve(d['parameters'],d['derived'])
 ownerStock=starter['stock'];ownerTotal=sum(q['thicknessMM'] for q in ownerStock['plies']) if 'plies' in ownerStock else ownerStock['thicknessMM']
 assert abs(ownerStock['thicknessMM']-ownerTotal)<1e-9,('owner-stock-ply-total',ownerStock['thicknessMM'],ownerTotal)
 assert abs(ownerTotal-number(d['stockThickness'],values))<1e-9,('owner-stock-caliper',ownerTotal,number(d['stockThickness'],values))
 assert len(d['panels'])<=256 and len(d['components'])<=128 and len(d['parameters'])<=128 and len(d['derived'])<=256
 assert len(d['requirements'])<=128 and len(d['joins'])<=128
 assert len(json.dumps(starter).encode())<4*1024*1024
 for q in d['parameters']:assert q['minimum']<=q['value']<=q['maximum'],q['name']
 for q in d['requirements']:
  a,b=number(q['lhs'],values),number(q['rhs'],values)
  passes={'==':abs(a-b)<1e-7,'<=':a<=b,'>=':a>=b,'>':a>b,'<':a<b,'!=':abs(a-b)>1e-7}[q['relation']]
  assert passes,(q['id'],a,q['relation'],b,q['message'])
 extent=pointnum(d['size'],values);assert all(0<x<=10000 for x in extent),extent
 panels={q['id']:[pointnum(x,values) for x in q['polygon']] for q in d['panels']}
 assert len(panels)==len(d['panels'])
 for id,poly in panels.items():
  assert area(poly)>.001,(id,'degenerate',poly)
  assert all(-1e-7<=x<=extent[0]+1e-7 and -1e-7<=y<=extent[1]+1e-7 for x,y in poly),(id,'outside atlas')
  # Strict convexity, including the tapered eight-point corner wings.
  turns=[cross(poly[i-1],poly[i],poly[(i+1)%len(poly)]) for i in range(len(poly))]
  assert all(t>=-1e-7 for t in turns) or all(t<=1e-7 for t in turns),(id,'nonconvex / crossing',poly)
 for aIndex,(id,a) in enumerate(panels.items()):
  ax=[q[0] for q in a];ay=[q[1] for q in a]
  for other,b in list(panels.items())[aIndex+1:]:
   bx=[q[0] for q in b];by=[q[1] for q in b]
   if min(max(ax),max(bx))<=max(min(ax),min(bx))+1e-7 or min(max(ay),max(by))<=max(min(ay),min(by))+1e-7:continue
   overlap=convex_intersection(a,b)
   assert not overlap or area(overlap)<.0001,(id,other,'overlapping saved flat panels',area(overlap))
 for q in d['panels']:
  poly=panels[q['id']]
  holes=[]
  for hole in q.get('cutouts',[]):
   pts=[pointnum(z,values) for z in hole['polygon']];assert area(pts)>.001
   assert abs(area(convex_intersection(pts,poly))-area(pts))<.001,(q['id'],hole['id'],'hole outside material',pts)
   assert all(not onboundary(p,poly) for p in pts),(q['id'],'hole touches edge')
   for previous in holes:assert area(convex_intersection(pts,previous))<.001,(q['id'],'holes overlap')
   holes.append(pts)
 for q in d['hinges']:
  a,b=pointnum(q['start'],values),pointnum(q['end'],values)
  assert math.dist(a,b)>.001
  for id in [q['parentPanelID'],q['childPanelID']]:assert all(onboundary(pt,panels[id]) for pt in [a,b,((a[0]+b[0])/2,(a[1]+b[1])/2)]),(q['id'],id,'hinge off material boundary',a,b)
 # Canonical physical registration can never rescale the artwork itself.
 for q in starter['artworkSources']:
  assert 0<number(q['width'],values)<=10000 and 0<number(q['height'],values)<=10000
  assert q['artwork']['backgroundOpacity']==0
  for region in q.get('artworkRegions',[]):
   assert set(x['id'] for x in q['artwork']['elements'])==set(sum((a['elementIDs'] for a in region.get('anchors',[])),[]))
 # Every real cut piece has exactly one stock-format assignment.
 assigned=sum((q['componentIDs'] for q in d['production']['materials']),[])
 assert len(assigned)==len(set(assigned))==len(d['components'])
 assert set(assigned)=={q['id'] for q in d['components']}
 checks=validate_contact_geometry(starter,values)
 # Independent target arithmetic: hold reference, running clearance, real seats.
 if values['dimensionReference']==0:
  assert abs(values['buw']-values['width'])<1e-8 and abs(values['bud']-values['depth'])<1e-8 and abs(values['busableH']-values['height'])<1e-8
 else:
  assert abs(values['baseOutsideW']-values['width'])<1e-8 and abs(values['baseOutsideD']-values['depth'])<1e-8
  assert abs(values['baseOutsideH']-values['height'])<1e-8
 assert abs(values['luw']-values['bfinishedW']-2*values['runningClearance'])<1e-8
 assert abs(values['lud']-values['bfinishedD']-2*values['runningClearance'])<1e-8
 assert abs(values['lidSeatY']-values['lf']-values['lidSeatBuild']-values['baseRim']-values['headspace'])<1e-8
 assert abs(values['baseRim']-(values['lidSeatY']-values['ltop']-values['lon']*(values['lskin']+values['coverBond']))-values['overlap'])<1e-8
 active=[q for q in d['components'] if number(q['enabled'],values)>0.5]
 assert len(active)>=10
 # Verify full source poses resolve at interior samples, with unchanged dimensions.
 for opening in [0,12,25,45,65,80,100]:
  posed=resolve(d['parameters'],d['derived'],pose=dict(opening=opening,explosion=73))
  assert posed['bfinishedW']==values['bfinishedW'] and posed['headspace']==values['headspace']
  for q in d['components']+d['groups']:
   for field in ['position','rotationDegrees']:
    assert all(math.isfinite(number(x,posed)) for x in q[field].values())
 # Exactly seventeen faces in each complete wrap, all preserved across modes.
 for q in d['components']:
  if '-cross-' in q['id']:assert sum(id==q['id'] or id.startswith(q['id']+'/') for id in panels)==17
 return dict(usable=[values['buw'],values['bud'],values['busableH']],finishedOutside=[values['baseOutsideW'],values['baseOutsideD'],values['baseOutsideH']],lidClear=[values['luw'],values['lud']],overlap=values['overlap'],headspace=values['headspace'],ownerStockTotalMM=ownerTotal,activePieces=len(active),atlas=list(extent),contactChecks=checks)

if __name__=='__main__':main()
