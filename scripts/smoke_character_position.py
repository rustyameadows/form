#!/usr/bin/env python3
"""Character forms acceptance using the real packaged MCP server in a disposable library.

Native Position picker, focused field commits and actual text selection are accepted
separately by computer use. No fonts, models or hardware are installed/contacted.
"""
import json
import pathlib
import uuid
from smoke_mcp import Client, OUTPUT, ROOT


def text(words, y, face='.AppleSystemUIFont', **typography):
    return dict(id=str(uuid.uuid4()).upper(),kind='text',x=12,y=y,width=200,height=25,
                text=words,fontSize=36,color='#203A4A',typography=dict(
                    fontName=face,kerningMode='metrics',baseline=3,**typography))


def main():
    c=Client()
    try:
        library=pathlib.Path(c.call('form_status')['library_path']).resolve()
        assert library.is_relative_to((ROOT/'.local').resolve()), 'Use a disposable .local validation library.'
        tools=c.discover(['form_edit_artwork','form_font_features','form_story','form_text_style','form_replace_font'])
        project=c.call('form_create_project',{'name':'CHARACTER FORMS / Source remains source'})
        sheet=c.call('form_add_object',{'recipe_id':'artboard','name':'Character forms source','parameters':{'width':230,'depth':210}})
        body=text('H12abQ original',30,variations={'1869640570':72},features={'10':2},opticalSizing={'mode':'automatic'})
        glyph_sample=text('Q original',70,'Georgia')
        caps=text('Orbital office / small caps',110,'Baskerville',features={'37':1})
        unavailable=text('Orbital office',145,'Georgia',features={'37':1})
        grapheme=text('e\u0301 👩🏽‍🚀 🇺🇸',178)
        c.call('form_set_artwork',{'object_id':sheet['id'],'artwork':{'background':'#FFFFFF','bleed':0,'elements':[body,glyph_sample,caps,unavailable,grapheme]}})
        def get():return c.call('form_get_project')
        def art():return c.call('form_get_artwork',{'object_id':sheet['id']})
        def element(value):return next(e for e in art()['elements'] if e['id']==value['id'])
        def position(value,owner=body,**args):
            return c.call('form_edit_artwork',dict(command='character_position',object_id=sheet['id'],element_ids=[owner['id']],position=value)|args)
        baseline=get();original=element(body)
        position('superscript',location=1,length=5)
        raised=get()
        # Locate by source UTF-16 range rather than relying on canonical span order.
        run=next(r for r in element(body)['textRuns'] if r['location']==1)
        assert raised['schemaVersion']>=47 and run['typography']['characterPosition']=='superscript'
        assert run['fontSize']==36 and run['typography']['baseline']==3
        assert run['typography']['features']==original['typography']['features']
        assert run['typography']['variations']==original['typography']['variations'] and element(body)['text']==original['text']
        c.call('form_undo');assert get()==baseline
        c.call('form_redo');assert get()==raised
        before=get()
        for value,args in [('raised',{}),('subscript',{'location':1.5,'length':2}),('superscript',{'location':0,'length':1,'element_ids':[grapheme['id']]})]:
            arguments=dict(command='character_position',object_id=sheet['id'],element_ids=[body['id']],position=value)|args
            c.call('form_edit_artwork',arguments,expect_error=True);assert get()==before
        c.call('form_batch',{'operations':[
            {'name':'form_update_object','arguments':{'object_id':sheet['id'],'name':'Must roll back'}},
            {'name':'form_edit_artwork','arguments':dict(command='character_position',object_id=sheet['id'],element_ids=[body['id']],position=True)}
        ]},expect_error=True);assert get()==before
        position('normal',location=1,length=5)
        normal=element(body);normal_run=next(r for r in normal['textRuns'] if r['location']==1)
        assert normal_run['typography']['characterPosition']=='normal' and normal_run['typography']['features']==original['typography']['features']
        c.call('form_undo');assert get()==raised
        position(None,location=1,length=5)
        reset=next(r for r in element(body)['textRuns'] if r['location']==1)
        assert reset['typography'].get('characterPosition') is None and reset['typography']['features']==original['typography']['features']
        c.call('form_undo');assert get()==raised
        glyphs=c.call('form_font_features',{'font_name':'Georgia','command':'glyphs','query':'ampersand','limit':20})['glyphs']
        glyph=next(row['glyph'] for row in glyphs if row['glyph'].get('glyphName')=='ampersand')
        c.call('form_edit_artwork',{'command':'glyph','object_id':sheet['id'],'element_ids':[glyph_sample['id']],'location':0,'length':1,'glyph':glyph})
        exact=element(glyph_sample);position('subscript',owner=glyph_sample,location=0,length=1)
        assert element(glyph_sample)['glyphOverrides']==exact['glyphOverrides'] and element(glyph_sample)['text']==exact['text']
        style=c.call('form_text_style',{'command':'create','name':'Superscript intent','font_size':36,
                     'typography':{'fontName':'.AppleSystemUIFont','characterPosition':'superscript','baseline':3,'features':{'10':2},'variations':{'1869640570':72}}})['style']
        c.call('form_text_style',{'command':'assign','style_id':style['id'],'object_id':sheet['id'],'element_ids':[body['id']]})
        styled=get();saved=element(body)
        c.call('form_text_style',{'command':'update','style_id':style['id'],'typography':{'fontName':'Georgia'}})
        assert element(body)['typography']['characterPosition']=='superscript' and element(body)['text']==saved['text']
        assert element(body)['typography']['variations']==saved['typography']['variations']
        c.call('form_undo');assert get()==styled
        c.call('form_text_style',{'command':'update','style_id':style['id'],'typography':{'features':{'10':1}}})
        assert element(body)['typography'].get('characterPosition') is None
        c.call('form_undo');assert get()==styled
        exports={}
        for fmt in ['svg','pdf','png']:
            exports[fmt]=c.call('form_export_artwork',{'object_id':sheet['id'],'format':fmt,'outline_text':False,'dpi':150,'path':str(OUTPUT/('character-forms.'+fmt))})
        assert exports['svg']['character_position_text_outlined']==2 and exports['svg']['small_caps_text_outlined']==2
        assert exports['svg']['character_forms_fallback'] and exports['svg']['small_caps_warnings']
        assert get()==styled
        c.call('form_convert_to_paths',{'object_id':sheet['id'],'element_ids':[body['id']]})
        hidden=element(body);assert hidden['hidden'] and hidden['text']==saved['text'] and hidden['typography']==saved['typography']
        c.call('form_undo');assert get()==styled
        second=c.call('form_add_object',{'recipe_id':'artboard','name':'Shared story capacity','parameters':{'width':230,'depth':210},'position':[270,0,0]})
        capacity=text('',30);c.call('form_set_artwork',{'object_id':second['id'],'artwork':{'background':'#FFFFFF','bleed':0,'elements':[capacity]}})
        c.call('form_story',{'command':'create','name':'One character-position source','frames':[
            {'object_id':sheet['id'],'element_id':body['id']},{'object_id':second['id'],'element_id':capacity['id']}]})
        story=next(s for s in c.call('form_story',{'command':'list'})['stories'] if s['name']=='One character-position source')
        source=c.call('form_story',{'command':'get','story_id':story['id']})['story'];before=get()
        position('subscript',location=1,length=5)
        now=c.call('form_story',{'command':'get','story_id':story['id']})['story']
        assert get()['objects']==before['objects'] and now['text']==source['text']
        assert next(r for r in now['textRuns'] if r['location']==1)['typography']['characterPosition']=='subscript'
        c.call('form_undo');assert get()==before
        c.call('form_open_project',{'project_id':project['id']});reopened=get()
        for key in ['objects','textStories','textStyles']:assert reopened.get(key)==before.get(key)
        package=library/(project['id']+'.form')
        for path in package.rglob('*.json'):
            raw=path.read_text()
            assert all(key not in raw for key in ['studio.form.positionSource','studio.form.positionResolution','studio.form.positionResolvedFont','studio.form.positionNominalFont','studio.form.positionMarker'])
        c.call('form_set_view',{'view':'artwork','object_id':sheet['id'],'element_ids':[body['id']]})
        report=dict(project_id=project['id'],sheet_id=sheet['id'],body_id=body['id'],glyph_id=glyph_sample['id'],caps_id=caps['id'],story_id=story['id'],tools=len(tools),exports=exports,
                    checks='Explicit position and legacy reset; nominal/manual source; strict grapheme and batch rejection; exact glyph; reusable style and font-only edits; native-outline SVG fallback; source recovery; one-Undo; shared story; schema47 disk reopen',native_acceptance_pending=True,hardware_contacted=False,external_model_calls=False)
        (OUTPUT/'character-forms-report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
    finally:c.close()


if __name__=='__main__':main()
