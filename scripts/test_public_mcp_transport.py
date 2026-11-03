#!/usr/bin/env python3
"""Offline public-helper transport checks; mocks never launch an app/helper."""
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

from validate_paper_packaging import MAXIMUM_MCP_BYTES, Session, decode_public_mcp_response


def response(value, **extra):
    payload = dict(content=[dict(type='text', text=json.dumps(value))],
                   structuredContent=value if isinstance(value, dict) else dict(result=value), isError=False)
    payload.update(extra)
    return dict(jsonrpc='2.0', id=1, result=payload)


class PublicMCPTransportTests(unittest.TestCase):
    def test_large_coherent_edit_uses_existing_stdin_protocol_and_exact_values_with_audit(self):
        args = dict(operations=[dict(name='form_set_artwork', arguments=dict(object_id='source',
                    artwork=dict(elements=[dict(text='"Keep\\n\\nthis" / façade ♥ ' * 15000)])))])
        value = dict(operations=1, undo_groups=1)
        with tempfile.TemporaryDirectory() as folder:
            session = Session(Path(folder)/'LAB.app', '/tmp/not-contacted.sock', Path(folder)/'evidence')
            mocked = SimpleNamespace(returncode=0, stdout=json.dumps(response(value))+'\n', stderr='')
            with patch('validate_paper_packaging.subprocess.run', return_value=mocked) as run:
                self.assertEqual(session.call('form_batch', args), value)
            command = run.call_args.args[0]; options = run.call_args.kwargs
            self.assertEqual(command, [str(session.helper)])
            self.assertEqual(options['timeout'], 240)
            request = json.loads(options['input'])
            self.assertEqual(request, dict(jsonrpc='2.0', id=1, method='tools/call', params=dict(name='form_batch', arguments=args)))
            self.assertEqual(len(options['input'].splitlines()), 1)
            self.assertLess(len(options['input'].encode()), MAXIMUM_MCP_BYTES)
            audit = json.loads((session.output/'requests.jsonl').read_text())
            self.assertEqual(audit['transport'], 'mcp_stdio')
            self.assertEqual(audit['arguments'], args)
            self.assertIn('response_sha256', audit)

    def test_small_existing_cli_path_keeps_literal_json_and_return_type(self):
        args = dict(name='A "quoted" name', text='first\nsecond $(literal)')
        with tempfile.TemporaryDirectory() as folder:
            session = Session(Path(folder)/'LAB.app', '/tmp/not-contacted.sock', Path(folder)/'evidence')
            with patch('validate_paper_packaging.subprocess.run', return_value=SimpleNamespace(returncode=0, stdout='[1,2]', stderr='')) as run:
                self.assertEqual(session.call('form_status', args), [1, 2])
            self.assertEqual(run.call_args.args[0][1:3], ['--call', 'form_status'])
            self.assertEqual(json.loads(run.call_args.args[0][3]), args)
            self.assertNotIn('input', run.call_args.kwargs)

    def test_response_protocol_tool_errors_identity_bounds_and_inconsistent_results_reject(self):
        wrong_identity=response({}); wrong_identity['id']=2
        inconsistent=response({}); inconsistent['result']['structuredContent']={'different':True}
        invalid_content=response({}); invalid_content['result']['content']=None
        cases=[wrong_identity, inconsistent, invalid_content,
               dict(jsonrpc='2.0',id=1,error=dict(code=-32602,message='Unknown tool')),
               response({},isError=True,content=[dict(type='text',text='Rejected canonical source')])]
        for case in cases:
            with self.subTest(case=case):
                with self.assertRaises(ValueError):decode_public_mcp_response(json.dumps(case),1)
        with self.assertRaises(ValueError):decode_public_mcp_response(json.dumps(response({}))+'\n'+json.dumps(response({})),1)
        with self.assertRaisesRegex(ValueError,'Oversized'):decode_public_mcp_response('x'*(MAXIMUM_MCP_BYTES+1),1)
        self.assertEqual(decode_public_mcp_response(json.dumps(response([1,'two'])),1),[1,'two'])

    def test_tool_error_is_audited_and_never_returned_as_success(self):
        args=dict(operations=[dict(name='form_set_artwork',arguments=dict(text='x'*230000))])
        with tempfile.TemporaryDirectory() as folder:
            session=Session(Path(folder)/'LAB.app','/tmp/not-contacted.sock',Path(folder)/'evidence')
            result=SimpleNamespace(returncode=0,stdout=json.dumps(response({},isError=True,content=[dict(type='text',text='Rejected source')])),stderr='')
            with patch('validate_paper_packaging.subprocess.run',return_value=result):
                with self.assertRaisesRegex(RuntimeError,'Public MCP tool error'):session.call('form_batch',args)
            audit=json.loads((session.output/'requests.jsonl').read_text())
            self.assertEqual(audit['transport'],'mcp_stdio')
            self.assertIn('Rejected source',audit['error'])
            self.assertNotIn('response_sha256',audit)

    def test_oversized_request_rejects_before_any_helper_process(self):
        with tempfile.TemporaryDirectory() as folder:
            session=Session(Path(folder)/'LAB.app','/tmp/not-contacted.sock',Path(folder)/'evidence')
            with patch('validate_paper_packaging.subprocess.run') as run:
                with self.assertRaisesRegex(ValueError,'8 MiB'):session.call('form_batch',dict(operations='x'*MAXIMUM_MCP_BYTES))
                run.assert_not_called()


if __name__=='__main__':unittest.main()
