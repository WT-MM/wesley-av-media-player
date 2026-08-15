#!/usr/bin/env python3
"""Adversarial unit tests for the macOS shipper phase reducers."""

from __future__ import annotations

import copy
import hashlib
import json
import unittest

import shipper_phase_metrics as metrics


BASE = 1_000_000_000
ORIGIN = 900_000_000
COALITION_ID = 77
CANDIDATE = "candidate-release"
ASSET = "a" * 64
VARIANT = "hevc-main10-mkv"


def digest(value):
    return hashlib.sha256(
        json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
            allow_nan=False,
        ).encode("utf-8")
    ).hexdigest()


def app_member(*, hwm=80 * 1024 * 1024):
    return {
        "member_id": "501:123456",
        "pid": 501,
        "process_start_abstime": 123456,
        "role": "app",
        "coalition_id": COALITION_ID,
        "proc_rusage_lifetime_max_phys_footprint_bytes": hwm,
    }


def helper_member(*, hwm=30 * 1024 * 1024):
    return {
        "member_id": "502:234567",
        "pid": 502,
        "process_start_abstime": 234567,
        "role": "decoder_helper",
        "coalition_id": COALITION_ID,
        "proc_rusage_lifetime_max_phys_footprint_bytes": hwm,
    }


def final_rusage(member, *, hwm, start, finish):
    proof = {
        "member_id": member["member_id"],
        "query_started_monotonic_ns": start,
        "query_finished_monotonic_ns": finish,
        "lifetime_max_phys_footprint_bytes": hwm,
        "terminal_capture_validated": True,
        "no_memory_activity_after_query": True,
    }
    return {
        "query_started_monotonic_ns": start,
        "query_finished_monotonic_ns": finish,
        "lifetime_max_phys_footprint_bytes": hwm,
        "terminal_capture_validated": True,
        "no_memory_activity_after_query": True,
        "final_rusage_receipt_sha256": digest(proof),
    }


def live_identity(member, hwm=None):
    result = {
        key: member[key]
        for key in (
            "member_id",
            "pid",
            "process_start_abstime",
            "role",
            "coalition_id",
        )
    }
    result["proc_rusage_lifetime_max_phys_footprint_bytes"] = (
        member["proc_rusage_lifetime_max_phys_footprint_bytes"]
        if hwm is None
        else hwm
    )
    return result


def make_artifact(
    run_id="startup-1",
    *,
    tick_step=2_000_000,
    record_count=36,
    latency_pattern=(0, 1_000_000, 500_000, 1_500_000),
    query_duration_ns=2_000_000,
    cold=False,
    transient=False,
    scrub_deliveries=None,
    authorized_phase_requests=None,
    memory_bytes=80 * 1024 * 1024,
):
    receipt_id = f"receipt-{run_id}"
    app = app_member(hwm=memory_bytes)
    helper = helper_member()
    records = []
    for index in range(record_count):
        scheduled = ORIGIN + index * metrics.SAMPLE_INTERVAL_NS
        started = scheduled + latency_pattern[index % len(latency_pattern)]
        finished = started + query_duration_ns
        if cold and index < 2:
            tasks_started = 0
            tasks_exited = 0
            live = []
        elif transient and index >= 5:
            tasks_started = 2
            tasks_exited = 1 if index >= 8 else 0
            live = [live_identity(app)] if index >= 8 else [live_identity(app), live_identity(helper)]
        else:
            tasks_started = 1
            tasks_exited = 0
            live = [live_identity(app)]
        records.append(
            {
                "sample_index": index,
                "scheduled_monotonic_ns": scheduled,
                "query_started_monotonic_ns": started,
                "query_finished_monotonic_ns": finished,
                "coalition_id": COALITION_ID,
                "coalition_cpu_time_ticks": 7_000_000_000_000 + index * tick_step,
                "tasks_started": tasks_started,
                "tasks_exited": tasks_exited,
                "active_count": tasks_started - tasks_exited,
                "coalition_phys_footprint_bytes": 999 * 1024 * 1024,
                "live_members": live,
                "scope_id": "coalition-77",
                "producer_receipt_id": receipt_id,
            }
        )
    app_started = records[2]["query_finished_monotonic_ns"] if cold else ORIGIN - 20_000_000
    lifecycles = [
        {
            **{key: app[key] for key in ("member_id", "pid", "process_start_abstime", "role", "coalition_id")},
            "tasks_started_ordinal": 1,
            "tasks_exited_ordinal": None,
            "started_monotonic_ns": app_started,
            "exited_monotonic_ns": None,
            "final_rusage": None,
        }
    ]
    if transient:
        helper_started = records[4]["query_finished_monotonic_ns"] + 1
        helper_exited = records[7]["query_finished_monotonic_ns"] + 1
        final = final_rusage(
            helper,
            hwm=helper["proc_rusage_lifetime_max_phys_footprint_bytes"],
            start=helper_exited - 2_000_000,
            finish=helper_exited - 1,
        )
        lifecycles.append(
            {
                **{key: helper[key] for key in ("member_id", "pid", "process_start_abstime", "role", "coalition_id")},
                "tasks_started_ordinal": 2,
                "tasks_exited_ordinal": 1,
                "started_monotonic_ns": helper_started,
                "exited_monotonic_ns": helper_exited,
                "final_rusage": final,
            }
        )
    artifact = {
        "schema": metrics.RAW_ARTIFACT_SCHEMA,
        "artifact_id": f"artifact-{run_id}",
        "receipt_id": receipt_id,
        "candidate_id": CANDIDATE,
        "asset_sha256": ASSET,
        "variant": VARIANT,
        "run_id": run_id,
        "scope_id": "coalition-77",
        "scope_kind": "resource_coalition",
        "coalition_id": COALITION_ID,
        "app_process_identity": {
            "pid": app["pid"],
            "process_start_abstime": app["process_start_abstime"],
            "coalition_id": COALITION_ID,
        },
        "schedule": {
            "origin_monotonic_ns": ORIGIN,
            "period_ns": metrics.SAMPLE_INTERVAL_NS,
            "mach_timebase_numer": 1,
            "mach_timebase_denom": 1,
            "clock_domain": "host_monotonic_ns",
        },
        "member_lifecycles": lifecycles,
        "records": records,
    }
    receipt = make_receipt(
        artifact,
        cold=cold,
        scrub_deliveries=[] if scrub_deliveries is None else scrub_deliveries,
        phase_requests=authorized_phase_requests,
    )
    return artifact, receipt


def make_receipt(
    artifact, *, cold=False, scrub_deliveries=None, phase_requests=None
):
    exited_receipts = []
    for lifecycle in artifact["member_lifecycles"]:
        if lifecycle["tasks_exited_ordinal"] is not None:
            exited_receipts.append(
                {
                    "member_id": lifecycle["member_id"],
                    "final_rusage_receipt_sha256": lifecycle["final_rusage"][
                        "final_rusage_receipt_sha256"
                    ],
                }
            )
    receipt = {
        "schema": metrics.TRUSTED_RECEIPT_SCHEMA,
        "receipt_id": artifact["receipt_id"],
        "raw_artifact_sha256": metrics.compute_raw_artifact_sha256(artifact),
        "scope_id": artifact["scope_id"],
        "scope_kind": artifact["scope_kind"],
        "coalition_id": artifact["coalition_id"],
        "candidate_id": artifact["candidate_id"],
        "asset_sha256": artifact["asset_sha256"],
        "variant": artifact["variant"],
        "run_id": artifact["run_id"],
        "mach_timebase_numer": artifact["schedule"]["mach_timebase_numer"],
        "mach_timebase_denom": artifact["schedule"]["mach_timebase_denom"],
        "clock_domain": artifact["schedule"]["clock_domain"],
        "validated_by": "test-receipt-validator-v1",
        "authentication_validated": True,
        "producer_identity": "wam.shipper.evidence-producer",
        "producer_tool_identity": "run_shipper",
        "producer_tool_version": "2.0",
        "producer_authentication_key_id": "test-key-1",
        "producer_tool_binary_sha256": "b" * 64,
        "producer_authentication_evidence_sha256": "c" * 64,
        "coverage_kind": "xnu_resource_coalition_v1",
        "cpu_counter_semantics": "coalition_info_resource_usage.cpu_time_mach_absolute_ticks",
        "memory_counter_semantics": "sum_authenticated_member_lifetime_hwm_nonco_temporal_upper_bound",
        "includes_transient_members": True,
        "includes_exited_members": True,
        "continuous_membership_lifecycle_audit": True,
        "tasks_counter_semantics_validated": True,
        "tasks_counter_delta_ordinals_complete": True,
        "exec_transition_accounting_validated": True,
        "event_clock_correlation_validated": True,
        "membership_lifecycle_audit_sha256": digest(artifact["member_lifecycles"]),
        "final_rusage_receipts_sha256": digest(exited_receipts),
        "scope_lifecycle_started_monotonic_ns": ORIGIN - 50_000_000,
        "scope_lifecycle_ended_monotonic_ns": ORIGIN
        + len(artifact["records"]) * metrics.SAMPLE_INTERVAL_NS
        + 20_000_000,
        "app_process_identity": copy.deepcopy(artifact["app_process_identity"]),
        "scrub_deliveries": [] if scrub_deliveries is None else scrub_deliveries,
        "scrub_request_id": None if not scrub_deliveries else "scrub-request",
        "phase_requests": copy.deepcopy(
            [phase_request("cold" if cold else "warm")]
            if phase_requests is None
            else phase_requests
        ),
        "scope_created_monotonic_ns": ORIGIN - 50_000_000,
        "cold_scope_no_prior_workload_contamination": cold,
        "cold_baseline_counter_validated": cold,
        "cold_new_launch_coalition": cold,
        "cold_no_preexisting_app": cold,
    }
    receipt["immutable_receipt_digest_sha256"] = (
        metrics.compute_immutable_receipt_digest_sha256(receipt)
    )
    return receipt


class FakeTrustedIndex(metrics.TrustedReceiptIndex):
    def __init__(self, receipts=()):
        self.receipts = {
            (value["receipt_id"], value["raw_artifact_sha256"]): copy.deepcopy(value)
            for value in receipts
        }

    @property
    def validator_identity(self):
        return "test-receipt-validator-v1"

    def resolve_authenticated_receipt(self, receipt_id, raw_artifact_sha256):
        value = self.receipts.get((receipt_id, raw_artifact_sha256))
        return None if value is None else copy.deepcopy(value)


def phase_request(phase, *, start=BASE, end=BASE + 500_000_000, request_id=None):
    result = {
        "schema": metrics.PHASE_REQUEST_SCHEMA,
        "request_id": request_id or f"{phase}-request",
        "phase": phase,
        "start_monotonic_ns": start,
        "end_monotonic_ns": end,
    }
    if phase == "cold":
        result["launch_request_monotonic_ns"] = start
    return result


def scrub_request():
    return {
        "schema": metrics.SCRUB_REQUEST_SCHEMA,
        "request_id": "scrub-request",
        "gestures": [
            {
                "request_id": "scrub-forward-request",
                "gesture_id": "gesture-forward",
                "direction": "forward",
                "delivery_evidence_id": "delivery-forward",
                "start_monotonic_ns": BASE,
                "end_monotonic_ns": BASE + 500_000_000,
            },
            {
                "request_id": "scrub-reverse-request",
                "gesture_id": "gesture-reverse",
                "direction": "reverse",
                "delivery_evidence_id": "delivery-reverse",
                "start_monotonic_ns": BASE + 600_000_000,
                "end_monotonic_ns": BASE + 1_100_000_000,
            },
        ],
    }


def deliveries(request):
    return [
        {
            "request_id": value["request_id"],
            "gesture_id": value["gesture_id"],
            "direction": value["direction"],
            "delivery_evidence_id": value["delivery_evidence_id"],
            "start_monotonic_ns": value["start_monotonic_ns"],
            "end_monotonic_ns": value["end_monotonic_ns"],
        }
        for value in request["gestures"]
    ]


def reduced_phase(phase, *, run_id="startup-1", tick_step=2_000_000, memory_bytes=80 * 1024 * 1024):
    artifact, receipt = make_artifact(
        run_id,
        tick_step=tick_step,
        cold=phase == "cold",
        authorized_phase_requests=[phase_request(phase)],
        memory_bytes=memory_bytes,
    )
    index = FakeTrustedIndex([receipt])
    return metrics.reduce_phase(
        artifact, phase_request(phase), trusted_receipt_index=index
    ), receipt


def reduced_scrub(*, run_id="scrub-1", tick_step=1_000_000):
    request = scrub_request()
    artifact, receipt = make_artifact(
        run_id,
        tick_step=tick_step,
        scrub_deliveries=deliveries(request),
    )
    index = FakeTrustedIndex([receipt])
    return metrics.reduce_scrub(
        artifact, request, trusted_receipt_index=index
    ), receipt


def startup_pair(
    *,
    run_id="startup-1",
    warm_tick=2_000_000,
    cold_tick=10_000_000,
    warm_total_ns=None,
    cold_total_ns=None,
    memory_bytes=80 * 1024 * 1024,
):
    cold_request = phase_request("cold")
    warm_request = phase_request(
        "warm",
        start=BASE + 600_000_000,
        end=BASE + 1_100_000_000,
        request_id="warm-second-open-request",
    )
    artifact, receipt = make_artifact(
        run_id,
        tick_step=0,
        cold=True,
        memory_bytes=memory_bytes,
        authorized_phase_requests=[cold_request, warm_request],
    )
    def increments(total, fallback):
        if total is None:
            return [fallback] * 11
        quotient, remainder = divmod(total, 11)
        return [quotient + (1 if index < remainder else 0) for index in range(11)]

    cold_increments = increments(cold_total_ns, cold_tick)
    warm_increments = increments(warm_total_ns, warm_tick)
    cumulative = 7_000_000_000_000
    for index, record in enumerate(artifact["records"]):
        if 2 <= index <= 12:
            cumulative += cold_increments[index - 2]
        elif 14 <= index <= 24:
            cumulative += warm_increments[index - 14]
        record["coalition_cpu_time_ticks"] = cumulative
    receipt = make_receipt(
        artifact,
        cold=True,
        phase_requests=[cold_request, warm_request],
    )
    index = FakeTrustedIndex([receipt])
    cold = metrics.reduce_phase(
        artifact, cold_request, trusted_receipt_index=index
    )
    warm = metrics.reduce_phase(
        artifact, warm_request, trusted_receipt_index=index
    )
    return warm, cold, receipt


def exact_phase_bundle(phase, *, run_id, total_cpu_ns, memory_bytes=80 * 1024 * 1024):
    request = phase_request(phase)
    artifact, _ = make_artifact(
        run_id,
        tick_step=0,
        cold=phase == "cold",
        memory_bytes=memory_bytes,
        authorized_phase_requests=[request],
    )
    quotient, remainder = divmod(total_cpu_ns, 11)
    cumulative = 7_000_000_000_000
    for index, record in enumerate(artifact["records"]):
        if 2 <= index <= 12:
            cumulative += quotient + (1 if index - 2 < remainder else 0)
        record["coalition_cpu_time_ticks"] = cumulative
    receipt = make_receipt(
        artifact, cold=phase == "cold", phase_requests=[request]
    )
    bundle = metrics.reduce_phase(
        artifact, request, trusted_receipt_index=FakeTrustedIndex([receipt])
    )
    return bundle, receipt


def exact_scrub_bundle(*, run_id, total_cpu_ns_each_leg):
    request = scrub_request()
    artifact, _ = make_artifact(
        run_id,
        tick_step=0,
        scrub_deliveries=deliveries(request),
    )
    quotient, remainder = divmod(total_cpu_ns_each_leg, 11)
    per_leg = [quotient + (1 if index < remainder else 0) for index in range(11)]
    cumulative = 7_000_000_000_000
    for index, record in enumerate(artifact["records"]):
        if 2 <= index <= 12:
            cumulative += per_leg[index - 2]
        elif 14 <= index <= 24:
            cumulative += per_leg[index - 14]
        record["coalition_cpu_time_ticks"] = cumulative
    receipt = make_receipt(artifact, scrub_deliveries=deliveries(request))
    bundle = metrics.reduce_scrub(
        artifact, request, trusted_receipt_index=FakeTrustedIndex([receipt])
    )
    return bundle, receipt


class ConservativePhaseTests(unittest.TestCase):
    def test_nonzero_duration_jitter_uses_conservative_bracket_and_exact_denominator(self):
        artifact, receipt = make_artifact(tick_step=3_000_000)
        result = metrics.reduce_phase(
            artifact, phase_request("warm"), trusted_receipt_index=FakeTrustedIndex([receipt])
        )
        self.assertEqual(result["baseline_record_index"], 1)
        self.assertEqual(result["terminal_record_index"], 12)
        self.assertLessEqual(result["baseline_snapshot_finished_monotonic_ns"], BASE)
        self.assertGreaterEqual(
            result["terminal_snapshot_started_monotonic_ns"], BASE + 500_000_000
        )
        self.assertEqual(result["cpu_time_ns_exact"], {"numerator": 33_000_000, "denominator": 1})
        self.assertEqual(result["cpu_percent_exact"], {"numerator": 33, "denominator": 5})
        self.assertEqual(result["elapsed_ns"], 500_000_000)
        self.assertTrue(result["evidence"]["boundary_cpu_cannot_undercount"])
        self.assertFalse(result["evidence"]["interpolation_used"])

    def test_arbitrary_event_bounds_are_conservatively_bracketed(self):
        artifact, receipt = make_artifact(tick_step=1_000_000)
        request = phase_request(
            "warm", start=BASE + 12_345_678, end=BASE + 387_654_321
        )
        receipt = make_receipt(artifact, phase_requests=[request])
        result = metrics.reduce_phase(
            artifact, request, trusted_receipt_index=FakeTrustedIndex([receipt])
        )
        self.assertLessEqual(result["baseline_snapshot_finished_monotonic_ns"], request["start_monotonic_ns"])
        self.assertGreaterEqual(result["terminal_snapshot_started_monotonic_ns"], request["end_monotonic_ns"])
        self.assertEqual(result["elapsed_ns"], 375_308_643)
        self.assertEqual(result["cpu_time_ns_exact"]["denominator"], 1)

    def test_huge_counters_use_delta_first_exact_arithmetic(self):
        artifact, receipt = make_artifact(tick_step=1)
        artifact["records"][0]["coalition_cpu_time_ticks"] = 9_007_199_254_740_992
        for index, record in enumerate(artifact["records"]):
            record["coalition_cpu_time_ticks"] = 9_007_199_254_740_992 + index
        receipt = make_receipt(artifact)
        result = metrics.reduce_phase(
            artifact, phase_request("warm"), trusted_receipt_index=FakeTrustedIndex([receipt])
        )
        self.assertEqual(result["cpu_time_ns_exact"], {"numerator": 11, "denominator": 1})

    def test_nonintegral_tick_conversion_fails_closed(self):
        artifact, _ = make_artifact()
        artifact["schedule"]["mach_timebase_denom"] = 3
        receipt = make_receipt(artifact)
        with self.assertRaisesRegex(metrics.PhaseMetricsError, "integral ns"):
            metrics.reduce_phase(
                artifact, phase_request("warm"), trusted_receipt_index=FakeTrustedIndex([receipt])
            )

    def test_memory_gate_uses_member_hwm_sum_not_coalition_diagnostic(self):
        artifact, receipt = make_artifact(memory_bytes=80 * 1024 * 1024)
        result = metrics.reduce_phase(
            artifact, phase_request("warm"), trusted_receipt_index=FakeTrustedIndex([receipt])
        )
        self.assertEqual(result["member_lifetime_hwm_sum_upper_bound_bytes"], 80 * 1024 * 1024)
        self.assertEqual(result["coalition_phys_footprint_bytes_diagnostic_only"], 999 * 1024 * 1024)
        self.assertFalse(result["evidence"]["coalition_instantaneous_phys_footprint_used_for_gate"])


class ScheduleAndTrustTests(unittest.TestCase):
    def assert_artifact_rejected(self, artifact, receipt, pattern):
        receipt = make_receipt(
            artifact,
            cold=receipt.get("cold_new_launch_coalition") is True,
            scrub_deliveries=receipt.get("scrub_deliveries", []),
        )
        with self.assertRaisesRegex(metrics.PhaseMetricsError, pattern):
            metrics.reduce_phase(
                artifact, phase_request("warm"), trusted_receipt_index=FakeTrustedIndex([receipt])
            )

    def test_plain_mapping_is_not_a_trust_index(self):
        artifact, receipt = make_artifact()
        with self.assertRaisesRegex(metrics.PhaseMetricsError, "TrustedReceiptIndex"):
            metrics.reduce_phase(
                artifact,
                phase_request("warm"),
                trusted_receipt_index={(receipt["receipt_id"], receipt["raw_artifact_sha256"]): receipt},
            )

    def test_missing_authenticated_receipt_fails_closed(self):
        artifact, _ = make_artifact()
        with self.assertRaisesRegex(metrics.PhaseMetricsError, "absent"):
            metrics.reduce_phase(
                artifact, phase_request("warm"), trusted_receipt_index=FakeTrustedIndex()
            )

    def test_receipt_requires_immutable_digest_and_tool_identity(self):
        artifact, receipt = make_artifact()
        receipt["producer_tool_identity"] = "invented-tool"
        with self.assertRaisesRegex(metrics.PhaseMetricsError, "digest"):
            metrics.reduce_phase(
                artifact, phase_request("warm"), trusted_receipt_index=FakeTrustedIndex([receipt])
            )

    def test_query_must_have_nonzero_bounded_duration(self):
        artifact, receipt = make_artifact()
        artifact["records"][4]["query_finished_monotonic_ns"] = artifact["records"][4]["query_started_monotonic_ns"]
        self.assert_artifact_rejected(artifact, receipt, "nonzero")
        artifact, receipt = make_artifact()
        artifact["records"][4]["query_finished_monotonic_ns"] += metrics.MAX_QUERY_DURATION_NS
        self.assert_artifact_rejected(artifact, receipt, "maximum duration")

    def test_early_late_and_overlapping_queries_fail(self):
        artifact, receipt = make_artifact()
        artifact["records"][4]["query_started_monotonic_ns"] = artifact["records"][4]["scheduled_monotonic_ns"] - 1
        self.assert_artifact_rejected(artifact, receipt, "before its deadline")
        artifact, receipt = make_artifact()
        artifact["records"][4]["query_started_monotonic_ns"] = artifact["records"][4]["scheduled_monotonic_ns"] + metrics.MAX_CAPTURE_LATENESS_NS + 1
        artifact["records"][4]["query_finished_monotonic_ns"] = artifact["records"][4]["query_started_monotonic_ns"] + 1
        self.assert_artifact_rejected(artifact, receipt, "deadline lateness")
        artifact, receipt = make_artifact()
        artifact["records"][4]["query_started_monotonic_ns"] = artifact["records"][3]["query_finished_monotonic_ns"] - 1
        artifact["records"][4]["query_finished_monotonic_ns"] = artifact["records"][4]["query_started_monotonic_ns"] + 1
        self.assert_artifact_rejected(artifact, receipt, "overlap")

    def test_burst_or_catchup_schedule_fails(self):
        artifact, receipt = make_artifact()
        artifact["records"][4]["query_started_monotonic_ns"] = artifact["records"][3]["query_started_monotonic_ns"] + 3_000_000
        artifact["records"][4]["query_finished_monotonic_ns"] = artifact["records"][4]["query_started_monotonic_ns"] + 1
        self.assert_artifact_rejected(artifact, receipt, "burst or catch-up")

    def test_scope_lifecycle_must_cover_outer_brackets(self):
        artifact, receipt = make_artifact()
        receipt["scope_lifecycle_started_monotonic_ns"] = BASE
        receipt["immutable_receipt_digest_sha256"] = metrics.compute_immutable_receipt_digest_sha256(receipt)
        with self.assertRaisesRegex(metrics.PhaseMetricsError, "scope lifecycle|outer brackets"):
            metrics.reduce_phase(
                artifact, phase_request("warm"), trusted_receipt_index=FakeTrustedIndex([receipt])
            )


class CoalitionLifecycleTests(unittest.TestCase):
    def test_transient_exited_helper_cpu_and_memory_are_retained(self):
        artifact, receipt = make_artifact(transient=True, tick_step=2_000_000)
        request = phase_request(
            "warm", start=BASE + 200_000_000, end=BASE + 500_000_000
        )
        receipt = make_receipt(artifact, phase_requests=[request])
        result = metrics.reduce_phase(
            artifact,
            request,
            trusted_receipt_index=FakeTrustedIndex([receipt]),
        )
        self.assertEqual(
            result["member_lifetime_hwm_sum_upper_bound_bytes"], 110 * 1024 * 1024
        )
        self.assertEqual(len(result["member_memory_upper_bound_contributors"]), 2)
        helper = result["member_memory_upper_bound_contributors"][1]
        self.assertIn("final proc rusage", helper["source"])
        self.assertEqual(result["cpu_time_ns_exact"]["denominator"], 1)

    def test_tasks_started_delta_without_lifecycle_fails(self):
        artifact, receipt = make_artifact(transient=True)
        artifact["member_lifecycles"].pop()
        with self.assertRaisesRegex(metrics.PhaseMetricsError, "every coalition task"):
            metrics.reduce_phase(
                artifact, phase_request("warm"), trusted_receipt_index=FakeTrustedIndex([receipt])
            )

    def test_helper_born_and_exited_between_samples_is_final_rusage_accounted(self):
        artifact, _ = make_artifact(transient=True, tick_step=2_000_000)
        helper_lifecycle = artifact["member_lifecycles"][1]
        helper_lifecycle["started_monotonic_ns"] = (
            artifact["records"][4]["query_finished_monotonic_ns"] + 1
        )
        helper_lifecycle["exited_monotonic_ns"] = (
            artifact["records"][5]["query_started_monotonic_ns"] - 1
        )
        helper_lifecycle["final_rusage"] = final_rusage(
            helper_member(),
            hwm=30 * 1024 * 1024,
            start=helper_lifecycle["exited_monotonic_ns"] - 2_000_000,
            finish=helper_lifecycle["exited_monotonic_ns"] - 1,
        )
        for record in artifact["records"][5:]:
            record["tasks_exited"] = 1
            record["active_count"] = 1
            record["live_members"] = [live_identity(app_member())]
        receipt = make_receipt(artifact)
        result = metrics.reduce_phase(
            artifact,
            phase_request("warm"),
            trusted_receipt_index=FakeTrustedIndex([receipt]),
        )
        self.assertEqual(
            result["member_lifetime_hwm_sum_upper_bound_bytes"],
            110 * 1024 * 1024,
        )
        helper_proof = result["member_memory_upper_bound_contributors"][1]
        self.assertEqual(
            helper_proof["final_rusage_receipt_sha256"],
            helper_lifecycle["final_rusage"]["final_rusage_receipt_sha256"],
        )

    def test_tasks_exited_delta_without_final_rusage_fails(self):
        artifact, receipt = make_artifact(transient=True)
        artifact["member_lifecycles"][1]["final_rusage"] = None
        with self.assertRaisesRegex(metrics.PhaseMetricsError, "final rusage"):
            metrics.reduce_phase(
                artifact, phase_request("warm"), trusted_receipt_index=FakeTrustedIndex([receipt])
            )

    def test_exited_final_rusage_must_be_terminal(self):
        artifact, receipt = make_artifact(transient=True)
        artifact["member_lifecycles"][1]["final_rusage"][
            "no_memory_activity_after_query"
        ] = False
        with self.assertRaisesRegex(metrics.PhaseMetricsError, "not proven terminal"):
            metrics.reduce_phase(
                artifact,
                phase_request("warm"),
                trusted_receipt_index=FakeTrustedIndex([receipt]),
            )

    def test_exited_final_rusage_cannot_drop_sampled_lifetime_hwm(self):
        artifact, receipt = make_artifact(transient=True)
        for record in artifact["records"][5:8]:
            for member in record["live_members"]:
                if member["role"] == "decoder_helper":
                    member[
                        "proc_rusage_lifetime_max_phys_footprint_bytes"
                    ] = 40 * 1024 * 1024
        with self.assertRaisesRegex(metrics.PhaseMetricsError, "below its sampled"):
            metrics.reduce_phase(
                artifact,
                phase_request("warm"),
                trusted_receipt_index=FakeTrustedIndex([receipt]),
            )

    def test_active_count_and_live_identities_are_reconciled(self):
        artifact, receipt = make_artifact(transient=True)
        artifact["records"][6]["active_count"] = 1
        with self.assertRaisesRegex(metrics.PhaseMetricsError, "active_count"):
            metrics.reduce_phase(
                artifact, phase_request("warm"), trusted_receipt_index=FakeTrustedIndex([receipt])
            )

    def test_exec_transition_ambiguity_fails_receipt_contract(self):
        artifact, receipt = make_artifact()
        receipt["exec_transition_accounting_validated"] = False
        receipt["immutable_receipt_digest_sha256"] = metrics.compute_immutable_receipt_digest_sha256(receipt)
        with self.assertRaisesRegex(metrics.PhaseMetricsError, "transient-complete"):
            metrics.reduce_phase(
                artifact, phase_request("warm"), trusted_receipt_index=FakeTrustedIndex([receipt])
            )


class ColdTests(unittest.TestCase):
    def test_cold_allows_absent_prelaunch_pid_and_subtracts_same_scope_nonzero_baseline(self):
        artifact, receipt = make_artifact(cold=True, tick_step=4_000_000)
        artifact["records"][0]["coalition_cpu_time_ticks"] = 8_000_000
        for index, record in enumerate(artifact["records"]):
            record["coalition_cpu_time_ticks"] = 8_000_000 + index * 4_000_000
        receipt = make_receipt(artifact, cold=True)
        result = metrics.reduce_phase(
            artifact, phase_request("cold"), trusted_receipt_index=FakeTrustedIndex([receipt])
        )
        self.assertEqual(result["baseline_record_index"], 1)
        self.assertEqual(result["cpu_time_ns_exact"]["numerator"], 44_000_000)

    def test_cold_requires_uncontaminated_new_app_free_coalition(self):
        for field in (
            "cold_scope_no_prior_workload_contamination",
            "cold_new_launch_coalition",
            "cold_no_preexisting_app",
        ):
            artifact, receipt = make_artifact(cold=True)
            receipt[field] = False
            receipt["immutable_receipt_digest_sha256"] = metrics.compute_immutable_receipt_digest_sha256(receipt)
            with self.subTest(field=field), self.assertRaises(metrics.PhaseMetricsError):
                metrics.reduce_phase(
                    artifact, phase_request("cold"), trusted_receipt_index=FakeTrustedIndex([receipt])
                )

    def test_cold_baseline_with_tasks_is_contamination(self):
        artifact, _ = make_artifact(cold=True)
        artifact["records"][1]["tasks_started"] = 1
        artifact["records"][1]["active_count"] = 1
        artifact["records"][1]["live_members"] = [live_identity(app_member())]
        receipt = make_receipt(artifact, cold=True)
        with self.assertRaisesRegex(metrics.PhaseMetricsError, "prelaunch coalition|retained member start"):
            metrics.reduce_phase(
                artifact, phase_request("cold"), trusted_receipt_index=FakeTrustedIndex([receipt])
            )

    def test_unauthenticated_event_bounds_fail_even_with_authentic_raw_artifact(self):
        artifact, receipt = make_artifact(cold=True)
        forged = phase_request(
            "cold", start=BASE + 1, end=BASE + 400_000_000
        )
        with self.assertRaisesRegex(metrics.PhaseMetricsError, "event identity"):
            metrics.reduce_phase(
                artifact, forged, trusted_receipt_index=FakeTrustedIndex([receipt])
            )


class ScrubTests(unittest.TestCase):
    def test_two_ordered_legs_and_rolling_proof_include_boundary_epsilon(self):
        request = scrub_request()
        artifact, receipt = make_artifact(
            run_id="scrub-1",
            tick_step=1_000_000,
            scrub_deliveries=deliveries(request),
        )
        result = metrics.reduce_scrub(
            artifact, request, trusted_receipt_index=FakeTrustedIndex([receipt])
        )
        self.assertEqual(result["gesture_count"], 2)
        self.assertEqual([item["direction"] for item in result["gestures"]], ["forward", "reverse"])
        proof_starts = {
            proof["window_start_monotonic_ns"]
            for proof in result["gestures"][0]["rolling_window_proofs"]
        }
        self.assertIn(BASE + 50_000_000, proof_starts)
        self.assertIn(BASE + 50_000_001, proof_starts)
        self.assertEqual(result["gestures"][0]["rolling_window_ns"], 250_000_000)

    def test_rolling_conservative_attribution_catches_edge_burst(self):
        request = scrub_request()
        artifact, _ = make_artifact(
            run_id="scrub-burst", tick_step=0, scrub_deliveries=deliveries(request)
        )
        for index, record in enumerate(artifact["records"]):
            if index >= 7:
                record["coalition_cpu_time_ticks"] += 62_500_001
        receipt = make_receipt(artifact, scrub_deliveries=deliveries(request))
        result = metrics.reduce_scrub(
            artifact, request, trusted_receipt_index=FakeTrustedIndex([receipt])
        )
        maximum = result["gestures"][0]["rolling_cpu_max_percent_exact"]
        self.assertGreater(maximum["numerator"] / maximum["denominator"], 25.0)

    def test_rolling_exact_25_boundary_passes_and_plus_epsilon_fails_gate(self):
        warm, cold, startup_receipt = startup_pair(
            warm_tick=2_000_000, cold_tick=2_000_000
        )
        steady, steady_receipt = reduced_phase("steady", run_id="steady-1", tick_step=1_000_000)
        request = scrub_request()
        artifact, _ = make_artifact(run_id="scrub-1", tick_step=0, scrub_deliveries=deliveries(request))
        for index, record in enumerate(artifact["records"]):
            if index >= 7:
                record["coalition_cpu_time_ticks"] += 62_500_000
        scrub_receipt = make_receipt(artifact, scrub_deliveries=deliveries(request))
        scrub = metrics.reduce_scrub(artifact, request, trusted_receipt_index=FakeTrustedIndex([scrub_receipt]))
        index = FakeTrustedIndex([startup_receipt, steady_receipt, scrub_receipt])
        report = metrics.evaluate_variant_gates(
            VARIANT,
            candidate_id=CANDIDATE,
            asset_sha256=ASSET,
            warm_runs=[warm],
            cold_runs=[cold],
            steady_runs=[steady],
            scrub_runs=[scrub],
            trusted_receipt_index=index,
        )
        self.assertTrue(report["gates"]["scrub_each_250ms_window_at_most_25_percent"])
        plus = copy.deepcopy(artifact)
        for record in plus["records"][7:]:
            record["coalition_cpu_time_ticks"] += 1
        plus_receipt = make_receipt(plus, scrub_deliveries=deliveries(request))
        plus_scrub = metrics.reduce_scrub(plus, request, trusted_receipt_index=FakeTrustedIndex([plus_receipt]))
        plus_index = FakeTrustedIndex([startup_receipt, steady_receipt, plus_receipt])
        plus_report = metrics.evaluate_variant_gates(
            VARIANT,
            candidate_id=CANDIDATE,
            asset_sha256=ASSET,
            warm_runs=[warm],
            cold_runs=[cold],
            steady_runs=[steady],
            scrub_runs=[plus_scrub],
            trusted_receipt_index=plus_index,
        )
        self.assertFalse(plus_report["gates"]["scrub_each_250ms_window_at_most_25_percent"])

    def test_scrub_rejects_overlap_direction_and_delivery_splice(self):
        request = scrub_request()
        artifact, receipt = make_artifact(scrub_deliveries=deliveries(request))
        for mutation, pattern in (
            (("gestures", 1, "start_monotonic_ns", BASE + 400_000_000), "overlap"),
            (("gestures", 0, "direction", "reverse"), "ordered"),
            (("gestures", 1, "delivery_evidence_id", "delivery-forward"), "distinct"),
        ):
            changed = copy.deepcopy(request)
            _, index, key, value = mutation
            changed["gestures"][index][key] = value
            with self.subTest(pattern=pattern), self.assertRaisesRegex(metrics.PhaseMetricsError, pattern):
                metrics.reduce_scrub(
                    artifact, changed, trusted_receipt_index=FakeTrustedIndex([receipt])
                )
        changed = copy.deepcopy(request)
        changed["request_id"] = "forged-scrub-request"
        with self.assertRaisesRegex(metrics.PhaseMetricsError, "authenticated"):
            metrics.reduce_scrub(
                artifact, changed, trusted_receipt_index=FakeTrustedIndex([receipt])
            )

    def test_scrub_requires_same_exact_member_set_across_both_legs(self):
        request = scrub_request()
        artifact, receipt = make_artifact(
            transient=True,
            scrub_deliveries=deliveries(request),
        )
        with self.assertRaisesRegex(metrics.PhaseMetricsError, "same exact"):
            metrics.reduce_scrub(
                artifact, request, trusted_receipt_index=FakeTrustedIndex([receipt])
            )


class EvaluatorTests(unittest.TestCase):
    def bundles(self, *, warm_tick=2_000_000, cold_tick=10_000_000, memory=80 * 1024 * 1024):
        warm, cold, startup_receipt = startup_pair(
            warm_tick=warm_tick, cold_tick=cold_tick, memory_bytes=memory
        )
        steady, sr = reduced_phase("steady", run_id="steady-1", tick_step=1_000_000, memory_bytes=memory)
        scrub, scr = reduced_scrub(tick_step=1_000_000)
        return (warm, cold, steady, scrub), FakeTrustedIndex(
            [startup_receipt, sr, scr]
        )

    def evaluate(self, bundles, index):
        warm, cold, steady, scrub = bundles
        return metrics.evaluate_variant_gates(
            VARIANT,
            candidate_id=CANDIDATE,
            asset_sha256=ASSET,
            warm_runs=[warm],
            cold_runs=[cold],
            steady_runs=[steady],
            scrub_runs=[scrub],
            trusted_receipt_index=index,
        )

    def test_report_replays_raw_and_retains_cold_cpu_and_steady_memory(self):
        bundles, index = self.bundles()
        report = self.evaluate(bundles, index)
        self.assertTrue(report["eligible"])
        self.assertIn("cold_cpu_percent", report["distributions"])
        self.assertIn(
            "steady",
            report["distributions"]["member_lifetime_hwm_sum_upper_bound_bytes_by_phase"],
        )
        self.assertEqual(report["threshold_policy_version"], metrics.THRESHOLD_POLICY_VERSION)
        self.assertEqual(len(report["report_sha256"]), 64)
        self.assertEqual(
            report["replayed_reduction_sha256s"]["warm"],
            [bundles[0]["reduction_sha256"]],
        )

    def test_mutating_derived_cpu_memory_or_bounds_fails_replay(self):
        for path, value in (
            (("cpu_time_ns_exact", "numerator"), 0),
            (("hard_gate_memory_upper_bound_bytes",), 0),
            (("start_monotonic_ns",), BASE + 1),
        ):
            bundles, index = self.bundles()
            warm = copy.deepcopy(bundles[0])
            target = warm
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = value
            changed = (warm, *bundles[1:])
            with self.subTest(path=path), self.assertRaisesRegex(metrics.PhaseMetricsError, "replay"):
                self.evaluate(changed, index)

    def test_recomputing_output_digest_does_not_authorize_derived_tampering(self):
        bundles, index = self.bundles()
        warm = copy.deepcopy(bundles[0])
        warm["cpu_time_ns_exact"]["numerator"] = 0
        body = dict(warm)
        body.pop("reduction_sha256")
        warm["reduction_sha256"] = digest(body)
        with self.assertRaisesRegex(metrics.PhaseMetricsError, "replay"):
            self.evaluate((warm, *bundles[1:]), index)

    def test_mutating_scrub_rolling_value_fails_replay(self):
        bundles, index = self.bundles()
        scrub = copy.deepcopy(bundles[3])
        scrub["gestures"][0]["rolling_cpu_max_percent_exact"] = {"numerator": 0, "denominator": 1}
        with self.assertRaisesRegex(metrics.PhaseMetricsError, "replay"):
            self.evaluate((*bundles[:3], scrub), index)

    def test_digest_rewrite_cannot_authenticate_mutated_raw(self):
        bundles, index = self.bundles()
        warm = copy.deepcopy(bundles[0])
        warm["raw_artifact"]["records"][5]["coalition_cpu_time_ticks"] += 1
        body = dict(warm)
        body.pop("reduction_sha256")
        warm["reduction_sha256"] = digest(body)
        with self.assertRaisesRegex(metrics.PhaseMetricsError, "absent"):
            self.evaluate((warm, *bundles[1:]), index)

    def test_cold_raw_record_delete_and_receipt_scope_splice_fail_closed(self):
        bundles, index = self.bundles()
        cold = copy.deepcopy(bundles[1])
        cold["raw_artifact"]["records"].pop(4)
        body = dict(cold)
        body.pop("reduction_sha256")
        cold["reduction_sha256"] = digest(body)
        with self.assertRaises(metrics.PhaseMetricsError):
            self.evaluate((bundles[0], cold, bundles[2], bundles[3]), index)

        bundles, _ = self.bundles()
        raw = bundles[1]["raw_artifact"]
        _, wrong_receipt = make_artifact(run_id="wrong-scope")
        malicious_index = FakeTrustedIndex()
        malicious_index.receipts[(raw["receipt_id"], metrics.compute_raw_artifact_sha256(raw))] = wrong_receipt
        with self.assertRaisesRegex(metrics.PhaseMetricsError, "different raw evidence"):
            self.evaluate(bundles, malicious_index)

    def test_warm_strict_10_and_total_25_boundaries(self):
        warm, cold, startup_receipt = startup_pair(
            warm_total_ns=25_000_000, cold_total_ns=100_000_000
        )
        steady, steady_receipt = reduced_phase(
            "steady", run_id="steady-1", tick_step=1_000_000
        )
        scrub, scrub_receipt = reduced_scrub()
        bundles = (warm, cold, steady, scrub)
        index = FakeTrustedIndex(
            [startup_receipt, steady_receipt, scrub_receipt]
        )
        report = self.evaluate(bundles, index)
        self.assertTrue(report["gates"]["warm_cpu_each_strictly_below_10_percent"])
        self.assertTrue(report["gates"]["warm_cpu_time_each_at_most_25_ms"])
        warm, cold, startup_receipt = startup_pair(
            warm_total_ns=25_000_001, cold_total_ns=100_000_000
        )
        bundles = (warm, cold, steady, scrub)
        index = FakeTrustedIndex(
            [startup_receipt, steady_receipt, scrub_receipt]
        )
        report = self.evaluate(bundles, index)
        self.assertFalse(report["gates"]["warm_cpu_time_each_at_most_25_ms"])
        warm, cold, startup_receipt = startup_pair(
            warm_total_ns=50_000_000, cold_total_ns=100_000_000
        )
        report = self.evaluate(
            (warm, cold, steady, scrub),
            FakeTrustedIndex([startup_receipt, steady_receipt, scrub_receipt]),
        )
        self.assertFalse(report["gates"]["warm_cpu_each_strictly_below_10_percent"])
        warm, cold, startup_receipt = startup_pair(
            warm_total_ns=49_999_999, cold_total_ns=100_000_000
        )
        report = self.evaluate(
            (warm, cold, steady, scrub),
            FakeTrustedIndex([startup_receipt, steady_receipt, scrub_receipt]),
        )
        self.assertTrue(report["gates"]["warm_cpu_each_strictly_below_10_percent"])

    def test_steady_and_scrub_strict_10_boundaries(self):
        warm, cold, startup_receipt = startup_pair(
            warm_total_ns=20_000_000, cold_total_ns=100_000_000
        )
        steady, steady_receipt = exact_phase_bundle(
            "steady", run_id="steady-1", total_cpu_ns=50_000_000
        )
        scrub, scrub_receipt = exact_scrub_bundle(
            run_id="scrub-1", total_cpu_ns_each_leg=49_999_999
        )
        report = self.evaluate(
            (warm, cold, steady, scrub),
            FakeTrustedIndex([startup_receipt, steady_receipt, scrub_receipt]),
        )
        self.assertFalse(
            report["gates"]["steady_cpu_each_strictly_below_10_percent"]
        )
        self.assertTrue(
            report["gates"]["scrub_each_leg_strictly_below_10_percent"]
        )
        steady, steady_receipt = exact_phase_bundle(
            "steady", run_id="steady-1", total_cpu_ns=49_999_999
        )
        scrub, scrub_receipt = exact_scrub_bundle(
            run_id="scrub-1", total_cpu_ns_each_leg=50_000_000
        )
        report = self.evaluate(
            (warm, cold, steady, scrub),
            FakeTrustedIndex([startup_receipt, steady_receipt, scrub_receipt]),
        )
        self.assertTrue(
            report["gates"]["steady_cpu_each_strictly_below_10_percent"]
        )
        self.assertFalse(
            report["gates"]["scrub_each_leg_strictly_below_10_percent"]
        )

    def test_memory_is_strictly_below_300_mib(self):
        bundles, index = self.bundles(memory=300 * 1024 * 1024)
        report = self.evaluate(bundles, index)
        self.assertFalse(report["gates"]["memory_every_member_lifetime_hwm_sum_strictly_below_limit"])
        bundles, index = self.bundles()
        with self.assertRaisesRegex(metrics.PhaseMetricsError, "fixes the strict"):
            metrics.evaluate_variant_gates(
                VARIANT,
                candidate_id=CANDIDATE,
                asset_sha256=ASSET,
                warm_runs=[bundles[0]],
                cold_runs=[bundles[1]],
                steady_runs=[bundles[2]],
                scrub_runs=[bundles[3]],
                trusted_receipt_index=index,
                memory_limit_bytes=metrics.DEFAULT_MEMORY_LIMIT_BYTES + 1,
            )

    def cold_distribution_report(self, cold_totals):
        warm_runs = []
        cold_runs = []
        receipts = []
        for index, total in enumerate(cold_totals):
            warm, cold, receipt = startup_pair(
                run_id=f"startup-{index}",
                warm_total_ns=20_000_000,
                cold_total_ns=total,
            )
            warm_runs.append(warm)
            cold_runs.append(cold)
            receipts.append(receipt)
        steady, steady_receipt = reduced_phase(
            "steady", run_id="steady-distribution", tick_step=1_000_000
        )
        scrub, scrub_receipt = reduced_scrub(run_id="scrub-distribution")
        return metrics.evaluate_variant_gates(
            VARIANT,
            candidate_id=CANDIDATE,
            asset_sha256=ASSET,
            warm_runs=warm_runs,
            cold_runs=cold_runs,
            steady_runs=[steady],
            scrub_runs=[scrub],
            trusted_receipt_index=FakeTrustedIndex(
                receipts + [steady_receipt, scrub_receipt]
            ),
        )

    def test_cold_p95_and_max_exact_boundaries_and_plus_epsilon(self):
        report = self.cold_distribution_report(
            [250_000_000] * 20 + [500_000_000]
        )
        self.assertTrue(report["gates"]["cold_cpu_p95_at_most_250_ms"])
        self.assertTrue(report["gates"]["cold_cpu_max_at_most_500_ms"])
        report = self.cold_distribution_report(
            [250_000_000] * 19 + [250_000_001, 500_000_000]
        )
        self.assertFalse(report["gates"]["cold_cpu_p95_at_most_250_ms"])
        self.assertTrue(report["gates"]["cold_cpu_max_at_most_500_ms"])
        report = self.cold_distribution_report(
            [250_000_000] * 20 + [500_000_001]
        )
        self.assertTrue(report["gates"]["cold_cpu_p95_at_most_250_ms"])
        self.assertFalse(report["gates"]["cold_cpu_max_at_most_500_ms"])

    def test_valid_cold_warm_pair_shares_run_scope_and_app(self):
        bundles, index = self.bundles()
        self.assertTrue(self.evaluate(bundles, index)["eligible"])

    def test_cross_pair_or_duplicate_startup_run_is_rejected(self):
        bundles, index = self.bundles()
        cold = copy.deepcopy(bundles[1])
        cold["app_process_identity"]["pid"] += 1
        with self.assertRaisesRegex(metrics.PhaseMetricsError, "replay"):
            self.evaluate((bundles[0], cold, bundles[2], bundles[3]), index)
        warm_a, _, receipt_a = startup_pair(
            run_id="startup-1", warm_total_ns=20_000_000, cold_total_ns=100_000_000
        )
        _, cold_b, receipt_b = startup_pair(
            run_id="startup-1", warm_total_ns=20_000_000, cold_total_ns=100_000_001
        )
        spliced_index = FakeTrustedIndex(
            [receipt_a, receipt_b]
            + [
                value
                for value in index.receipts.values()
                if value["run_id"] != "startup-1"
            ]
        )
        with self.assertRaisesRegex(metrics.PhaseMetricsError, "one retained"):
            self.evaluate(
                (warm_a, cold_b, bundles[2], bundles[3]), spliced_index
            )
        with self.assertRaisesRegex(metrics.PhaseMetricsError, "unique run IDs"):
            metrics.evaluate_variant_gates(
                VARIANT,
                candidate_id=CANDIDATE,
                asset_sha256=ASSET,
                warm_runs=[bundles[0], bundles[0]],
                cold_runs=[bundles[1], bundles[1]],
                steady_runs=[bundles[2]],
                scrub_runs=[bundles[3]],
                trusted_receipt_index=index,
            )

    def test_candidate_asset_and_policy_are_bound(self):
        bundles, index = self.bundles()
        with self.assertRaisesRegex(metrics.PhaseMetricsError, "identity"):
            metrics.evaluate_variant_gates(
                VARIANT,
                candidate_id="other-build",
                asset_sha256=ASSET,
                warm_runs=[bundles[0]],
                cold_runs=[bundles[1]],
                steady_runs=[bundles[2]],
                scrub_runs=[bundles[3]],
                trusted_receipt_index=index,
            )
        warm = copy.deepcopy(bundles[0])
        warm["threshold_policy_version"] = "old-policy"
        with self.assertRaisesRegex(metrics.PhaseMetricsError, "replay"):
            self.evaluate((warm, *bundles[1:]), index)


if __name__ == "__main__":
    unittest.main()
