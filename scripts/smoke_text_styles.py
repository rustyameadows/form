#!/usr/bin/env python3
"""FOLIO: reusable typography across frames and linked physical faces.

Run in an isolated FORM_LIBRARY_PATH. No model or printer commands.
"""
import copy
import json
import pathlib
import statistics
import time
import uuid
from smoke_mcp import Client, OUTPUT


def text(x, y, w, h, content, size=12, color='#283C32', name=None):
    return dict(id=str(uuid.uuid4()).upper(), kind='text', x=x, y=y, width=w, height=h,
        text=content, fontSize=size, color=color, name=name or content.replace('\n', ' / '))


def shape(kind, x, y, w, h, color, **extra):
    return dict(id=str(uuid.uuid4()).upper(), kind=kind, x=x, y=y, width=w, height=h,
        text='', fontSize=14, color=color, **extra)


def main():
    c = Client()
    try:
        status = c.call('form_status'); assert '/.local/' in status['library_path']
        c.discover(['form_text_style'])
        project = c.call('form_create_project', {'name': 'FOLIO · A guide to light'})
        styles = {}
        for name, size, type in [
            ('Heading', 36, dict(fontName='Baskerville', leading=42, featureSelections={'1':[2,4,20]})),
            ('Body', 12, dict(fontName='Georgia', leading=17, paragraphAfter=7, wordSpacing=.2)),
            ('Caption', 8, dict(fontName='Menlo-Regular', tracking=.8)),
        ]:
            styles[name] = c.call('form_text_style', {'command':'create','name':name,'font_size':size,'typography':type})['style']['id']
        cover = c.call('form_add_object', {'recipe_id':'artboard','name':'FOLIO / Field guide cover',
            'parameters':{'width':160,'depth':210}})
        page = c.call('form_add_object', {'recipe_id':'artboard','name':'FOLIO / Instructions',
            'parameters':{'width':160,'depth':210}})
        title = text(14,33,132,60,'A little\nlight.',name='Cover title')
        intro = text(14,99,126,23,'A field guide to the small rituals\nthat make a room feel like home.',name='Cover introduction')
        stamp = text(14,13,132,7,'FOLIO / OBSERVATIONS IN EVERYDAY DESIGN')
        footer = text(14,195,132,6,'LIGHT & PROPORTION / VOL. 01')
        sun = shape('ellipse',91,135,48,48,'#D99B65')
        halo = shape('ellipse',86,130,58,58,'#F3EEE2',fillEnabled=False,stroke={'color':'#D99B65','width':.35})
        horizon = shape('line',14,159,132,.1,'#283C32',stroke={'color':'#283C32','width':.35})
        rays = [shape('line',14,166+i*3.4,130,.1,'#C8C1AC',stroke={'color':'#C8C1AC','width':.18}) for i in range(5)]
        c.call('form_set_artwork', {'object_id':cover['id'],'artwork':dict(background='#F3EEE2',bleed=0,
            elements=[stamp,title,intro,sun,halo,horizon,*rays,footer])})
        chapter = text(14,29,132,39,'Find your\nmorning light.',name='Chapter heading')
        byline = text(14,74,132,19,'Three small gestures.\nA different beginning to the day.',name='Chapter introduction')
        captions = [text(14,13,132,7,'FIELD NOTES / 01'),text(14,195,132,6,'FORM / A PRACTICE IN PAYING ATTENTION')]
        bodies=[]; steps=[]
        for number, y, label, body in [
            ('01',102,'OPEN THE ROOM','Draw back the curtain. Let the first\nlight find a place to land.'),
            ('02',132,'MAKE A QUIET CORNER','A lamp, a surface, a favorite object.\nLeave a little space around them.'),
            ('03',162,'NOTICE WHAT CHANGES','Move one thing. Watch its shadow.\nGood proportion begins with looking.'),
        ]:
            steps += [text(14,y,12,7,number,color='#BA6546'), text(34,y,112,7,label,color='#BA6546')]
            bodies.append(text(34,y+8,112,20,body,name='Step '+number+' body'))
        c.call('form_set_artwork', {'object_id':page['id'],'artwork':dict(background='#F3EEE2',bleed=0,
            elements=[*captions,chapter,byline,*steps,*bodies])})
        def apply(owner, ids, style):
            return c.call('form_text_style', {'command':'assign','style_id':styles[style],
                'object_id':owner,'element_ids':[e['id'] for e in ids]})
        apply(cover['id'],[title],'Heading');apply(cover['id'],[intro],'Body');apply(cover['id'],[stamp,footer],'Caption')
        apply(page['id'],[chapter],'Heading');apply(page['id'],[byline,*bodies],'Body');apply(page['id'],[*captions,*steps],'Caption')
        def art(owner):return c.call('form_get_artwork',{'object_id':owner})
        def element(owner,id):return next(e for e in art(owner)['elements'] if e['id']==id)
        # A deliberate local display size stays linked to the heading style.
        display=element(cover['id'],title['id']);display['fontSize']=54;display['typography']['leading']=56
        c.call('form_edit_artwork',{'object_id':cover['id'],'command':'replace','elements':[display]})
        assert element(cover['id'],title['id'])['textStyle']['overrides']==['fontSize','leading']
        boxes=[]
        for source, material, x in [(cover,'oak',-240),(page,'graphite',240)]:
            box=c.call('form_add_object',{'recipe_id':'box','name':'FOLIO / '+material.title()+' edition',
                'material_id':material,'parameters':{'width':160,'depth':210,'height':12,'corner':2},'position':[x,0,0]})
            c.call('form_link_artwork',{'object_id':box['id'],'source_object_id':source['id']});boxes.append(box)
        package=pathlib.Path(status['library_path'])/(project['id']+'.form')
        resources=lambda:{o['id']:o['file'] for o in json.loads((package/'Manifest.json').read_text())['objects']}
        before=c.call('form_get_project');old=resources()
        c.call('form_text_style',{'command':'update','style_id':styles['Heading'],'font_size':40,'typography':{'tracking':.3}})
        assert element(cover['id'],title['id'])['fontSize']==54
        assert element(cover['id'],title['id'])['typography']['tracking']==.3
        assert element(page['id'],chapter['id'])['fontSize']==40
        assert {k for k in old if resources()[k]!=old[k]}=={cover['id'],page['id']}
        c.call('form_undo');assert c.call('form_get_project')==before
        c.call('form_text_style',{'command':'assign','style_id':styles['Caption'],'object_id':cover['id'],
            'element_ids':[intro['id']],'location':0,'length':7})
        c.call('form_text_style',{'command':'update','style_id':styles['Body'],'typography':{'leading':19}})
        first=element(cover['id'],intro['id'])['textRuns'][0]
        assert first['fontSize']==8 and first['textStyle']['characterOnly']
        assert first['paragraphStyle']['styleID']==styles['Body'] and first['typography']['leading']==19
        c.call('form_text_style',{'command':'update','style_id':styles['Caption'],'font_size':9,'typography':{'leading':90}})
        first=element(cover['id'],intro['id'])['textRuns'][0]
        assert first['fontSize']==9 and first['typography']['leading']==19
        for _ in range(3):c.call('form_undo')
        assert c.call('form_get_project')==before
        c.call('form_text_style',{'command':'update','style_id':styles['Body'],'name':'Body / reading'})
        assert resources()==old
        c.call('form_undo');assert c.call('form_get_project')==before
        def export(owner,name,fmt='png'):
            path=OUTPUT/(name+'.'+fmt)
            c.call('form_export_artwork',{'object_id':owner,'format':fmt,'dpi':150,'path':str(path)})
            return path.read_bytes()
        initial=[export(cover['id'],'folio-cover'),export(page['id'],'folio-page')]
        c.call('form_text_style',{'command':'delete','style_id':styles['Body']})
        assert [export(cover['id'],'folio-cover-detached'),export(page['id'],'folio-page-detached')]==initial
        c.call('form_undo');assert c.call('form_get_project')==before
        c.call('form_text_style',{'command':'detach','object_id':boxes[0]['id'],'element_ids':[intro['id']]})
        assert export(cover['id'],'folio-cover-single-detach')==initial[0]
        c.call('form_undo');assert c.call('form_get_project')==before
        c.call('form_batch',{'operations':[
            {'name':'form_text_style','arguments':{'command':'update','style_id':styles['Heading'],'font_size':44}},
            {'name':'form_text_style','arguments':{'command':'assign','style_id':str(uuid.uuid4()),'object_id':cover['id'],'element_ids':[intro['id']]}}]},expect_error=True)
        assert c.call('form_get_project')==before
        c.call('form_text_style',{'command':'reset','object_id':cover['id'],'element_ids':[title['id']]})
        assert element(cover['id'],title['id'])['fontSize']==36
        c.call('form_undo');assert c.call('form_get_project')==before
        for owner,name in [(cover['id'],'folio-cover'),(page['id'],'folio-page')]:
            for fmt in ['svg','pdf','jpeg']:export(owner,name,fmt)
        c.call('form_convert_to_paths',{'object_id':cover['id'],'element_ids':[title['id']]})
        assert element(cover['id'],title['id'])['hidden'] and element(cover['id'],title['id'])['textStyle']['styleID']==styles['Heading']
        c.call('form_undo');assert c.call('form_get_project')==before
        c.call('form_open_project',{'project_id':project['id']})
        assert c.call('form_get_project')['schemaVersion']==12
        assert c.call('form_get_project')['objects']==before['objects']
        perf=c.call('form_add_object',{'recipe_id':'artboard','name':'Styles performance','parameters':{'width':500,'depth':500}})
        specimens=[text(10+(i%10)*49,10+(i//10)*24,47,20,'Light / '+str(i)) for i in range(200)]
        c.call('form_set_artwork',{'object_id':perf['id'],'artwork':dict(background='#F3EEE2',bleed=0,elements=specimens)})
        apply(perf['id'],specimens,'Body')
        c.call('form_set_view',{'view':'artwork','object_id':perf['id']})
        times=[]
        for i in range(20):
            start=time.perf_counter()
            c.call('form_text_style',{'command':'update','style_id':styles['Body'],'typography':{'tracking':i*.02}})
            times.append((time.perf_counter()-start)*1000)
        perf_status=c.call('form_status')
        c.call('form_text_style',{'command':'update','style_id':styles['Body'],'typography':{'tracking':0}})
        c.call('form_delete_objects',{'object_ids':[perf['id']]})
        c.call('form_set_view',{'view':'artwork','object_id':boxes[1]['id'],'element_ids':[bodies[0]['id']]})
        report=dict(project_id=project['id'],cover_id=cover['id'],page_id=page['id'],box_ids=[b['id'] for b in boxes],
            styles=styles,title_id=title['id'],intro_id=intro['id'],chapter_id=chapter['id'],body_ids=[e['id'] for e in bodies],
            tools=50,saved_edit_median_ms=round(statistics.median(times),2),saved_edit_p95_ms=round(sorted(times)[18],2),
            performance_status=perf_status,status=c.call('form_status'),
            checks='Reusable heading/body/caption; inherited updates with persistent local overrides; selective immutable resources; linked physical faces; rename metadata; reset; pixel-identical detach/delete; batch rollback; recoverable outlines; physical SVG/PDF/PNG/JPEG; schema-12 reopen; 200-text saved style edits')
        (OUTPUT/'text-styles-report.json').write_text(json.dumps(report,indent=2)+'\n')
        (OUTPUT/'text-styles-baseline.json').write_text(json.dumps(c.call('form_get_project'),indent=2)+'\n')
        print(json.dumps(report,indent=2))
    finally:c.close()


if __name__=='__main__':main()
