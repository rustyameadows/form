#!/usr/bin/env python3
"""Author the unchanged organic reference with ordinary parametric CAD operations.

This is model content. It uses existing cubic curve profiles, loft and shell.
Run without arguments to regenerate model.json; --body-only produces a diagnostic solid.
"""
import argparse,json,math,uuid
from pathlib import Path

ROOT=Path(__file__).resolve().parents[3]
PEAK=.47
NECK=.94
SIGNIFICANT_DIGITS=12
BASE_LOBES=0.0
ANGULAR_SECONDARY=-.18
ANGULAR_PHASE=.055
STATIONS=[0,.08,.19,.32,.47,.60,.72,.82,.90,.96,1]
DENSE_STATIONS=[0,.04,.10,.20,.34,.47,.55,.63,.70,.76,.82,.87,.92,.96,1]
FAIR_STATIONS=[0,.025,.06,.11,.18,.26,.35,.42,.47,.52,.57,.62,.67,.72,.77,.82,.87,.92,.96,1]
NECK_STATIONS=[0,.06,.11,.18,.26,.35,.47,.52,.57,.62,.67,.72,.77,.82,.87,.92,.94,.96,.98,1]
STATION_LAYOUT='neck-transition'

def ident(name):return str(uuid.uuid5(uuid.NAMESPACE_URL,'form-organic-analytic/'+name))
def smooth(t):return t*t*t*(10+t*(-15+6*t))
def number(x):
 if abs(x)<1e-13:return '0'
 s=format(x,f'.{SIGNIFICANT_DIGITS}g').replace('-0.','-.')
 return s[1:] if s.startswith('0.') else s

def law(t):
 """Linear radius/translation bases, C2 across belly and cylindrical neck."""
 if t<=PEAK:
  v=t/PEAK;f=.6*(1-(1-v)**3)+.4*(1-(1-v)**2)
  radii=(1-f,f,0)
  lobes=BASE_LOBES+(1-BASE_LOBES)*smooth(v)
  offsets=(smooth(v),0)
 elif t<NECK:
  u=(t-PEAK)/(NECK-PEAK);g=1-smooth(u**1.25)
  # Match the lower law's second derivative for every radius setting.
  correction=-.4*((NECK-PEAK)/PEAK)**2*u*u*(1-u)**3
  radii=(-correction,g+correction,1-g)
  blend=smooth(u**1.4);offsets=(1-blend,blend);lobes=g
 else:radii=(0,0,1);offsets=(0,1);lobes=0
 nominal=sum(w*r for w,r in zip(radii,(30,69,14.5)))
 # Section scaling supplies one radius factor; this supplies the second.
 rib=nominal/69
 return radii,lobes,rib,offsets

def combination(terms):
 out=''
 for name,weight in terms:
  if abs(weight)<1e-13:continue
  part=name if abs(abs(weight)-1)<1e-13 else name+'*'+number(abs(weight))
  out+=('-' if weight<0 else '+' if out else '')+part
 return out or '0'

def angular_wave(a):
 """A soft three-lobed polar contour, with an optional broad-tip correction."""
 phase=a+ANGULAR_PHASE
 return (math.cos(3*phase)+ANGULAR_SECONDARY*math.cos(6*phase))*(1-.15*math.cos(a)+.08*math.sin(a))+.02*math.cos(a)

def model(segments=192,flutes=48,flute_depth=.25,body_only=False,belly_offset=-10.0,neck_offset=16.0,depth_ratio=1.015,lobe_amount=.12,neck_depth_offset=-17,stations=20,refine=True,belly_radius=73.0,minimum_lobes=.10):
 params=[('height',180,150,210,'mm'),('bellyHeight',84.6,72,96,'mm'),('bellyRadius',belly_radius,62,76,'mm'),('baseRadius',30,26,34,'mm'),('neckRadius',14.5,12.5,16,'mm'),('bellyOffset',belly_offset,-12,0,'mm'),('neckOffset',neck_offset,16,30,'mm'),('neckDepthOffset',neck_depth_offset,-22,-12,'mm'),('depthScale',depth_ratio,.94,1.04,'ratio'),('lobeAmount',lobe_amount,minimum_lobes,.27,'ratio'),('fluteDepth',flute_depth,0,.25,'mm'),('wall',3,2.5,3.5,'mm')]
 selected_stations={11:STATIONS,15:DENSE_STATIONS,20:FAIR_STATIONS if STATION_LAYOUT=='balanced' else NECK_STATIONS}[stations]
 if flutes and segments<4*flutes:raise ValueError('Use at least four C2 control samples per physical flute.')
 features=[];step=2*math.pi/segments
 for j,t in enumerate(selected_stations):
  radius_weights,lobes,rib,offsets=law(t)
  radius=combination(zip(['baseRadius','bellyRadius','neckRadius'],radius_weights))
  if '+' in radius or '-' in radius:radius='('+radius+')'
  controls=[]
  for i in range(segments):
   a=i*step;c,s=math.cos(a),math.sin(a)
   wave=angular_wave(a)
   controls.append(((c,lobes*wave*c,rib*math.cos(flutes*a)*c),(s,lobes*wave*s,rib*math.cos(flutes*a)*s)))
  gain=1/(2/3+math.cos(flutes*step)/3) if flutes else 1
  def coordinate(coefficients,depth):
   a,b,c=coefficients
   factor=number(a)+('+' if b>=0 else '-')+'lobeAmount*'+number(abs(b)) if abs(b)>1e-13 else number(a)
   value='('+factor+')'
   if flutes and abs(c)>1e-13:value+=('+' if c>=0 else '-')+'fluteDepth/bellyRadius*'+number(abs(c)*gain)
   assert len(value)<=256,(len(value),value)
   return value
  curves=[]
  for i in range(segments):
   weights=[[(i-1,1/6),(i,4/6),(i+1,1/6)],[(i,4/6),(i+1,2/6)],[(i,2/6),(i+1,4/6)],[(i,1/6),(i+1,4/6),(i+2,1/6)]]
   points=[]
   for w in weights:
    xy=[[sum(weight*controls[k%segments][axis][coefficient] for k,weight in w) for coefficient in range(3)] for axis in range(2)]
    points.append(dict(x=coordinate(xy[0],False),y=coordinate(xy[1],True)))
   curves.append(dict(kind='cubicBezier',**dict(zip(['start','control1','control2','end'],points))))
  sketch=ident('unit-ring-'+str(j))
  features.append(dict(id=sketch,name=f'Unit section curve {j+1:02}',operation=dict(kind='curveProfile',inputs=[],values={},curves=curves,plane=dict(origin=dict(x=0,y=0,z=0),u=dict(x=1,y=0,z=0),v=dict(x=0,y=0,z=-1)))))
  profile=sketch
  if refine:
   profile=ident('refined-ring-'+str(j));features.append(dict(id=profile,name=f'Refine tangent section spans {j+1:02}',operation=dict(kind='refine',inputs=[sketch],values={})))
  vertical_weight=math.sin(math.pi*t)**2/math.sin(math.pi*PEAK)**2
  vertical=combination([('height',t-PEAK*vertical_weight),('bellyHeight',vertical_weight)])
  features.append(dict(id=ident('ring-'+str(j)),name=f'Placed analytic section {j+1:02}',operation=dict(kind='transform',inputs=[profile],values={},matrix=[radius,0,0,combination(zip(['bellyOffset','neckOffset'],offsets)),0,1,0,vertical,0,0,'depthScale*'+radius,'neckDepthOffset*'+number(offsets[1]),0,0,0,1])))
 loft=ident('body');features.append(dict(id=loft,name='Continuous analytic body',operation=dict(kind='loft',inputs=[ident('ring-'+str(j)) for j in range(len(selected_stations))],values={},ruled=False)))
 output=loft
 if not body_only:
  output=ident('normal-wall');features.append(dict(id=output,name='True normal wall and open mouth',operation=dict(kind='shell',inputs=[loft],values=dict(thickness='wall'),selection=dict(faceAtMaximum=dict(axis='y')))))
 requirements=[dict(id='neck-wall',lhs='wall',relation='<',rhs='neckRadius*.35',message='Retain a bounded physical wall and open neck.')]
 if flutes:
  lobe_floor=1.2*(1+abs(ANGULAR_SECONDARY))
  requirements.append(dict(id='detail-curvature-margin',lhs='wall*fluteDepth*'+str(flutes*flutes)+'*1.22',relation='<',rhs='pow(bellyRadius*(1-lobeAmount*'+number(lobe_floor)+'),2)*.75',message='Keep a conservative ridge-curvature margin for the declared normal wall; kernel validation is still required.'))
 checks=[dict(id='one-solid',outputID=output,metric='solids',relation='==',value=1,message='Retain one valid material solid.'),dict(id='height',outputID=output,metric='height',relation='==',value='height',tolerance=.2,message='Retain the authored physical height.')]
 if not body_only:
  checks.extend([dict(id='material-not-filled',outputID=output,metric='volume',relation='<',value='wall*height*bellyRadius*8',message='Reject a filled body or grossly excessive material volume.'),dict(id='material-not-vanishing',outputID=output,metric='volume',relation='>',value='wall*height*bellyRadius*3',message='Reject a vanishing or grossly undersized material wall.')])
 return dict(id='0c6fde30-700c-5094-bc75-15a17bc5ecdc',version=2,revision=11,name='Organic analytic source study'+(' / body only' if body_only else ' / normal shell'),parameters=[dict(name=n,value=v,minimum=lo,maximum=hi,unit=u) for n,v,lo,hi,u in params],features=features,outputs=[output],requirements=requirements,outputRequirements=checks,assumptions=['Experimental source-only candidate against the frozen AI design reference.','Axial radius/offset laws have matched C2 joins for every declared parameter value.','Every section uses periodic C2 cubic Bezier correspondence.',f'{flutes} physical longitudinal flutes; radial depth fades toward the neck.',f'Axial law: peak={PEAK}; neck={NECK}; base_lobes={BASE_LOBES}.',f'Angular section: secondary={ANGULAR_SECONDARY}; phase={ANGULAR_PHASE}.','BODY ONLY: silhouette study, not a hollow or physically accepted vessel.' if body_only else 'Wall is a true inward normal shell, not radial inner-loft subtraction.'],unresolvedMeasurements=['Visual acceptance and the declared parameter envelope require actual native evaluation.'])

if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--output',type=Path,default=Path(__file__).with_name('model.json'))
 p.add_argument('--segments',type=int,default=192)
 p.add_argument('--flutes',type=int,default=48)
 p.add_argument('--flute-depth',type=float,default=.25)
 g=p.add_mutually_exclusive_group()
 g.add_argument('--body-only',action='store_true')
 g.add_argument('--shell',action='store_false',dest='body_only',help=argparse.SUPPRESS)
 p.set_defaults(body_only=False)
 p.add_argument('--belly-radius',type=float,default=73.0)
 p.add_argument('--belly-offset',type=float,default=-10.0)
 p.add_argument('--neck-offset',type=float,default=16.0)
 p.add_argument('--depth-ratio',type=float,default=1.015)
 p.add_argument('--lobes',type=float,default=.12)
 p.add_argument('--minimum-lobes',type=float,default=.10)
 p.add_argument('--neck-depth-offset',type=float,default=-17)
 p.add_argument('--stations',type=int,choices=[11,15,20],default=20)
 p.add_argument('--station-layout',choices=['balanced','neck-transition'],default='neck-transition')
 p.add_argument('--revision',type=int,default=11)
 p.add_argument('--model-id',type=uuid.UUID,default=uuid.UUID('0c6fde30-700c-5094-bc75-15a17bc5ecdc'))
 p.add_argument('--no-refine',action='store_true')
 p.add_argument('--digits',type=int,choices=[12,13],default=12)
 p.add_argument('--base-lobes',type=float,default=0.0)
 p.add_argument('--lobe-harmonic',type=float,default=-.18)
 p.add_argument('--phase',type=float,default=.055)
 a=p.parse_args()
 SIGNIFICANT_DIGITS=a.digits
 BASE_LOBES=a.base_lobes
 ANGULAR_SECONDARY=a.lobe_harmonic
 ANGULAR_PHASE=a.phase
 STATION_LAYOUT=a.station_layout
 m=model(a.segments,a.flutes,a.flute_depth,a.body_only,a.belly_offset,
         a.neck_offset,a.depth_ratio,a.lobes,a.neck_depth_offset,a.stations,
         not a.no_refine,a.belly_radius,a.minimum_lobes)
 m['revision']=a.revision
 if a.model_id:m['id']=str(a.model_id)
 data=json.dumps(m,indent=2)+'\n'
 a.output.parent.mkdir(parents=True,exist_ok=True)
 a.output.write_text(data)
 print(json.dumps(dict(path=str(a.output),
       canonical_bytes=len(json.dumps(m,separators=(',',':')).encode()),
       features=len(m['features']))))
