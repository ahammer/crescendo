"""Deterministic protocol peer: no model calls or native tools execute."""
import json
import sys
import os

observed, mode = sys.argv[1:3]
if sys.argv[-3:] == ["mcp", "list", "--json"]:
    print(json.dumps([{"name": "inherited-server", "enabled": True}]))
    sys.exit(0)


def emit(message):
    print(json.dumps(message), flush=True)


with open(observed, "a", encoding="utf-8") as log:
    if "--config" in sys.argv:
        with open("/proc/self/fd/198") as source:
            catalog = json.load(source)
        try:
            os.write(198, b"changed")
        except OSError:
            pass
        else:
            raise RuntimeError("Catalog was mutable")
        log.write(json.dumps({"catalog": catalog}) + "\n")
    log.write(json.dumps({"argv": sys.argv[3:]}) + "\n")
    log.flush()
    for line in sys.stdin:
        message = json.loads(line)
        log.write(json.dumps(message) + "\n")
        log.flush()
        method, request_id = message.get("method"), message.get("id")
        if method == "initialize":
            emit({"id": request_id, "result": {}})
        elif method == "thread/start":
            emit({"id": request_id, "result": {"thread": {"id": "helper-thread"}}})
        elif method == "turn/start":
            emit({"id": request_id, "result": {"turn": {"id": "helper-turn"}}})
            if mode == "approval":
                emit({"id": 100, "method": "item/commandExecution/requestApproval", "params": {"command": "touch escaped"}})
            elif mode == "large-previews":
                changes = {f"evidence/{n}.json": {"type": "update", "content": "x" * 310_080} for n in range(19)}
                emit({"method": "item/completed", "params": {"item": {"type": "FileChange", "id": "file-change", "status": "completed", "changes": changes}}})
                emit({"method": "item/completed", "params": {"item": {"type": "fileChange", "id": "legacy", "changes": [{"path": "legacy.txt", "diff": "d" * 946_606}]}}})
                item = {"type": "DynamicToolCall", "id": "tool-call", "status": "completed", "arguments": {"query": "preserve" * 3000}, "content_items": [{"type": "inputText", "text": "t" * 152_336}]}
                emit({"method": "item/completed", "params": {"item": item}})
                emit({"id": 101, "method": "item/tool/call", "params": {"tool": "read_source", "arguments": {"operation": "list", "query": "argument" * 3000}}})
            else:
                emit({"id": 102, "method": "item/tool/call", "params": {"tool": "read_source", "arguments": {"operation": "read", "path": "source.txt"}}})
                emit({"method": "item/agentMessage/delta", "params": {"delta": "partial"}})
                emit({"method": "item/completed", "params": {"item": {"type": "agentMessage", "id": "answer", "text": "Pinned source observations. " + "a" * 18_000}}})
                emit({"method": "turn/completed", "params": {"turn": {"status": "completed"}}})
        elif request_id == 101 and "result" in message:
            emit({"method": "turn/completed", "params": {"turn": {"status": "completed", "items": [{"type": "agentMessage", "id": "final", "text": "z" * 1_000_000}], "usage": {"total_tokens": 77}}}})
