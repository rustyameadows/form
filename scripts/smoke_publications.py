#!/usr/bin/env python3
"""Real packaged publication/story flow; refuses ordinary user libraries."""
import copy
import json
import pathlib
import re
import statistics
import time
import uuid
from smoke_mcp import Client, OUTPUT, ROOT


def main():
    c = Client()
    try:
        library = pathlib.Path(c.call('form_status')['library_path']).resolve()
        assert library.is_relative_to((ROOT / '.local').resolve()), 'Use a disposable .local validation library.'
        c.discover(['form_story', 'form_publication', 'form_export_publication'])
        project = c.call('form_create_project', {'name': 'ORBITAL / Physical booklet', 'template': 'fieldGuide'})
        def get(): return c.call('form_get_project')
        def story(): return c.call('form_story', {'command': 'get', 'story_id': sid})
        def layout(): return c.call('form_story', {'command': 'layout', 'story_id': sid})
        document = project['publications'][0]
        pid = document['id']; sid = project['textStories'][0]['id']
        original = story(); source = original['source']; words = original['story']['text']
        frame = original['story']['frames'][0]
        object_id = frame['objectID']; element_id = frame['elementID']
        package = library / (project['id'] + '.form')
        def references():
            return {o['id']: o['file'] for o in json.loads((package / 'Manifest.json').read_text())['objects']}
        baseline = get(); refs = references()
        initial = layout()
        assert len(initial['frames']) == 4 and initial['overset_length'] == 0
        assert all(f['source_length'] > 0 for f in initial['frames']), 'Every body column must contain real source.'
        assert all(not e['text'] and not e.get('textRuns') and not e.get('listItems')
                   for o in baseline['objects'] for e in o.get('artwork', {}).get('elements', []) if e.get('storyFrame'))
        c.call('form_story', {'command': 'edit', 'story_id': sid, 'name': 'A renamed editable story'})
        assert references() == refs, 'Story metadata must not rewrite page object files.'
        c.call('form_undo'); assert get() == baseline
        c.call('form_edit_artwork', {'command': 'paragraph', 'object_id': object_id, 'element_ids': [element_id],
            'location': 0, 'length': 5, 'typography': {'direction': 'ltr', 'language': 'tr'}})
        assert story()['story']['text'] == words and references() == refs
        c.call('form_undo'); assert get() == baseline
        c.call('form_batch', {'operations': [
            {'name': 'form_story', 'arguments': {'command': 'edit', 'story_id': sid, 'name': 'Must roll back'}},
            {'name': 'form_story', 'arguments': {'command': 'append', 'story_id': sid,
                'frames': [{'object_id': str(uuid.uuid4()), 'element_id': str(uuid.uuid4())}]}}]}, expect_error=True)
        assert get() == baseline
        ordered = [p['objectID'] for p in document['pages']]
        reordered = [ordered[0], ordered[2], ordered[1]]
        c.call('form_publication', {'command': 'reorder', 'publication_id': pid, 'page_ids': reordered})
        assert layout()['frames'][0]['object_id'] == reordered[1]
        assert story()['story']['text'] == words
        c.call('form_undo'); assert get() == baseline
        copied = c.call('form_duplicate_object', {'object_id': object_id, 'mode': 'iteration'})
        assert len(story()['story']['frames']) == 6 and story()['story']['text'] == words
        c.call('form_undo'); assert get() == baseline
        c.call('form_duplicate_object', {'object_id': object_id, 'mode': 'variant'}, expect_error=True)
        assert get() == baseline
        c.call('form_story', {'command': 'unlink', 'frames': [{'object_id': object_id, 'element_id': element_id}]})
        assert story()['story']['text'] == words and len(story()['story']['frames']) == 3
        c.call('form_undo'); assert get() == baseline
        added = c.call('form_publication', {'command': 'add_page', 'publication_id': pid, 'story_id': sid,
            'width': 160, 'height': 210, 'columns': 2})
        assert len(story()['story']['frames']) == 6 and story()['story']['text'] == words
        c.call('form_undo'); assert get() == baseline
        c.call('form_publication', {'command': 'settings', 'publication_id': pid,
            'baseline_grid': {'spacing': 0, 'origin': 0}}, expect_error=True)
        assert get() == baseline
        report = c.call('form_publication', {'command': 'preflight', 'publication_id': pid})
        assert report['can_export'], report
        exports = {}
        for outlined in [False, True]:
            path = OUTPUT / ('orbital-booklet-outlined.pdf' if outlined else 'orbital-booklet.pdf')
            result = c.call('form_export_publication', {'publication_id': pid, 'path': str(path), 'dpi': 144,
                'outline_text': outlined})
            assert result['page_count'] == 3 and result['bytes'] > 5000
            pdf = path.read_bytes()
            assert len(re.findall(rb'/Type\s*/Page\b', pdf)) == 3
            assert len(re.findall(rb'/TrimBox\b', pdf)) == 3 and len(re.findall(rb'/BleedBox\b', pdf)) == 3
            exports['outlined' if outlined else 'native'] = result
        assert get() == baseline
        # Force real overset without replacing, truncating, or copying the source.
        shortened = copy.deepcopy(source)
        shortened['fontSize'] = 100
        for run in shortened.get('textRuns', []): run['fontSize'] = 100
        c.call('form_story', {'command': 'edit', 'story_id': sid, 'source': shortened})
        assert layout()['overset_length'] > 0 and story()['story']['text'] == words
        c.call('form_export_publication', {'publication_id': pid, 'path': str(OUTPUT / 'refused-overset.pdf')}, expect_error=True)
        c.call('form_undo'); assert get() == baseline
        c.call('form_open_project', {'project_id': project['id']})
        reopened = get()
        assert reopened['schemaVersion'] >= 26 and reopened['textStories'] == baseline['textStories']
        assert reopened['publications'] == baseline['publications'] and reopened['objects'] == baseline['objects']
        for resource in (package / 'Objects').glob('*.json'):
            raw = resource.read_text()
            assert 'resolved' not in raw and words[:70] not in raw and 'studio.form.' not in raw
        c.call('form_set_view', {'view': 'canvas', 'object_id': object_id, 'element_ids': [element_id]})
        timings = []
        for i in range(20):
            start = time.perf_counter()
            c.call('form_story', {'command': 'edit', 'story_id': sid, 'name': f'A field guide / timing {i}'})
            layout()
            timings.append((time.perf_counter() - start) * 1000)
        result = dict(project_id=project['id'], publication_id=pid, story_id=sid, first_frame=frame,
            source_units=len(words.encode('utf-16-le')) // 2, exports=exports, preflight=report,
            edit_layout_median_ms=round(statistics.median(timings), 2), edit_layout_p95_ms=round(sorted(timings)[18], 2),
            performance_scope='20 saved story metadata edits plus layout queries on the three-page, four-column study. Native typing and large-document performance require separate checks.',
            checks='Real packaged MCP; discovery; one rich global source; frame capacity and page order; paragraph routing; invalid batch rollback; duplicate/unlink/add-page Undo; overset refusal; physical native/outlined multipage PDF; schema reopen; frame-file immutability and transient metadata exclusion.',
            status=c.call('form_status'))
        (OUTPUT / 'publications-report.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps({k: v for k, v in result.items() if k not in ['exports', 'status', 'preflight']}, indent=2))
    finally:
        c.close()


if __name__ == '__main__':
    main()
