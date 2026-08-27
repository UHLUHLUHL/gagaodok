#!/usr/bin/env python3
"""Dependency-free Gagaodok E2EE LP v1 and HKDF contract verifier."""

from __future__ import annotations

import hashlib
import hmac
import json
import uuid
from collections.abc import Iterable


PROTOCOL_SALT = b"gagaodok/e2ee/v1/hkdf-salt"
PROTOCOL_VERSION = 1
LP_MAGIC = b"GDK1"


def _canonical_uuid_ascii(value: str) -> bytes:
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError) as error:
        raise ValueError("UUID is invalid") from error
    if str(parsed).upper() != value:
        raise ValueError("UUID must use uppercase hyphenated ASCII")
    return value.encode("ascii")


def encode_lp(fields: Iterable[tuple[int, bytes | None]]) -> bytes:
    items = list(fields)
    if len(items) > 0xFFFF:
        raise ValueError("too many LP fields")

    previous_id = 0
    output = bytearray(LP_MAGIC)
    output.extend(len(items).to_bytes(2, "big"))
    for field_id, value in items:
        if not 1 <= field_id <= 0xFFFF:
            raise ValueError("field id is outside UInt16")
        if field_id <= previous_id:
            raise ValueError("LP field ids must be unique and ascending")
        previous_id = field_id

        output.extend(field_id.to_bytes(2, "big"))
        if value is None:
            output.append(0)
            output.extend((0).to_bytes(4, "big"))
            continue
        if len(value) > 0xFFFFFFFF:
            raise ValueError("LP field value is too large")
        output.append(1)
        output.extend(len(value).to_bytes(4, "big"))
        output.extend(value)
    return bytes(output)


def hkdf_extract(salt: bytes, ikm: bytes) -> bytes:
    return hmac.new(salt, ikm, hashlib.sha256).digest()


def hkdf_expand(prk: bytes, info: bytes, length: int) -> bytes:
    digest_size = hashlib.sha256().digest_size
    if not 0 <= length <= 255 * digest_size:
        raise ValueError("HKDF output length is outside RFC 5869 limits")

    output = bytearray()
    previous = b""
    for counter in range(1, (length + digest_size - 1) // digest_size + 1):
        previous = hmac.new(prk, previous + info + bytes([counter]), hashlib.sha256).digest()
        output.extend(previous)
    return bytes(output[:length])


def hkdf_info(purpose: str, context: bytes | None) -> bytes:
    return encode_lp([
        (1, PROTOCOL_VERSION.to_bytes(2, "big")),
        (2, purpose.encode("utf-8")),
        (3, context),
    ])


def labeled_hash(label: str, payload: bytes) -> bytes:
    return hashlib.sha256(encode_lp([
        (1, label.encode("utf-8")),
        (2, payload),
    ])).digest()


def canonical_scope_context(
    *,
    account_id: str,
    space_id: str,
    room_id: str,
    worldline_id: str | None,
) -> bytes:
    return encode_lp([
        (1, _canonical_uuid_ascii(account_id)),
        (2, space_id.encode("utf-8")),
        (3, _canonical_uuid_ascii(room_id)),
        (4, None if worldline_id is None else _canonical_uuid_ascii(worldline_id)),
    ])


def claim_redeem_verifier(
    *,
    session_id: str,
    claim_id: str,
    claim_lookup: bytes,
    claim_redeem_auth: bytes,
) -> bytes:
    if len(claim_lookup) != 32:
        raise ValueError("claim lookup must be 32 bytes")
    if len(claim_redeem_auth) != 32:
        raise ValueError("claim redeem auth must be 32 bytes")
    payload = encode_lp([
        (1, _canonical_uuid_ascii(session_id)),
        (2, _canonical_uuid_ascii(claim_id)),
        (3, claim_lookup),
        (4, claim_redeem_auth),
    ])
    return labeled_hash("gagaodok/e2ee/v1/claim-redeem-verifier", payload)


def pairing_aad(
    *,
    session_id: str,
    claim_id: str,
    claim_lookup: bytes,
    payload_type: str,
    alg: int,
) -> bytes:
    if len(claim_lookup) != 32:
        raise ValueError("claim lookup must be 32 bytes")
    if payload_type not in {"claim", "delivery"}:
        raise ValueError("pairing payload type is invalid")
    if alg != 1:
        raise ValueError("E2EE v1 only accepts AES-256-GCM algorithm 1")
    return encode_lp([
        (1, PROTOCOL_VERSION.to_bytes(2, "big")),
        (2, _canonical_uuid_ascii(session_id)),
        (3, _canonical_uuid_ascii(claim_id)),
        (4, claim_lookup),
        (5, payload_type.encode("ascii")),
        (6, alg.to_bytes(1, "big")),
    ])


def derive_scope_keys(account_master_key: bytes, context: bytes) -> dict[str, bytes]:
    if len(account_master_key) != 32:
        raise ValueError("account master key must be 32 bytes")

    scope_prk = hkdf_extract(PROTOCOL_SALT, account_master_key)
    scope_root_key = hkdf_expand(
        scope_prk,
        hkdf_info("gagaodok/e2ee/v1/scope-root", context),
        32,
    )
    labels = {
        "field_aead_key": "gagaodok/e2ee/v1/field-aead",
        "checkpoint_aead_key": "gagaodok/e2ee/v1/checkpoint-aead",
        "attachment_wrap_key": "gagaodok/e2ee/v1/attachment-wrap",
        "compat_tag_key": "gagaodok/e2ee/v1/compat-tag",
    }
    keys = {
        name: hkdf_expand(scope_root_key, hkdf_info(label, None), 32)
        for name, label in labels.items()
    }
    return {
        "scope_prk": scope_prk,
        "scope_root_key": scope_root_key,
        **keys,
    }


def documented_vector() -> dict[str, str]:
    context = canonical_scope_context(
        account_id="11111111-1111-4111-8111-111111111111",
        space_id="MAC_SPACE",
        room_id="22222222-2222-4222-8222-222222222222",
        worldline_id=None,
    )
    keys = derive_scope_keys(bytes(range(32)), context)
    return {
        "canonical_scope_context": context.hex(),
        "scope_root_hkdf_info": hkdf_info(
            "gagaodok/e2ee/v1/scope-root", context
        ).hex(),
        **{name: value.hex() for name, value in keys.items()},
    }


if __name__ == "__main__":
    print(json.dumps(documented_vector(), indent=2, sort_keys=True))
