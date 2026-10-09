#!/usr/bin/env python3
"""Deployment validation, bounded drain policy and journal (no service mutations)."""
import json
import sys
import time
import urllib.request
from pathlib import Path


def count(value):
    return type(value) is int and value >= 0


def validate(state, mode):
    if mode not in ("running", "healthy") or not isinstance(state, dict):
        raise ValueError("invalid deployment state")
    projects = state.get("projects")
    if (
        "error" in state
        or state.get("project") is not None
        or state.get("snapshot_status") != "complete"
        or not isinstance(projects, list)
        or not projects
        or not all(
            isinstance(project, dict)
            and project.get("started") is True
            and "failure" in project
            and project["failure"] is None
            and project.get("snapshot_status") == "ok"
            and count(project.get("running"))
            and count(project.get("ready"))
            for project in projects
        )
    ):
        raise ValueError("incomplete project snapshots")
    if mode == "healthy" and not all(project.get("tracker_ready") is True for project in projects):
        raise ValueError("project tracker not ready")
    running = state.get("running")
    counts = state.get("counts")
    if not isinstance(running, list) or not isinstance(counts, dict) or counts.get("running") != len(running):
        raise ValueError("invalid running count")
    if not count(counts.get("running")):
        raise ValueError("unknown running count")
    throttle = state.get("throttle")
    busy = throttle.get("busy") if isinstance(throttle, dict) else None
    if not count(busy):
        raise ValueError("unknown held slots")
    helpers = throttle.get("helpers")
    helper_busy = 0
    if helpers is not None:
        if not isinstance(helpers, dict) or not count(helpers.get("busy")):
            raise ValueError("unknown helper slots")
        helper_busy = helpers["busy"]
    return max(len(running), busy) + helper_busy


def events(root):
    # ponytail: scan the existing journal; index it if deployment polling becomes slow.
    try:
        lines = (root / "deploys.jsonl").read_text().splitlines()
    except FileNotFoundError:
        return []
    result = []
    for line in lines:
        try:
            event = json.loads(line)
            if isinstance(event, dict):
                result.append(event)
        except ValueError:
            continue  # An interrupted append must not hide earlier retry deadlines.
    return result


def record(root, outcome, target, **fields):
    root.mkdir(parents=True, exist_ok=True)
    event = dict(at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                 outcome=outcome, release=target, **fields)
    with (root / "deploys.jsonl").open("ab+") as journal:
        if journal.tell():
            journal.seek(-1, 2)
            if journal.read(1) != b"\n":
                journal.write(b"\n")  # Separate an interrupted append from the next event.
        journal.write((json.dumps(event) + "\n").encode())


def retry_until(root):
    return max((event.get("retry_until", 0) for event in events(root)), default=0)


def drain(root, target, observe, limit, pause, token, force=False,
          clock=time.monotonic, wall=time.time, sleep=time.sleep):
    if limit <= 0 or pause <= 0:
        raise ValueError("drain limit and dispatch pause must be positive")

    def snapshot():
        try:
            state = observe()
            return state, validate(state, "running")
        except (ValueError, OSError):
            return None, None

    state, running = snapshot()
    paused = wall() < retry_until(root)
    if not force and running != 0 and paused:
        return 3  # Busy or unknown: leave dispatch open throughout the retry pause.
    root.mkdir(parents=True, exist_ok=True)
    try:
        with (root / "drain").open("x") as flag:
            flag.write(token)
    except FileExistsError as error:
        raise ValueError("drain already held") from error
    started = clock()
    record(root, "drain_started", target, token=token, started_epoch=wall(),
           pause_seconds=pause, retry_until=wall() + limit + pause)
    state, running = snapshot()  # Recheck after holding dispatch; the preflight can race a new worker.
    if not force and running != 0 and paused:
        return 3
    while True:
        now = clock()
        fields = dict(token=token, elapsed_seconds=now - started, observed_epoch=wall(),
                      running=running)
        if state is not None:
            throttle = state["throttle"]
            fields.update(ready=sum(project["ready"] for project in state["projects"]),
                          busy=throttle["busy"], service_slots=throttle.get("service_slots"),
                          quota_paused=throttle.get("paused"), over_budget=throttle.get("over_budget"))
        record(root, "drain_sample", target, **fields)
        if force or running == 0:
            return 0
        if now - started >= limit:
            return 2
        sleep(min(30, limit - (now - started)))
        state, running = snapshot()


def finish(root, target, token, outcome, wall=time.time):
    flag = root / "drain"
    if not flag.exists() or flag.read_text() != token:
        return
    try:
        history = [event for event in events(root) if event.get("token") == token]
        start = next((event for event in reversed(history) if event["outcome"] == "drain_started"), None)
        if start is None:
            return  # Failed journal append: still release our hold.
        sample = next((event for event in reversed(history) if event["outcome"] == "drain_sample"), {})
        idle_seconds = 0
        if sample.get("running") == 0:
            idle_seconds += max(0, wall() - sample["observed_epoch"])
        record(root, "drain_finished", target, token=token, result=outcome, idle_seconds=idle_seconds,
               elapsed_seconds=max(0, wall() - start["started_epoch"]),
               retry_until=wall() + start["pause_seconds"])
    finally:
        if flag.exists() and flag.read_text() == token:
            flag.unlink()


def main(args):
    mode = args[0]
    if mode == "drain":
        root, target, url, limit, pause, token, force = args[1:]

        def observe():
            with urllib.request.urlopen(url, timeout=10) as response:
                return json.load(response)

        return drain(Path(root), target, observe, int(limit), int(pause), token, force == "0")
    if mode == "finish":
        root, target, token, outcome = args[1:]
        finish(Path(root), target, token, outcome)
        return 0
    running = validate(json.load(sys.stdin), mode)
    if mode == "running":
        print(running)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (ValueError, IndexError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
