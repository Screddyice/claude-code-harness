#!/usr/bin/env python3
"""Exercise the real Qwen CLI against a deterministic local OpenAI fixture.

QWEN_CODE_TEST_BIN must name an installed Qwen Code cli.js (0.24.1 tested).
No Ollama request, network credential, or existing session is used.
"""
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parent.parent
BIN = os.environ.get('QWEN_CODE_TEST_BIN')


@unittest.skipUnless(BIN, 'set QWEN_CODE_TEST_BIN to the installed cli.js')
class RuntimeTests(unittest.TestCase):
    def run_fixture(self, recover):
        with tempfile.TemporaryDirectory(prefix='qwen-hook-runtime-') as tmp:
            root = Path(tmp)
            (root / 'input.txt').write_text('export const ActualType = 1;\n')
            requests = []
            stage = [0]

            class API(http.server.BaseHTTPRequestHandler):
                def log_message(self, *_):
                    pass

                def do_POST(self):
                    body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                    requests.append(body)
                    text = json.dumps(body.get('messages', []))
                    if recover and 'This inspection already returned the same result twice' in text:
                        if stage[0] == 0:
                            name, args = 'write_file', {'file_path': str(root / 'result.txt'), 'content': 'RECOVERED\n'}
                            stage[0] = 1
                        elif stage[0] == 1:
                            name, args = 'run_shell_command', {'command': 'test -f result.txt && grep -qx RECOVERED result.txt', 'description': 'Verify recovered output'}
                            stage[0] = 2
                        else:
                            name = None
                    else:
                        name, args = 'run_shell_command', {'command': 'grep -n Missing input.txt', 'description': 'Search attempt ' + str(len(requests))}
                    delta = {'role': 'assistant'}
                    if name:
                        delta['tool_calls'] = [{'index': 0, 'id': 'call_' + str(len(requests)), 'type': 'function', 'function': {'name': name, 'arguments': json.dumps(args)}}]
                    else:
                        delta['content'] = 'Recovered and verified the output.'
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/event-stream')
                    self.end_headers()
                    for change, finish in [(delta, None), ({}, 'tool_calls' if name else 'stop')]:
                        item = {'id': 'fixture', 'object': 'chat.completion.chunk', 'created': 0, 'model': 'fixture', 'choices': [{'index': 0, 'delta': change, 'finish_reason': finish}]}
                        self.wfile.write(('data: ' + json.dumps(item) + '\n\n').encode())
                    self.wfile.write(b'data: [DONE]\n\n')

            server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
            url = f'http://127.0.0.1:{server.server_port}/v1'
            cfg = json.loads((ROOT / 'config/qwen-code-local.json').read_text())
            cfg['modelProviders']['openai'] = [{'id': 'fixture', 'envKey': 'OPENAI_API_KEY', 'baseUrl': url, 'generationConfig': {'contextWindowSize': 32768, 'maxRetries': 0}}]
            cfg['model']['name'] = 'fixture'
            cfg['fastModel'] = 'fixture'
            cfg['model']['maxToolCallsPerTurn'] = 10
            cfg['security']['folderTrust'] = {'enabled': False}
            settings = root / 'settings.json'
            settings.write_text(json.dumps(cfg))
            env = dict(os.environ, HOME=tmp, QWEN_CODE_SYSTEM_DEFAULTS_PATH=str(settings),
                       QWEN_HARNESS_ROOT=str(ROOT), QWEN_PROGRESS_STATE_DIR=str(root / 'progress'),
                       QWEN_DISABLE_AUTO_TITLE='1', OPENAI_API_KEY='fixture',
                       OPENAI_BASE_URL=url, QWEN_SESSION_MODEL='fixture', QWEN_FAST_MODEL='fixture', QWEN_LOCAL_BASE_URL=url)
            for key in ['ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'GOOGLE_API_KEY', 'GEMINI_API_KEY']:
                env.pop(key, None)
            proc = subprocess.run(['node', BIN, '--auth-type', 'openai', '--model', 'fixture',
                                   '--openai-base-url', url, '-y', '-p', 'Inspect input.txt, recover from a repeated search, write result.txt and verify it.', '-o', 'stream-json'],
                                  cwd=tmp, env=env, text=True, capture_output=True, timeout=90)
            evidence = proc.stdout + proc.stderr
            self.assertGreater(len(requests), 2, evidence[-5000:])
            model_context = json.dumps(requests)
            self.assertTrue('no matches' in model_context, evidence[-2500:])
            self.assertTrue('This inspection already returned the same result twice' in model_context, evidence[-2500:])
            if recover:
                self.assertEqual((root / 'result.txt').read_text(), 'RECOVERED\n')
                self.assertEqual(proc.returncode, 0, evidence[-5000:])
                self.assertIn('Verify recovered output', evidence)
            else:
                self.assertIn('Qwen progress guard:', evidence)
                self.assertLessEqual(len(requests), 5, evidence[-5000:])
            print(f'Runtime {"recovery" if recover else "hard stop"}: {len(requests)} model requests, exit {proc.returncode}')

    def test_model_can_recover_and_finish(self):
        self.run_fixture(True)

    def test_ignored_redirect_stops_the_actual_runtime(self):
        self.run_fixture(False)


if __name__ == '__main__':
    unittest.main()
