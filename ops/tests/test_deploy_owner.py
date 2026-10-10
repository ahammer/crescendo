"""Owner exit, cancellation and interrupted swap against an isolated deploy copy."""
import json
import os
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from unittest.mock import patch

from test_deploy_drain import policy, state


class OwnerPolicyTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "deploy-drain.lock").touch()
        self.target = "b" * 40

    def acquire(self, token="private-owner"):
        return policy.drain(self.root, self.target, lambda: state(0), 300, 1800, token)

    def test_live_owner_never_expires_and_restart_observation_preserves_it(self):
        with policy.owner_lock(self.root) as acquired:
            self.assertTrue(acquired)
            self.acquire()
            with patch.object(policy.time, "time", return_value=time.time() + 1000000):
                first = policy.observe(self.root)
                second = policy.observe(self.root)
            self.assertEqual(first, second)
            self.assertEqual(first["owner_status"], "live")
            self.assertNotIn("private-owner", json.dumps(first))
            policy.swap(self.root, self.target, "private-owner")
            self.assertEqual(policy.observe(self.root)["phase"], "swapping")
        self.assertEqual(policy.observe(self.root)["owner_status"], "recovery_required")
        self.assertTrue((self.root / "deploy-drain.json").exists())

    def test_dead_waiting_owner_releases_without_touching_manual_and_newer_owner(self):
        self.acquire("old")
        (self.root / "drain").write_text("intentional manual")
        self.assertIsNone(policy.observe(self.root, reconcile=True))
        self.assertEqual((self.root / "drain").read_text(), "intentional manual")
        (self.root / "drain").unlink()
        with policy.owner_lock(self.root):
            self.acquire("new")
            policy.finish(self.root, self.target, "old", "cancelled")
            self.assertEqual(policy.observe(self.root)["owner_status"], "live")
            self.assertEqual(policy.managed(self.root)["token"], "new")
        self.assertTrue(all("token" not in event for event in policy.events(self.root)))

    def test_swap_cancellation_journal_failure_and_recovery_fail_closed(self):
        self.acquire()
        policy.swap(self.root, self.target, "private-owner")
        policy.finish(self.root, self.target, "private-owner", "cancelled")
        self.assertEqual(policy.observe(self.root)["owner_status"], "recovery_required")
        self.assertEqual(policy.recover(self.root), self.target)
        with patch.object(policy, "record", side_effect=OSError("unavailable")):
            with self.assertRaises(OSError):
                policy.main(["recovered", str(self.root), self.target])
        self.assertIsNotNone(policy.managed(self.root))
        policy.main(["recovered", str(self.root), self.target])
        self.assertIsNone(policy.observe(self.root, reconcile=True))
        self.assertEqual(policy.events(self.root)[-1]["result"], "recovered")


class OwnerShellTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "deploy-drain.lock").touch()
        self.install, self.config, self.journal, self.commands, self.scripts = [
            self.root / name for name in ("install", "config", "state", "commands", "scripts")]
        for directory in (self.install / "source.git", self.config, self.commands, self.scripts):
            directory.mkdir(parents=True)
        self.old = self.install / "releases" / ("a" * 40)
        self.new = self.install / "releases" / ("b" * 40)
        self.new.mkdir(parents=True)
        (self.new / ".built").touch()
        installer = self.new / "source/ops/install.sh"
        installer.parent.mkdir(parents=True)
        installer.write_text("exit 0\n")
        self.env_file = self.config / "service.env"
        self.original = f'CRESCENDO_RELEASE="{self.old}"\n'
        self.env_file.write_text(self.original)
        for name in ("deploy", "deploy-state.py"):
            shutil.copyfile(Path(__file__).parents[1] / "bin" / name, self.scripts / name)
        self.snapshot = state(1)
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps(outer.snapshot).encode())

            def log_message(self, *args):
                pass

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        health = self.root / "healthy.json"
        health.write_text(json.dumps(state(0)))
        scripts = {
            "git": '#!/bin/sh\ncase "$*" in *rev-parse*) echo "$TEST_TARGET" ;; esac\n',
            "sleep": "#!/bin/sh\nexit 0\n",
            "curl": '#!/bin/sh\ncat "$TEST_HEALTH"\n',
            "systemctl": """#!/usr/bin/env python3
import os, time
from pathlib import Path
root = Path(os.environ['TEST_ROOT'])
(root / 'restarting').write_text(str(os.getpid()))
with (root / 'restarts').open('a') as output:
    output.write(Path(os.environ['TEST_ENV']).read_text())
while (root / 'block-swap').exists():
    time.sleep(0.01)
raise SystemExit(1 if (root / 'fail-restart').exists() else 0)
""",
        }
        for name, script in scripts.items():
            file = self.commands / name
            file.write_text(script)
            file.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.commands) + os.pathsep + os.environ["PATH"],
                        CRESCENDO_INSTALL_ROOT=str(self.install), CRESCENDO_CONFIG_DIR=str(self.config),
                        CRESCENDO_STATE_DIR=str(self.journal), CRESCENDO_PORT=str(self.server.server_port),
                        CRESCENDO_UNIT="isolated-test.service", TEST_TARGET=self.new.name,
                        TEST_ROOT=str(self.root), TEST_ENV=str(self.env_file), TEST_HEALTH=str(health))
        self.processes = []
        self.addCleanup(self.stop_processes)

    def stop_server(self):
        self.server.shutdown()
        self.thread.join()
        self.server.server_close()

    def stop_processes(self):
        for process in self.processes:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate(timeout=5)

    def start(self):
        process = subprocess.Popen(["sh", str(self.scripts / "deploy")], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        self.processes.append(process)
        return process

    def wait_for(self, predicate):
        deadline = time.monotonic() + 5
        while not predicate():
            if time.monotonic() > deadline:
                self.fail("isolated owner did not reach the expected phase")
            time.sleep(0.01)

    def test_cancellation_releases_pre_swap_owner(self):
        process = self.start()
        self.wait_for(lambda: (self.journal / "deploy-drain.json").exists())
        os.killpg(process.pid, signal.SIGTERM)
        process.communicate(timeout=5)
        self.assertEqual(process.returncode, 130)
        self.assertIsNone(policy.managed(self.journal))
        self.assertEqual(policy.events(self.journal)[-1]["result"], "cancelled")

    def test_abrupt_exit_reconciles_and_a_new_deployment_runs(self):
        process = self.start()
        self.wait_for(lambda: (self.journal / "deploy-drain.json").exists())
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate(timeout=5)
        self.assertIsNotNone(policy.managed(self.journal))
        self.assertIsNone(policy.observe(self.journal, reconcile=True))
        self.assertEqual(policy.events(self.journal)[-1]["result"], "abandoned")
        self.snapshot = state(0)
        resumed = self.start()
        output = resumed.communicate(timeout=5)
        self.assertEqual(resumed.returncode, 0, output)
        self.assertIsNone(policy.managed(self.journal))
        self.assertEqual(policy.events(self.journal)[-1]["result"], "deployed")

    def test_live_swap_child_and_interrupted_swap_roll_back_before_same_target_exit(self):
        self.snapshot = state(0)
        blocker = self.root / "block-swap"
        blocker.touch()
        process = self.start()
        self.wait_for(lambda: (self.root / "restarting").exists())
        self.assertEqual(policy.observe(self.journal)["owner_status"], "live")
        os.kill(process.pid, signal.SIGKILL)  # A live restart child retains the owner lock.
        process.wait(timeout=5)
        self.assertEqual(policy.observe(self.journal)["owner_status"], "live")
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate(timeout=5)
        self.assertEqual(policy.observe(self.journal)["owner_status"], "recovery_required")
        self.assertNotEqual(self.env_file.read_text(), self.original)
        blocker.unlink()
        resumed = self.start()
        output = resumed.communicate(timeout=5)
        self.assertEqual(resumed.returncode, 0, output)
        self.assertEqual(self.env_file.read_text(), self.original)
        self.assertIsNone(policy.managed(self.journal))
        self.assertTrue((self.new / ".failed").exists())
        self.assertEqual(policy.events(self.journal)[-1]["outcome"], "swap_recovered")

    def test_failed_interrupted_swap_rollback_keeps_admission_held(self):
        self.snapshot = state(0)
        blocker = self.root / "block-swap"
        blocker.touch()
        process = self.start()
        self.wait_for(lambda: (self.root / "restarting").exists())
        os.killpg(process.pid, signal.SIGTERM)
        process.communicate(timeout=5)
        self.assertEqual(policy.observe(self.journal)["owner_status"], "recovery_required")
        self.assertEqual(policy.events(self.journal)[-1]["result"], "cancelled")
        blocker.unlink()
        (self.root / "fail-restart").touch()
        resumed = self.start()
        resumed.communicate(timeout=5)
        self.assertEqual(resumed.returncode, 1)
        self.assertEqual(policy.observe(self.journal)["owner_status"], "recovery_required")


if __name__ == "__main__":
    unittest.main()
