"""Focused tests for the local-only Phase 2 synthetic sync fixture."""

from __future__ import annotations

import base64
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from tools.synthetic_sync_fixture import (
    MAX_ATTACHMENT_CIPHERTEXT_BYTES,
    MAX_ATTACHMENT_SOURCE_BYTES,
    build_synthetic_fixture,
    canonical_fixture_bytes,
    validate_synthetic_fixture,
)


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "tools" / "synthetic_sync_fixture.py"


class SyntheticSyncFixtureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = build_synthetic_fixture()

    def test_generation_is_byte_deterministic(self):
        first = canonical_fixture_bytes(build_synthetic_fixture())
        second = canonical_fixture_bytes(build_synthetic_fixture())
        self.assertEqual(first, second)

    def test_fixture_declares_local_synthetic_provenance(self):
        self.assertEqual(
            self.fixture["provenance"],
            {
                "classification": "SYNTHETIC_ONLY",
                "contains_real_user_data": False,
                "remote_resources_allowed": False,
            },
        )

    def test_two_accounts_keep_the_same_room_uuid_tenant_isolated(self):
        rooms = self.fixture["rooms"]
        shared_room_ids = {row["room_id"] for row in rooms}
        self.assertIn("10000000-0000-4000-8000-000000000001", shared_room_ids)

        matching = [
            (row["account_id"], row["space_id"])
            for row in rooms
            if row["room_id"] == "10000000-0000-4000-8000-000000000001"
        ]
        self.assertEqual(
            matching,
            [
                ("A0000000-0000-4000-8000-000000000001", "MAC_SPACE"),
                ("A0000000-0000-4000-8000-000000000001", "PHONE_SPACE"),
                ("A0000000-0000-4000-8000-000000000002", "MAC_SPACE"),
            ],
        )

    def test_fixture_covers_all_canonical_spaces(self):
        self.assertEqual(
            {device["space_id"] for device in self.fixture["devices"]},
            {"MAC_SPACE", "PHONE_SPACE", "TABLET_SPACE"},
        )

    def test_group_state_is_phone_only_and_has_no_worldline_identity(self):
        group_states = self.fixture["group_states"]
        self.assertEqual(len(group_states), 1)
        self.assertEqual(group_states[0]["space_id"], "PHONE_SPACE")
        self.assertNotIn("worldline_id", group_states[0])
        self.assertNotIn("worldline_key", group_states[0])

    def test_worldlines_cover_null_and_named_bindings_in_phone_space(self):
        worldlines = self.fixture["worldlines"]
        self.assertEqual(
            [(row["worldline_id"], row["worldline_key"]) for row in worldlines],
            [
                (None, ""),
                (
                    "20000000-0000-4000-8000-000000000001",
                    "20000000-0000-4000-8000-000000000001",
                ),
            ],
        )
        self.assertEqual({row["space_id"] for row in worldlines}, {"PHONE_SPACE"})

    def test_envelope_is_canonical_padded_base64_with_minimum_shape(self):
        encoded = self.fixture["opaque_envelopes"]["minimal_v1_aes_gcm"]
        raw = base64.b64decode(encoded, validate=True)
        self.assertEqual(len(raw), 34)
        self.assertEqual(raw[:2], b"\x01\x01")
        self.assertEqual(base64.b64encode(raw).decode("ascii"), encoded)

    def test_validator_rejects_worldline_binding_drift(self):
        self.fixture["worldlines"][0]["worldline_key"] = "WRONG"
        with self.assertRaisesRegex(ValueError, "worldline binding"):
            validate_synthetic_fixture(self.fixture)

    def test_m04_fixture_links_room_to_exact_profile_and_snapshot_revisions(self):
        ref = self.fixture["room_ai_state_refs"][0]
        self.assertEqual(ref["engine_profile_revision"], 1)
        self.assertEqual(ref["persona_snapshot_revision"], 1)

        profile_keys = {
            (
                row["account_id"],
                row["space_id"],
                row["engine_profile_id"],
                row["profile_revision"],
            )
            for row in self.fixture["engine_profiles"]
        }
        snapshot_keys = {
            (
                row["account_id"],
                row["space_id"],
                row["persona_snapshot_id"],
                row["snapshot_revision"],
            )
            for row in self.fixture["persona_snapshots"]
        }
        self.assertIn(
            (
                ref["account_id"],
                ref["space_id"],
                ref["engine_profile_id"],
                ref["engine_profile_revision"],
            ),
            profile_keys,
        )
        self.assertIn(
            (
                ref["account_id"],
                ref["space_id"],
                ref["persona_snapshot_id"],
                ref["persona_snapshot_revision"],
            ),
            snapshot_keys,
        )

    def test_persona_head_points_to_exact_immutable_snapshot(self):
        head = self.fixture["persona_snapshot_heads"][0]
        self.assertEqual(head["current_snapshot_revision"], 1)
        self.assertNotIn("head_revision", head)
        self.assertTrue(
            any(
                row["account_id"] == head["account_id"]
                and row["space_id"] == head["space_id"]
                and row["persona_snapshot_id"] == head["persona_snapshot_id"]
                and row["snapshot_revision"] == head["current_snapshot_revision"]
                for row in self.fixture["persona_snapshots"]
            )
        )

    def test_checkpoint_fixture_uses_nullable_m06_sequence_and_default_scope(self):
        checkpoint = self.fixture["checkpoints"][0]
        self.assertIsNone(checkpoint["worldline_id"])
        self.assertEqual(checkpoint["worldline_key"], "")
        self.assertIsNone(checkpoint["through_server_seq"])
        self.assertIsNone(checkpoint["first_turn_id"])
        self.assertIsNone(checkpoint["last_turn_id"])
        self.assertEqual(checkpoint["revision"], 0)

    def test_m05_attachment_fixture_uses_exact_binary_envelope_size_contract(self):
        attachment = self.fixture["attachments"][0]
        self.assertEqual(MAX_ATTACHMENT_SOURCE_BYTES, 12_582_912)
        self.assertEqual(MAX_ATTACHMENT_CIPHERTEXT_BYTES, 12_582_946)
        self.assertEqual(
            attachment["ciphertext_byte_size"],
            attachment["source_byte_size"] + 34,
        )
        self.assertEqual(attachment["state"], "allocated")
        self.assertEqual(attachment["key_generation"], 1)
        self.assertEqual(len(attachment["ciphertext_hash"]), 64)
        self.assertNotIn("content", attachment)
        self.assertNotIn("ciphertext", attachment)

    def test_validator_rejects_attachment_size_or_state_drift(self):
        self.fixture["attachments"][0]["ciphertext_byte_size"] += 1
        with self.assertRaisesRegex(ValueError, "attachment size"):
            validate_synthetic_fixture(self.fixture)

        self.fixture = build_synthetic_fixture()
        self.fixture["attachments"][0]["state"] = "uploading"
        with self.assertRaisesRegex(ValueError, "attachment state"):
            validate_synthetic_fixture(self.fixture)

    def test_m06_fixture_uses_next_unallocated_sequence_and_one_change(self):
        accounts = {row["account_id"]: row for row in self.fixture["accounts"]}
        operation = self.fixture["operation_logs"][0]
        change = self.fixture["change_logs"][0]
        self.assertEqual(operation["server_seq"], 1)
        self.assertEqual(change["server_seq"], 1)
        self.assertEqual(accounts[operation["account_id"]]["next_server_seq"], 2)
        self.assertEqual(operation["change_kind"], "upsert")
        self.assertEqual(len(self.fixture["operation_logs"]), 1)
        self.assertEqual(len(self.fixture["change_logs"]), 1)

    def test_m06_change_identity_has_exact_room_storage_axes(self):
        change = self.fixture["change_logs"][0]
        present = {
            key
            for key, value in change.items()
            if value is not None
            and key
            in {
                "space_id",
                "room_id",
                "worldline_key",
                "turn_id",
                "message_id",
                "persona_snapshot_id",
                "snapshot_revision",
                "engine_profile_id",
                "profile_revision",
                "checkpoint_id",
                "attachment_id",
            }
        }
        self.assertEqual(present, {"space_id", "room_id"})

    def test_validator_rejects_m06_identity_or_sequence_drift(self):
        self.fixture["change_logs"][0]["attachment_id"] = (
            "70000000-0000-4000-8000-000000000002"
        )
        with self.assertRaisesRegex(ValueError, "change identity"):
            validate_synthetic_fixture(self.fixture)

        self.fixture = build_synthetic_fixture()
        self.fixture["accounts"][0]["next_server_seq"] = 0
        with self.assertRaisesRegex(ValueError, "next server sequence"):
            validate_synthetic_fixture(self.fixture)

    def test_m06_atomic_scenarios_consume_sequence_only_once(self):
        scenarios = {row["name"]: row for row in self.fixture["atomic_scenarios"]}
        applied = scenarios["new_operation"]
        self.assertEqual(applied["sequence_after"], applied["sequence_before"] + 1)
        self.assertEqual(applied["operation_rows_delta"], 1)
        self.assertEqual(applied["change_rows_delta"], 1)
        for name, scenario in scenarios.items():
            if name == "new_operation":
                continue
            self.assertEqual(scenario["sequence_after"], scenario["sequence_before"])
            self.assertEqual(scenario["operation_rows_delta"], 0)
            self.assertEqual(scenario["change_rows_delta"], 0)
            self.assertEqual(scenario["canonical_rows_delta"], 0)

    def test_validator_rejects_atomic_failure_that_consumes_sequence(self):
        scenario = next(
            row
            for row in self.fixture["atomic_scenarios"]
            if row["name"] == "cas_mismatch"
        )
        scenario["sequence_after"] += 1
        with self.assertRaisesRegex(ValueError, "consumed a sequence"):
            validate_synthetic_fixture(self.fixture)

    def test_cross_space_write_is_an_atomic_auth_failure(self):
        scenario = next(
            row
            for row in self.fixture["atomic_scenarios"]
            if row["name"] == "cross_space_write"
        )
        self.assertEqual(scenario["outcome"], "AUTH_INVALID")
        self.assertEqual(scenario["sequence_after"], scenario["sequence_before"])
        self.assertEqual(scenario["operation_rows_delta"], 0)
        self.assertEqual(scenario["change_rows_delta"], 0)
        self.assertEqual(scenario["canonical_rows_delta"], 0)

    def test_read_scenarios_cover_crash_reapply_and_late_write_recovery(self):
        scenarios = {row["name"]: row for row in self.fixture["read_scenarios"]}
        replay = scenarios["changes_page_crash_reapply"]
        self.assertEqual(replay["page_change_seqs"], [1])
        self.assertEqual(replay["apply_count"], 2)
        self.assertEqual(replay["expected_replica_writes"], 1)
        self.assertEqual(replay["scanned_through_seq"], 1)

        bootstrap = scenarios["bootstrap_late_write_recovery"]
        self.assertEqual(bootstrap["snapshot_high_watermark_seq"], 1)
        self.assertEqual(bootstrap["late_write_server_seq"], 2)
        self.assertEqual(bootstrap["changes_after_seq"], 1)
        self.assertEqual(bootstrap["expected_recovered_change_seqs"], [2])
        self.assertEqual(scenarios["cross_account_read"]["outcome"], "EMPTY_RESULT")

    def test_validator_rejects_read_recovery_drift(self):
        scenario = next(
            row
            for row in self.fixture["read_scenarios"]
            if row["name"] == "bootstrap_late_write_recovery"
        )
        scenario["changes_after_seq"] = 2
        with self.assertRaisesRegex(ValueError, "bootstrap recovery"):
            validate_synthetic_fixture(self.fixture)

    def test_r2_scenarios_consume_sequence_only_when_ready(self):
        scenarios = {row["name"]: row for row in self.fixture["r2_scenarios"]}
        self.assertEqual(scenarios["allocated_to_uploaded"]["sequence_delta"], 0)
        self.assertEqual(scenarios["uploaded_to_ready"]["sequence_delta"], 1)
        self.assertEqual(scenarios["uploaded_to_ready"]["change_rows_delta"], 1)
        self.assertFalse(scenarios["checksum_mismatch"]["object_persisted"])
        orphan = scenarios["r2_success_d1_failure_orphan"]
        self.assertTrue(orphan["object_persisted"])
        self.assertFalse(orphan["automatic_cleanup"])

    def test_validator_rejects_ready_transition_without_one_change(self):
        scenario = next(
            row
            for row in self.fixture["r2_scenarios"]
            if row["name"] == "uploaded_to_ready"
        )
        scenario["change_rows_delta"] = 0
        with self.assertRaisesRegex(ValueError, "ready transition"):
            validate_synthetic_fixture(self.fixture)

    def test_validator_rejects_cross_space_room_ai_reference(self):
        self.fixture["room_ai_state_refs"][0]["space_id"] = "MAC_SPACE"
        with self.assertRaisesRegex(ValueError, "room AI state reference"):
            validate_synthetic_fixture(self.fixture)

    def test_validator_rejects_non_positive_immutable_revision(self):
        self.fixture["engine_profiles"][0]["profile_revision"] = 0
        with self.assertRaisesRegex(ValueError, "immutable revision"):
            validate_synthetic_fixture(self.fixture)

    def test_fixture_has_no_content_token_or_recovery_fields(self):
        forbidden_keys = {
            "content",
            "message",
            "text",
            "token",
            "recovery_phrase",
            "recovery_code",
        }

        def keys(value: object) -> set[str]:
            if isinstance(value, dict):
                found = set(value)
                for child in value.values():
                    found.update(keys(child))
                return found
            if isinstance(value, list):
                found: set[str] = set()
                for child in value:
                    found.update(keys(child))
                return found
            return set()

        self.assertTrue(forbidden_keys.isdisjoint(keys(self.fixture)))

    def test_cli_writes_file_without_printing_identifiers_or_envelope(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "fixture.json"
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--output", str(output)],
                cwd=REPO_ROOT,
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            written = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(written, self.fixture)
            combined = result.stdout + result.stderr
            self.assertNotIn(self.fixture["accounts"][0]["account_id"], combined)
            self.assertNotIn(
                self.fixture["opaque_envelopes"]["minimal_v1_aes_gcm"], combined
            )
            self.assertRegex(result.stdout, r"records=\d+ sha256=[0-9a-f]{64}")


if __name__ == "__main__":
    unittest.main()
