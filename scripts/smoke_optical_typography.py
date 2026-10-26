#!/usr/bin/env python3
"""Packaged optical sizing/source/Undo/export acceptance in a disposable .local library.

No font installation/download, external model call or hardware operation.
Native focused Up/Down/repeat/Shift/Undo is accepted separately with actual events.
"""
import json
import pathlib
import uuid
from smoke_mcp import Client, OUTPUT, ROOT


def text(value, x, y, size=32, face='.AppleSystemUIFont'):
    return dict(id=str(uuid.uuid4()).upper(), kind='text', x=x, y=y, width=200,
                height=60, text=value, color='#203A4A', fontSize=size,
                typography=dict(fontName=face, kerningMode='metrics', caseTreatment='uppercase',
                                variations={'1869640570':72}, featureSelections={'1':[2]}))


def main():
    c = Client()
    try:
        library = pathlib.Path(c.call('form_status')['library_path']).resolve()
        assert library.is_relative_to((ROOT/'.local').resolve()), 'Use a disposable .local validation library.'
        tools = c.discover(['form_edit_artwork','form_font_features','form_text_style','form_story','form_replace_font'])
        project = c.call('form_create_project', {'name':'OPTICAL / The intended size'})
        sheet = c.call('form_add_object', {'recipe_id':'artboard','name':'Optical typography source','parameters':{'width':230,'depth':165}})
        body = text('Q office / Original words',12,45)
        title = text('OPTICAL / The intended size',12,10,24,'Georgia')
        title['typography'].pop('variations'); title['typography'].pop('featureSelections')
        c.call('form_set_artwork', {'object_id':sheet['id'],'artwork':{'background':'#F6F3EB','bleed':0,'elements':[title,body]}})
        def get(): return c.call('form_get_project')
        def art(): return c.call('form_get_artwork', {'object_id':sheet['id']})
        def layer(): return next(e for e in art()['elements'] if e['id']==body['id'])
        def optical(policy, **args):
            return c.call('form_edit_artwork',dict(command='optical',object_id=sheet['id'],element_ids=[body['id']],optical_sizing=policy)|args)
        baseline = get(); original = layer()
        optical({'mode':'automatic'})
        auto = get(); assert auto['schemaVersion']>=42 and layer()['typography']['opticalSizing']=={'mode':'automatic'}
        assert layer()['text']==original['text'] and layer()['typography']['variations']==original['typography']['variations']
        assert layer()['typography']['featureSelections']==original['typography']['featureSelections']
        c.call('form_undo'); assert get()==baseline
        c.call('form_redo'); assert get()==auto
        before = get()
        for policy in [{'mode':'explicit','points':100}, {'mode':'explicit','points':True}, {'mode':'automatic','points':24}]:
            c.call('form_edit_artwork',dict(command='optical',object_id=sheet['id'],element_ids=[body['id']],optical_sizing=policy),expect_error=True)
            assert get()==before
        glyphs = c.call('form_font_features', {'command':'alternates','font_name':'.AppleSystemUIFont','text':body['text'],
                      'location':0,'length':1,'font_size':32,'typography':layer()['typography']})['glyphs']
        glyph = next(g['glyph'] for g in glyphs if g.get('current'))
        c.call('form_edit_artwork', {'command':'glyph','object_id':sheet['id'],'element_ids':[body['id']],
                                   'location':0,'length':1,'glyph':glyph})
        glyph_source = layer(); words = glyph_source['text']; exact = glyph_source['glyphOverrides']
        optical({'mode':'explicit','points':72},location=0,length=1)
        assert layer()['text']==words and layer()['glyphOverrides']==exact
        assert layer()['textRuns'][0]['typography']['opticalSizing']=={'mode':'explicit','points':72}
        c.call('form_undo'); assert layer()==glyph_source
        before = get()
        c.call('form_batch', {'operations':[
            {'name':'form_update_object','arguments':{'object_id':sheet['id'],'name':'Must roll back'}},
            {'name':'form_edit_artwork','arguments':dict(command='optical',object_id=sheet['id'],element_ids=[body['id']],optical_sizing={'mode':'explicit','points':100})}
        ]},expect_error=True)
        assert get()==before
        style = c.call('form_text_style', {'command':'create','name':'Optical heading','font_size':32,
                      'typography':dict(fontName='.AppleSystemUIFont',opticalSizing={'mode':'automatic'},variations={'1869640570':72})})['style']
        c.call('form_text_style', {'command':'assign','style_id':style['id'],'object_id':sheet['id'],
                                 'element_ids':[body['id']]})
        styled = get(); styled_body = layer()
        c.call('form_text_style', {'command':'update','style_id':style['id'],'typography':{'opticalSizing':{'mode':'none'}}})
        assert layer()['typography']['opticalSizing']=={'mode':'none'} and layer()['text']==words and layer()['glyphOverrides']==exact
        c.call('form_undo'); assert get()==styled
        optical(None)
        assert layer()['typography'].get('opticalSizing') is None and '1869640570' not in layer()['typography']['variations']
        c.call('form_undo'); assert get()==styled
        replaced = c.call('form_replace_font', {'from_font':'.AppleSystemUIFont','to_font':'Georgia'})
        assert replaced['warnings']
        changed = layer()
        assert changed['text']==words and changed['glyphOverrides']==exact
        assert changed['typography']['opticalSizing']==styled_body['typography']['opticalSizing']
        assert changed['typography']['variations']==styled_body['typography']['variations']
        c.call('form_undo'); assert get()==styled
        outputs = {}
        for fmt in ['svg','pdf','png']:
            outputs[fmt]=c.call('form_export_artwork',{'object_id':sheet['id'],'format':fmt,
                     'outline_text':False,'dpi':150,'path':str(OUTPUT/('optical-typography.'+fmt))})
        assert outputs['svg']['optical_text_outlined']==1 and outputs['svg']['optical_sizing_fallback']
        assert get()==styled
        second = c.call('form_add_object', {'recipe_id':'artboard','name':'Story capacity','parameters':{'width':230,'depth':165},'position':[270,0,0]})
        capacity = text('',12,45)
        c.call('form_set_artwork',{'object_id':second['id'],'artwork':{'background':'#F6F3EB','bleed':0,'elements':[capacity]}})
        story_result=c.call('form_story',{'command':'create','name':'One optical source','frames':[
            {'object_id':sheet['id'],'element_id':body['id']},{'object_id':second['id'],'element_id':capacity['id']}]})
        stories=c.call('form_story',{'command':'list'})['stories'];story=next(s for s in stories if s['name']=='One optical source')
        before=get();frame_objects=before['objects'];source=c.call('form_story',{'command':'get','story_id':story['id']})['story']
        optical({'mode':'explicit','points':72},location=0,length=1)
        after=get();now=c.call('form_story',{'command':'get','story_id':story['id']})['story']
        assert after['objects']==frame_objects and now['text']==source['text'] and now['glyphOverrides']==source['glyphOverrides']
        assert now['textRuns'][0]['typography']['opticalSizing']=={'mode':'explicit','points':72}
        c.call('form_undo');assert get()==before
        c.call('form_open_project',{'project_id':project['id']});reopened=get()
        assert reopened['objects']==before['objects'] and reopened['textStories']==before['textStories'] and reopened['textStyles']==before['textStyles']
        assert reopened['schemaVersion']>=42
        c.call('form_set_view',{'view':'artwork','object_id':sheet['id'],'element_ids':[body['id']]})
        report=dict(project_id=project['id'],sheet_id=sheet['id'],body_id=body['id'],story_id=story['id'],style_id=style['id'],
                    glyph=exact[0]['glyph'],tools=len(tools),exports=outputs,native_acceptance_pending=True,
                    checks='Real optical modes; strict focused command/range; glyph identity; source/style/story preservation; reset; font replacement; atomic rollback; one Undo; physical SVG fallback/PDF/PNG; schema42 reopen',
                    hardware_contacted=False,external_model_calls=False)
        (OUTPUT/'optical-typography-report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
    finally:c.close()


if __name__=='__main__':main()
