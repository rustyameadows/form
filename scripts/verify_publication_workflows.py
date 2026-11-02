#!/usr/bin/env python3
"""Author and verify two editable publications in an already-running disposable LAB.

This runner never launches an app, writes project internals, calls an image model,
or contacts manufacturing hardware. All project edits use public native MCP calls.
Use an explicit ordinary LAB.app, its existing socket, a disposable .local/validation
library, and a fresh evidence folder. Native compositor measurements calibrate copy
before the accepted baseline; no exported text is silently discarded.
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
import time
import uuid
import xml.etree.ElementTree as ET

from validate_paper_packaging import Session
from render_paper_packaging import camera

NS = uuid.UUID('a22e9ba1-ef54-48aa-8ceb-ff122a1fe011')
INK = '#193F3C'
PAPER = '#F4EDDD'
BLUE = '#365D85'
ORANGE = '#B95D38'

# These are authored project contents, not application recipes or product types.
MATERIALS = [
    ('Paper', 'The memory of a fold', 'A paper edge records a decision before the face of the sheet says anything.', 'crease', 'a scored sample beside an unscored sample', 'the direction of the fibres'),
    ('Linen', 'A useful irregularity', 'Linen makes a surface legible through small differences rather than a perfect repeat.', 'weave', 'a loose swatch beside a tensioned swatch', 'the open space between threads'),
    ('Plywood', 'Reading the layers', 'The edge of plywood is a drawing of how the board was assembled.', 'lamination', 'an exposed edge beside a covered edge', 'the sequence of thin veneers'),
    ('Glass', 'A boundary made of light', 'Glass changes the apparent distance between a hand and the object behind it.', 'reflection', 'a clear sample beside a lightly frosted sample', 'the changing angle of the light'),
    ('Stone', 'Weight before image', 'A stone object announces its weight even when it is standing perfectly still.', 'grain', 'a rough fragment beside a polished face', 'the difference between texture and pattern'),
    ('Steel', 'The line of a joint', 'Steel asks the designer to decide which connections should be seen.', 'joint', 'a folded corner beside a joined corner', 'the space needed for a tool'),
    ('Ceramic', 'The small space around a rim', 'A ceramic rim describes both the vessel and the way a person will approach it.', 'rim', 'a narrow rim beside a generous rim', 'the transition between wall and lip'),
    ('Cork', 'A quiet interruption', 'Cork is useful where a hard object should meet its surroundings gently.', 'compression', 'a narrow foot beside a continuous pad', 'the area that actually carries the load'),
    ('Rubber', 'Holding without a handle', 'Rubber often does its best work at the point where another material would slip.', 'grip', 'a smooth patch beside a shallow rib', 'the direction of an ordinary movement'),
    ('Leather', 'A surface that keeps time', 'A leather sample becomes more informative after it has been handled.', 'wear', 'a fresh offcut beside a handled sample', 'the places where a hand returns'),
    ('Wool', 'The structure of softness', 'Wool can give a soft outline to an object without hiding its underlying shape.', 'loft', 'a flat swatch beside a gently formed swatch', 'the relation between outline and thickness'),
    ('Aluminum', 'A light edge', 'Aluminum makes the thickness of an edge a particularly visible choice.', 'section', 'a solid strip beside a folded section', 'the small return that gives an edge its stiffness'),
    ('Fibre board', 'Making use of the remainder', 'Fibre board invites an honest account of what the surface is made from.', 'fibre', 'a cut face beside an uncut face', 'the fragments held together in the sheet'),
    ('Recycled polymer', 'A second clear purpose', 'A recycled polymer sample is most convincing when its next use is easy to understand.', 'surface', 'a translucent sample beside an opaque sample', 'the balance between visible history and clear function'),
]
CITY = [
    ('Walking', 'The route that appears slowly', 'A useful route is often discovered by returning to the same corner at different times.', 'route', 'a direct path beside a slower path', 'the details that only appear at walking speed'),
    ('Repair', 'Keeping a place in use', 'A repaired object keeps a small record of the people who chose to keep it.', 'repair', 'a repaired joint beside an untouched joint', 'the difference between care and concealment'),
]


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def stable(name):
    return str(uuid.uuid5(NS, name)).upper()


def utf16(text):
    return len(text.encode('utf-16-le')) // 2


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def canonical(project):
    return {key: project.get(key) for key in ('id', 'objects', 'publications', 'textStories', 'textStyles', 'camera', 'studioPresentation')}


def element(kind, name, x, y, width, height, color=INK, text='', points=12, **extra):
    value = dict(id=stable(name), name=name, kind=kind, x=x, y=y, width=width, height=height,
                 color=color, text=text, fontSize=points)
    if kind == 'text':
        value['typography'] = dict(fontName='HelveticaNeue', leading=round(points * 1.4, 6))
    value.update(extra)
    return value


def art(elements, background=PAPER, transparent=False, position=None):
    value = dict(background=background, bleed=3, elements=elements, unit='mm', showGuides=False)
    if transparent:
        value.update(backgroundOpacity=0, bleed=0)
    if position:
        value['canvasPosition'] = dict(zip(('x', 'y'), position))
    return value


def prose(notes):
    material, title, lead, detail, comparison, observation = notes
    paragraphs = [
        lead + ' This chapter begins with an ordinary encounter rather than a finished specification. The aim is to notice what the material already offers, then make one clear decision about how to use it. A small sample on the table is often more useful than a large collection of images.',
        f'Begin with {comparison}. Give the two samples the same amount of space and look at them from the same distance. The comparison should reveal a choice, not declare a winner. Write down what changes when the light moves, and what remains understandable when it does not.',
        f'The first drawing should record {observation}. Leave enough white space around it to show where the object ends. A close view can explain a surface, but a second view should show how that surface belongs to a larger thing. Neither drawing needs to pretend that it is a photograph.',
        f'In {material.lower()}, the {detail} is a useful point of attention. Follow it with a finger, then follow it with a pencil. The two actions produce different kinds of information. A hand discovers interruptions and resistance; a drawing makes those discoveries available to somebody who was not there.',
        'Keep the first version nearby while making the second. It is surprisingly easy to improve a detail and lose the quality that made the earlier version promising. A pair of dated samples makes that trade visible. It also gives the next conversation something more precise than a memory of what looked better.',
        f'Consider the space around the {detail}, not only the detail itself. The empty interval may be where a tool enters, where a hand rests, or where two parts need room to move. Drawing that space as carefully as the object usually makes the eventual object simpler.',
        'A useful test changes one thing at a time. Keep the overall size, the viewpoint and the light consistent, then change the edge or the connection. The result will not answer every question. It will answer one question clearly enough that the next decision has a reliable starting point.',
        f'Return to {comparison} after the samples have been handled. Look for a change that was absent from the first photograph. The point is not to make every mark disappear. It is to decide which marks help the object become familiar and which ones interrupt its intended use.',
        'Scale belongs in the record. Put a dimension next to the drawing and give the sample a name that will still make sense a month later. A number without a physical reference can be misleading; a photograph without a dimension can be just as difficult to use.',
        f'The final spread keeps {observation} in view. It places the surface beside its section and the section beside a small account of use. The three views should support one another. If they disagree, the disagreement is useful: it points to the next sample rather than hiding an unresolved choice.',
        'There is no need to turn this study into a catalogue of every possible result. Keep the alternatives that explain a real difference, and remove the ones that only repeat the same answer. A concise record leaves room for another person to continue the work without first reconstructing the entire process.',
        f'The chapter ends where it began, with {material.lower()} on the table. What has changed is the quality of the question. Instead of asking whether the material looks right, we can now ask which edge, interval or connection allows it to do the work we have in mind.',
    ]
    return '\n\n'.join(paragraphs)


def illustration(prefix, width, y, height, index):
    """Ordinary editable vector layers: sections, samples and measured intervals."""
    result = []
    left, usable = 17, width - 34
    color = [BLUE, ORANGE, INK, '#8B876A'][index % 4]
    result.append(element('rectangle', prefix+'-plate', left, y, usable, height, '#E5DCC6'))
    for band in range(5):
        x = left + 8 + band * (usable - 16) / 5
        result.append(element('rectangle', prefix+f'-section-{band}', x, y+8+band*2, (usable-24)/5, height-17-band*2, color, rotation=(index%3-1)*3))
    result.append(element('line', prefix+'-datum', left, y+height+4, usable, 0.001, color, stroke=dict(color=color, width=0.25)))
    return result


class PublicationProof:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        require(not (self.output/'publication-report.json').exists(), 'Choose a fresh evidence output folder.')
        self.output.mkdir(parents=True, exist_ok=True)
        self.library = args.library.resolve()
        require(any(self.library.parts[i:i+2] == ('.local', 'validation') for i in range(len(self.library.parts)-1)), 'The explicit library must be disposable under .local/validation.')
        require(Path(args.socket).exists(), 'The explicit socket must already exist; this script never launches LAB.')
        require(stat.S_ISSOCK(os.stat(args.socket).st_mode), 'The explicit path is not a native socket.')
        self.session = Session(args.app, args.socket, self.output)
        require(self.session.helper.is_file(), 'The explicit app must include its packaged lab-mcp helper.')
        running = subprocess.run(['ps', '-axo', 'pid=,command='], capture_output=True, text=True, check=True).stdout
        binary=str(args.app.resolve()/'Contents/MacOS/LAB')
        commands=[line.strip().split(None,1)[1] for line in running.splitlines() if len(line.strip().split(None,1))==2]
        require(any(command==binary or command.startswith(binary+' ') for command in commands), 'The explicit ordinary LAB binary must already be running.')
        self.session.env.update(LAB_LIBRARY_PATH=str(self.library), FORM_LIBRARY_PATH=str(self.library), FORM_SOCKET_PATH=args.socket)
        status = self.call('form_status')
        require(Path(status['library_path']).resolve() == self.library, 'The socket does not belong to the explicitly expected disposable library.')
        self.report = dict(version=1, app=str(args.app.resolve()), app_sha256=hashlib.sha256((args.app.resolve()/'Contents/MacOS/LAB').read_bytes()).hexdigest(), socket=args.socket, library=str(self.library), project_id=None, publications=[], checks=[], renders=[], limitations=['Digital source, composition and appearance evidence only; physical binding and printer calibration are not measured.'])
        self.save()

    def call(self, tool, **kwargs):
        return self.session.call(tool, kwargs)

    def save(self):
        (self.output/'publication-report.json').write_text(json.dumps(self.report, indent=2)+'\n')

    def check(self, name, condition, **evidence):
        require(condition, name)
        self.report['checks'].append(dict(name=name, passed=True, **evidence))
        self.save()

    def project(self):
        return self.call('form_get_project')

    def object(self, object_id):
        return next(o for o in self.project()['objects'] if o['id'] == object_id)

    def style(self, name, size, font='HelveticaNeue', **typography):
        value = self.call('form_text_style', command='create', name=name, font_size=size, typography=dict(fontName=font, leading=round(size*1.4, 6), **typography))
        return value['style']['id']

    def set_art(self, object_id, artwork):
        self.call('form_set_artwork', object_id=object_id, artwork=artwork)

    def add_source(self, name, width, height, artwork):
        value = self.call('form_add_object', recipe_id='artboard', name=name, parameters=dict(width=width, depth=height))
        object_id = value.get('id') or value.get('object_id')
        require(object_id, 'Native add_object returned no source ID.')
        self.set_art(object_id, artwork)
        return object_id

    def publication(self, name, count, width, height, notes, origin):
        publication_id = self.call('form_publication', command='create', name=name, page_ids=[], margins=dict(top=16, right=17, bottom=16, left=17), language='en', layout=dict(facingPages=True, firstPageSide='recto', innerMargin=19, outerMargin=15), numbering=dict(start=1, style='arabic', prefix='', suffix=''))['publication_id']
        page_ids = self.call('form_publication', command='create_pages', publication_id=publication_id, count=count, width=width, height=height, columns=1, gutter=8)['page_ids']
        styles = dict(body=self.style(name+' / Body', 12), heading=self.style(name+' / Heading', 20, 'HelveticaNeue-Medium'), caption=self.style(name+' / Caption', 8.5))
        master_name = name+' / Running furniture'
        master_elements = [element('text',master_name+'-running',17,7,width-34,6,INK,name.upper(),8), element('text',master_name+'-chapter',17,height-11,width-45,5,INK,'{{chapter.title}}',7.5), element('text',master_name+'-folio',width-25,height-11,10,5,INK,'{{page.number}}',8)]
        master_id = self.add_source(master_name,width,height,art(master_elements,transparent=True,position=(origin[0]-width-55,origin[1])))
        master = dict(id=stable(name+'-master'),name='Running head / chapter / folio',sourceObjectID=master_id,x=0,y=0,side='all',behind=False)
        self.call('form_publication',command='settings',publication_id=publication_id,masters=[master],baseline_grid=dict(spacing=16.8,origin=0))
        chapters = []
        chapter_pages = 4
        start = 2 if count == 12 else 4
        mapping = {start+i*chapter_pages:(i,topic) for i,topic in enumerate(notes)}
        body_map = {page:(start_index,chapter_index,topic) for start_index,(chapter_index,topic) in mapping.items() for page in range(start_index,start_index+chapter_pages)}
        originals = {o['id']:o for o in self.project()['objects']}
        body_ids = {}
        for index,page_id in enumerate(page_ids):
            prefix=name+f'-page-{index+1}'
            page=originals[page_id]
            self.call('form_update_object',object_id=page_id,name=name+f' / {index+1:02d}')
            elements=[]
            if index in body_map:
                start_index,chapter_index,topic=body_map[index]
                offset=index-start_index
                elements.append(element('text',prefix+'-chapter',17,23,width-34,22,INK,topic[1] if offset == 0 else topic[0]+' / '+str(offset+1),20,typography=dict(fontName='HelveticaNeue-Medium',leading=28),textStyle=dict(styleID=styles['heading'])))
                elements += illustration(prefix,width,45,50 if count == 12 else 68,chapter_index+offset)
                elements.append(element('text',prefix+'-caption',17,102 if count == 12 else 120,width-34,6,INK,f'{chapter_index+1:02d}.{offset+1} / {topic[4].capitalize()}',8.5,textStyle=dict(styleID=styles['caption'])))
                frame=next(e for e in page['artwork']['elements'] if e['kind']=='text')
                frame.update(x=17,y=116 if count == 12 else 134,width=width-34,height=height-(116 if count == 12 else 134)-18,fontSize=12,color=INK,text='',name='Linked chapter body',typography=dict(fontName='HelveticaNeue',leading=16.8),textStyle=dict(styleID=styles['body']))
                body_ids[page_id]=frame['id'];elements.append(frame)
            else:
                title = name if index == 0 else ('Contents' if index == 1 else ('Colophon' if index == count-2 else 'A record worth keeping'))
                elements=[element('text',prefix+'-title',17,29,width-34,35,INK,title,31 if index == 0 else 23),*illustration(prefix,width,82,65 if count == 12 else 95,index)]
                copy_text = '\n'.join(f'{i+1:02d}  {topic[1]}' for i,topic in enumerate(notes)) if title == 'Contents' else ('A working collection of observations, drawings and useful questions.\n\nFIELD OFFICE / 2026\nFirst edition · edited in LAB')
                if title == 'Contents':
                    elements=[elements[0],element('text',prefix+'-note',17,78,width-34,height-100,INK,copy_text,10)]
                else:
                    elements.append(element('text',prefix+'-note',17,height-52,width-34,32,INK,copy_text,10))
            self.set_art(page_id,art(elements,position=(origin[0]+index*(width+36),origin[1])))
            if index in mapping:
                topic=mapping[index][1]
                self.call('form_publication',command='page_settings',publication_id=publication_id,page_id=page_id,chapter_title=topic[1])
            if index in (0,count-1):
                self.call('form_publication',command='page_settings',publication_id=publication_id,page_id=page_id,master_ids=[])
        for start_index,(chapter_index,topic) in mapping.items():
            frame_pages=page_ids[start_index:start_index+chapter_pages]
            frames=[dict(object_id=pid,element_id=body_ids[pid]) for pid in frame_pages]
            story_id=self.call('form_story',command='create',publication_id=publication_id,name=topic[1],frames=frames)['story_id']
            self.call('form_story',command='replace_text',story_id=story_id,location=0,length=0,text=prose(topic))
            source=self.call('form_story',command='get',story_id=story_id)['source']
            first_end=source['text'].find('.')+1
            source['textRuns']=[dict(location=0,length=utf16(source['text'][:first_end]),typography=dict(fontName='HelveticaNeue-Medium',leading=16.8),fontSize=12,color=INK)]
            self.call('form_story',command='edit',story_id=story_id,source=source)
            calibrated=self.calibrate(story_id,frames,height-18)
            chapters.append(dict(story_id=story_id,title=topic[1],frames=frames,**calibrated))
        row=dict(name=name,publication_id=publication_id,page_ids=page_ids,width_mm=width,height_mm=height,master_id=master_id,styles=styles,chapters=chapters)
        self.report['publications'].append(row);self.save()
        return row

    def calibrate(self, story_id, frames, bottom):
        adjustments=[]
        for attempt in range(24):
            layout=self.call('form_story',command='layout',story_id=story_id)
            source=self.call('form_story',command='get',story_id=story_id)['source']
            last=layout['frames'][-1]['source_length']
            if layout['overset_length']==0 and last>40:
                return dict(source_sha256=hashlib.sha256(source['text'].encode()).hexdigest(),source_units=utf16(source['text']),layout=layout,authoring_adjustments=adjustments)
            current=self.object(frames[0]['object_id'])['artwork']
            frame=next(e for e in current['elements'] if e['id']==frames[0]['element_id'])
            maximum=bottom-frame['y'];old=frame['height']
            new=min(maximum,old*1.25) if layout['overset_length'] else max(18,old*.8)
            if abs(new-old)<.1 and layout['overset_length']:
                # Explicitly authored copy calibration before the accepted baseline.
                text=source['text'];cut=text.rfind('\n\n')
                require(cut>400,'Cannot fit the complete chapter source in the selected physical capacity.')
                self.call('form_story',command='replace_text',story_id=story_id,location=utf16(text[:cut]),length=utf16(text[cut:]),text='')
                adjustments.append(dict(action='Removed complete final draft paragraph before baseline',removed_source_units=utf16(text[cut:])))
            else:
                require(abs(new-old)>=.1,'Chapter does not reach its last selected frame at minimum useful capacity.')
                for target in frames:
                    page=self.object(target['object_id']);artwork=page['artwork'];next(e for e in artwork['elements'] if e['id']==target['element_id'])['height']=new
                    self.set_art(target['object_id'],artwork)
                adjustments.append(dict(action='Resized ordinary body frames before baseline',height_mm=new))
        raise AssertionError('Native chapter calibration did not converge.')

    def export_publication(self,row):
        exports={}
        for layout in ('pages','spreads','booklet'):
            report=self.call('form_publication',command='preflight',publication_id=row['publication_id'],output_layout=layout)
            self.check(row['name']+' / '+layout+' preflight',report.get('can_export') is True,report=report)
            path=self.output/'exports'/(row['name'].replace(' / ','-')+'-'+layout+'.pdf');path.parent.mkdir(exist_ok=True)
            result=self.call('form_export_publication',publication_id=row['publication_id'],layout=layout,path=str(path),outline_text=True)
            require(path.is_file() and path.read_bytes().startswith(b'%PDF'),'Native publication export did not create a real PDF.')
            plan=result['arrangement'];indices=[placement.get('sourcePage') for side in plan['sides'] for placement in side['placements'] if placement.get('sourcePage') is not None]
            self.check(row['name']+' / '+layout+' retains every logical source once',sorted(indices)==list(range(1,len(row['page_ids'])+1)),source_page_count=result['source_page_count'],output_page_count=result['page_count'])
            if layout=='booklet' and len(row['page_ids'])==12:
                self.check(row['name']+' / actual twelve-page folded order',[[p.get('sourcePage') for p in side['placements']] for side in plan['sides']]==[[12,1],[2,11],[10,3],[4,9],[8,5],[6,7]],plan=plan)
            exports[layout]=dict(result=result,path=str(path),sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        row['exports']=exports;self.save()

    def source_exports(self,row):
        source_ids={row['page_ids'][0],row['page_ids'][-1]}
        for obj in self.project()['objects']:
            definition=obj.get('sheetAssembly') or {}
            if definition.get('publicationID')!=row['publication_id']:
                continue
            for plane in definition.get('enclosure') or []:
                for side in ('front','back'):
                    if plane.get(side):
                        source_ids.add(plane[side]['sourceObjectID'])
        row['cover_exports']=[]
        for index,source_id in enumerate(sorted(source_ids)):
            for format in ('pdf','svg'):
                path=self.output/'exports'/(row['name'].replace(' / ','-')+f'-cover-source-{index+1}.'+format)
                path.parent.mkdir(exist_ok=True)
                result=self.call('form_export_artwork',object_id=source_id,format=format,path=str(path),outline_text=format=='pdf')
                require(path.is_file() and path.stat().st_size>100,'Native canonical cover source export is missing.')
                if format=='svg':
                    ET.parse(path)
                row['cover_exports'].append(dict(source_id=source_id,format=format,path=str(path),sha256=hashlib.sha256(path.read_bytes()).hexdigest(),result=result))
        page=row['chapters'][0]['frames'][0]['object_id']
        path=self.output/'exports'/(row['name'].replace(' / ','-')+'-master-and-body.svg')
        self.call('form_export_artwork',object_id=page,format='svg',path=str(path),outline_text=False)
        texts=' '.join(ET.parse(path).getroot().itertext())
        self.check(row['name']+' / actual SVG resolves running furniture tokens','{{' not in texts and row['name'].upper() in texts,path=str(path))
        before=canonical(self.project());master=self.object(row['master_id']);updated=copy.deepcopy(master['artwork'])
        header=next(e for e in updated['elements'] if e['name'].endswith('-running'))
        header['text']='REVISED / '+row['name'].upper()
        self.set_art(row['master_id'],updated)
        current=self.project();before_pages={o['id']:o for o in before['objects'] if o['id'] in row['page_ids']}
        self.check(row['name']+' / master edit preserves ordinary page sources',all(o==before_pages[o['id']] for o in current['objects'] if o['id'] in before_pages))
        changed_path=path.with_name(path.stem+'-master-edit.svg')
        self.call('form_export_artwork',object_id=page,format='svg',path=str(changed_path),outline_text=False)
        changed_text=' '.join(ET.parse(changed_path).getroot().itertext())
        self.check(row['name']+' / master change reaches actual page output','REVISED / '+row['name'].upper() in changed_text,path=str(changed_path))
        self.call('form_undo');self.check(row['name']+' / master Undo restores exact source',canonical(self.project())==before)
        self.save()

    def edit_proofs(self,row):
        story=row['chapters'][0]['story_id'];before=canonical(self.project());source=self.call('form_story',command='get',story_id=story)['source'];text=source['text']
        self.call('form_story',command='replace_text',story_id=story,location=0,length=0,text='A new opening. ')
        edited=self.call('form_story',command='get',story_id=story)['source']
        self.check(row['name']+' / rich source edit',edited['text']=='A new opening. '+text and bool(edited.get('textRuns')))
        self.call('form_undo');self.check(row['name']+' / exact source edit Undo',canonical(self.project())==before)
        self.call('form_redo');self.check(row['name']+' / source edit Redo',self.call('form_story',command='get',story_id=story)['source']['text']==edited['text'])
        self.call('form_undo');self.check(row['name']+' / baseline restored',canonical(self.project())==before)
        baseline_layout=self.call('form_story',command='layout',story_id=story)
        self.call('form_text_style',command='update',style_id=row['styles']['body'],font_size=15)
        varied=self.call('form_story',command='layout',story_id=story)
        self.check(row['name']+' / shared type reflows real source',varied['source_length']==baseline_layout['source_length'] and (varied['frames']!=baseline_layout['frames'] or varied['overset_length']!=baseline_layout['overset_length']))
        self.call('form_undo');self.check(row['name']+' / typography Undo',canonical(self.project())==before)
        row['accepted_source_sha256']=digest(canonical(self.project()));self.save()

    def run(self):
        self.call('form_create_project',name='FIELD / Publication workshop',template='blank')
        self.report['project_id']=self.project()['id'];self.save()
        booklet=self.publication('Slow city / Field notes',12,148,210,CITY,(500,40))
        hardcover=self.publication('Material atlas / Useful edges',64,180,240,MATERIALS,(500,1550))
        # Physical data is authored by the independent geometry review and uses
        # the same public definition/commands as the native binding inspector.
        from publication_physical_examples import create_physical_examples, render_evidence
        physical=create_physical_examples(self.call,[booklet,hardcover])
        self.report['physical']=physical;self.save()
        for row in self.report['publications']:
            self.edit_proofs(row);self.export_publication(row);self.source_exports(row)
        self.report['renders']=render_evidence(self.call,self.output,physical,width=2000,height=1600)
        before=canonical(self.project());self.call('form_open_project',project_id=self.report['project_id'])
        self.check('Save/reopen preserves canonical pages, stories, styles, physical definitions and scenes',canonical(self.project())==before)
        self.check('Table defaults contain two physical assemblies',sum(o.get('sheetAssembly') is not None for o in self.project()['objects'])==2)
        for row in self.report['publications']:
            current=self.call('form_publication',command='get',publication_id=row['publication_id'])
            self.check(row['name']+' / exact logical page order', [p['objectID'] for p in current['pages']]==row['page_ids'])
            for chapter in row['chapters']:
                layout=self.call('form_story',command='layout',story_id=chapter['story_id'])
                self.check(row['name']+' / complete chapter '+chapter['title'],layout['overset_length']==0 and layout['frames'][-1]['source_length']>40,layout=layout)
        self.report['passed']=True;self.save()
        print(json.dumps(dict(project_id=self.report['project_id'],report=str(self.output/'publication-report.json')),indent=2))


def main():
    parser=argparse.ArgumentParser(description=__doc__,formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--app',type=Path,required=True)
    parser.add_argument('--socket',required=True)
    parser.add_argument('--library',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    proof=PublicationProof(args)
    try:
        proof.run()
    except Exception as error:
        proof.report.update(passed=False,error=str(error));proof.save();raise


if __name__=='__main__':
    main()
