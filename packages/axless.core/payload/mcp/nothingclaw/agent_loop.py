"""Autonomous agent loop for NothingClaw.

Everything else in `server.py` is a *passive* tool surface: the model on the
other end of the HTTP bridge decides what to call. This module adds the piece
every real agent has - a loop that drives the tools itself.

Design notes (why it looks the way it does)
-------------------------------------------
The shape follows the standard minimal-agent pattern that Aider, smolagents
and Anthropic's "building effective agents" all converge on:

    goal -> model -> (tool_calls | final answer) -> execute -> observe -> repeat

Three rules keep small models usable, which is the whole reason this is
separate from the tool dispatcher:

1. **Tool results are observations, not prose.** Every tool response is
   truncated to a byte budget before it goes back into the history, so a
   runaway `list_installed_apps` cannot eat the context window. This is the
   same problem `context_budget.py` solves for a single HTTP call; here it
   has to hold across N turns.
2. **A hard budget, always.** `max_steps` and `max_seconds` are both
   enforced. An agent that keeps calling tools forever is worse than one
   that stops and admits it did not finish.
3. **Parallel tool calls are executed as issued.** llama3.2 and friends
   happily return two or three `tool_calls` in one turn; running them
   serially wastes wall-clock time for no reason.

The model backend is Ollama's `/api/chat`, already used by `server.py` for
capability detection, so a NothingClaw install adds no new dependency.
"""

import json
import os
import re
import time
import urllib.error
import urllib.request

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

DEFAULT_HOST = os.environ.get("NOTHINGCLAW_OLLAMA", "http://127.0.0.1:11434")
DEFAULT_MODEL = os.environ.get("NOTHINGCLAW_MODEL", "llama3.2:latest")

# Hard ceiling on a single observation handed back to the model. Roughly
# 25k characters ≈ 6k tokens, which leaves room in a 8k window for the
# goal, the transcript summary and the reply.
OBSERVATION_CHAR_BUDGET = 8000

# Refuse to render the full catalogue to a small model - it burns budget
# and small models pick badly from a 30-item menu anyway.
MAX_TOOLS_FOR_AGENT = 24


class AgentError(Exception):
    """Raised for unrecoverable agent failures (no model, no backend)."""


# ---------------------------------------------------------------------------
# Ollama transport
# ---------------------------------------------------------------------------

def _post_json(url, payload, timeout=120):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"},
        method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")[:400]
        raise AgentError("HTTP %s from %s: %s" % (exc.code, url, body))
    except urllib.error.URLError as exc:
        raise AgentError("Cannot reach %s: %s" % (url, exc.reason))


def list_models(host=DEFAULT_HOST):
    """Return the model names available on the Ollama backend."""
    try:
        with urllib.request.urlopen(host.rstrip("/") + "/api/tags",
                                    timeout=10) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except Exception as exc:  # noqa: BLE001 - reported to the caller as text
        return {"error": str(exc), "models": []}
    return {
        "error": None,
        "models": [m.get("name") for m in payload.get("models", [])
                   if m.get("name")],
    }


def _chat(host, model, messages, tools, timeout=120):
    payload = {
        "model": model,
        "messages": messages,
        "stream": False,
        "options": {"temperature": 0.1},
    }
    if tools:
        payload["tools"] = tools
    return _post_json(host.rstrip("/") + "/api/chat", payload, timeout=timeout)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _clip(text, budget=OBSERVATION_CHAR_BUDGET):
    """Clamp an observation, marking the cut so the model knows."""
    if text is None:
        return ""
    text = str(text)
    if len(text) <= budget:
        return text
    kept = text[:budget]
    dropped = len(text) - budget
    return (kept
            + "\n... [truncated %d characters - narrow the query or read the "
              "file in chunks]" % dropped)


def _normalise_arguments(raw):
    """Ollama returns tool arguments as a dict *or* as a JSON string.

    llama3.2 emits a dict, qwen emits a JSON string, and some builds emit
    a string that is not valid JSON at all. Being forgiving here is what
    stops a single malformed call from killing the whole run.
    """
    if raw is None:
        return {}
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, (bytes, bytearray)):
        raw = raw.decode("utf-8", "replace")
    if isinstance(raw, str):
        text = raw.strip()
        if not text:
            return {}
        try:
            parsed = json.loads(text)
        except ValueError:
            return {"_raw": text}
        return parsed if isinstance(parsed, dict) else {"_raw": parsed}
    return {"_raw": raw}


def _tool_schema(tools, allow=None):
    """Convert the bridge's internal tool definitions to the Ollama shape."""
    out = []
    for tool in tools:
        name = tool.get("name")
        if not name or (allow is not None and name not in allow):
            continue
        out.append({
            "type": "function",
            "function": {
                "name": name,
                "description": tool.get("description", ""),
                "parameters": tool.get("inputSchema")
                or tool.get("parameters")
                or {"type": "object", "properties": {}},
            },
        })
    return out


# ---------------------------------------------------------------------------
# Fallback parsing for models that ignore the native `tools` parameter
# ---------------------------------------------------------------------------
#
# Plenty of small local models do not honour the `tools` field at all: they
# emit the call as JSON *text* in `content` instead, e.g.
#
#     {"name": "list_windows", "parameters": {"verbose": true}}
#
# llama3.2 does this often enough that without a fallback the loop treats
# the call as the final answer and stops after one step having done nothing.
# Detecting that shape and promoting it to a real tool call is what makes
# the loop work on the models people actually have installed.

_NAME_KEYS = ("name", "tool", "tool_name", "function")
_ARGS_KEYS = ("parameters", "arguments", "args", "input", "params")


def _coerce_tool_call(name, raw_args):
    """Build a call dict in Ollama's shape from loosely-typed input."""
    if isinstance(raw_args, str):
        raw_args = _normalise_arguments(raw_args)
    if not isinstance(raw_args, dict):
        raw_args = {}
    # OpenAI-style {"function": {...}} wrappers appear too.
    if name is None and isinstance(raw_args.get("function"), dict):
        fn = raw_args["function"]
        name = fn.get("name")
        raw_args = (fn.get("arguments") if fn.get("arguments") is not None
                    else fn.get("parameters")) or {}
    if not name:
        return None
    return {"function": {"name": str(name),
                         "arguments": _normalise_arguments(raw_args)}}


_RE_NAME = re.compile(
    r'"(?:name|tool|tool_name|function)"\s*:\s*"([^"\\]{1,64})"')
_RE_PAIR = re.compile(r'"([A-Za-z_][A-Za-z0-9_]{0,40})"\s*:\s*"(.*?)"\s*(?=[,}])',
                      re.S)


def _lenient_pairs(blob):
    """Salvage `"key": "value"` pairs from malformed JSON.

    Small models routinely emit unescaped quotes inside a string value -
    `{"name": "execute_command", "parameters": {"command": "ls -name "*.md""}}`
    is not valid JSON and `json.loads` rejects it outright. Without a salvage
    path the call is lost and the run ends having done nothing.

    The value regex is lazy up to the *last* quote that is followed by a
    closing brace or comma, which is what recovers the full command string
    instead of stopping at the first inner quote.
    """
    pairs = {}
    for key, value in _RE_PAIR.findall(blob):
        pairs.setdefault(key, value)
    return pairs


def _salvage(text):
    """Last-resort recovery for a text response that looks like a call."""
    names = _RE_NAME.findall(text)
    if not names:
        return None
    name = names[0]
    pairs = _lenient_pairs(text)
    # Drop the envelope keys; whatever is left is the argument object.
    args = {k: v for k, v in pairs.items()
            if k not in ("name", "tool", "tool_name", "function",
                         "parameters", "arguments", "args", "input")}
    return _coerce_tool_call(name, args)


def _extract_tool_calls(text):
    """Pull tool calls out of a text response.

    Handles, in order: a bare JSON object, a JSON object inside a ```json
    fence, and the ```tool_call / <tool_call> fenced blocks that several
    fine-tunes emit. Returns [] when the text is ordinary prose.
    """
    if not text:
        return []

    candidates = []

    def _try(blob):
        blob = (blob or "").strip()
        if not blob or blob[0] not in "{[":
            return
        try:
            parsed = json.loads(blob)
        except ValueError:
            return
        candidates.append(parsed)

    # 1) fenced blocks: ```json {...} ``` or ```tool_call {...} ```
    for fence in re.findall(r"```(?:json|tool_call|tool)?\s*(.+?)```",
                            text, re.S):
        _try(fence)

    # 2) the whole message, if it is already JSON
    stripped = text.strip()
    _try(stripped)

    # 3) the outermost JSON object anywhere in the text
    if not candidates:
        start = stripped.find("{")
        while start != -1:
            depth = 0
            for i in range(start, len(stripped)):
                if stripped[i] == "{":
                    depth += 1
                elif stripped[i] == "}":
                    depth -= 1
                    if depth == 0:
                        _try(stripped[start:i + 1])
                        break
            start = stripped.find("{", start + 1)

    if not candidates:
        salvaged = _salvage(text)
        return [salvaged] if salvaged else []

    calls = []
    for parsed in candidates:
        items = parsed if isinstance(parsed, list) else [parsed]
        # A single message may bundle several calls in a {"tool_calls": []}.
        if isinstance(parsed, dict) and isinstance(parsed.get("tool_calls"), list):
            items = parsed["tool_calls"]
        for item in items:
            if not isinstance(item, dict):
                continue
            # OpenAI/{"function": {...}} wrapper: unwrap before looking for
            # a name, otherwise the wrapper itself has no *_KEYS and the
            # call is silently dropped.
            if isinstance(item.get("function"), dict):
                fn = item["function"]
                item = {"name": fn.get("name"),
                        "arguments": (fn.get("arguments")
                                      if fn.get("arguments") is not None
                                      else fn.get("parameters")) or {}}
            name = None
            for key in _NAME_KEYS:
                if isinstance(item.get(key), str):
                    name = item[key]
                    break
            args = None
            for key in _ARGS_KEYS:
                if key in item:
                    args = item[key]
                    break
            call = _coerce_tool_call(name, args if args is not None else {})
            if call and call["function"]["name"]:
                calls.append(call)

    # Deduplicate: the fence scan and the whole-text scan often yield the
    # same call twice.
    unique, seen = [], set()
    for call in calls:
        key = (call["function"]["name"],
               json.dumps(call["function"]["arguments"], sort_keys=True,
                          default=str))
        if key not in seen:
            seen.add(key)
            unique.append(call)
    if not unique:
        salvaged = _salvage(text)
        if salvaged:
            unique = [salvaged]
    return unique


SYSTEM_PROMPT = """You are NothingClaw, an agent that controls this Linux \
desktop and the machine behind it.

Work in small steps:
- Look before you leap. List windows, workspaces, monitors or a directory \
before you try to act on something you have not seen yet.
- Call tools with concrete values you actually observed, never with guesses \
or placeholder ids.
- When a tool reports an error, read it. Do not retry the same call \
unchanged.
- Stop as soon as the goal is met, and answer in one or two plain sentences \
describing what you did. Do not narrate a plan you are not going to execute.

If the goal cannot be achieved with the tools you have, say so plainly \
instead of inventing a result."""


# ---------------------------------------------------------------------------
# The loop
# ---------------------------------------------------------------------------

def run_agent(goal,
              invoke_tool,
              tools,
              context=None,
              model=DEFAULT_MODEL,
              host=DEFAULT_HOST,
              max_steps=12,
              max_seconds=240,
              allowed_tools=None,
              log=None):
    """Drive `tools` with `invoke_tool` until `goal` is met or budget runs out.

    Parameters
    ----------
    goal : str
        Natural-language objective handed to the model verbatim.
    invoke_tool : callable
        ``invoke_tool(name, arguments, ctx) -> {"content", "error"}``.
        Injected rather than imported so this module stays free of any
        dependency on ``server`` (and therefore free of an import cycle).
    tools : list
        Tool definitions in the bridge's own format.
    context : object, optional
        Forwarded to ``invoke_tool`` untouched (the `_RequestContext` that
        sizes results for small models).
    model : str
        Ollama model name.
    allowed_tools : list, optional
        Restrict the catalogue to these tool names.
    log : callable, optional
        ``log(level, message)`` progress sink.

    Returns a dict with the final ``answer``, the full ``transcript`` and a
    ``stopped_reason`` so the caller can tell "finished" from "gave up".
    """
    if not goal or not str(goal).strip():
        raise AgentError("Empty goal")

    started = time.time()
    transcript = []

    def note(kind, payload):
        entry = dict(payload)
        entry["kind"] = kind
        entry["t"] = round(time.time() - started, 2)
        transcript.append(entry)
        if log:
            log("info", "%s %s" % (kind, json.dumps(payload)[:160]))
        return entry

    catalogue = _tool_schema(tools, allow=allowed_tools)
    if len(catalogue) > MAX_TOOLS_FOR_AGENT:
        catalogue = catalogue[:MAX_TOOLS_FOR_AGENT]
        note("warning", {
            "message": "catalogue trimmed to %d tools" % len(catalogue)})

    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": str(goal)},
    ]

    stopped = "max_steps"
    answer = ""
    steps = 0

    while steps < max_steps:
        if time.time() - started > max_seconds:
            stopped = "timeout"
            break
        steps += 1

        try:
            reply = _chat(host, model, messages, catalogue,
                          timeout=max(30, int(max_seconds)))
        except AgentError as exc:
            note("error", {"message": str(exc)})
            stopped = "model_error"
            answer = "Could not reach the model backend: %s" % exc
            break

        message = (reply or {}).get("message") or {}
        tool_calls = message.get("tool_calls") or []
        text = (message.get("content") or "").strip()

        if not tool_calls and text:
            # Model ignored the native tools field and wrote the call as
            # text instead. Promote it so one step is not wasted.
            recovered = _extract_tool_calls(text)
            if recovered:
                tool_calls = recovered
                note("recovered_call", {
                    "message": "tool call recovered from message text",
                    "tools": [c["function"]["name"] for c in tool_calls]})

        if not tool_calls:
            # No tool calls means the model considers itself done.
            messages.append({"role": "assistant", "content": message.get("content") or ""})
            answer = text or "The agent finished without producing a message."
            stopped = "done"
            note("answer", {"content": answer})
            break

        messages.append({
            "role": "assistant",
            "content": message.get("content") or "",
            "tool_calls": tool_calls,
        })
        note("thought", {"content": text, "tool_calls": len(tool_calls)})

        # Ollama expects one "tool" message per call, in order.
        for call in tool_calls:
            fn = call.get("function") or {}
            name = fn.get("name", "")
            args = _normalise_arguments(fn.get("arguments"))

            try:
                result = invoke_tool(name, args, context)
            except Exception as exc:  # noqa: BLE001 - a bad tool must not kill the run
                result = {"content": "", "error": "%s: %s" % (type(exc).__name__, exc)}

            content = _clip(result.get("content", ""))
            error = result.get("error")
            if error:
                # Errors are observations too - feed them back so the model
                # can adapt instead of retrying blindly.
                content = ("ERROR: %s" % error) + (("\n%s" % content) if content else "")

            note("observation", {
                "tool": name,
                "arguments": args,
                "content": content,
                "error": error,
            })
            messages.append({"role": "tool", "name": name, "content": content})
    else:
        stopped = "max_steps"

    return {
        "goal": goal,
        "answer": answer,
        "steps": steps,
        "stopped_reason": stopped,
        "elapsed": round(time.time() - started, 2),
        "model": model,
        "transcript": transcript,
        "content": answer,
        "error": None if stopped == "done" else "Agent stopped: " + stopped,
    }