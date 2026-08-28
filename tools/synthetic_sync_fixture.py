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
            {"account_id": ACCOUNT_A},
            {"account_id": ACCOUNT_B},
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
