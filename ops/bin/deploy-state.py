#!/usr/bin/env python3
"""Validate a state response for deployment without touching the service."""
import json
import sys


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
    running = state.get("running")
    counts = state.get("counts")
    if not isinstance(running, list) or not isinstance(counts, dict) or counts.get("running") != len(running):
        raise ValueError("invalid running count")
    if not count(counts.get("running")):
        raise ValueError("unknown running count")
    throttle = state.get("throttle")
    busy = throttle.get("busy") if isinstance(throttle, dict) else 0
    if not count(busy):
        raise ValueError("unknown held slots")
    return max(len(running), busy)


if __name__ == "__main__":
    try:
        mode = sys.argv[1]
        running = validate(json.load(sys.stdin), mode)
        if mode == "running":
            print(running)
    except (ValueError, IndexError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
