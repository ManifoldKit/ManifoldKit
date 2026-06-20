#!/usr/bin/env python3
"""Regenerate the byte-match chat-template goldens (#1938).

Oracle of record: Hugging Face `transformers`' chat-template rendering. We do NOT
download any model — instead we reproduce `transformers`' exact Jinja
environment (`_compile_jinja_template`): an `ImmutableSandboxedEnvironment` with
`trim_blocks=True, lstrip_blocks=True`, the `tojson` filter, and the
`raise_exception` / `strftime_now` globals. The chat template a GGUF carries in
`tokenizer.chat_template` is rendered by transformers through exactly this
environment, so reproducing it gives the byte-for-byte ground truth the model
was trained against, with zero network or torch dependency.

This generator also mirrors `JinjaPromptRenderer`'s context construction
(`jinjaMessage` + `toolsContext` in
Sources/ManifoldInference/Services/JinjaPromptRenderer.swift) so the golden
reflects the *same* context MK feeds swift-jinja. The Swift byte-match test then
asserts swift-jinja produces the identical bytes for that context — i.e. it locks
MK's renderer against the transformers reference and catches future drift.

Run:  uv run --with jinja2 Tests/ManifoldInferenceTests/Fixtures/ChatTemplates/regenerate.py

Each fixture is `<name>.jinja` (the template) + `<name>.context.json` (MK-facing
inputs); output is `<name>.golden.txt`. The `.context.json` MUST mirror the Swift
test's hand-built inputs for that fixture — the byte-match test enforces it (a
drift makes the golden stop matching swift-jinja's output).
"""

from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path

import jinja2
from jinja2.sandbox import ImmutableSandboxedEnvironment

RENDERABLE_ROLES = {"system", "user", "assistant", "tool"}
HERE = Path(__file__).parent


def transformers_env() -> jinja2.Environment:
    """Reproduce transformers `_compile_jinja_template`'s Jinja environment."""

    def raise_exception(message):  # noqa: ANN001
        raise jinja2.exceptions.TemplateError(message)

    def tojson(x, ensure_ascii=False, indent=None, separators=None, sort_keys=False):  # noqa: ANN001
        return json.dumps(
            x, ensure_ascii=ensure_ascii, indent=indent, separators=separators, sort_keys=sort_keys
        )

    def strftime_now(fmt):  # noqa: ANN001
        return datetime.now().strftime(fmt)

    env = ImmutableSandboxedEnvironment(trim_blocks=True, lstrip_blocks=True)
    env.filters["tojson"] = tojson
    env.globals["raise_exception"] = raise_exception
    env.globals["strftime_now"] = strftime_now
    return env


def parse_arguments(raw: str):
    """Mirror `argumentsValue`: parse a JSON-string argument to an object, else
    return the raw string."""
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return raw


def data_uri(image: dict) -> str:
    """Mirror `dataURI(data:mimeType:)`: `data:<mime>;base64,<payload>`.

    The fixture carries the base64 payload directly (`base64` field) so the
    generator needs no image bytes on disk and stays byte-identical to the Swift
    test's hand-built `Data(base64Encoded:)` input.
    """
    return f"data:{image['mimeType']};base64,{image['base64']}"


def image_content_list(text: str, images: list[dict]) -> list[dict]:
    """Mirror `imageContentList(text:images:)` in JinjaPromptRenderer.swift."""
    blocks: list[dict] = []
    if text:
        blocks.append({"type": "text", "text": text})
    for image in images:
        uri = data_uri(image)
        blocks.append({"type": "image", "image_url": {"url": uri}, "image": uri})
    return blocks


def jinja_message(message: dict, thread_images: bool) -> dict:
    """Mirror `jinjaMessage(from:threadImages:)` in JinjaPromptRenderer.swift."""
    out: dict = {"role": message["role"], "content": message.get("text", "")}

    images = message.get("images", []) or []
    if thread_images and images:
        out["content"] = image_content_list(message.get("text", ""), images)

    tool_calls = []
    for call in message.get("toolCalls", []) or []:
        args = parse_arguments(call["arguments"])
        tool_calls.append(
            {
                "id": call["id"],
                "type": "function",
                "function": {"name": call["name"], "arguments": args},
                # Flat aliases for templates that read tool_call.name / .arguments.
                "name": call["name"],
                "arguments": args,
            }
        )
    if tool_calls:
        out["tool_calls"] = tool_calls

    result = message.get("toolResult")
    if result is not None:
        out["tool_call_id"] = result["callId"]
        if not out["content"]:
            out["content"] = result["content"]

    return out


def tools_context(tools: list[dict]) -> list[dict]:
    """Mirror `toolsContext(_:)` in JinjaPromptRenderer.swift."""
    ctx = []
    for tool in tools:
        parameters = tool.get("parameters") or {"type": "object", "properties": {}}
        ctx.append(
            {
                "type": "function",
                "function": {
                    "name": tool["name"],
                    "description": tool["description"],
                    "parameters": parameters,
                },
                # Flat aliases for gemma-style templates that read tool.name.
                "name": tool["name"],
                "description": tool["description"],
                "parameters": parameters,
            }
        )
    return ctx


def documents_context(documents: list[dict]) -> list[dict]:
    """Mirror `documentsContext(_:)` in JinjaPromptRenderer.swift."""
    return [
        {
            "doc_id": doc.get("docID") or str(index),
            "title": doc["title"],
            "text": doc["text"],
        }
        for index, doc in enumerate(documents)
    ]


def template_references_word(template: str, word: str) -> bool:
    """Mirror `templateReferencesImages` / `templateReferencesToolsVariable`:
    the bare identifier appears inside a `{% %}` / `{{ }}` block on identifier
    boundaries. A coarse-but-faithful port — scans delimited regions only."""
    import re

    for match in re.finditer(r"\{[%{](.*?)[%}]\}", template, re.DOTALL):
        region = match.group(1)
        if re.search(rf"(?<![A-Za-z0-9_]){re.escape(word)}(?![A-Za-z0-9_])", region):
            return True
    return False


def build_context(ctx: dict) -> dict:
    """Mirror JinjaPromptRenderer.render's context assembly."""
    system_prompt = ctx.get("systemPrompt")
    messages = ctx.get("messages", [])
    template_path = HERE / ctx.get("template", "")
    template_src = template_path.read_text() if template_path.is_file() else ""
    thread_images = template_references_word(template_src, "image")

    jinja_messages: list[dict] = []
    history_has_leading_system = bool(messages) and messages[0].get("role") == "system"
    if system_prompt and not history_has_leading_system:
        jinja_messages.append({"role": "system", "content": system_prompt})
    for message in messages:
        if message.get("role") in RENDERABLE_ROLES:
            jinja_messages.append(jinja_message(message, thread_images))

    return {
        "messages": jinja_messages,
        "add_generation_prompt": True,
        "tools": tools_context(ctx.get("tools", [])),
        "documents": documents_context(ctx.get("documents", [])),
    }


def main() -> None:
    env = transformers_env()
    for context_path in sorted(HERE.glob("*.context.json")):
        name = context_path.name[: -len(".context.json")]
        golden_path = HERE / f"{name}.golden.txt"
        ctx = json.loads(context_path.read_text())
        # A fixture may reuse another fixture's template (e.g. the default-system
        # variant shares qwen25.jinja) via an optional "template" field. Resolve
        # it once and pin it back into ctx so build_context can probe the template
        # (e.g. for the image-threading gate) using the same path.
        ctx["template"] = ctx.get("template", f"{name}.jinja")
        template_path = HERE / ctx["template"]
        template = env.from_string(template_path.read_text())
        rendered = template.render(**build_context(ctx))
        golden_path.write_text(rendered)
        print(f"wrote {golden_path.name} ({len(rendered)} bytes)")


if __name__ == "__main__":
    main()
