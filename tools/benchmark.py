#!/usr/bin/env python3

"""Read-only throughput and latency benchmark for one recorded run.

The benchmark measures exactly two concurrency levels, 1 and 4, because the
validated profile admits four request slots and no other shape is reproducible
against it. Every wave releases its requests together, so a concurrency-4
number really describes four simultaneous streams instead of four requests that
happened to overlap.

Three rules keep the reported numbers honest:

* Warmup never enters a metric. The first request after a cold start pays for
  graph capture and allocator growth that no steady-state number should carry.
* Timings come from a monotonic clock taken inside the client, and a wave's wall
  clock is measured from the earliest start to the latest completion rather than
  by summing per-request durations.
* Anything the deployment did not report stays absent. A missing usage total, an
  unsupported stream, or an unavailable speculative gauge is published as null,
  never as an estimate.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import dataclasses
import math
import re
import sys
import threading
from collections.abc import Mapping, Sequence
from typing import Any

from tools.api_validation import (
    CORRECTNESS_FAILURE_CLASSES,
    INFRASTRUCTURE_FAILURE_CLASSES,
    METRICS_PATH,
    SCHEMA_VERSION,
    InfrastructureError,
    OpenAIClient,
    StreamedChat,
    ValidationError,
    canonical_json,
    verify_identity,
)


CONCURRENCY_VALUES = (1, 4)
DEFAULT_OUTPUT_TOKENS = 1024
DEFAULT_WARMUP_TOKENS = 128
DEFAULT_ROUNDS = 3
MAXIMUM_ROUNDS = 32
BARRIER_TIMEOUT_SECONDS = 900.0

SPEC_ACCEPT_LENGTH_METRIC = "sglang:spec_accept_length"
SPEC_ACCEPT_RATE_METRIC = "sglang:spec_accept_rate"
METRIC_LINE_PATTERN = re.compile(
    r"\A(?P<name>[A-Za-z_:][A-Za-z0-9_:]*)(?P<labels>\{[^}]*\})?\s+(?P<value>\S+)\s*\Z"
)

# A continuous technical essay keeps the decode phase saturated without asking
# the deployment to reason about a puzzle, so the measurement describes serving
# throughput rather than prompt difficulty.
BENCHMARK_PROMPT_TEMPLATE = (
    "Write a continuous technical essay, numbered section {index}, about "
    "operating reliable distributed inference: bounded queues, explicit "
    "timeouts, backpressure, evidence retention, and failure isolation. Keep "
    "writing prose without lists or headings."
)


@dataclasses.dataclass(frozen=True)
class BenchmarkRequest:
    name: str
    payload: Mapping[str, Any]
    expected_completion_tokens: int

    def __post_init__(self) -> None:
        if not isinstance(self.name, str) or not self.name:
            raise ValueError("a benchmark request must be named")
        if not isinstance(self.payload, Mapping):
            raise ValueError("a benchmark request must carry a payload mapping")
        if (
            not isinstance(self.expected_completion_tokens, int)
            or self.expected_completion_tokens <= 0
        ):
            raise ValueError("a benchmark request must expect a positive token count")


@dataclasses.dataclass(frozen=True)
class RequestMeasurement:
    name: str
    wave: int
    started_seconds: float
    first_token_seconds: float | None
    completed_seconds: float
    prompt_tokens: int
    completion_tokens: int
    failure_class: str | None

    @property
    def succeeded(self) -> bool:
        return self.failure_class is None

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

    @property
    def decode_tokens(self) -> int:
        # The first token is produced by prefill, so only the remainder measures
        # decode throughput.
        return max(self.completion_tokens - 1, 0)


@dataclasses.dataclass(frozen=True)
class WaveResult:
    wave: int
    request_count: int
    succeeded: int
    wall_clock_seconds: float
    decode_span_seconds: float | None
    completion_tokens: int


@dataclasses.dataclass(frozen=True)
class SpecMetrics:
    available: bool
    accept_length: float | None
    accept_rate: float | None


@dataclasses.dataclass(frozen=True)
class BenchmarkResult:
    concurrency: int
    request_count: int
    succeeded: int
    failed: int
    wall_clock_seconds: float
    completion_tokens_total: int
    completion_tokens_exact: bool
    aggregate_end_to_end_tokens_per_second: float | None
    aggregate_decode_tokens_per_second: float | None
    latency_p50_seconds: float | None
    latency_p95_seconds: float | None
    ttft_p50_seconds: float | None
    ttft_p95_seconds: float | None
    tpot_p50_seconds: float | None
    tpot_p95_seconds: float | None
    per_stream_decode_p50_tokens_per_second: float | None
    per_stream_decode_p95_tokens_per_second: float | None
    waves: tuple[WaveResult, ...]
    measurements: tuple[RequestMeasurement, ...]
    failures: tuple[tuple[str, str], ...]
    spec_metrics: SpecMetrics | None = None


def percentile(values: Sequence[float], fraction: float) -> float:
    """Nearest-rank percentile.

    Nearest rank always returns an observed measurement. Interpolating would
    publish a latency the deployment never produced.
    """
    if not values:
        raise ValueError("a percentile needs at least one observation")
    if not isinstance(fraction, (int, float)) or not 0 < fraction <= 1:
        raise ValueError("a percentile fraction must fall in (0, 1]")
    ordered = sorted(float(value) for value in values)
    index = math.ceil(fraction * len(ordered)) - 1
    return ordered[max(0, min(index, len(ordered) - 1))]


def _optional_percentile(
    values: Sequence[float],
    fraction: float,
) -> float | None:
    if not values:
        return None
    return percentile(values, fraction)


def _require_concurrency(concurrency: Any) -> int:
    if isinstance(concurrency, bool) or concurrency not in CONCURRENCY_VALUES:
        raise ValueError("the benchmark supports concurrency 1 and 4 only")
    return int(concurrency)


def build_benchmark_requests(
    model: str,
    count: int,
    output_tokens: int,
    prompt_index_start: int = 0,
    name_prefix: str = "request",
) -> list[BenchmarkRequest]:
    """Build a fixed, distinct request set with an exact completion budget."""
    if not isinstance(model, str) or not model:
        raise ValueError("the benchmark requires the recorded served model name")
    if not isinstance(count, int) or count <= 0:
        raise ValueError("the benchmark request count must be positive")
    if not isinstance(output_tokens, int) or output_tokens <= 0:
        raise ValueError("the benchmark output token budget must be positive")
    if not isinstance(prompt_index_start, int) or prompt_index_start < 0:
        raise ValueError("the benchmark prompt index must not be negative")
    requests = []
    for offset in range(count):
        index = prompt_index_start + offset
        requests.append(
            BenchmarkRequest(
                name=f"{name_prefix}-{index}",
                payload={
                    "model": model,
                    "messages": [
                        {
                            "role": "user",
                            "content": BENCHMARK_PROMPT_TEMPLATE.format(index=index),
                        }
                    ],
                    "max_tokens": output_tokens,
                    "min_tokens": output_tokens,
                    "temperature": 0.0,
                    # Exact token accounting needs the deployment to keep
                    # generating until the budget is spent.
                    "ignore_eos": True,
                    "stream": True,
                    "stream_options": {"include_usage": True},
                },
                expected_completion_tokens=output_tokens,
            )
        )
    return requests


def _failure_class_of(error: BaseException) -> str:
    failure_class = getattr(error, "failure_class", None)
    if failure_class in INFRASTRUCTURE_FAILURE_CLASSES:
        return str(failure_class)
    if failure_class in CORRECTNESS_FAILURE_CLASSES:
        return str(failure_class)
    return "transport"


def run_benchmark(
    client: Any,
    requests: Sequence[BenchmarkRequest],
    concurrency: int,
    warmup: BenchmarkRequest | None = None,
) -> BenchmarkResult:
    """Run whole synchronized waves and summarize what was actually measured."""
    concurrency = _require_concurrency(concurrency)
    if not requests:
        raise ValueError("the benchmark requires at least one request")
    if len(requests) % concurrency != 0:
        raise ValueError("the benchmark request count must fill whole waves")

    if warmup is not None:
        try:
            client.stream_chat(dict(warmup.payload))
        except (InfrastructureError, ValidationError):
            # A failed warmup is not evidence about steady state, and every
            # measured request still reports its own outcome below.
            pass

    measurements: list[RequestMeasurement] = []
    wave_count = len(requests) // concurrency
    for wave in range(wave_count):
        batch = list(requests[wave * concurrency : (wave + 1) * concurrency])
        measurements.extend(_run_wave(client, batch, wave, concurrency))
    return summarize_measurements(
        concurrency=concurrency,
        measurements=measurements,
        expected_completion_tokens=requests[0].expected_completion_tokens,
    )


def _run_wave(
    client: Any,
    batch: Sequence[BenchmarkRequest],
    wave: int,
    concurrency: int,
) -> list[RequestMeasurement]:
    barrier = threading.Barrier(concurrency, timeout=BARRIER_TIMEOUT_SECONDS)
    ordered: list[RequestMeasurement | None] = [None] * len(batch)

    def issue(position: int) -> None:
        request = batch[position]
        # Every request in a wave waits here, so the wave really begins as a
        # simultaneous burst instead of a staggered ramp.
        barrier.wait()
        try:
            streamed = client.stream_chat(dict(request.payload))
        except (InfrastructureError, ValidationError) as error:
            ordered[position] = _failed_measurement(request, wave, error)
            return
        ordered[position] = _measurement_from(request, wave, streamed)

    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = [executor.submit(issue, position) for position in range(len(batch))]
        for future in futures:
            future.result()
    results = []
    for measurement in ordered:
        if measurement is None:
            raise ValueError("a benchmark wave produced no measurement for a request")
        results.append(measurement)
    return results


def _measurement_from(
    request: BenchmarkRequest,
    wave: int,
    streamed: StreamedChat,
) -> RequestMeasurement:
    return RequestMeasurement(
        name=request.name,
        wave=wave,
        started_seconds=streamed.started_seconds,
        first_token_seconds=streamed.first_token_seconds,
        completed_seconds=streamed.completed_seconds,
        prompt_tokens=streamed.prompt_tokens,
        completion_tokens=streamed.completion_tokens,
        failure_class=None,
    )


def _failed_measurement(
    request: BenchmarkRequest,
    wave: int,
    error: BaseException,
) -> RequestMeasurement:
    return RequestMeasurement(
        name=request.name,
        wave=wave,
        started_seconds=0.0,
        first_token_seconds=None,
        completed_seconds=0.0,
        prompt_tokens=0,
        completion_tokens=0,
        failure_class=_failure_class_of(error),
    )


def _validate_monotonic(measurement: RequestMeasurement) -> None:
    if measurement.completed_seconds < measurement.started_seconds:
        raise ValueError(f"request {measurement.name} completed before it started")
    if measurement.first_token_seconds is None:
        return
    if not (
        measurement.started_seconds
        <= measurement.first_token_seconds
        <= measurement.completed_seconds
    ):
        raise ValueError(f"request {measurement.name} reported a non-monotonic stream")


def summarize_measurements(
    concurrency: int,
    measurements: Sequence[RequestMeasurement],
    expected_completion_tokens: int,
    spec_metrics: SpecMetrics | None = None,
) -> BenchmarkResult:
    """Derive every published metric from the measurements, and only from them."""
    concurrency = _require_concurrency(concurrency)
    if not measurements:
        raise ValueError("a benchmark summary needs at least one measurement")
    if (
        not isinstance(expected_completion_tokens, int)
        or expected_completion_tokens <= 0
    ):
        raise ValueError("the expected completion token count must be positive")

    waves: dict[int, list[RequestMeasurement]] = {}
    for measurement in measurements:
        if measurement.succeeded:
            _validate_monotonic(measurement)
        waves.setdefault(measurement.wave, []).append(measurement)
    for wave, batch in waves.items():
        if len(batch) != concurrency:
            raise ValueError(f"wave {wave} does not hold exactly {concurrency} requests")

    wave_results = []
    for wave in sorted(waves):
        wave_results.append(_summarize_wave(wave, waves[wave]))

    succeeded = [item for item in measurements if item.succeeded]
    failures = tuple(
        (item.name, str(item.failure_class))
        for item in measurements
        if not item.succeeded
    )
    completion_tokens_total = sum(item.completion_tokens for item in succeeded)
    wall_clock = sum(result.wall_clock_seconds for result in wave_results)
    decode_span = sum(
        result.decode_span_seconds
        for result in wave_results
        if result.decode_span_seconds is not None
    )
    decode_tokens = sum(
        item.decode_tokens for item in succeeded if item.first_token_seconds is not None
    )

    latencies = [item.end_to_end_seconds for item in succeeded]
    ttfts = [
        item.ttft_seconds for item in succeeded if item.ttft_seconds is not None
    ]
    per_stream = []
    tpots = []
    for item in succeeded:
        duration = item.decode_seconds
        if duration is None or duration <= 0 or item.decode_tokens <= 0:
            continue
        per_stream.append(item.decode_tokens / duration)
        tpots.append(duration / item.decode_tokens)

    return BenchmarkResult(
        concurrency=concurrency,
        request_count=len(measurements),
        succeeded=len(succeeded),
        failed=len(measurements) - len(succeeded),
        wall_clock_seconds=wall_clock,
        completion_tokens_total=completion_tokens_total,
        completion_tokens_exact=all(
            item.completion_tokens == expected_completion_tokens for item in succeeded
        ),
        aggregate_end_to_end_tokens_per_second=(
            completion_tokens_total / wall_clock
            if succeeded and wall_clock > 0
            else None
        ),
        aggregate_decode_tokens_per_second=(
            decode_tokens / decode_span if decode_tokens > 0 and decode_span > 0 else None
        ),
        latency_p50_seconds=_optional_percentile(latencies, 0.5),
        latency_p95_seconds=_optional_percentile(latencies, 0.95),
        ttft_p50_seconds=_optional_percentile(ttfts, 0.5),
        ttft_p95_seconds=_optional_percentile(ttfts, 0.95),
        tpot_p50_seconds=_optional_percentile(tpots, 0.5),
        tpot_p95_seconds=_optional_percentile(tpots, 0.95),
        per_stream_decode_p50_tokens_per_second=_optional_percentile(per_stream, 0.5),
        per_stream_decode_p95_tokens_per_second=_optional_percentile(per_stream, 0.95),
        waves=tuple(wave_results),
        measurements=tuple(measurements),
        failures=failures,
        spec_metrics=spec_metrics,
    )


def _summarize_wave(wave: int, batch: Sequence[RequestMeasurement]) -> WaveResult:
    succeeded = [item for item in batch if item.succeeded]
    if not succeeded:
        return WaveResult(
            wave=wave,
            request_count=len(batch),
            succeeded=0,
            wall_clock_seconds=0.0,
            decode_span_seconds=None,
            completion_tokens=0,
        )
    started = min(item.started_seconds for item in succeeded)
    completed = max(item.completed_seconds for item in succeeded)
    first_tokens = [
        item.first_token_seconds
        for item in succeeded
        if item.first_token_seconds is not None
    ]
    # The decode span excludes the slowest prefill in the wave, so concurrent
    # decode throughput is not diluted by time no token was being produced.
    decode_span = completed - min(first_tokens) if first_tokens else None
    return WaveResult(
        wave=wave,
        request_count=len(batch),
        succeeded=len(succeeded),
        wall_clock_seconds=completed - started,
        decode_span_seconds=decode_span,
        completion_tokens=sum(item.completion_tokens for item in succeeded),
    )


# ---------------------------------------------------------------------------
# Speculative decoding gauges
# ---------------------------------------------------------------------------


def _parse_metric(text: str, metric_name: str) -> float | None:
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        matched = METRIC_LINE_PATTERN.match(stripped)
        if matched is None or matched.group("name") != metric_name:
            continue
        try:
            value = float(matched.group("value"))
        except ValueError:
            return None
        if value != value or value in (float("inf"), float("-inf")):
            return None
        return value
    return None


def read_spec_metrics(client: Any) -> SpecMetrics:
    """Read the DFlash speculative gauges, or report them as unavailable.

    These are last-batch gauges rather than whole-run averages, and an endpoint
    without a metrics route is a normal configuration. Neither case may be
    filled in with a guess.
    """
    try:
        payload = client.get_text(METRICS_PATH)
    except (InfrastructureError, ValidationError, OSError):
        return SpecMetrics(available=False, accept_length=None, accept_rate=None)
    if not isinstance(payload, str):
        return SpecMetrics(available=False, accept_length=None, accept_rate=None)
    return SpecMetrics(
        available=True,
        accept_length=_parse_metric(payload, SPEC_ACCEPT_LENGTH_METRIC),
        accept_rate=_parse_metric(payload, SPEC_ACCEPT_RATE_METRIC),
    )


# ---------------------------------------------------------------------------
# Sanitized evidence
# ---------------------------------------------------------------------------


def _rounded(value: float | None, digits: int = 6) -> float | None:
    if value is None:
        return None
    return round(float(value), digits)


def _concurrency_payload(result: BenchmarkResult) -> dict[str, Any]:
    spec = result.spec_metrics
    return {
        "concurrency": result.concurrency,
        "request_count": result.request_count,
        "succeeded": result.succeeded,
        "failed": result.failed,
        "wave_count": len(result.waves),
        "wall_clock_seconds": _rounded(result.wall_clock_seconds),
        "completion_tokens_total": result.completion_tokens_total,
        "completion_tokens_exact": result.completion_tokens_exact,
        "aggregate_end_to_end_tokens_per_second": _rounded(
            result.aggregate_end_to_end_tokens_per_second
        ),
        "aggregate_decode_tokens_per_second": _rounded(
            result.aggregate_decode_tokens_per_second
        ),
        "latency_p50_seconds": _rounded(result.latency_p50_seconds),
        "latency_p95_seconds": _rounded(result.latency_p95_seconds),
        "ttft_p50_seconds": _rounded(result.ttft_p50_seconds),
        "ttft_p95_seconds": _rounded(result.ttft_p95_seconds),
        "tpot_p50_seconds": _rounded(result.tpot_p50_seconds),
        "tpot_p95_seconds": _rounded(result.tpot_p95_seconds),
        "per_stream_decode_p50_tokens_per_second": _rounded(
            result.per_stream_decode_p50_tokens_per_second
        ),
        "per_stream_decode_p95_tokens_per_second": _rounded(
            result.per_stream_decode_p95_tokens_per_second
        ),
        "round_wall_clock_seconds": [
            _rounded(wave.wall_clock_seconds) for wave in result.waves
        ],
        "spec_metrics_available": bool(spec.available) if spec is not None else False,
        "spec_accept_length": _rounded(spec.accept_length) if spec is not None else None,
        "spec_accept_rate": _rounded(spec.accept_rate) if spec is not None else None,
        # Request names are package-generated, but publishing them adds nothing
        # a reader can act on, so only the failure taxonomy survives.
        "failure_classes": sorted({failure for _name, failure in result.failures}),
    }


def sanitized_benchmark_payload(
    results: Sequence[BenchmarkResult],
    request_configuration: Mapping[str, Any],
    served_model_name: str,
) -> dict[str, Any]:
    """Build the only representation of a benchmark that may be persisted."""
    if not results:
        raise ValueError("a benchmark payload needs at least one result")
    sections: dict[str, Any] = {}
    outcome = "passed"
    for result in results:
        key = f"c{result.concurrency}"
        if key in sections:
            raise ValueError(f"the benchmark repeats concurrency {result.concurrency}")
        sections[key] = _concurrency_payload(result)
        if result.failed or not result.succeeded:
            outcome = "failed-infrastructure"
        elif not result.completion_tokens_exact and outcome == "passed":
            outcome = "failed-correctness"
    return {
        "schema_version": SCHEMA_VERSION,
        "suite": "benchmark",
        "served_model_name": served_model_name,
        "model_path_matches_recorded_run": True,
        "outcome": outcome,
        "request_configuration": dict(request_configuration),
        "concurrency": sections,
    }


# ---------------------------------------------------------------------------
# Remote execution
# ---------------------------------------------------------------------------


def _build_remote_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="benchmark.py remote")
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--timeout-seconds", required=True, type=float)
    parser.add_argument("--expected-model-path", required=True)
    parser.add_argument("--expected-served-name", required=True)
    parser.add_argument("--output-tokens", type=int, default=DEFAULT_OUTPUT_TOKENS)
    parser.add_argument("--warmup-tokens", type=int, default=DEFAULT_WARMUP_TOKENS)
    parser.add_argument("--rounds", type=int, default=DEFAULT_ROUNDS)
    return parser


def run_remote_benchmark(arguments: Sequence[str]) -> dict[str, Any]:
    options = _build_remote_parser().parse_args(list(arguments))
    if not 1 <= options.rounds <= MAXIMUM_ROUNDS:
        raise ValueError("the benchmark round count is outside the supported range")
    client = OpenAIClient(options.base_url, timeout_seconds=options.timeout_seconds)
    served_name = options.expected_served_name
    configuration = {
        "output_tokens_per_request": options.output_tokens,
        "warmup_output_tokens": options.warmup_tokens,
        "temperature": 0.0,
        "ignore_eos": True,
        "rounds": options.rounds,
        "concurrency_levels": list(CONCURRENCY_VALUES),
        "timeout_seconds": options.timeout_seconds,
    }
    try:
        verify_identity(client, options.expected_model_path, served_name)
    except InfrastructureError as exc:
        return _failed_benchmark_payload(served_name, exc.failure_class, configuration)

    results = []
    prompt_index = 0
    try:
        for concurrency in CONCURRENCY_VALUES:
            warmup = build_benchmark_requests(
                served_name,
                count=1,
                output_tokens=options.warmup_tokens,
                prompt_index_start=prompt_index,
                name_prefix=f"warmup-c{concurrency}",
            )[0]
            prompt_index += 1
            requests = build_benchmark_requests(
                served_name,
                count=concurrency * options.rounds,
                output_tokens=options.output_tokens,
                prompt_index_start=prompt_index,
                name_prefix=f"c{concurrency}",
            )
            prompt_index += len(requests)
            result = run_benchmark(client, requests, concurrency, warmup=warmup)
            results.append(
                dataclasses.replace(result, spec_metrics=read_spec_metrics(client))
            )
    except InfrastructureError as exc:
        return _failed_benchmark_payload(served_name, exc.failure_class, configuration)
    return sanitized_benchmark_payload(results, configuration, served_name)


def _failed_benchmark_payload(
    served_name: str,
    failure_class: str,
    configuration: Mapping[str, Any],
) -> dict[str, Any]:
    section = {
        "concurrency": 0,
        "request_count": 0,
        "succeeded": 0,
        "failed": 0,
        "failure_classes": [failure_class],
    }
    return {
        "schema_version": SCHEMA_VERSION,
        "suite": "benchmark",
        "served_model_name": served_name,
        "model_path_matches_recorded_run": False,
        "outcome": "failed-infrastructure",
        "request_configuration": dict(configuration),
        "concurrency": {
            "c1": dict(section, concurrency=1),
            "c4": dict(section, concurrency=4),
        },
    }


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="benchmark.py")
    subparsers = parser.add_subparsers(dest="command", required=True)
    remote_parser = subparsers.add_parser("remote")
    remote_parser.add_argument("--mode", required=True, choices=("benchmark",))
    remote_parser.add_argument("arguments", nargs=argparse.REMAINDER)
    return parser


def main(arguments: list[str] | None = None) -> int:
    parser = _build_parser()
    options = parser.parse_args(arguments)
    values = list(options.arguments)
    if values and values[0] == "--":
        values = values[1:]
    try:
        print(canonical_json(run_remote_benchmark(values)))
    except (ValidationError, ValueError, OSError) as exc:
        print(f"benchmark: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
