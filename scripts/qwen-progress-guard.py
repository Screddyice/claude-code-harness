#!/usr/bin/env python3
"""Redirect repeated, unchanged inspections through Qwen Code's hook contract.

Store only digests, scoped to a session/agent/cwd. Never approve a tool or replay
one: an empty response preserves the client's normal permission policy.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sys

READ_TOOLS = {'read_file', 'grep_search', 'glob'}
WINDOW = 12
STOP_REASON = 'Qwen progress guard: repeated unchanged inspection after two redirects. Start a fresh session with a smaller, testable objective.'
REDIRECT = ('This inspection already returned the same result twice. Do not repeat it. '
            'Use a different search pattern or path, inspect an import or definition, '
            'or make the next supported edit and run its test. A grep/rg exit code 1 '
            'with no error means no matches; it is not a tool failure.')


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def guarded(name, args):
    if name in READ_TOOLS:
        return True
    if name != 'run_shell_command' or not isinstance(args.get('command'), str):
        return False
    # Only simple searches, optionally preceded by the common `cd path &&`.
    command = re.sub(r'^\s*cd\s+[^;&\n]+&&\s*', '', args['command'], count=1)
    return bool(re.match(r'^\s*(grep|rg)\s', command)) and not re.search(r'[;&|<>`$\n]', command)


def response_payload(response):
    if isinstance(response, dict) and 'llmContent' in response:
        text = json.dumps(response['llmContent'], sort_keys=True)
        return re.sub(r'Process Group PGID: \d+', 'Process Group PGID: <pid>', text)
    parts = response.get('response_parts', []) if isinstance(response, dict) else []
    payload = [part['functionResponse'].get('response') for part in parts
               if isinstance(part, dict) and isinstance(part.get('functionResponse'), dict)]
    # Do not hash call ids, duration, display metadata, or shell PGIDs.
    text = json.dumps(payload if payload else response, sort_keys=True)
    return re.sub(r'Process Group PGID: \d+', 'Process Group PGID: <pid>', text)


def decide(data, state):
    event = data.get('hook_event_name')
    name = data.get('tool_name')
    args = data.get('tool_input') or {}
    response = data.get('tool_response') or {}
    if event == 'UserPromptSubmit':
        prompt_id = data.get('prompt_id')
        # Qwen also fires this hook on empty tool-result continuations.
        # Those retain the prompt id and must not erase the loop evidence.
        if (prompt_id and prompt_id != state.get('prompt_id')) or (not prompt_id and data.get('prompt')):
            state.clear()
            state['prompt_id'] = prompt_id
        if state.get('halted'):
            return {'continue': False, 'stopReason': STOP_REASON}
        return {}
    if (
        event == 'PostToolUse' and name in {'edit', 'write_file'}
        and not response.get('error') and response.get('execution_status') != 'error'
    ):
        prompt_id = state.get('prompt_id')
        state.clear()
        state['prompt_id'] = prompt_id
        return {}
    if not guarded(name, args):
        return {}
    key = digest([name, {k: v for k, v in args.items() if k != 'description'}])
    history = state.setdefault('history', [])
    denials = state.setdefault('denials', {})
    prior = [item[1] for item in history if item[0] == key]
    if event == 'PreToolUse' and len(prior) >= 2 and prior[-1] == prior[-2]:
        denials[key] = denials.get(key, 0) + 1
        if denials[key] >= 3:
            # Do not include permissionDecision=deny: Qwen handles that before
            # continue=false and would turn a hard stop into another retry.
            state['halted'] = True
            return {'continue': False, 'stopReason': STOP_REASON}
        return {'hookSpecificOutput': {'hookEventName': event,
                'permissionDecision': 'deny', 'permissionDecisionReason': REDIRECT}}
    if event == 'PostToolUse':
        payload = response_payload(response)
        fingerprint = digest(payload)
        if prior and prior[-1] != fingerprint:
            denials.pop(key, None)
        history.append([key, fingerprint])
        del history[:-WINDOW]
        active = {item[0] for item in history}
        state['denials'] = {k: v for k, v in denials.items() if k in active}
        if name == 'run_shell_command' and re.search(r'Exit Code: 1(?:\\n|\n|$)', payload) and 'Error: (none)' in payload:
            return {'hookSpecificOutput': {'hookEventName': event, 'additionalContext':
                    'The search completed with no matches (exit code 1). Change the pattern or search scope; do not retry the identical command.'}}
    return {}


def main():
    data = json.load(sys.stdin)
    if not data.get('session_id'):
        print('{}')
        return
    root = Path(os.environ.get('QWEN_PROGRESS_STATE_DIR', str(Path.home() / '.cache/qwen/progress')))
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    key = digest([data['session_id'], data.get('agent_id'), data.get('cwd')])
    path = root / (key + '.json')
    # One lock per session prevents concurrent tools from losing each other's
    # observations. Atomic replacement leaves the prior state on interruption.
    with (root / (key + '.lock')).open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            state = json.loads(path.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            state = {}
        result = decide(data, state)
        tmp = root / (key + f'.{os.getpid()}.tmp')
        tmp.write_text(json.dumps(state))
        os.chmod(tmp, 0o600)
        tmp.replace(path)
    print(json.dumps(result))


if __name__ == '__main__':
    main()
