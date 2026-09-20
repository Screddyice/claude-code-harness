#!/usr/bin/env python3
"""Regression tests for repeated Qwen searches across malformed tool calls."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('qwen-progress-guard.py')


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = dict(os.environ, QWEN_PROGRESS_STATE_DIR=self.tmp.name)

    def call(self, event='PreToolUse', name='run_shell_command', args=None,
             result=None, session='test', **fields):
        data = dict(hook_event_name=event, session_id=session, cwd='/repo',
                    tool_name=name, tool_input=args or {'command': 'cd /repo && grep -rn "ToolType" src/index.ts'}, **fields)
        if result is not None:
            data['tool_response'] = result
        if not SCRIPT.exists():
            return {}  # Baseline: launcher has no progress hook.
        p = subprocess.run(['python3', str(SCRIPT)], input=json.dumps(data),
                           text=True, capture_output=True, env=self.env, check=True)
        return json.loads(p.stdout or '{}')

    def result(self, pgid=100, text='(empty)'):
        return {'response_parts': [{'functionResponse': {'id': str(pgid), 'name': 'run_shell_command',
                'response': {'output': f'Output: {text}\nError: (none)\nExit Code: 1\nProcess Group PGID: {pgid}'}}}]}

    def executed(self, **kwargs):
        self.call(**kwargs)
        return self.call(event='PostToolUse', result=self.result(), **kwargs)

    def test_same_empty_search_with_interleaved_malformed_call_is_denied(self):
        self.executed()
        self.call(args={'function': 'grep ToolType src/index.ts'})
        self.call('PostToolUseFailure', args={'function': 'grep ToolType src/index.ts'}, error='missing command')
        self.call('PostToolUse', result=self.result(200), args={'description': 'another description', 'command': 'cd /repo && grep -rn "ToolType" src/index.ts'})
        out = self.call()
        self.assertEqual(out.get('hookSpecificOutput', {}).get('permissionDecision'), 'deny')
        self.assertIn('different', out['hookSpecificOutput']['permissionDecisionReason'])

    def test_no_match_explanation_reaches_model(self):
        out = self.executed()
        self.assertIn('no matches', out.get('hookSpecificOutput', {}).get('additionalContext', ''))

    def test_persistent_retries_stop_without_allowing_permission_bypass(self):
        self.call('UserPromptSubmit', prompt_id='p1', prompt='task')
        self.executed(); self.executed()
        self.call(); self.call()
        out = self.call()
        self.assertIs(out.get('continue'), False)
        self.assertNotIn('permissionDecision', out.get('hookSpecificOutput', {}))
        self.assertIs(self.call('UserPromptSubmit', prompt_id='p1', prompt='').get('continue'), False)

    def test_changing_results_allow_polling(self):
        for n in range(4):
            out = self.call()
            self.assertEqual(out, {})
            self.call('PostToolUse', result=self.result(n, str(n)))

    def test_successful_edit_and_user_prompt_reset(self):
        for event in ['PostToolUse', 'UserPromptSubmit']:
            self.executed(); self.executed()
            self.call(event, name='edit', result={'execution_status': 'success'}, prompt='new task')
            self.assertEqual(self.call(), {})

    def test_tool_continuation_does_not_reset_prompt_history(self):
        self.call('UserPromptSubmit', prompt_id='p1', prompt='task')
        self.executed()
        self.call('UserPromptSubmit', prompt_id='p1', prompt='')
        self.executed()
        self.call('UserPromptSubmit', prompt_id='p1', prompt='')
        self.assertEqual(self.call()['hookSpecificOutput']['permissionDecision'], 'deny')
        self.call('UserPromptSubmit', prompt_id='p2', prompt='new task')
        self.assertEqual(self.call(), {})

    def test_failed_edit_does_not_reset(self):
        self.executed(); self.executed()
        self.call('PostToolUseFailure', name='edit', error='not found')
        self.assertEqual(self.call()['hookSpecificOutput']['permissionDecision'], 'deny')

    def test_new_session_and_new_search_are_independent(self):
        self.executed(); self.executed()
        self.assertEqual(self.call(session='other'), {})
        self.assertEqual(self.call(args={'command': 'rg ToolType src/'}), {})

    def test_non_search_commands_are_not_guarded_or_approved(self):
        for _ in range(5):
            self.executed(args={'command': 'pytest -q'})
            self.assertEqual(self.call(args={'command': 'pytest -q'}), {})

    def test_read_file_detects_same_result_despite_call_ids(self):
        args = {'file_path': '/repo/src/index.ts'}
        for i in range(2):
            self.call('PostToolUse', name='read_file', args=args, result={'response_parts': [{'functionResponse': {'id': str(i), 'response': {'output': 'unchanged'}}}]})
        self.assertEqual(self.call(name='read_file', args=args)['hookSpecificOutput']['permissionDecision'], 'deny')

    def test_native_scheduler_payload_ignores_display_and_pgid(self):
        for i in range(2):
            self.call('PostToolUse', result={'llmContent': f'Output: (empty)\nError: (none)\nExit Code: 1\nProcess Group PGID: {i}', 'returnDisplay': str(i)})
        self.assertEqual(self.call()['hookSpecificOutput']['permissionDecision'], 'deny')

    def test_state_does_not_store_commands_or_results(self):
        self.executed()
        content = ''.join(p.read_text() for p in Path(self.tmp.name).glob('*.json'))
        self.assertNotIn('ToolType', content)
        self.assertNotIn('Process Group', content)


if __name__ == '__main__':
    unittest.main()
