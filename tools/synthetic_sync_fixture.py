#!/usr/bin/env python3
"""Build a deterministic, local-only synthetic sync fixture.

The fixture contains structural contract data only. It never reads Gagaodok
archives, contacts a remote service, or prints identifiers or opaque envelope
bytes. The fixed envelope is a non-cryptographic shape sentinel, not user data.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path
import sys
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.canonical_schema_contract import (
    PHONE_SPACE,
    SPACE_IDS,
    canonical_uuid,
    validate_worldline_binding,
)


ACCOUNT_A = "A0000000-0000-4000-8000-000000000001"
ACCOUNT_B = "A0000000-0000-4000-8000-000000000002"
DEVICE_MAC = "80000000-0000-4000-8000-000000000001"
DEVICE_PHONE = "80000000-0000-4000-8000-000000000002"
DEVICE_TABLET = "80000000-0000-4000-8000-000000000003"
ROOM_SHARED = "10000000-0000-4000-8000-000000000001"
WORLDLINE_NAMED = "20000000-0000-4000-8000-000000000001"
ENGINE_PROFILE = "C0000000-0000-4000-8000-0000000000E1"
PERSONA_SNAPSHOT = "50000000-0000-4000-8000-000000000001"
CHECKPOINT = "60000000-0000-4000-8000-000000000001"
ATTACHMENT = "70000000-0000-4000-8000-000000000001"
OPERATION = "90000000-0000-4000-8000-000000000001"

MAX_ATTACHMENT_SOURCE_BYTES = 12_582_912
ATTACHMENT_BINARY_ENVELOPE_OVERHEAD = 34
MAX_ATTACHMENT_CIPHERTEXT_BYTES = (
    MAX_ATTACHMENT_SOURCE_BYTES + ATTACHMENT_BINARY_ENVELOPE_OVERHEAD
)
ATTACHMENT_STATES = {
    "allocated",
    "uploaded",
    "ready",
    "abandoned",
    "tombstoned",
    "garbage_collected",
}


def _minimal_shape_envelope() -> str:
    # E2EE v1 structural minimum: version + algorithm + key generation +
    # 12-byte nonce slot + 16-byte tag slot. It is deliberately not encrypted.
    raw = b"\x01\x01" + (1).to_bytes(4, "big") + bytes(range(1, 13)) + bytes(16)
    return base64.b64encode(raw).decode("ascii")


def build_synthetic_fixture() -> dict[str, Any]:
    fixture: dict[str, Any] = {
        "schema_version": 1,
        "provenance": {
            "classification": "SYNTHETIC_ONLY",
            "contains_real_user_data": False,
            "remote_resources_allowed": False,
        },
        "accounts": [
            {"account_id": ACCOUNT_A, "next_server_seq": 2},
            {"account_id": ACCOUNT_B, "next_server_seq": 1},
        ],
        "devices": [
            {
                "account_id": ACCOUNT_A,
                "device_id": DEVICE_MAC,
                "space_id": "MAC_SPACE",
                "revoked_at": None,
            },
            {
                "account_id": ACCOUNT_A,
                "device_id": DEVICE_PHONE,
                "space_id": PHONE_SPACE,
                "revoked_at": None,
            },
            {
                "account_id": ACCOUNT_A,
                "device_id": DEVICE_TABLET,
                "space_id": "TABLET_SPACE",
                "revoked_at": "2026-01-01T00:00:00Z",
            },
        ],
        "rooms": [
            {"account_id": ACCOUNT_A, "space_id": "MAC_SPACE", "room_id": ROOM_SHARED},
            {"account_id": ACCOUNT_A, "space_id": PHONE_SPACE, "room_id": ROOM_SHARED},
            {"account_id": ACCOUNT_B, "space_id": "MAC_SPACE", "room_id": ROOM_SHARED},
        ],
        "group_states": [
            {"account_id": ACCOUNT_A, "space_id": PHONE_SPACE, "room_id": ROOM_SHARED}
        ],
        "worldlines": [
            {
                "account_id": ACCOUNT_A,
                "space_id": PHONE_SPACE,
                "room_id": ROOM_SHARED,
                "worldline_id": None,
                "worldline_key": "",
            },
            {
                "account_id": ACCOUNT_A,
                "space_id": PHONE_SPACE,
                "room_id": ROOM_SHARED,
                "worldline_id": WORLDLINE_NAMED,
                "worldline_key": WORLDLINE_NAMED,
            },
        ],
        "engine_profiles": [
            {
                "account_id": ACCOUNT_A,
                "space_id": PHONE_SPACE,
                "engine_profile_id": ENGINE_PROFILE,
                "profile_revision": 1,
                "server_seq": None,
            }
        ],
        "persona_snapshots": [
            {
                "account_id": ACCOUNT_A,
                "space_id": PHONE_SPACE,
                "persona_snapshot_id": PERSONA_SNAPSHOT,
                "snapshot_revision": 1,
                "owner_space_id": PHONE_SPACE,
                "created_by_device_id": DEVICE_PHONE,
                "persona_schema_version": 1,
                "server_seq": None,
            }
        ],
        "persona_snapshot_heads": [
            {
                "account_id": ACCOUNT_A,
                "space_id": PHONE_SPACE,
                "persona_snapshot_id": PERSONA_SNAPSHOT,
                "current_snapshot_revision": 1,
            }
        ],
        "room_ai_state_refs": [
            {
                "account_id": ACCOUNT_A,
                "space_id": PHONE_SPACE,
                "room_id": ROOM_SHARED,
                "engine_profile_id": ENGINE_PROFILE,
                "engine_profile_revision": 1,
                "persona_snapshot_id": PERSONA_SNAPSHOT,
                "persona_snapshot_revision": 1,
            }
        ],
        "checkpoints": [
            {
                "account_id": ACCOUNT_A,
                "space_id": PHONE_SPACE,
                "room_id": ROOM_SHARED,
                "worldline_id": None,
                "worldline_key": "",
                "checkpoint_id": CHECKPOINT,
                "first_turn_id": None,
                "last_turn_id": None,
                "through_server_seq": None,
                "owner_space_id": PHONE_SPACE,
                "created_by_device_id": DEVICE_PHONE,
                "checkpoint_schema_version": 1,
                "revision": 0,
                "server_seq": None,
            }
        ],
        "attachments": [
            {
                "account_id": ACCOUNT_A,
                "attachment_id": ATTACHMENT,
                "origin_space_id": PHONE_SPACE,
                "r2_object_key": "obj/70000000-0000-4000-8000-0000000000FF",
                "kind": "attachment",
                "state": "allocated",
                "source_byte_size": 64,
                "ciphertext_byte_size": 64 + ATTACHMENT_BINARY_ENVELOPE_OVERHEAD,
                "ciphertext_hash": "00" * 32,
                "key_generation": 1,
                "file_name_enc": _minimal_shape_envelope(),
                "mime_type_enc": _minimal_shape_envelope(),
                "wrapped_file_key_enc": _minimal_shape_envelope(),
                "created_at": "2026-01-01T00:00:00Z",
                "server_seq": None,
            }
        ],
        "operation_logs": [
            {
                "account_id": ACCOUNT_A,
                "operation_id": OPERATION,
                "request_fingerprint": "11" * 32,
                "entity_type": "room",
                "change_kind": "upsert",
                "result_revision": 0,
                "server_seq": 1,
            }
        ],
        "change_logs": [
            {
                "account_id": ACCOUNT_A,
                "server_seq": 1,
                "entity_type": "room",
                "change_kind": "upsert",
                "revision": 0,
                "space_id": "MAC_SPACE",
                "room_id": ROOM_SHARED,
                "worldline_key": None,
                "turn_id": None,
                "message_id": None,
                "persona_snapshot_id": None,
                "snapshot_revision": None,
                "engine_profile_id": None,
                "profile_revision": None,
                "checkpoint_id": None,
                "attachment_id": None,
            }
        ],
        "atomic_scenarios": [
            {
                "name": "new_operation",
                "outcome": "applied",
                "sequence_before": 1,
                "sequence_after": 2,
                "operation_rows_delta": 1,
                "change_rows_delta": 1,
                "canonical_rows_delta": 1,
            },
            {
                "name": "same_fingerprint_replay",
                "outcome": "replayed",
                "sequence_before": 2,
                "sequence_after": 2,
                "operation_rows_delta": 0,
                "change_rows_delta": 0,
                "canonical_rows_delta": 0,
            },
            {
                "name": "different_fingerprint_replay",
                "outcome": "OPERATION_REPLAY_MISMATCH",
                "sequence_before": 2,
                "sequence_after": 2,
                "operation_rows_delta": 0,
                "change_rows_delta": 0,
                "canonical_rows_delta": 0,
            },
            {
                "name": "cas_mismatch",
                "outcome": "REVISION_CONFLICT",
                "sequence_before": 2,
                "sequence_after": 2,
                "operation_rows_delta": 0,
                "change_rows_delta": 0,
                "canonical_rows_delta": 0,
            },
            {
                "name": "revoked_device_write",
                "outcome": "DEVICE_REVOKED",
                "sequence_before": 2,
                "sequence_after": 2,
                "operation_rows_delta": 0,
                "change_rows_delta": 0,
                "canonical_rows_delta": 0,
            },
        ],
        "opaque_envelopes": {"minimal_v1_aes_gcm": _minimal_shape_envelope()},
    }
    validate_synthetic_fixture(fixture)
    return fixture


def canonical_fixture_bytes(fixture: dict[str, Any]) -> bytes:
    validate_synthetic_fixture(fixture)
    return (
        json.dumps(fixture, ensure_ascii=True, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")


def validate_synthetic_fixture(fixture: dict[str, Any]) -> None:
    provenance = fixture.get("provenance")
    if provenance != {
        "classification": "SYNTHETIC_ONLY",
        "contains_real_user_data": False,
        "remote_resources_allowed": False,
    }:
        raise ValueError("fixture must declare local synthetic provenance")

    account_ids = set()
    for account in fixture.get("accounts", []):
        account_ids.add(canonical_uuid(account.get("account_id"), field="account_id"))
    if account_ids != {ACCOUNT_A, ACCOUNT_B}:
        raise ValueError("fixture must use the reserved synthetic account set")
    for account in fixture.get("accounts", []):
        next_seq = account.get("next_server_seq")
        if isinstance(next_seq, bool) or not isinstance(next_seq, int) or not 1 <= next_seq <= 2**53:
            raise ValueError("next server sequence is invalid")

    for collection in (
        "devices",
        "rooms",
        "group_states",
        "worldlines",
        "engine_profiles",
        "persona_snapshots",
        "persona_snapshot_heads",
        "room_ai_state_refs",
        "checkpoints",
    ):
        for row in fixture.get(collection, []):
            if row.get("account_id") not in account_ids:
                raise ValueError(f"{collection} row crosses the synthetic account boundary")
            if row.get("space_id") not in SPACE_IDS:
                raise ValueError(f"{collection} row has a non-canonical space")

    for row in fixture.get("devices", []):
        canonical_uuid(row.get("device_id"), field="device_id")
    for row in fixture.get("rooms", []):
        canonical_uuid(row.get("room_id"), field="room_id")

    for row in fixture.get("group_states", []):
        if row.get("space_id") != PHONE_SPACE:
            raise ValueError("group_state must use PHONE_SPACE")
        if "worldline_id" in row or "worldline_key" in row:
            raise ValueError("group_state must not carry worldline identity")

    for row in fixture.get("worldlines", []):
        if row.get("space_id") != PHONE_SPACE:
            raise ValueError("worldline must use PHONE_SPACE")
        try:
            validate_worldline_binding(row.get("worldline_id"), row.get("worldline_key"))
        except ValueError as error:
            raise ValueError("worldline binding is invalid") from error

    profile_keys = set()
    for row in fixture.get("engine_profiles", []):
        canonical_uuid(row.get("engine_profile_id"), field="engine_profile_id")
        revision = row.get("profile_revision")
        if isinstance(revision, bool) or not isinstance(revision, int) or revision < 1:
            raise ValueError("immutable revision must be a positive integer")
        profile_keys.add(
            (row.get("account_id"), row.get("space_id"), row.get("engine_profile_id"), revision)
        )

    snapshot_keys = set()
    for row in fixture.get("persona_snapshots", []):
        canonical_uuid(row.get("persona_snapshot_id"), field="persona_snapshot_id")
        revision = row.get("snapshot_revision")
        if isinstance(revision, bool) or not isinstance(revision, int) or revision < 1:
            raise ValueError("immutable revision must be a positive integer")
        if row.get("owner_space_id") != row.get("space_id"):
            raise ValueError("persona owner space must match snapshot space")
        snapshot_keys.add(
            (row.get("account_id"), row.get("space_id"), row.get("persona_snapshot_id"), revision)
        )

    for row in fixture.get("persona_snapshot_heads", []):
        key = (
            row.get("account_id"),
            row.get("space_id"),
            row.get("persona_snapshot_id"),
            row.get("current_snapshot_revision"),
        )
        if key not in snapshot_keys:
            raise ValueError("persona head must reference an immutable snapshot")

    room_keys = {
        (row.get("account_id"), row.get("space_id"), row.get("room_id"))
        for row in fixture.get("rooms", [])
    }
    for row in fixture.get("room_ai_state_refs", []):
        room_key = (row.get("account_id"), row.get("space_id"), row.get("room_id"))
        profile_key = (
            row.get("account_id"),
            row.get("space_id"),
            row.get("engine_profile_id"),
            row.get("engine_profile_revision"),
        )
        snapshot_key = (
            row.get("account_id"),
            row.get("space_id"),
            row.get("persona_snapshot_id"),
            row.get("persona_snapshot_revision"),
        )
        if room_key not in room_keys or profile_key not in profile_keys or snapshot_key not in snapshot_keys:
            raise ValueError("room AI state reference must use exact same-space owners")

    for row in fixture.get("checkpoints", []):
        try:
            validate_worldline_binding(row.get("worldline_id"), row.get("worldline_key"))
        except ValueError as error:
            raise ValueError("checkpoint worldline binding is invalid") from error
        if row.get("worldline_id") is not None and row.get("space_id") != PHONE_SPACE:
            raise ValueError("named checkpoint worldline must use PHONE_SPACE")
        if (row.get("first_turn_id") is None) != (row.get("last_turn_id") is None):
            raise ValueError("checkpoint turn range must be wholly present or absent")

    r2_keys = set()
    for row in fixture.get("attachments", []):
        if row.get("account_id") not in account_ids:
            raise ValueError("attachment row crosses the synthetic account boundary")
        canonical_uuid(row.get("attachment_id"), field="attachment_id")
        if row.get("origin_space_id") not in SPACE_IDS:
            raise ValueError("attachment origin space is not canonical")
        if row.get("kind") not in {"attachment", "avatar"}:
            raise ValueError("attachment kind is invalid")
        if row.get("state") not in ATTACHMENT_STATES:
            raise ValueError("attachment state is invalid")
        source_size = row.get("source_byte_size")
        ciphertext_size = row.get("ciphertext_byte_size")
        if (
            isinstance(source_size, bool)
            or not isinstance(source_size, int)
            or source_size < 1
            or source_size > MAX_ATTACHMENT_SOURCE_BYTES
            or ciphertext_size != source_size + ATTACHMENT_BINARY_ENVELOPE_OVERHEAD
            or ciphertext_size > MAX_ATTACHMENT_CIPHERTEXT_BYTES
        ):
            raise ValueError("attachment size contract is invalid")
        digest = row.get("ciphertext_hash")
        if (
            not isinstance(digest, str)
            or len(digest) != 64
            or any(character not in "0123456789abcdef" for character in digest)
        ):
            raise ValueError("attachment ciphertext hash is invalid")
        if row.get("key_generation") != 1:
            raise ValueError("attachment key generation is invalid")
        r2_key = row.get("r2_object_key")
        unique_key = (row.get("account_id"), r2_key)
        if not isinstance(r2_key, str) or not r2_key or unique_key in r2_keys:
            raise ValueError("attachment R2 object key is invalid")
        r2_keys.add(unique_key)

    operation_keys = set()
    operation_sequences = set()
    for row in fixture.get("operation_logs", []):
        if row.get("account_id") not in account_ids:
            raise ValueError("operation log crosses the synthetic account boundary")
        canonical_uuid(row.get("operation_id"), field="operation_id")
        fingerprint = row.get("request_fingerprint")
        if (
            not isinstance(fingerprint, str)
            or len(fingerprint) != 64
            or any(character not in "0123456789abcdef" for character in fingerprint)
        ):
            raise ValueError("operation fingerprint is invalid")
        if row.get("change_kind") not in {"upsert", "tombstone"}:
            raise ValueError("operation change kind is invalid")
        server_seq = row.get("server_seq")
        if isinstance(server_seq, bool) or not isinstance(server_seq, int) or not 1 <= server_seq < 2**53:
            raise ValueError("operation server sequence is invalid")
        result_revision = row.get("result_revision")
        if result_revision is not None and (
            isinstance(result_revision, bool)
            or not isinstance(result_revision, int)
            or result_revision < 0
            or result_revision >= 2**53
        ):
            raise ValueError("operation result revision is invalid")
        key = (row.get("account_id"), row.get("operation_id"))
        sequence = (row.get("account_id"), row.get("server_seq"))
        if key in operation_keys or sequence in operation_sequences:
            raise ValueError("operation ledger key is not unique")
        operation_keys.add(key)
        operation_sequences.add(sequence)

    identity_columns = {
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
    identity_shapes = {
        "room": {"space_id", "room_id"},
        "group_state": {"space_id", "room_id"},
        "worldline": {"space_id", "room_id", "worldline_key"},
        "turn": {"space_id", "room_id", "worldline_key", "turn_id"},
        "bubble": {"space_id", "room_id", "worldline_key", "turn_id", "message_id"},
        "persona_snapshot": {"space_id", "persona_snapshot_id", "snapshot_revision"},
        "engine_profile": {"space_id", "engine_profile_id", "profile_revision"},
        "checkpoint": {"space_id", "room_id", "worldline_key", "checkpoint_id"},
        "attachment": {"attachment_id"},
    }
    change_keys = set()
    for row in fixture.get("change_logs", []):
        if row.get("account_id") not in account_ids:
            raise ValueError("change log crosses the synthetic account boundary")
        if row.get("change_kind") not in {"upsert", "tombstone"}:
            raise ValueError("change kind is invalid")
        key = (row.get("account_id"), row.get("server_seq"))
        if key in change_keys or key not in operation_sequences:
            raise ValueError("change sequence is invalid")
        change_keys.add(key)
        expected = identity_shapes.get(row.get("entity_type"))
        present = {column for column in identity_columns if row.get(column) is not None}
        if expected is None or present != expected:
            raise ValueError("change identity shape is invalid")

    expected_scenarios = {
        "new_operation": ("applied", 1, 1, 1),
        "same_fingerprint_replay": ("replayed", 0, 0, 0),
        "different_fingerprint_replay": ("OPERATION_REPLAY_MISMATCH", 0, 0, 0),
        "cas_mismatch": ("REVISION_CONFLICT", 0, 0, 0),
        "revoked_device_write": ("DEVICE_REVOKED", 0, 0, 0),
    }
    scenarios = fixture.get("atomic_scenarios", [])
    if {row.get("name") for row in scenarios} != set(expected_scenarios):
        raise ValueError("atomic scenario set is incomplete")
    for row in scenarios:
        expected = expected_scenarios[row["name"]]
        observed = (
            row.get("outcome"),
            row.get("operation_rows_delta"),
            row.get("change_rows_delta"),
            row.get("canonical_rows_delta"),
        )
        if observed != expected:
            raise ValueError("atomic scenario outcome is invalid")
        before = row.get("sequence_before")
        after = row.get("sequence_after")
        if row["name"] == "new_operation":
            if after != before + 1:
                raise ValueError("applied operation must consume one sequence")
        elif after != before:
            raise ValueError("failed or replayed operation consumed a sequence")

    encoded = fixture.get("opaque_envelopes", {}).get("minimal_v1_aes_gcm")
    if not isinstance(encoded, str):
        raise ValueError("minimal structural envelope is missing")
    try:
        raw = base64.b64decode(encoded, validate=True)
    except (ValueError, base64.binascii.Error) as error:
        raise ValueError("minimal structural envelope is not canonical Base64") from error
    if len(raw) != 34 or raw[:2] != b"\x01\x01":
        raise ValueError("minimal structural envelope has the wrong shape")
    if base64.b64encode(raw).decode("ascii") != encoded:
        raise ValueError("minimal structural envelope is not canonical Base64")


def _record_count(fixture: dict[str, Any]) -> int:
    return sum(
        len(fixture[name])
        for name in (
            "accounts",
            "devices",
            "rooms",
            "group_states",
            "worldlines",
            "engine_profiles",
            "persona_snapshots",
            "persona_snapshot_heads",
            "room_ai_state_refs",
            "checkpoints",
            "attachments",
            "operation_logs",
            "change_logs",
            "atomic_scenarios",
        )
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)

    fixture = build_synthetic_fixture()
    payload = canonical_fixture_bytes(fixture)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(payload)
    digest = hashlib.sha256(payload).hexdigest()
    print(f"synthetic fixture written: records={_record_count(fixture)} sha256={digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
