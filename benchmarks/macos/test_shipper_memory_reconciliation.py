#!/usr/bin/env python3

import copy
import dataclasses
from collections import UserDict
import unittest

import shipper_memory_reconciliation as memory


RUN_ID = "123e4567-e89b-12d3-a456-426614174000"
ASSET_SHA256 = "ab" * 32
MIB = 1024 * 1024


class MemoryReconciliationTests(unittest.TestCase):
    def setUp(self):
        self.binding = memory.MemoryBinding(
            run_id=RUN_ID,
            process_id=4242,
            process_start_abstime=987654321,
            source_key=73,
            asset_sha256=ASSET_SHA256,
            candidate_id="candidate-release-42",
        )
        self.bounds = memory.PhaseBounds(1_000_000_000, 5_000_000_000)
        self.close = memory.PhaseCloseBinding(
            epoch_id="epoch-steady-1",
            epoch_generation=9,
            phase_end_barrier_id="phase-end-barrier-9",
            work_sequence_at_phase_end=71,
        )
        self.processes = (
            memory.CoalitionProcess(4242, 987654321, "app", 912),
            memory.CoalitionProcess(5000, 987654400, "decoder_helper", 912),
        )
        self.provider = memory.OSProviderProvenance(
            provider_id="proc-pid-rusage-provider",
            provider_executable_sha256="33" * 32,
            provider_audit_token_sha256="44" * 32,
            api_name="proc_pid_rusage-v4",
            api_version=4,
        )
        self.baseline_categories = self._categories(
            snapshot_id="baseline-snapshot", sequence=1, baseline=True
        )
        self.end_categories = self._categories(
            snapshot_id="end-snapshot", sequence=2, baseline=False
        )
        self.native_evidence = self._native_evidence()
        self.os_evidence = self._os_evidence()
        self.native_receipt = self._native_receipt(self.native_evidence)
        self.os_receipt = self._os_receipt(self.os_evidence)

    def _categories(self, *, snapshot_id, sequence, baseline):
        common = {
            "epoch_id": self.close.epoch_id,
            "snapshot_id": snapshot_id,
            "checkpoint_sequence": sequence,
        }

        def pair(current, hwm):
            return current, current if baseline else hwm

        values = {
            "surface": pair(20 * MIB, 90 * MIB),
            "source": pair(4 * MIB, 80 * MIB),
            "dispatcher": pair(2 * MIB, 70 * MIB),
            "live": pair(8 * MIB, 60 * MIB),
            "decoder_inflight": pair(4 * MIB, 50 * MIB),
            "decoder_pending": pair(2 * MIB, 40 * MIB),
            "copy": pair(4 * MIB, 30 * MIB),
            "preview_staged": pair(2 * MIB, 20 * MIB),
            "preview_inflight": pair(2 * MIB, 18 * MIB),
            "retained": pair(1 * MIB, 15 * MIB),
            "ring": pair(1 * MIB, 14 * MIB),
            "resources": pair(4 * MIB, 13 * MIB),
            "retirement": pair(1 * MIB, 12 * MIB),
            "quarantine": pair(1 * MIB, 11 * MIB),
        }

        def facts(**items):
            return {**common, **items}

        return {
            "surface": facts(
                current_bytes=values["surface"][0],
                diagnostic_hwm_bytes=values["surface"][1],
                current_count=3,
                diagnostic_hwm_count=3 if baseline else 4,
            ),
            "source_staged_payload": facts(
                current_bytes=values["source"][0],
                diagnostic_hwm_bytes=values["source"][1],
            ),
            "dispatcher_pending_payload": facts(
                current_bytes=values["dispatcher"][0],
                diagnostic_hwm_bytes=values["dispatcher"][1],
            ),
            "decoder": facts(
                live_current_bytes=values["live"][0],
                live_diagnostic_hwm_bytes=values["live"][1],
                inflight_current_bytes=values["decoder_inflight"][0],
                inflight_diagnostic_hwm_bytes=values["decoder_inflight"][1],
                pending_current_bytes=values["decoder_pending"][0],
                pending_diagnostic_hwm_bytes=values["decoder_pending"][1],
                copy_current_bytes=values["copy"][0],
                copy_diagnostic_hwm_bytes=values["copy"][1],
            ),
            "preview": facts(
                staged_current_bytes=values["preview_staged"][0],
                staged_diagnostic_hwm_bytes=values["preview_staged"][1],
                inflight_current_bytes=values["preview_inflight"][0],
                inflight_diagnostic_hwm_bytes=values["preview_inflight"][1],
            ),
            "audio": facts(
                retained_current_bytes=values["retained"][0],
                retained_diagnostic_hwm_bytes=values["retained"][1],
                ring_current_bytes=values["ring"][0],
                ring_diagnostic_hwm_bytes=values["ring"][1],
            ),
            "qt": facts(
                resources_current_count=12,
                resources_diagnostic_hwm_count=12 if baseline else 20,
                resources_current_bytes=values["resources"][0],
                resources_diagnostic_hwm_bytes=values["resources"][1],
                retirement_current_count=2,
                retirement_diagnostic_hwm_count=2 if baseline else 8,
                retirement_current_bytes=values["retirement"][0],
                retirement_diagnostic_hwm_bytes=values["retirement"][1],
                quarantine_current_count=1,
                quarantine_diagnostic_hwm_count=1 if baseline else 5,
                quarantine_current_bytes=values["quarantine"][0],
                quarantine_diagnostic_hwm_bytes=values["quarantine"][1],
            ),
        }

    def _native_evidence(self):
        return {
            "schema": memory.NATIVE_EVENT_SCHEMA,
            "binding": self.binding.as_dict(),
            "phase": "steady",
            "variant": "hevc-main10-mkv",
            "epoch_id": self.close.epoch_id,
            "epoch_generation": self.close.epoch_generation,
            "phase_started_monotonic_ns": self.bounds.started_monotonic_ns,
            "phase_ended_monotonic_ns": self.bounds.ended_monotonic_ns,
            "close_binding": self.close.as_dict(),
            "events": [
                {
                    "sequence": 0,
                    "kind": "epoch_reset",
                    "monotonic_ns": self.bounds.started_monotonic_ns,
                    "epoch_id": self.close.epoch_id,
                    "epoch_generation": self.close.epoch_generation,
                },
                {
                    "sequence": 1,
                    "kind": "phase_baseline",
                    "monotonic_ns": self.bounds.started_monotonic_ns,
                    "epoch_id": self.close.epoch_id,
                    "epoch_generation": self.close.epoch_generation,
                    "snapshot_id": "baseline-snapshot",
                    "aggregate_current_bytes": 56 * MIB,
                    "aggregate_native_hwm_bytes": 56 * MIB,
                    "barrier_id": "phase-start-barrier-9",
                    "work_sequence": 40,
                    "categories": copy.deepcopy(self.baseline_categories),
                },
                {
                    "sequence": 2,
                    "kind": "phase_end_checkpoint",
                    "monotonic_ns": self.bounds.ended_monotonic_ns + 10_000_000,
                    "epoch_id": self.close.epoch_id,
                    "epoch_generation": self.close.epoch_generation,
                    "snapshot_id": "end-snapshot",
                    "aggregate_current_bytes": 56 * MIB,
                    "aggregate_native_hwm_bytes": 112 * MIB,
                    "barrier_id": self.close.phase_end_barrier_id,
                    "work_sequence": self.close.work_sequence_at_phase_end,
                    "categories": copy.deepcopy(self.end_categories),
                },
            ],
        }

    def _rusage_row(
        self,
        process,
        *,
        current,
        lifetime_hwm,
        observation_id="coalition-query-1",
        started_ns=5_020_000_000,
        ended_ns=5_029_000_000,
    ):
        return {
            **process.as_dict(),
            "observation_id": observation_id,
            "query_started_monotonic_ns": started_ns,
            "query_ended_monotonic_ns": ended_ns,
            "query_status": 0,
            **self.provider.as_dict(),
            "current_phys_footprint_bytes": current,
            "lifetime_max_phys_footprint_bytes": lifetime_hwm,
        }

    def _os_evidence(self):
        return {
            "schema": memory.OS_REDUCER_SCHEMA,
            "receipt_id": "os-receipt-1",
            "binding": self.binding.as_dict(),
            "phase": "steady",
            "variant": "hevc-main10-mkv",
            "close_binding": self.close.as_dict(),
            "window": self.bounds.as_dict(),
            "coalition_id": 912,
            "processes": [process.as_dict() for process in self.processes],
            "provider": self.provider.as_dict(),
            "tasks_started_before": 2,
            "tasks_started_after": 2,
            "tasks_exited_before": 0,
            "tasks_exited_after": 0,
            "task_counters_started_monotonic_ns": self.bounds.started_monotonic_ns,
            "task_counters_ended_monotonic_ns": self.bounds.ended_monotonic_ns,
            "query": {
                "query_id": "coalition-query-1",
                "query_started_monotonic_ns": 5_020_000_000,
                "query_ended_monotonic_ns": 5_030_000_000,
                "query_status": 0,
                "epoch_id": self.close.epoch_id,
                "epoch_generation": self.close.epoch_generation,
                "phase_end_barrier_id": self.close.phase_end_barrier_id,
                "work_sequence_at_query_begin": self.close.work_sequence_at_phase_end,
                "work_sequence_at_query_end": self.close.work_sequence_at_phase_end,
                # Diagnostic only. The evaluator never gates on this scalar.
                "coalition_current_footprint_bytes": 140 * MIB,
                "members": [
                    self._rusage_row(
                        self.processes[0], current=90 * MIB, lifetime_hwm=130 * MIB
                    ),
                    self._rusage_row(
                        self.processes[1], current=50 * MIB, lifetime_hwm=70 * MIB
                    ),
                ],
            },
            "lifecycle_receipt": None,
        }

    def _authenticate_native_mapping(self, retained):
        digest = memory._canonical_sha256(retained, "test native receipt")
        index = memory.TrustedExecutionIndex(
            "trusted-index-1",
            (
                memory.TrustedExecutionEntry(
                    "native_memory", retained["receipt_id"], digest
                ),
            ),
        )
        return memory.authenticate_native_receipt(
            retained, trusted_execution_index=index
        )

    def _native_receipt(self, evidence, **overrides):
        retained = {
            "schema": memory.NATIVE_RECEIPT_SCHEMA,
            "trusted_execution_index_id": "trusted-index-1",
            "receipt_id": "native-receipt-1",
            "producer_id": "wam-native-memory-producer",
            "producer_attestation_id": "attestation-native-1",
            "producer_executable_sha256": "11" * 32,
            "producer_audit_token_sha256": "22" * 32,
            "binding": self.binding.as_dict(),
            "phase": "steady",
            "variant": "hevc-main10-mkv",
            "epoch_id": self.close.epoch_id,
            "epoch_generation": self.close.epoch_generation,
            "phase_bounds": self.bounds.as_dict(),
            "event_count": len(evidence["events"]),
            "completed_checkpoint_sequence": 2,
            "event_sha256": memory.native_event_sha256(evidence),
            "allocation_contract_sha256": memory.ALLOCATION_CONTRACT_SHA256,
            "sealed_monotonic_ns": 5_040_000_000,
            "next_reset_monotonic_ns": 5_200_000_000,
            "next_reset_epoch_generation": self.close.epoch_generation + 1,
            "phase_end_barrier_id": self.close.phase_end_barrier_id,
            "work_sequence_at_phase_end": self.close.work_sequence_at_phase_end,
            "work_sequence_at_checkpoint": self.close.work_sequence_at_phase_end,
            "work_sequence_at_seal": self.close.work_sequence_at_phase_end,
        }
        retained.update(overrides)
        return self._authenticate_native_mapping(retained)

    def _authenticate_os_mapping(self, retained):
        digest = memory._canonical_sha256(retained, "test OS receipt")
        index = memory.TrustedExecutionIndex(
            "trusted-index-1",
            (
                memory.TrustedExecutionEntry(
                    "os_coalition_memory", retained["receipt_id"], digest
                ),
            ),
        )
        return memory.authenticate_os_receipt(
            retained, trusted_execution_index=index
        )

    def _os_receipt(self, evidence, **overrides):
        lifecycle = evidence["lifecycle_receipt"]
        lifecycle_sha = (
            memory._canonical_sha256(lifecycle, "test lifecycle receipt")
            if lifecycle is not None
            else None
        )
        query = evidence["query"]
        retained = {
            "schema": memory.OS_RECEIPT_SCHEMA,
            "trusted_execution_index_id": "trusted-index-1",
            "receipt_id": "os-receipt-1",
            "producer_id": "trusted-coalition-reducer",
            "producer_attestation_id": "attestation-os-1",
            "producer_executable_sha256": "33" * 32,
            "producer_audit_token_sha256": "44" * 32,
            "binding": self.binding.as_dict(),
            "phase": "steady",
            "variant": "hevc-main10-mkv",
            "close_binding": self.close.as_dict(),
            "phase_bounds": self.bounds.as_dict(),
            "coalition_id": 912,
            "processes": [process.as_dict() for process in self.processes],
            "provider": self.provider.as_dict(),
            "query_id": query["query_id"],
            "query_started_monotonic_ns": query["query_started_monotonic_ns"],
            "query_ended_monotonic_ns": query["query_ended_monotonic_ns"],
            "query_status": query["query_status"],
            "lifecycle_receipt_sha256": lifecycle_sha,
            "reducer_evidence_sha256": memory.os_reducer_evidence_sha256(evidence),
            "sealed_monotonic_ns": 5_040_000_000,
            "work_sequence_at_seal": self.close.work_sequence_at_phase_end,
        }
        retained.update(overrides)
        return self._authenticate_os_mapping(retained)

    def _trusted_index(self, native_receipt, os_receipt):
        return memory.TrustedExecutionIndex(
            "trusted-index-1",
            tuple(
                sorted(
                    (
                        memory.TrustedExecutionEntry(
                            "native_memory",
                            native_receipt.receipt_id,
                            native_receipt.retained_receipt_sha256,
                        ),
                        memory.TrustedExecutionEntry(
                            "os_coalition_memory",
                            os_receipt.receipt_id,
                            os_receipt.retained_receipt_sha256,
                        ),
                    )
                )
            ),
        )

    def validate(
        self,
        native=None,
        *,
        native_receipt=None,
        os_evidence=None,
        os_receipt=None,
        binding=None,
        bounds=None,
        close=None,
        processes=None,
        memory_limit_bytes=memory.DEFAULT_MEMORY_LIMIT_BYTES,
    ):
        selected_native = self.native_evidence if native is None else native
        selected_os = self.os_evidence if os_evidence is None else os_evidence
        selected_native_receipt = (
            self.native_receipt if native_receipt is None else native_receipt
        )
        selected_os_receipt = self.os_receipt if os_receipt is None else os_receipt
        index_native = (
            selected_native_receipt
            if isinstance(selected_native_receipt, memory.TrustedNativeProducerReceipt)
            else self.native_receipt
        )
        index_os = (
            selected_os_receipt
            if isinstance(selected_os_receipt, memory.TrustedOSCoalitionReceipt)
            else self.os_receipt
        )
        return memory.validate_memory_reconciliation(
            selected_native,
            trusted_native_receipt=selected_native_receipt,
            os_reducer_evidence=selected_os,
            trusted_os_receipt=selected_os_receipt,
            trusted_execution_index=self._trusted_index(index_native, index_os),
            expected_binding=self.binding if binding is None else binding,
            expected_phase="steady",
            expected_variant="hevc-main10-mkv",
            allowed_phase_bounds=self.bounds if bounds is None else bounds,
            expected_close_binding=self.close if close is None else close,
            expected_processes=self.processes if processes is None else processes,
            memory_limit_bytes=memory_limit_bytes,
        )

    def _valid_churn_evidence(self):
        evidence = copy.deepcopy(self.os_evidence)
        replacement = memory.CoalitionProcess(
            5001, 987654500, "decoder_helper", 912
        )
        evidence["tasks_started_after"] = 3
        evidence["tasks_exited_after"] = 1
        evidence["query"]["members"] = [
            copy.deepcopy(evidence["query"]["members"][0]),
            self._rusage_row(replacement, current=40 * MIB, lifetime_hwm=60 * MIB),
        ]
        lifecycle_id = "lifecycle-receipt-1"
        evidence["lifecycle_receipt"] = {
            "schema": memory.LIFECYCLE_RECEIPT_SCHEMA,
            "receipt_id": lifecycle_id,
            "binding": self.binding.as_dict(),
            "phase": "steady",
            "variant": "hevc-main10-mkv",
            "close_binding": self.close.as_dict(),
            "coalition_id": 912,
            "provider": self.provider.as_dict(),
            "tasks_started_before": 2,
            "tasks_started_after": 3,
            "tasks_exited_before": 0,
            "tasks_exited_after": 1,
            "task_counters_started_monotonic_ns": self.bounds.started_monotonic_ns,
            "task_counters_ended_monotonic_ns": self.bounds.ended_monotonic_ns,
            "events": [
                {
                    "sequence": 0,
                    "kind": "task_started",
                    "monotonic_ns": 2_000_000_000,
                    "member": replacement.as_dict(),
                    "final_rusage": None,
                },
                {
                    "sequence": 1,
                    "kind": "task_exited",
                    "monotonic_ns": 3_000_000_000,
                    "member": self.processes[1].as_dict(),
                    "final_rusage": self._rusage_row(
                        self.processes[1],
                        current=0,
                        lifetime_hwm=70 * MIB,
                        observation_id=f"{lifecycle_id}.exit.1",
                        started_ns=2_999_000_000,
                        ended_ns=3_001_000_000,
                    ),
                },
            ],
        }
        return evidence

    def test_complete_reconciliation_derives_conservative_member_sum_and_delta(self):
        report = self.validate()
        self.assertTrue(report.reconciliation_complete)
        self.assertTrue(report.evidence_pass)
        self.assertFalse(report.production_integration_authorized)
        self.assertFalse(report.gate_pass)
        self.assertFalse(report.eligible)
        self.assertEqual(report.os_conservative_member_hwm_sum_bytes, 200 * MIB)
        self.assertEqual(report.os_coalition_current_footprint_bytes, 140 * MIB)
        self.assertEqual(report.native_reconciled_peak_bytes, 112 * MIB)
        self.assertEqual(report.untracked_delta_bytes, 88 * MIB)
        self.assertEqual(report.os_distinct_member_count, 2)
        self.assertFalse(report.os_member_churn_observed)

    def test_independent_native_diagnostic_hwms_are_never_summed(self):
        report = self.validate()
        diagnostic_sum = sum(
            self.end_categories[category][hwm]
            for category, _current, hwm in memory._BYTE_PAIRS
        )
        self.assertGreater(diagnostic_sum, 500 * MIB)
        self.assertEqual(report.native_reconciled_peak_bytes, 112 * MIB)
        self.assertNotEqual(report.native_reconciled_peak_bytes, diagnostic_sum)

    def test_report_and_evaluation_context_are_deterministic_hashes(self):
        first = self.validate().as_dict()
        second = self.validate().as_dict()
        self.assertEqual(first, second)
        self.assertRegex(first["report_sha256"], r"^[0-9a-f]{64}$")
        changed = copy.deepcopy(self.os_evidence)
        changed["query"]["members"][1]["lifetime_max_phys_footprint_bytes"] += 1
        third = self.validate(
            os_evidence=changed, os_receipt=self._os_receipt(changed)
        ).as_dict()
        self.assertNotEqual(first["evaluation_context_sha256"], third["evaluation_context_sha256"])
        self.assertNotEqual(first["report_sha256"], third["report_sha256"])

    def test_zero_member_rows_and_forged_299_mib_scalar_fail(self):
        evidence = copy.deepcopy(self.os_evidence)
        evidence["query"]["coalition_current_footprint_bytes"] = 299 * MIB
        for row in evidence["query"]["members"]:
            row["current_phys_footprint_bytes"] = 0
            row["lifetime_max_phys_footprint_bytes"] = 0
        report = self.validate(os_evidence=evidence, os_receipt=self._os_receipt(evidence))
        self.assertFalse(report.reconciliation_complete)
        self.assertFalse(report.evidence_pass)
        self.assertIsNone(report.os_conservative_member_hwm_sum_bytes)
        self.assertEqual(report.os_coalition_current_footprint_bytes, 299 * MIB)

    def test_coalition_current_footprint_is_diagnostic_only(self):
        for diagnostic in (0, 1, 299 * MIB, 999 * MIB):
            with self.subTest(diagnostic=diagnostic):
                evidence = copy.deepcopy(self.os_evidence)
                evidence["query"]["coalition_current_footprint_bytes"] = diagnostic
                report = self.validate(
                    os_evidence=evidence, os_receipt=self._os_receipt(evidence)
                )
                self.assertTrue(report.evidence_pass)
                self.assertEqual(
                    report.os_conservative_member_hwm_sum_bytes, 200 * MIB
                )
                self.assertEqual(
                    report.os_coalition_current_footprint_bytes, diagnostic
                )

    def test_producer_authored_peak_scalar_is_not_in_the_closed_schema(self):
        evidence = copy.deepcopy(self.os_evidence)
        evidence["coalition_hard_peak_bytes"] = 1
        report = self.validate(os_evidence=evidence, os_receipt=self._os_receipt(evidence))
        self.assertFalse(report.evidence_pass)
        self.assertTrue(any("fields are not exact" in error for error in report.errors))
        receipt_mapping = self.os_receipt.as_dict()
        receipt_mapping["coalition_hard_peak_bytes"] = 299 * MIB
        digest = memory._canonical_sha256(receipt_mapping, "test receipt")
        index = memory.TrustedExecutionIndex(
            "trusted-index-1",
            (
                memory.TrustedExecutionEntry(
                    "os_coalition_memory", "os-receipt-1", digest
                ),
            ),
        )
        with self.assertRaisesRegex(memory.MemoryReconciliationError, "fields are not exact"):
            memory.authenticate_os_receipt(
                receipt_mapping, trusted_execution_index=index
            )

    def test_301_mib_fails_even_with_a_400_mib_override(self):
        evidence = copy.deepcopy(self.os_evidence)
        evidence["query"]["members"][0]["lifetime_max_phys_footprint_bytes"] = 231 * MIB
        receipt = self._os_receipt(evidence)
        report = self.validate(
            os_evidence=evidence,
            os_receipt=receipt,
            memory_limit_bytes=400 * MIB,
        )
        self.assertTrue(report.reconciliation_complete)
        self.assertEqual(report.os_conservative_member_hwm_sum_bytes, 301 * MIB)
        self.assertEqual(report.requested_memory_limit_bytes, 400 * MIB)
        self.assertEqual(report.effective_memory_limit_bytes, 300 * MIB)
        self.assertFalse(report.under_memory_limit)
        self.assertFalse(report.evidence_pass)

    def test_caller_can_tighten_but_not_widen_hard_ceiling(self):
        self.assertTrue(self.validate(memory_limit_bytes=201 * MIB).evidence_pass)
        self.assertFalse(self.validate(memory_limit_bytes=200 * MIB).evidence_pass)
        with self.assertRaisesRegex(memory.MemoryReconciliationError, "positive integer"):
            self.validate(memory_limit_bytes=True)

    def test_native_checkpoint_and_seal_45_seconds_late_fail_close_bound(self):
        native = copy.deepcopy(self.native_evidence)
        native["events"][2]["monotonic_ns"] = self.bounds.ended_monotonic_ns + 45_000_000_000
        receipt = self._native_receipt(
            native,
            sealed_monotonic_ns=self.bounds.ended_monotonic_ns + 45_010_000_000,
            next_reset_monotonic_ns=self.bounds.ended_monotonic_ns + 46_000_000_000,
        )
        report = self.validate(native, native_receipt=receipt)
        self.assertFalse(report.epoch_and_order_complete)
        self.assertFalse(report.evidence_pass)
        self.assertTrue(any("fixed close bound" in error for error in report.errors))

    def test_os_query_and_seal_45_seconds_late_fail_close_bound(self):
        evidence = copy.deepcopy(self.os_evidence)
        query = evidence["query"]
        query["query_started_monotonic_ns"] += 45_000_000_000
        query["query_ended_monotonic_ns"] += 45_000_000_000
        for row in query["members"]:
            row["query_started_monotonic_ns"] += 45_000_000_000
            row["query_ended_monotonic_ns"] += 45_000_000_000
        receipt = self._os_receipt(
            evidence, sealed_monotonic_ns=self.bounds.ended_monotonic_ns + 45_040_000_000
        )
        report = self.validate(os_evidence=evidence, os_receipt=receipt)
        self.assertFalse(report.evidence_pass)
        self.assertTrue(any("fixed phase-close bound" in error for error in report.errors))

    def test_bool_and_float_numeric_metadata_fail_strictly(self):
        cases = []
        boolean = copy.deepcopy(self.os_evidence)
        boolean["query"]["query_status"] = False
        cases.append(boolean)
        floating = copy.deepcopy(self.os_evidence)
        floating["query"]["epoch_generation"] = 9.0
        cases.append(floating)
        member_float = copy.deepcopy(self.os_evidence)
        member_float["query"]["members"][0]["lifetime_max_phys_footprint_bytes"] = float(130 * MIB)
        cases.append(member_float)
        for evidence in cases:
            with self.subTest(value=evidence["query"].get("query_status")):
                report = self.validate(os_evidence=evidence)
                self.assertFalse(report.evidence_pass)
        native = copy.deepcopy(self.native_evidence)
        native["events"][0]["sequence"] = False
        self.assertFalse(self.validate(native).evidence_pass)

    def test_task_churn_without_lifecycle_receipt_is_ineligible(self):
        evidence = copy.deepcopy(self.os_evidence)
        evidence["tasks_started_after"] = 3
        report = self.validate(os_evidence=evidence, os_receipt=self._os_receipt(evidence))
        self.assertTrue(report.os_member_churn_observed)
        self.assertFalse(report.evidence_pass)
        self.assertTrue(any("lifecycle/member/final-rusage" in error for error in report.errors))

    def test_task_counters_bind_exact_phase_and_active_member_cardinality(self):
        wrong_time = copy.deepcopy(self.os_evidence)
        wrong_time["task_counters_ended_monotonic_ns"] -= 1
        report = self.validate(
            os_evidence=wrong_time, os_receipt=self._os_receipt(wrong_time)
        )
        self.assertFalse(report.evidence_pass)
        wrong_count = copy.deepcopy(self.os_evidence)
        wrong_count["tasks_started_before"] = 3
        wrong_count["tasks_started_after"] = 3
        report = self.validate(
            os_evidence=wrong_count, os_receipt=self._os_receipt(wrong_count)
        )
        self.assertFalse(report.evidence_pass)
        self.assertTrue(any("active member sets" in error for error in report.errors))

    def test_valid_churn_uses_final_rusage_for_every_distinct_member(self):
        evidence = self._valid_churn_evidence()
        report = self.validate(os_evidence=evidence, os_receipt=self._os_receipt(evidence))
        self.assertTrue(report.reconciliation_complete)
        self.assertTrue(report.evidence_pass)
        self.assertTrue(report.os_member_churn_observed)
        self.assertEqual(report.os_distinct_member_count, 3)
        self.assertEqual(report.os_conservative_member_hwm_sum_bytes, 260 * MIB)

    def test_churn_final_rusage_or_event_count_cannot_be_omitted(self):
        evidence = self._valid_churn_evidence()
        evidence["lifecycle_receipt"]["events"][1]["final_rusage"] = None
        report = self.validate(os_evidence=evidence, os_receipt=self._os_receipt(evidence))
        self.assertFalse(report.evidence_pass)

        evidence = self._valid_churn_evidence()
        evidence["lifecycle_receipt"]["tasks_exited_after"] = 2
        report = self.validate(os_evidence=evidence, os_receipt=self._os_receipt(evidence))
        self.assertFalse(report.evidence_pass)

    def test_same_count_member_swap_without_lifecycle_is_ineligible(self):
        evidence = copy.deepcopy(self.os_evidence)
        replacement = memory.CoalitionProcess(5001, 987654500, "decoder_helper", 912)
        evidence["query"]["members"][1] = self._rusage_row(
            replacement, current=40 * MIB, lifetime_hwm=60 * MIB
        )
        report = self.validate(os_evidence=evidence, os_receipt=self._os_receipt(evidence))
        self.assertFalse(report.evidence_pass)
        self.assertTrue(any("member set changed" in error for error in report.errors))

    def test_every_member_row_binds_pid_start_role_and_coalition(self):
        changes = {
            "process_id": 6000,
            "process_start_abstime": 999999,
            "role": "app",
            "coalition_id": 913,
        }
        for field, value in changes.items():
            with self.subTest(field=field):
                evidence = copy.deepcopy(self.os_evidence)
                evidence["query"]["members"][1][field] = value
                report = self.validate(
                    os_evidence=evidence, os_receipt=self._os_receipt(evidence)
                )
                self.assertFalse(report.evidence_pass)

    def test_member_rows_bind_query_status_brackets_and_provider(self):
        mutations = []
        wrong_id = copy.deepcopy(self.os_evidence)
        wrong_id["query"]["members"][0]["observation_id"] = "other-query"
        mutations.append(wrong_id)
        late = copy.deepcopy(self.os_evidence)
        late["query"]["members"][0]["query_ended_monotonic_ns"] = 5_031_000_000
        mutations.append(late)
        failed = copy.deepcopy(self.os_evidence)
        failed["query"]["members"][0]["query_status"] = 5
        mutations.append(failed)
        provider = copy.deepcopy(self.os_evidence)
        provider["query"]["members"][0]["provider_id"] = "other-provider"
        mutations.append(provider)
        for evidence in mutations:
            report = self.validate(os_evidence=evidence, os_receipt=self._os_receipt(evidence))
            self.assertFalse(report.evidence_pass)

    def test_member_lifetime_hwm_must_cover_current(self):
        evidence = copy.deepcopy(self.os_evidence)
        evidence["query"]["members"][0]["lifetime_max_phys_footprint_bytes"] = 89 * MIB
        report = self.validate(os_evidence=evidence, os_receipt=self._os_receipt(evidence))
        self.assertFalse(report.evidence_pass)

    def test_receipt_and_evidence_hashes_prevent_peak_or_process_forgery(self):
        evidence = copy.deepcopy(self.os_evidence)
        evidence["query"]["members"][0]["lifetime_max_phys_footprint_bytes"] = 1
        report = self.validate(os_evidence=evidence)
        self.assertFalse(report.os_receipt_bound)
        self.assertFalse(report.evidence_pass)

    def test_run_pid_start_source_asset_and_candidate_are_exactly_bound(self):
        changes = {
            "run_id": "123e4567-e89b-12d3-a456-426614174001",
            "process_id": 4243,
            "process_start_abstime": 987654322,
            "source_key": 74,
            "asset_sha256": "cd" * 32,
            "candidate_id": "other-candidate",
        }
        for field, value in changes.items():
            with self.subTest(field=field):
                binding = dataclasses.replace(self.binding, **{field: value})
                processes = self.processes
                if field in {"process_id", "process_start_abstime"}:
                    processes = tuple(
                        sorted(
                            (
                                memory.CoalitionProcess(
                                    binding.process_id,
                                    binding.process_start_abstime,
                                    "app",
                                    912,
                                ),
                                self.processes[1],
                            )
                        )
                    )
                report = self.validate(binding=binding, processes=processes)
                self.assertFalse(report.identity_bound)
                self.assertFalse(report.evidence_pass)
        evidence = copy.deepcopy(self.os_evidence)
        evidence["query"]["members"][1]["process_id"] = 5001
        report = self.validate(os_evidence=evidence)
        self.assertFalse(report.os_receipt_bound)
        self.assertFalse(report.evidence_pass)

    def test_native_and_os_close_bindings_must_match_exactly(self):
        close = dataclasses.replace(self.close, work_sequence_at_phase_end=72)
        report = self.validate(close=close)
        self.assertFalse(report.identity_bound)
        self.assertFalse(report.evidence_pass)
        evidence = copy.deepcopy(self.os_evidence)
        evidence["query"]["work_sequence_at_query_end"] = 72
        report = self.validate(os_evidence=evidence, os_receipt=self._os_receipt(evidence))
        self.assertFalse(report.evidence_pass)

    def test_reset_or_work_cannot_intervene_before_both_receipts_seal(self):
        receipt = self._native_receipt(
            self.native_evidence,
            sealed_monotonic_ns=5_030_000_000,
            next_reset_monotonic_ns=5_035_000_000,
        )
        report = self.validate(native_receipt=receipt)
        self.assertFalse(report.epoch_and_order_complete)
        self.assertFalse(report.evidence_pass)
        receipt = self._native_receipt(
            self.native_evidence, work_sequence_at_seal=72
        )
        report = self.validate(native_receipt=receipt)
        self.assertFalse(report.native_receipt_bound)
        self.assertFalse(report.evidence_pass)

    def test_reset_baseline_epoch_and_atomic_end_checkpoint_are_exact(self):
        cases = []
        reset = copy.deepcopy(self.native_evidence)
        reset["events"][0]["monotonic_ns"] -= 1
        cases.append(reset)
        baseline = copy.deepcopy(self.native_evidence)
        baseline["events"][1]["monotonic_ns"] += 1
        cases.append(baseline)
        epoch = copy.deepcopy(self.native_evidence)
        epoch["events"][2]["epoch_generation"] = 10
        cases.append(epoch)
        mixed = copy.deepcopy(self.native_evidence)
        mixed["events"][2]["categories"]["audio"]["snapshot_id"] = "other"
        cases.append(mixed)
        for native in cases:
            report = self.validate(native, native_receipt=self._native_receipt(native))
            self.assertFalse(report.epoch_and_order_complete)
            self.assertFalse(report.evidence_pass)

    def test_valid_midphase_checkpoint_cannot_hide_later_peak(self):
        native = copy.deepcopy(self.native_evidence)
        final = copy.deepcopy(native["events"][2])
        final["sequence"] = 3
        final["snapshot_id"] = "actual-final"
        final["aggregate_native_hwm_bytes"] = 150 * MIB
        for facts in final["categories"].values():
            facts["checkpoint_sequence"] = 3
            facts["snapshot_id"] = "actual-final"
        native["events"][2]["monotonic_ns"] = 3_000_000_000
        native["events"].append(final)
        report = self.validate(native, native_receipt=self._native_receipt(native))
        self.assertFalse(report.epoch_and_order_complete)
        self.assertFalse(report.evidence_pass)

    def test_closed_categories_and_disjoint_current_sum_fail_closed(self):
        cases = []
        missing = copy.deepcopy(self.native_evidence)
        del missing["events"][2]["categories"]["audio"]
        cases.append(missing)
        negative = copy.deepcopy(self.native_evidence)
        negative["events"][2]["categories"]["decoder"]["copy_current_bytes"] = -1
        cases.append(negative)
        wrong_sum = copy.deepcopy(self.native_evidence)
        wrong_sum["events"][2]["aggregate_current_bytes"] += 1
        cases.append(wrong_sum)
        baseline_hwm = copy.deepcopy(self.native_evidence)
        baseline_hwm["events"][1]["categories"]["audio"]["ring_diagnostic_hwm_bytes"] += 1
        cases.append(baseline_hwm)
        for native in cases:
            report = self.validate(native, native_receipt=self._native_receipt(native))
            self.assertFalse(report.required_categories_complete)
            self.assertFalse(report.evidence_pass)

    def test_native_receipt_hash_prevents_mutable_evidence_forgery(self):
        native = copy.deepcopy(self.native_evidence)
        native["events"][2]["aggregate_native_hwm_bytes"] = 90 * MIB
        report = self.validate(native)
        self.assertFalse(report.native_receipt_bound)
        self.assertFalse(report.evidence_pass)

    def test_native_peak_cannot_exceed_conservative_os_sum(self):
        native = copy.deepcopy(self.native_evidence)
        native["events"][2]["aggregate_native_hwm_bytes"] = 201 * MIB
        receipt = self._native_receipt(native)
        report = self.validate(native, native_receipt=receipt)
        self.assertIsNone(report.untracked_delta_bytes)
        self.assertFalse(report.evidence_pass)

    def test_receipts_require_external_index_and_sealed_capabilities(self):
        with self.assertRaisesRegex(memory.MemoryReconciliationError, "capture boundary"):
            self.validate(native_receipt=self.native_receipt.as_dict())
        with self.assertRaisesRegex(memory.MemoryReconciliationError, "capture boundary"):
            self.validate(os_receipt=self.os_receipt.as_dict())
        with self.assertRaisesRegex(memory.MemoryReconciliationError, "sealed"):
            dataclasses.replace(self.native_receipt, _capability_seal=object())

    def test_unindexed_or_modified_retained_receipt_is_rejected(self):
        mapping = self.os_receipt.as_dict()
        digest = memory._canonical_sha256(mapping, "test receipt")
        index = memory.TrustedExecutionIndex(
            "trusted-index-1",
            (
                memory.TrustedExecutionEntry(
                    "os_coalition_memory", "different-receipt", digest
                ),
            ),
        )
        with self.assertRaisesRegex(memory.MemoryReconciliationError, "trusted execution"):
            memory.authenticate_os_receipt(mapping, trusted_execution_index=index)
        mapping["query_status"] = 1
        with self.assertRaisesRegex(memory.MemoryReconciliationError, "trusted execution"):
            memory.authenticate_os_receipt(
                mapping,
                trusted_execution_index=memory.TrustedExecutionIndex(
                    "trusted-index-1",
                    (
                        memory.TrustedExecutionEntry(
                            "os_coalition_memory", "os-receipt-1", digest
                        ),
                    ),
                ),
            )

    def test_noncanonical_mapping_and_nan_fail_closed(self):
        report = self.validate(UserDict(self.native_evidence))
        self.assertFalse(report.evidence_pass)
        native = copy.deepcopy(self.native_evidence)
        native["events"][2]["aggregate_native_hwm_bytes"] = float("nan")
        report = self.validate(native)
        self.assertFalse(report.evidence_pass)
        self.assertTrue(any("canonical JSON" in error for error in report.errors))

    def test_require_accepts_complete_evidence_but_not_the_production_gate(self):
        report = memory.require_memory_reconciliation(
            self.native_evidence,
            trusted_native_receipt=self.native_receipt,
            os_reducer_evidence=self.os_evidence,
            trusted_os_receipt=self.os_receipt,
            trusted_execution_index=self._trusted_index(
                self.native_receipt, self.os_receipt
            ),
            expected_binding=self.binding,
            expected_phase="steady",
            expected_variant="hevc-main10-mkv",
            allowed_phase_bounds=self.bounds,
            expected_close_binding=self.close,
            expected_processes=self.processes,
        )
        self.assertTrue(report.evidence_pass)
        self.assertFalse(report.gate_pass)


if __name__ == "__main__":
    unittest.main()
