"""Isolated lifecycle checks: no service, units, network or deployment script."""
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("deploy_state", Path(__file__).parents[1] / "bin/deploy-state.py")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


def state(running=1, ready=4, paused=None, budget=None):
    return dict(snapshot_status="complete", project=None,
                projects=[dict(started=True, failure=None, snapshot_status="ok", running=running, ready=ready)],
                running=[{}] * running, counts=dict(running=running),
                throttle=dict(busy=running, service_slots=3, paused=paused, over_budget=budget))


class DrainTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.now = 10000

    def sleep(self, seconds):
        self.now += seconds

    def drain(self, observe=lambda: state(), target="a", token="owner", **options):
        return policy.drain(self.root, target, observe, 300, 1800, token,
                            clock=lambda: self.now, wall=lambda: self.now, sleep=self.sleep, **options)

    def finish(self, outcome="postponed", target="a", token="owner"):
        policy.finish(self.root, target, token, outcome, wall=lambda: self.now)

    def test_long_worker_and_queue_get_dispatch_between_repeated_timer_drains(self):
        dispatched = 0
        holds = 0
        # One worker lasts longer than two old 7200-second waits; queued work remains available.
        for tick in range(0, 16201, 600):
            self.now = 10000 + tick
            result = self.drain()
            if result == 2:
                holds += 1
                self.finish()
            else:
                self.assertEqual(result, 3)
            self.assertFalse((self.root / "drain").exists())
            dispatched += 1  # Governor can acquire: the shared hold is absent.
        self.assertGreater(dispatched, 20)
        self.assertLess(holds * 300, 16200 / 4)
        samples = [event for event in policy.events(self.root) if event["outcome"] == "drain_sample"]
        self.assertTrue(all(event["running"] == 1 and event["ready"] == 4 for event in samples))

    def test_new_candidate_cannot_bypass_pause_but_idle_deploys_promptly(self):
        self.assertEqual(self.drain(), 2)
        self.finish()
        self.assertEqual(self.drain(target="new"), 3)
        self.assertEqual(self.drain(lambda: state(0), target="new"), 0)
        self.sleep(15)
        self.finish("deployed", target="new")
        event = policy.events(self.root)[-1]
        self.assertEqual(event["idle_seconds"], 15)
        self.assertEqual(event["elapsed_seconds"], 15)
        self.assertFalse((self.root / "drain").exists())

    def test_preflight_empty_is_rechecked_after_dispatch_is_held(self):
        observations = iter([state(0)] + [state()] * 20)
        self.assertEqual(self.drain(lambda: next(observations)), 2)
        self.finish()

    def test_idle_preflight_race_cannot_take_busy_drain_during_pause(self):
        self.assertEqual(self.drain(), 2)
        self.finish()
        observations = iter([state(0), state()])
        self.assertEqual(self.drain(lambda: next(observations)), 3)
        self.finish("cancelled")
        self.assertFalse((self.root / "drain").exists())

    def test_release_even_if_journal_start_append_failed(self):
        (self.root / "drain").write_text("owner")
        self.finish("cancelled")
        self.assertFalse((self.root / "drain").exists())

    def test_unknown_snapshots_and_network_timeouts_fail_closed(self):
        for index, observation in enumerate((lambda: {}, lambda: (_ for _ in ()).throw(TimeoutError()))):
            if index:
                self.sleep(2100)
            self.assertEqual(self.drain(observation), 2)
            self.finish()
        self.assertEqual(self.drain(lambda: {}), 3)

    def test_cancelled_observation_releases_hold_and_preserves_dispatch_pause(self):
        calls = 0

        def cancelled():
            nonlocal calls
            calls += 1
            if calls == 2:
                raise KeyboardInterrupt()
            return state()

        try:
            with self.assertRaises(KeyboardInterrupt):
                self.drain(cancelled)
        finally:
            self.finish("cancelled")
        self.assertFalse((self.root / "drain").exists())
        self.assertEqual(self.drain(), 3)

    def test_cancellation_swap_failure_rollback_and_success_release_owned_hold(self):
        for outcome in ("cancelled", "swap_failed", "rolled_back", "deployed"):
            self.assertEqual(self.drain(lambda: state(0)), 0)
            self.assertTrue((self.root / "drain").exists())
            self.finish(outcome)
            self.finish(outcome)  # EXIT after early cleanup is harmless.
            self.assertFalse((self.root / "drain").exists())
            self.assertEqual(policy.events(self.root)[-1]["result"], outcome)
        # Gate failure occurs before acquiring any hold.
        policy.record(self.root, "gate_failed", "bad")
        self.assertFalse((self.root / "drain").exists())

    def test_manual_hold_and_other_owner_are_preserved(self):
        (self.root / "drain").write_text("manual")
        with self.assertRaisesRegex(ValueError, "already held"):
            self.drain(lambda: state(0))
        self.finish()
        self.assertEqual((self.root / "drain").read_text(), "manual")

    def test_manual_hold_enabled_during_cleanup_is_preserved(self):
        self.assertEqual(self.drain(lambda: state(0)), 0)
        flag = self.root / "drain"

        def manual_takeover():
            flag.write_text("manual")
            return self.now

        policy.finish(self.root, "a", "owner", "deployed", wall=manual_takeover)
        self.assertEqual(flag.read_text(), "manual")

    def test_observations_keep_quota_budget_and_no_ready_work_separate(self):
        self.assertEqual(self.drain(lambda: state(0, 0, "quota", "budget")), 0)
        self.sleep(10)
        self.finish("deployed")
        sample = policy.events(self.root)[1]
        self.assertEqual((sample["ready"], sample["quota_paused"], sample["over_budget"]), (0, "quota", "budget"))
        self.assertEqual(sample["service_slots"], 3)
        self.assertEqual(policy.events(self.root)[-1]["idle_seconds"], 10)

    def test_interrupted_append_and_missing_finish_keep_retry_pause(self):
        self.assertEqual(self.drain(), 2)
        # Simulate an uncatchable kill: start record still protects the retry interval.
        (self.root / "drain").unlink()
        with (self.root / "deploys.jsonl").open("a") as journal:
            journal.write('{"interrupted":\n')
        self.assertEqual(self.drain(target="new"), 3)

    def test_truncated_journal_tail_preserves_the_next_drain_retry_pause(self):
        (self.root / "deploys.jsonl").write_text('{"interrupted":')
        self.assertEqual(self.drain(), 2)
        self.finish()
        self.assertEqual(policy.retry_until(self.root), self.now + 1800)
        self.assertEqual(self.drain(target="new"), 3)
        self.assertFalse((self.root / "drain").exists())

    def test_force_is_explicit_and_invalid_limits_never_acquire(self):
        self.assertEqual(self.drain(force=True), 0)
        self.finish("deployed")
        with self.assertRaisesRegex(ValueError, "positive"):
            policy.drain(self.root, "a", lambda: state(), 0, 1800, "owner")
        self.assertFalse((self.root / "drain").exists())


if __name__ == "__main__":
    unittest.main()
