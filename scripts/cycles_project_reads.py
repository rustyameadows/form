"""Revision-guarded public project reads for the material authoring clients.

The returned Python snapshot is an explicitly marked local projection. It is
never sent back as a Project or mistaken for a complete application document.
"""


STALE_REVISION_MESSAGE = 'Project read revision changed. Restart from view:summary before reading more pages.'


class ProjectReadRevisionChanged(RuntimeError):
    """Only the exact public stale-revision error or an envelope token mismatch."""


class ProjectReader:
    def __init__(self, call):
        self.call = call

    @staticmethod
    def envelope(value, view, revision=None, project=None):
        if not isinstance(value, dict) or value.get('view') != view or value.get('response_complete') is not False:
            raise RuntimeError('Expected an explicitly partial bounded project response')
        token, metadata = value.get('revision'), value.get('project')
        if not isinstance(token, str) or not token or not isinstance(metadata, dict) or not metadata.get('id'):
            raise RuntimeError('Project response is missing its identity/revision')
        if revision is not None and token != revision:
            raise ProjectReadRevisionChanged('Project read revision changed while collecting pages')
        if project is not None and metadata != project:
            raise RuntimeError('Project identity/metadata changed while collecting pages')
        if not isinstance(value.get('sections'), dict) or not isinstance(value.get('pages'), dict):
            raise RuntimeError('Project response lacks section completeness metadata')
        return token, metadata

    def array(self, section, first, view, revision, metadata):
        rows, offset, total = [], 0, None
        response = first
        while True:
            self.envelope(response, view, revision, metadata)
            values = response['sections'].get(section)
            page = response['pages'].get(section)
            if not isinstance(values, list) or not isinstance(page, dict):
                raise RuntimeError('Expected an array page for ' + section)
            for field in ('offset', 'returned', 'total'):
                if type(page.get(field)) is not int or not 0 <= page[field] <= 1_000_000:
                    raise RuntimeError('Invalid project page count: ' + section)
            if total is None:
                total = page['total']
            end = offset + len(values)
            more = end < total
            if (page['total'] != total or page['offset'] != offset or page['returned'] != len(values)
                    or end > total or page.get('has_more') is not more
                    or page.get('complete') is not (offset == 0 and end == total)
                    or page.get('next_offset') != (end if more else None)
                    or (more and not values)):
                raise RuntimeError('Incomplete, stalled or inconsistent project page: ' + section)
            rows.extend(values)
            if not more:
                return rows
            offset = end
            arguments = dict(view=view, offset=offset, limit=64, expected_revision=revision)
            if view == 'scoped':
                arguments['sections'] = [section]
            response = self.call('form_get_project', arguments)

    def snapshot(self, protect=False, first=None, scalar_sections=()):
        initial = first if first is not None else self.call('form_get_project', dict(view='summary', offset=0, limit=64))
        revision, metadata = self.envelope(initial, 'summary')
        snapshot = dict(metadata)
        complete = []
        if not protect:
            snapshot['objects'] = self.array('objects', initial, 'summary', revision, metadata)
            if any(o.get('details_complete') is not False for o in snapshot['objects']):
                raise RuntimeError('Summary object details must be explicitly incomplete')
        requested = ['objects', 'materials', 'recipes', 'notes'] if protect else ['materials', 'notes']
        for section in requested:
            response = self.call('form_get_project', dict(view='scoped', sections=[section], offset=0, limit=64, expected_revision=revision))
            snapshot[section] = self.array(section, response, 'scoped', revision, metadata)
            complete.append(section)
        if (any(not isinstance(s, str) or not s for s in scalar_sections)
                or len(set(scalar_sections)) != len(scalar_sections) or set(scalar_sections) & set(requested)):
            raise ValueError('Additional scalar sections must be distinct named sections')
        for section in scalar_sections:
            response = self.call('form_get_project', dict(view='scoped', sections=[section], expected_revision=revision))
            self.envelope(response, 'scoped', revision, metadata)
            page = response['pages'].get(section)
            if (section not in response['sections'] or not isinstance(page, dict)
                    or page.get('kind') != 'scalar' or page.get('complete') is not True):
                raise RuntimeError('Expected one complete scalar project section: ' + section)
            snapshot[section] = response['sections'][section]
            complete.append(section)
        objects = snapshot['objects']
        if len(objects) != initial.get('object_count') or initial.get('selected_object_count') != len(objects):
            raise RuntimeError('Project object inventory is not complete')
        ids = [o.get('id') for o in objects]
        if any(not isinstance(i, str) or not i for i in ids) or len(set(ids)) != len(ids):
            raise RuntimeError('Project object inventory contains missing or duplicate identities')
        if 'camera' not in snapshot:
            raise RuntimeError('Project metadata is missing the protected camera')
        complete.append('camera')
        snapshot['_project_read'] = dict(revision=revision, complete_sections=complete,
                                         object_inventory_complete=True, object_details_complete=protect)
        return snapshot

    def open(self, project_id, protect=False, scalar_sections=()):
        response = self.call('form_open_project', dict(project_id=project_id, view='summary', offset=0, limit=64))
        for attempt in range(3):
            _, metadata = self.envelope(response, 'summary')
            if metadata['id'] != project_id:
                raise RuntimeError('Opened project identity differs from the explicit target')
            try:
                return self.snapshot(protect=protect, first=response, scalar_sections=scalar_sections)
            except ProjectReadRevisionChanged:
                # Native open-time viewport/hydration updates can legitimately
                # advance the document before its first paged read. Discard
                # every collected field and restart; never merge revisions or
                # reopen again. Ordinary snapshot() reads still fail closed.
                if attempt==2:
                    raise
                response=self.call('form_get_project',dict(view='summary',offset=0,limit=64))
