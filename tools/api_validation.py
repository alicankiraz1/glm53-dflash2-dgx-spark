#!/usr/bin/env python3

"""Read-only API, correctness, and long-context validation for one recorded run.

The module never mutates a cluster. It issues bounded HTTP requests against the
endpoint of an already-active run, evaluates fixed expectations, and emits a
sanitized, machine-readable summary.

Two distinctions drive every outcome in this module:

* Infrastructure failures mean the deployment could not be asked the question:
  transport faults, HTTP status faults, timeouts, malformed payloads, or an
  endpoint that cannot be proven to serve the recorded run.
* Correctness failures mean the deployment answered and the answer was wrong.

Conflating them turns a broken tunnel into a model regression, so the taxonomy
is closed, disjoint, and reported explicitly.

Nothing derived from a prompt, a reply, a reasoning trace, an endpoint address,
a filesystem path, or a server error body reaches persisted output. Only counts,
fixed vocabulary, and declared request configuration survive.
"""

from __future__ import annotations

import argparse
import base64
import dataclasses
import datetime
import json
import os
import pathlib
import re
import secrets
import shlex
import socket
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable, Mapping, Sequence
from typing import Any


SCHEMA_VERSION = 1
REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parents[1]

CHAT_PATH = "v1/chat/completions"
MODEL_INFO_PATH = "get_model_info"
SERVED_MODELS_PATH = "v1/models"
METRICS_PATH = "metrics"

MAX_RESPONSE_BYTES = 8 * 1024 * 1024
MAX_STREAM_LINES = 2_000_000
DEFAULT_MAX_TOKENS = 4096

VALIDATION_ID_PATTERN = re.compile(r"\A[0-9]{8}T[0-9]{6}\.[0-9]{6}Z-[0-9a-f]{32}\Z")
RESOURCE_PATH_PATTERN = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._/-]*\Z")
ARTIFACT_NAME_PATTERN = re.compile(r"\A[a-z][a-z0-9-]{0,31}\.json\Z")
CONFIGURATION_KEY_PATTERN = re.compile(r"\A[a-z][a-z0-9_]{0,47}\Z")
DIGEST_PATTERN = re.compile(r"\A[0-9a-f]{64}\Z")
IDENTIFIER_PATTERN = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")
DETAIL_PATTERN = re.compile(r"\A[A-Za-z0-9 ,.'-]{1,160}\Z")

# Any published string that matches this pattern would carry inventory,
# filesystem layout, or credential material out of the controller.
UNSAFE_VALUE_PATTERN = re.compile(
    r"://"
    r"|\b[0-9]{1,3}(?:\.[0-9]{1,3}){3}\b"
    r"|\A/"
    r"|authoriz|bearer|passphrase|password|credential|secret"
    r"|api[_-]?key|access[_-]?token|known_hosts|private[_-]?key",
    re.IGNORECASE,
)

SUITE_NAMES = ("smoke", "correctness", "needle", "benchmark")
API_SUITE_NAMES = ("smoke", "correctness", "needle")
OUTCOMES = ("passed", "failed-correctness", "failed-infrastructure")
MANIFEST_STATUSES = ("started", *OUTCOMES)

INFRASTRUCTURE_FAILURE_CLASSES = frozenset(
    {
        "transport",
        "http-status",
        "timeout",
        "malformed-response",
        "identity-mismatch",
    }
)
CORRECTNESS_FAILURE_CLASSES = frozenset(
    {
        "wrong-answer",
        "empty-content",
        "missing-tool-call",
        "tool-schema-mismatch",
        "needle-mismatch",
        "prompt-size-mismatch",
    }
)

# Fixed, reviewable phrasing. A failure detail is never derived from a served
# response, so no reply text can escape through it.
FAILURE_DETAILS = {
    None: "the case matched its expectation",
    "transport": "the endpoint could not be reached",
    "http-status": "the endpoint answered with a failing HTTP status",
    "timeout": "the request exceeded its bounded timeout",
    "malformed-response": "the response did not follow the chat completion schema",
    "identity-mismatch": "the endpoint does not serve the recorded run",
    "wrong-answer": "the final answer did not match the expected value",
    "empty-content": "the reply carried no final answer",
    "missing-tool-call": "the reply carried no structured tool call",
    "tool-schema-mismatch": "the tool call did not match the expected function schema",
    "needle-mismatch": "the inserted catalog label was not retrieved",
    "prompt-size-mismatch": "the measured prompt size missed the requested budget",
}

PLACEHOLDER_MODEL_NAME = "recorded-served-model"

# ---------------------------------------------------------------------------
# Deterministic long-context probe parameters
# ---------------------------------------------------------------------------

NEEDLE_TARGET_TOKENS = 120000
NEEDLE_DEPTHS = (10, 50, 90)
NEEDLE_SEED = 20260828
NEEDLE_MAX_TOKENS = 8000
NEEDLE_TOLERANCE_FRACTION = 0.02
NEEDLE_MINIMUM_LINES = 8
NEEDLE_LABEL_PATTERN = r"\ACOPPER-IBIS-[0-9]{4}-ZX\Z"

CALIBRATION_LINES = 2000
# The proven root cause of the earlier long-context ceiling was a needle-free
# calibration prompt that became a prefix of the real probe, letting cached
# state answer for text the model never attended to. Calibration therefore
# numbers its lines from a disjoint range that no probe can ever reuse.
CALIBRATION_LINE_OFFSET = 5_000_000
CALIBRATION_SEED = 0
MINIMUM_TOKENS_PER_LINE = 8.0
MAXIMUM_TOKENS_PER_LINE = 512.0
DEFAULT_TOKENS_PER_LINE = 44.0

NEEDLE_STATEMENT = (
    "The catalog label assigned to the regional herbarium specimen is {label}. "
    "Remember this exact catalog label."
)
NEEDLE_QUESTION = (
    "\n\nWhat is the catalog label assigned to the regional herbarium "
    "specimen? Reply with the catalog label only."
)

# A haystack of near-identical lines is a weak probe: a model can summarise it
# without attending to any single line, so a miss would describe the filler
# rather than the deployment. These sentences vary in subject, structure, and
# figures while staying uniform in length.
FILLER_SENTENCES = (
    "Line {index:07d}: The {region} depot logged {count} outbound pallets on "
    "{weekday}, and the duty officer recorded a {minutes}-minute delay at the "
    "loading bay before the convoy departed for {destination}.",
    "Line {index:07d}: Maintenance crew {count} replaced the hydraulic seals "
    "on lift {minutes} at the {region} facility, returning it to service on "
    "{weekday} ahead of the shipment bound for {destination}.",
    "Line {index:07d}: Inventory reconciliation for the {region} warehouse "
    "showed a variance of {count} units against the manifest, which the "
    "{weekday} audit attributed to mislabelled crates from {destination}.",
    "Line {index:07d}: The night shift at {destination} reported {count} "
    "temperature excursions in cold storage bay {minutes}, all resolved before "
    "the {weekday} handover to the {region} coordination desk.",
    "Line {index:07d}: Fuel consumption on the {region} to {destination} route "
    "rose by {count} litres this period, and dispatch has scheduled a "
    "{minutes}-hour review for the following {weekday}.",
)
FILLER_REGIONS = (
    "northern",
    "southern",
    "eastern",
    "western",
    "coastal",
    "inland",
)
FILLER_DESTINATIONS = (
    "Northgate",
    "Riverbend",
    "Stonemarket",
    "Fairhaven",
    "Westmill",
    "Ashford",
    "Brightwater",
)
FILLER_WEEKDAYS = (
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
)

TOOL_FUNCTION_NAME = "get_shipment_status"
TOOL_SHIPMENT_ID = "ZX-4471"


# ---------------------------------------------------------------------------
# Error taxonomy
# ---------------------------------------------------------------------------


class ValidationError(Exception):
    """Base class for every validation failure this module reports."""


class InfrastructureError(ValidationError):
    """The deployment could not be asked the question at all."""

    failure_class = "transport"


class TransportFailure(InfrastructureError):
    failure_class = "transport"


class TimeoutFailure(InfrastructureError):
    failure_class = "timeout"


class MalformedResponse(InfrastructureError):
    failure_class = "malformed-response"


class IdentityMismatch(InfrastructureError):
    failure_class = "identity-mismatch"


class HTTPFailure(InfrastructureError):
    failure_class = "http-status"

    def __init__(self, message: str, status_code: int) -> None:
        super().__init__(message)
        self.status_code = int(status_code)


class EvidenceError(ValueError):
    """Raised when validation evidence is unsafe, malformed, or unpersistable."""


def failure_kind(failure_class: str) -> str:
    """Map a failure class onto the only two kinds a caller may act on."""
    if failure_class in INFRASTRUCTURE_FAILURE_CLASSES:
        return "infrastructure"
    if failure_class in CORRECTNESS_FAILURE_CLASSES:
        return "correctness"
    raise ValueError(f"unknown failure class: {failure_class}")


# ---------------------------------------------------------------------------
# Bounded HTTP client
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class StreamedChat:
    """One streamed completion measured against a monotonic clock."""

    started_seconds: float
    first_token_seconds: float | None
    completed_seconds: float
    prompt_tokens: int
    completion_tokens: int
    content_characters: int
    reasoning_characters: int
    finish_reason: str | None
    chunk_count: int

    @property
    def end_to_end_seconds(self) -> float:
        return self.completed_seconds - self.started_seconds

    @property
    def ttft_seconds(self) -> float | None:
        if self.first_token_seconds is None:
            return None
        return self.first_token_seconds - self.started_seconds

    @property
    def decode_seconds(self) -> float | None:
        if self.first_token_seconds is None:
            return None
        return self.completed_seconds - self.first_token_seconds


Opener = Callable[..., Any]
Clock = Callable[[], float]


class OpenAIClient:
    """Minimal OpenAI-compatible client with explicit bounds on every read."""

    def __init__(
        self,
        base_url: str,
        timeout_seconds: float,
        opener: Opener = urllib.request.urlopen,
        max_response_bytes: int = MAX_RESPONSE_BYTES,
        clock: Clock = time.monotonic,
    ) -> None:
        self.base_url = _validate_base_url(base_url)
        if not isinstance(timeout_seconds, (int, float)) or timeout_seconds <= 0:
            raise ValueError("the HTTP timeout must be a positive number of seconds")
        if not isinstance(max_response_bytes, int) or max_response_bytes <= 0:
            raise ValueError("the bounded response size must be a positive integer")
        self.timeout_seconds = float(timeout_seconds)
        self.opener = opener
        self.max_response_bytes = max_response_bytes
        self.clock = clock

    def _url(self, path: str) -> str:
        if not isinstance(path, str) or not RESOURCE_PATH_PATTERN.fullmatch(path):
            raise ValueError(f"unsafe endpoint path: {path!r}")
        return f"{self.base_url}/{path}"

    @staticmethod
    def _request(url: str, body: bytes | None) -> urllib.request.Request:
        headers = {"Accept": "application/json"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        return urllib.request.Request(
            url,
            data=body,
            headers=headers,
            method="POST" if body is not None else "GET",
        )

    def _read_bounded(self, response: Any) -> bytes:
        body = response.read(self.max_response_bytes + 1)
        if not isinstance(body, bytes):
            raise MalformedResponse("the response body was not raw bytes")
        if len(body) > self.max_response_bytes:
            raise MalformedResponse("the response body exceeded the bounded read")
        return body

    def _fetch(self, path: str, body: bytes | None) -> bytes:
        request = self._request(self._url(path), body)
        try:
            with self.opener(request, timeout=self.timeout_seconds) as response:
                status = int(getattr(response, "status", 200) or 200)
                if status < 200 or status >= 300:
                    raise HTTPFailure(
                        "the endpoint answered with a failing status",
                        status_code=status,
                    )
                return self._read_bounded(response)
        except urllib.error.HTTPError as exc:
            # The served body is deliberately discarded: an upstream error page
            # can carry arbitrary text that must never reach evidence.
            raise HTTPFailure(
                "the endpoint answered with a failing status",
                status_code=int(exc.code),
            ) from None
        except (socket.timeout, TimeoutError) as exc:
            raise TimeoutFailure("the request exceeded its bounded timeout") from exc
        except urllib.error.URLError:
            raise TransportFailure("the endpoint could not be reached") from None
        except OSError:
            raise TransportFailure("the endpoint could not be reached") from None

    @staticmethod
    def _decode_json(body: bytes) -> Mapping[str, Any]:
        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as exc:
            raise MalformedResponse("the response body was not valid JSON") from exc
        if not isinstance(payload, Mapping):
            raise MalformedResponse("the response body was not a JSON object")
        return payload

    def get_json(self, path: str) -> Mapping[str, Any]:
        return self._decode_json(self._fetch(path, None))

    def get_text(self, path: str) -> str:
        body = self._fetch(path, None)
        try:
            return body.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise MalformedResponse("the response body was not valid UTF-8") from exc

    def chat(self, request: Mapping[str, Any]) -> Mapping[str, Any]:
        payload = _validate_chat_request(request, streaming=False)
        return self._decode_json(self._fetch(CHAT_PATH, payload))

    def stream_chat(self, request: Mapping[str, Any]) -> StreamedChat:
        payload = _validate_chat_request(request, streaming=True)
        http_request = self._request(self._url(CHAT_PATH), payload)
        started = float(self.clock())
        try:
            with self.opener(http_request, timeout=self.timeout_seconds) as response:
                status = int(getattr(response, "status", 200) or 200)
                if status < 200 or status >= 300:
                    raise HTTPFailure(
                        "the endpoint answered with a failing status",
                        status_code=status,
                    )
                return self._consume_stream(response, started)
        except urllib.error.HTTPError as exc:
            raise HTTPFailure(
                "the endpoint answered with a failing status",
                status_code=int(exc.code),
            ) from None
        except (socket.timeout, TimeoutError) as exc:
            raise TimeoutFailure("the request exceeded its bounded timeout") from exc
        except urllib.error.URLError:
            raise TransportFailure("the endpoint could not be reached") from None
        except OSError:
            raise TransportFailure("the endpoint could not be reached") from None

    def _consume_stream(self, response: Any, started: float) -> StreamedChat:
        first_token: float | None = None
        content_characters = 0
        reasoning_characters = 0
        finish_reason: str | None = None
        usage: Mapping[str, Any] | None = None
        chunk_count = 0
        consumed = 0
        lines = 0

        while True:
            raw = response.readline(self.max_response_bytes + 1)
            if not raw:
                break
            lines += 1
            consumed += len(raw)
            if consumed > self.max_response_bytes or lines > MAX_STREAM_LINES:
                raise MalformedResponse("the streamed body exceeded the bounded read")
            line = raw.decode("utf-8", errors="replace").strip()
            if not line or not line.startswith("data:"):
                continue
            data = line[len("data:") :].strip()
            if data == "[DONE]":
                break
            try:
                chunk = json.loads(data)
            except ValueError as exc:
                raise MalformedResponse("a streamed chunk was not valid JSON") from exc
            if not isinstance(chunk, Mapping):
                raise MalformedResponse("a streamed chunk was not a JSON object")
            chunk_usage = chunk.get("usage")
            if isinstance(chunk_usage, Mapping):
                usage = chunk_usage
            choices = chunk.get("choices")
            if not isinstance(choices, list) or not choices:
                continue
            choice = choices[0]
            if not isinstance(choice, Mapping):
                raise MalformedResponse("a streamed choice was not a JSON object")
            if isinstance(choice.get("finish_reason"), str):
                finish_reason = choice["finish_reason"]
            delta = choice.get("delta")
            if not isinstance(delta, Mapping):
                continue
            content = delta.get("content")
            reasoning = delta.get("reasoning_content")
            emitted = 0
            if isinstance(content, str):
                content_characters += len(content)
                emitted += len(content)
            if isinstance(reasoning, str):
                reasoning_characters += len(reasoning)
                emitted += len(reasoning)
            if emitted == 0:
                continue
            chunk_count += 1
            # Time to first token measures prefill, so the first streamed token
            # counts whether the deployment emits reasoning or content first.
            if first_token is None:
                first_token = float(self.clock())

        completed = float(self.clock())
        if usage is None:
            raise MalformedResponse("the stream reported no usage totals")
        prompt_tokens = _require_token_count(usage.get("prompt_tokens"))
        completion_tokens = _require_token_count(usage.get("completion_tokens"))
        if completed < started or (first_token is not None and first_token < started):
            raise MalformedResponse("the streamed timings were not monotonic")
        return StreamedChat(
            started_seconds=started,
            first_token_seconds=first_token,
            completed_seconds=completed,
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            content_characters=content_characters,
            reasoning_characters=reasoning_characters,
            finish_reason=finish_reason,
            chunk_count=chunk_count,
        )


def _validate_base_url(base_url: str) -> str:
    if not isinstance(base_url, str) or not base_url:
        raise ValueError("the base URL is required")
    parsed = urllib.parse.urlsplit(base_url)
    if parsed.scheme != "http":
        raise ValueError("the base URL must use plain HTTP on the private fabric")
    if not parsed.hostname:
        raise ValueError("the base URL must carry a host")
    if parsed.username or parsed.password:
        raise ValueError("the base URL must not embed credentials")
    if parsed.query or parsed.fragment:
        raise ValueError("the base URL must not carry a query or fragment")
    if parsed.path not in ("", "/"):
        raise ValueError("the base URL must not carry a path")
    port = f":{parsed.port}" if parsed.port else ""
    return f"http://{parsed.hostname}{port}"


def _validate_chat_request(request: Mapping[str, Any], streaming: bool) -> bytes:
    if not isinstance(request, Mapping):
        raise ValueError("a chat request must be a mapping")
    model = request.get("model")
    if not isinstance(model, str) or not model:
        raise ValueError("a chat request must name a model")
    messages = request.get("messages")
    if not isinstance(messages, list):
        raise ValueError("a chat request must carry a message list")
    if streaming:
        if request.get("stream") is not True:
            raise ValueError("a streamed chat request must set stream to true")
        options = request.get("stream_options")
        if not isinstance(options, Mapping) or options.get("include_usage") is not True:
            raise ValueError("a streamed chat request must request usage totals")
    elif request.get("stream"):
        raise ValueError("chat() cannot serve a streamed request")
    try:
        return json.dumps(dict(request), ensure_ascii=False, allow_nan=False).encode(
            "utf-8"
        )
    except (TypeError, ValueError) as exc:
        raise ValueError("the chat request could not be encoded as JSON") from exc


def _require_token_count(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise MalformedResponse("a reported token count was missing or invalid")
    return value


# ---------------------------------------------------------------------------
# Recorded serving identity
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class IdentityReport:
    model_path: str
    served_model_name: str
    is_generation: bool


def verify_identity(
    client: OpenAIClient,
    expected_model_path: str,
    expected_served_name: str,
) -> IdentityReport:
    """Prove the endpoint serves this run's pinned snapshot and served name.

    Liveness is not identity: an unrelated listener on the recorded address, or
    the right server holding a different model, must both fail here.
    """
    if not expected_model_path or not expected_served_name:
        raise ValueError("identity verification requires the recorded run identity")
    info = client.get_json(MODEL_INFO_PATH)
    if info.get("model_path") != expected_model_path:
        raise IdentityMismatch("the served model path does not match the recorded run")
    if info.get("is_generation") is not True:
        raise IdentityMismatch("the endpoint is not serving a generation model")
    listing = client.get_json(SERVED_MODELS_PATH)
    entries = listing.get("data")
    if not isinstance(entries, list) or not entries:
        raise MalformedResponse("the served model listing was empty or malformed")
    observed = []
    for entry in entries:
        if not isinstance(entry, Mapping):
            raise MalformedResponse("the served model listing had a malformed entry")
        observed.append(entry.get("id"))
    if observed != [expected_served_name]:
        raise IdentityMismatch("the served model name does not match the recorded run")
    return IdentityReport(
        model_path=expected_model_path,
        served_model_name=expected_served_name,
        is_generation=True,
    )


# ---------------------------------------------------------------------------
# Fixed validation cases
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class ToolExpectation:
    name: str
    required_arguments: tuple[tuple[str, str], ...]

    def __post_init__(self) -> None:
        if not isinstance(self.name, str) or not self.name:
            raise ValueError("a tool expectation must name a function")
        if not self.required_arguments:
            raise ValueError("a tool expectation must require at least one argument")


@dataclasses.dataclass(frozen=True)
class ValidationCase:
    name: str
    suite: str
    request: Mapping[str, Any]
    expected_equals: str | None = None
    expected_contains: tuple[str, ...] = ()
    expected_tool: ToolExpectation | None = None
    mismatch_class: str = "wrong-answer"

    def __post_init__(self) -> None:
        if not IDENTIFIER_PATTERN.fullmatch(self.name):
            raise ValueError(f"unsafe case name: {self.name!r}")
        if self.suite not in API_SUITE_NAMES:
            raise ValueError(f"unknown case suite: {self.suite!r}")
        if not isinstance(self.request, Mapping) or not self.request.get("model"):
            raise ValueError("a case request must name a model")
        if (
            self.expected_equals is None
            and not self.expected_contains
            and self.expected_tool is None
        ):
            raise ValueError("a case must declare at least one expectation")
        if self.mismatch_class not in CORRECTNESS_FAILURE_CLASSES:
            raise ValueError(f"unknown mismatch class: {self.mismatch_class!r}")


@dataclasses.dataclass(frozen=True)
class CaseResult:
    name: str
    suite: str
    passed: bool
    failure_class: str | None
    detail: str
    prompt_tokens: int | None
    completion_tokens: int | None
    finish_reason: str | None
    content_characters: int
    reasoning_characters: int


def _chat_request(
    model: str,
    prompt: str,
    max_tokens: int,
    tools: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    request: dict[str, Any] = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0.0,
    }
    if tools is not None:
        request["tools"] = tools
        request["tool_choice"] = "auto"
    return request


def build_smoke_cases(
    model: str,
    max_tokens: int = DEFAULT_MAX_TOKENS,
) -> list[ValidationCase]:
    """One minimal end-to-end request that proves the API answers at all."""
    _require_case_budget(max_tokens)
    return [
        ValidationCase(
            name="smoke",
            suite="smoke",
            request=_chat_request(
                model,
                "Reply with the single word READY and nothing else.",
                max_tokens,
            ),
            expected_equals="READY",
        )
    ]


def build_correctness_cases(
    model: str,
    max_tokens: int = DEFAULT_MAX_TOKENS,
) -> list[ValidationCase]:
    """Arithmetic, code, Turkish, and structured tool calling."""
    _require_case_budget(max_tokens)
    return [
        ValidationCase(
            name="arithmetic",
            suite="correctness",
            request=_chat_request(
                model,
                "Compute 2841 * 37. Reply with the integer only.",
                max_tokens,
            ),
            expected_equals="105117",
        ),
        ValidationCase(
            name="code",
            suite="correctness",
            request=_chat_request(
                model,
                (
                    "Write a Python function named parity_label that returns "
                    "'even' for an even integer and 'odd' otherwise. Reply with "
                    "code only."
                ),
                max_tokens,
            ),
            expected_contains=("def parity_label", "return"),
        ),
        ValidationCase(
            name="turkish",
            suite="correctness",
            request=_chat_request(
                model,
                "3 sayısını Türkçe kelimeyle yaz. Yalnızca kelimeyi yaz.",
                max_tokens,
            ),
            expected_equals="üç",
        ),
        ValidationCase(
            name="tool_call",
            suite="correctness",
            request=_chat_request(
                model,
                (
                    f"Look up the delivery status of shipment {TOOL_SHIPMENT_ID} "
                    "using the available tool."
                ),
                max_tokens,
                tools=[
                    {
                        "type": "function",
                        "function": {
                            "name": TOOL_FUNCTION_NAME,
                            "description": "Look up the status of one shipment.",
                            "parameters": {
                                "type": "object",
                                "properties": {
                                    "shipment_id": {
                                        "type": "string",
                                        "description": "The shipment identifier.",
                                    }
                                },
                                "required": ["shipment_id"],
                            },
                        },
                    }
                ],
            ),
            expected_tool=ToolExpectation(
                name=TOOL_FUNCTION_NAME,
                required_arguments=(("shipment_id", TOOL_SHIPMENT_ID),),
            ),
        ),
    ]


def _require_case_budget(max_tokens: int) -> None:
    # The deployment is thinking-always: a budget sized for the answer alone is
    # spent on reasoning and returns empty content, which looks like a wrong
    # answer but is a starved request.
    if not isinstance(max_tokens, int) or max_tokens < 2048:
        raise ValueError("a validation case needs at least 2048 completion tokens")


def _normalize_answer(text: str) -> str:
    return text.strip().rstrip(".").strip()


def _extract_message(
    response: Mapping[str, Any],
) -> tuple[Mapping[str, Any], str | None]:
    if not isinstance(response, Mapping):
        raise MalformedResponse("the chat response was not a JSON object")
    choices = response.get("choices")
    if not isinstance(choices, list) or not choices:
        raise MalformedResponse("the chat response carried no choices")
    choice = choices[0]
    if not isinstance(choice, Mapping):
        raise MalformedResponse("the first choice was not a JSON object")
    message = choice.get("message")
    if not isinstance(message, Mapping):
        raise MalformedResponse("the first choice carried no message object")
    finish_reason = choice.get("finish_reason")
    if finish_reason is not None and not isinstance(finish_reason, str):
        raise MalformedResponse("the reported finish reason was not a string")
    return message, finish_reason


def _extract_usage(response: Mapping[str, Any]) -> tuple[int | None, int | None]:
    usage = response.get("usage")
    if not isinstance(usage, Mapping):
        return None, None

    def read(key: str) -> int | None:
        value = usage.get(key)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            return None
        return value

    return read("prompt_tokens"), read("completion_tokens")


def _evaluate_tool_call(
    message: Mapping[str, Any],
    expectation: ToolExpectation,
) -> str | None:
    calls = message.get("tool_calls")
    if not isinstance(calls, list) or not calls:
        return "missing-tool-call"
    first = calls[0]
    if not isinstance(first, Mapping):
        return "tool-schema-mismatch"
    function = first.get("function")
    if not isinstance(function, Mapping):
        return "tool-schema-mismatch"
    if function.get("name") != expectation.name:
        return "tool-schema-mismatch"
    raw_arguments = function.get("arguments")
    if not isinstance(raw_arguments, str):
        return "tool-schema-mismatch"
    try:
        arguments = json.loads(raw_arguments)
    except ValueError:
        return "tool-schema-mismatch"
    if not isinstance(arguments, Mapping):
        return "tool-schema-mismatch"
    for key, expected in expectation.required_arguments:
        if str(arguments.get(key)) != expected:
            return "tool-schema-mismatch"
    return None


def evaluate_case(
    case: ValidationCase,
    response: Mapping[str, Any],
) -> CaseResult:
    """Judge one served response against one fixed expectation.

    A response that does not follow the chat schema is an infrastructure
    failure, not a wrong answer: the deployment never answered the question.
    """
    try:
        message, finish_reason = _extract_message(response)
    except MalformedResponse:
        return _case_result(case, "malformed-response", None, None, None, 0, 0)

    content = message.get("content")
    reasoning = message.get("reasoning_content")
    if content is not None and not isinstance(content, str):
        return _case_result(case, "malformed-response", None, None, None, 0, 0)
    if reasoning is not None and not isinstance(reasoning, str):
        return _case_result(case, "malformed-response", None, None, None, 0, 0)
    content_text = content or ""
    reasoning_text = reasoning or ""
    prompt_tokens, completion_tokens = _extract_usage(response)

    def result(failure_class: str | None) -> CaseResult:
        return _case_result(
            case,
            failure_class,
            prompt_tokens,
            completion_tokens,
            finish_reason,
            len(content_text),
            len(reasoning_text),
        )

    if case.expected_tool is not None:
        return result(_evaluate_tool_call(message, case.expected_tool))

    normalized = _normalize_answer(content_text)
    if not normalized:
        return result("empty-content")
    if case.expected_equals is not None and normalized != case.expected_equals:
        return result(case.mismatch_class)
    for fragment in case.expected_contains:
        if fragment not in content_text:
            return result(case.mismatch_class)
    return result(None)


def _case_result(
    case: ValidationCase,
    failure_class: str | None,
    prompt_tokens: int | None,
    completion_tokens: int | None,
    finish_reason: str | None,
    content_characters: int,
    reasoning_characters: int,
) -> CaseResult:
    return CaseResult(
        name=case.name,
        suite=case.suite,
        passed=failure_class is None,
        failure_class=failure_class,
        detail=FAILURE_DETAILS[failure_class],
        prompt_tokens=prompt_tokens,
        completion_tokens=completion_tokens,
        finish_reason=finish_reason,
        content_characters=content_characters,
        reasoning_characters=reasoning_characters,
    )


def run_cases(
    client: OpenAIClient,
    cases: Sequence[ValidationCase],
) -> list[CaseResult]:
    """Issue each case once, converting infrastructure faults into results."""
    results: list[CaseResult] = []
    for case in cases:
        try:
            response = client.chat(dict(case.request))
        except InfrastructureError as exc:
            results.append(
                _case_result(case, exc.failure_class, None, None, None, 0, 0)
            )
            continue
        results.append(evaluate_case(case, response))
    return results


# ---------------------------------------------------------------------------
# Deterministic 120K needle suite
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class NeedleCase:
    case: ValidationCase
    label: str
    depth_percent: int
    target_tokens: int
    line_count: int
    needle_line_index: int
    tokens_per_line: float
    seed: int

    @property
    def prompt(self) -> str:
        return str(self.case.request["messages"][0]["content"])


def _mix(seed: int, index: int) -> int:
    return (index * 2654435761 + seed * 40503 + 0x9E3779B9) & 0xFFFFFFFF


def _filler_line(seed: int, index: int) -> str:
    variant = _mix(seed, index)
    template = FILLER_SENTENCES[variant % len(FILLER_SENTENCES)]
    return template.format(
        index=index,
        region=FILLER_REGIONS[(variant >> 3) % len(FILLER_REGIONS)],
        destination=FILLER_DESTINATIONS[(variant >> 7) % len(FILLER_DESTINATIONS)],
        weekday=FILLER_WEEKDAYS[(variant >> 11) % len(FILLER_WEEKDAYS)],
        count=(variant >> 5) % 900 + 12,
        minutes=(variant >> 9) % 90 + 3,
    )


def _filler_block(seed: int, start: int, count: int) -> str:
    return "\n".join(_filler_line(seed, start + offset) for offset in range(count))


def calibration_prompt() -> str:
    """A needle-free filler block that no probe can ever reuse as a prefix."""
    return _filler_block(CALIBRATION_SEED, CALIBRATION_LINE_OFFSET, CALIBRATION_LINES)


def needle_label(depth_percent: int, seed: int) -> str:
    return "COPPER-IBIS-{number}-ZX".format(
        number=7000 + ((seed * 131 + depth_percent * 137) % 1000)
    )


def build_needle_case(
    total_tokens: int,
    depth_percent: int,
    seed: int,
    *,
    tokens_per_line: float = DEFAULT_TOKENS_PER_LINE,
    model: str = PLACEHOLDER_MODEL_NAME,
    max_tokens: int = NEEDLE_MAX_TOKENS,
) -> NeedleCase:
    """Build one deterministic haystack with a single label at a fixed depth."""
    if not isinstance(total_tokens, int) or total_tokens <= 0:
        raise ValueError("the needle token budget must be a positive integer")
    if not isinstance(depth_percent, int) or not 0 <= depth_percent <= 100:
        raise ValueError("the needle depth must be a percentage between 0 and 100")
    if not isinstance(seed, int):
        raise ValueError("the needle seed must be an integer")
    if (
        not isinstance(tokens_per_line, (int, float))
        or not MINIMUM_TOKENS_PER_LINE <= float(tokens_per_line) <= MAXIMUM_TOKENS_PER_LINE
    ):
        raise ValueError("the calibrated tokens per line is outside the plausible range")
    _require_case_budget(max_tokens)

    line_count = int(total_tokens / float(tokens_per_line))
    if line_count < NEEDLE_MINIMUM_LINES:
        raise ValueError("the needle token budget is too small to build a haystack")
    needle_line_index = int(line_count * depth_percent / 100)
    label = needle_label(depth_percent, seed)
    segments = []
    if needle_line_index:
        segments.append(_filler_block(seed, 0, needle_line_index))
    segments.append(NEEDLE_STATEMENT.format(label=label))
    if line_count - needle_line_index:
        segments.append(
            _filler_block(seed, needle_line_index, line_count - needle_line_index)
        )
    prompt = "\n".join(segments) + NEEDLE_QUESTION
    return NeedleCase(
        case=ValidationCase(
            name=f"needle_depth_{depth_percent}",
            suite="needle",
            request=_chat_request(model, prompt, max_tokens),
            expected_contains=(label,),
            mismatch_class="needle-mismatch",
        ),
        label=label,
        depth_percent=depth_percent,
        target_tokens=total_tokens,
        line_count=line_count,
        needle_line_index=needle_line_index,
        tokens_per_line=float(tokens_per_line),
        seed=seed,
    )


def calibrate_tokens_per_line(client: OpenAIClient, model: str) -> float:
    """Measure the server's own tokens-per-line ratio with a single request.

    Exactly one calibration request runs per invocation. Repeating it once per
    depth is what previously polluted the shared prefix across probes.
    """
    response = client.chat(
        {
            "model": model,
            "messages": [{"role": "user", "content": calibration_prompt()}],
            "max_tokens": 1,
            "temperature": 0.0,
        }
    )
    prompt_tokens, _completion_tokens = _extract_usage(response)
    if prompt_tokens is None:
        raise MalformedResponse("the calibration request reported no prompt tokens")
    measured = prompt_tokens / CALIBRATION_LINES
    if not MINIMUM_TOKENS_PER_LINE <= measured <= MAXIMUM_TOKENS_PER_LINE:
        raise MalformedResponse(
            "the calibration measurement is outside the plausible range"
        )
    return measured


def run_needle_suite(
    client: OpenAIClient,
    model: str,
    *,
    target_tokens: int = NEEDLE_TARGET_TOKENS,
    depths: Sequence[int] = NEEDLE_DEPTHS,
    seed: int = NEEDLE_SEED,
    max_tokens: int = NEEDLE_MAX_TOKENS,
) -> tuple[list[CaseResult], list[dict[str, Any]]]:
    """Probe every requested depth once against a single calibration."""
    tokens_per_line = calibrate_tokens_per_line(client, model)
    results: list[CaseResult] = []
    records: list[dict[str, Any]] = []
    tolerance = target_tokens * NEEDLE_TOLERANCE_FRACTION
    for depth in depths:
        needle = build_needle_case(
            target_tokens,
            depth,
            seed,
            tokens_per_line=tokens_per_line,
            model=model,
            max_tokens=max_tokens,
        )
        try:
            response = client.chat(dict(needle.case.request))
        except InfrastructureError as exc:
            result = _case_result(
                needle.case,
                exc.failure_class,
                None,
                None,
                None,
                0,
                0,
            )
        else:
            result = evaluate_case(needle.case, response)
        within_tolerance = (
            result.prompt_tokens is not None
            and abs(result.prompt_tokens - target_tokens) <= tolerance
        )
        if result.passed and not within_tolerance:
            # The label was returned, but the probe did not exercise the
            # requested context size, so the retrieval claim is not supported.
            result = dataclasses.replace(
                result,
                passed=False,
                failure_class="prompt-size-mismatch",
                detail=FAILURE_DETAILS["prompt-size-mismatch"],
            )
        results.append(result)
        records.append(
            {
                "name": needle.case.name,
                "depth_percent": depth,
                "label": needle.label,
                "target_tokens": target_tokens,
                "line_count": needle.line_count,
                "needle_line_index": needle.needle_line_index,
                "tokens_per_line": round(needle.tokens_per_line, 4),
                "prompt_tokens": result.prompt_tokens,
                "completion_tokens": result.completion_tokens,
                "prompt_tokens_within_tolerance": within_tolerance,
                "retrieved": result.failure_class != "needle-mismatch",
                "finish_reason": result.finish_reason,
            }
        )
    return results, records


# ---------------------------------------------------------------------------
# Sanitized evidence
# ---------------------------------------------------------------------------


def canonical_json(value: Any) -> str:
    return json.dumps(
        value,
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    )


def _require_safe_scalar(value: Any, location: str) -> Any:
    if value is None or isinstance(value, bool) or isinstance(value, int):
        return value
    if isinstance(value, float):
        if value != value or value in (float("inf"), float("-inf")):
            raise EvidenceError(f"{location} is not a finite number")
        return value
    if isinstance(value, str):
        if UNSAFE_VALUE_PATTERN.search(value):
            raise EvidenceError(f"{location} carries inventory or credential material")
        if len(value) > 200:
            raise EvidenceError(f"{location} is longer than published evidence allows")
        return value
    raise EvidenceError(f"{location} is not a publishable scalar")


def _require_safe_mapping(value: Any, location: str) -> dict[str, Any]:
    if not isinstance(value, Mapping):
        raise EvidenceError(f"{location} is not an object")
    safe: dict[str, Any] = {}
    for key, item in value.items():
        if not isinstance(key, str) or not CONFIGURATION_KEY_PATTERN.fullmatch(key):
            raise EvidenceError(f"{location} carries an unsafe field name")
        if isinstance(item, list):
            safe[key] = [
                _require_safe_scalar(element, f"{location}.{key}") for element in item
            ]
            continue
        if isinstance(item, Mapping):
            safe[key] = _require_safe_mapping(item, f"{location}.{key}")
            continue
        safe[key] = _require_safe_scalar(item, f"{location}.{key}")
    return safe


def _case_payload(result: CaseResult) -> dict[str, Any]:
    if not DETAIL_PATTERN.fullmatch(result.detail):
        raise EvidenceError("a case detail is not fixed publishable phrasing")
    return {
        "name": result.name,
        "suite": result.suite,
        "passed": bool(result.passed),
        "failure_class": result.failure_class,
        "detail": result.detail,
        "prompt_tokens": result.prompt_tokens,
        "completion_tokens": result.completion_tokens,
        "finish_reason": result.finish_reason,
        "content_characters": result.content_characters,
        "reasoning_characters": result.reasoning_characters,
    }


def worst_outcome(failure_classes: Sequence[str | None]) -> str:
    kinds = {failure_kind(item) for item in failure_classes if item is not None}
    if "infrastructure" in kinds:
        return "failed-infrastructure"
    if "correctness" in kinds:
        return "failed-correctness"
    return "passed"


def sanitized_suite_payload(
    suite: str,
    identity: IdentityReport,
    results: Sequence[CaseResult],
    records: Sequence[Mapping[str, Any]],
    request_configuration: Mapping[str, Any],
) -> dict[str, Any]:
    """Build the only representation of an API suite that may be persisted."""
    if suite not in API_SUITE_NAMES:
        raise EvidenceError(f"unknown API suite: {suite!r}")
    payload = {
        "schema_version": SCHEMA_VERSION,
        "suite": suite,
        "served_model_name": _require_safe_scalar(
            identity.served_model_name,
            "served model name",
        ),
        # The pinned snapshot path is deliberately reduced to a claim: it proves
        # the identity gate ran without publishing the remote filesystem layout.
        "model_path_matches_recorded_run": bool(identity.model_path),
        "outcome": worst_outcome([result.failure_class for result in results]),
        "request_configuration": _require_safe_mapping(
            request_configuration,
            "request configuration",
        ),
        "cases": [_case_payload(result) for result in results],
        "needle_probes": [
            _require_safe_mapping(record, "needle probe") for record in records
        ],
    }
    return payload


# ---------------------------------------------------------------------------
# Run-scoped evidence directories and atomic persistence
# ---------------------------------------------------------------------------


def new_validation_id() -> str:
    """A collision-resistant identifier in the same shape as a run identity."""
    now = datetime.datetime.now(datetime.timezone.utc)
    return f"{now.strftime('%Y%m%dT%H%M%S.%f')}Z-{secrets.token_hex(16)}"


def validate_validation_id(value: str) -> str:
    if not isinstance(value, str) or not VALIDATION_ID_PATTERN.fullmatch(value):
        raise ValueError("the validation identifier does not use the required format")
    return value


def _require_plain_directory(path: pathlib.Path) -> None:
    try:
        mode = path.lstat().st_mode
    except OSError as exc:
        raise EvidenceError(f"cannot inspect {path}: {exc}") from exc
    if not stat.S_ISDIR(mode) or stat.S_ISLNK(mode):
        raise EvidenceError(f"validation output path is not a plain directory: {path}")


def prepare_validation_directory(
    root: pathlib.Path,
    run_id: str,
    validation_id: str,
) -> pathlib.Path:
    """Create a fresh, private, run-scoped directory without following links."""
    validate_validation_id(validation_id)
    if not VALIDATION_ID_PATTERN.fullmatch(run_id):
        raise ValueError("the run identifier does not use the required format")
    root = pathlib.Path(root)
    try:
        root.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise EvidenceError(f"cannot create {root}: {exc}") from exc
    _require_plain_directory(root)
    try:
        root.chmod(0o700)
    except OSError as exc:
        raise EvidenceError(f"cannot secure {root}: {exc}") from exc

    run_directory = root / run_id
    if run_directory.exists() or run_directory.is_symlink():
        _require_plain_directory(run_directory)
    else:
        try:
            run_directory.mkdir(mode=0o700)
        except OSError as exc:
            raise EvidenceError(f"cannot create {run_directory}: {exc}") from exc
    validation_directory = run_directory / validation_id
    try:
        # Exclusive creation: a repeated validation never reuses or overwrites
        # the evidence of an earlier one.
        validation_directory.mkdir(mode=0o700)
    except OSError as exc:
        raise EvidenceError(f"cannot create {validation_directory}: {exc}") from exc
    return validation_directory


def _write_atomically(directory: pathlib.Path, name: str, text: str) -> pathlib.Path:
    _require_plain_directory(directory)
    destination = directory / name
    temporary_path: pathlib.Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=directory,
            prefix=f".{name}.",
            delete=False,
        ) as handle:
            temporary_path = pathlib.Path(handle.name)
            os.fchmod(handle.fileno(), 0o600)
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, destination)
        temporary_path = None
        os.chmod(destination, 0o600)
        descriptor = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    except OSError as exc:
        raise EvidenceError(f"cannot atomically write {destination}: {exc}") from exc
    finally:
        if temporary_path is not None:
            try:
                temporary_path.unlink()
            except FileNotFoundError:
                pass
    return destination


def validate_suite_document(document: Any, expected_suite: str) -> str:
    """Reject any suite payload that is malformed, unknown, or unsafe.

    A remote reply is untrusted input. Only a payload whose shape, vocabulary,
    and every published value are provably safe becomes validation evidence.
    """
    if expected_suite not in SUITE_NAMES:
        raise EvidenceError(f"unknown suite: {expected_suite!r}")
    if not isinstance(document, Mapping):
        raise EvidenceError("the suite payload is not a JSON object")
    if document.get("schema_version") != SCHEMA_VERSION:
        raise EvidenceError("the suite payload has an unsupported schema version")
    if document.get("suite") != expected_suite:
        raise EvidenceError("the suite payload does not describe the requested suite")
    outcome = document.get("outcome")
    if outcome not in OUTCOMES:
        raise EvidenceError("the suite payload does not report a known outcome")
    if not isinstance(document.get("model_path_matches_recorded_run"), bool):
        raise EvidenceError("the suite payload does not assert recorded identity")
    _require_safe_scalar(document.get("served_model_name"), "served model name")
    _require_safe_mapping(
        document.get("request_configuration"),
        "request configuration",
    )
    if expected_suite == "benchmark":
        expected_keys = {
            "schema_version",
            "suite",
            "served_model_name",
            "model_path_matches_recorded_run",
            "outcome",
            "request_configuration",
            "concurrency",
        }
        if set(document) != expected_keys:
            raise EvidenceError("the benchmark payload has missing or unknown fields")
        concurrency = document.get("concurrency")
        if not isinstance(concurrency, Mapping) or set(concurrency) != {"c1", "c4"}:
            raise EvidenceError("the benchmark payload must report exactly C1 and C4")
        for key, expected_value in (("c1", 1), ("c4", 4)):
            section = _require_safe_mapping(concurrency[key], f"benchmark {key}")
            if section.get("concurrency") != expected_value:
                raise EvidenceError(f"benchmark {key} does not report its concurrency")
            if not isinstance(section.get("failure_classes"), list):
                raise EvidenceError(f"benchmark {key} does not report failure classes")
        return outcome

    expected_keys = {
        "schema_version",
        "suite",
        "served_model_name",
        "model_path_matches_recorded_run",
        "outcome",
        "request_configuration",
        "cases",
        "needle_probes",
    }
    if set(document) != expected_keys:
        raise EvidenceError("the suite payload has missing or unknown fields")
    cases = document.get("cases")
    if not isinstance(cases, list) or not cases:
        raise EvidenceError("the suite payload carried no evaluated cases")
    case_keys = {
        "name",
        "suite",
        "passed",
        "failure_class",
        "detail",
        "prompt_tokens",
        "completion_tokens",
        "finish_reason",
        "content_characters",
        "reasoning_characters",
    }
    for case in cases:
        if not isinstance(case, Mapping) or set(case) != case_keys:
            raise EvidenceError("a case record has missing or unknown fields")
        _require_safe_mapping(case, "case record")
        failure_class = case.get("failure_class")
        if failure_class is not None:
            failure_kind(failure_class)
        detail = case.get("detail")
        if not isinstance(detail, str) or not DETAIL_PATTERN.fullmatch(detail):
            raise EvidenceError("a case detail is not fixed publishable phrasing")
    probes = document.get("needle_probes")
    if not isinstance(probes, list):
        raise EvidenceError("the suite payload does not report needle probes")
    for probe in probes:
        _require_safe_mapping(probe, "needle probe")
    return outcome


def build_manifest(
    run_id: str,
    validation_id: str,
    requested_suite: str,
    profile_name: str,
    served_model_name: str,
    config_digest: str,
    lock_digest: str,
    status: str,
    completed: Sequence[str],
) -> dict[str, Any]:
    if status not in MANIFEST_STATUSES:
        raise EvidenceError(f"unknown manifest status: {status!r}")
    if requested_suite not in (*SUITE_NAMES, "all"):
        raise EvidenceError(f"unknown requested suite: {requested_suite!r}")
    validate_validation_id(validation_id)
    if not VALIDATION_ID_PATTERN.fullmatch(run_id):
        raise EvidenceError("the run identifier does not use the required format")
    for digest in (config_digest, lock_digest):
        if not DIGEST_PATTERN.fullmatch(digest):
            raise EvidenceError("a recorded contract digest is malformed")
    suites: dict[str, str] = {}
    for entry in completed:
        name, separator, outcome = entry.partition("=")
        if not separator or name not in SUITE_NAMES or outcome not in OUTCOMES:
            raise EvidenceError(f"malformed completed suite record: {entry!r}")
        if name in suites:
            raise EvidenceError(f"completed suite repeats: {name}")
        suites[name] = outcome
    return {
        "schema_version": SCHEMA_VERSION,
        "run_id": run_id,
        "validation_id": validation_id,
        "requested_suite": requested_suite,
        "profile_name": _require_safe_scalar(profile_name, "profile name"),
        "served_model_name": _require_safe_scalar(
            served_model_name,
            "served model name",
        ),
        "config_digest": config_digest,
        "lock_digest": lock_digest,
        "status": status,
        "suites": suites,
        "updated_at": _utc_now(),
    }


def append_event(directory: pathlib.Path, suite: str, status: str) -> None:
    """Append one sanitized event line without ever rewriting earlier ones."""
    if suite not in SUITE_NAMES:
        raise EvidenceError(f"unknown suite: {suite!r}")
    if status not in OUTCOMES:
        raise EvidenceError(f"unknown event status: {status!r}")
    _require_plain_directory(pathlib.Path(directory))
    line = canonical_json(
        {"at": _utc_now(), "suite": suite, "status": status}
    )
    path = pathlib.Path(directory) / "events.jsonl"
    descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        os.write(descriptor, (line + "\n").encode("utf-8"))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _utc_now() -> str:
    now = datetime.datetime.now(datetime.timezone.utc)
    return now.strftime("%Y-%m-%dT%H:%M:%S.%fZ")


# ---------------------------------------------------------------------------
# Remote execution bootstrap
# ---------------------------------------------------------------------------


def build_bootstrap(
    preloaded: Sequence[tuple[str, bytes]],
    entry_source: bytes,
) -> str:
    """Render a single-line bootstrap that runs this package's modules remotely.

    Nodes hold no copy of these tools, so the controller ships the exact local
    bytes it just digested. Preloaded modules are registered under their real
    dotted names, and their parent packages are stubbed, so the entry module
    keeps the same ordinary top-level imports it uses locally.
    """
    statements = ["import base64", "import sys", "import types"]
    packaged: set[str] = set()
    for name, source in preloaded:
        parts = name.split(".")
        for part in parts:
            if not IDENTIFIER_PATTERN.fullmatch(part):
                raise ValueError(f"unsafe preloaded module name: {name!r}")
        for depth in range(1, len(parts)):
            package = ".".join(parts[:depth])
            if package in packaged:
                continue
            packaged.add(package)
            statements.extend(
                (
                    f'_package = types.ModuleType("{package}")',
                    "_package.__path__ = []",
                    f'sys.modules["{package}"] = _package',
                )
            )
        encoded = base64.b64encode(source).decode("ascii")
        statements.extend(
            (
                f'_module = types.ModuleType("{name}")',
                f'_module.__file__ = "<{name}>"',
                f'sys.modules["{name}"] = _module',
                (
                    f'exec(compile(base64.b64decode("{encoded}"), '
                    f'"<{name}>", "exec"), _module.__dict__)'
                ),
            )
        )
        if len(parts) > 1:
            parent = ".".join(parts[:-1])
            statements.append(
                f'setattr(sys.modules["{parent}"], "{parts[-1]}", _module)'
            )
    encoded_entry = base64.b64encode(entry_source).decode("ascii")
    statements.append(
        f'exec(compile(base64.b64decode("{encoded_entry}"), '
        '"<entry>", "exec"), {"__name__": "__main__"})'
    )
    return ";".join(statements)


def build_remote_command(
    mode: str,
    arguments: Sequence[str],
    root: pathlib.Path = REPOSITORY_ROOT,
) -> str:
    if mode not in SUITE_NAMES:
        raise ValueError(f"unsupported remote validation mode: {mode!r}")
    api_source = (pathlib.Path(root) / "tools" / "api_validation.py").read_bytes()
    if mode == "benchmark":
        preloaded = [("tools.api_validation", api_source)]
        entry_source = (pathlib.Path(root) / "tools" / "benchmark.py").read_bytes()
    else:
        preloaded = []
        entry_source = api_source
    argv = [
        "python3",
        "-c",
        build_bootstrap(preloaded, entry_source),
        "remote",
        "--mode",
        mode,
        "--",
        *arguments,
    ]
    return shlex.join(argv)


# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------


def _strip_separator(arguments: Sequence[str]) -> list[str]:
    values = list(arguments)
    if values and values[0] == "--":
        return values[1:]
    return values


def _build_remote_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="api_validation.py remote")
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--timeout-seconds", required=True, type=float)
    parser.add_argument("--expected-model-path", required=True)
    parser.add_argument("--expected-served-name", required=True)
    parser.add_argument("--max-tokens", type=int, default=DEFAULT_MAX_TOKENS)
    parser.add_argument("--target-tokens", type=int, default=NEEDLE_TARGET_TOKENS)
    parser.add_argument("--depths", default=",".join(str(item) for item in NEEDLE_DEPTHS))
    parser.add_argument("--seed", type=int, default=NEEDLE_SEED)
    return parser


def _parse_depths(value: str) -> tuple[int, ...]:
    depths = []
    for raw in value.split(","):
        text = raw.strip()
        if not text.isdigit():
            raise ValueError("the needle depth list must contain integers only")
        depth = int(text)
        if not 0 <= depth <= 100:
            raise ValueError("every needle depth must be a percentage")
        depths.append(depth)
    if not depths:
        raise ValueError("the needle depth list is empty")
    return tuple(depths)


def run_remote_suite(mode: str, arguments: Sequence[str]) -> dict[str, Any]:
    """Execute one API suite on the serving node and return its payload."""
    options = _build_remote_parser().parse_args(list(arguments))
    client = OpenAIClient(options.base_url, timeout_seconds=options.timeout_seconds)
    served_name = options.expected_served_name
    configuration: dict[str, Any] = {
        "temperature": 0.0,
        "max_tokens": options.max_tokens,
        "timeout_seconds": options.timeout_seconds,
    }
    try:
        identity = verify_identity(
            client,
            options.expected_model_path,
            served_name,
        )
    except InfrastructureError as exc:
        return _failed_suite_payload(mode, served_name, exc.failure_class, configuration)

    try:
        if mode == "smoke":
            results = run_cases(client, build_smoke_cases(served_name, options.max_tokens))
            records: list[dict[str, Any]] = []
        elif mode == "correctness":
            results = run_cases(
                client,
                build_correctness_cases(served_name, options.max_tokens),
            )
            records = []
        else:
            configuration.update(
                {
                    "target_tokens": options.target_tokens,
                    "depths": list(_parse_depths(options.depths)),
                    "seed": options.seed,
                    "max_tokens": NEEDLE_MAX_TOKENS,
                    "tolerance_fraction": NEEDLE_TOLERANCE_FRACTION,
                }
            )
            results, records = run_needle_suite(
                client,
                served_name,
                target_tokens=options.target_tokens,
                depths=_parse_depths(options.depths),
                seed=options.seed,
            )
    except InfrastructureError as exc:
        return _failed_suite_payload(mode, served_name, exc.failure_class, configuration)
    return sanitized_suite_payload(mode, identity, results, records, configuration)


def _failed_suite_payload(
    suite: str,
    served_name: str,
    failure_class: str,
    configuration: Mapping[str, Any],
) -> dict[str, Any]:
    """Report an infrastructure fault as evidence rather than as a crash."""
    return {
        "schema_version": SCHEMA_VERSION,
        "suite": suite,
        "served_model_name": served_name,
        "model_path_matches_recorded_run": False,
        "outcome": "failed-infrastructure",
        "request_configuration": _require_safe_mapping(
            configuration,
            "request configuration",
        ),
        "cases": [
            {
                "name": "gate",
                "suite": suite if suite in API_SUITE_NAMES else "smoke",
                "passed": False,
                "failure_class": failure_class,
                "detail": FAILURE_DETAILS[failure_class],
                "prompt_tokens": None,
                "completion_tokens": None,
                "finish_reason": None,
                "content_characters": 0,
                "reasoning_characters": 0,
            }
        ],
        "needle_probes": [],
    }


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="api_validation.py")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("new-id")

    encode_parser = subparsers.add_parser("encode")
    encode_parser.add_argument("--mode", required=True, choices=SUITE_NAMES)
    encode_parser.add_argument("arguments", nargs=argparse.REMAINDER)

    remote_parser = subparsers.add_parser("remote")
    remote_parser.add_argument("--mode", required=True, choices=SUITE_NAMES)
    remote_parser.add_argument("arguments", nargs=argparse.REMAINDER)

    directory_parser = subparsers.add_parser("prepare-directory")
    directory_parser.add_argument("--root", required=True, type=pathlib.Path)
    directory_parser.add_argument("--run-id", required=True)
    directory_parser.add_argument("--validation-id", required=True)

    persist_parser = subparsers.add_parser("persist")
    persist_parser.add_argument("--directory", required=True, type=pathlib.Path)
    persist_parser.add_argument("--name", required=True)
    persist_parser.add_argument("--expect-suite", required=True, choices=SUITE_NAMES)

    manifest_parser = subparsers.add_parser("manifest")
    manifest_parser.add_argument("--directory", required=True, type=pathlib.Path)
    manifest_parser.add_argument("--run-id", required=True)
    manifest_parser.add_argument("--validation-id", required=True)
    manifest_parser.add_argument("--requested-suite", required=True)
    manifest_parser.add_argument("--profile-name", required=True)
    manifest_parser.add_argument("--served-model-name", required=True)
    manifest_parser.add_argument("--config-digest", required=True)
    manifest_parser.add_argument("--lock-digest", required=True)
    manifest_parser.add_argument("--status", required=True)
    manifest_parser.add_argument("--completed-suite", action="append", default=[])

    event_parser = subparsers.add_parser("append-event")
    event_parser.add_argument("--directory", required=True, type=pathlib.Path)
    event_parser.add_argument("--suite", required=True, choices=SUITE_NAMES)
    event_parser.add_argument("--status", required=True, choices=OUTCOMES)
    return parser


def _read_bounded_stdin() -> str:
    payload = sys.stdin.read(MAX_RESPONSE_BYTES + 1)
    if len(payload) > MAX_RESPONSE_BYTES:
        raise EvidenceError("the suite payload exceeded the bounded read")
    return payload


def main(arguments: list[str] | None = None) -> int:
    parser = _build_parser()
    options = parser.parse_args(arguments)
    try:
        if options.command == "new-id":
            print(new_validation_id())
            return 0
        if options.command == "encode":
            print(
                build_remote_command(
                    options.mode,
                    _strip_separator(options.arguments),
                )
            )
            return 0
        if options.command == "remote":
            payload = run_remote_suite(
                options.mode,
                _strip_separator(options.arguments),
            )
            print(canonical_json(payload))
            return 0
        if options.command == "prepare-directory":
            print(
                prepare_validation_directory(
                    options.root,
                    options.run_id,
                    options.validation_id,
                )
            )
            return 0
        if options.command == "persist":
            if not ARTIFACT_NAME_PATTERN.fullmatch(options.name):
                raise EvidenceError(f"unsafe artifact name: {options.name!r}")
            try:
                document = json.loads(_read_bounded_stdin())
            except ValueError as exc:
                raise EvidenceError("the suite payload was not valid JSON") from exc
            outcome = validate_suite_document(document, options.expect_suite)
            _write_atomically(
                options.directory,
                options.name,
                canonical_json(document) + "\n",
            )
            print(outcome)
            return 0
        if options.command == "manifest":
            manifest = build_manifest(
                run_id=options.run_id,
                validation_id=options.validation_id,
                requested_suite=options.requested_suite,
                profile_name=options.profile_name,
                served_model_name=options.served_model_name,
                config_digest=options.config_digest,
                lock_digest=options.lock_digest,
                status=options.status,
                completed=options.completed_suite,
            )
            _write_atomically(
                options.directory,
                "manifest.json",
                canonical_json(manifest) + "\n",
            )
            return 0
        if options.command == "append-event":
            append_event(options.directory, options.suite, options.status)
            return 0
    except (EvidenceError, ValidationError, ValueError, OSError) as exc:
        print(f"api_validation: {exc}", file=sys.stderr)
        return 2
    parser.error(f"unsupported command: {options.command}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
