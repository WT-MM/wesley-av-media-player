#!/usr/bin/env python3

import copy
import hashlib
import json
import math
import struct
import tempfile
import unittest
import zlib
from pathlib import Path

import shipper_screen_driver_evidence as evidence
import shipper_raw_evidence as raw_evidence


RUN_ID = "123e4567-e89b-12d3-a456-426614174000"
CAPTURE_NONCE = "b" * 64
ASSET_SHA256 = "a" * 64
AUDIT_TOKEN_SHA256 = "c" * 64
LOADER_PATH = "/Applications/WAM.app/Contents/Frameworks/WAMMpvFallback.dylib"
LOADER_IDENTITY = evidence.DylibFileIdentity(
    canonical_path=LOADER_PATH,
    device=16777234,
    inode=9010,
    sha256="9" * 64,
)


class TestAttestation:
    __name__ = "ExternalAttestationCapability"

    def __init__(self, bundle):
        self.binding = raw_evidence.EvidenceBinding(
            **bundle.binding.as_dict()
        )
        self.capture_nonce = CAPTURE_NONCE
        self.audit_token_sha256 = AUDIT_TOKEN_SHA256
        self.candidate_dylib = raw_evidence.CandidateDylibIdentity(
            canonical_path=LOADER_IDENTITY.canonical_path,
            device=LOADER_IDENTITY.device,
            inode=LOADER_IDENTITY.inode,
            byte_length=1234,
            sha256=LOADER_IDENTITY.sha256,
        )
        self.trust_index_sha256 = "8" * 64
        self._tools = {}
        for invocation in bundle.invocations:
            if invocation.role in raw_evidence._TRUST_TOOL_ROLES:
                self._tools[invocation.role] = raw_evidence.TrustedToolIdentity(
                    role=invocation.role,
                    process_id=bundle.binding.process_id,
                    process_start_abstime=bundle.binding.process_start_abstime,
                    executable_argv_sha256=evidence._digest(list(invocation.argv)),
                    executable_path=invocation.executable_path,
                    executable_device=1,
                    executable_inode=1,
                    executable_byte_length=1,
                    executable_sha256=invocation.executable_sha256,
                    audit_token_sha256=AUDIT_TOKEN_SHA256,
                )

    def tool(self, role):
        return self._tools[role]


def png(width=128, height=72, marker=b"captured"):
    def chunk(kind, data):
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        )

    seed = sum(marker) & 0xFF
    rows = []
    for y in range(height):
        row = bytearray((0,))
        for x in range(width):
            row.extend(((x + seed) & 0xFF, (y * 3 + seed) & 0xFF, (x + y) & 0xFF))
        rows.append(bytes(row))
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(b"".join(rows)))
        + chunk(b"IEND", b"")
    )


def rgba_png(width=128, height=72, alpha=0):
    def chunk(kind, data):
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        )

    rows = []
    for y in range(height):
        row = bytearray((0,))
        for x in range(width):
            row.extend((x & 0xFF, y & 0xFF, (x + y) & 0xFF, alpha))
        rows.append(bytes(row))
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(b"".join(rows)))
        + chunk(b"IEND", b"")
    )


def wav_frame_values(values, sample_rate=48_000, channels=2, byte_rate=None):
    samples = [sample for value in values for sample in (value,) * channels]
    sample_bytes = struct.pack("<" + "h" * len(samples), *samples)
    block_align = channels * 2
    actual_byte_rate = sample_rate * block_align if byte_rate is None else byte_rate
    fmt = struct.pack(
        "<HHIIHH", 1, channels, sample_rate, actual_byte_rate, block_align, 16
    )
    body = b"fmt " + struct.pack("<I", len(fmt)) + fmt
    body += b"data" + struct.pack("<I", len(sample_bytes)) + sample_bytes
    return b"RIFF" + struct.pack("<I", len(body) + 4) + b"WAVE" + body


def wav(pattern=(1000, -1000, 500, -500), frames=24_000):
    channels = 2
    sample_rate = 48_000
    samples = tuple(pattern[index % len(pattern)] for index in range(frames * channels))
    sample_bytes = struct.pack("<" + "h" * len(samples), *samples)
    block_align = channels * 2
    byte_rate = sample_rate * block_align
    fmt = struct.pack("<HHIIHH", 1, channels, sample_rate, byte_rate, block_align, 16)
    body = b"fmt " + struct.pack("<I", len(fmt)) + fmt
    body += b"data" + struct.pack("<I", len(sample_bytes)) + sample_bytes
    return b"RIFF" + struct.pack("<I", len(body) + 4) + b"WAVE" + body


def native_event(binding, event, monotonic_ns, **overrides):
    value = {
        "schema": evidence.NATIVE_TELEMETRY_SCHEMA,
        "event": event,
        "monotonic_ns": monotonic_ns,
        "route": "undecided",
        "route_proof": False,
        "source_key": binding.source_key,
        "attempt": 0,
        "serial": 0,
        "generation": 0,
        "gesture": 0,
        "request": 0,
        "draw_sequence": 0,
        "target_seconds": None,
        "libmpv_initialized": False,
        "run_id": binding.run_id,
        "process_id": binding.process_id,
        "process_start_abstime": binding.process_start_abstime,
        "asset_sha256": binding.asset_sha256,
        "candidate_id": binding.candidate_id,
    }
    value.update(overrides)
    return value


class ValidBundle:
    def __init__(self):
        self.phase_variant = evidence.PhaseVariant(
            phase="startup",
            codec="vp9",
            container="webm",
            profile="fallback",
            replicate=0,
        )
        self.capture_context_sha256 = evidence.capture_context_sha256(
            evidence.DriverBinding(
                run_id=RUN_ID,
                process_id=4242,
                process_start_abstime=987654321,
                asset_sha256=ASSET_SHA256,
                candidate_id="2" * 64,
                source_key=7,
            ),
            self.phase_variant,
            CAPTURE_NONCE,
        )
        self.binding = evidence.DriverBinding(
            run_id=RUN_ID,
            process_id=4242,
            process_start_abstime=987654321,
            asset_sha256=ASSET_SHA256,
            candidate_id="2" * 64,
            source_key=7,
        )
        self.asset = evidence.AssetFileIdentity(
            canonical_path="/Applications/WAM.app/Contents/Resources/Media/control.webm",
            device=16777234,
            inode=9001,
        )
        app_path = "/Applications/WAM.app/Contents/MacOS/WAM"
        self.audit = evidence.MacOSAuditIdentity(
            audit_session_id=91,
            audit_uid=501,
            effective_uid=501,
            real_uid=501,
            effective_gid=20,
            real_gid=20,
            process_id=self.binding.process_id,
            audit_token_sha256=AUDIT_TOKEN_SHA256,
            signing_identifier="com.wesleymaa.wam",
            team_identifier="WAMTEAM01",
            executable_path=app_path,
            executable_sha256="1" * 64,
            screen_recording_authorized=True,
            accessibility_authorized=True,
        )
        self.window = evidence.WindowIdentity(
            window_id=77,
            owner_process_id=self.binding.process_id,
            owner_process_start_abstime=self.binding.process_start_abstime,
            owner_bundle_id="com.wesleymaa.wam",
            owner_name="WAM",
            onscreen=True,
            frontmost=True,
            visible=True,
            layer=0,
            alpha=1.0,
            display_id=1,
            bounds_x=100.0,
            bounds_y=80.0,
            bounds_width=64.0,
            bounds_height=36.0,
            backing_scale_factor=2.0,
        )
        specs = {
            "app": ("app_executable", app_path),
            "audio": ("system_audio_capture", "/opt/wam-tools/process-audio-capture"),
            "audit": ("window_audit", "/opt/wam-tools/window-audit"),
            "harness": ("capture_harness", "/opt/wam-tools/shipper-harness"),
            "input": ("input_driver", "/opt/wam-tools/input-driver"),
            "loader": ("loader_inspector", "/usr/bin/vmmap"),
            "open": ("open_driver", "/usr/bin/open"),
            "screen": ("screen_capture", "/usr/sbin/screencapture"),
        }
        all_invocations = tuple(
            evidence.TrustedInvocation(
                invocation_id=invocation_id,
                role=role,
                executable_path=path,
                executable_sha256=(format(index + 1, "x") * 64)[:64],
                argv=(
                    path,
                    "--receipt-mode",
                    invocation_id,
                    f"--capture-context-sha256={self.capture_context_sha256}",
                ),
                capture_context_sha256=self.capture_context_sha256,
            )
            for index, (invocation_id, (role, path)) in enumerate(sorted(specs.items()))
        )
        self.all_invocations = all_invocations
        self.actor_for_role = {
            value.role: value.invocation_id for value in all_invocations
        }
        self.invocations = tuple(
            value
            for value in all_invocations
            if value.role in evidence.PHASE_INVOCATION_ROLES[self.phase_variant.phase]
        )
        actor_for_role = self.actor_for_role
        artifact_for_event = {
            "macos_audit_capture": "artifact-window",
            "loader_pre_capture": "artifact-loader-pre",
            "initial_open_action": "artifact-initial-open",
            "open_shortcut_key_down": "artifact-dialog",
            "open_shortcut_key_up": "artifact-dialog",
            "file_dialog_shown": "artifact-dialog",
            "file_dialog_path_selected": "artifact-dialog",
            "file_dialog_accepted": "artifact-dialog",
            "warm_open_action": "artifact-dialog",
            "warm_open_source_observed": "artifact-warm-source",
            "fallback_route_selected": "artifact-fallback-route",
            "pointer_down": "artifact-input",
            "pointer_move": "artifact-input",
            "pointer_up": "artifact-input",
            "screenshot_capture": "artifact-screen",
            "loader_post_capture": "artifact-loader-post",
            "system_audio_capture": "artifact-audio",
        }
        role_for_event = {
            "macos_audit_capture": "window_audit",
            "loader_pre_capture": "loader_inspector",
            "initial_open_action": "open_driver",
            "open_shortcut_key_down": "input_driver",
            "open_shortcut_key_up": "input_driver",
            "file_dialog_shown": "input_driver",
            "file_dialog_path_selected": "input_driver",
            "file_dialog_accepted": "input_driver",
            "warm_open_action": "input_driver",
            "warm_open_source_observed": "capture_harness",
            "fallback_route_selected": "capture_harness",
            "pointer_down": "input_driver",
            "pointer_move": "input_driver",
            "pointer_up": "input_driver",
            "screenshot_capture": "screen_capture",
            "loader_post_capture": "loader_inspector",
            "system_audio_capture": "system_audio_capture",
        }
        self.events = []

        def add(name, clock, details):
            self.events.append(
                {
                    "sequence": len(self.events),
                    "event": name,
                    "monotonic_ns": clock,
                    "binding": self.binding.as_dict(),
                    "capture_nonce": CAPTURE_NONCE,
                    "actor_invocation_id": actor_for_role[role_for_event[name]],
                    "artifact_id": artifact_for_event[name],
                    "details": details,
                }
            )

        add(
            "macos_audit_capture",
            1_000_000_000,
            {
                "window_id": 77,
                "audit_session_id": 91,
                "capture_receipt_id": "audit-receipt",
            },
        )
        loader_common = {
            "library_canonical_path": LOADER_PATH,
            "observation_scope": "process",
            "target_process_id": self.binding.process_id,
            "target_process_start_abstime": self.binding.process_start_abstime,
            "observation_method": "dyld_image_list",
        }
        add(
            "loader_pre_capture",
            1_010_000_000,
            {
                **loader_common,
                "loaded": False,
                "observation_receipt_id": "loader-pre-receipt",
            },
        )
        open_common = {
            "action_kind": "open_asset",
            "delivery_source": "launchservices_completion",
            "asset": self.asset.as_dict(),
            "target_process_id": self.binding.process_id,
            "target_process_start_abstime": self.binding.process_start_abstime,
        }
        add(
            "initial_open_action",
            1_020_000_000,
            {
                **open_common,
                "action_id": "open-initial",
                "delivery_receipt_id": "open-receipt-initial",
                "process_was_already_running": True,
                "resulting_source_key": 6,
            },
        )
        add(
            "open_shortcut_key_down",
            1_021_000_000,
            {
                "key": "O",
                "modifiers": ["command"],
                "delivery_receipt_id": "input-cmd-o-down",
                "target_window_id": self.window.window_id,
            },
        )
        add(
            "open_shortcut_key_up",
            1_022_000_000,
            {
                "key": "O",
                "modifiers": ["command"],
                "delivery_receipt_id": "input-cmd-o-up",
                "target_window_id": self.window.window_id,
            },
        )
        add(
            "file_dialog_shown",
            1_024_000_000,
            {
                "dialog_kind": "native_file_dialog",
                "dialog_window_id": 78,
                "owner_process_id": self.binding.process_id,
                "owner_process_start_abstime": self.binding.process_start_abstime,
                "onscreen": True,
                "frontmost": True,
                "delivery_receipt_id": "input-dialog-shown",
            },
        )
        add(
            "file_dialog_path_selected",
            1_027_000_000,
            {
                "dialog_window_id": 78,
                "asset": self.asset.as_dict(),
                "delivery_receipt_id": "input-path-select",
            },
        )
        add(
            "file_dialog_accepted",
            1_030_000_000,
            {
                "dialog_window_id": 78,
                "asset": self.asset.as_dict(),
                "delivery_receipt_id": "input-dialog-accept",
                "target_process_id": self.binding.process_id,
                "target_process_start_abstime": self.binding.process_start_abstime,
            },
        )
        add(
            "warm_open_action",
            1_031_000_000,
            {
                **open_common,
                "delivery_source": "screen_file_dialog_acceptance",
                "action_id": "open-warm",
                "prior_action_id": "open-initial",
                "delivery_receipt_id": "open-receipt-warm",
                "process_was_already_running": True,
                "same_process_confirmed": True,
                "target_window_id": self.window.window_id,
                "accessibility_receipt_id": "input-receipt",
                "command_key_delivery_receipt_id": "input-cmd-o",
                "dialog_acceptance_receipt_id": "input-dialog-accept",
                "standard_key": "StandardKey.Open",
                "shortcut": "Meta+O",
                "dialog_kind": "native_file_dialog",
                "dialog_window_id": 78,
                "dialog_owner_process_id": self.binding.process_id,
                "dialog_owner_process_start_abstime": self.binding.process_start_abstime,
                "dialog_onscreen": True,
                "dialog_frontmost": True,
                "command_key_down_monotonic_ns": 1_021_000_000,
                "command_key_up_monotonic_ns": 1_022_000_000,
                "dialog_shown_monotonic_ns": 1_024_000_000,
                "path_selected_monotonic_ns": 1_027_000_000,
                "dialog_accepted_monotonic_ns": 1_030_000_000,
                "command_key_down_receipt_id": "input-cmd-o-down",
                "command_key_up_receipt_id": "input-cmd-o-up",
                "path_selection_receipt_id": "input-path-select",
            },
        )
        self.warm_native_events = (
            native_event(
                self.binding,
                "open_requested",
                1_036_000_000,
            ),
            native_event(
                self.binding,
                "native_selected",
                1_045_000_000,
                route="native",
                route_proof=True,
                attempt=11,
                serial=12,
                generation=13,
                target_seconds=0.0,
            ),
            native_event(
                self.binding,
                "first_frame_drawn",
                1_060_000_000,
                route="native",
                attempt=11,
                serial=14,
                generation=13,
                draw_sequence=1,
                target_seconds=0.0,
            ),
        )
        add(
            "warm_open_source_observed",
            1_060_000_000,
            {
                "source_key": self.binding.source_key,
                "caused_by_action_id": "open-warm",
                "telemetry_event": "warm_open_to_first_frame",
                "asset_sha256": self.binding.asset_sha256,
                "target_process_id": self.binding.process_id,
                "target_process_start_abstime": self.binding.process_start_abstime,
                "telemetry_receipt_id": "warm-source-receipt",
                "open_requested_monotonic_ns": 1_036_000_000,
                "native_selected_monotonic_ns": 1_045_000_000,
                "first_frame_drawn_monotonic_ns": 1_060_000_000,
            },
        )
        pointer_clock = 1_070_000_000
        scrub_events = []
        for gesture_id, (start, finish) in ((21, (0.05, 0.95)), (22, (0.95, 0.05))):
            gesture_start_clock = pointer_clock
            steps = [("pointer_down", 0, start)]
            steps.extend(
                (
                    "pointer_move",
                    index * evidence.DRAG_PERIOD_NS,
                    start + ((finish - start) * index / evidence.DRAG_MOVE_COUNT_PER_LEG),
                )
                for index in range(1, evidence.DRAG_MOVE_COUNT_PER_LEG + 1)
            )
            steps.append(("pointer_up", evidence.DRAG_LEG_DURATION_NS, finish))
            for phase, offset_ns, x in steps:
                delivery_clock = (
                    gesture_start_clock
                    + offset_ns
                    + (1 if phase == "pointer_up" else 0)
                )
                scrub_events.append(
                    (
                        phase,
                        delivery_clock,
                        {
                        "gesture_id": gesture_id,
                        "pointer_id": 1,
                        "normalized_x": x,
                        "normalized_y": 0.5,
                        "delivery_receipt_id": (
                            f"input-{gesture_id}-{phase}-{offset_ns}"
                        ),
                        "window_id": self.window.window_id,
                        "planned_offset_ns": offset_ns,
                        },
                    )
                )
            pointer_clock = (
                gesture_start_clock
                + evidence.DRAG_LEG_DURATION_NS
                + 1
                + 250_000_000
            )
        audio_payload = wav()
        self.audio_payload = audio_payload
        audio_frames = 24_000
        peak_dbfs = 20.0 * math.log10(1000 / 32768.0)
        fallback_tail = [
            (
                "loader_post_capture",
                pointer_clock,
                {
                    **loader_common,
                    "loaded": True,
                    "observation_receipt_id": "loader-post-receipt",
                },
            ),
            (
                "screenshot_capture",
                pointer_clock + 10_000_000,
                {
                    "window_id": self.window.window_id,
                    "owner_process_id": self.binding.process_id,
                    "owner_process_start_abstime": self.binding.process_start_abstime,
                    "capture_receipt_id": "screenshot-receipt",
                },
            ),
            (
                "system_audio_capture",
                pointer_clock + 520_000_000,
                {
                "capture_scope": "process",
                "target_process_id": self.binding.process_id,
                "target_process_start_abstime": self.binding.process_start_abstime,
                "audit_token_sha256": AUDIT_TOKEN_SHA256,
                "audio_active": True,
                "audible": True,
                "sample_rate_hz": 48_000,
                "channels": 2,
                "captured_frames": audio_frames,
                "non_silent_frames": audio_frames,
                "peak_dbfs": peak_dbfs,
                "capture_receipt_id": "audio-receipt",
                },
            ),
        ]
        self.scrub_events = scrub_events
        self.fallback_tail = fallback_tail
        self.events = [
            event
            for event in self.events
            if event["event"]
            in {
                "macos_audit_capture",
                "initial_open_action",
                "open_shortcut_key_down",
                "open_shortcut_key_up",
                "file_dialog_shown",
                "file_dialog_path_selected",
                "file_dialog_accepted",
                "warm_open_action",
                "warm_open_source_observed",
            }
        ]
        for index, event in enumerate(self.events):
            event["sequence"] = index
        pointer_events = [
            event
            for event in self.events
            if event["event"] in {"pointer_down", "pointer_move", "pointer_up"}
        ]
        self.input_receipt = evidence.InputDriverReceipt(
            receipt_id="input-receipt",
            invocation_id=actor_for_role["input_driver"],
            audit_session_id=self.audit.audit_session_id,
            audit_token_sha256=AUDIT_TOKEN_SHA256,
            target_process_id=self.binding.process_id,
            target_process_start_abstime=self.binding.process_start_abstime,
            target_window_id=self.window.window_id,
            event_tap_location="cghid",
            posted_by_harness=True,
            started_monotonic_ns=next(
                event["monotonic_ns"]
                for event in self.events
                if event["event"] == "open_shortcut_key_down"
            ),
            ended_monotonic_ns=next(
                event["monotonic_ns"]
                for event in self.events
                if event["event"] == "warm_open_action"
            ),
            event_count=6,
            event_sequence_sha256=evidence.input_event_sha256(self.events),
            artifact_id="artifact-input",
        )
        events_by_name = {event["event"]: event for event in self.events}
        invocation_by_role = {value.role: value for value in all_invocations}
        artifact_metadata = {
            "artifact-window": (
                "window_audit", "window_audit", "audit-receipt",
                999_000_000, 1_000_000_000,
            ),
            "artifact-initial-open": (
                "initial_open_receipt", "open_driver", "open-receipt-initial",
                1_019_000_000, 1_020_000_000,
            ),
            "artifact-input": (
                "input_trace", "input_driver", "input-receipt",
                self.input_receipt.started_monotonic_ns,
                self.input_receipt.ended_monotonic_ns,
            ),
            "artifact-dialog": (
                "dialog_acceptance", "input_driver", "input-dialog-accept",
                1_021_000_000, 1_031_000_000,
            ),
            "artifact-warm-source": (
                "warm_source_telemetry", "capture_harness", "warm-source-receipt",
                1_035_000_000, 1_060_000_000,
            ),
        }

        def record(artifact_id, payload):
            kind, role, receipt_id, started, ended = artifact_metadata[artifact_id]
            return evidence.make_artifact_record(
                artifact_id,
                kind,
                payload,
                producer_invocation_id=invocation_by_role[role].invocation_id,
                producer_receipt_id=receipt_id,
                capture_started_monotonic_ns=started,
                capture_ended_monotonic_ns=ended,
            )

        self.payloads = {
            "artifact-window": evidence.make_window_audit_payload(
                self.binding, CAPTURE_NONCE, self.audit, self.window
            ),
            "artifact-input": evidence.make_input_trace_payload(
                self.binding, CAPTURE_NONCE, self.input_receipt, self.events
            ),
            "artifact-initial-open": evidence.make_initial_open_payload(
                self.binding,
                CAPTURE_NONCE,
                self.asset,
                events_by_name["initial_open_action"],
            ),
            "artifact-dialog": evidence.make_dialog_acceptance_payload(
                self.binding,
                CAPTURE_NONCE,
                self.asset,
                self.window,
                self.events,
            ),
            "artifact-warm-source": evidence.make_warm_source_payload(
                self.warm_native_events
            ),
        }
        self.artifacts = tuple(
            record(artifact_id, payload)
            for artifact_id, payload in self.payloads.items()
        )
        self.receipt = evidence.seal_capture_receipt(
            binding=self.binding,
            phase_variant=self.phase_variant,
            capture_nonce=CAPTURE_NONCE,
            asset=self.asset,
            trusted_invocations=self.invocations,
            macos_audit=self.audit,
            window=self.window,
            input_driver_receipt=self.input_receipt,
            artifacts=self.artifacts,
            events=self.events,
        )
        self.external_transcript_sha256 = self.receipt["transcript_sha256"]

    def validate(self, receipt=None, payloads=None, **overrides):
        arguments = {
            "expected_binding": self.binding,
            "expected_capture_nonce": CAPTURE_NONCE,
            "expected_transcript_sha256": self.external_transcript_sha256,
            "expected_phase_variant": self.phase_variant,
            "expected_asset": self.asset,
            "expected_invocations": self.invocations,
            "expected_loader_identity": LOADER_IDENTITY,
            "expected_media_duration_seconds": 10.0,
            "external_attestation": TestAttestation(self),
            "artifact_payloads": self.payloads if payloads is None else payloads,
        }
        arguments.update(overrides)
        return evidence.validate_capture_receipt(
            self.receipt if receipt is None else receipt,
            **arguments,
        )


def phase_bundle(phase):
    base = ValidBundle()
    if phase == "startup":
        return base
    result = copy.copy(base)
    result.phase_variant = evidence.PhaseVariant(
        phase=phase,
        codec="vp9" if phase == "fallback_control" else "h264",
        container="webm" if phase == "fallback_control" else "mp4",
        profile="fallback" if phase == "fallback_control" else "any",
        replicate=0,
    )
    result.capture_context_sha256 = evidence.capture_context_sha256(
        result.binding, result.phase_variant, CAPTURE_NONCE
    )
    result.invocations = tuple(
        evidence.dataclasses.replace(
            invocation,
            argv=tuple(
                argument
                if not argument.startswith("--capture-context-sha256=")
                else f"--capture-context-sha256={result.capture_context_sha256}"
                for argument in invocation.argv
            ),
            capture_context_sha256=result.capture_context_sha256,
        )
        for invocation in result.all_invocations
        if invocation.role in evidence.PHASE_INVOCATION_ROLES[phase]
    )
    invocation_by_role = {value.role: value for value in result.invocations}
    base_events = {event["event"]: copy.deepcopy(event) for event in base.events}

    def event(name, clock, artifact_id, role, details):
        return {
            "sequence": 0,
            "event": name,
            "monotonic_ns": clock,
            "binding": result.binding.as_dict(),
            "capture_nonce": CAPTURE_NONCE,
            "actor_invocation_id": invocation_by_role[role].invocation_id,
            "artifact_id": artifact_id,
            "details": copy.deepcopy(details),
        }

    audit_event = base_events["macos_audit_capture"]
    initial_event = base_events["initial_open_action"]
    initial_event["details"]["resulting_source_key"] = result.binding.source_key
    records_by_kind = {record.kind: record for record in base.artifacts}
    payloads_by_kind = {
        record.kind: base.payloads[record.artifact_id]
        for record in base.artifacts
    }
    initial_payload = evidence.make_initial_open_payload(
        result.binding, CAPTURE_NONCE, result.asset, initial_event
    )
    initial_record = evidence.make_artifact_record(
        "artifact-initial-open",
        "initial_open_receipt",
        initial_payload,
        producer_invocation_id=invocation_by_role["open_driver"].invocation_id,
        producer_receipt_id="open-receipt-initial",
        capture_started_monotonic_ns=1_019_000_000,
        capture_ended_monotonic_ns=1_020_000_000,
    )

    if phase == "steady":
        steady_start_clock = 1_200_000_000
        steady_start = event(
            "steady_playback_started",
            steady_start_clock,
            "artifact-steady-native",
            "capture_harness",
            {"telemetry_receipt_id": "steady-native-receipt"},
        )
        steady_samples = []
        for index in range(evidence.STEADY_SAMPLE_COUNT):
            steady_samples.append(
                event(
                    "steady_playback_sample",
                    steady_start_clock + (index + 1) * evidence.STEADY_SAMPLE_PERIOD_NS,
                    "artifact-steady-native",
                    "capture_harness",
                    {
                        "telemetry_receipt_id": "steady-native-receipt",
                        "sample_index": index,
                        "source_key": base.binding.source_key,
                        "draw_sequence": index + 2,
                        "position_seconds": 0.5 * (index + 1),
                    },
                )
            )
        steady_end = event(
            "steady_playback_completed",
            steady_start_clock
            + evidence.STEADY_SAMPLE_DURATION_NS
            + evidence.STEADY_SAMPLE_PERIOD_NS
            + 1,
            "artifact-steady-native",
            "capture_harness",
            {"telemetry_receipt_id": "steady-native-receipt"},
        )
        events = [
            audit_event,
            initial_event,
            steady_start,
            *steady_samples,
            steady_end,
        ]
        native_events = [
            native_event(base.binding, "open_requested", 1_030_000_000),
            native_event(
                base.binding,
                "native_selected",
                1_050_000_000,
                route="native",
                route_proof=True,
                attempt=11,
                serial=12,
                generation=13,
                target_seconds=0.0,
            ),
            native_event(
                base.binding,
                "first_frame_drawn",
                1_100_000_000,
                route="native",
                attempt=11,
                serial=14,
                generation=13,
                draw_sequence=1,
                target_seconds=0.0,
            ),
        ]
        native_events.extend(
            native_event(
                base.binding,
                "first_frame_drawn",
                sample["monotonic_ns"],
                route="native",
                attempt=11,
                serial=15 + index,
                generation=13,
                draw_sequence=sample["details"]["draw_sequence"],
                target_seconds=sample["details"]["position_seconds"],
            )
            for index, sample in enumerate(steady_samples)
        )
        steady_payload = evidence.make_warm_source_payload(native_events)
        steady_record = evidence.make_artifact_record(
            "artifact-steady-native",
            "steady_native_telemetry",
            steady_payload,
            producer_invocation_id=invocation_by_role["capture_harness"].invocation_id,
            producer_receipt_id="steady-native-receipt",
            capture_started_monotonic_ns=steady_start["monotonic_ns"],
            capture_ended_monotonic_ns=steady_end["monotonic_ns"],
        )
        artifacts = (
            records_by_kind["window_audit"],
            initial_record,
            steady_record,
        )
        payloads = {
            records_by_kind["window_audit"].artifact_id: payloads_by_kind[
                "window_audit"
            ],
            initial_record.artifact_id: initial_payload,
            steady_record.artifact_id: steady_payload,
        }
        input_receipt = None
    elif phase == "scrub":
        telemetry_start_clock = base.scrub_events[0][1] - 1_000_000
        telemetry_end_clock = base.scrub_events[-1][1] + 2_000_000
        telemetry_start = event(
            "scrub_telemetry_started",
            telemetry_start_clock,
            "artifact-scrub-native",
            "capture_harness",
            {"telemetry_receipt_id": "scrub-native-receipt"},
        )
        pointer_events = [
            event(name, clock, "artifact-input", "input_driver", details)
            for name, clock, details in base.scrub_events
        ]
        pointer_by_gesture = {
            gesture_id: [
                value
                for value in pointer_events
                if value["details"]["gesture_id"] == gesture_id
            ]
            for gesture_id in (21, 22)
        }
        telemetry_end = event(
            "scrub_telemetry_completed",
            telemetry_end_clock,
            "artifact-scrub-native",
            "capture_harness",
            {"telemetry_receipt_id": "scrub-native-receipt"},
        )
        events = [audit_event, initial_event, telemetry_start, *pointer_events, telemetry_end]
        for index, value in enumerate(events):
            value["sequence"] = index
        input_receipt = evidence.InputDriverReceipt(
            receipt_id="scrub-input-receipt",
            invocation_id=invocation_by_role["input_driver"].invocation_id,
            audit_session_id=base.audit.audit_session_id,
            audit_token_sha256=AUDIT_TOKEN_SHA256,
            target_process_id=base.binding.process_id,
            target_process_start_abstime=base.binding.process_start_abstime,
            target_window_id=base.window.window_id,
            event_tap_location="cghid",
            posted_by_harness=True,
            started_monotonic_ns=pointer_events[0]["monotonic_ns"],
            ended_monotonic_ns=pointer_events[-1]["monotonic_ns"],
            event_count=len(pointer_events),
            event_sequence_sha256=evidence.input_event_sha256(events),
            artifact_id="artifact-input",
        )
        input_payload = evidence.make_input_trace_payload(
            base.binding, CAPTURE_NONCE, input_receipt, events
        )
        native_events = []
        for gesture_index, gesture_id in enumerate((21, 22)):
            moves = [
                value
                for value in pointer_events
                if value["event"] == "pointer_move"
                and value["details"]["gesture_id"] == gesture_id
            ]
            up = next(
                value
                for value in pointer_events
                if value["event"] == "pointer_up"
                and value["details"]["gesture_id"] == gesture_id
            )
            gesture_native = []
            for move_index, move in enumerate(moves, start=1):
                target = float(move["details"]["normalized_x"]) * 10.0
                gesture_native.append(
                    native_event(
                        base.binding,
                        "preview_demanded",
                        move["monotonic_ns"] + 1_000,
                        route="native",
                        gesture=gesture_id,
                        request=(gesture_index + 1) * 10_000 + move_index,
                        target_seconds=target,
                    )
                )
            last_demand = gesture_native[-1]
            draw_source = moves[len(moves) // 2]
            draw_request = (gesture_index + 1) * 10_000 + len(moves) // 2 + 1
            draw_target = float(draw_source["details"]["normalized_x"]) * 10.0
            gesture_native.append(
                native_event(
                    base.binding,
                    "preview_frame_drawn",
                    draw_source["monotonic_ns"] + 2_000,
                    route="native",
                    attempt=41 + gesture_index,
                    serial=51 + gesture_index,
                    generation=61 + gesture_index,
                    gesture=gesture_id,
                    request=draw_request,
                    draw_sequence=21 + gesture_index,
                    target_seconds=draw_target,
                )
            )
            commit_request = (gesture_index + 1) * 10_000 + 999
            commit_common = {
                "route": "native",
                "attempt": 71 + gesture_index,
                "serial": 81 + gesture_index,
                "generation": 91 + gesture_index,
                "gesture": gesture_id,
                "request": commit_request,
                "target_seconds": last_demand["target_seconds"],
            }
            gesture_native.append(
                native_event(
                    base.binding,
                    "commit_seek_submitted",
                    up["monotonic_ns"] + 1_000,
                    **commit_common,
                )
            )
            commit_draw_clock = up["monotonic_ns"] + 1_000_000
            gesture_native.append(
                native_event(
                    base.binding,
                    "commit_ready",
                    commit_draw_clock,
                    draw_sequence=101 + gesture_index,
                    **commit_common,
                )
            )
            gesture_native.append(
                native_event(
                    base.binding,
                    "commit_frame_drawn",
                    commit_draw_clock,
                    draw_sequence=101 + gesture_index,
                    **commit_common,
                )
            )
            gesture_native.sort(
                key=lambda value: (
                    value["monotonic_ns"],
                    {
                        "preview_demanded": 0,
                        "preview_frame_drawn": 1,
                        "commit_seek_submitted": 2,
                        "commit_ready": 3,
                        "commit_frame_drawn": 4,
                    }[value["event"]],
                )
            )
            native_events.extend(gesture_native)
        scrub_payload = evidence.make_scrub_native_telemetry_payload(native_events)
        input_record = evidence.make_artifact_record(
            "artifact-input",
            "input_trace",
            input_payload,
            producer_invocation_id=invocation_by_role["input_driver"].invocation_id,
            producer_receipt_id=input_receipt.receipt_id,
            capture_started_monotonic_ns=input_receipt.started_monotonic_ns,
            capture_ended_monotonic_ns=input_receipt.ended_monotonic_ns,
        )
        scrub_record = evidence.make_artifact_record(
            "artifact-scrub-native",
            "scrub_native_telemetry",
            scrub_payload,
            producer_invocation_id=invocation_by_role["capture_harness"].invocation_id,
            producer_receipt_id="scrub-native-receipt",
            capture_started_monotonic_ns=telemetry_start_clock,
            capture_ended_monotonic_ns=telemetry_end_clock,
        )
        artifacts = (
            records_by_kind["window_audit"],
            initial_record,
            input_record,
            scrub_record,
        )
        payloads = {
            records_by_kind["window_audit"].artifact_id: payloads_by_kind["window_audit"],
            initial_record.artifact_id: initial_payload,
            input_record.artifact_id: input_payload,
            scrub_record.artifact_id: scrub_payload,
        }
    else:
        loader_common = {
            "library_canonical_path": LOADER_PATH,
            "observation_scope": "process",
            "target_process_id": base.binding.process_id,
            "target_process_start_abstime": base.binding.process_start_abstime,
            "observation_method": "dyld_image_list",
        }
        loader_pre = event(
            "loader_pre_capture",
            1_010_000_000,
            "artifact-loader-pre",
            "loader_inspector",
            {**loader_common, "loaded": False, "observation_receipt_id": "loader-pre-receipt"},
        )
        loader_post_clock = 1_500_000_000
        fallback_route_clock = 1_400_000_000
        screenshot_clock = 1_510_000_000
        audio_end_clock = 2_020_000_000
        loader_post = event(
            "loader_post_capture",
            loader_post_clock,
            "artifact-loader-post",
            "loader_inspector",
            {**loader_common, "loaded": True, "observation_receipt_id": "loader-post-receipt"},
        )
        fallback_route = event(
            "fallback_route_selected",
            fallback_route_clock,
            "artifact-fallback-route",
            "capture_harness",
            {
                "source_key": base.binding.source_key,
                "telemetry_event": "fallback_selected",
                "asset_sha256": base.binding.asset_sha256,
                "target_process_id": base.binding.process_id,
                "target_process_start_abstime": base.binding.process_start_abstime,
                "route_proof": True,
                "libmpv_initialized": True,
                "telemetry_receipt_id": "fallback-route-receipt",
            },
        )
        screenshot = event(
            "screenshot_capture",
            screenshot_clock,
            "artifact-screen",
            "screen_capture",
            {
                "window_id": base.window.window_id,
                "owner_process_id": base.binding.process_id,
                "owner_process_start_abstime": base.binding.process_start_abstime,
                "capture_receipt_id": "screenshot-receipt",
            },
        )
        audio = event(
            "system_audio_capture",
            audio_end_clock,
            "artifact-audio",
            "system_audio_capture",
            {
                "capture_scope": "process",
                "capture_api": "AudioHardwareCreateProcessTap",
                "tap_process_id": base.binding.process_id,
                "tap_receipt_id": "process-tap-receipt",
                "output_device_uid": "BuiltInOutputDevice",
                "output_route_active": True,
                "target_process_id": base.binding.process_id,
                "target_process_start_abstime": base.binding.process_start_abstime,
                "audit_token_sha256": AUDIT_TOKEN_SHA256,
                "audio_active": True,
                "audible": True,
                "sample_rate_hz": 48_000,
                "channels": 2,
                "captured_frames": 24_000,
                "non_silent_frames": 24_000,
                "peak_dbfs": 20.0 * math.log10(1000 / 32768.0),
                "capture_receipt_id": "audio-receipt",
            },
        )
        events = [
            audit_event,
            loader_pre,
            initial_event,
            fallback_route,
            loader_post,
            screenshot,
            audio,
        ]
        for index, value in enumerate(events):
            value["sequence"] = index
        input_receipt = None

        def artifact_template(artifact_id, kind, role, receipt, start, end):
            return evidence.make_artifact_record(
                artifact_id,
                kind,
                b"placeholder",
                producer_invocation_id=invocation_by_role[role].invocation_id,
                producer_receipt_id=receipt,
                capture_started_monotonic_ns=start,
                capture_ended_monotonic_ns=end,
            )

        loader_pre_template = artifact_template(
            "artifact-loader-pre", "loader_pre", "loader_inspector",
            "loader-pre-receipt", 1_009_000_000, 1_010_000_000,
        )
        loader_post_template = artifact_template(
            "artifact-loader-post", "loader_post", "loader_inspector",
            "loader-post-receipt", 1_499_000_000, loader_post_clock,
        )
        loader_pre_payload = evidence.make_loader_capture_payload(
            base.binding,
            CAPTURE_NONCE,
            library_identity=LOADER_IDENTITY,
            loaded=False,
            observation_method="dyld_image_list",
            invocation=invocation_by_role["loader_inspector"],
            artifact=loader_pre_template,
        )
        loader_post_payload = evidence.make_loader_capture_payload(
            base.binding,
            CAPTURE_NONCE,
            library_identity=LOADER_IDENTITY,
            loaded=True,
            observation_method="dyld_image_list",
            invocation=invocation_by_role["loader_inspector"],
            artifact=loader_post_template,
        )
        screenshot_payload = png()
        fallback_route_payload = evidence.make_warm_source_payload(
            (
                native_event(
                    base.binding,
                    "fallback_selected",
                    fallback_route_clock,
                    route="fallback",
                    route_proof=True,
                    attempt=31,
                    serial=32,
                    generation=0,
                    libmpv_initialized=True,
                ),
            )
        )
        artifacts = (
            records_by_kind["window_audit"],
            initial_record,
            evidence.dataclasses.replace(
                loader_pre_template,
                sha256=hashlib.sha256(loader_pre_payload).hexdigest(),
                byte_length=len(loader_pre_payload),
            ),
            evidence.dataclasses.replace(
                loader_post_template,
                sha256=hashlib.sha256(loader_post_payload).hexdigest(),
                byte_length=len(loader_post_payload),
            ),
            evidence.make_artifact_record(
                "artifact-fallback-route",
                "fallback_route_telemetry",
                fallback_route_payload,
                producer_invocation_id=invocation_by_role[
                    "capture_harness"
                ].invocation_id,
                producer_receipt_id="fallback-route-receipt",
                capture_started_monotonic_ns=fallback_route_clock - 1_000_000,
                capture_ended_monotonic_ns=fallback_route_clock,
            ),
            evidence.make_artifact_record(
                "artifact-screen", "screenshot", screenshot_payload,
                producer_invocation_id=invocation_by_role["screen_capture"].invocation_id,
                producer_receipt_id="screenshot-receipt",
                capture_started_monotonic_ns=loader_post_clock + 1,
                capture_ended_monotonic_ns=screenshot_clock,
            ),
            evidence.make_artifact_record(
                "artifact-audio", "system_audio", base.audio_payload,
                producer_invocation_id=invocation_by_role["system_audio_capture"].invocation_id,
                producer_receipt_id="audio-receipt",
                capture_started_monotonic_ns=audio_end_clock - 500_000_000,
                capture_ended_monotonic_ns=audio_end_clock,
            ),
        )
        payloads = {
            records_by_kind["window_audit"].artifact_id: payloads_by_kind["window_audit"],
            initial_record.artifact_id: initial_payload,
            "artifact-loader-pre": loader_pre_payload,
            "artifact-loader-post": loader_post_payload,
            "artifact-fallback-route": fallback_route_payload,
            "artifact-screen": screenshot_payload,
            "artifact-audio": base.audio_payload,
        }

    for index, value in enumerate(events):
        value["sequence"] = index
    final_initial = next(
        value for value in events if value["event"] == "initial_open_action"
    )
    initial_payload = evidence.make_initial_open_payload(
        result.binding, CAPTURE_NONCE, result.asset, final_initial
    )
    initial_record = evidence.make_artifact_record(
        "artifact-initial-open",
        "initial_open_receipt",
        initial_payload,
        producer_invocation_id=invocation_by_role["open_driver"].invocation_id,
        producer_receipt_id="open-receipt-initial",
        capture_started_monotonic_ns=1_019_000_000,
        capture_ended_monotonic_ns=1_020_000_000,
    )
    artifacts = tuple(
        initial_record if value.kind == "initial_open_receipt" else value
        for value in artifacts
    )
    payloads[initial_record.artifact_id] = initial_payload
    result.events = events
    result.input_receipt = input_receipt
    result.artifacts = artifacts
    result.payloads = payloads
    result.receipt = evidence.seal_capture_receipt(
        binding=result.binding,
        phase_variant=result.phase_variant,
        capture_nonce=CAPTURE_NONCE,
        asset=result.asset,
        trusted_invocations=result.invocations,
        macos_audit=result.audit,
        window=result.window,
        input_driver_receipt=input_receipt,
        artifacts=artifacts,
        events=events,
    )
    result.external_transcript_sha256 = result.receipt["transcript_sha256"]
    return result


def replace_artifact(bundle, artifact_id, payload, **record_changes):
    changed = copy.deepcopy(bundle.receipt)
    record = next(
        value for value in changed["artifacts"] if value["artifact_id"] == artifact_id
    )
    record["sha256"] = hashlib.sha256(payload).hexdigest()
    record["byte_length"] = len(payload)
    record.update(record_changes)
    digest = evidence.transcript_sha256(changed["events"], changed["artifacts"])
    changed["transcript_sha256"] = digest
    payloads = dict(bundle.payloads)
    payloads[artifact_id] = payload
    return changed, payloads, digest


class ScreenDriverEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.bundle = ValidBundle()

    def test_complete_receipt_validates_exact_screen_run(self):
        result = self.bundle.validate()
        self.assertEqual(result.binding, self.bundle.binding)
        self.assertEqual(result.gesture_ids, ())
        self.assertEqual(result.capture_nonce, CAPTURE_NONCE)
        self.assertEqual(
            result.transcript_sha256,
            evidence.transcript_sha256(
                self.bundle.events, self.bundle.receipt["artifacts"]
            ),
        )
        self.assertIn("integrity-only", result.harness_trust_boundary)

    def test_each_shipping_phase_has_its_own_exact_non_omnibus_grammar(self):
        expected = {
            "startup": (
                9,
                (),
                {
                    "window_audit",
                    "initial_open_receipt",
                    "input_trace",
                    "dialog_acceptance",
                    "warm_source_telemetry",
                },
            ),
            "steady": (
                13,
                (),
                {
                    "window_audit",
                    "initial_open_receipt",
                    "steady_native_telemetry",
                },
            ),
            "scrub": (
                968,
                (21, 22),
                {
                    "window_audit",
                    "initial_open_receipt",
                    "input_trace",
                    "scrub_native_telemetry",
                },
            ),
            "fallback_control": (
                7,
                (),
                {
                    "window_audit",
                    "initial_open_receipt",
                    "loader_pre",
                    "fallback_route_telemetry",
                    "loader_post",
                    "screenshot",
                    "system_audio",
                },
            ),
        }
        for phase, (event_count, gesture_ids, artifact_kinds) in expected.items():
            with self.subTest(phase=phase):
                bundle = phase_bundle(phase)
                result = bundle.validate()
                self.assertEqual(len(bundle.events), event_count)
                self.assertEqual(result.gesture_ids, gesture_ids)
                self.assertEqual(
                    {record.kind for record in bundle.artifacts}, artifact_kinds
                )
                if phase != "fallback_control":
                    self.assertFalse(
                        any(
                            name.startswith("loader_")
                            for name in (event["event"] for event in bundle.events)
                        )
                    )

    def test_phase_variant_and_invocation_context_are_external_commitments(self):
        steady = phase_bundle("steady")
        with self.assertRaisesRegex(evidence.ScreenDriverEvidenceError, "phase"):
            steady.validate(expected_phase_variant=self.bundle.phase_variant)

        expected = list(steady.invocations)
        expected[0] = dataclass_replace(
            expected[0],
            argv=tuple(
                argument
                if not argument.startswith("--capture-context-sha256=")
                else f"--capture-context-sha256={self.bundle.capture_context_sha256}"
                for argument in expected[0].argv
            ),
            capture_context_sha256=self.bundle.capture_context_sha256,
        )
        with self.assertRaises(evidence.ScreenDriverEvidenceError):
            steady.validate(expected_invocations=tuple(expected))

    def test_external_trust_index_and_exact_dylib_identity_are_required(self):
        with self.assertRaisesRegex(evidence.ScreenDriverEvidenceError, "trust-index"):
            self.bundle.validate(external_attestation=None)

        fallback = phase_bundle("fallback_control")
        wrong_dylib = dataclass_replace(LOADER_IDENTITY, sha256="7" * 64)
        with self.assertRaisesRegex(evidence.ScreenDriverEvidenceError, "dylib"):
            fallback.validate(expected_loader_identity=wrong_dylib)

        forged = TestAttestation(fallback)
        forged.capture_nonce = "e" * 64
        with self.assertRaisesRegex(evidence.ScreenDriverEvidenceError, "nonce"):
            fallback.validate(external_attestation=forged)

    def test_scrub_is_exactly_two_directional_120hz_four_second_legs(self):
        bundle = phase_bundle("scrub")
        pointer = [
            event
            for event in bundle.events
            if event["event"] in {"pointer_down", "pointer_move", "pointer_up"}
        ]
        self.assertEqual(len(pointer), 2 * (evidence.DRAG_MOVE_COUNT_PER_LEG + 2))
        self.assertEqual(
            sum(event["event"] == "pointer_move" for event in pointer), 960
        )

        mutations = []
        changed = copy.deepcopy(bundle.receipt)
        move = next(event for event in changed["events"] if event["event"] == "pointer_move")
        move["details"]["normalized_x"] = 0.5
        mutations.append(changed)

        changed = copy.deepcopy(bundle.receipt)
        move = next(event for event in changed["events"] if event["event"] == "pointer_move")
        move["details"]["normalized_y"] = 0.0
        mutations.append(changed)

        changed = copy.deepcopy(bundle.receipt)
        up = next(event for event in changed["events"] if event["event"] == "pointer_up")
        up["details"]["planned_offset_ns"] = 3_000_000_000
        mutations.append(changed)

        changed = copy.deepcopy(bundle.receipt)
        second_down = [
            event for event in changed["events"] if event["event"] == "pointer_down"
        ][1]
        second_down["monotonic_ns"] += 2_000_000
        mutations.append(changed)

        changed = copy.deepcopy(bundle.receipt)
        remove_index = next(
            index
            for index, event in enumerate(changed["events"])
            if event["event"] == "pointer_move"
        )
        changed["events"].pop(remove_index)
        for index, event in enumerate(changed["events"]):
            event["sequence"] = index
        mutations.append(changed)

        for changed in mutations:
            changed["transcript_sha256"] = evidence.transcript_sha256(
                changed["events"], changed["artifacts"]
            )
            with self.subTest(mutation=mutations.index(changed)):
                with self.assertRaises(evidence.ScreenDriverEvidenceError):
                    bundle.validate(receipt=changed)

    def test_scrub_requires_retained_public_demands_draws_and_commits(self):
        bundle = phase_bundle("scrub")
        raw_lines = bundle.payloads["artifact-scrub-native"].splitlines()
        substitutions = {
            "missing-demand": b"\n".join(raw_lines[1:]) + b"\n",
        }
        framed = [json.loads(line) for line in raw_lines]
        changed_source = [
            value
            for value in framed
            if value.get("record") == "event"
        ]
        for value in changed_source:
            value.pop("record")
            value.pop("batch")
            value.pop("event_sequence")
        substitutions["missing-commit-draw"] = (
            evidence.make_scrub_native_telemetry_payload(
                [
                    value
                    for value in changed_source
                    if value["event"] != "commit_frame_drawn"
                ]
            )
        )
        changed_source = copy.deepcopy(changed_source)
        changed_source[0]["source_key"] = 99
        substitutions["wrong-source"] = evidence.make_scrub_native_telemetry_payload(
            changed_source
        )
        for label, payload in substitutions.items():
            changed, payloads, digest = replace_artifact(
                bundle, "artifact-scrub-native", payload
            )
            with self.subTest(label=label):
                with self.assertRaises(evidence.ScreenDriverEvidenceError):
                    bundle.validate(
                        receipt=changed,
                        payloads=payloads,
                        expected_transcript_sha256=digest,
                    )

    def test_warm_source_is_raw_same_pid_native_first_frame_lineage(self):
        raw_events = list(self.bundle.warm_native_events)
        substitutions = {
            "open-only": evidence.make_warm_source_payload(raw_events[:1]),
            "no-first-frame": evidence.make_warm_source_payload(raw_events[:2]),
        }
        wrong_pid = copy.deepcopy(raw_events)
        wrong_pid[-1]["process_id"] = 9999
        substitutions["wrong-pid"] = evidence.make_warm_source_payload(wrong_pid)
        for label, payload in substitutions.items():
            changed, payloads, digest = replace_artifact(
                self.bundle, "artifact-warm-source", payload
            )
            with self.subTest(label=label):
                with self.assertRaises(evidence.ScreenDriverEvidenceError):
                    self.bundle.validate(
                        receipt=changed,
                        payloads=payloads,
                        expected_transcript_sha256=digest,
                    )

    def test_warm_native_open_must_follow_dialog_acceptance(self):
        forged = copy.deepcopy(list(self.bundle.warm_native_events))
        forged[0]["monotonic_ns"] = 1_015_000_000
        payload = evidence.make_warm_source_payload(forged)
        changed, payloads, digest = replace_artifact(
            self.bundle, "artifact-warm-source", payload
        )
        with self.assertRaises(evidence.ScreenDriverEvidenceError):
            self.bundle.validate(
                receipt=changed,
                payloads=payloads,
                expected_transcript_sha256=digest,
            )

    def test_native_v2_framing_duplicate_keys_and_terminal_commit_are_exact(self):
        payload = self.bundle.payloads["artifact-warm-source"]
        lines = payload.splitlines()
        no_terminal = b"\n".join(lines[:-1]) + b"\n"
        duplicate_key = (
            lines[0].replace(b'{"schema":', b'{"record":"forged","schema":', 1)
            + b"\n"
            + b"\n".join(lines[1:])
            + b"\n"
        )
        for label, forged in (
            ("no-terminal", no_terminal),
            ("duplicate-key", duplicate_key),
        ):
            changed, payloads, digest = replace_artifact(
                self.bundle, "artifact-warm-source", forged
            )
            with self.subTest(label=label):
                with self.assertRaises(evidence.ScreenDriverEvidenceError):
                    self.bundle.validate(
                        receipt=changed,
                        payloads=payloads,
                        expected_transcript_sha256=digest,
                    )

    def test_scrub_rejects_unknown_gesture_global_duplicate_and_unmapped_targets(self):
        bundle = phase_bundle("scrub")
        framed = [
            json.loads(line)
            for line in bundle.payloads["artifact-scrub-native"].splitlines()
        ]
        events = [value for value in framed if value.get("record") == "event"]

        def raw(values):
            result = []
            for value in values:
                item = copy.deepcopy(value)
                item.pop("record")
                item.pop("batch")
                item.pop("event_sequence")
                result.append(item)
            return result

        cases = {}
        extra = raw(events)
        forged = copy.deepcopy(extra[0])
        forged["gesture"] = 999
        forged["request"] = 999999
        extra.append(forged)
        extra.sort(key=lambda value: value["monotonic_ns"])
        cases["unknown-gesture"] = extra

        duplicate = raw(events)
        second_gesture = next(value for value in duplicate if value["gesture"] == 22)
        second_gesture["request"] = next(
            value["request"] for value in duplicate if value["gesture"] == 21
        )
        cases["global-duplicate"] = duplicate

        unmapped = raw(events)
        for index, value in enumerate(
            item for item in unmapped if item["event"] == "preview_demanded"
        ):
            value["target_seconds"] = 100.0 + index / 960.0
        cases["unmapped-targets"] = unmapped

        for label, values in cases.items():
            payload = evidence.make_scrub_native_telemetry_payload(values)
            changed, payloads, digest = replace_artifact(
                bundle, "artifact-scrub-native", payload
            )
            with self.subTest(label=label):
                with self.assertRaises(evidence.ScreenDriverEvidenceError):
                    bundle.validate(
                        receipt=changed,
                        payloads=payloads,
                        expected_transcript_sha256=digest,
                    )

    def test_scrub_draws_are_in_drag_and_commit_record_order_is_exact(self):
        bundle = phase_bundle("scrub")
        framed = [
            json.loads(line)
            for line in bundle.payloads["artifact-scrub-native"].splitlines()
        ]
        source = []
        for value in framed:
            if value.get("record") != "event":
                continue
            item = copy.deepcopy(value)
            item.pop("record")
            item.pop("batch")
            item.pop("event_sequence")
            source.append(item)

        post_commit = copy.deepcopy(source)
        for gesture in (21, 22):
            commit = next(
                value
                for value in post_commit
                if value["gesture"] == gesture
                and value["event"] == "commit_frame_drawn"
            )
            draw = next(
                value
                for value in post_commit
                if value["gesture"] == gesture
                and value["event"] == "preview_frame_drawn"
            )
            draw["monotonic_ns"] = commit["monotonic_ns"] + 1
        post_commit.sort(key=lambda value: value["monotonic_ns"])

        reverse_commit = copy.deepcopy(source)
        for gesture in (21, 22):
            ready_index = next(
                index
                for index, value in enumerate(reverse_commit)
                if value["gesture"] == gesture and value["event"] == "commit_ready"
            )
            draw_index = next(
                index
                for index, value in enumerate(reverse_commit)
                if value["gesture"] == gesture
                and value["event"] == "commit_frame_drawn"
            )
            reverse_commit[ready_index], reverse_commit[draw_index] = (
                reverse_commit[draw_index],
                reverse_commit[ready_index],
            )

        for label, values in (
            ("post-commit-preview", post_commit),
            ("reversed-commit", reverse_commit),
        ):
            payload = evidence.make_scrub_native_telemetry_payload(values)
            changed, payloads, digest = replace_artifact(
                bundle, "artifact-scrub-native", payload
            )
            with self.subTest(label=label):
                with self.assertRaises(evidence.ScreenDriverEvidenceError):
                    bundle.validate(
                        receipt=changed,
                        payloads=payloads,
                        expected_transcript_sha256=digest,
                    )

    def test_steady_requires_route_first_frame_and_advancing_samples(self):
        bundle = phase_bundle("steady")
        receipt = copy.deepcopy(bundle.receipt)
        receipt["events"] = receipt["events"][:2]
        for index, value in enumerate(receipt["events"]):
            value["sequence"] = index
        receipt["transcript_sha256"] = evidence.transcript_sha256(
            receipt["events"], receipt["artifacts"]
        )
        with self.assertRaises(evidence.ScreenDriverEvidenceError):
            bundle.validate(receipt=receipt)

        stalled = copy.deepcopy(bundle.receipt)
        sample = next(
            value
            for value in stalled["events"]
            if value["event"] == "steady_playback_sample"
            and value["details"]["sample_index"] == 1
        )
        previous = next(
            value
            for value in stalled["events"]
            if value["event"] == "steady_playback_sample"
            and value["details"]["sample_index"] == 0
        )
        sample["details"]["draw_sequence"] = previous["details"]["draw_sequence"]
        sample["details"]["position_seconds"] = previous["details"]["position_seconds"]
        stalled["transcript_sha256"] = evidence.transcript_sha256(
            stalled["events"], stalled["artifacts"]
        )
        with self.assertRaises(evidence.ScreenDriverEvidenceError):
            bundle.validate(receipt=stalled)

    def test_capture_commands_never_execute_without_injected_runner(self):
        with tempfile.TemporaryDirectory() as temporary:
            tool = Path(temporary) / "capture-tool"
            tool.write_bytes(b"#!/bin/false\ntrusted tool bytes\n")
            tool.chmod(0o755)
            invocation = evidence.identify_trusted_invocation(
                "screen",
                "screen_capture",
                (
                    str(tool.resolve()),
                    "--receipt",
                    f"--capture-context-sha256={self.bundle.capture_context_sha256}",
                ),
                capture_context_sha256=self.bundle.capture_context_sha256,
            )
            with self.assertRaisesRegex(evidence.ScreenDriverEvidenceError, "injected"):
                evidence.run_capture_command(invocation)
            calls = []

            def runner(argv, executable_fd):
                calls.append((argv, Path(f"/dev/fd/{executable_fd}").read_bytes()))
                return evidence.CaptureCommandResult(0, b"receipt", b"")

            result = evidence.run_capture_command(invocation, runner=runner)
            self.assertEqual(result.stdout, b"receipt")
            self.assertEqual(calls[0][0], invocation.argv)
            self.assertEqual(calls[0][1], tool.read_bytes())

            def failed_runner(argv, executable_fd):
                return evidence.CaptureCommandResult(23, b"", b"failure")

            with self.assertRaisesRegex(evidence.ScreenDriverEvidenceError, "nonzero"):
                evidence.run_capture_command(invocation, runner=failed_runner)

    def test_invocation_argv_carries_the_exact_nonce_run_pid_phase_context(self):
        expected_argument = (
            f"--capture-context-sha256={self.bundle.capture_context_sha256}"
        )
        for invocation in self.bundle.invocations:
            self.assertEqual(invocation.argv.count(expected_argument), 1)

        invocation = self.bundle.invocations[0]
        with self.assertRaisesRegex(evidence.ScreenDriverEvidenceError, "context"):
            dataclass_replace(
                invocation,
                argv=tuple(
                    argument
                    for argument in invocation.argv
                    if not argument.startswith("--capture-context-sha256=")
                ),
            )

    def test_identify_tool_hashes_bytes_without_executing(self):
        with tempfile.TemporaryDirectory() as temporary:
            tool = Path(temporary) / "capture-tool"
            tool.write_bytes(b"#!/bin/false\ntrusted tool bytes\n")
            tool.chmod(0o755)
            invocation = evidence.identify_trusted_invocation(
                "screen",
                "screen_capture",
                (
                    str(tool.resolve()),
                    "--receipt",
                    f"--capture-context-sha256={self.bundle.capture_context_sha256}",
                ),
                capture_context_sha256=self.bundle.capture_context_sha256,
            )
            self.assertEqual(invocation.executable_path, str(tool.resolve()))
            self.assertIn("--receipt", invocation.argv)
            self.assertEqual(len(invocation.executable_sha256), 64)

    def test_external_nonce_and_all_binding_fields_are_mandatory(self):
        for field, value in (
            ("run_id", "123e4567-e89b-12d3-a456-426614174001"),
            ("process_id", 5000),
            ("process_start_abstime", 777),
            ("asset_sha256", "d" * 64),
            ("candidate_id", "3" * 64),
            ("source_key", 8),
        ):
            changed = dataclass_replace(self.bundle.binding, **{field: value})
            with self.subTest(field=field):
                with self.assertRaisesRegex(evidence.ScreenDriverEvidenceError, "binding"):
                    self.bundle.validate(expected_binding=changed)
        with self.assertRaisesRegex(evidence.ScreenDriverEvidenceError, "nonce"):
            self.bundle.validate(expected_capture_nonce="e" * 64)

    def test_asset_canonical_path_device_and_inode_are_exact(self):
        for field, value in (
            ("canonical_path", "/tmp/copy.webm"),
            ("device", 99),
            ("inode", 99),
        ):
            changed = dataclass_replace(self.bundle.asset, **{field: value})
            with self.subTest(field=field):
                with self.assertRaisesRegex(evidence.ScreenDriverEvidenceError, "asset"):
                    self.bundle.validate(expected_asset=changed)

    def test_tool_path_hash_argv_and_producer_roles_are_exact(self):
        expected = list(self.bundle.invocations)
        index = next(i for i, value in enumerate(expected) if value.role == "input_driver")
        expected[index] = dataclass_replace(expected[index], executable_sha256="f" * 64)
        expected.sort(key=lambda value: value.invocation_id)
        with self.assertRaisesRegex(evidence.ScreenDriverEvidenceError, "trusted"):
            self.bundle.validate(expected_invocations=tuple(expected))

        changed = copy.deepcopy(self.bundle.receipt)
        screen = next(
            value for value in changed["trusted_invocations"] if value["role"] == "input_driver"
        )
        screen["argv"][-1] = "untrusted-mode"
        with self.assertRaises(evidence.ScreenDriverEvidenceError):
            self.bundle.validate(receipt=changed)

    def test_warm_open_is_a_distinct_delivered_same_process_action(self):
        cases = (
            ("same_process_confirmed", False),
            ("process_was_already_running", False),
            ("delivery_source", "launchservices_completion"),
            ("target_process_start_abstime", 123),
        )
        warm_index = next(
            index
            for index, event in enumerate(self.bundle.events)
            if event["event"] == "warm_open_action"
        )
        for field, value in cases:
            changed = copy.deepcopy(self.bundle.receipt)
            changed["events"][warm_index]["details"][field] = value
            changed["transcript_sha256"] = evidence.transcript_sha256(
                changed["events"], changed["artifacts"]
            )
            with self.subTest(field=field):
                with self.assertRaises(evidence.ScreenDriverEvidenceError):
                    self.bundle.validate(receipt=changed)

    def test_event_clocks_order_and_duplicates_fail_closed(self):
        changed = copy.deepcopy(self.bundle.receipt)
        changed["events"][5]["monotonic_ns"] = changed["events"][4]["monotonic_ns"]
        changed["transcript_sha256"] = evidence.transcript_sha256(
            changed["events"], changed["artifacts"]
        )
        with self.assertRaisesRegex(evidence.ScreenDriverEvidenceError, "strictly increasing"):
            self.bundle.validate(receipt=changed)

        changed = copy.deepcopy(self.bundle.receipt)
        duplicate = copy.deepcopy(changed["events"][5])
        changed["events"].insert(6, duplicate)
        for index, event in enumerate(changed["events"]):
            event["sequence"] = index
            event["monotonic_ns"] = 1_000_000_000 + index * 10_000_000
        changed["transcript_sha256"] = evidence.transcript_sha256(
            changed["events"], changed["artifacts"]
        )
        with self.assertRaises(evidence.ScreenDriverEvidenceError):
            self.bundle.validate(receipt=changed)

    def test_transcript_digest_is_recomputed_over_canonical_events(self):
        changed = copy.deepcopy(self.bundle.receipt)
        changed["transcript_sha256"] = "0" * 64
        with self.assertRaisesRegex(evidence.ScreenDriverEvidenceError, "SHA-256"):
            self.bundle.validate(receipt=changed)

    def test_screen_permissions_and_window_owner_visibility_are_required(self):
        for section, field, value in (
            ("macos_audit", "screen_recording_authorized", False),
            ("macos_audit", "accessibility_authorized", False),
            ("window", "owner_process_id", 9000),
            ("window", "onscreen", False),
            ("window", "frontmost", False),
            ("window", "visible", False),
        ):
            changed = copy.deepcopy(self.bundle.receipt)
            changed[section][field] = value
            with self.subTest(section=section, field=field):
                with self.assertRaises(evidence.ScreenDriverEvidenceError):
                    self.bundle.validate(receipt=changed)

    def test_input_receipt_must_seal_every_pointer_delivery(self):
        for field, value in (
            ("posted_by_harness", False),
            ("event_count", 5),
            ("event_sequence_sha256", "f" * 64),
            ("target_window_id", 88),
        ):
            changed = copy.deepcopy(self.bundle.receipt)
            changed["input_driver_receipt"][field] = value
            with self.subTest(field=field):
                with self.assertRaises(evidence.ScreenDriverEvidenceError):
                    self.bundle.validate(receipt=changed)

    def test_audio_must_be_audible_and_process_scoped(self):
        bundle = phase_bundle("fallback_control")
        audio_index = len(bundle.receipt["events"]) - 1
        for field, value in (
            ("capture_scope", "system"),
            ("target_process_id", 9999),
            ("audio_active", False),
            ("audible", False),
            ("non_silent_frames", 0),
        ):
            changed = copy.deepcopy(bundle.receipt)
            changed["events"][audio_index]["details"][field] = value
            changed["transcript_sha256"] = evidence.transcript_sha256(
                changed["events"], changed["artifacts"]
            )
            with self.subTest(field=field):
                with self.assertRaises(evidence.ScreenDriverEvidenceError):
                    bundle.validate(receipt=changed)

    def test_fallback_media_are_structurally_real_and_post_route(self):
        bundle = phase_bundle("fallback_control")
        fake_png = rgba_png()
        zero_wav = wav_frame_values([0] * 24_000)
        burst_wav = wav_frame_values([1000] * 1_200 + [0] * 22_800)
        dc_wav = wav_frame_values([1000] * 24_000)
        impulse_wav = wav_frame_values(
            [1000 if index % 20 == 0 else 0 for index in range(24_000)]
        )
        one_hz_wav = wav_frame_values([1000], sample_rate=1)
        wrong_byte_rate_wav = wav_frame_values(
            [1000] * 24_000, byte_rate=1
        )
        substitutions = {
            "transparent-png": ("artifact-screen", fake_png),
            "zero-wav": ("artifact-audio", zero_wav),
            "short-burst-wav": ("artifact-audio", burst_wav),
            "constant-dc-wav": ("artifact-audio", dc_wav),
            "impulse-train-wav": ("artifact-audio", impulse_wav),
            "one-hz-wav": ("artifact-audio", one_hz_wav),
            "wrong-byte-rate-wav": ("artifact-audio", wrong_byte_rate_wav),
        }
        for label, (artifact_id, payload) in substitutions.items():
            changed, payloads, digest = replace_artifact(bundle, artifact_id, payload)
            if artifact_id == "artifact-audio":
                samples = struct.unpack(
                    "<" + "h" * ((len(payload) - 44) // 2), payload[44:]
                )
                channels = 2
                frames = len(samples) // channels
                non_silent = sum(
                    any(samples[frame * channels + channel] != 0 for channel in range(channels))
                    for frame in range(frames)
                )
                peak = max(abs(value) for value in samples) if samples else 0
                audio_event = changed["events"][-1]
                audio_event["details"]["sample_rate_hz"] = struct.unpack(
                    "<I", payload[24:28]
                )[0]
                audio_event["details"]["captured_frames"] = frames
                audio_event["details"]["non_silent_frames"] = non_silent
                audio_event["details"]["peak_dbfs"] = (
                    20.0 * math.log10(peak / 32768.0) if peak else -160.0
                )
                digest = evidence.transcript_sha256(
                    changed["events"], changed["artifacts"]
                )
                changed["transcript_sha256"] = digest
            with self.subTest(label=label):
                with self.assertRaises(evidence.ScreenDriverEvidenceError):
                    bundle.validate(
                        receipt=changed,
                        payloads=payloads,
                        expected_transcript_sha256=digest,
                    )

        changed = copy.deepcopy(bundle.receipt)
        screen_record = next(
            record
            for record in changed["artifacts"]
            if record["artifact_id"] == "artifact-screen"
        )
        loader_post = next(
            event
            for event in changed["events"]
            if event["event"] == "loader_post_capture"
        )
        screen_record["capture_started_monotonic_ns"] = (
            loader_post["monotonic_ns"] - 1
        )
        digest = evidence.transcript_sha256(changed["events"], changed["artifacts"])
        changed["transcript_sha256"] = digest
        with self.assertRaisesRegex(evidence.ScreenDriverEvidenceError, "screenshot"):
            bundle.validate(receipt=changed, expected_transcript_sha256=digest)

    def test_fabricated_window_png_tone_and_loader_are_end_to_end_rejected(self):
        bundle = phase_bundle("fallback_control")
        substitutions = {
            "artifact-window": json.dumps(
                {"window_id": 77, "onscreen": True, "frontmost": True}
            ).encode(),
            "artifact-screen": b"arbitrary png bytes",
            "artifact-audio": wav(pattern=(440, -440)),
            "artifact-loader-post": (
                b"library=/Applications/WAM.app/Contents/Frameworks/"
                b"WAMMpvFallback.dylib\nloaded=true\nfabricated=true\n"
            ),
        }
        for artifact_id, payload in substitutions.items():
            changed, payloads, digest = replace_artifact(bundle, artifact_id, payload)
            with self.subTest(artifact_id=artifact_id):
                with self.assertRaises(evidence.ScreenDriverEvidenceError):
                    bundle.validate(
                        receipt=changed,
                        payloads=payloads,
                        expected_transcript_sha256=digest,
                    )

    def test_captured_by_harness_and_explicit_trust_boundary_are_required(self):
        for field, value in (
            ("captured_by_harness", False),
            ("harness_trust_boundary", "cryptographically trusted"),
        ):
            changed = copy.deepcopy(self.bundle.receipt)
            changed[field] = value
            with self.subTest(field=field):
                with self.assertRaises(evidence.ScreenDriverEvidenceError):
                    self.bundle.validate(receipt=changed)

    def test_arbitrary_valid_artifacts_cannot_replace_harness_captures(self):
        substitutions = {
            "artifact-window": json.dumps(
                {"window_id": 77, "onscreen": True, "frontmost": True}
            ).encode(),
            "artifact-dialog": b'{"accepted":true}',
            "artifact-warm-source": b'{"event":"open_requested"}',
        }
        for artifact_id, arbitrary_payload in substitutions.items():
            payloads = dict(self.bundle.payloads)
            payloads[artifact_id] = arbitrary_payload
            changed = copy.deepcopy(self.bundle.receipt)
            record = next(
                value for value in changed["artifacts"] if value["artifact_id"] == artifact_id
            )
            record["sha256"] = hashlib.sha256(arbitrary_payload).hexdigest()
            record["byte_length"] = len(arbitrary_payload)
            changed["transcript_sha256"] = evidence.transcript_sha256(
                changed["events"], changed["artifacts"]
            )
            with self.subTest(artifact_id=artifact_id):
                with self.assertRaisesRegex(
                    evidence.ScreenDriverEvidenceError, "external harness anchor"
                ):
                    self.bundle.validate(receipt=changed, payloads=payloads)

    def test_fabricated_payloads_fail_even_with_rewritten_internal_receipt(self):
        substitutions = {
            "artifact-window": b'{"window_id":77,"onscreen":true}',
            "artifact-dialog": b'{"accepted":true}',
            "artifact-warm-source": b'{"event":"open_requested"}',
        }
        for artifact_id, payload in substitutions.items():
            changed = copy.deepcopy(self.bundle.receipt)
            record = next(
                value for value in changed["artifacts"] if value["artifact_id"] == artifact_id
            )
            record["sha256"] = hashlib.sha256(payload).hexdigest()
            record["byte_length"] = len(payload)
            changed_digest = evidence.transcript_sha256(
                changed["events"], changed["artifacts"]
            )
            changed["transcript_sha256"] = changed_digest
            payloads = dict(self.bundle.payloads)
            payloads[artifact_id] = payload
            with self.subTest(artifact_id=artifact_id):
                with self.assertRaises(evidence.ScreenDriverEvidenceError):
                    self.bundle.validate(
                        receipt=changed,
                        payloads=payloads,
                        expected_transcript_sha256=changed_digest,
                    )

    def test_launchservices_or_telemetry_only_cannot_claim_a_warm_open(self):
        warm_index = next(
            index
            for index, event in enumerate(self.bundle.receipt["events"])
            if event["event"] == "warm_open_action"
        )
        changed = copy.deepcopy(self.bundle.receipt)
        changed["events"][warm_index]["details"][
            "delivery_source"
        ] = "launchservices_completion"
        changed["transcript_sha256"] = evidence.transcript_sha256(
            changed["events"], changed["artifacts"]
        )
        with self.assertRaisesRegex(evidence.ScreenDriverEvidenceError, "warm open"):
            self.bundle.validate(receipt=changed)

        changed = copy.deepcopy(self.bundle.receipt)
        changed["events"] = [
            event
            for event in changed["events"]
            if event["event"] != "warm_open_action"
        ]
        for index, event in enumerate(changed["events"]):
            event["sequence"] = index
        changed["transcript_sha256"] = evidence.transcript_sha256(
            changed["events"], changed["artifacts"]
        )
        with self.assertRaises(evidence.ScreenDriverEvidenceError):
            self.bundle.validate(receipt=changed)

    def test_artifacts_without_matching_trusted_receipt_cannot_pass(self):
        with self.assertRaises(evidence.ScreenDriverEvidenceError):
            evidence.validate_capture_receipt(
                None,
                expected_binding=self.bundle.binding,
                expected_capture_nonce=CAPTURE_NONCE,
                expected_transcript_sha256=self.bundle.external_transcript_sha256,
                expected_phase_variant=self.bundle.phase_variant,
                expected_asset=self.bundle.asset,
                expected_invocations=self.bundle.invocations,
                expected_loader_identity=LOADER_IDENTITY,
                expected_media_duration_seconds=10.0,
                external_attestation=TestAttestation(self.bundle),
                artifact_payloads=self.bundle.payloads,
            )

        changed = copy.deepcopy(self.bundle.receipt)
        changed["trusted_invocations"] = [
            value for value in changed["trusted_invocations"] if value["role"] != "capture_harness"
        ]
        with self.assertRaisesRegex(evidence.ScreenDriverEvidenceError, "roles"):
            self.bundle.validate(receipt=changed)

        changed = copy.deepcopy(self.bundle.receipt)
        changed["macos_audit"]["audit_token_sha256"] = "f" * 64
        with self.assertRaises(evidence.ScreenDriverEvidenceError):
            self.bundle.validate(receipt=changed)


def dataclass_replace(value, **changes):
    return evidence.dataclasses.replace(value, **changes)


if __name__ == "__main__":
    unittest.main()
