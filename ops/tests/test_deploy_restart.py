"""Run the real deploy shell against temporary releases and fake service commands."""
import json
import os
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from test_deploy_drain import state


class RestartTest(unittest.TestCase):
    def check_rollback(self, restart_fails):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            install, config, journal, commands = [root / name for name in ("install", "config", "state", "commands")]
            for directory in (install / "source.git", config, commands):
                directory.mkdir(parents=True)
            old = install / "releases" / ("a" * 40)
            new = install / "releases" / ("b" * 40)
            new.mkdir(parents=True)
            (new / ".built").touch()
            env_file = config / "service.env"
            original = f'CRESCENDO_RELEASE="{old}"\n'
            env_file.write_text(original)
            snapshot = json.dumps(state(0)).encode()

            class Handler(BaseHTTPRequestHandler):
                def do_GET(self):
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(snapshot)

                def log_message(self, *args):
                    pass

            server = HTTPServer(("127.0.0.1", 0), Handler)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                scripts = {
                    "git": '#!/bin/sh\ncase "$*" in *rev-parse*) printf "%s\\n" "$TEST_TARGET" ;; esac\n',
                    "sleep": "#!/bin/sh\nexit 0\n",
                    "curl": "#!/bin/sh\nprintf '{}\\n'\n",
                    "systemctl": """#!/usr/bin/env python3
import os
from pathlib import Path
log = Path(os.environ['TEST_RESTART_LOG'])
with log.open('a') as output:
    output.write(Path(os.environ['TEST_ENV_FILE']).read_text())
raise SystemExit(1 if os.environ['TEST_RESTART_FAIL'] == '1' and len(log.read_text().splitlines()) == 1 else 0)
""",
                }
                for name, script in scripts.items():
                    path = commands / name
                    path.write_text(script)
                    path.chmod(0o755)
                log = root / "restarts.log"
                environment = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"],
                                   CRESCENDO_INSTALL_ROOT=str(install), CRESCENDO_CONFIG_DIR=str(config),
                                   CRESCENDO_STATE_DIR=str(journal), CRESCENDO_PORT=str(server.server_port),
                                   TEST_TARGET=new.name, TEST_RESTART_LOG=str(log), TEST_ENV_FILE=str(env_file),
                                   TEST_RESTART_FAIL="1" if restart_fails else "0")
                result = subprocess.run(["sh", str(Path(__file__).parents[1] / "bin/deploy")],
                                        env=environment, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(env_file.read_text(), original)
                self.assertEqual(log.read_text().splitlines(), [f'CRESCENDO_RELEASE="{new}"', original.strip()])
                self.assertTrue((new / ".failed").exists())
                self.assertFalse((journal / "drain").exists())
                events = [json.loads(line) for line in (journal / "deploys.jsonl").read_text().splitlines()]
                self.assertTrue(any(event["outcome"] == "rolled_back" for event in events))
                self.assertEqual(events[-1]["result"], "rolled_back")
            finally:
                server.shutdown()
                worker.join()
                server.server_close()

    def test_restart_failure_restores_previous_release_and_releases_drain(self):
        self.check_rollback(restart_fails=True)

    def test_failed_health_after_restart_uses_the_same_rollback(self):
        self.check_rollback(restart_fails=False)


if __name__ == "__main__":
    unittest.main()
