#!/usr/bin/env python3
"""Author original VARIOUS portfolio sources and real native Studio stills.

No application launch, external model API, stock photography or manufactured
product claim. --plan-only writes reproducible authoring data without an app.
The normal run requires an already-running ordinary LAB and its explicit
.local/validation library; every project mutation goes through public MCP.
"""
from __future__ import annotations
import argparse
import copy
import hashlib
import json
import math
from pathlib import Path
import struct
import time
import uuid

from verify_publication_workflows import PublicationProof, require
from render_paper_packaging import camera, geometry, rotated

ROOT=Path(__file__).resolve().parents[1]
EDITORIAL=ROOT/'examples/publications/various-quarterly/editorial.json'
NS=uuid.UUID('eae4166a-a009-46c2-ae80-5ed38fb43883')
INK='#191D1D'
FAMILIES={'fold_bureau':'fold','matter_study':'clay','signal_rooms':'print','common_current':'light','soft_registry':'textile','index_works':'metal'}
COLORS={'fold':'#E7DDC7','clay':'#BC775E','print':'#E64F34','light':'#9AA688','textile':'#244B73','metal':'#A7AEAC'}


# Editorial selection is an explicit art-direction decision, never an index
# modulo a list of unrelated subjects. Artist and cover identities stay direct.
CURATED_EDITORIAL_ALIASES={
 'frontmatter_01':'cover_inside_front', 'frontmatter_02':'cover_inside_front',
 'frontmatter_03':'signal_rooms_05', 'frontmatter_04':'signal_rooms_04',
 'various_front_01':'fold_bureau_05', 'various_front_02':'editorial_process_06',
 'various_front_03':'matter_study_08', 'various_front_04':'editorial_process_04',
 'various_front_05':'index_works_01', 'various_front_06':'index_works_05',
 'various_front_07':'editorial_process_13', 'various_front_08':'index_works_04',
 'various_front_09':'signal_rooms_02', 'various_front_10':'editorial_process_03',
 'various_front_11':'common_current_07', 'various_front_12':'index_works_02',
 'useful_gap_01':'useful_gap_01', 'useful_gap_02':'fold_bureau_01',
 'useful_gap_03':'matter_study_05', 'useful_gap_04':'signal_rooms_04',
 'useful_gap_05':'editorial_process_07', 'useful_gap_06':'matter_study_06',
 'useful_gap_07':'editorial_process_02', 'useful_gap_08':'index_works_05',
 'useful_gap_09':'editorial_process_01', 'useful_gap_10':'signal_rooms_05',
 'surfaces_time_01':'index_works_06', 'surfaces_time_02':'fold_bureau_06',
 'surfaces_time_03':'soft_registry_06', 'surfaces_time_04':'editorial_process_08',
 'surfaces_time_05':'index_works_08', 'surfaces_time_06':'fold_bureau_06',
 'surfaces_time_07':'soft_registry_07', 'surfaces_time_08':'matter_study_03',
 'surfaces_time_09':'index_works_05', 'surfaces_time_10':'common_current_08',
 'room_accident_01':'soft_registry_01', 'room_accident_02':'soft_registry_02',
 'room_accident_03':'signal_rooms_05', 'room_accident_04':'useful_gap_01',
 'room_accident_05':'soft_registry_04', 'room_accident_06':'signal_rooms_04',
 'room_accident_07':'soft_registry_05', 'room_accident_08':'cover_inside_back',
 'room_accident_09':'signal_rooms_08', 'room_accident_10':'soft_registry_01',
 'various_back_01':'index_works_05', 'various_back_02':'index_works_03',
 'various_back_03':'fold_bureau_01', 'various_back_04':'index_works_05',
 'various_back_05':'index_works_01', 'various_back_06':'index_works_07',
 'various_back_07':'index_works_06', 'various_back_08':'signal_rooms_05',
 'various_back_09':'common_current_08', 'various_back_10':'editorial_process_05',
 'various_back_11':'index_works_02', 'various_back_12':'matter_study_08',
}


def uid(key):return str(uuid.uuid5(NS,key)).upper()
def sha(value):return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':')).encode()).hexdigest()
def p2(x,y):return dict(x=x,y=y)
def p3(x=0,y=0,z=0):return dict(x=x,y=y,z=z)
def art(elements):return dict(background='#FFFFFF',backgroundOpacity=0,bleed=0,elements=elements,unit='mm',showGuides=False)

def shape(kind,key,x,y,w,h,color=INK,**extra):
    return dict(id=uid(key),name=key,kind=kind,x=x,y=y,width=w,height=h,color=color,text='',fontSize=12,**extra)
def rect(key,x,y,w,h,color=INK,**extra):return shape('rectangle',key,x,y,w,h,color,**extra)
def ellipse(key,x,y,w,h,color=INK,**extra):return shape('ellipse',key,x,y,w,h,color,**extra)

def label(key,value,x,y,w,h,size=12,color=INK):
    return dict(id=uid(key),name=key,kind='text',x=x,y=y,width=w,height=h,color=color,text=value,fontSize=size,
                typography=dict(fontName='HelveticaNeue-Bold',leading=size*1.16))

def path(key,points,color=INK,closed=True,fill=True,width=.45):
    return shape('path',key,0,0,100,100,color,fillEnabled=fill,
        stroke=None if fill else dict(color=color,width=width,cap='round',join='round'),
        path=dict(width=100,height=100,evenOdd=False,contours=[dict(closed=closed,nodes=[dict(id=uid(key+':'+str(i)),anchor=p2(x,y)) for i,(x,y) in enumerate(points)])]))

def line(key,a,b,width=.45,color=INK,dash=None):
    value=path(key,[a,b],color,False,False,width)
    if dash:value['stroke']['dash']=dash
    return value

def black_artwork(source):
    result=copy.deepcopy(source)
    for e in result['elements']:
        e['color']='#000000'
        if e.get('stroke'):e['stroke']['color']='#000000'
        e.pop('gradient',None);e.pop('fillSwatchID',None)
    return result


def monochrome_process(source,family):
    result=black_artwork(source)
    for e in result['elements']:
        if e['kind']!='text' and (family=='textile' or e['width']*e['height']>6000):
            e['fillEnabled']=False;e['stroke']=dict(color='#000000',width=.45,join='round')
    return result


def vector_detail(key,family,n,parent_number):
    result=graphic_work(key,family,parent_number)
    if n==6:
        for e in result['elements']:e['affine']=dict(a=1.8,b=0,c=0,d=1.8,tx=-35,ty=-24)
    elif n==7:
        if family=='textile':
            for e in result['elements']:e['affine']=dict(a=1.6,b=0,c=0,d=1.6,tx=-22,ty=-32)
        else:
            for i,e in enumerate(result['elements'][:2]):e['affine']=dict(a=.86,b=0,c=0,d=.86,tx=3+i*9,ty=12-i*9)
    else:
        if family=='textile':
            for e in result['elements']:e['affine']=dict(a=1.7,b=0,c=0,d=1.7,tx=-60,ty=-12)
        else:
            result['elements'].append(rect(key+'-margin',13,14,74,72,'#E64F34',fillEnabled=False,stroke=dict(color='#E64F34',width=.8,dash=[2,1])))
    return result


def process_diagram(key,family,variant=0):
    """Actual editable silhouettes, sections and registration paths, not charts."""
    e=[]
    if family=='fold':
        if variant%3==0:
            e=[path(key+'-blank',[(12,30),(38,30),(38,14),(68,14),(68,30),(88,30),(88,72),(68,72),(68,88),(38,88),(38,72),(12,72)],fill=False),
               line(key+'-crease-a',(38,30),(38,72),dash=[1.4,1.4]),line(key+'-crease-b',(68,30),(68,72),dash=[1.4,1.4]),
               line(key+'-crease-c',(38,30),(68,30),dash=[1.4,1.4]),line(key+'-crease-d',(38,72),(68,72),dash=[1.4,1.4])]
        elif variant%3==1:
            for i in range(3):e.append(path(key+str(i),[(14+i*9,65-i*13),(50,40-i*13),(84-i*6,58-i*13),(49,84-i*13)],fill=False,width=.65))
        else:e=[path(key+'-section',[(12,76),(12,25),(40,25),(40,58),(72,58),(72,25),(88,25)],closed=False,fill=False,width=1.2),line(key+'-reference',(12,86),(88,86),.3)]
    elif family=='clay':
        outer=[(50+34*math.cos(i*2*math.pi/72),50+41*math.sin(i*2*math.pi/72)) for i in range(72)]
        inner=[(50+20*math.cos(i*2*math.pi/72),50+27*math.sin(i*2*math.pi/72)) for i in range(72)]
        e=[path(key+'-wall',outer,fill=False,width=.7),path(key+'-void',inner,fill=False,width=.7)]
        if variant%2:
            e += [line(key+'-cut',(12,52),(88,52),.35,dash=[2,1.5]),path(key+'-profile',[(18,80),(24,23),(32,20),(30,76),(70,76),(68,20),(76,23),(82,80)],fill=False,width=.7)]
    elif family=='light':
        e=[path(key+'-base',[(25,84),(25,88),(72,88),(72,84)],fill=False),path(key+'-arm',[(34,84),(34,32),(39,22),(54,15),(70,19),(80,31)],INK,False,False,.9),
           path(key+'-shade',[(63,37),(83,37),(89,48),(57,48)],fill=False,width=.7)]
        for i in range(4):e.append(line(key+'-beam'+str(i),(62+i*7,55),(55+i*11,74),.3))
    elif family=='metal':
        for i in range(2):
            e.append(path(key+'-rail'+str(i),[(16+i*8,75-i*13),(16+i*8,30-i*13),(70+i*8,30-i*13),(70+i*8,75-i*13)],fill=False,width=.9))
        e.extend([ellipse(key+'-pin',68,34,4,4,fillEnabled=False,stroke=dict(color=INK,width=.5)),line(key+'-fold',(28,24),(28,82),.35,dash=[1,1.5])])
    elif family=='textile':
        for i in range(8):
            points=[(10+80*t/40,18+i*8+3*math.sin(t/40*math.pi*2+variant*.3+i*.45)) for t in range(41)]
            e.append(path(key+'-warp'+str(i),points,closed=False,fill=False,width=.8))
        for i in range(7):e.append(line(key+'-weft'+str(i),(18+i*10,12),(21+i*10,87),.45))
    else:
        e=[label(key+'-word','INTERVAL',8,12,90,25,24)]
        for i in range(4):
            e += [ellipse(key+'-dot'+str(i),12+i*20,52+(i%2)*8,7,7),line(key+'-axis'+str(i),(15+i*20,69),(15+i*20,86),.45)]
    e.append(label(key+'-id',family.upper()+' / '+f'{variant+1:02}',10,91,85,8,6))
    return black_artwork(art(e))


def graphic_work(key,family,n):
    e=[];red='#E9583C';blue='#235C8B';yellow='#D7B857';sage='#6A8D7B'
    if family=='print':
        if n==1:
            e=[rect(key+'-field',7,7,86,86,red)]
            for i,word in enumerate(('SLOW','DOWN','LOOK','AGAIN')):e.append(label(key+str(i),word,12,11+i*20,81,23,45,'#F7F0E0'))
        elif n==2:
            for i in range(7):
                a=i*.28;e.append(ellipse(key+str(i),10+i*10,20+math.sin(a*3)*20,21-i,21-i,blue if i%2 else red))
            e += [label(key+'-title','INTERVAL',8,66,89,22,34),label(key+'-note','AN ATLAS OF WAITING',9,90,85,8,6)]
        elif n==3:
            e=[path(key+'-a',[(8,17),(64,17),(64,39),(31,39),(31,87),(8,87)],blue),path(key+'-b',[(39,8),(91,8),(91,86),(70,86),(70,31),(39,31)],red),label(key+'-id','CUT / 03',40,62,32,20,16)]
        elif n==4:
            for i,(word,angle) in enumerate((('NOW',-8),('SOON',0),('LATER',8))):
                a=label(key+str(i),word,7,8+i*26,91,29,50,(red,INK,blue)[i]);a['rotation']=angle;e.append(a)
        else:
            e=[rect(key+'-plate',8,8,84,84,blue),label(key+'-type','OPEN',12,24,80,36,60,'#F4ECD9'),line(key+'-line',(15,72),(84,72),.8,'#F4ECD9'),label(key+'-foot','LEAVE ROOM FOR THE NEXT WORD',15,79,73,10,7,'#F4ECD9')]
    else:
        # Interlaced tapered ribbons with real interruptions at crossings. Each
        # ribbon/crossing is separately editable artwork, no baked fabric photo.
        for row in range(9):
            yy=11+row*9
            for col in range(9):
                xx=10+col*9;shift=(row%3-1)*(1.5 if n!=3 else 3)
                width=5+(1 if (row+col+n)%3==0 else 0)
                color=(blue,red,sage,yellow,INK)[(row//2+n)%5]
                if n==2 and (col+row)%5==0:continue
                if n==5 and col>6 and row%2:continue
                e.append(path(key+f'-warp-{row}-{col}',[(xx+shift,yy),(xx+shift+width,yy+1),(xx+shift+width-1,yy+7),(xx+shift,yy+8)],color))
                if (row+col+n)%2==0:
                    e.append(path(key+f'-weft-{row}-{col}',[(xx-1,yy+2),(xx+8,yy+2),(xx+8,yy+5),(xx-1,yy+5)],'#E1D7BD' if n%2 else sage))
        e.append(label(key+'-foot',('SHIFT WEAVE','OPEN REPEAT','LONG INTERVAL','CROSS REGISTER','LOOSE COUNT')[n-1],10,93,85,7,6))
    return art(e)


def construction(key,n):
    w,d=100,75
    panels=[('base',[(0,0),(w,0),(w,d),(0,d)],None,None)]
    wings=[]
    if n==1:wings=[('left',[(-68,0),(0,0),(0,d),(-68,d)],'base',((0,0),(0,d),1)),('right',[(w,0),(w+88,0),(w+88,d),(w,d)],'base',((w,0),(w,d),-1))]
    elif n==2:wings=[('back',[(0,d),(w,d),(w,d+85),(0,d+85)],'base',((0,d),(w,d),1)),('wing',[(w,0),(w+48,0),(w+48,d),(w,d)],'base',((w,0),(w,d),-1))]
    elif n==3:wings=[('roof-left',[(-85,0),(0,0),(0,d),(-85,d)],'base',((0,0),(0,d),.62)),('roof-right',[(w,0),(w+85,0),(w+85,d),(w,d)],'base',((w,0),(w,d),-.62))]
    elif n==4:
        for i in range(3):
            a=w+i*46;wings.append(('fan'+str(i),[(a,0),(a+46,0),(a+46,d),(a,d)],'base' if i==0 else 'fan'+str(i-1),((a,0),(a,d),(1 if i%2==0 else -1)*.72)))
    else:
        panels[0]=('base',[(0,0),(100,0),(100,32),(45,32),(45,100),(0,100)],None,None)
        wings=[('wall',[(-65,0),(0,0),(0,100),(-65,100)],'base',((0,0),(0,100),1)),('return',[(0,100),(45,100),(45,165),(0,165)],'base',((0,100),(45,100),-.84))]
    panels+=wings
    minx=min(p[0] for _,ring,_,_ in panels for p in ring);miny=min(p[1] for _,ring,_,_ in panels for p in ring)
    maxx=max(p[0] for _,ring,_,_ in panels for p in ring);maxy=max(p[1] for _,ring,_,_ in panels for p in ring)
    point=lambda p:p2(f'{p[0]-minx}*scale',f'{p[1]-miny}*scale')
    return dict(version=1,name=key,parameters=[dict(name='scale',value=1,minimum=.65,maximum=1.5,unit='×'),dict(name='foldAngle',value=90,minimum=30,maximum=120,unit='°')],
        size=p2(f'{maxx-minx}*scale',f'{maxy-miny}*scale'),stockThickness='1.2*scale',
        panels=[dict(id=name,name=name,role='body' if name=='base' else 'side',polygon=[point(p) for p in ring]) for name,ring,_,_ in panels],
        hinges=[dict(id=name+'-crease',parentPanelID=parent,childPanelID=name,start=point(hinge[0]),end=point(hinge[1]),angleDegrees=f'{hinge[2]}*foldAngle') for name,_,parent,hinge in wings],joins=[],rootPanelID='base')


def cad_definition(key,n):
    features=[]
    def add(name,kind,inputs=(),values=None,**extra):
        identifier=uid(key+'/'+name);features.append(dict(id=identifier,name=name,operation=dict(kind=kind,inputs=list(inputs),values=values or {},**extra)));return identifier
    def plane(kind='xy',x=0,y=0,z=0):
        return dict(origin=p3(x,y,z),u=p3(1,0,0),v=p3(0,1,0) if kind=='xy' else p3(0,0,-1))
    def ellipse_profile(name,cx,cy,rx,ry,kind='xy',origin=None):
        k=.5522847498307936;points=[(cx+rx,cy),(cx,cy+ry),(cx-rx,cy),(cx,cy-ry)]
        controls=[((cx+rx,cy+k*ry),(cx+k*rx,cy+ry)),((cx-k*rx,cy+ry),(cx-rx,cy+k*ry)),((cx-rx,cy-k*ry),(cx-k*rx,cy-ry)),((cx+k*rx,cy-ry),(cx+rx,cy-k*ry))]
        curves=[dict(kind='cubicBezier',start=p2(*points[i]),control1=p2(*controls[i][0]),control2=p2(*controls[i][1]),end=p2(*points[(i+1)%4])) for i in range(4)]
        p=plane(kind);p['origin']=origin or p['origin']
        return add(name,'curveProfile',curves=curves,plane=p)
    def extrude(name,profile,distance,direction):return add(name,'extrude',[profile],dict(distance=distance),direction=p3(*direction))
    def ring(name,cx,cy,rx,ry,ix,iy,depth=25):
        outer=ellipse_profile(name+' outer',cx,cy,rx,ry);body=extrude(name+' body',outer,depth,(0,0,1))
        inner=ellipse_profile(name+' opening',cx,cy,ix,iy,origin=p3(0,0,-1));hole=extrude(name+' tool',inner,depth+2,(0,0,1))
        return add(name+' void','subtract',[body,hole])
    if n==1:output=ring('Window',0,65,45,63,26,42,30)
    elif n==2:
        outer=ellipse_profile('Double body',0,0,72,43,'xz');body=extrude('Ceramic wall',outer,83,(0,1,0))
        for i,x in enumerate((-29,29)):
            inner=ellipse_profile('Mouth '+str(i),x,0,23,25,'xz',p3(0,6,0));tool=extrude('Mouth tool '+str(i),inner,80,(0,1,0));body=add('Open mouth '+str(i),'subtract',[body,tool])
        output=body
    elif n==3:
        curves=[dict(kind='cubicBezier',start=p2(39,0),control1=p2(53,5),control2=p2(61,22),end=p2(64,41)),
            dict(kind='line',start=p2(64,41),end=p2(59,41)),dict(kind='cubicBezier',start=p2(59,41),control1=p2(57,24),control2=p2(48,9),end=p2(36,6)),
            dict(kind='line',start=p2(36,6),end=p2(0,6)),dict(kind='line',start=p2(0,6),end=p2(0,0)),dict(kind='line',start=p2(0,0),end=p2(39,0))]
        profile=add('Bowl wall section','curveProfile',curves=curves,plane=plane());output=add('Revolved low aperture','revolve',[profile])
    elif n==4:
        output=ring('Handle field',0,57,65,55,25,32,24)
        for i,x in enumerate((-43,43)):
            hole=ellipse_profile('Finger aperture '+str(i),x,57,8,12,origin=p3(0,0,-1));tool=extrude('Finger tool '+str(i),hole,26,(0,0,1));output=add('Finger space '+str(i),'subtract',[output,tool])
    else:
        outer=ellipse_profile('Offset cup',-10,0,34,34,'xz');body=extrude('Cup body',outer,78,(0,1,0))
        inner=ellipse_profile('Offset cavity',-14,0,27,27,'xz',p3(0,6,0));tool=extrude('Cup cavity tool',inner,80,(0,1,0));cup=add('Open cup','subtract',[body,tool])
        handle=ring('Handle',42,42,24,24,16,16,12);output=add('Joined cup handle','union',[cup,handle])
    def scaled_point(value):return {axis:f'{number}*scale' for axis,number in value.items()}
    for feature in features:
        op=feature['operation'];op['values']={name:f'{value}*scale' for name,value in op['values'].items()}
        if op.get('plane'):op['plane']['origin']=scaled_point(op['plane']['origin'])
        for curve in op.get('curves',[]):
            for field in ('start','end','control1','control2'):
                if field in curve:curve[field]=scaled_point(curve[field])
    return dict(id=uid(key+'/cad'),version=1,revision=0,name=key,parameters=[dict(name='scale',value=1,minimum=.65,maximum=1.5,unit='×')],features=features,outputs=[output],
        assumptions=['Original fictional studio design. Physical dimensions are authored millimeters.'],unresolvedMeasurements=['Digital appearance only; material and manufacturing samples not measured.'])


def part(kind,**values):return dict(kind=kind,values={k:str(v)+'*scale' if k not in ('rotationX','rotationY','rotationZ') else str(v) for k,v in values.items()})
def recipe_definition(key,family,n):
    parts=[]
    if family=='metal':
        if n==1:parts=[part('box',width=120,height=5,depth=32,x=0,y=2.5,z=0,corner=1.5),part('box',width=80,height=5,depth=24,x=20,y=17,z=0,corner=1.2),part('box',width=5,height=18,depth=24,x=-17.5,y=10,z=0,corner=.6)]
        elif n==2:
            parts=[part('box',width=8,height=82,depth=12,x=-42,y=45,z=0,corner=1.2),part('box',width=8,height=55,depth=12,x=42,y=31.5,z=0,corner=1.2),part('box',width=92,height=8,depth=12,x=0,y=8,z=0,corner=1.2),part('box',width=64,height=8,depth=12,x=-10,y=82,z=0,corner=1.2)]
        elif n==3:parts=[part('box',width=110,height=5,depth=48,x=0,y=2.5,z=0,corner=2),part('box',width=6,height=55,depth=36,x=-42,y=30,z=0,corner=1),part('box',width=6,height=55,depth=36,x=42,y=30,z=0,corner=1),part('box',width=90,height=5,depth=36,x=0,y=57,z=0,corner=1)]
        elif n==4:parts=[part('box',width=72,height=25,depth=48,x=0,y=12.5,z=0,corner=5),part('box',width=80,height=3,depth=35,x=5,y=35,z=0,rotationZ=-18,corner=1),part('cylinder',radius=4,height=8,x=24,y=28,z=0)]
        else:parts=[part('box',width=110,height=5,depth=38,x=0,y=2.5,z=0,corner=1),part('box',width=32,height=5,depth=38,x=42,y=19,z=0,rotationZ=70,corner=1),part('cylinder',radius=6,height=40,x=42,y=5,z=0,rotationX=90)]
    elif n==1:
        return dict(id='various_'+key,name=key,symbol='lamp.desk',summary='Original analytic arc and sampled support assembly.',parameters=[dict(id='scale',name='Scale',value=1,minimum=.65,maximum=1.5,step=.05,unit='×')],parts=[],solid=dict(spacing='1.25',nodes=[
            dict(kind='ellipsoid',values={k:str(v)+'*scale' for k,v in dict(x=-55,y=4,z=0,radiusX=33,radiusY=4,radiusZ=25).items()}),
            dict(kind='segment',values={k:str(v)+'*scale' for k,v in dict(x=-55,y=6,z=0,endX=-55,endY=40,endZ=0,radius=3,endRadius=3).items()}),
            dict(kind='sweep',sweep=dict(samples='96',variable='u',sides=32,values=dict(x='-55*cos(pi*u)*scale',y='(40+65*sin(pi*u))*scale',z='0',radiusX='3*scale',radiusY='3*scale',roll='0'))),
            dict(kind='ellipsoid',values={k:str(v)+'*scale' for k,v in dict(x=55,y=40,z=0,radiusX=30,radiusY=3,radiusZ=23).items()})]))
    elif n==2:parts=[part('cylinder',radius=30,height=5,x=0,y=2.5,z=0),part('cylinder',radius=3,height=118,x=0,y=64,z=0),part('box',width=75,height=5,depth=50,x=-15,y=123,z=0,rotationZ=-8,corner=3),part('box',width=63,height=5,depth=46,x=18,y=141,z=0,rotationZ=8,corner=3)]
    elif n==3:parts=[part('cylinder',radius=24,height=42,x=-38,y=21,z=0),part('box',width=7,height=118,depth=7,x=-38,y=82,z=0,rotationZ=-15,corner=2),part('box',width=110,height=6,depth=7,x=9,y=140,z=0,rotationZ=12,corner=2),part('cone',bottomRadius=35,topRadius=8,height=27,x=58,y=127,z=0)]
    elif n==4:parts=[part('box',width=65,height=6,depth=45,x=0,y=3,z=0,corner=4),part('box',width=6,height=120,depth=6,x=-18,y=65,z=0,rotationZ=-10,corner=1),part('box',width=75,height=5,depth=6,x=15,y=126,z=0,rotationZ=-15,corner=1),part('torus',ringRadius=30,pipeRadius=3,x=50,y=115,z=0,rotationZ=-15),part('sphere',radius=12,x=50,y=111,z=0)]
    else:parts=[part('box',width=65,height=6,depth=50,x=0,y=3,z=0,corner=3),part('box',width=6,height=125,depth=6,x=-18,y=66,z=0,corner=1),part('box',width=90,height=3,depth=70,x=17,y=128,z=0,rotationZ=-22,corner=1),part('box',width=70,height=3,depth=70,x=67,y=115,z=0,rotationZ=25,corner=1)]
    return dict(id='various_'+key,name=key,symbol='cube',summary='Original project-authored physical assembly study.',parameters=[dict(id='scale',name='Scale',value=1,minimum=.65,maximum=1.5,step=.05,unit='×')],parts=parts)


def part_bounds(recipe):
    points=[]
    def rotated(p,angles):
        x,y,z=p
        for axis,a in enumerate(angles):
            c,s=math.cos(math.radians(a)),math.sin(math.radians(a))
            if axis==0:y,z=c*y-s*z,s*y+c*z
            elif axis==1:x,z=c*x+s*z,-s*x+c*z
            else:x,y=c*x-s*y,s*x+c*y
        return x,y,z
    for part in recipe['parts']:
        values={k:float(v.replace('*scale','')) for k,v in part['values'].items()}
        kind=part['kind']
        if kind=='box':extents=[values['width']/2,values['height']/2,values['depth']/2]
        elif kind in ('cylinder','cone'):extents=[values.get('radius',max(values.get('topRadius',0),values.get('bottomRadius',0))),values['height']/2,values.get('radius',max(values.get('topRadius',0),values.get('bottomRadius',0)))]
        elif kind=='sphere':extents=[values['radius']]*3
        else:extents=[values['ringRadius']+values['pipeRadius'],values['pipeRadius'],values['ringRadius']+values['pipeRadius']]
        angles=[values.get('rotation'+a,0) for a in 'XYZ'];center=[values.get(a,0) for a in 'xyz']
        for x in (-extents[0],extents[0]):
            for y in (-extents[1],extents[1]):
                for z in (-extents[2],extents[2]):
                    p=rotated((x,y,z),angles);points.append([p[i]+center[i] for i in range(3)])
    return points


def cover_artwork(key,index):
    e=[]
    if index==0:
        e=[path(key+'-fold',[(8,68),(38,40),(62,61),(91,31),(91,71),(62,91),(38,72),(8,92)],fill=False,width=1.4),
           ellipse(key+'-circle',11,8,27,27,fillEnabled=False,stroke=dict(color=INK,width=1.1)),path(key+'-arch',[(50+29*math.cos(i*math.pi/40),37-24*math.sin(i*math.pi/40)) for i in range(41)],closed=False,fill=False,width=2)]
    elif index==1:
        for index,family in enumerate(('fold','clay','print','light','textile','metal')):
            row,col=divmod(index,2)
            base=process_diagram(key+family,family,0)
            for original in base['elements'][:-1]:
                x=copy.deepcopy(original);x['affine']=dict(a=.43,b=0,c=0,d=.27,tx=5+col*47,ty=4+row*31);e.append(x)
    elif index==2:
        for i in range(6):
            a=i*math.pi/3;center=(50+30*math.cos(a),50+30*math.sin(a))
            e.append(ellipse(key+'-anchor'+str(i),center[0]-3,center[1]-3,6,6))
            e.append(line(key+'-spoke'+str(i),center,(50,50),.5))
        e.append(ellipse(key+'-center',39,39,22,22,fillEnabled=False,stroke=dict(color=INK,width=1)))
    else:
        e=[path(key+'-return',[(15,84),(15,22),(78,22),(78,71),(44,71),(44,49),(61,49)],closed=False,fill=False,width=2),
           ellipse(key+'-point',75,8,7,7),line(key+'-datum',(15,92),(87,92),.45)]
    return black_artwork(art(e))


def author_plan(editorial):
    originals={}
    for family_key,family in FAMILIES.items():
        for n in range(1,6):
            key=f'{family_key}_{n:02}'
            if family in ('print','textile'):
                source=graphic_work(key,family,n);kind='vector';method='editable_artwork'
            elif family=='fold':source=construction(key,n);kind='raster';method='construction'
            elif family=='clay':source=cad_definition(key,n);kind='raster';method='cad'
            else:source=recipe_definition(key,family,n);kind='raster';method='recipe'
            originals[key]=dict(key=key,family=family,kind=kind,method=method,source_definition=source,
                black_only_artwork=monochrome_process(source,family) if kind=='vector' else process_diagram(key+'-process',family,n-1),width_mm=100,height_mm=100)
        for n,parent in zip((6,7,8),(1,3,5)):
            key=f'{family_key}_{n:02}';source=f'{family_key}_{parent:02}'
            if family in ('print','textile'):
                detail=vector_detail(key,family,n,parent)
                originals[key]=dict(key=key,family=family,kind='vector',method='editable_artwork',source_work=source,source_definition=detail,
                    black_only_artwork=monochrome_process(detail,family),width_mm=100,height_mm=100)
            else:
                originals[key]=dict(key=key,family=family,kind='raster',method='detail',source_work=source,source_definition=None,
                    black_only_artwork=process_diagram(key+'-process',family,n-4),width_mm=100,height_mm=100)
    diagram_keys=[]
    for s in editorial['sections']:
        if not s.get('family_key'):
            diagram_keys += [w['key'] for w in s['works']]
    family_order=('fold','clay','print','light','textile','metal')
    for i in range(17):
        key='editorial_process_'+f'{i+1:02}';family=family_order[i%6]
        source=process_diagram(key,family,i//6)
        originals[key]=dict(key=key,family=family,kind='vector',method='editable_artwork',source_definition=source,
            black_only_artwork=source,width_mm=100,height_mm=100)
    originals['useful_gap_01']=dict(key='useful_gap_01',family='fold',kind='raster',method='hero',source_work='fold_bureau_03',source_definition=None,
        black_only_artwork=process_diagram('hero-fold-plan','fold',1),width_mm=100,height_mm=100)
    for i,cover in enumerate(editorial['covers']):
        key=cover['visual_key'];source=cover_artwork(key,i)
        originals[key]=dict(key=key,family='print',kind='vector',method='editable_artwork',source_definition=source,
            black_only_artwork=source,width_mm=100,height_mm=100)
    aliases={key:key for key in originals if not key.startswith('editorial_process_')}
    aliases.update(CURATED_EDITORIAL_ALIASES)
    required=[w['key'] for s in editorial['sections'] for w in s['works']]+[c['visual_key'] for c in editorial['covers']]
    require(len(required)==110 and set(required)<=set(aliases),'Every editorial slot must map directly to a reproducible original.')
    require(len(originals)==70,'The portfolio plan retains70 distinct original render/vector assets.')
    return dict(version=1,originals=originals,aliases={k:aliases[k] for k in required},editorial_sha256=sha(editorial))


class VisualAssetAuthor(PublicationProof):
    def __init__(self,args,plan):
        output=args.output.resolve()
        require(not output.exists() or (output.is_dir() and not any(output.iterdir())),
                'Choose a fresh empty portfolio output folder; retain prior failed evidence.')
        self.plan=plan;super().__init__(args)
        self.manifest=dict(version=1,state='authoring',assets={},originals={},editorial_sha256=plan['editorial_sha256'],
            app=self.report['app'],app_sha256=self.report['app_sha256'],project_id=None,
            provenance='Original fictional studio portfolio. Generic project-authored sources and actual native Studio renders; no stock photographs, external model calls or manufactured-object attribution.')
        self.materials=[];self.sources={};self.flush()
    def save(self):
        (self.output/'visual-authoring-report.json').write_text(json.dumps(self.report,indent=2)+'\n')
    def flush(self):
        (self.output/'visual-assets.in-progress.json').write_text(json.dumps(self.manifest,indent=2)+'\n')
    def material(self,family):
        keywords={'fold':('paper','uncoated'),'clay':('clay','ceramic'),'light':('sage','powder'),'metal':('aluminum','metal','graphite')}.get(family,('paper',))
        ranked=sorted(self.materials,key=lambda m:sum((len(keywords)-i)*10 for i,k in enumerate(keywords) if k in (m.get('name','')+' '+m.get('category','')+' '+m.get('id','')).lower()),reverse=True)
        require(bool(ranked),'Native Studio material library must not be empty.')
        return ranked[0]['id']
    def wait_cad(self,job,state='ready'):
        deadline=time.monotonic()+180
        while job['state'] not in (state,'failed','cancelled'):
            require(time.monotonic()<deadline,'Exact CAD source evaluation timed out; no placeholder is substituted.')
            time.sleep(.15);job=self.call('form_cad',command='status',job_id=job['job_id'])
        require(job['state']==state,'Exact CAD source evaluation failed: '+json.dumps(job))
        return job
    def add_source(self,row):
        key,family,definition=row['key'],row['family'],row['source_definition']
        if row['method']=='construction':
            identifier=self.call('form_construction',command='create',definition=definition,name=key)['object_id']
            self.call('form_set_artwork',object_id=identifier,artwork=art([]))
            self.call('form_paper',command='configure',object_id=identifier,stock=dict(name='Warm uncoated sculptural sheet',thicknessMM=1.2,
                profile=dict(texture='cotton',color=COLORS[family],roughness=.94,textureScaleMM=.6,textureDepthMM=.009,opacity=1)))
            inspection=self.call('form_construction',command='inspect',object_id=identifier)
            obj=self.object(identifier);points,matrices=geometry(inspection,obj)
            hinge=definition['hinges'][0];m=matrices[hinge['parentPanelID']]
            hx,hy=(float(hinge['start'][axis].split('*')[0]) for axis in ('x','y'))
            focus=[m[r*4]*hx-m[r*4+1]*hy+m[r*4+3] for r in range(3)]
        elif row['method']=='cad':
            job=self.wait_cad(self.call('form_cad',command='create',definition=definition,quality='inspection'))
            committed=self.wait_cad(self.call('form_cad',command='commit',job_id=job['job_id']),'committed')
            identifier=committed['result']['object_id'];obj=self.object(identifier)
            components=obj.get('cadRepresentation',{}).get('components',[])
            require(bool(components),'Committed exact CAD must retain actual component bounds.')
            points=[[c[k]['x'],c[l]['y'],c[m]['z']] for c in components for k in ('minimum','maximum') for l in ('minimum','maximum') for m in ('minimum','maximum')]
            self.call('form_update_object',object_id=identifier,material_id=self.material(family),color=COLORS[family])
            focus=[(min(p[0] for p in points)+max(p[0] for p in points))/2,max(p[1] for p in points)-3,(min(p[2] for p in points)+max(p[2] for p in points))/2]
        else:
            self.call('form_create_recipe',recipe=definition)
            obj=self.call('form_add_object',recipe_id=definition['id'],name=key,material_id=self.material(family),color=COLORS[family])
            identifier=obj.get('id') or obj.get('object_id')
            if definition.get('solid'):
                inspection=self.call('form_solid',command='inspect',object_id=identifier)
                lo,hi=inspection['minimum_mm'],inspection['maximum_mm']
                points=[[x,y,z] for x in (lo[0],hi[0]) for y in (lo[1],hi[1]) for z in (lo[2],hi[2])]
            else:points=part_bounds(definition)
            focus=points[7] if family=='metal' else [(min(p[0] for p in points)+max(p[0] for p in points))/2,max(p[1] for p in points)-3,0]
        rise=-min(p[1] for p in points)
        self.call('form_update_object',object_id=identifier,position=[0,rise,0])
        points=[[p[0],p[1]+rise,p[2]] for p in points]
        stored=self.object(identifier)
        return dict(object_id=identifier,points=points,feature_point=[focus[0],focus[1]+rise,focus[2]],source_definition=definition,stored_object=stored)
    def vector(self,row):
        artwork=row['source_definition'];key=row['key']
        obj=self.call('form_add_object',recipe_id='artboard',name=key+' / editable graphic',parameters=dict(width=100,depth=100))
        identifier=obj.get('id') or obj.get('object_id');self.call('form_set_artwork',object_id=identifier,artwork=artwork)
        return dict(kind='vector',artwork=artwork,source_object_id=identifier,source_definition=artwork,sha256=sha(artwork))
    def render(self,row,source):
        key=row['key'];points=source['points'];outward=(.65,.42,1)
        size=(2000,1600)
        if row['method']=='hero':size=(4800,1600);outward=(.2,.52,1)
        elif row['method']=='detail':
            n=int(key[-2:]);outward={6:(.55,.38,1),7:(1,.18,.2),8:(.1,.55,1)}[n]
            if n==6:
                radius=18 if row['family']!='light' else 24
                center=source['feature_point']
                points=[[center[0]+x,center[1]+y,center[2]+z] for x in (-radius,radius) for y in (-radius,radius) for z in (-radius,radius)]
        if row['method']=='detail' and key.endswith('_08'):
            copies=[source]*3;angles=(-28,20,90)
            if row['family']=='fold':
                flat=copy.deepcopy(source['source_definition'])
                flat['name']=key+' / actual flat parameter variant'
                for parameter in flat['parameters']:
                    if parameter['name']=='foldAngle':parameter.update(value=0,minimum=0)
                alternative=self.add_source(dict(key=key+'_flat',family='fold',method='construction',source_definition=flat))
                copies=[alternative,source];angles=(0,0)
            span=max(max(p[0] for p in item['points'])-min(p[0] for p in item['points']) for item in copies)*1.35
            instances=[];points=[]
            for i,(item,angle) in enumerate(zip(copies,angles)):
                offset=(i-(len(copies)-1)/2)*span;position=copy.deepcopy(item['stored_object']['position']);position['x']+=offset
                instances.append(dict(id=uid(key+'/instance/'+str(i)),name=key+' / '+str(i+1),sourceObjectID=item['object_id'],positionMM=position,rotationDegrees=angle,visible=True))
                for point in item['points']:
                    local=[point[j]-item['stored_object']['position'][axis] for j,axis in enumerate(('x','y','z'))]
                    p=rotated(local,angle);points.append([p[j]+position[axis] for j,axis in enumerate(('x','y','z'))])
            state=camera(points,outward,margin=1.12,aspect=1.8)
            scene=self.call('form_studio_scene',command='create',name=key)
            scene.update(instances=instances,camera=state,pixels=dict(width=2400,height=1333),lighting='soft-side-v1',surface='Daylight')
            saved=self.call('form_studio_scene',command='save',scene=scene)
            destination=self.output/'renders'/(key+'.render');destination.parent.mkdir(parents=True,exist_ok=True)
            try:result=self.call('form_export',format='png',scene_id=saved['id'],path=str(destination))
            finally:self.call('form_studio_scene',command='delete',scene_id=saved['id'])
            path=Path(result['path']);data=path.read_bytes()
            require(data[:8]==b'\x89PNG\r\n\x1a\n' and struct.unpack('>II',data[16:24])==(2400,1333),'Native multi-view plate pixels must match its scene.')
            return dict(kind='raster',path=str(path.resolve()),width_px=2400,height_px=1333,source_object_id=source['object_id'],source_definition=source['source_definition'],
                source_instances=instances,source_variants=[item['source_definition'] for item in copies],camera=state,sha256=hashlib.sha256(data).hexdigest(),render_result=result)
        state=camera(points,outward,margin=1.12,aspect=size[0]/size[1])
        shot=self.call('form_set_view',view='studio',studio_command='capture',name=key,camera=state,
            reference_aspect=size[0]/size[1],visibility=dict(mode='objects',objectIDs=[source['object_id']]),
            width=size[0],height=size[1],lighting='soft-side-v1',surface='Daylight')
        destination=self.output/'renders'/(key+'.render');destination.parent.mkdir(parents=True,exist_ok=True)
        try:result=self.call('form_export',format='png',shot_id=shot['id'],path=str(destination))
        finally:self.call('form_set_view',view='studio',studio_command='delete',shot_id=shot['id'])
        path=Path(result['path']);data=path.read_bytes();dimensions=struct.unpack('>II',data[16:24])
        require(data[:8]==b'\x89PNG\r\n\x1a\n' and dimensions==size,'Native still must retain exact requested output pixels.')
        return dict(kind='raster',path=str(path.resolve()),width_px=size[0],height_px=size[1],source_object_id=source['object_id'],
            source_definition=source['source_definition'],stored_object=source['stored_object'],camera=state,
            sha256=hashlib.sha256(data).hexdigest(),render_result=result)
    def run(self):
        self.call('form_create_project',name='VARIOUS / original portfolio sources',template='blank')
        self.manifest['project_id']=self.project()['id'];self.report['project_id']=self.manifest['project_id']
        self.materials=self.call('form_list_materials')
        (self.output/'authoring-plan.json').write_text(json.dumps(self.plan,indent=2)+'\n')
        for key,row in self.plan['originals'].items():
            if row['kind']=='vector':entry=self.vector(row)
            else:
                parent=row.get('source_work')
                if parent:source=self.sources[parent]
                else:source=self.add_source(row);self.sources[key]=source
                entry=self.render(row,source)
            entry.update(key=key,family=row['family'],width_mm=100,height_mm=100,black_only_artwork=row['black_only_artwork'],
                source_work=row.get('source_work'),source_project_id=self.manifest['project_id'],
                provenance='Original LAB-authored fictional studio study; '+('actual native Studio still' if entry['kind']=='raster' else 'editable original vector artwork')+'.')
            self.manifest['originals'][key]=entry;self.flush()
        for key,original in self.plan['aliases'].items():
            value=copy.deepcopy(self.manifest['originals'][original]);value['key']=key
            if key!=original:value['reuse_of']=original
            self.manifest['assets'][key]=value
        require(len(self.manifest['assets'])==110 and len(self.manifest['originals'])==70,'All intended publication assets must exist before publishing the manifest.')
        self.manifest.update(state='complete',original_count=70,placement_count=110,
            actual_native_stills=sum(a['kind']=='raster' for a in self.manifest['originals'].values()),visual_acceptance='Requires inspection of actual source/still contact sheets and final magazine pages.')
        final=self.output/'visual-assets.json';final.write_text(json.dumps(self.manifest,indent=2)+'\n')
        self.report.update(passed=True,manifest=str(final),sources=self.sources);self.save()
        print(json.dumps(dict(project_id=self.manifest['project_id'],manifest=str(final),originals=70,placements=110),indent=2))



def revise_manifest(source_path,output):
    source_path=Path(source_path).resolve();output=Path(output).resolve();output.mkdir(parents=True,exist_ok=True)
    prior=json.loads(source_path.read_text());require(prior.get('state')=='complete','Revise a completed native manifest only.')
    revised=copy.deepcopy(prior);patches={}
    def digest(value):return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()).hexdigest()
    editorial=json.loads(EDITORIAL.read_text())
    captions={work['key']:work for section in editorial['sections'] for work in section['works']}
    mappings={key:key for key in prior['assets']};mappings.update(CURATED_EDITORIAL_ALIASES)
    for key,original_key in mappings.items():
        require(original_key in prior['originals'],'Select an existing captured/drawn original: '+original_key)
        original=prior['originals'][original_key]
        if original['kind']=='raster':
            data=Path(original['path']).read_bytes()
            require(hashlib.sha256(data).hexdigest()==original['sha256'],'Do not change existing native PNG bytes.')
        entry=copy.deepcopy(original);entry['key']=key
        if key!=original_key:entry['reuse_of']=original_key
        else:entry.pop('reuse_of',None)
        previous=prior['assets'][key]
        previous_key=previous.get('reuse_of',key)
        if previous_key!=original_key:
            work=captions.get(key,{})
            reason='Choose '+original_key+' for '+work.get('title',key)+': '+work.get('caption','')
            patches[key]=dict(prior_entry_sha256=digest(previous),original_asset_key=original_key,entry=entry,reason=reason)
            revised['assets'][key]=entry
    require(len(revised['assets'])==110,'Keep every visual placement and all editorial words/counts.')
    require(revised['originals']==prior['originals'],'A semantic selection revision never edits original definitions or captured PNGs.')
    used={value.get('reuse_of',key) for key,value in revised['assets'].items()}
    require(60<=len(used)<=72,'Retain the intended number of distinct original sources in the printed issue.')
    final=output/'visual-assets-semantic-v2.json';patch=output/'semantic-alias-patch-v2.json'
    require(not final.exists() and not patch.exists(),'Retain prior evidence; use a fresh revision output folder.')
    revised.update(semantic_revision=2,revises_manifest_sha256=hashlib.sha256(source_path.read_bytes()).hexdigest(),
        semantic_selection='Every artist/cover identity stays direct; editorial selections are explicitly tied to caption subjects.',
        used_original_count=len(used))
    final.write_text(json.dumps(revised,indent=2)+'\n')
    result=dict(version=1,source_manifest_path=str(source_path),source_manifest_sha256=hashlib.sha256(source_path.read_bytes()).hexdigest(),
        revised_manifest_path=str(final),revised_manifest_sha256=hashlib.sha256(final.read_bytes()).hexdigest(),patches=patches,
        unchanged_artist_and_cover_placements=52,changed_placements=len(patches),used_original_count=len(used),
        remaining_editorial_review=['room_accident_04 reuses the actual earlier cross-gutter hero; its current slot itself is not a two-page placement.',
          'K-only3D-family alternatives remain schematic process drawings from the original bank, rather than literal CAD elevations.',
          'various_front_03 uses actual multiple orientations under the same native light setup; no different studio lighting rigs are claimed.'])
    patch.write_text(json.dumps(result,indent=2)+'\n')
    return dict(revised_manifest=str(final),patch=str(patch),changed_placements=len(patches),used_original_count=len(used))

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',type=Path);parser.add_argument('--socket');parser.add_argument('--library',type=Path)
    parser.add_argument('--output',type=Path,required=True);parser.add_argument('--plan-only',action='store_true');parser.add_argument('--revise-manifest',type=Path)
    args=parser.parse_args()
    if args.revise_manifest:
        print(json.dumps(revise_manifest(args.revise_manifest,args.output),indent=2));return
    editorial=json.loads(EDITORIAL.read_text());plan=author_plan(editorial)
    if args.plan_only:
        args.output.mkdir(parents=True,exist_ok=True);destination=args.output/'authoring-plan.json'
        require(not destination.exists(),'Choose a fresh plan output path.');destination.write_text(json.dumps(plan,indent=2)+'\n')
        print(json.dumps(dict(plan=str(destination),originals=len(plan['originals']),placements=len(plan['aliases']))));return
    require(args.app is not None and args.socket and args.library is not None,'A native run requires --app, --socket and --library.')
    author=VisualAssetAuthor(args,plan)
    try:author.run()
    except Exception as error:
        author.report.update(passed=False,error=str(error));author.save();raise


if __name__=='__main__':main()
