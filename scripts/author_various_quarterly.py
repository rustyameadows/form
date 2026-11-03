#!/usr/bin/env python3
"""Author VARIOUS through the public tools of one already-running ordinary LAB.

--plan-only validates/layouts the complete editorial issue without contacting LAB.
The live mode requires an explicit disposable library and a fresh output folder;
it never launches an app, edits project internals, calls an image model or prints.
All copy is retained. A failed fit stops authoring rather than deleting words.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import stat
import subprocess
import sys
import uuid

from magazine_physical_examples import TRIM_MM, assembly_definition, parent_sheet_plan
from render_paper_packaging import camera
from validate_paper_packaging import Session

ROOT = Path(__file__).resolve().parents[1]
EDITORIAL = ROOT / 'examples/publications/various-quarterly/editorial.json'
NAMESPACE = uuid.UUID('16361317-eaea-4939-8b74-3059879132fd')
W, H = TRIM_MM
M, CW, GAP = 18.0, 85.95, 8.0
BLACK = '#000000'
FONT = 'HelveticaNeue'
MEDIUM = 'HelveticaNeue-Medium'
BOLD = 'HelveticaNeue-Bold'


def require(value, message):
    if not value:
        raise AssertionError(message)


def stable(value):
    return str(uuid.uuid5(NAMESPACE, value)).upper()


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()


def utf16(value):
    return len(value.encode('utf-16-le')) // 2


def canonical(project):
    return {key: project.get(key) for key in ('id', 'objects', 'publications', 'textStories', 'textStyles', 'swatches', 'studioPresentation')}


def typography(size, font=FONT, leading=None):
    return dict(fontName=font, leading=round(leading or size * 1.35, 6), paragraphAfter=4.0,
                alignment='left', language='en')


def node(kind, key, x, y, width, height, text='', size=10.0, font=FONT, **extra):
    value = dict(id=stable(key), name=key, kind=kind, x=round(x, 5), y=round(y, 5),
                 width=round(width, 5), height=round(height, 5), color=BLACK,
                 text=text, fontSize=float(size))
    if kind == 'text':
        value['typography'] = typography(size, font)
    value.update(extra)
    return value


def verify_k_element(element, ink_id, stories):
    """Check painted canonical ink, resolving empty linked-frame references."""
    reference=element.get('storyFrame')
    if reference:
        require(element.get('kind')=='text' and not element.get('text') and not element.get('textRuns'),
                'A linked frame must remain unpainted canonical capacity.')
        story=stories.get(reference.get('storyID'))
        require(story is not None,'A colored page references a missing rich story source.')
        verify_k_element(dict(story,kind='text'),ink_id,{})
        return
    kind=element.get('kind')
    if kind!='group' and kind!='line' and element.get('fillEnabled',True) and (kind!='text' or element.get('text')):
        require(element.get('fillSwatchID')==ink_id,'Every painted colored-page fill/story source must retain processK intent.')
    stroke=element.get('stroke')
    if stroke and stroke.get('enabled',True) and stroke.get('width',0)>0:
        require(stroke.get('swatchID')==ink_id,'Every colored-page stroke must retain processK intent.')
    if kind=='line':require(stroke and stroke.get('swatchID')==ink_id,'An implicit colored-page line stroke is not declared processK.')
    for run in element.get('textRuns') or []:
        if run.get('length',0)>0:require(run.get('swatchID')==ink_id,'Every painted rich story/text span must retain processK intent.')


def verify_library_scope(library, *, verified_existing=False, resume=None, project_id=None, expected_source_hash=None):
    """Normal-library access is only for an explicitly pinned existing source."""
    library=Path(library).resolve()
    disposable=any(library.parts[i:i+2]==('.local','validation') for i in range(len(library.parts)-1))
    if verified_existing:
        require(resume is not None and project_id and expected_source_hash,
                'Verified existing-library access requires a completed report, snapshot, explicit project UUID and canonical source SHA256.')
        require(len(resume)==3 and Path(resume[0]).is_file() and Path(resume[1]).is_file(),
                'Verified existing-library access requires existing report and public source-snapshot files.')
        try:uuid.UUID(project_id)
        except (ValueError,TypeError,AttributeError):raise AssertionError('Existing-library project UUID must be valid.')
        require(len(expected_source_hash)==64 and all(c in '0123456789abcdef' for c in expected_source_hash.lower()) and resume[2]==expected_source_hash,
                'Existing-library access requires the exact explicit canonical SHA256 guard.')
    require(disposable or verified_existing,
            'New authoring requires a disposable library under .local/validation; normal libraries require --verified-existing-project-library and full guarded resume.')
    return 'disposable_validation' if disposable else 'verified_existing_project'


def verify_resume_app(report, app, expected_hash=None):
    app=Path(app).resolve();actual=sha(app/'Contents/MacOS/LAB')
    expected=(expected_hash or report['app_sha256']).lower()
    require(len(expected)==64 and all(c in '0123456789abcdef' for c in expected),'Expected app SHA256 must be exactly64hexadecimal characters.')
    require(actual==expected,'The running app binary does not match the explicitly expected verified SHA256.')
    require(expected_hash is not None or Path(report['app']).resolve()==app,
            'A changed app path requires --expected-app-sha256 for that explicitly verified binary.')
    return dict(prior_app=str(Path(report['app']).resolve()),prior_app_sha256=report['app_sha256'],
                app=str(app),app_sha256=actual,explicit_verified_update=expected_hash is not None)


def verify_resume_source(report, snapshot, plan, project_id, expected_source_hash):
    require(project_id==report.get('project_id')==snapshot.get('id'),'Resume project UUID must match the report, snapshot and explicit CLI project.')
    require(len(report.get('page_ids',[]))==52 and len(report.get('placements',[]))==110 and len(report.get('stories',[]))==26,
            'Verify/export resume requires a completely authored52page110placement26story checkpoint.')
    publication=next((p for p in snapshot.get('publications',[]) if p['id']==report.get('publication_id')),None)
    require(publication is not None and [p['objectID'] for p in publication['pages']]==report['page_ids'],'Resume publication/page ownership differs from its completed report.')
    expected={s['key']:s['source_sha256'] for s in plan.stories}
    require({s['key']:s['source_sha256'] for s in report['stories']}==expected,'Resume report no longer matches every finalized editorial story.')
    baseline=digest(canonical(snapshot))
    require(baseline==expected_source_hash,'Resume snapshot canonical hash differs from the explicit CLI guard.')
    return baseline


class IssuePlan:
    """Offline editorial composition; all IDs become ordinary authored project data."""
    def __init__(self, editorial):
        self.editorial = editorial
        fake = dict(id=stable('offline-document'), layout=dict(firstPageSide='recto'),
                    pages=[dict(id=stable(f'logical-{i}'), objectID=stable(f'page-{i}')) for i in range(1, 53)])
        self.physical = parent_sheet_plan(fake)
        self.black_pages = set(self.physical['black_only_pages'])
        self.pages = {i: dict(logical_page=i, elements=[], placements=[], section=None,
                             print_intent='blackOnly' if i in self.black_pages else 'color') for i in range(1, 53)}
        self.stories = []
        self.copy_fragments = []
        self.visuals = []
        self.build()
        self.validate()

    def text(self, page, key, text, x, y, width, height, size=10.0, font=FONT, counted=True):
        if not text:
            return
        self.pages[page]['elements'].append(node('text', key, x, y, width, height, text, size, font))
        if counted:
            self.copy_fragments.append(dict(key=key, text=text, logical_page=page, kind='text'))

    def line(self, page, key, x, y, width, weight=.25):
        self.pages[page]['elements'].append(node('rectangle', key, x, y, width, weight))

    def heading(self, page, section, *, small=False):
        self.pages[page]['section'] = section['key']
        kicker = section.get('studio') or ('FIELD NOTES' if section['kind']=='dispatches' else 'STYLE / AN ESSAY' if section['kind']=='essay' else 'OPENING NOTES')
        self.text(page, section['key']+'-kicker', kicker.upper(), M, 18, W-2*M, 8, 9.0, MEDIUM, counted=False)
        self.text(page, section['key']+'-title', section['title'], M, 34, W-2*M, 50 if not small else 37,
                  39.0 if not small else 31.0, BOLD)
        self.text(page, section['key']+'-standfirst', section['standfirst'], M, 88 if not small else 77,
                  W-2*M, 29, 13.0, FONT)

    def visual(self, page, work, box, *, caption_y=None, caption_width=None, crop=None, across=None, image_role=None):
        x, y, width, height = box
        record = dict(key=work['key'], logical_page=page, box_mm=[x,y,width,height],
                      print_intent=self.pages[page]['print_intent'], source_work=work.get('source_work'),
                      source_works=work.get('source_works'), caption=work.get('caption',''), title=work.get('title',''))
        if image_role is not None:
            require(image_role in ('whole-view', 'detail'), 'Unknown editorial image role: '+str(image_role))
            record['image_role'] = image_role
        if across:
            record['across_pages'] = across
        if crop:
            record['crop'] = crop
        self.pages[page]['placements'].append(record)
        self.visuals.append(record)
        if work.get('title') or work.get('caption'):
            title = work.get('title', '')
            caption = work.get('caption', '')
            content = title + ('\n' if title and caption else '') + caption
            self.text(page, work['key']+'-caption', content, x, caption_y if caption_y is not None else y+height+3,
                      caption_width or min(width, W-M-x), 18 if height>55 else 15, 8.0, FONT)

    def story(self, key, title, text, frames, *, size=11.25, leading=15.2, minimum=10.0):
        require(bool(text.strip()), 'An authored story must have complete nonempty source: '+key)
        specs=[]
        for index, (page, x, y, width, height) in enumerate(frames):
            identity=stable(key+f'-frame-{index}')
            value=node('text', key+f'-frame-{index}', x,y,width,height,'',size)
            value['typography']=typography(size, leading=leading)
            self.pages[page]['elements'].append(value)
            specs.append(dict(logical_page=page, element_id=identity, box_mm=[x,y,width,height]))
        self.stories.append(dict(key=key, name=title, source=text, source_sha256=hashlib.sha256(text.encode()).hexdigest(),
                                 source_utf16=utf16(text), frames=specs, size=float(size), leading=float(leading), minimum_size=minimum))
        self.copy_fragments.append(dict(key=key, text=text, logical_page=frames[0][0], kind='story'))

    def profile(self, section):
        a,b,c,d=section['logical_pages']; works=section['works']; self.heading(a,section)
        for page in (a,b,c,d):
            self.pages[page]['section']=section['key']
        self.visual(a,works[0],(M,124,W-2*M,109),caption_y=237)
        self.text(a,section['key']+'-fictional',section['printed_notice'],M,261,W-2*M,7,7.0,counted=False)
        self.visual(b,works[1],(M,22,W-2*M,105),caption_y=131)
        self.visual(c,works[2],(M,176,CW,61),caption_y=241)
        self.visual(c,works[3],(M+CW+GAP,176,CW,61),caption_y=241)
        self.visual(d,works[4],(M,26,109,154),caption_y=184)
        self.visual(d,works[5],(139,26,58.9,64),caption_y=94)
        self.visual(d,works[6],(139,119,58.9,64),caption_y=187)
        self.visual(d,works[7],(M,216,W-2*M,35),caption_y=254)
        self.story(section['key']+'-body',section['studio']+' / Profile','\n\n'.join(section['body']),
                   [(b,M,164,CW,88),(b,M+CW+GAP,164,CW,88),(c,M,28,CW,126),(c,M+CW+GAP,28,CW,126)])

    def essay(self, section):
        a,b,c,d=section['logical_pages']; works=section['works']; self.heading(a,section,small=True)
        for page in (a,b,c,d): self.pages[page]['section']=section['key']
        self.visual(a,works[1],(M,115,W-2*M,61),caption_y=180)
        across=section['key']=='style_01'
        require(not across or b not in self.black_pages and c not in self.black_pages,'A color gutter hero needs two white parent faces.')
        self.visual(b,works[0],(M,23,2*W-2*M if across else W-2*M,128),caption_y=155,
                    caption_width=W-2*M, across=[b,c] if across else None)
        frames=[(a,M,203,CW,49),(a,M+CW+GAP,203,CW,49),(b,M,185,CW,67),(b,M+CW+GAP,185,CW,67)]
        if across:
            self.visual(c,works[2],(112,189,85.9,52),caption_y=245)
            frames.append((c,M,185,CW,67))
            remaining=works[3:]
            self.visual(d,remaining[0],(M,22,W-2*M,78),caption_y=104)
            for i, work in enumerate(remaining[1:]):
                col=i%3; row=i//3
                self.visual(d,work,(M+col*62.5,131+row*66,54.9,43),caption_y=177+row*66)
        else:
            self.visual(c,works[2],(M,23,W-2*M,128),caption_y=155)
            self.visual(c,works[3],(112,189,85.9,52),caption_y=245)
            frames.append((c,M,185,CW,67))
            for i,work in enumerate(works[4:]):
                col=i%2; row=i//2
                self.visual(d,work,(M+col*(CW+GAP),22+row*78,CW,51),caption_y=77+row*78)
        self.story(section['key']+'-body',section['title'],'\n\n'.join(section['body']),frames,size=11.0,leading=14.8)

    def dispatches(self, section):
        pages=section['logical_pages']; works=section['works']; self.heading(pages[0],section,small=True)
        for page in pages: self.pages[page]['section']=section['key']
        self.visual(pages[0],works[0],(M,113,109,125),caption_y=242)
        self.visual(pages[0],works[1],(139,113,58.9,52),caption_y=169)
        self.visual(pages[0],works[2],(139,201,58.9,39),caption_y=244)
        for offset,page in enumerate(pages[1:]):
            for column in range(3):
                work=works[3+offset*3+column]
                self.visual(page,work,(M+column*62.5,22,54.9,84),caption_y=110,
                            image_role='whole-view' if work['key']=='various_back_05' else None)
            for column in range(2):
                module=section['modules'][offset*2+column]; x=M+column*(CW+GAP)
                self.text(page,module['key']+'-heading',module['title'],x,137,CW,13,13.0,MEDIUM)
                self.story(section['key']+'-'+module['key'],module['title'],module['body'],[(page,x,155,CW,97)],size=10.75,leading=14.4)

    def frontmatter(self, section):
        a,b,c,d=section['logical_pages']; self.heading(a,section)
        for page in (a,b,c,d):self.pages[page]['section']=section['key']
        works=section['works']; self.visual(a,works[0],(M,126,W-2*M,119),caption_y=249)
        self.text(b,'contents-heading','In this issue',M,23,W-2*M,20,27.0,MEDIUM,counted=False)
        for index,item in enumerate(self.editorial['contents']):
            y=58+index*10.5
            self.line(b,f'contents-rule-{index}',M,y+8,W-2*M,.15)
            self.text(b,'contents-'+item['key'],item['title'],M,y,148,8,10.0)
            self.text(b,'contents-range-'+item['key'],f"{item['interior_start']:02d}–{item['interior_end']:02d}",172,y,25.9,8,9.0,MEDIUM,counted=False)
        self.visual(b,works[1],(M,207,W-2*M,39),caption_y=250)
        self.text(c,'letter-heading',"Editor's letter",M,23,CW,15,17.0,MEDIUM,counted=False)
        self.story('frontmatter-letter',"Editor's letter",'\n\n'.join(section['body']),[(c,M,52,CW,188)],size=11.25,leading=15.2)
        self.visual(c,works[2],(119,52,78.9,183),caption_y=239)
        masthead,contributors=section['modules']
        self.text(d,'masthead-heading',masthead['title'],M,24,W-2*M,14,20.0,MEDIUM)
        self.story('frontmatter-masthead',masthead['title'],masthead['body'],[(d,M,45,W-2*M,41)],size=10.5,leading=14.0)
        self.text(d,'contributors-heading',contributors['title'],M,104,W-2*M,14,20.0,MEDIUM)
        contribution='\n'.join(item['title']+' / '+item['body'] for item in contributors['items'])
        self.story('frontmatter-contributors',contributors['title'],contribution,[(d,M,127,W-2*M,76)],size=10.5,leading=14.5)
        self.visual(d,works[3],(M,219,W-2*M,30),caption_y=252)

    def cover(self, cover):
        page=cover['logical_page']; key=cover['key']; self.pages[page]['section']=key
        # A separate editable native composition occupies each cover; ochre is stock, never a printed fill.
        work=dict(key=cover['visual_key'],title='',caption='')
        if page==1:
            self.text(page,key+'-season','AUTUMN 2026 / QUARTERLY',M,22,W-2*M,8,9.0,MEDIUM,counted=False)
            self.text(page,key+'-title',cover['title'],M,37,W-2*M,43,76.0,BOLD)
            self.text(page,key+'-subtitle',cover['subtitle'],M,86,W-2*M,13,13.0,MEDIUM)
            self.visual(page,work,(M,114,W-2*M,110))
            self.text(page,key+'-text',cover['text'],M,242,W-2*M,20,10.0)
        elif page==52:
            self.text(page,key+'-subtitle',cover['subtitle'],M,23,W-2*M,10,11.0,MEDIUM)
            self.text(page,key+'-title',cover['title'],M,53,W-2*M,77,41.0,BOLD)
            self.visual(page,work,(M,146,W-2*M,72))
            self.text(page,key+'-text',cover['text'],M,244,W-2*M,18,10.0)
        else:
            self.text(page,key+'-subtitle',cover['subtitle'],M,25,W-2*M,10,10.0,MEDIUM)
            self.text(page,key+'-title',cover['title'],M,48,W-2*M,40,30.0,MEDIUM)
            self.visual(page,work,(M,103,W-2*M,80))
            self.story(key+'-source',cover['title'],cover['text'],[(page,M,207,W-2*M,52)],size=11.0,leading=15.0)

    def build(self):
        for section in self.editorial['sections']:
            getattr(self, {'profile':'profile','essay':'essay','dispatches':'dispatches','frontmatter':'frontmatter'}[section['kind']])(section)
        for cover in self.editorial['covers']:self.cover(cover)

    def validate(self):
        require(len(self.pages)==52 and len(self.visuals)==110,'The issue needs52pages and110 explicit visual placements.')
        keys=[row['key'] for row in self.visuals]
        require(len(set(keys))==110,'Every editorial visual slot must occur exactly once.')
        expected={work['key'] for s in self.editorial['sections'] for work in s['works']}|{c['visual_key'] for c in self.editorial['covers']}
        require(set(keys)==expected,'Visual placements must cover the exact finalized editorial keys.')
        require(len(self.black_pages)==16 and len(set(self.pages)-self.black_pages)==36,'Parent stock/intents must retain16black-only and36colorfaces.')
        all_text='\n'.join(row['text'] for row in self.copy_fragments)
        fragments=[]
        for section in self.editorial['sections']:
            fragments += [section['title'],section['standfirst'],*section['body']]
            for work in section['works']:fragments += [work['title'],work['caption']]
            for module in section.get('modules',[]):
                fragments.append(module['title'])
                if 'body' in module:fragments.append(module['body'])
                for item in module.get('items',[]):fragments += [item['title'],item['body']]
        for cover in self.editorial['covers']:fragments += [cover['title'],cover['subtitle'],cover['text']]
        fragments += [row['title'] for row in self.editorial['contents']]
        require(all(text in all_text for text in fragments),'Every finalized editorial fragment must be printed without trimming or substitution.')
        require(all(row['source_sha256']==hashlib.sha256(row['source'].encode()).hexdigest() for row in self.stories),'Story source hashes must cover the complete copy.')
        for number,page in self.pages.items():
            identities=[e['id'] for e in page['elements']]
            require(len(identities)==len(set(identities)),f'Duplicate page element identity on{number}.')
            for placement in page['placements']:
                if placement.get('across_pages'):
                    require(placement['across_pages']==[20,21] and all(p not in self.black_pages for p in placement['across_pages']),'Only the declared both-white reader hero may span source pages.')
                else:
                    x,y,w,h=placement['box_mm'];require(x>=M-.001 and y>=M-.001 and x+w<=W-M+.001 and y+h<=H-M+.001,'Image outside safe page area: '+placement['key'])
        self.copy_proof=dict(editorial_words=self.editorial['word_counts'],fragments=len(fragments),all_original_fragments_present=True,
                             sections=[dict(key=section['key'],title=section.get('studio') or section['title'],
                                            interior_pages=section['interior_pages'],logical_pages=section['logical_pages'],
                                            word_counts=section['word_counts'],visual_placements=len(section['works']))
                                       for section in self.editorial['sections']],
                             story_count=len(self.stories),story_source_units=sum(s['source_utf16'] for s in self.stories),
                             visual_placements=len(self.visuals),black_only_logical_pages=sorted(self.black_pages))

    def json(self):
        return dict(version=1,editorial_sha256=digest(self.editorial),copy_proof=self.copy_proof,
                    pages=list(self.pages.values()),stories=self.stories,visuals=self.visuals,
                    note='Offline plan only. Native compositor, image pixels, PDF boxes/channels and visual acceptance require the live run.')


# These are the explicit nonoptional defaults of FormCore.Typography. They
# apply only to newly generated replacement DTOs, never unrelated native art.
NATIVE_TYPOGRAPHY_DEFAULTS=dict(fontName='HelveticaNeue-Medium',tracking=0,leading=0,baseline=0,wordSpacing=0,horizontalScale=100,
    alignment='left',verticalAlignment='top',paragraphBefore=0,paragraphAfter=0,leftIndent=0,rightIndent=0,firstLineIndent=0,
    underline=False,strikethrough=False,ligatures=1,direction='natural',frameMode='area',caseTreatment='original',hyphenation=0,
    features={},variations={},pairKerning={})


def native_generated_element(element):
    value=copy.deepcopy(element)
    if value.get('stroke','absent') is None:value.pop('stroke')
    for typography in [value.get('typography')]+[span.get('typography') for span in value.get('textRuns') or []]:
        if typography is not None:
            for key,default in NATIVE_TYPOGRAPHY_DEFAULTS.items():
                if typography.get(key) is None:typography[key]=copy.deepcopy(default)
    return value


def normalize_generated_candidate(project,generated_ids):
    value=copy.deepcopy(project)
    for obj in value['objects']:
        if obj.get('artwork'):
            obj['artwork']['elements']=[native_generated_element(e) if e['id'] in generated_ids else e for e in obj['artwork']['elements']]
    return value


def remap_vector(artwork, placement, swatch_id=None, ink_color=BLACK):
    """Uniform physical fit of ordinary editable vectors; no flattened PDF/SVG copy."""
    source=copy.deepcopy(artwork.get('elements',[]) if isinstance(artwork,dict) else artwork)
    require(source,'Missing editable vector alternative for '+placement['key'])
    require(all(e.get('kind') not in ('image',) and not e.get('component') and not e.get('objectView') for e in source),
            'Artwork must contain self-contained editable vector sources: '+placement['key'])
    x,y,w,h=placement['box_mm'];source_size=artwork.get('source_size_mm',dict(x=100,y=100)) if isinstance(artwork,dict) else dict(x=100,y=100)
    sw,sh=source_size.get('x'),source_size.get('y')
    require(all(isinstance(v,(int,float)) and not isinstance(v,bool) and math.isfinite(v) and 0<v<=10000 for v in (sw,sh)),
            'Editable vector source dimensions must be finite positive physical sizes.')
    scale=min(w/sw,h/sh)
    root_id=stable(placement['key']+'-placed-vector')
    root=node('group',placement['key']+'-placed-vector',x+(w-sw*scale)/2,y+(h-sh*scale)/2,sw*scale,sh*scale,
              contentSize=dict(x=sw,y=sh))
    mask=node('rectangle',placement['key']+'-frame-mask',x,y,w,h,fillEnabled=False)
    root['clipID']=mask['id']
    ids={e['id']:stable(placement['key']+'/'+e['id']) for e in source}
    def namespace(value):
        if isinstance(value,list):return [namespace(item) for item in value]
        if not isinstance(value,dict):return value
        result={key:namespace(item) for key,item in value.items()}
        for key in ('id','listID'):
            if isinstance(value.get(key),str):result[key]=stable(placement['key']+'/'+value[key])
        return result
    output=[root]
    for original in source:
        e=namespace(original);e['id']=ids[original['id']];e['parentID']=ids.get(original.get('parentID'),root_id)
        if original.get('clipID'):e['clipID']=ids[original['clipID']]
        if swatch_id is not None:
            # A black-only alternative is actual ink geometry, not an RGB monochrome bitmap.
            require(not any(e.get(key) for key in ('gradient','shadow','paintStack','effectStack')),
                    'Process-K alternatives must use explicit contour/fill/stroke geometry: '+placement['key'])
            e['color']=ink_color;e['fillSwatchID']=swatch_id
            if e.get('kind')=='line' and not e.get('stroke'):
                e['stroke']=dict(color=ink_color,width=.5,swatchID=swatch_id)
            if e.get('stroke'):
                e['stroke']['color']=ink_color;e['stroke']['swatchID']=swatch_id
            for run in e.get('textRuns') or []:run['color']=ink_color;run['swatchID']=swatch_id
        else:
            # Full-color vector originals remain their authored colors; manifest sources
            # have no project palette identity until imported into this new project.
            e.pop('fillSwatchID',None)
            if e.get('stroke'):e['stroke'].pop('swatchID',None)
            for run in e.get('textRuns') or []:run.pop('swatchID',None)
        output.append(e)
    output.append(mask)
    return [native_generated_element(e) for e in output]


def clipped_vector_repair(project,report,plan,keys):
    require(keys and len(keys)==len(set(keys)),'Select distinct explicit vector placement keys to repair.')
    planned={p['key']:p for p in plan.visuals};recorded={p['key']:p for p in report['placements']}
    candidate=copy.deepcopy(project);objects={o['id']:o for o in candidate['objects']};changes=[]
    for key in keys:
        require(key in planned and key in recorded and recorded[key].get('actual_kind')=='vector','Only recorded vector placements can receive frame repair: '+key)
        placement=planned[key];record=recorded[key]
        require(record['box_mm']==placement['box_mm'],'The recorded frame differs from its editorial plan: '+key)
        obj=objects[record['object_id']];elements=obj['artwork']['elements'];root_id=stable(key+'-placed-vector');mask_id=stable(key+'-frame-mask')
        root=next((e for e in elements if e['id']==root_id),None)
        require(root is not None and root.get('kind')=='group' and not root.get('parentID'),'The editable placement root moved into another hierarchy: '+key)
        require(root.get('clipID') in (None,mask_id),'An existing native clip must be preserved; review this placement before repair: '+key)
        x,y,w,h=placement['box_mm'];mask=node('rectangle',key+'-frame-mask',x,y,w,h,fillEnabled=False)
        existing=next((e for e in elements if e['id']==mask_id),None)
        if existing is not None:require(existing==mask,'A native frame mask changed; refusing to overwrite it: '+key)
        before_root=copy.deepcopy(root);root['clipID']=mask_id
        if existing is None:elements.append(mask)
        changes.append(dict(key=key,object_id=obj['id'],root_id=root_id,mask_id=mask_id,box_mm=placement['box_mm'],
                            before_root=before_root,after_root=copy.deepcopy(root),added_mask=existing is None))
    # Construction touched only root.clipID and new unpainted rectangle masks.
    restored=copy.deepcopy(candidate);restored_objects={o['id']:o for o in restored['objects']}
    for change in changes:
        elements=restored_objects[change['object_id']]['artwork']['elements']
        for index,e in enumerate(elements):
            if e['id']==change['root_id']:elements[index]=change['before_root']
        if change['added_mask']:elements[:]=[e for e in elements if e['id']!=change['mask_id']]
    require(restored==project,'Frame repair would modify unrelated source data.')
    return candidate,changes


def editorial_repair_transition(editorial, revision):
    """Reconstruct only the explicitly approved caption correction's prior bytes."""
    require(revision.get('version')==1 and revision.get('key')=='room_accident_04' and revision.get('field')=='caption',
            'Unknown editorial correction; review its source explicitly.')
    current_raw=(json.dumps(editorial,ensure_ascii=False,indent=2)+'\n').encode()
    require(hashlib.sha256(current_raw).hexdigest()==revision['revised_editorial_sha256'],'Corrected editorial bytes differ from their explicit revision.')
    prior=copy.deepcopy(editorial)
    section=next(s for s in prior['sections'] if any(w['key']==revision['key'] for w in s['works']))
    work=next(w for w in section['works'] if w['key']==revision['key'])
    require(work['caption']==revision['after'],'Corrected caption no longer matches its approved revision.')
    work['caption']=revision['before'];delta=revision['word_count_after']-revision['word_count_before']
    for key in ('captions','total'):section['word_counts'][key]-=delta
    for key in ('sections','total'):prior['word_counts'][key]-=delta
    prior_raw=(json.dumps(prior,ensure_ascii=False,indent=2)+'\n').encode()
    require(hashlib.sha256(prior_raw).hexdigest()==revision['prior_editorial_sha256'],'Editorial revision changes more than its approved caption/counts.')
    require(all(a['body']==b['body'] and a.get('modules')==b.get('modules') for a,b in zip(prior['sections'],editorial['sections'])),
            'Editorial correction must preserve all body/module sources.')
    return prior


def raster_requires_fit(entry, placement):
    """Preserve explicit complete views; retain deliberate detail crops elsewhere."""
    return placement.get('image_role')=='whole-view' or len(entry.get('source_instances') or [])>=2


def raster_frame(entry, box, *, fit=False):
    x,y,width,height=box;pw=entry.get('width_px');ph=entry.get('height_px')
    require(isinstance(pw,(int,float)) and isinstance(ph,(int,float)) and pw>0 and ph>0,'Native raster dimensions are required for truthful placement.')
    if fit:
        scale=min(width/pw,height/ph);w=pw*scale;h=ph*scale
        return dict(x=x+(width-w)/2,y=y+(height-h)/2,width=w,height=h),None
    source=pw/ph;target=width/height
    crop=dict(x=(1-target/source)/2,y=0,width=target/source,height=1) if source>target else dict(x=0,y=(1-source/target)/2,width=1,height=source/target)
    return dict(x=x,y=y,width=width,height=height),crop


def owned_placement_ids(elements, record):
    by_id={e['id']:e for e in elements};ids=set(record['element_ids'])
    require(ids and ids.issubset(by_id),'A recorded placement has missing native layers: '+record['key'])
    if record['actual_kind']=='raster':
        require(len(ids)==1 and by_id[next(iter(ids))]['kind']=='image','A recorded image placement changed hierarchy: '+record['key'])
        root=by_id[next(iter(ids))]
        require(not root.get('parentID') and not root.get('clipID') and not root.get('locked'),'A native image hierarchy, clip or lock needs explicit review: '+record['key'])
    else:
        root_id=stable(record['key']+'-placed-vector');require(root_id in ids and by_id[root_id]['kind']=='group','A recorded vector root is missing.')
        require(not by_id[root_id].get('parentID') and not by_id[root_id].get('locked'),'A native vector hierarchy or lock needs explicit review: '+record['key'])
        descendants={root_id};pending=[root_id]
        while pending:
            parent=pending.pop()
            for child in elements:
                if child.get('parentID')==parent and child['id'] not in descendants:descendants.add(child['id']);pending.append(child['id'])
        # Source masks can be siblings at any level within the owned tree.
        for e in elements:
            if e['id'] in descendants and e.get('clipID'):descendants.add(e['clipID'])
        require(descendants==ids,'Unrecorded native children or detached placement layers require review: '+record['key'])
    require(not any(e['id'] not in ids and (e.get('parentID') in ids or e.get('clipID') in ids) for e in elements),
            'Other native content depends on the selected placement: '+record['key'])
    return ids


def semantic_asset_repair(project,report,plan,patch,assets,asset_names,ink_id,ink_color,revision):
    """Replace explicit subject sources, fit group photos, and retain every other source."""
    records={p['key']:p for p in report['placements']};planned={p['key']:p for p in plan.visuals}
    require(patch.get('version')==1 and patch.get('patches'),'A curated versioned semantic patch is required.')
    require(set(patch['patches']).issubset(records),'Semantic patch includes unknown editorial placement keys.')
    for key,item in patch['patches'].items():
        require(digest(records[key]['manifest_entry'])==item['prior_entry_sha256'],'Native report asset attribution changed: '+key)
        require(item['entry']==assets[key],'Revised complete manifest and per-key patch disagree: '+key)
    keys=set(patch['patches']) | {key for key,entry in assets.items() if entry.get('kind')=='raster' and raster_requires_fit(entry,planned[key]) and records[key]['logical_page'] not in plan.black_pages}
    candidate=copy.deepcopy(project);objects={o['id']:o for o in candidate['objects']};changes=[];updated=[]
    touched={}
    for key in sorted(keys):
        record=records[key];placement=planned[key];entry=assets[key];obj=objects[record['object_id']];elements=obj['artwork']['elements']
        require(record['box_mm']==placement['box_mm'],'Editorial placement frame changed: '+key)
        use_vector=record['logical_page'] in plan.black_pages or entry['kind']=='vector'
        changed=key in patch['patches'];new_record=copy.deepcopy(record)
        prior_entry=record['manifest_entry']
        if use_vector:
            old_art=prior_entry.get('black_only_artwork') if record['logical_page'] in plan.black_pages else prior_entry.get('artwork') or prior_entry.get('black_only_artwork')
            new_art=entry.get('black_only_artwork') if record['logical_page'] in plan.black_pages else entry.get('artwork') or entry.get('black_only_artwork')
            same_source=record['actual_kind']=='vector' and old_art==new_art
        else:same_source=record['actual_kind']=='raster' and prior_entry.get('sha256')==entry.get('sha256')
        needs_fit=not use_vector and raster_requires_fit(entry,placement)
        if same_source and not needs_fit:
            # A correction to a nonprinting alternative or provenance must never
            # reset a native crop/adjustment/transform of the unchanged source.
            new_record['manifest_entry']=copy.deepcopy(entry);updated.append(new_record)
            changes.append(dict(key=key,object_id=obj['id'],reason=patch['patches'][key]['reason'],old_ids=record['element_ids'],new_ids=record['element_ids'],semantic_replacement=changed,source_changed=False))
            continue
        old_ids=owned_placement_ids(elements,record);old_elements=[copy.deepcopy(e) for e in elements if e['id'] in old_ids]
        old_first=min(i for i,e in enumerate(elements) if e['id'] in old_ids)
        if use_vector:
            artwork=entry.get('black_only_artwork') if record['logical_page'] in plan.black_pages else entry.get('artwork') or entry.get('black_only_artwork')
            replacement=remap_vector(artwork,placement,ink_id if record['logical_page'] in plan.black_pages else None,ink_color)
            new_record['source_artwork_sha256']=digest(artwork)
            for name in ('original_path','original_sha256','project_asset','native_image_info'):new_record.pop(name,None)
        else:
            require(entry['sha256'] in asset_names,'Missing staged project-owned raster: '+key)
            fit=raster_requires_fit(entry,placement);frame,crop=raster_frame(entry,placement['box_mm'],fit=fit)
            if record['actual_kind']=='raster':image=copy.deepcopy(old_elements[0])
            else:image=node('image',key+'-placed-image',**frame,color='#FFFFFF');image['name']='VARIOUS / '+key
            image.update(frame);image['asset']=asset_names[entry['sha256']]
            if crop is None:image.pop('imageCrop',None)
            else:image['imageCrop']=crop
            replacement=[image]
            new_record.update(original_path=entry['path'],original_sha256=entry['sha256'],project_asset=image['asset'],image_placement='fit' if fit else 'fill',actual_frame_mm=[frame[k] for k in ('x','y','width','height')])
            new_record.pop('source_artwork_sha256',None);new_record.pop('native_image_info',None)
        old_root=next(e for e in old_elements if not e.get('parentID') and (record['actual_kind']=='raster' or e['id']==stable(key+'-placed-vector')))
        for property_name in ('name','rotation','affine','opacity','blendMode','hidden','shadow','blur','effectStack'):
            if property_name in old_root:replacement[0][property_name]=copy.deepcopy(old_root[property_name])
        new_ids={e['id'] for e in replacement}
        require(not new_ids.intersection({e['id'] for e in elements}-old_ids),'Replacement collides with unrelated native layer identities: '+key)
        remaining=[e for e in elements if e['id'] not in old_ids]
        # Preserve all unrelated native layers and their order; replace at the old root slot.
        insert_at=sum(1 for e in elements[:old_first] if e['id'] not in old_ids)
        elements[:]=remaining[:insert_at]+replacement+remaining[insert_at:]
        touched.setdefault(obj['id'],dict(old=set(),new=set()))['old'].update(old_ids);touched[obj['id']]['new'].update(new_ids)
        new_record.update(manifest_entry=copy.deepcopy(entry),actual_kind='vector' if use_vector else 'raster',element_ids=[e['id'] for e in replacement])
        updated.append(new_record);changes.append(dict(key=key,object_id=obj['id'],reason=patch['patches'][key]['reason'] if changed else 'Keep the complete native whole view or multiview group visible without cropping.',old_ids=sorted(old_ids),new_ids=sorted(new_ids),semantic_replacement=changed,source_changed=old_elements!=replacement,image_placement=new_record.get('image_placement')))
    # Only this factual caption changes. Rich chapter/story sources stay byte-identical.
    key=revision['key'];placement=planned[key];obj=objects[records[key]['object_id']];caption_id=stable(key+'-caption')
    caption=next(e for e in obj['artwork']['elements'] if e['id']==caption_id)
    expected=placement['title']+'\n'+revision['before'];replacement=placement['title']+'\n'+revision['after']
    require(caption['text']==expected and not caption.get('textRuns'),'The native caption was edited; refusing to overwrite it.')
    caption['text']=replacement
    # Strip only explicitly replaced placement trees and the one approved text
    # change, then compare the ENTIRE original source, including native edits.
    before=copy.deepcopy(project);after=copy.deepcopy(candidate)
    for value,which in ((before,'old'),(after,'new')):
        for obj in value['objects']:
            if obj['id'] in touched:obj['artwork']['elements']=[e for e in obj['artwork']['elements'] if e['id'] not in touched[obj['id']][which]]
            if obj['id']==records[key]['object_id']:
                next(e for e in obj['artwork']['elements'] if e['id']==caption_id)['text']=expected
    require(before==after,'Semantic repair would change unrelated canonical source.')
    changed_record={p['key']:p for p in updated}
    all_records=[changed_record.get(p['key'],copy.deepcopy(p)) for p in report['placements']]
    next(p for p in all_records if p['key']==key)['caption']=revision['after']
    proof=dict(placements=changes,caption=dict(key=key,element_id=caption_id,before=expected,after=replacement),
               preservation='Only explicitly patched placement-owned layers, aspect-fit group-photo frames, and the single approved caption differ; all other source, original chapter text, story/frame IDs, captions and native edits retain exact values.')
    return candidate,all_records,proof


def projection_note_repair(project,diagnostics):
    message='Text is overset or wider than its frame. Add capacity before physical output.'
    targets={(issue['object_id'],issue['element_id']) for report in diagnostics for issue in report.get('issues',[])
             if issue.get('severity')=='error' and issue.get('message')==message}
    require(targets,'Native ink diagnostics contain no overset annotations to repair.')
    candidate=copy.deepcopy(project);objects={obj['id']:obj for obj in candidate['objects']};changes=[]
    for object_id,element_id in sorted(targets):
        require(object_id in objects,'An ink diagnostic belongs to an unknown page.')
        element=next((e for e in objects[object_id]['artwork']['elements'] if e['id']==element_id),None)
        require(element is not None and element['kind']=='text' and element.get('name','').endswith('/projection-note'),
                'Overset diagnostic is not a local source-derived projection annotation; review it explicitly.')
        require(element.get('fontSize')==12 and element.get('width')==90 and element.get('height')==6 and not element.get('textRuns')
                and math.isclose(element.get('typography',{}).get('leading',0),13.92,abs_tol=1e-10),
                'Projection note changed since its native fit diagnosis.')
        require(element['text'] in ('PARAMETER WIREFRAME / BEVELS OMITTED','WINDOW REFERENCE / TOP LIMB SECTION'),
                'Only the two natively diagnosed long annotation strings are authorized.')
        before=copy.deepcopy(element);element['fontSize']=10;element['typography']['leading']=11.6
        changes.append(dict(object_id=object_id,element_id=element_id,before=before,after=copy.deepcopy(element)))
    restored=copy.deepcopy(candidate);restored_objects={obj['id']:obj for obj in restored['objects']}
    for change in changes:
        elements=restored_objects[change['object_id']]['artwork']['elements']
        elements[elements.index(next(e for e in elements if e['id']==change['element_id']))]=change['before']
    require(restored==project,'Projection-note fit would alter unrelated source.')
    return candidate,changes


def source_without_history(project):
    return {key:value for key,value in project.items() if key not in ('history','updatedAt','camera')}


def verify_recorded_semantic_batch(before,after,operations,proof,expected):
    generated={identity for change in proof['placements'] if change['source_changed'] for identity in change['new_ids']}
    affected={change['object_id'] for change in proof['placements'] if change['source_changed']}
    caption_id=proof['caption']['element_id']
    affected.update(obj['id'] for obj in before['objects'] if any(e['id']==caption_id for e in (obj.get('artwork') or {}).get('elements',[])))
    require(operations and all(op.get('name')=='form_set_artwork' and set(op.get('arguments',{}))=={'object_id','artwork'} for op in operations),
            'Recorded semantic batch contains an unapproved operation.')
    identities=[op['arguments']['object_id'] for op in operations]
    require(len(set(identities))==len(identities) and set(identities)==affected,'Recorded semantic batch page ownership differs from its explicit repair.')
    recorded=copy.deepcopy(before);objects={obj['id']:obj for obj in recorded['objects']}
    for operation in operations:objects[operation['arguments']['object_id']]['artwork']=copy.deepcopy(operation['arguments']['artwork'])
    normalized=normalize_generated_candidate(recorded,generated)
    require(source_without_history(normalized)==source_without_history(expected),
            'Recorded public batch differs beyond typed defaults of explicitly generated owned layers.')
    require(source_without_history(after)==source_without_history(expected),
            'Applied native source differs beyond the exact typed expected repair; unrelated changes are never normalized.')
    return dict(generated_layer_count=len(generated),before_sha256=digest(canonical(before)),after_sha256=digest(canonical(after)),
                normalization='Only generated-owned Typography nonoptional Codable defaults and absent optional null strokes; all other authoring source compares exactly.')


class MagazineAuthor:
    def __init__(self,args,plan,resume=None):
        self.args=args;self.plan=plan;self.resuming=False;self.repairing=False;self.semantic_phase=None;self.output=args.output.resolve()
        require(not self.output.exists() or not any(self.output.iterdir()),'Choose a fresh empty evidence folder; existing outputs are never replaced.')
        self.output.mkdir(parents=True,exist_ok=True)
        self.library=args.library.resolve();app=args.app.resolve()
        self.library_scope=verify_library_scope(self.library,verified_existing=getattr(args,'verified_existing_project_library',False),resume=resume,
                                                project_id=getattr(args,'project_id',None),expected_source_hash=getattr(args,'expected_source_sha256',None))
        require(Path(args.socket).exists() and stat.S_ISSOCK(os.stat(args.socket).st_mode),'The supplied native socket must already exist; this script never launches LAB.')
        self.session=Session(app,args.socket,self.output)
        require(self.session.helper.is_file(),'The supplied ordinary app must include its packaged lab-mcp helper.')
        running=subprocess.run(['ps','-axo','command='],capture_output=True,text=True,check=True).stdout.splitlines()
        binary=str(app/'Contents/MacOS/LAB')
        require(any(line.strip()==binary or line.strip().startswith(binary+' ') for line in running),'The supplied ordinary LAB binary must already be running.')
        self.session.env.update(LAB_LIBRARY_PATH=str(self.library),FORM_LIBRARY_PATH=str(self.library),FORM_SOCKET_PATH=args.socket)
        status=self.call('form_status');require(Path(status['library_path']).resolve()==self.library,'Socket/library mismatch; no project was authored.')
        self.manifest_path=args.assets.resolve();self.manifest=json.loads(self.manifest_path.read_text())
        self.assets=self.manifest['assets']
        if isinstance(self.assets,list):self.assets={row['key']:row for row in self.assets}
        require(set(row['key'] for row in plan.visuals).issubset(self.assets),'Visual manifest is missing required editorial keys.')
        for placement in plan.visuals:
            entry=self.assets[placement['key']]
            require(entry.get('kind') in ('raster','vector'),'Unknown visual manifest kind: '+placement['key'])
            if placement['logical_page'] in plan.black_pages:
                require(bool(entry.get('black_only_artwork')),'Missing editable K-only alternative: '+placement['key'])
            elif entry['kind']=='raster':
                self.asset_path(entry)
            else:
                require(bool(entry.get('artwork')),'Missing full-color vector source: '+placement['key'])
        self.report=dict(version=1,project_id=None,publication_id=None,page_ids=[],app=str(app),app_sha256=sha(app/'Contents/MacOS/LAB'),
                         library=str(self.library),library_scope=self.library_scope,socket=args.socket,editorial=str(args.editorial.resolve()),editorial_sha256=sha(args.editorial),
                         visual_manifest=str(self.manifest_path),visual_manifest_sha256=sha(self.manifest_path),
                         copy_proof=plan.copy_proof,stories=[],placements=[],scenes=[],exports=[],checks=[],passed=False,
                         limitations=['Generic OS CMYK is a profile-pinned digital conversion study, not a calibrated press profile.',
                                      'Digital material/binding geometry and screen appearance do not establish a manufactured binding or measured press proof.'])
        self.page_ids={};self.object_cache={};self.profile=None;self.ink=None;self.ink_color=BLACK
        self.write('layout-plan.json',plan.json())
        if resume:self.adopt_resume(*resume)
        else:self.save()

    def adopt_resume(self,report_path,snapshot_path,expected_source_hash):
        report_path=Path(report_path).resolve();snapshot_path=Path(snapshot_path).resolve()
        raw_report=report_path.read_bytes();raw_snapshot=snapshot_path.read_bytes()
        report=json.loads(raw_report);snapshot=json.loads(raw_snapshot)
        app_update=verify_resume_app(report,self.args.app,self.args.expected_app_sha256)
        library_transition=dict(prior_library=str(Path(report['library']).resolve()),library=str(self.library),prior_socket=report.get('socket'),socket=self.args.socket,
                                verified_existing_project=getattr(self.args,'verified_existing_project_library',False))
        if Path(report['library']).resolve()!=self.library:
            require(getattr(self.args,'verified_existing_project_library',False) and self.library_scope=='verified_existing_project',
                    'Moving a completed source into the normal library requires explicit verified-existing-project access.')
        require(sha(self.manifest_path)==report['visual_manifest_sha256'],'Resume actual-asset manifest hash has changed.')
        if sha(self.args.editorial)!=report['editorial_sha256']:
            require(getattr(self.args,'repair_semantic_assets',None) or getattr(self.args,'finalize_semantic_repair',None),'Resume editorial source changed without an explicit approved semantic repair.')
            revision=json.loads(self.args.editorial.with_name('editorial-revision.json').read_text())
            prior_editorial=editorial_repair_transition(self.plan.editorial,revision)
            require(hashlib.sha256((json.dumps(prior_editorial,ensure_ascii=False,indent=2)+'\n').encode()).hexdigest()==report['editorial_sha256'],
                    'Approved caption transition does not match the native report editorial hash.')
        baseline=verify_resume_source(report,snapshot,self.plan,self.args.project_id,expected_source_hash)
        current=self.project()
        require(current['id']==self.args.project_id and digest(canonical(current))==baseline,
                'The currently open native project/source differs from the explicit verified resume snapshot; no authoring or export was attempted.')
        if self.library_scope=='verified_existing_project':
            require(all(current.get(key)==snapshot.get(key) for key in ('materials','recipes','unit','fontLibrary')),
                    'Imported existing-project material, recipe, units or font sources differ from the pinned public snapshot.')
        # Never overwrite the failed round. Preserve its exact bytes in the fresh
        # resume folder before replacing this runner's separate checkpoint.
        (self.output/'prior-magazine-report.json').write_bytes(raw_report)
        (self.output/'prior-source-snapshot.json').write_bytes(raw_snapshot)
        self.report=copy.deepcopy(report)
        self.report['canonical_source_sha256']=baseline
        self.report.setdefault('resume_runs',[]).append(dict(mode='projection_note_repair' if getattr(self.args,'repair_projection_notes',None) else 'semantic_finalize' if getattr(self.args,'finalize_semantic_repair',None) else 'semantic_asset_repair' if getattr(self.args,'repair_semantic_assets',None) else 'vector_frame_repair' if self.args.repair_vector_frames else 'verify_export_only',prior_report=str(report_path),
            prior_report_sha256=hashlib.sha256(raw_report).hexdigest(),snapshot=str(snapshot_path),
            snapshot_sha256=hashlib.sha256(raw_snapshot).hexdigest(),canonical_source_sha256=baseline,
            project_id=self.args.project_id,prior_error=report.get('error'),app_update=app_update,library_transition=library_transition))
        self.report.setdefault('authoring_app',dict(app=report['app'],app_sha256=report['app_sha256']))
        self.report['app']=app_update['app'];self.report['app_sha256']=app_update['app_sha256']
        self.report.setdefault('authoring_library',report['library']);self.report['library']=str(self.library);self.report['library_scope']=self.library_scope;self.report['socket']=self.args.socket
        self.report.pop('error',None);self.report['passed']=False
        self.pub=self.report['publication_id'];self.page_ids=dict(enumerate(self.report['page_ids'],1))
        self.ink=self.report['print_ink']['id'];self.ink_color=self.report['print_ink']['color'];self.profile=self.report['output_profile']['portable']
        self.resuming=True;self.save()

    def call(self,tool,**arguments):
        if self.resuming:
            allowed=tool in ('form_get_project','form_status','form_export_publication','form_export') or (tool=='form_publication' and arguments.get('command') in ('get','spreads','preflight')) or (tool=='form_story' and arguments.get('command') in ('get','layout')) or (tool=='form_open_project' and arguments.get('project_id')==self.report['project_id'])
            if getattr(self,'repairing',False) and tool=='form_batch' and arguments.get('operations')==self._repair_operations:allowed=True
            phase=getattr(self,'semantic_phase',None)
            if phase=='stage' and tool=='form_import_image' and arguments==self._staging_arguments:allowed=True
            if phase in ('undo_stage','undo_final') and tool=='form_undo' and not arguments:allowed=True
            if phase=='redo_final' and tool=='form_redo' and not arguments:allowed=True
            if phase=='apply' and tool=='form_batch' and arguments.get('operations')==self._semantic_operations:allowed=True
            require(allowed,'Verify/export resume refuses authoring command: '+tool)
        encoded=json.dumps(arguments,separators=(',',':'),ensure_ascii=False).encode()
        require(len(encoded)<8*1024*1024-1024,'A public tool payload exceeds the existing 8 MiB bridge budget: '+tool)
        return self.session.call(tool,arguments)

    def write(self,name,value):
        path=self.output/name;require(not path.exists(),'Refusing to replace output: '+str(path))
        path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(value,indent=2,ensure_ascii=False)+'\n')

    def save(self):
        # This runner owns its checkpoint; exported assets/PDFs are exclusively created.
        path=self.output/'magazine-report.json';tmp=self.output/'magazine-report.json.tmp'
        tmp.write_text(json.dumps(self.report,indent=2,ensure_ascii=False)+'\n');tmp.replace(path)

    def check(self,name,condition,**evidence):
        require(condition,name);self.report['checks'].append(dict(name=name,passed=True,**evidence));self.save()

    def project(self):return self.call('form_get_project')

    def batch(self,operations):
        chunk=[];size=0
        for operation in operations:
            n=len(json.dumps(operation,ensure_ascii=False).encode())
            require(n<180_000,'One artwork operation is too large for public helper argv.')
            if chunk and (len(chunk)>=12 or size+n>180_000):
                self.call('form_batch',operations=chunk);chunk=[];size=0
            chunk.append(operation);size+=n
        if chunk:self.call('form_batch',operations=chunk)

    def add_source(self,name,width,height,artwork):
        value=self.call('form_add_object',recipe_id='artboard',name=name,parameters=dict(width=width,depth=height))
        identity=value.get('id') or value.get('object_id');require(identity,'Native source creation returned no UUID.')
        self.call('form_set_artwork',object_id=identity,artwork=artwork);return identity

    def appearance(self,e):
        e=copy.deepcopy(e);e['color']=self.ink_color;e['fillSwatchID']=self.ink
        if e.get('kind')=='line' and not e.get('stroke'):e['stroke']=dict(color=self.ink_color,width=.5,swatchID=self.ink)
        if e.get('stroke'):e['stroke'].update(color=self.ink_color,swatchID=self.ink)
        for run in e.get('textRuns') or []:run.update(color=self.ink_color,swatchID=self.ink)
        return e

    def artwork(self,elements,position=None):
        value=dict(background='#FFFFFF',backgroundOpacity=0,bleed=0,unit='mm',showGuides=False,snapEnabled=False,safeInset=M,
                   elements=[self.appearance(e) for e in elements])
        if self.profile:value['outputColorProfile']=copy.deepcopy(self.profile)
        if position:value['canvasPosition']=dict(zip(('x','y'),position))
        return value

    def configure_ink(self):
        profiles=self.call('form_color_profile',command='list')['profiles']
        candidates=[p for p in profiles if p.get('model')=='CMYK']
        require(candidates,'Install a local CMYK ICC profile before this digital proof; no profile is invented.')
        candidates.sort(key=lambda p:(('generic' not in p['name'].lower()),p['name'],p['path']))
        chosen=next((p for p in candidates if self.args.profile and Path(p['path']).resolve()==self.args.profile.resolve()),None) if self.args.profile else candidates[0]
        if self.args.profile:require(chosen is not None,'Explicit ICC profile must be an installed CMYK profile.')
        summary=self.call('form_color_profile',command='set',object_id=self.page_ids[1],profile_path=chosen['path'])
        self.profile=summary['pdf_output_profile'];require(self.profile and self.profile['model']=='CMYK','Native ICC import did not retain its profile identity.')
        ink=dict(kind='process_cmyk',components=dict(cyan=0.0,magenta=0.0,yellow=0.0,black=1.0),profile=self.profile,tint=1.0)
        swatch=self.call('form_swatch',command='create',name='VARIOUS / Process K / 100%',color=BLACK,print_ink=ink)['swatch']
        self.ink=swatch['id'];self.ink_color=swatch['color']
        self.report['print_ink']=swatch;self.report['output_profile']=dict(installed=chosen,portable=self.profile,calibrated_press=False);self.save()

    def author_pages(self):
        project=self.call('form_create_project',name='VARIOUS / 01 / Small adjustments',template='blank')
        self.report['project_id']=project['id'];self.save()
        publication=self.call('form_publication',command='create',name='VARIOUS / Issue 01',page_ids=[],language='en',
                              margins=dict(top=M,right=M,bottom=M,left=M),layout=dict(facingPages=True,firstPageSide='recto',innerMargin=M,outerMargin=M),
                              numbering=dict(start=1,style='arabic',prefix='',suffix=''))
        self.pub=publication['publication_id'];self.report['publication_id']=self.pub
        ids=self.call('form_publication',command='create_pages',publication_id=self.pub,count=52,width=W,height=H,columns=1,gutter=8)['page_ids']
        self.page_ids=dict(enumerate(ids,1));self.report['page_ids']=ids;self.save();self.configure_ink()
        operations=[]
        section_titles={s['key']:s.get('studio') or s['title'] for s in self.plan.editorial['sections']}
        for number,page in self.plan.pages.items():
            identity=self.page_ids[number]
            label=f'{number-2:02d}' if 3<=number<=50 else {1:'Front cover',2:'Inside front cover',51:'Inside back cover',52:'Back cover'}[number]
            title=f"VARIOUS / {label} / {page['section'].replace('_',' ')}"
            art=self.artwork(page['elements'],position=((number-1)*(W+40),0))
            operations.append(dict(name='form_update_object',arguments=dict(object_id=identity,name=title)))
            operations.append(dict(name='form_set_artwork',arguments=dict(object_id=identity,artwork=art)))
            settings=dict(command='page_settings',publication_id=self.pub,page_id=identity,label=label,chapter_title=section_titles.get(page['section'],label))
            if 3<=number<=50:settings['number_override']=number-2
            else:settings['master_ids']=[]
            operations.append(dict(name='form_publication',arguments=settings))
        self.batch(operations)
        self.author_masters()

    def author_masters(self):
        sources=[];definitions=[]
        for side in ('verso','recto'):
            label_x=M if side=='verso' else W-M-14
            title_x=M+22 if side=='verso' else M
            elements=[node('text','master-'+side+'-folio',label_x,H-11,14,6,'{{page.number}}',8.0,MEDIUM),
                      node('text','master-'+side+'-issue',title_x,H-11,W-2*M-22,6,'VARIOUS / 01 — {{chapter.title}}',7.0)]
            identity=self.add_source('VARIOUS / '+side.title()+' running furniture',W,H,self.artwork(elements,(-2*W-80,0 if side=='verso' else H+50)))
            sources.append(identity);definitions.append(dict(id=stable('master-'+side),name=side.title()+' / folio and running section',sourceObjectID=identity,x=0,y=0,side=side,behind=False))
        self.call('form_publication',command='settings',publication_id=self.pub,masters=definitions)
        self.report['master_source_ids']=sources;self.save()

    def author_stories(self):
        styles={}
        for spec in self.plan.stories:
            signature=(spec['size'],spec['leading'])
            if signature not in styles:
                style=self.call('form_text_style',command='create',name=f'VARIOUS / Body {spec["size"]:g} / {spec["leading"]:g}',
                                font_size=spec['size'],typography=typography(spec['size'],leading=spec['leading']))['style']
                styles[signature]=style['id']
            frames=[dict(object_id=self.page_ids[f['logical_page']],element_id=f['element_id']) for f in spec['frames']]
            result=self.call('form_story',command='create',publication_id=self.pub,name=spec['name'],frames=frames)
            identity=result['story_id']
            self.call('form_story',command='replace_text',story_id=identity,location=0,length=0,text=spec['source'])
            source=self.call('form_story',command='get',story_id=identity)['source']
            source.update(color=self.ink_color,fillSwatchID=self.ink,textStyle=dict(styleID=styles[signature]),fontSize=spec['size'],
                          typography=typography(spec['size'],leading=spec['leading']))
            self.call('form_story',command='edit',story_id=identity,source=source)
            attempts=[]
            # Frame reserves were designed for complete copy. Font calibration is bounded/readable;
            # rejected fits retain every word and stop rather than cut editorial paragraphs.
            for step in range(6):
                layout=self.call('form_story',command='layout',story_id=identity)
                if layout['overset_length']==0:break
                size=round(spec['size']-.25*(step+1),2)
                require(size>=spec['minimum_size'],'Complete copy needs a larger authored frame reserve: '+spec['key'])
                source=self.call('form_story',command='get',story_id=identity)['source']
                source.pop('textStyle',None);source['fontSize']=size;source['typography']=typography(size,leading=round(spec['leading']*size/spec['size'],6))
                self.call('form_story',command='edit',story_id=identity,source=source)
                attempts.append(dict(font_size=size,reason='Fit complete original copy within reserved physical columns; no words removed.'))
            else:layout=self.call('form_story',command='layout',story_id=identity)
            actual=self.call('form_story',command='get',story_id=identity)['source']
            self.check('Complete story / '+spec['key'],actual['text']==spec['source'] and layout['overset_length']==0,
                       source_sha256=spec['source_sha256'],source_units=spec['source_utf16'],layout=layout)
            self.report['stories'].append(dict(key=spec['key'],story_id=identity,frames=frames,source_sha256=spec['source_sha256'],
                                                source_utf16=spec['source_utf16'],layout=layout,fit_adjustments=attempts));self.save()

    def asset_path(self,entry):
        path=Path(entry['path']);path=path if path.is_absolute() else self.manifest_path.parent/path
        path=path.resolve();require(path.is_file(),'Missing actual rendered visual: '+str(path))
        if entry.get('sha256'):require(sha(path)==entry['sha256'],'Rendered asset hash mismatch: '+str(path))
        return path

    def author_visuals(self):
        for placement in self.plan.visuals:
            entry=self.assets[placement['key']];number=placement['logical_page'];object_id=self.page_ids[number]
            use_vector=number in self.plan.black_pages or entry['kind']=='vector'
            record=copy.deepcopy(placement);record.update(object_id=object_id,manifest_entry=entry,actual_kind='vector' if use_vector else 'raster')
            if use_vector:
                artwork=entry.get('black_only_artwork') if number in self.plan.black_pages else entry.get('artwork') or entry.get('black_only_artwork')
                elements=remap_vector(artwork,placement,self.ink if number in self.plan.black_pages else None,self.ink_color)
                self.call('form_edit_artwork',command='add',object_id=object_id,elements=elements)
                record['element_ids']=[e['id'] for e in elements]
                record['source_artwork_sha256']=digest(artwork)
            else:
                path=self.asset_path(entry);fit=raster_requires_fit(entry,placement)
                frame,_=raster_frame(entry,placement['box_mm'],fit=fit)
                result=self.call('form_import_image',object_id=object_id,path=str(path),**frame,name='VARIOUS / '+placement['key'])
                record.update(element_ids=result['selected_elements'],original_path=str(path),original_sha256=sha(path),project_asset=result['asset'],image_placement='fit' if fit else 'fill',actual_frame_mm=[frame[k] for k in ('x','y','width','height')])
                if placement.get('crop'):
                    self.call('form_edit_image',object_id=object_id,element_ids=result['selected_elements'],crop=placement['crop'])
                record['native_image_info']=self.call('form_image_info',object_id=object_id,element_ids=result['selected_elements'])
            self.report['placements'].append(record);self.save()
        self.check('110 original editorial visual slots authored',len(self.report['placements'])==110)
        hero=next(p for p in self.report['placements'] if p.get('across_pages'))
        self.check('One canonical color image crosses the both-white Style01 gutter',hero['logical_page']==20 and hero['across_pages']==[20,21] and hero['actual_kind']=='raster' and len(hero['element_ids'])==1,hero=hero)

    def physical_and_scenes(self):
        document=self.call('form_publication',command='get',publication_id=self.pub)
        definition,plan=assembly_definition(document)
        physical=self.call('form_publication',command='sheet_assembly_create',publication_id=self.pub,
                           name='VARIOUS / 13 folded parents / linked source',position=[0,0,0],definition=definition)
        object_id=physical['object_id'];self.report['physical']=dict(object_id=object_id,definition=definition,plan=plan);self.save()
        before=canonical(self.project())
        cases=[('VARIOUS / Four independent reader positions',[(0,0,'Closed / front cover',-255,-177),(180,6,'Fold Bureau / open',245,-177),
                (180,10,'Style01 / cross-gutter',-255,177),(135,18,'Soft Registry / open',245,177)]),
               ('VARIOUS / Binding comparison',[(155,10,'Saddle stitch',-255,0),(155,10,'Side staples',245,0)])]
        for name,poses in cases:
            scene=self.call('form_studio_scene',command='create',name=name)
            instances=[]
            for index,(angle,spread,title,x,z) in enumerate(poses):
                binding='sideStaple' if title=='Side staples' else 'saddleStitch'
                instances.append(dict(id=stable(name+f'-instance-{index}'),name=title,sourceObjectID=object_id,visible=True,
                                      positionMM=dict(x=x,y=0,z=z),rotationDegrees=0,
                                      sheetPose=dict(openingDegrees=angle,activeSpread=spread,bendMM=1.5 if angle else 0,bindingStyle=binding)))
            points=[[x,y,z] for x in (-510,510) for y in (0,240) for z in (-335,335)]
            scene.update(instances=instances,camera=camera(points,[.18,1,.42],margin=1.12,aspect=1.5),
                         pixels=dict(width=2400,height=1600),lighting='soft-side-v1',surface='Daylight')
            saved=self.call('form_studio_scene',command='save',scene=scene);self.report['scenes'].append(saved);self.save()
        after=canonical(self.project());before.pop('studioPresentation');after.pop('studioPresentation')
        self.check('Independent Studio poses preserve canonical pages, physical stock and binding',before==after)
        self.check('Three different open positions and closed copy share one source',len(self.report['scenes'][0]['instances'])==4 and
                   len({i['sheetPose']['activeSpread'] for i in self.report['scenes'][0]['instances'] if i['sheetPose']['openingDegrees']>0})==3)

    def repair_semantic_assets(self):
        require(self.resuming,'Semantic repair requires an explicit guarded completed-project resume.')
        patch_path=self.args.repair_semantic_assets.resolve();patch=json.loads(patch_path.read_text())
        require(patch['source_manifest_sha256']==self.report['visual_manifest_sha256'] and sha(Path(patch['source_manifest_path']))==patch['source_manifest_sha256'],
                'Curated patch does not target the exact currently authored manifest.')
        revised_path=Path(patch['revised_manifest_path']).resolve()
        require(sha(revised_path)==patch['revised_manifest_sha256'],'Revised manifest byte hash mismatch.')
        revised=json.loads(revised_path.read_text());assets=revised['assets']
        require(isinstance(assets,dict) and set(assets)==set(self.assets),'Revised manifest must retain all110exact editorial keys.')
        for key,entry in assets.items():
            if entry!=self.assets[key]:require(key in patch['patches'],'An undeclared manifest entry changed: '+key)
        revision=json.loads(self.args.editorial.with_name('editorial-revision.json').read_text())
        editorial_repair_transition(self.plan.editorial,revision)
        before=self.project()
        require(digest(canonical(before))==self.report['resume_runs'][-1]['canonical_source_sha256'],'Canonical source changed after the guarded resume; no staging or semantic edit attempted.')
        self.write('semantic-repair-before.json',before)
        objects={o['id']:o for o in before['objects']};asset_names={}
        for record in self.report['placements']:
            if record['actual_kind']=='raster':
                image=next(e for e in objects[record['object_id']]['artwork']['elements'] if e['id']==record['element_ids'][0])
                require(image.get('asset')==record['project_asset'],'A native raster reference changed; review attribution before repair.')
                asset_names[record['original_sha256']]=record['project_asset']
        needed={entry['sha256']:entry for key,entry in assets.items() if key in patch['patches'] and entry['kind']=='raster' and next(p['logical_page'] for p in self.report['placements'] if p['key']==key) not in self.plan.black_pages}
        for checksum,entry in needed.items():
            path=Path(entry['path']).resolve();require(path.is_file() and sha(path)==checksum,'Revised native PNG bytes are missing or changed.')
        provisional=dict(asset_names)
        for checksum in needed:provisional.setdefault(checksum,stable('staged-'+checksum)+'.png')
        # Ownership, every per-entry digest, the one caption and all unrelated
        # native source are checked before even reversible public asset staging.
        semantic_asset_repair(before,self.report,self.plan,patch,assets,provisional,self.ink,self.ink_color,revision)
        target=next(record for record in self.report['placements'] if record['actual_kind']=='raster')
        for index,(checksum,entry) in enumerate(sorted(needed.items())):
            path=Path(entry['path']).resolve()
            if checksum in asset_names:continue
            self.write(f'semantic-stage-{index}-before.json',before)
            self._staging_arguments=dict(object_id=target['object_id'],element_id=target['element_ids'][0],path=str(path))
            self.semantic_phase='stage'
            try:result=self.call('form_import_image',**self._staging_arguments)
            finally:self.semantic_phase=None
            self.semantic_phase='undo_stage'
            try:self.call('form_undo')
            finally:self.semantic_phase=None
            restored=self.project();self.write(f'semantic-stage-{index}-restored.json',restored)
            require(canonical(restored)==canonical(before),'Immutable asset staging failed to restore the exact canonical publication; stop and inspect.')
            require(isinstance(result.get('asset'),str),'Public import did not return a project-owned asset identity.')
            asset_names[checksum]=result['asset']
            self.report.setdefault('semantic_asset_staging',[]).append(dict(source_sha256=checksum,path=str(path),project_asset=result['asset'],target_object_id=target['object_id'],target_element_id=target['element_ids'][0],canonical_restored_sha256=digest(canonical(restored))))
            self.save()
        candidate,records,proof=semantic_asset_repair(before,self.report,self.plan,patch,assets,asset_names,self.ink,self.ink_color,revision)
        affected={p['object_id'] for p in proof['placements'] if p['source_changed']}|{next(p['object_id'] for p in self.report['placements'] if p['key']==revision['key'])}
        candidate_objects={o['id']:o for o in candidate['objects']}
        self._semantic_operations=[dict(name='form_set_artwork',arguments=dict(object_id=i,artwork=candidate_objects[i]['artwork'])) for i in sorted(affected)]
        require(0<len(self._semantic_operations)<=100,'Semantic source repair must remain one public atomic batch.')
        self.write('semantic-repair-plan.json',dict(proof=proof,operations=len(self._semantic_operations),patch_path=str(patch_path),patch_sha256=sha(patch_path)))
        self.semantic_phase='apply'
        try:self.call('form_batch',operations=self._semantic_operations)
        finally:self.semantic_phase=None
        after=self.project();self.write('semantic-repair-after.json',after)
        self.report['canonical_source_sha256']=digest(canonical(after));self.save()
        require(canonical(after)==canonical(candidate),'Native semantic repair differs beyond the explicit reviewed sources.')
        self.finish_semantic_repair(before,after,records,proof,patch,revised_path,revised,revision)

    def repair_projection_notes(self):
        require(self.resuming,'Projection-note repair requires a guarded existing-project resume.')
        before=self.project();require(digest(canonical(before))==self.args.expected_source_sha256,'Source changed before annotation repair.')
        folder=self.args.repair_projection_notes.resolve();files=sorted(folder.glob('logical-*.json'))
        require(len(files)==16,'Retain all16native black-page diagnostics before this bounded repair.')
        diagnostics=[json.loads(path.read_text()) for path in files]
        candidate,changes=projection_note_repair(before,diagnostics)
        require(len(changes)==7,'Expected exactly the seven confirmed overset projection notes; inspect any different scope.')
        grouped={}
        for change in changes:grouped.setdefault(change['object_id'],[]).append(change['after'])
        self._semantic_operations=[dict(name='form_edit_artwork',arguments=dict(command='replace',object_id=identity,elements=elements)) for identity,elements in sorted(grouped.items())]
        self.write('projection-note-before.json',before)
        self.write('projection-note-plan.json',dict(changes=changes,diagnostics=[dict(path=str(path),sha256=sha(path)) for path in files],operations=len(self._semantic_operations)))
        self.semantic_phase='apply'
        try:self.call('form_batch',operations=self._semantic_operations)
        finally:self.semantic_phase=None
        after=self.project();self.write('projection-note-after.json',after)
        self.report['canonical_source_sha256']=digest(canonical(after));self.save()
        require(source_without_history(after)==source_without_history(candidate),'Annotation repair changed more than the fourteen approved numeric fields.')
        self.semantic_phase='undo_final'
        try:self.call('form_undo')
        finally:self.semantic_phase=None
        undone=self.project();self.write('projection-note-undone.json',undone)
        require(canonical(undone)==canonical(before),'Annotation repair must restore exact source in one Undo.')
        self.semantic_phase='redo_final'
        try:self.call('form_redo')
        finally:self.semantic_phase=None
        redone=self.project();self.write('projection-note-redone.json',redone)
        require(canonical(redone)==canonical(after),'Annotation repair Redo differs from its accepted source.')
        for change in changes:
            record=next(p for p in self.report['placements'] if change['element_id'] in p['element_ids'])
            record.setdefault('native_annotation_overrides',[]).append(dict(element_id=change['element_id'],font_size_before=12,font_size_after=10,leading_before=change['before']['typography']['leading'],leading_after=11.6,
                reason='Native compositor diagnosed wrap/overset; preserve every word, frame, parent transform and process-K ink.'))
        proof=dict(changes=changes,before_sha256=digest(canonical(before)),after_sha256=digest(canonical(after)),single_undo_exact=True,single_redo_exact=True,
                   preservation='Only fontSize and Typography.leading on the seven diagnosed existing projection labels; all text/IDs/frames/ink/other source exact.')
        self.report.setdefault('projection_note_repairs',[]).append(proof);self.write('projection-note-proof.json',proof);self.save()

    def finalize_semantic_repair(self):
        require(self.resuming,'Finalization only verifies an explicitly pinned already-applied public batch.')
        prior=self.args.finalize_semantic_repair.resolve()
        before=json.loads((prior/'semantic-repair-before.json').read_text());after=json.loads((prior/'semantic-repair-after.json').read_text())
        prior_report=json.loads((prior/'magazine-report.json').read_text());saved_plan=json.loads((prior/'semantic-repair-plan.json').read_text())
        require(prior_report['project_id']==self.report['project_id']==before['id']==after['id'],'Prior semantic evidence belongs to a different project.')
        require(digest(canonical(after))==self.args.expected_source_sha256==prior_report['canonical_source_sha256'],
                'Finalization must target the exact recorded already-applied source hash.')
        rows=[json.loads(line) for line in (prior/'requests.jsonl').read_text().splitlines()]
        batches=[(index,row) for index,row in enumerate(rows) if row['name']=='form_batch']
        require(len(batches)==1 and batches[0][1]['returncode']==0,'Expected one successful recorded semantic batch.')
        batch_index,batch=batches[0]
        require(not any(row['name'] in ('form_undo','form_redo') for row in rows[batch_index+1:]),
                'The recorded batch already has history actions; inspect rather than repeat them.')
        patch_path=Path(saved_plan['patch_path']).resolve();require(sha(patch_path)==saved_plan['patch_sha256'],'Curated patch changed after the recorded batch.')
        patch=json.loads(patch_path.read_text());revised_path=Path(patch['revised_manifest_path']).resolve()
        require(patch['source_manifest_sha256']==prior_report['visual_manifest_sha256'] and sha(revised_path)==patch['revised_manifest_sha256'],
                'Recorded source/revised manifest proof differs.')
        revised=json.loads(revised_path.read_text());assets=revised['assets'];names={record['original_sha256']:record['project_asset'] for record in prior_report['placements'] if record['actual_kind']=='raster'}
        for stage in prior_report.get('semantic_asset_staging',[]):
            require(stage['canonical_restored_sha256']==digest(canonical(before)),'A staged immutable asset lacks exact source restoration evidence.')
            names[stage['source_sha256']]=stage['project_asset']
        revision=json.loads(self.args.editorial.with_name('editorial-revision.json').read_text());editorial_repair_transition(self.plan.editorial,revision)
        expected,records,proof=semantic_asset_repair(before,prior_report,self.plan,patch,assets,names,self.ink,self.ink_color,revision)
        receipt=verify_recorded_semantic_batch(before,after,batch['arguments']['operations'],proof,expected)
        current=self.project()
        require(source_without_history(current)==source_without_history(after),'The current app changed since its applied-batch receipt; no Undo/Redo attempted.')
        status=self.call('form_status')
        require(status.get('project_id')==after['id'] and status.get('can_undo') is True and current.get('history')==after.get('history'),
                'The live batch Undo history changed or was cleared; inspect instead of guessing a history action.')
        proof['applied_batch_receipt']=receipt
        self.write('semantic-repair-before.json',before);self.write('semantic-repair-after.json',after)
        self.write('semantic-finalize-receipt.json',dict(receipt=receipt,prior_round=str(prior),prior_report_sha256=sha(prior/'magazine-report.json'),request_audit_sha256=sha(prior/'requests.jsonl'),patch_sha256=sha(patch_path)))
        self.finish_semantic_repair(before,after,records,proof,patch,revised_path,revised,revision)

    def finish_semantic_repair(self,before,after,records,proof,patch,revised_path,revised,revision):
        self.semantic_phase='undo_final'
        try:self.call('form_undo')
        finally:self.semantic_phase=None
        undone=self.project();self.write('semantic-repair-undone.json',undone)
        require(canonical(undone)==canonical(before),'One Undo did not restore the entire pre-repair canonical source.')
        self.semantic_phase='redo_final'
        try:self.call('form_redo')
        finally:self.semantic_phase=None
        redone=self.project();self.write('semantic-repair-redone.json',redone)
        require(canonical(redone)==canonical(after),'One Redo did not recover the exact repaired source.')
        proof.update(before_sha256=digest(canonical(before)),after_sha256=digest(canonical(after)),single_undo_exact=True,single_redo_exact=True,
                     prior_manifest_sha256=self.report['visual_manifest_sha256'],revised_manifest_sha256=patch['revised_manifest_sha256'],editorial_revision=revision)
        self.report['placements']=records;self.report['copy_proof']=self.plan.copy_proof
        self.report['visual_manifest']=str(revised_path);self.report['visual_manifest_sha256']=patch['revised_manifest_sha256']
        self.report['editorial_sha256']=sha(self.args.editorial);self.report['editorial']=str(self.args.editorial.resolve())
        self.report.setdefault('semantic_repairs',[]).append(proof)
        self.write('semantic-repair-proof.json',proof)
        self.manifest_path=revised_path;self.manifest=revised;self.assets=revised['assets'];self.save()

    def repair_vector_frames(self):
        require(self.resuming,'Frame repair requires a guarded completed-project resume; it never creates a project.')
        before=self.project();candidate,changes=clipped_vector_repair(before,self.report,self.plan,self.args.repair_key)
        self.write('vector-frame-repair-before.json',before)
        changed_ids={change['object_id'] for change in changes};objects={o['id']:o for o in candidate['objects']}
        self._repair_operations=[dict(name='form_set_artwork',arguments=dict(object_id=identity,artwork=objects[identity]['artwork'])) for identity in sorted(changed_ids)]
        self.repairing=True
        try:self.call('form_batch',operations=self._repair_operations)
        finally:self.repairing=False
        after=self.project();self.write('vector-frame-repair-after.json',after)
        self.report['canonical_source_sha256']=digest(canonical(after))
        self.report.setdefault('vector_frame_repair_attempts',[]).append(dict(keys=self.args.repair_key,before_sha256=digest(canonical(before)),after_sha256=digest(canonical(after))))
        self.save()
        require(canonical(after)==canonical(candidate),'Native repair changed source beyond the explicit vector frame masks.')
        for record in self.report['placements']:
            change=next((c for c in changes if c['key']==record['key']),None)
            if change and change['mask_id'] not in record['element_ids']:record['element_ids'].append(change['mask_id'])
        proof=dict(keys=self.args.repair_key,changes=changes,before_sha256=digest(canonical(before)),after_sha256=digest(canonical(after)),
                   preservation='Only selected placement roots gain clipID and explicit unpainted frame masks; original children, text/stories, assets and every unrelated source retain exact values.')
        self.report.setdefault('vector_frame_repairs',[]).append(proof);self.report['canonical_source_sha256']=proof['after_sha256']
        self.write('vector-frame-repair.json',proof);self.save()

    def verify_sources(self):
        project=self.project();objects={o['id']:o for o in project['objects']};document=self.call('form_publication',command='get',publication_id=self.pub)
        self.check('52 canonical page owners in exact editorial order',[p['objectID'] for p in document['pages']]==self.report['page_ids'])
        self.check('All independent editorial titles, standfirsts and captions retain exact source',
                   all(next(e for e in objects[self.page_ids[number]]['artwork']['elements'] if e['id']==expected['id'])['text']==expected['text']
                       for number,page in self.plan.pages.items() for expected in page['elements'] if expected.get('text')))
        self.check('Default saved facing reader layout',document['layout']['facingPages'] and document['layout']['firstPageSide']=='recto')
        spreads=self.call('form_publication',command='spreads',publication_id=self.pub)
        self.check('27 logical reader spreads',len(spreads['spreads'])==27,spread_records=spreads)
        actual_black=[]
        for number,identity in self.page_ids.items():
            art=objects[identity]['artwork'];require(art.get('backgroundOpacity')==0 and art.get('bleed')==0,'Stock must stay nonprinting and zero-bleed on every canonical page.')
            if number in self.plan.black_pages:
                actual_black.append(number)
                require(not any(e['kind']=='image' for e in art['elements']),'A colored parent face contains an undeclared raster: '+str(number))
                stories={story['id']:story for story in project.get('textStories',[])}
                for e in art['elements']:verify_k_element(e,self.ink,stories)
        self.check('16 colored faces use editable declared K-only ink and transparent stock',actual_black==sorted(self.plan.black_pages),logical_pages=actual_black)
        hero=next(p for p in self.report['placements'] if p.get('across_pages'));hero_id=hero['element_ids'][0]
        self.check('Gutter hero has exactly one saved source element',sum(e['id']==hero_id for o in objects.values() for e in (o.get('artwork') or {}).get('elements',[]))==1)
        for spec in self.report['stories']:
            source=self.call('form_story',command='get',story_id=spec['story_id'])['source']
            layout=self.call('form_story',command='layout',story_id=spec['story_id'])
            require(hashlib.sha256(source['text'].encode()).hexdigest()==spec['source_sha256'] and layout['overset_length']==0,'Final original story preservation/fit failed: '+spec['key'])
            verify_k_element(source,self.ink,{})
        for identity in self.report.get('master_source_ids',[]):
            for element in objects[identity]['artwork']['elements']:verify_k_element(element,self.ink,{})
        physical=self.call('form_publication',command='preflight',publication_id=self.pub,output_layout='booklet',ink_output='composite',physical_object_id=self.report['physical']['object_id'])
        self.check('Actual rich story inks and physical K-only parent preflight',physical.get('can_export') is True,preflight=physical)
        before=canonical(project);self.call('form_open_project',project_id=project['id'])
        self.check('Reopen preserves every page, story, source, stock and independent scene',canonical(self.project())==before)
        self.write('source-snapshot.json',self.project())

    def export(self):
        folder=self.output/'exports';folder.mkdir()
        for layout,mode in [('pages','composite'),('spreads','preview'),('booklet','composite')]:
            preflight=self.call('form_publication',command='preflight',publication_id=self.pub,output_layout=layout,ink_output=mode,
                                physical_object_id=self.report['physical']['object_id'])
            self.check(layout+' / native publication preflight',preflight.get('can_export') is True,preflight=preflight)
            destination=folder/('various-'+layout+'.pdf');require(not destination.exists(),'Never replace an existing PDF.')
            result=self.call('form_export_publication',publication_id=self.pub,layout=layout,ink_output=mode,
                             physical_object_id=self.report['physical']['object_id'],path=str(destination),outline_text=True)
            require(destination.is_file() and destination.read_bytes().startswith(b'%PDF'),'Native publication PDF is missing.')
            expected_count={'pages':52,'spreads':27,'booklet':26}[layout]
            self.check(layout+' / exact derived output count',result.get('page_count')==expected_count,
                       source_page_count=result.get('source_page_count'),output_page_count=result.get('page_count'))
            if layout=='booklet':
                sides=result['arrangement']['sides']
                self.check('26 imposed sides retain exact17x11-inch physical dimensions and zero added bleed',
                           len(sides)==26 and all(abs(s['widthMM']-431.8)<1e-6 and abs(s['heightMM']-279.4)<1e-6 and s['bleedMM']==0 for s in sides))
            self.report['exports'].append(dict(layout=layout,ink_output=mode,path=str(destination),sha256=sha(destination),result=result));self.save()
        if not self.args.skip_renders:
            for index,scene in enumerate(self.report['scenes']):
                path=self.output/f'various-scene-{index+1}.render';require(not path.exists(),'Never replace an existing native render.')
                result=self.call('form_export',format='png',scene_id=scene['id'],path=str(path))
                self.report['exports'].append(dict(scene_id=scene['id'],result=result));self.save()

    def run(self):
        if not self.resuming:
            self.author_pages();self.author_stories();self.author_visuals();self.physical_and_scenes()
        if self.args.repair_vector_frames:self.repair_vector_frames()
        if self.args.repair_semantic_assets:self.repair_semantic_assets()
        if self.args.finalize_semantic_repair:self.finalize_semantic_repair()
        if self.args.repair_projection_notes:self.repair_projection_notes()
        self.verify_sources()
        if not self.args.skip_exports:self.export()
        if not self.resuming:self.call('form_set_view',view='split',publication_id=self.pub,object_id=self.page_ids[20])
        self.report['passed']=True;self.report['acceptance']='Authoring/source/compositor checks passed. Root must still inspect actual pages, output channels/boxes and native renders.';self.save()
        print(json.dumps(dict(project_id=self.report['project_id'],publication_id=self.pub,report=str(self.output/'magazine-report.json')),indent=2))


def parse_args():
    parser=argparse.ArgumentParser(description=__doc__,formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--app',type=Path,required=True);parser.add_argument('--socket',required=True)
    parser.add_argument('--library',type=Path,required=True);parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--editorial',type=Path,default=EDITORIAL);parser.add_argument('--assets',type=Path)
    parser.add_argument('--profile',type=Path,help='Installed local CMYK ICC path; otherwise deterministic Generic CMYK preference.')
    parser.add_argument('--plan-only',action='store_true',help='Write the offline plan only; no socket, app, image or native call.')
    parser.add_argument('--skip-exports',action='store_true');parser.add_argument('--skip-renders',action='store_true')
    parser.add_argument('--resume-report',type=Path,help='Verify/export only, from a completely authored prior report; --output must be a fresh folder.')
    parser.add_argument('--source-snapshot',type=Path,help='Public get_project snapshot captured at the failed completed authoring checkpoint.')
    parser.add_argument('--project-id',help='Explicit expected native project UUID; required for resume.')
    parser.add_argument('--expected-source-sha256',help='SHA256 of canonical(snapshot); required for resume.')
    parser.add_argument('--expected-app-sha256',help='Explicit SHA256 of a separately verified updated app binary; resume otherwise requires the prior app hash.')
    parser.add_argument('--repair-vector-frames',action='store_true',help='Guarded resume only: add native outline clip masks to selected existing vector placements; no reauthoring.')
    parser.add_argument('--repair-key',action='append',default=[],help='Exact vector placement key to clip; repeat for each specifically reviewed placement.')
    parser.add_argument('--repair-semantic-assets',type=Path,help='Guarded resume only: apply an explicit curated manifest patch, fit native group views and the approved caption correction.')
    parser.add_argument('--verified-existing-project-library',action='store_true',help='Permit ONLY an existing fully hash-pinned resume/repair in the explicit matching normal app library; never create a new project there.')
    parser.add_argument('--finalize-semantic-repair',type=Path,help='Guarded resume only: verify an already-applied recorded semantic batch, then perform its exact Undo/Redo and final source checks; no imports or new edits.')
    parser.add_argument('--repair-projection-notes',type=Path,help='Guarded resume only: use the retained16native ink diagnostics to fit only the seven confirmed long projection annotations; no words/frame/ink changes.')
    return parser.parse_args()


def main():
    args=parse_args();editorial=json.loads(args.editorial.read_text());plan=IssuePlan(editorial)
    if args.plan_only:
        output=args.output.resolve();require(not output.exists() or not any(output.iterdir()),'Choose a fresh empty plan folder.')
        output.mkdir(parents=True,exist_ok=True);path=output/'layout-plan.json';path.write_text(json.dumps(plan.json(),ensure_ascii=False,indent=2)+'\n')
        print(json.dumps(dict(plan=str(path),**plan.copy_proof),indent=2));return
    resume=None
    if args.resume_report:
        require(args.source_snapshot is not None and args.project_id and args.expected_source_sha256,'Resume requires --source-snapshot, --project-id and --expected-source-sha256.')
        prior=json.loads(args.resume_report.read_text())
        if args.assets is None:args.assets=Path(prior['visual_manifest'])
        resume=(args.resume_report,args.source_snapshot,args.expected_source_sha256)
    if args.repair_vector_frames:require(resume is not None and args.repair_key,'Vector repair requires --resume-report and explicit --repair-key values.')
    if args.repair_semantic_assets:require(resume is not None and not args.repair_vector_frames,'Semantic repair requires its own guarded resume after clipping.')
    if args.finalize_semantic_repair:require(resume is not None and not args.repair_vector_frames and not args.repair_semantic_assets,'Finalization requires a separate guarded resume of the existing applied source.')
    if args.repair_projection_notes:require(resume is not None and not args.repair_vector_frames and not args.repair_semantic_assets and not args.finalize_semantic_repair,'Annotation repair requires its own guarded existing-source resume.')
    require(args.assets is not None,'Live authoring requires --assets pointing to the actual generated visual-assets.json.')
    author=MagazineAuthor(args,plan,resume=resume)
    try:author.run()
    except Exception as error:
        author.report.update(passed=False,error=str(error));author.save();raise


if __name__=='__main__':main()
