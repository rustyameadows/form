#!/usr/bin/env python3
"""Author ordinary CAD model data from the frozen independent design reference.

Only familiar cubic section curves, a smooth loft and an inward shell are used.
This script is example content; it is never imported or registered by the app.
"""
import argparse
import json
import math
from pathlib import Path
import re
import uuid

HERE=Path(__file__).resolve().parent
def identity(name):
    return str(uuid.uuid5(uuid.NAMESPACE_URL,"form-organic-reference-vase/"+name))


def model(flutes=32,flute_depth=.35,segments=192,style="rounded",curve_mode="periodic-c2",compact=True):
    parameters=[
        ("height",180,150,210,"mm"),("bellyRadius",64,54,72,"mm"),
        ("baseRadius",32,25,38,"mm"),("neckRadius",13,11,16,"mm"),
        ("neckOffset",16,8,24,"mm"),("shoulderHeight",120,108,135,"mm"),
        ("depthScale",1.05,.90,1.16,"ratio"),("lobeAmount",.17,.10,.22,"ratio"),
        ("fluteDepth",flute_depth,0,.75,"mm"),("wall",3,2.2,3.5,"mm")]
    # Height, radius, lobe strength, flute strength, neck offset. The upper
    # sections settle into a narrow neck through one continuous loft.
    sections=[
        ("0","baseRadius",0,0,0),
        ("shoulderHeight*.04","baseRadius*.8+bellyRadius*.15",.10,.12,.01),
        ("shoulderHeight*.12","bellyRadius*.58",.45,.35,.03),
        ("shoulderHeight*.27","bellyRadius*.83",.80,.75,.06),
        ("shoulderHeight*.48","bellyRadius*1.03",1,1,.10),
        ("shoulderHeight*.68","bellyRadius*1.08",1,1,.14),
        ("shoulderHeight*.86","bellyRadius*.98",.95,.90,.22),
        ("shoulderHeight","bellyRadius*.77",.80,.60,.36),
        ("shoulderHeight+(height-shoulderHeight)*.25","bellyRadius*.49",.45,.20,.66),
        ("shoulderHeight+(height-shoulderHeight)*.50","neckRadius*1.04",.06,.025,.94),
        ("shoulderHeight+(height-shoulderHeight)*.65","neckRadius*.98",0,.008,1),
        ("shoulderHeight+(height-shoulderHeight)*.82","neckRadius*.98",0,0,1),
        ("height","neckRadius",0,0,1)]
    if style=="rounded":
        parameters=[(n,68 if n=="bellyRadius" else 26 if n=="neckOffset" else .18 if n=="lobeAmount" else v,
                     lo,78 if n=="bellyRadius" else 34 if n=="neckOffset" else hi,u)
                    for n,v,lo,hi,u in parameters]
        sections=[
            ("0","baseRadius",.12,0,0),
            ("shoulderHeight*.04","bellyRadius*.62",.36,.12,.01),
            ("shoulderHeight*.12","bellyRadius*.79",.66,.35,.03),
            ("shoulderHeight*.27","bellyRadius*.96",.88,.75,.06),
            ("shoulderHeight*.48","bellyRadius*1.05",1,1,.10),
            ("shoulderHeight*.68","bellyRadius*1.03",1,1,.14),
            ("shoulderHeight*.86","bellyRadius*.90",.93,.90,.22),
            ("shoulderHeight","bellyRadius*.68",.72,.60,.36),
            ("shoulderHeight+(height-shoulderHeight)*.25","bellyRadius*.39",.35,.20,.66),
            ("shoulderHeight+(height-shoulderHeight)*.50","neckRadius*1.04",.04,.025,.94),
            ("shoulderHeight+(height-shoulderHeight)*.65","neckRadius*.98",.002,.008,1),
            ("shoulderHeight+(height-shoulderHeight)*.82","neckRadius*.98",.002,0,1),
            ("height","neckRadius",.002,0,1)]
    features=[]
    step=2*math.pi/segments
    def coefficients(theta,lobes,fluting):
        c,s=math.cos(theta),math.sin(theta)
        if style=="rounded":
            modulation=1-.15*math.cos(theta)+.08*math.sin(theta)
            derivative=.15*math.sin(theta)+.08*math.cos(theta)
            wave=math.cos(3*theta)*modulation+.02*math.cos(theta)
            slope=-3*math.sin(3*theta)*modulation+math.cos(3*theta)*derivative-.02*math.sin(theta)
        else:
            wave=.75*math.cos(3*theta)+.30*math.cos(2*theta)-.15*math.cos(theta+.7)
            slope=-2.25*math.sin(3*theta)-.60*math.sin(2*theta)+.15*math.sin(theta+.7)
        rib=math.cos(flutes*theta);drib=-flutes*math.sin(flutes*theta)
        return ((c,lobes*wave*c,fluting*rib*c),
                (s,lobes*wave*s,fluting*rib*s),
                (-s,lobes*(slope*c-wave*s),fluting*(drib*c-rib*s)),
                (c,lobes*(slope*s+wave*c),fluting*(drib*s+rib*c)))
    def coordinate(radius,values,depth=False):
        a,b,c=values
        if compact:
            def number(value):
                if abs(value)<1e-14:return "0"
                text=f"{value:.14g}"
                text=text.replace("-0.","-.")
                return text[1:] if text.startswith("0.") else text
            match=re.fullmatch(r"([A-Za-z][A-Za-z0-9]*)(?:\*([0-9.]+))?",radius)
            if match:
                radius=match[1];factor=float(match[2] or 1);a*=factor;b*=factor
            else:
                radius="("+radius+")"
            value=radius+"*("+number(a)+("+" if b>=0 else "-")+"lobeAmount*"+number(abs(b))+")"
            if abs(c)>=1e-14:value+=("+" if c>=0 else "-")+"fluteDepth*"+number(abs(c))
        else:
            value=f"({radius})*({a:.15g}+lobeAmount*({b:.15g}))+fluteDepth*({c:.15g})"
        return "depthScale*("+value+")" if depth else value
    def point(radius,x,y):
        return dict(x=coordinate(radius,x),y=coordinate(radius,y,True))
    for index,(height,radius,lobes,fluting,offset) in enumerate(sections):
        curves=[]
        controls=[coefficients(i*step,lobes,fluting) for i in range(segments)]
        def blend(weights,axis):
            return [sum(weight*controls[i%segments][axis][k] for i,weight in weights) for k in range(3)]
        for edge in range(segments):
            if curve_mode=="periodic-c2":
                weights=[
                    [(edge-1,1/6),(edge,4/6),(edge+1,1/6)],
                    [(edge,4/6),(edge+1,2/6)],
                    [(edge,2/6),(edge+1,4/6)],
                    [(edge,1/6),(edge+1,4/6),(edge+2,1/6)]]
                points=[(blend(w,0),blend(w,1)) for w in weights]
                # Uniform cubic control filtering attenuates a sinusoid. Keep
                # the authored flute-depth control approximately physical.
                gain=1/(2/3+math.cos(flutes*step)/3)
                for x,y in points:x[2]*=gain;y[2]*=gain
                curves.append(dict(kind="cubicBezier",**{
                    key:point(radius,*p) for key,p in zip(["start","control1","control2","end"],points)}))
            else:
                a=controls[edge]
                b=controls[(edge+1)%segments]
                control1=([a[0][k]+step*a[2][k]/3 for k in range(3)],
                          [a[1][k]+step*a[3][k]/3 for k in range(3)])
                control2=([b[0][k]-step*b[2][k]/3 for k in range(3)],
                          [b[1][k]-step*b[3][k]/3 for k in range(3)])
                curves.append(dict(kind="cubicBezier",start=point(radius,a[0],a[1]),
                    control1=point(radius,*control1),control2=point(radius,*control2),
                    end=point(radius,b[0],b[1])))
        features.append(dict(id=identity("section-"+str(index)),name=f"Organic section {index+1:02}",
            operation=dict(kind="curveProfile",inputs=[],values={},curves=curves,
                plane=dict(origin=dict(x=f"neckOffset*{offset}",y=height,z=0),
                           u=dict(x=1,y=0,z=0),v=dict(x=0,y=0,z=-1)))))
    loft=identity("continuous-loft")
    features.append(dict(id=loft,name="Continuous asymmetric lobed and fluted skin",
        operation=dict(kind="loft",inputs=[f["id"] for f in features],values={},ruled=False)))
    output=identity("normal-wall")
    features.append(dict(id=output,name="Open mouth and true normal ceramic wall",
        operation=dict(kind="shell",inputs=[loft],values=dict(thickness="wall"),
            selection=dict(faceAtMaximum=dict(axis="y")))))
    definition=dict(id=identity("model"),version=2,revision=0,
        name="Organic reference study / offset three-lobed bud vase",
        parameters=[dict(name=n,value=v,minimum=lo,maximum=hi,unit=u) for n,v,lo,hi,u in parameters],
        features=features,outputs=[output],
        requirements=[
            dict(id="neck-wall",lhs="wall",relation="<",rhs="neckRadius*.35",message="Keep an open neck with a bounded wall."),
            dict(id="shoulder-room",lhs="shoulderHeight",relation="<",rhs="height*.80",message="Leave room for the blended shoulder and neck.")],
        outputRequirements=[
            dict(id="single-solid",outputID=output,metric="solids",relation="==",value=1,message="The vase must remain one closed material solid."),
            dict(id="height",outputID=output,metric="height",relation="==",value="height",tolerance=.02,message="Retain the authored physical height.")],
        assumptions=["Authored after the frozen AI-generated three-view design reference.",
                     f"{flutes} shallow longitudinal flutes are physical curved geometry, not a texture.",
                     "The section curves, smooth loft and normal shell are ordinary document features."],
        unresolvedMeasurements=["Visual silhouette, shoulder blending, neck placement and flute scale require comparison with the frozen reference."])
    if style=="rounded" and curve_mode=="periodic-c2" and compact:
        definition["revision"]=5
        definition["name"]="Organic reference study / compact C2 clover and fine fluting"
        for check in definition["outputRequirements"]:
            if check["id"]=="height":check["tolerance"]=.2
        definition["assumptions"].append("Periodic C2 cubic B-spline controls encoded in existing cubic Bezier segments, six controls per flute; scalar coefficients factored and compacted within existing document bounds.")
    return definition


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output",type=Path,default=HERE/"model.json")
    parser.add_argument("--flutes",type=int,default=32)
    parser.add_argument("--flute-depth",type=float,default=.35)
    parser.add_argument("--segments",type=int,default=192)
    parser.add_argument("--style",choices=["original","rounded"],default="rounded")
    parser.add_argument("--curve-mode",choices=["hermite","periodic-c2"],default="periodic-c2")
    parser.add_argument("--compact",action="store_true",default=True)
    parser.add_argument("--no-compact",dest="compact",action="store_false")
    args=parser.parse_args()
    definition=model(args.flutes,args.flute_depth,args.segments,args.style,args.curve_mode,args.compact)
    args.output.write_text(json.dumps(definition,indent=2)+"\n")
    print(args.output)
