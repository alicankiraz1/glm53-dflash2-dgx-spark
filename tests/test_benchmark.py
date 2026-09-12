"""Throughput and latency tests for the read-only benchmark module.

Timings come from recorded fixtures and a local fake client, so the arithmetic
is exact and no test contacts a served endpoint.
"""

import json
import pathlib
import threading
import unittest

from tools.api_validation import HTTPFailure, StreamedChat, TimeoutFailure
from tools.benchmark import (
    CONCURRENCY_VALUES,
    BenchmarkRequest,
    RequestMeasurement,
    build_benchmark_requests,
    percentile,
    read_spec_metrics,
    run_benchmark,
    sanitized_benchmark_payload,
    summarize_measurements,
)


ROOT = pathlib.Path(__file__).resolve().parents[1]
BENCHMARK_FIXTURES = ROOT / "tests" / "fixtures" / "benchmark"
API_FIXTURES = ROOT / "tests" / "fixtures" / "api"
MODEL = "glm-5.3-flash-nvfp4"


def load_samples(name: str) -> dict:
    return json.loads((BENCHMARK_FIXTURES / name).read_text(encoding="utf-8"))


def measurements_from(samples: dict) -> list[RequestMeasurement]:
    measurements = []
    for wave in samples["waves"]:
        for request in wave["requests"]:
            measurements.append(
                RequestMeasurement(
                    name=request["name"],
                    wave=wave["wave"],
                    started_seconds=request["started_seconds"],
                    first_token_seconds=(
                        request["started_seconds"] + request["ttft_seconds"]
                    ),
                    completed_seconds=request["completed_seconds"],
                    prompt_tokens=request["prompt_tokens"],
                    completion_tokens=request["completion_tokens"],
                    failure_class=None,
                )
            )
    return measurements


def summarize_samples(name: str):
    samples = load_samples(name)
    return summarize_measurements(
        concurrency=samples["concurrency"],
        measurements=measurements_from(samples),
        expected_completion_tokens=samples["expected_completion_tokens"],
    )


class PercentileTests(unittest.TestCase):
    def test_nearest_rank_selection_is_used(self) -> None:
        self.assertEqual(percentile([4.0, 1.0, 3.0, 2.0], 0.5), 2.0)
        self.assertEqual(percentile([4.0, 1.0, 3.0, 2.0], 0.95), 4.0)
        self.assertEqual(percentile([1.0, 2.0, 3.0], 0.5), 2.0)
        self.assertEqual(percentile([1.0, 2.0, 3.0], 0.95), 3.0)
        self.assertEqual(percentile([7.5], 0.5), 7.5)
        self.assertEqual(percentile([7.5], 0.95), 7.5)

    def test_empty_and_out_of_range_inputs_are_rejected(self) -> None:
        with self.assertRaises(ValueError):
            percentile([], 0.5)
        with self.assertRaises(ValueError):
            percentile([1.0], 0.0)
        with self.assertRaises(ValueError):
            percentile([1.0], 1.5)


class ConcurrencyOneSummaryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.result = summarize_samples("c1-samples.json")

    def test_request_accounting_is_exact(self) -> None:
        self.assertEqual(self.result.concurrency, 1)
        self.assertEqual(self.result.request_count, 3)
        self.assertEqual(self.result.succeeded, 3)
        self.assertEqual(self.result.failed, 0)
        self.assertEqual(self.result.completion_tokens_total, 3072)
        self.assertTrue(self.result.completion_tokens_exact)
        self.assertEqual(self.result.failures, ())

    def test_wall_clock_sums_only_synchronized_wave_spans(self) -> None:
        self.assertAlmostEqual(self.result.wall_clock_seconds, 96.0)
        self.assertEqual(
            [round(wave.wall_clock_seconds, 6) for wave in self.result.waves],
            [31.0, 32.0, 33.0],
        )

    def test_aggregate_throughput_uses_measured_totals(self) -> None:
        self.assertAlmostEqual(
            self.result.aggregate_end_to_end_tokens_per_second,
            32.0,
        )
        self.assertAlmostEqual(
            self.result.aggregate_decode_tokens_per_second,
            3069.0 / 94.5,
        )

    def test_latency_ttft_and_tpot_percentiles(self) -> None:
        self.assertAlmostEqual(self.result.latency_p50_seconds, 32.0)
        self.assertAlmostEqual(self.result.latency_p95_seconds, 33.0)
        self.assertAlmostEqual(self.result.ttft_p50_seconds, 0.5)
        self.assertAlmostEqual(self.result.ttft_p95_seconds, 0.75)
        self.assertAlmostEqual(self.result.tpot_p50_seconds, 31.5 / 1023.0)
        self.assertAlmostEqual(self.result.tpot_p95_seconds, 32.25 / 1023.0)

    def test_per_stream_decode_percentiles(self) -> None:
        self.assertAlmostEqual(
            self.result.per_stream_decode_p50_tokens_per_second,
            1023.0 / 31.5,
        )
        self.assertAlmostEqual(
            self.result.per_stream_decode_p95_tokens_per_second,
            1023.0 / 30.75,
        )


class ConcurrencyFourSummaryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.result = summarize_samples("c4-samples.json")

    def test_request_accounting_is_exact(self) -> None:
        self.assertEqual(self.result.concurrency, 4)
        self.assertEqual(self.result.request_count, 8)
        self.assertEqual(self.result.succeeded, 8)
        self.assertEqual(self.result.completion_tokens_total, 8192)
        self.assertTrue(self.result.completion_tokens_exact)

    def test_wave_spans_reflect_synchronized_starts(self) -> None:
        self.assertAlmostEqual(self.result.wall_clock_seconds, 128.0)
        self.assertEqual(
            [round(wave.wall_clock_seconds, 6) for wave in self.result.waves],
            [64.0, 64.0],
        )
        self.assertEqual([wave.request_count for wave in self.result.waves], [4, 4])

    def test_aggregate_throughput_scales_above_single_stream(self) -> None:
        self.assertAlmostEqual(
            self.result.aggregate_end_to_end_tokens_per_second,
            64.0,
        )
        self.assertAlmostEqual(
            self.result.aggregate_decode_tokens_per_second,
            8184.0 / 127.0,
        )
        self.assertGreater(
            self.result.aggregate_decode_tokens_per_second,
            self.result.per_stream_decode_p50_tokens_per_second,
        )

    def test_latency_ttft_and_decode_percentiles(self) -> None:
        self.assertAlmostEqual(self.result.latency_p50_seconds, 62.0)
        self.assertAlmostEqual(self.result.latency_p95_seconds, 64.0)
        self.assertAlmostEqual(self.result.ttft_p50_seconds, 0.55)
        self.assertAlmostEqual(self.result.ttft_p95_seconds, 0.75)
        self.assertAlmostEqual(
            self.result.per_stream_decode_p50_tokens_per_second,
            1023.0 / 62.35,
        )
        self.assertAlmostEqual(
            self.result.per_stream_decode_p95_tokens_per_second,
            1023.0 / 60.25,
        )
        self.assertAlmostEqual(self.result.tpot_p50_seconds, 61.6 / 1023.0)
        self.assertAlmostEqual(self.result.tpot_p95_seconds, 63.5 / 1023.0)


class SummaryEdgeCaseTests(unittest.TestCase):
    def base_measurement(self, name: str, **overrides) -> RequestMeasurement:
        fields = {
            "name": name,
            "wave": 0,
            "started_seconds": 10.0,
            "first_token_seconds": 10.5,
            "completed_seconds": 20.5,
            "prompt_tokens": 64,
            "completion_tokens": 1024,
            "failure_class": None,
        }
        fields.update(overrides)
        return RequestMeasurement(**fields)

    def test_inexact_completion_tokens_are_reported(self) -> None:
        result = summarize_measurements(
            concurrency=1,
            measurements=[self.base_measurement("r0", completion_tokens=1000)],
            expected_completion_tokens=1024,
        )
        self.assertFalse(result.completion_tokens_exact)

    def test_partial_failure_is_excluded_from_metrics_but_reported(self) -> None:
        result = summarize_measurements(
            concurrency=4,
            measurements=[
                self.base_measurement("r0"),
                self.base_measurement("r1"),
                self.base_measurement("r2"),
                self.base_measurement(
                    "r3",
                    first_token_seconds=None,
                    completed_seconds=15.0,
                    completion_tokens=0,
                    failure_class="timeout",
                ),
            ],
            expected_completion_tokens=1024,
        )
        self.assertEqual(result.succeeded, 3)
        self.assertEqual(result.failed, 1)
        self.assertEqual(result.completion_tokens_total, 3072)
        self.assertEqual(result.failures, (("r3", "timeout"),))

    def test_a_wave_of_only_failures_never_fabricates_throughput(self) -> None:
        result = summarize_measurements(
            concurrency=1,
            measurements=[
                self.base_measurement(
                    "r0",
                    first_token_seconds=None,
                    completion_tokens=0,
                    failure_class="transport",
                )
            ],
            expected_completion_tokens=1024,
        )
        self.assertEqual(result.succeeded, 0)
        self.assertIsNone(result.aggregate_end_to_end_tokens_per_second)
        self.assertIsNone(result.aggregate_decode_tokens_per_second)
        self.assertIsNone(result.latency_p50_seconds)
        self.assertIsNone(result.ttft_p50_seconds)
        self.assertIsNone(result.tpot_p50_seconds)

    def test_unstreamed_requests_report_latency_without_inventing_ttft(self) -> None:
        result = summarize_measurements(
            concurrency=1,
            measurements=[self.base_measurement("r0", first_token_seconds=None)],
            expected_completion_tokens=1024,
        )
        self.assertAlmostEqual(result.latency_p50_seconds, 10.5)
        self.assertIsNone(result.ttft_p50_seconds)
        self.assertIsNone(result.tpot_p50_seconds)
        self.assertIsNone(result.per_stream_decode_p50_tokens_per_second)
        self.assertIsNone(result.aggregate_decode_tokens_per_second)

    def test_single_completion_token_cannot_produce_a_time_per_output_token(self) -> None:
        result = summarize_measurements(
            concurrency=1,
            measurements=[self.base_measurement("r0", completion_tokens=1)],
            expected_completion_tokens=1,
        )
        self.assertIsNone(result.tpot_p50_seconds)
        self.assertIsNone(result.per_stream_decode_p50_tokens_per_second)

    def test_summary_rejects_an_unsupported_concurrency(self) -> None:
        for concurrency in (0, 2, 3, 5, -1):
            with self.subTest(concurrency=concurrency):
                with self.assertRaises(ValueError):
                    summarize_measurements(
                        concurrency=concurrency,
                        measurements=[self.base_measurement("r0")],
                        expected_completion_tokens=1024,
                    )

    def test_summary_rejects_non_monotonic_timings(self) -> None:
        with self.assertRaises(ValueError):
            summarize_measurements(
                concurrency=1,
                measurements=[
                    self.base_measurement("r0", completed_seconds=9.0),
                ],
                expected_completion_tokens=1024,
            )
        with self.assertRaises(ValueError):
            summarize_measurements(
                concurrency=1,
                measurements=[
                    self.base_measurement("r0", first_token_seconds=21.0),
                ],
                expected_completion_tokens=1024,
            )

    def test_summary_rejects_an_uneven_wave(self) -> None:
        with self.assertRaises(ValueError):
            summarize_measurements(
                concurrency=4,
                measurements=[self.base_measurement("r0")],
                expected_completion_tokens=1024,
            )


class RequestBuilderTests(unittest.TestCase):
    def test_requests_preserve_the_declared_configuration(self) -> None:
        requests = build_benchmark_requests(MODEL, count=4, output_tokens=1024)
        self.assertEqual(len(requests), 4)
        for request in requests:
            self.assertEqual(request.expected_completion_tokens, 1024)
            payload = request.payload
            self.assertEqual(payload["model"], MODEL)
            self.assertEqual(payload["temperature"], 0.0)
            self.assertEqual(payload["max_tokens"], 1024)
            self.assertEqual(payload["min_tokens"], 1024)
            self.assertTrue(payload["ignore_eos"])
            self.assertTrue(payload["stream"])
            self.assertTrue(payload["stream_options"]["include_usage"])

    def test_prompts_are_distinct_so_no_request_reuses_another_prefix(self) -> None:
        requests = build_benchmark_requests(MODEL, count=8, output_tokens=128)
        prompts = {request.payload["messages"][0]["content"] for request in requests}
        self.assertEqual(len(prompts), 8)
        names = [request.name for request in requests]
        self.assertEqual(len(set(names)), 8)

    def test_invalid_builder_arguments_are_rejected(self) -> None:
        with self.assertRaises(ValueError):
            build_benchmark_requests(MODEL, count=0, output_tokens=128)
        with self.assertRaises(ValueError):
            build_benchmark_requests(MODEL, count=4, output_tokens=0)
        with self.assertRaises(ValueError):
            build_benchmark_requests("", count=4, output_tokens=128)


class FakeStreamClient:
    """Serves recorded timings and proves requests really ran concurrently.

    The internal barrier is the assertion: it only releases once the expected
    number of requests is simultaneously in flight, so a sequential scheduler
    breaks the barrier instead of quietly reporting optimistic numbers.
    """

    def __init__(
        self,
        timings: dict,
        expected_parallel: int,
        failures: dict | None = None,
    ) -> None:
        self.timings = timings
        self.failures = failures or {}
        self.barrier = threading.Barrier(expected_parallel, timeout=10.0)
        self.lock = threading.Lock()
        self.entered: list[str] = []
        self.exited: list[str] = []

    def stream_chat(self, request: dict) -> StreamedChat:
        name = request["messages"][0]["content"]
        with self.lock:
            self.entered.append(name)
        if not name.startswith("warmup"):
            self.barrier.wait()
        with self.lock:
            self.exited.append(name)
        if name in self.failures:
            raise self.failures[name]
        timing = self.timings[name]
        return StreamedChat(
            started_seconds=timing["started_seconds"],
            first_token_seconds=(
                timing["started_seconds"] + timing["ttft_seconds"]
            ),
            completed_seconds=timing["completed_seconds"],
            prompt_tokens=timing["prompt_tokens"],
            completion_tokens=timing["completion_tokens"],
            content_characters=4096,
            reasoning_characters=512,
            finish_reason="length",
            chunk_count=timing["completion_tokens"],
        )


def requests_from(samples: dict) -> tuple[list[BenchmarkRequest], dict]:
    requests = []
    timings = {}
    for wave in samples["waves"]:
        for record in wave["requests"]:
            timings[record["name"]] = record
            requests.append(
                BenchmarkRequest(
                    name=record["name"],
                    payload={
                        "model": samples["model"],
                        "messages": [{"role": "user", "content": record["name"]}],
                        "max_tokens": samples["expected_completion_tokens"],
                        "min_tokens": samples["expected_completion_tokens"],
                        "temperature": 0.0,
                        "ignore_eos": True,
                        "stream": True,
                        "stream_options": {"include_usage": True},
                    },
                    expected_completion_tokens=samples[
                        "expected_completion_tokens"
                    ],
                )
            )
    return requests, timings


class SchedulingTests(unittest.TestCase):
    def test_concurrency_one_runs_one_request_at_a_time(self) -> None:
        samples = load_samples("c1-samples.json")
        requests, timings = requests_from(samples)
        client = FakeStreamClient(timings, expected_parallel=1)
        result = run_benchmark(client, requests, 1)
        self.assertEqual(result.concurrency, 1)
        self.assertEqual(result.succeeded, 3)
        self.assertAlmostEqual(result.aggregate_end_to_end_tokens_per_second, 32.0)
        self.assertEqual(client.entered, [request.name for request in requests])

    def test_concurrency_four_releases_every_request_together(self) -> None:
        samples = load_samples("c4-samples.json")
        requests, timings = requests_from(samples)
        client = FakeStreamClient(timings, expected_parallel=4)
        result = run_benchmark(client, requests, 4)
        self.assertEqual(result.succeeded, 8)
        self.assertEqual([wave.request_count for wave in result.waves], [4, 4])
        self.assertAlmostEqual(result.aggregate_end_to_end_tokens_per_second, 64.0)

    def test_a_later_wave_never_starts_before_the_previous_one_finishes(self) -> None:
        samples = load_samples("c4-samples.json")
        requests, timings = requests_from(samples)
        client = FakeStreamClient(timings, expected_parallel=4)
        run_benchmark(client, requests, 4)
        first_wave = {record["name"] for record in samples["waves"][0]["requests"]}
        second_wave = {record["name"] for record in samples["waves"][1]["requests"]}
        first_wave_exit = max(
            index for index, name in enumerate(client.exited) if name in first_wave
        )
        second_wave_entry = min(
            index for index, name in enumerate(client.entered) if name in second_wave
        )
        self.assertEqual(len(client.exited), 8)
        self.assertGreaterEqual(len(client.entered), 8)
        self.assertLess(first_wave_exit, len(client.exited))
        self.assertGreaterEqual(second_wave_entry, 4)

    def test_warmup_is_issued_and_excluded_from_every_metric(self) -> None:
        samples = load_samples("c1-samples.json")
        requests, timings = requests_from(samples)
        timings["warmup-0"] = {
            "started_seconds": 1.0,
            "ttft_seconds": 0.1,
            "completed_seconds": 6.0,
            "prompt_tokens": 64,
            "completion_tokens": 128,
        }
        warmup = BenchmarkRequest(
            name="warmup-0",
            payload={
                "model": MODEL,
                "messages": [{"role": "user", "content": "warmup-0"}],
                "max_tokens": 128,
                "min_tokens": 128,
                "temperature": 0.0,
                "ignore_eos": True,
                "stream": True,
                "stream_options": {"include_usage": True},
            },
            expected_completion_tokens=128,
        )
        client = FakeStreamClient(timings, expected_parallel=1)
        result = run_benchmark(client, requests, 1, warmup=warmup)
        self.assertEqual(client.entered[0], "warmup-0")
        self.assertEqual(result.request_count, 3)
        self.assertEqual(result.completion_tokens_total, 3072)
        self.assertNotIn(
            "warmup-0",
            [measurement.name for measurement in result.measurements],
        )
        self.assertAlmostEqual(result.wall_clock_seconds, 96.0)

    def test_only_concurrency_one_and_four_are_accepted(self) -> None:
        samples = load_samples("c1-samples.json")
        requests, timings = requests_from(samples)
        self.assertEqual(CONCURRENCY_VALUES, (1, 4))
        for concurrency in (0, 2, 3, 5, 8, -1):
            with self.subTest(concurrency=concurrency):
                client = FakeStreamClient(timings, expected_parallel=1)
                with self.assertRaises(ValueError):
                    run_benchmark(client, requests, concurrency)
                self.assertEqual(client.entered, [])

    def test_request_count_must_fill_whole_waves(self) -> None:
        samples = load_samples("c4-samples.json")
        requests, timings = requests_from(samples)
        client = FakeStreamClient(timings, expected_parallel=4)
        with self.assertRaises(ValueError):
            run_benchmark(client, requests[:6], 4)
        with self.assertRaises(ValueError):
            run_benchmark(client, [], 4)

    def test_one_failing_request_does_not_abort_the_wave(self) -> None:
        samples = load_samples("c4-samples.json")
        requests, timings = requests_from(samples)
        failing = samples["waves"][0]["requests"][2]["name"]
        client = FakeStreamClient(
            timings,
            expected_parallel=4,
            failures={failing: TimeoutFailure("the request exceeded its budget")},
        )
        result = run_benchmark(client, requests, 4)
        self.assertEqual(result.failed, 1)
        self.assertEqual(result.succeeded, 7)
        self.assertEqual(result.failures, ((failing, "timeout"),))
        self.assertEqual(result.completion_tokens_total, 7 * 1024)

    def test_an_infrastructure_failure_is_recorded_with_its_class(self) -> None:
        samples = load_samples("c1-samples.json")
        requests, timings = requests_from(samples)
        failing = samples["waves"][1]["requests"][0]["name"]
        client = FakeStreamClient(
            timings,
            expected_parallel=1,
            failures={failing: HTTPFailure("upstream refused", status_code=503)},
        )
        result = run_benchmark(client, requests, 1)
        self.assertEqual(result.failures, ((failing, "http-status"),))
        self.assertEqual(result.failed, 1)


class SpeculativeMetricTests(unittest.TestCase):
    class MetricsClient:
        def __init__(self, payload) -> None:
            self.payload = payload

        def get_text(self, path: str) -> str:
            if isinstance(self.payload, BaseException):
                raise self.payload
            assert path == "metrics"
            return self.payload

    def test_prometheus_gauges_are_read_exactly(self) -> None:
        payload = (API_FIXTURES / "metrics.ok.txt").read_text(encoding="utf-8")
        metrics = read_spec_metrics(self.MetricsClient(payload))
        self.assertAlmostEqual(metrics.accept_length, 2.3767123287671232)
        self.assertAlmostEqual(metrics.accept_rate, 0.19667318982387474)

    def test_absent_gauges_are_reported_as_unavailable(self) -> None:
        metrics = read_spec_metrics(
            self.MetricsClient("# HELP other gauge\nother 1.0\n")
        )
        self.assertIsNone(metrics.accept_length)
        self.assertIsNone(metrics.accept_rate)

    def test_unparsable_gauge_values_are_never_guessed(self) -> None:
        metrics = read_spec_metrics(
            self.MetricsClient('sglang:spec_accept_length{a="b"} not-a-number\n')
        )
        self.assertIsNone(metrics.accept_length)

    def test_an_unavailable_metrics_endpoint_does_not_fail_the_benchmark(self) -> None:
        metrics = read_spec_metrics(
            self.MetricsClient(HTTPFailure("no metrics route", status_code=404))
        )
        self.assertIsNone(metrics.accept_length)
        self.assertIsNone(metrics.accept_rate)
        self.assertFalse(metrics.available)


class BenchmarkSanitationTests(unittest.TestCase):
    def payload(self) -> dict:
        return sanitized_benchmark_payload(
            results=[
                summarize_samples("c1-samples.json"),
                summarize_samples("c4-samples.json"),
            ],
            request_configuration={
                "output_tokens_per_request": 1024,
                "warmup_output_tokens": 128,
                "temperature": 0.0,
                "ignore_eos": True,
                "rounds": 3,
                "seed": 20260828,
            },
            served_model_name=MODEL,
        )

    def test_payload_reports_both_required_concurrency_levels(self) -> None:
        payload = self.payload()
        self.assertEqual(sorted(payload["concurrency"]), ["c1", "c4"])
        self.assertAlmostEqual(
            payload["concurrency"]["c1"]["aggregate_end_to_end_tokens_per_second"],
            32.0,
        )
        self.assertAlmostEqual(
            payload["concurrency"]["c4"]["aggregate_end_to_end_tokens_per_second"],
            64.0,
        )
        self.assertEqual(payload["outcome"], "passed")

    def test_payload_preserves_safe_request_configuration(self) -> None:
        payload = self.payload()
        self.assertEqual(payload["request_configuration"]["rounds"], 3)
        self.assertEqual(
            payload["request_configuration"]["output_tokens_per_request"],
            1024,
        )
        self.assertEqual(payload["served_model_name"], MODEL)

    def test_payload_carries_no_prompts_endpoints_or_credentials(self) -> None:
        encoded = json.dumps(self.payload())
        for forbidden in (
            "messages",
            "content",
            "Authorization",
            "Bearer",
            "http://",
            "c1-w0-r0",
        ):
            self.assertNotIn(forbidden, encoded)

    def test_payload_marks_a_partial_failure_as_a_failed_benchmark(self) -> None:
        degraded = summarize_measurements(
            concurrency=1,
            measurements=[
                RequestMeasurement(
                    name="r0",
                    wave=0,
                    started_seconds=1.0,
                    first_token_seconds=None,
                    completed_seconds=2.0,
                    prompt_tokens=64,
                    completion_tokens=0,
                    failure_class="transport",
                )
            ],
            expected_completion_tokens=1024,
        )
        payload = sanitized_benchmark_payload(
            results=[degraded],
            request_configuration={},
            served_model_name=MODEL,
        )
        self.assertEqual(payload["outcome"], "failed-infrastructure")
        self.assertEqual(
            payload["concurrency"]["c1"]["failure_classes"],
            ["transport"],
        )


if __name__ == "__main__":
    unittest.main()
