"""Correctness tests for the read-only API validation module.

Every HTTP interaction and every clock reading is a local fake. Nothing in this
file may contact a node, a served endpoint, or the network.
"""

import dataclasses
import io
import json
import pathlib
import re
import shlex
import socket
import sys
import unittest
import urllib.error

from tools.api_validation import (
    CALIBRATION_LINE_OFFSET,
    CORRECTNESS_FAILURE_CLASSES,
    INFRASTRUCTURE_FAILURE_CLASSES,
    NEEDLE_DEPTHS,
    NEEDLE_LABEL_PATTERN,
    HTTPFailure,
    IdentityMismatch,
    MalformedResponse,
    OpenAIClient,
    TimeoutFailure,
    TransportFailure,
    ToolExpectation,
    ValidationCase,
    build_bootstrap,
    build_correctness_cases,
    build_needle_case,
    build_remote_command,
    build_smoke_cases,
    calibrate_tokens_per_line,
    calibration_prompt,
    evaluate_case,
    failure_kind,
    new_validation_id,
    run_needle_suite,
    sanitized_suite_payload,
    validate_validation_id,
    verify_identity,
)


ROOT = pathlib.Path(__file__).resolve().parents[1]
API_FIXTURES = ROOT / "tests" / "fixtures" / "api"
BASE_URL = "http://198.51.100.10:8002"
MODEL = "glm-5.3-flash-nvfp4"
MODEL_PATH = (
    "/srv/hf-cache/models--LibertAIDAI--GLM-5.3-Flash-NVFP4/snapshots/"
    "aa28e1f54130286c95fee10d0705c74ce8743734"
)


def load_fixture(name: str) -> dict:
    return json.loads((API_FIXTURES / name).read_text(encoding="utf-8"))


class FakeResponse(io.BytesIO):
    """Minimal stand-in for the object urlopen returns."""

    def __init__(self, payload: bytes, status: int = 200) -> None:
        super().__init__(payload)
        self.status = status

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *_exception: object) -> bool:
        self.close()
        return False


class RecordingOpener:
    """Serves queued fixture bodies and records every issued request."""

    def __init__(self, bodies: list[object]) -> None:
        self.bodies = list(bodies)
        self.requests: list[dict] = []
        self.timeouts: list[float] = []

    def __call__(self, request: object, timeout: float = 0.0) -> FakeResponse:
        self.timeouts.append(timeout)
        payload = b""
        if request.data:
            payload = request.data
        self.requests.append(
            {
                "url": request.full_url,
                "method": request.get_method(),
                "headers": dict(request.headers),
                "body": json.loads(payload) if payload else None,
            }
        )
        if not self.bodies:
            raise AssertionError("the fake opener ran out of queued responses")
        body = self.bodies.pop(0)
        if isinstance(body, BaseException):
            raise body
        if isinstance(body, tuple):
            status, encoded = body
            return FakeResponse(encoded, status=status)
        if isinstance(body, bytes):
            return FakeResponse(body)
        return FakeResponse(json.dumps(body).encode("utf-8"))


def json_client(bodies: list[object], **keywords: object) -> tuple:
    opener = RecordingOpener(bodies)
    client = OpenAIClient(
        BASE_URL,
        timeout_seconds=30.0,
        opener=opener,
        **keywords,
    )
    return client, opener


class ClientTransportTests(unittest.TestCase):
    def test_chat_posts_canonical_json_with_bounded_timeout(self) -> None:
        client, opener = json_client([load_fixture("chat.smoke.ok.json")])
        response = client.chat({"model": MODEL, "messages": []})
        self.assertEqual(response["model"], MODEL)
        self.assertEqual(opener.timeouts, [30.0])
        issued = opener.requests[0]
        self.assertEqual(issued["url"], f"{BASE_URL}/v1/chat/completions")
        self.assertEqual(issued["method"], "POST")
        self.assertEqual(issued["headers"]["Content-type"], "application/json")
        self.assertEqual(issued["body"], {"model": MODEL, "messages": []})

    def test_authorization_headers_are_never_sent(self) -> None:
        client, opener = json_client([load_fixture("chat.smoke.ok.json")])
        client.chat({"model": MODEL, "messages": []})
        lowered = {key.lower() for key in opener.requests[0]["headers"]}
        self.assertNotIn("authorization", lowered)
        self.assertNotIn("proxy-authorization", lowered)

    def test_rejects_a_non_positive_timeout(self) -> None:
        with self.assertRaises(ValueError):
            OpenAIClient(BASE_URL, timeout_seconds=0.0)

    def test_rejects_a_non_http_base_url(self) -> None:
        with self.assertRaises(ValueError):
            OpenAIClient("file:///etc/passwd", timeout_seconds=5.0)

    def test_rejects_a_base_url_carrying_credentials(self) -> None:
        with self.assertRaises(ValueError):
            OpenAIClient("http://user:secret@198.51.100.10:8002", timeout_seconds=5.0)

    def test_malformed_body_is_an_infrastructure_failure(self) -> None:
        malformed = (API_FIXTURES / "malformed.txt").read_bytes()
        client, _opener = json_client([malformed])
        with self.assertRaises(MalformedResponse) as caught:
            client.chat({"model": MODEL, "messages": []})
        self.assertEqual(caught.exception.failure_class, "malformed-response")
        self.assertEqual(failure_kind("malformed-response"), "infrastructure")

    def test_oversized_body_is_rejected_before_decoding(self) -> None:
        client, _opener = json_client([b"[" + b"0," * 4096 + b"0]"], max_response_bytes=64)
        with self.assertRaises(MalformedResponse):
            client.chat({"model": MODEL, "messages": []})

    def test_http_error_status_is_classified_and_body_is_not_exposed(self) -> None:
        error = urllib.error.HTTPError(
            f"{BASE_URL}/v1/chat/completions",
            503,
            "Service Unavailable",
            {},
            io.BytesIO(b"internal upstream detail that must not leak"),
        )
        client, _opener = json_client([error])
        with self.assertRaises(HTTPFailure) as caught:
            client.chat({"model": MODEL, "messages": []})
        self.assertEqual(caught.exception.failure_class, "http-status")
        self.assertEqual(caught.exception.status_code, 503)
        self.assertNotIn("upstream detail", str(caught.exception))

    def test_non_success_status_without_an_exception_is_still_rejected(self) -> None:
        client, _opener = json_client([(500, b"{}")])
        with self.assertRaises(HTTPFailure):
            client.chat({"model": MODEL, "messages": []})

    def test_transport_error_is_classified(self) -> None:
        client, _opener = json_client([urllib.error.URLError("connection refused")])
        with self.assertRaises(TransportFailure) as caught:
            client.chat({"model": MODEL, "messages": []})
        self.assertEqual(caught.exception.failure_class, "transport")

    def test_timeout_is_classified_separately_from_transport(self) -> None:
        client, _opener = json_client([socket.timeout("timed out")])
        with self.assertRaises(TimeoutFailure) as caught:
            client.chat({"model": MODEL, "messages": []})
        self.assertEqual(caught.exception.failure_class, "timeout")
        self.assertEqual(failure_kind("timeout"), "infrastructure")

    def test_failure_class_taxonomy_is_disjoint_and_closed(self) -> None:
        self.assertEqual(
            INFRASTRUCTURE_FAILURE_CLASSES & CORRECTNESS_FAILURE_CLASSES,
            frozenset(),
        )
        for failure_class in INFRASTRUCTURE_FAILURE_CLASSES:
            self.assertEqual(failure_kind(failure_class), "infrastructure")
        for failure_class in CORRECTNESS_FAILURE_CLASSES:
            self.assertEqual(failure_kind(failure_class), "correctness")
        with self.assertRaises(ValueError):
            failure_kind("something-invented")


class StreamingTests(unittest.TestCase):
    @staticmethod
    def stream_body(chunks: list[dict]) -> bytes:
        lines = [f"data: {json.dumps(chunk)}\n\n" for chunk in chunks]
        lines.append("data: [DONE]\n\n")
        return "".join(lines).encode("utf-8")

    def test_stream_measures_ttft_and_end_to_end_from_a_monotonic_clock(self) -> None:
        body = self.stream_body(
            [
                {"choices": [{"delta": {"reasoning_content": "weighing"}}]},
                {"choices": [{"delta": {"content": "alpha"}}]},
                {"choices": [{"delta": {"content": " beta"}, "finish_reason": "length"}]},
                {
                    "choices": [],
                    "usage": {"prompt_tokens": 64, "completion_tokens": 1024},
                },
            ]
        )
        readings = iter([100.0, 100.25, 131.0])
        client, _opener = json_client([body], clock=lambda: next(readings))
        streamed = client.stream_chat(
            {
                "model": MODEL,
                "messages": [],
                "stream": True,
                "stream_options": {"include_usage": True},
            }
        )
        self.assertEqual(streamed.started_seconds, 100.0)
        self.assertEqual(streamed.completed_seconds, 131.0)
        self.assertAlmostEqual(streamed.ttft_seconds, 0.25)
        self.assertAlmostEqual(streamed.end_to_end_seconds, 31.0)
        self.assertEqual(streamed.completion_tokens, 1024)
        self.assertEqual(streamed.prompt_tokens, 64)
        self.assertEqual(streamed.finish_reason, "length")
        self.assertEqual(streamed.content_characters, len("alpha beta"))
        self.assertEqual(streamed.reasoning_characters, len("weighing"))

    def test_ttft_counts_the_first_streamed_token_including_reasoning(self) -> None:
        # Time to first token measures prefill. This deployment is
        # thinking-always, so waiting for the first content token would report
        # the whole reasoning trace as prefill latency.
        body = self.stream_body(
            [
                {"choices": [{"delta": {"reasoning_content": "thinking"}}]},
                {"choices": [{"delta": {"content": "x"}}]},
                {
                    "choices": [],
                    "usage": {"prompt_tokens": 8, "completion_tokens": 2},
                },
            ]
        )
        readings = iter([10.0, 10.5, 12.0])
        client, _opener = json_client([body], clock=lambda: next(readings))
        streamed = client.stream_chat(
            {
                "model": MODEL,
                "messages": [],
                "stream": True,
                "stream_options": {"include_usage": True},
            }
        )
        self.assertAlmostEqual(streamed.ttft_seconds, 0.5)
        self.assertEqual(streamed.reasoning_characters, len("thinking"))

    def test_stream_requires_usage_reporting_to_be_requested(self) -> None:
        client, _opener = json_client([b""])
        with self.assertRaises(ValueError):
            client.stream_chat({"model": MODEL, "messages": [], "stream": True})

    def test_stream_without_usage_never_fabricates_a_token_count(self) -> None:
        body = self.stream_body([{"choices": [{"delta": {"content": "x"}}]}])
        readings = iter([1.0, 1.1, 2.0])
        client, _opener = json_client([body], clock=lambda: next(readings))
        with self.assertRaises(MalformedResponse):
            client.stream_chat(
                {
                    "model": MODEL,
                    "messages": [],
                    "stream": True,
                    "stream_options": {"include_usage": True},
                }
            )

    def test_stream_enforces_a_bounded_total_read(self) -> None:
        body = self.stream_body(
            [{"choices": [{"delta": {"content": "y" * 512}}]} for _ in range(32)]
        )
        readings = iter([1.0, 1.1, 2.0])
        client, _opener = json_client(
            [body],
            clock=lambda: next(readings),
            max_response_bytes=256,
        )
        with self.assertRaises(MalformedResponse):
            client.stream_chat(
                {
                    "model": MODEL,
                    "messages": [],
                    "stream": True,
                    "stream_options": {"include_usage": True},
                }
            )


class IdentityTests(unittest.TestCase):
    def test_matching_endpoint_reports_the_recorded_identity(self) -> None:
        client, opener = json_client(
            [
                load_fixture("model-info.ok.json"),
                load_fixture("models.ok.json"),
            ]
        )
        report = verify_identity(client, MODEL_PATH, MODEL)
        self.assertEqual(report.served_model_name, MODEL)
        self.assertEqual(report.model_path, MODEL_PATH)
        self.assertTrue(report.is_generation)
        self.assertEqual(
            [issued["url"] for issued in opener.requests],
            [f"{BASE_URL}/get_model_info", f"{BASE_URL}/v1/models"],
        )
        self.assertEqual(
            [issued["method"] for issued in opener.requests],
            ["GET", "GET"],
        )

    def test_wrong_model_path_is_an_identity_mismatch(self) -> None:
        payload = load_fixture("model-info.ok.json")
        payload["model_path"] = "/srv/hf-cache/models--other--Model/snapshots/deadbeef"
        client, _opener = json_client([payload])
        with self.assertRaises(IdentityMismatch) as caught:
            verify_identity(client, MODEL_PATH, MODEL)
        self.assertEqual(caught.exception.failure_class, "identity-mismatch")

    def test_non_generation_endpoint_is_an_identity_mismatch(self) -> None:
        payload = load_fixture("model-info.ok.json")
        payload["is_generation"] = False
        client, _opener = json_client([payload])
        with self.assertRaises(IdentityMismatch):
            verify_identity(client, MODEL_PATH, MODEL)

    def test_wrong_served_name_is_an_identity_mismatch(self) -> None:
        listing = load_fixture("models.ok.json")
        listing["data"][0]["id"] = "some-other-model"
        client, _opener = json_client([load_fixture("model-info.ok.json"), listing])
        with self.assertRaises(IdentityMismatch):
            verify_identity(client, MODEL_PATH, MODEL)

    def test_extra_served_models_are_an_identity_mismatch(self) -> None:
        listing = load_fixture("models.ok.json")
        listing["data"].append({"id": "shadow-model", "object": "model"})
        client, _opener = json_client([load_fixture("model-info.ok.json"), listing])
        with self.assertRaises(IdentityMismatch):
            verify_identity(client, MODEL_PATH, MODEL)

    def test_malformed_identity_payload_is_not_an_identity_mismatch(self) -> None:
        client, _opener = json_client([b"not json at all"])
        with self.assertRaises(MalformedResponse):
            verify_identity(client, MODEL_PATH, MODEL)


class CaseEvaluationTests(unittest.TestCase):
    def named_case(self, name: str) -> ValidationCase:
        for case in build_smoke_cases(MODEL) + build_correctness_cases(MODEL):
            if case.name == name:
                return case
        raise AssertionError(f"no built case is named {name}")

    def test_smoke_and_correctness_cases_cover_the_required_behaviors(self) -> None:
        smoke = [case.name for case in build_smoke_cases(MODEL)]
        correctness = [case.name for case in build_correctness_cases(MODEL)]
        self.assertEqual(smoke, ["smoke"])
        self.assertEqual(
            correctness,
            ["arithmetic", "code", "turkish", "tool_call"],
        )
        for case in build_smoke_cases(MODEL) + build_correctness_cases(MODEL):
            self.assertEqual(case.request["model"], MODEL)
            self.assertEqual(case.request["temperature"], 0.0)
            # Thinking-always behavior spends completion budget on reasoning
            # before any answer, so every case must fund a full reply.
            self.assertGreaterEqual(case.request["max_tokens"], 2048)

    def test_correct_answer_passes_and_publishes_only_counts(self) -> None:
        result = evaluate_case(
            self.named_case("arithmetic"),
            load_fixture("chat.arithmetic.ok.json"),
        )
        self.assertTrue(result.passed)
        self.assertIsNone(result.failure_class)
        self.assertEqual(result.prompt_tokens, 31)
        self.assertEqual(result.completion_tokens, 48)
        self.assertEqual(result.finish_reason, "stop")
        self.assertEqual(result.content_characters, len("105117"))
        self.assertGreater(result.reasoning_characters, 0)
        encoded = json.dumps(dataclasses.asdict(result))
        self.assertNotIn("105117", encoded)
        self.assertNotIn("2841", encoded)

    def test_wrong_answer_is_a_correctness_failure(self) -> None:
        result = evaluate_case(
            self.named_case("arithmetic"),
            load_fixture("chat.arithmetic.wrong.json"),
        )
        self.assertFalse(result.passed)
        self.assertEqual(result.failure_class, "wrong-answer")
        self.assertEqual(failure_kind(result.failure_class), "correctness")

    def test_code_case_requires_every_expected_fragment(self) -> None:
        passing = evaluate_case(
            self.named_case("code"),
            load_fixture("chat.code.ok.json"),
        )
        self.assertTrue(passing.passed)
        payload = load_fixture("chat.code.ok.json")
        payload["choices"][0]["message"]["content"] = "def other_name(value): pass"
        failing = evaluate_case(self.named_case("code"), payload)
        self.assertEqual(failing.failure_class, "wrong-answer")

    def test_turkish_case_preserves_non_ascii_comparison(self) -> None:
        result = evaluate_case(
            self.named_case("turkish"),
            load_fixture("chat.turkish.ok.json"),
        )
        self.assertTrue(result.passed)
        payload = load_fixture("chat.turkish.ok.json")
        payload["choices"][0]["message"]["content"] = "uc"
        self.assertEqual(
            evaluate_case(self.named_case("turkish"), payload).failure_class,
            "wrong-answer",
        )

    def test_trailing_punctuation_and_whitespace_do_not_fail_a_correct_answer(self) -> None:
        payload = load_fixture("chat.arithmetic.ok.json")
        payload["choices"][0]["message"]["content"] = "  105117.\n"
        self.assertTrue(evaluate_case(self.named_case("arithmetic"), payload).passed)

    def test_empty_content_is_reported_as_its_own_correctness_class(self) -> None:
        payload = load_fixture("chat.arithmetic.ok.json")
        payload["choices"][0]["message"]["content"] = "   "
        result = evaluate_case(self.named_case("arithmetic"), payload)
        self.assertEqual(result.failure_class, "empty-content")
        self.assertEqual(failure_kind(result.failure_class), "correctness")

    def test_tool_call_case_accepts_the_expected_function_and_arguments(self) -> None:
        result = evaluate_case(
            self.named_case("tool_call"),
            load_fixture("chat.tool-call.ok.json"),
        )
        self.assertTrue(result.passed)
        self.assertEqual(result.finish_reason, "tool_calls")

    def test_tool_call_schema_mismatch_is_distinct_from_a_missing_call(self) -> None:
        mismatch = evaluate_case(
            self.named_case("tool_call"),
            load_fixture("chat.tool-call.wrong-schema.json"),
        )
        self.assertEqual(mismatch.failure_class, "tool-schema-mismatch")
        without_call = load_fixture("chat.tool-call.ok.json")
        without_call["choices"][0]["message"].pop("tool_calls")
        without_call["choices"][0]["message"]["content"] = "I will look that up."
        self.assertEqual(
            evaluate_case(self.named_case("tool_call"), without_call).failure_class,
            "missing-tool-call",
        )

    def test_unparsable_tool_arguments_are_a_schema_mismatch(self) -> None:
        payload = load_fixture("chat.tool-call.ok.json")
        payload["choices"][0]["message"]["tool_calls"][0]["function"][
            "arguments"
        ] = "{not json"
        self.assertEqual(
            evaluate_case(self.named_case("tool_call"), payload).failure_class,
            "tool-schema-mismatch",
        )

    def test_structurally_broken_response_is_an_infrastructure_failure(self) -> None:
        for broken in ({}, {"choices": []}, {"choices": [{"message": None}]}):
            with self.subTest(broken=broken):
                result = evaluate_case(self.named_case("arithmetic"), broken)
                self.assertEqual(result.failure_class, "malformed-response")
                self.assertEqual(failure_kind(result.failure_class), "infrastructure")

    def test_missing_usage_is_reported_without_inventing_token_counts(self) -> None:
        payload = load_fixture("chat.arithmetic.ok.json")
        payload.pop("usage")
        result = evaluate_case(self.named_case("arithmetic"), payload)
        self.assertIsNone(result.prompt_tokens)
        self.assertIsNone(result.completion_tokens)

    def test_case_detail_comes_from_a_closed_vocabulary(self) -> None:
        details = set()
        payload = load_fixture("chat.arithmetic.wrong.json")
        details.add(evaluate_case(self.named_case("arithmetic"), payload).detail)
        details.add(
            evaluate_case(self.named_case("arithmetic"), {"choices": []}).detail
        )
        for detail in details:
            self.assertNotIn("105118", detail)
            self.assertRegex(detail, r"\A[A-Za-z0-9 ,.'-]+\Z")


class NeedleTests(unittest.TestCase):
    def test_depths_are_exactly_the_required_three(self) -> None:
        self.assertEqual(NEEDLE_DEPTHS, (10, 50, 90))

    def test_case_is_byte_identical_for_the_same_seed(self) -> None:
        first = build_needle_case(120000, 50, 20260828)
        second = build_needle_case(120000, 50, 20260828)
        self.assertEqual(first.prompt, second.prompt)
        self.assertEqual(first.label, second.label)
        self.assertEqual(first.needle_line_index, second.needle_line_index)

    def test_a_different_seed_changes_the_haystack_and_the_label(self) -> None:
        first = build_needle_case(120000, 50, 20260828)
        second = build_needle_case(120000, 50, 20260829)
        self.assertNotEqual(first.prompt, second.prompt)
        self.assertNotEqual(first.label, second.label)

    def test_label_uses_the_neutral_catalog_code_form(self) -> None:
        for depth in NEEDLE_DEPTHS:
            case = build_needle_case(120000, depth, 20260828)
            self.assertRegex(case.label, NEEDLE_LABEL_PATTERN)
            self.assertTrue(case.label.startswith("COPPER-IBIS-"))
            self.assertTrue(case.label.endswith("-ZX"))

    def test_labels_differ_across_depths_so_a_reply_cannot_be_reused(self) -> None:
        labels = {build_needle_case(120000, depth, 7).label for depth in NEEDLE_DEPTHS}
        self.assertEqual(len(labels), len(NEEDLE_DEPTHS))

    def test_prompt_wording_stays_neutral_and_avoids_credential_terms(self) -> None:
        case = build_needle_case(120000, 50, 20260828)
        lowered = case.prompt.lower()
        for forbidden in ("secret", "authorization", "password", "token", "credential"):
            self.assertNotIn(forbidden, lowered)
        self.assertIn("catalog label", lowered)

    def test_needle_is_inserted_exactly_once_at_the_requested_depth(self) -> None:
        for depth in NEEDLE_DEPTHS:
            with self.subTest(depth=depth):
                case = build_needle_case(120000, depth, 20260828)
                self.assertEqual(case.prompt.count(case.label), 1)
                lines = case.prompt.splitlines()
                located = [
                    index for index, line in enumerate(lines) if case.label in line
                ]
                self.assertEqual(located, [case.needle_line_index])
                observed_depth = 100.0 * case.needle_line_index / case.line_count
                self.assertAlmostEqual(observed_depth, float(depth), delta=1.0)

    def test_filler_lines_are_all_distinct_and_varied(self) -> None:
        case = build_needle_case(6000, 50, 3)
        filler = [
            line
            for index, line in enumerate(case.prompt.splitlines())
            if index != case.needle_line_index and line.startswith("Line ")
        ]
        self.assertGreater(len(filler), 100)
        self.assertEqual(len(set(filler)), len(filler))
        prefixes = {line[:96] for line in filler}
        self.assertGreater(len(prefixes), len(filler) // 2)

    def test_line_count_follows_the_calibrated_tokens_per_line(self) -> None:
        dense = build_needle_case(120000, 50, 1, tokens_per_line=30.0)
        sparse = build_needle_case(120000, 50, 1, tokens_per_line=60.0)
        self.assertEqual(dense.line_count, 4000)
        self.assertEqual(sparse.line_count, 2000)
        self.assertEqual(dense.tokens_per_line, 30.0)

    def test_invalid_needle_arguments_are_rejected(self) -> None:
        with self.assertRaises(ValueError):
            build_needle_case(120000, 101, 1)
        with self.assertRaises(ValueError):
            build_needle_case(0, 50, 1)
        with self.assertRaises(ValueError):
            build_needle_case(120000, 50, 1, tokens_per_line=0.0)

    def test_calibration_filler_is_never_a_prefix_of_a_needle_haystack(self) -> None:
        # The proven root cause of the earlier retrieval ceiling was a shared
        # prefix between a needle-free calibration request and the real probe.
        calibration = calibration_prompt()
        case = build_needle_case(120000, 10, 20260828)
        self.assertFalse(case.prompt.startswith(calibration[:512]))
        self.assertGreater(CALIBRATION_LINE_OFFSET, 0)

    def test_calibration_uses_one_bounded_request(self) -> None:
        client, opener = json_client([load_fixture("chat.needle-calibration.ok.json")])
        tokens_per_line = calibrate_tokens_per_line(client, MODEL)
        self.assertEqual(len(opener.requests), 1)
        self.assertEqual(opener.requests[0]["body"]["max_tokens"], 1)
        self.assertEqual(opener.requests[0]["body"]["temperature"], 0.0)
        self.assertAlmostEqual(tokens_per_line, 44.0)

    def test_calibration_rejects_an_implausible_measurement(self) -> None:
        payload = load_fixture("chat.needle-calibration.ok.json")
        payload["usage"]["prompt_tokens"] = 3
        client, _opener = json_client([payload])
        with self.assertRaises(MalformedResponse):
            calibrate_tokens_per_line(client, MODEL)

    def needle_reply(self, label: str, prompt_tokens: int = 120121) -> dict:
        payload = load_fixture("chat.needle.ok.json")
        message = payload["choices"][0]["message"]
        message["content"] = message["content"].format(label=label)
        message["reasoning_content"] = message["reasoning_content"].format(label=label)
        payload["usage"]["prompt_tokens"] = prompt_tokens
        return payload

    def test_suite_calibrates_once_and_probes_every_depth(self) -> None:
        cases = [build_needle_case(120000, depth, 20260828) for depth in NEEDLE_DEPTHS]
        bodies = [load_fixture("chat.needle-calibration.ok.json")]
        bodies.extend(self.needle_reply(case.label) for case in cases)
        client, opener = json_client(bodies)
        results, records = run_needle_suite(client, MODEL, seed=20260828)
        self.assertEqual(len(opener.requests), 1 + len(NEEDLE_DEPTHS))
        self.assertEqual(len(results), len(NEEDLE_DEPTHS))
        self.assertTrue(all(result.passed for result in results))
        self.assertEqual([record["depth_percent"] for record in records], [10, 50, 90])
        for record in records:
            self.assertEqual(record["prompt_tokens"], 120121)
            self.assertTrue(record["prompt_tokens_within_tolerance"])
            self.assertEqual(record["target_tokens"], 120000)

    def test_a_missed_needle_is_a_correctness_failure(self) -> None:
        bodies = [
            load_fixture("chat.needle-calibration.ok.json"),
            self.needle_reply(build_needle_case(120000, 10, 5).label),
            load_fixture("chat.needle.miss.json"),
            self.needle_reply(build_needle_case(120000, 90, 5).label),
        ]
        client, _opener = json_client(bodies)
        results, _records = run_needle_suite(client, MODEL, seed=5)
        self.assertEqual(
            [result.failure_class for result in results],
            [None, "needle-mismatch", None],
        )
        self.assertEqual(failure_kind("needle-mismatch"), "correctness")

    def test_prompt_token_drift_is_recorded_as_an_out_of_tolerance_probe(self) -> None:
        cases = [build_needle_case(120000, depth, 11) for depth in NEEDLE_DEPTHS]
        bodies = [load_fixture("chat.needle-calibration.ok.json")]
        bodies.extend(
            self.needle_reply(case.label, prompt_tokens=71000) for case in cases
        )
        client, _opener = json_client(bodies)
        results, records = run_needle_suite(client, MODEL, seed=11)
        self.assertFalse(any(record["prompt_tokens_within_tolerance"] for record in records))
        self.assertEqual(
            [result.failure_class for result in results],
            ["prompt-size-mismatch"] * len(NEEDLE_DEPTHS),
        )
        self.assertEqual(failure_kind("prompt-size-mismatch"), "correctness")

    def test_needle_records_never_carry_prompt_or_reply_text(self) -> None:
        cases = [build_needle_case(120000, depth, 20260828) for depth in NEEDLE_DEPTHS]
        bodies = [load_fixture("chat.needle-calibration.ok.json")]
        bodies.extend(self.needle_reply(case.label) for case in cases)
        client, _opener = json_client(bodies)
        _results, records = run_needle_suite(client, MODEL, seed=20260828)
        encoded = json.dumps(records)
        self.assertNotIn("Line 000", encoded)
        self.assertNotIn("Scanning the catalog", encoded)
        self.assertNotIn("botanical", encoded)


class SanitationTests(unittest.TestCase):
    def build_payload(self) -> dict:
        client, _opener = json_client(
            [
                load_fixture("model-info.ok.json"),
                load_fixture("models.ok.json"),
                load_fixture("chat.smoke.ok.json"),
            ]
        )
        identity = verify_identity(client, MODEL_PATH, MODEL)
        results = [
            evaluate_case(case, client.chat(dict(case.request)))
            for case in build_smoke_cases(MODEL)
        ]
        return sanitized_suite_payload(
            suite="smoke",
            identity=identity,
            results=results,
            records=[],
            request_configuration={
                "temperature": 0.0,
                "max_tokens": 4096,
                "seed": 20260828,
            },
        )

    def test_payload_keeps_safe_request_configuration(self) -> None:
        payload = self.build_payload()
        self.assertEqual(payload["suite"], "smoke")
        self.assertEqual(payload["request_configuration"]["temperature"], 0.0)
        self.assertEqual(payload["request_configuration"]["seed"], 20260828)
        self.assertEqual(payload["served_model_name"], MODEL)
        self.assertEqual(payload["outcome"], "passed")
        self.assertEqual(payload["cases"][0]["name"], "smoke")

    def test_payload_omits_endpoint_inventory_and_response_bodies(self) -> None:
        encoded = json.dumps(self.build_payload())
        for forbidden in (
            "198.51.100.10",
            "8002",
            "/srv/hf-cache",
            "Authorization",
            "Bearer",
            "READY",
            "operator asked",
            "Reply with",
        ):
            self.assertNotIn(forbidden, encoded)

    def test_payload_reports_the_worst_failure_kind(self) -> None:
        client, _opener = json_client(
            [
                load_fixture("model-info.ok.json"),
                load_fixture("models.ok.json"),
            ]
        )
        identity = verify_identity(client, MODEL_PATH, MODEL)
        wrong = evaluate_case(
            build_correctness_cases(MODEL)[0],
            load_fixture("chat.arithmetic.wrong.json"),
        )
        broken = evaluate_case(build_correctness_cases(MODEL)[0], {"choices": []})
        correctness_only = sanitized_suite_payload(
            suite="correctness",
            identity=identity,
            results=[wrong],
            records=[],
            request_configuration={},
        )
        self.assertEqual(correctness_only["outcome"], "failed-correctness")
        mixed = sanitized_suite_payload(
            suite="correctness",
            identity=identity,
            results=[wrong, broken],
            records=[],
            request_configuration={},
        )
        self.assertEqual(mixed["outcome"], "failed-infrastructure")


class ValidationIdentifierTests(unittest.TestCase):
    def test_new_identifier_matches_the_run_identity_format(self) -> None:
        identifier = new_validation_id()
        self.assertRegex(
            identifier,
            r"\A[0-9]{8}T[0-9]{6}\.[0-9]{6}Z-[0-9a-f]{32}\Z",
        )
        self.assertEqual(validate_validation_id(identifier), identifier)

    def test_successive_identifiers_do_not_collide(self) -> None:
        identifiers = {new_validation_id() for _ in range(16)}
        self.assertEqual(len(identifiers), 16)

    def test_unsafe_identifiers_are_rejected(self) -> None:
        for unsafe in (
            "../escape",
            "20260828T120000.000000Z-short",
            "20260828T120000.000000Z-00112233445566778899AABBCCDDEEFF",
            "",
            "20260828T120000.000000Z-00112233445566778899aabbccddeeff/x",
        ):
            with self.subTest(unsafe=unsafe):
                with self.assertRaises(ValueError):
                    validate_validation_id(unsafe)


class ToolExpectationTests(unittest.TestCase):
    def test_expectation_requires_a_function_name(self) -> None:
        with self.assertRaises(ValueError):
            ToolExpectation(name="", required_arguments=(("a", "b"),))

    def test_case_rejects_an_expectation_free_definition(self) -> None:
        with self.assertRaises(ValueError):
            ValidationCase(
                name="empty",
                suite="smoke",
                request={"model": MODEL, "messages": []},
            )

    def test_needle_label_pattern_is_anchored(self) -> None:
        compiled = re.compile(NEEDLE_LABEL_PATTERN)
        self.assertIsNone(compiled.search("prefix COPPER-IBIS-7000-ZX suffix"))
        self.assertIsNotNone(compiled.search("COPPER-IBIS-7000-ZX"))


class RemoteBootstrapTests(unittest.TestCase):
    """The nodes hold no copy of these tools, so the shipped program must run."""

    def test_bootstrap_makes_a_dotted_preload_importable(self) -> None:
        for name in ("pkg", "pkg.leaf"):
            self.addCleanup(sys.modules.pop, name, None)
        bootstrap = build_bootstrap(
            preloaded=[("pkg.leaf", b"VALUE = 41\n")],
            # The entry module runs as __main__ in its own namespace, exactly as
            # it does on a node, so it reports back through the preloaded module.
            entry_source=b"import pkg.leaf\npkg.leaf.RESULT = pkg.leaf.VALUE + 1\n",
        )
        exec(compile(bootstrap, "<bootstrap>", "exec"), {})
        self.assertEqual(sys.modules["pkg.leaf"].RESULT, 42)

    def test_benchmark_mode_ships_both_modules_as_one_program(self) -> None:
        command = build_remote_command(
            "benchmark",
            ["--base-url", BASE_URL, "--timeout-seconds", "60"],
        )
        self.assertIn("--mode benchmark", command)
        self.assertNotIn("\n", command)
        # A bootstrap that cannot compile would only fail on a live node.
        bootstrap = command.split("python3 -c ", 1)[1]
        source = shlex.split(bootstrap)[0]
        compile(source, "<bootstrap>", "exec")
        self.assertIn("tools.api_validation", source)

    def test_bootstrap_rejects_an_unsafe_module_name(self) -> None:
        for unsafe in ("tools.api validation", "tools/api", "", "tools."):
            with self.subTest(unsafe=unsafe):
                with self.assertRaises(ValueError):
                    build_bootstrap([(unsafe, b"")], b"")

    def test_remote_command_rejects_an_unknown_mode(self) -> None:
        with self.assertRaises(ValueError):
            build_remote_command("teardown", [])


if __name__ == "__main__":
    unittest.main()
