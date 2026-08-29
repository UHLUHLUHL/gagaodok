#!/usr/bin/env python3
"""Dependency-free Gagaodok E2EE LP v1 and HKDF contract verifier."""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
from pathlib import Path
import uuid
from collections.abc import Iterable


PROTOCOL_SALT = b"gagaodok/e2ee/v1/hkdf-salt"
PROTOCOL_VERSION = 1
LP_MAGIC = b"GDK1"

_AES_SBOX = (
    0x63, 0x7C, 0x77, 0x7B, 0xF2, 0x6B, 0x6F, 0xC5, 0x30, 0x01, 0x67, 0x2B, 0xFE, 0xD7, 0xAB, 0x76,
    0xCA, 0x82, 0xC9, 0x7D, 0xFA, 0x59, 0x47, 0xF0, 0xAD, 0xD4, 0xA2, 0xAF, 0x9C, 0xA4, 0x72, 0xC0,
    0xB7, 0xFD, 0x93, 0x26, 0x36, 0x3F, 0xF7, 0xCC, 0x34, 0xA5, 0xE5, 0xF1, 0x71, 0xD8, 0x31, 0x15,
    0x04, 0xC7, 0x23, 0xC3, 0x18, 0x96, 0x05, 0x9A, 0x07, 0x12, 0x80, 0xE2, 0xEB, 0x27, 0xB2, 0x75,
    0x09, 0x83, 0x2C, 0x1A, 0x1B, 0x6E, 0x5A, 0xA0, 0x52, 0x3B, 0xD6, 0xB3, 0x29, 0xE3, 0x2F, 0x84,
    0x53, 0xD1, 0x00, 0xED, 0x20, 0xFC, 0xB1, 0x5B, 0x6A, 0xCB, 0xBE, 0x39, 0x4A, 0x4C, 0x58, 0xCF,
    0xD0, 0xEF, 0xAA, 0xFB, 0x43, 0x4D, 0x33, 0x85, 0x45, 0xF9, 0x02, 0x7F, 0x50, 0x3C, 0x9F, 0xA8,
    0x51, 0xA3, 0x40, 0x8F, 0x92, 0x9D, 0x38, 0xF5, 0xBC, 0xB6, 0xDA, 0x21, 0x10, 0xFF, 0xF3, 0xD2,
    0xCD, 0x0C, 0x13, 0xEC, 0x5F, 0x97, 0x44, 0x17, 0xC4, 0xA7, 0x7E, 0x3D, 0x64, 0x5D, 0x19, 0x73,
    0x60, 0x81, 0x4F, 0xDC, 0x22, 0x2A, 0x90, 0x88, 0x46, 0xEE, 0xB8, 0x14, 0xDE, 0x5E, 0x0B, 0xDB,
    0xE0, 0x32, 0x3A, 0x0A, 0x49, 0x06, 0x24, 0x5C, 0xC2, 0xD3, 0xAC, 0x62, 0x91, 0x95, 0xE4, 0x79,
    0xE7, 0xC8, 0x37, 0x6D, 0x8D, 0xD5, 0x4E, 0xA9, 0x6C, 0x56, 0xF4, 0xEA, 0x65, 0x7A, 0xAE, 0x08,
    0xBA, 0x78, 0x25, 0x2E, 0x1C, 0xA6, 0xB4, 0xC6, 0xE8, 0xDD, 0x74, 0x1F, 0x4B, 0xBD, 0x8B, 0x8A,
    0x70, 0x3E, 0xB5, 0x66, 0x48, 0x03, 0xF6, 0x0E, 0x61, 0x35, 0x57, 0xB9, 0x86, 0xC1, 0x1D, 0x9E,
    0xE1, 0xF8, 0x98, 0x11, 0x69, 0xD9, 0x8E, 0x94, 0x9B, 0x1E, 0x87, 0xE9, 0xCE, 0x55, 0x28, 0xDF,
    0x8C, 0xA1, 0x89, 0x0D, 0xBF, 0xE6, 0x42, 0x68, 0x41, 0x99, 0x2D, 0x0F, 0xB0, 0x54, 0xBB, 0x16,
)
_AES_RCON = (0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40)


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


def hkdf_sha256(*, ikm: bytes, label: str, length: int = 32) -> bytes:
    """RFC 5869 Extract+Expand using the protocol salt and canonical info."""
    return hkdf_expand(
        hkdf_extract(PROTOCOL_SALT, ikm),
        hkdf_info(label, None),
        length,
    )


def labeled_hash(label: str, payload: bytes) -> bytes:
    return hashlib.sha256(encode_lp([
        (1, label.encode("utf-8")),
        (2, payload),
    ])).digest()


def derive_recovery_material(recovery_entropy: bytes) -> dict[str, bytes]:
    if len(recovery_entropy) != 16:
        raise ValueError("recovery entropy must be 16 bytes")
    return {
        "recovery_lookup": hkdf_sha256(
            ikm=recovery_entropy,
            label="gagaodok/e2ee/v1/recovery-lookup",
        ),
        "recovery_auth": hkdf_sha256(
            ikm=recovery_entropy,
            label="gagaodok/e2ee/v1/recovery-auth",
        ),
        "recovery_wrap_key": hkdf_sha256(
            ikm=recovery_entropy,
            label="gagaodok/e2ee/v1/recovery-wrap",
        ),
    }


def recovery_auth_verifier(recovery_auth: bytes) -> bytes:
    if len(recovery_auth) != 32:
        raise ValueError("recovery auth must be 32 bytes")
    return labeled_hash("gagaodok/e2ee/v1/recovery-auth-verifier", recovery_auth)


def derive_pairing_material(pairing_secret: bytes, claim_secret: bytes) -> dict[str, bytes | str]:
    if len(pairing_secret) != 32:
        raise ValueError("pairing secret must be 32 bytes")
    if len(claim_secret) != 32:
        raise ValueError("claim secret must be 32 bytes")
    joint_secret = encode_lp([(1, pairing_secret), (2, claim_secret)])
    sas_bytes = hkdf_sha256(
        ikm=joint_secret,
        label="gagaodok/e2ee/v1/pairing-sas",
        length=4,
    )
    return {
        "pairing_session_lookup": hkdf_sha256(
            ikm=pairing_secret,
            label="gagaodok/e2ee/v1/pairing-session-lookup",
        ),
        "pairing_claim_key": hkdf_sha256(
            ikm=pairing_secret,
            label="gagaodok/e2ee/v1/pairing-claim",
        ),
        "claim_lookup": hkdf_sha256(
            ikm=claim_secret,
            label="gagaodok/e2ee/v1/claim-lookup",
        ),
        "claim_redeem_auth": hkdf_sha256(
            ikm=claim_secret,
            label="gagaodok/e2ee/v1/claim-redeem-auth",
        ),
        "joint_secret": joint_secret,
        "pairing_delivery_key": hkdf_sha256(
            ikm=joint_secret,
            label="gagaodok/e2ee/v1/pairing-delivery",
        ),
        "pairing_sas_bytes": sas_bytes,
        "pairing_sas": f"{int.from_bytes(sas_bytes, 'big') % 1_000_000:06d}",
    }


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


def recovery_aad(
    *,
    account_id: str,
    recovery_lookup: bytes,
    recovery_version: int,
    key_generation: int = 1,
    alg: int = 1,
) -> bytes:
    if len(recovery_lookup) != 32:
        raise ValueError("recovery lookup must be 32 bytes")
    if not 1 <= recovery_version <= 0xFFFFFFFF:
        raise ValueError("recovery version is outside UInt32")
    if key_generation != 1 or alg != 1:
        raise ValueError("E2EE v1 only accepts generation and algorithm 1")
    return encode_lp([
        (1, PROTOCOL_VERSION.to_bytes(2, "big")),
        (2, _canonical_uuid_ascii(account_id)),
        (3, recovery_lookup),
        (4, recovery_version.to_bytes(4, "big")),
        (5, key_generation.to_bytes(4, "big")),
        (6, b"recovery_wrapped_master_key"),
        (7, alg.to_bytes(1, "big")),
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


def field_aad(
    *,
    account_id: str,
    space_id: str,
    room_id: str,
    worldline_id: str | None,
    entity_type: str,
    entity_id: str,
    field_path: str | None,
    bubble_order: int | None,
    recovery_version: int | None,
    key_generation: int = 1,
    alg: int = 1,
) -> bytes:
    if key_generation != 1 or alg != 1:
        raise ValueError("E2EE v1 only accepts generation and algorithm 1")
    if bubble_order is not None and not 0 <= bubble_order <= 0xFFFFFFFFFFFFFFFF:
        raise ValueError("bubble order is outside UInt64")
    if recovery_version is not None and not 0 <= recovery_version <= 0xFFFFFFFF:
        raise ValueError("recovery version is outside UInt32")
    return encode_lp([
        (1, PROTOCOL_VERSION.to_bytes(2, "big")),
        (2, key_generation.to_bytes(4, "big")),
        (3, _canonical_uuid_ascii(account_id)),
        (4, space_id.encode("utf-8")),
        (5, _canonical_uuid_ascii(room_id)),
        (6, None if worldline_id is None else _canonical_uuid_ascii(worldline_id)),
        (7, entity_type.encode("ascii")),
        (8, entity_id.encode("utf-8")),
        (9, None if field_path is None else field_path.encode("utf-8")),
        (10, None if bubble_order is None else bubble_order.to_bytes(8, "big")),
        (11, None if recovery_version is None else recovery_version.to_bytes(4, "big")),
        (12, alg.to_bytes(1, "big")),
    ])


def _aes_sub_word(word: int) -> int:
    return sum(_AES_SBOX[(word >> shift) & 0xFF] << shift for shift in (24, 16, 8, 0))


def _aes_rot_word(word: int) -> int:
    return ((word << 8) & 0xFFFFFFFF) | (word >> 24)


def _aes256_round_keys(key: bytes) -> list[bytes]:
    if len(key) != 32:
        raise ValueError("AES-256 key must be 32 bytes")
    words = [int.from_bytes(key[index:index + 4], "big") for index in range(0, 32, 4)]
    for index in range(8, 60):
        temporary = words[index - 1]
        if index % 8 == 0:
            temporary = _aes_sub_word(_aes_rot_word(temporary)) ^ (_AES_RCON[index // 8] << 24)
        elif index % 8 == 4:
            temporary = _aes_sub_word(temporary)
        words.append(words[index - 8] ^ temporary)
    return [
        b"".join(word.to_bytes(4, "big") for word in words[index:index + 4])
        for index in range(0, 60, 4)
    ]


def _aes_xtime(value: int) -> int:
    return ((value << 1) ^ (0x11B if value & 0x80 else 0)) & 0xFF


def _aes256_encrypt_block(key: bytes, block: bytes) -> bytes:
    if len(block) != 16:
        raise ValueError("AES block must be 16 bytes")
    round_keys = _aes256_round_keys(key)
    state = [value ^ round_keys[0][index] for index, value in enumerate(block)]

    for round_index in range(1, 15):
        state = [_AES_SBOX[value] for value in state]
        before_shift = state[:]
        for row in range(4):
            for column in range(4):
                state[row + 4 * column] = before_shift[row + 4 * ((column + row) % 4)]
        if round_index != 14:
            for column in range(4):
                offset = 4 * column
                a0, a1, a2, a3 = state[offset:offset + 4]
                total = a0 ^ a1 ^ a2 ^ a3
                state[offset] = a0 ^ total ^ _aes_xtime(a0 ^ a1)
                state[offset + 1] = a1 ^ total ^ _aes_xtime(a1 ^ a2)
                state[offset + 2] = a2 ^ total ^ _aes_xtime(a2 ^ a3)
                state[offset + 3] = a3 ^ total ^ _aes_xtime(a3 ^ a0)
        state = [value ^ round_keys[round_index][index] for index, value in enumerate(state)]
    return bytes(state)


def _gcm_multiply(left: int, right: int) -> int:
    product = 0
    value = right
    for shift in range(127, -1, -1):
        if (left >> shift) & 1:
            product ^= value
        value = (value >> 1) ^ (0xE1000000000000000000000000000000 if value & 1 else 0)
    return product


def _gcm_hash(hash_subkey: bytes, aad: bytes, ciphertext: bytes) -> bytes:
    data = bytearray(aad)
    data.extend(bytes((-len(data)) % 16))
    data.extend(ciphertext)
    data.extend(bytes((-len(ciphertext)) % 16))
    data.extend((len(aad) * 8).to_bytes(8, "big"))
    data.extend((len(ciphertext) * 8).to_bytes(8, "big"))
    result = 0
    multiplier = int.from_bytes(hash_subkey, "big")
    for index in range(0, len(data), 16):
        result = _gcm_multiply(result ^ int.from_bytes(data[index:index + 16], "big"), multiplier)
    return result.to_bytes(16, "big")


def _gcm_counter_bytes(key: bytes, initial_counter: bytes, length: int) -> bytes:
    counter_prefix = initial_counter[:12]
    counter = int.from_bytes(initial_counter[12:], "big")
    output = bytearray()
    while len(output) < length:
        counter = (counter + 1) & 0xFFFFFFFF
        output.extend(_aes256_encrypt_block(key, counter_prefix + counter.to_bytes(4, "big")))
    return bytes(output[:length])


def aes256_gcm_seal(*, key: bytes, nonce: bytes, plaintext: bytes, aad: bytes) -> bytes:
    if len(key) != 32:
        raise ValueError("AES-256 key must be 32 bytes")
    if len(nonce) != 12:
        raise ValueError("GCM nonce must be 12 bytes")
    initial_counter = nonce + b"\x00\x00\x00\x01"
    stream = _gcm_counter_bytes(key, initial_counter, len(plaintext))
    ciphertext = bytes(left ^ right for left, right in zip(plaintext, stream, strict=True))
    hash_subkey = _aes256_encrypt_block(key, bytes(16))
    authentication = _gcm_hash(hash_subkey, aad, ciphertext)
    tag_mask = _aes256_encrypt_block(key, initial_counter)
    tag = bytes(left ^ right for left, right in zip(tag_mask, authentication, strict=True))
    return ciphertext + tag


def seal_v1_envelope(*, key: bytes, nonce: bytes, plaintext: bytes, aad: bytes) -> bytes:
    return (
        b"\x01\x01"
        + (1).to_bytes(4, "big")
        + nonce
        + aes256_gcm_seal(key=key, nonce=nonce, plaintext=plaintext, aad=aad)
    )


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


def documented_aead_vector() -> dict[str, str | int | None]:
    account_id = "11111111-1111-4111-8111-111111111111"
    room_id = "22222222-2222-4222-8222-222222222222"
    context = canonical_scope_context(
        account_id=account_id,
        space_id="MAC_SPACE",
        room_id=room_id,
        worldline_id=None,
    )
    key = derive_scope_keys(bytes(range(32)), context)["field_aead_key"]
    nonce = bytes(range(12))
    plaintext = "가가오독 synthetic vector".encode("utf-8")
    aad = field_aad(
        account_id=account_id,
        space_id="MAC_SPACE",
        room_id=room_id,
        worldline_id=None,
        entity_type="room",
        entity_id=room_id,
        field_path="title",
        bubble_order=None,
        recovery_version=None,
    )
    envelope = seal_v1_envelope(key=key, nonce=nonce, plaintext=plaintext, aad=aad)
    return {
        "account_id": account_id,
        "space_id": "MAC_SPACE",
        "room_id": room_id,
        "worldline_id": None,
        "entity_type": "room",
        "entity_id": room_id,
        "field_path": "title",
        "bubble_order": None,
        "recovery_version": None,
        "version": 1,
        "alg": 1,
        "key_generation": 1,
        "field_aead_key_hex": key.hex(),
        "nonce_hex": nonce.hex(),
        "plaintext_utf8": plaintext.decode("utf-8"),
        "plaintext_hex": plaintext.hex(),
        "aad_hex": aad.hex(),
        "ciphertext_and_tag_hex": envelope[18:].hex(),
        "envelope_hex": envelope.hex(),
        "envelope_base64": base64.b64encode(envelope).decode("ascii"),
    }


def documented_recovery_vector() -> dict[str, str | int]:
    entropy = bytes(range(0x40, 0x50))
    material = derive_recovery_material(entropy)
    recovery_auth = material["recovery_auth"]
    assert isinstance(recovery_auth, bytes)
    account_id = "11111111-1111-4111-8111-111111111111"
    recovery_lookup = material["recovery_lookup"]
    recovery_wrap_key = material["recovery_wrap_key"]
    assert isinstance(recovery_lookup, bytes)
    assert isinstance(recovery_wrap_key, bytes)
    nonce = bytes(range(0x20, 0x2C))
    account_master_key = bytes(range(32))
    aad = recovery_aad(
        account_id=account_id,
        recovery_lookup=recovery_lookup,
        recovery_version=1,
    )
    envelope = seal_v1_envelope(
        key=recovery_wrap_key,
        nonce=nonce,
        plaintext=account_master_key,
        aad=aad,
    )
    return {
        "account_id": account_id,
        "recovery_version": 1,
        "recovery_entropy_hex": entropy.hex(),
        "recovery_lookup_hex": recovery_lookup.hex(),
        "recovery_auth_hex": recovery_auth.hex(),
        "recovery_wrap_key_hex": recovery_wrap_key.hex(),
        "recovery_auth_verifier_hex": recovery_auth_verifier(recovery_auth).hex(),
        "account_master_key_hex": account_master_key.hex(),
        "nonce_hex": nonce.hex(),
        "aad_hex": aad.hex(),
        "envelope_hex": envelope.hex(),
        "envelope_base64": base64.b64encode(envelope).decode("ascii"),
    }


def documented_pairing_vector() -> dict[str, str]:
    session_id = "33333333-3333-4333-8333-333333333333"
    claim_id = "44444444-4444-4444-8444-444444444444"
    pairing_secret = bytes(range(32))
    claim_secret = bytes(range(32, 64))
    material = derive_pairing_material(pairing_secret, claim_secret)
    binary_keys = {
        key: value.hex()
        for key, value in material.items()
        if isinstance(value, bytes)
    }
    claim_lookup = material["claim_lookup"]
    claim_redeem_auth = material["claim_redeem_auth"]
    assert isinstance(claim_lookup, bytes)
    assert isinstance(claim_redeem_auth, bytes)
    return {
        "session_id": session_id,
        "claim_id": claim_id,
        "pairing_secret_hex": pairing_secret.hex(),
        "claim_secret_hex": claim_secret.hex(),
        **{f"{key}_hex": value for key, value in binary_keys.items()},
        "pairing_sas": str(material["pairing_sas"]),
        "claim_aad_hex": pairing_aad(
            session_id=session_id,
            claim_id=claim_id,
            claim_lookup=claim_lookup,
            payload_type="claim",
            alg=1,
        ).hex(),
        "delivery_aad_hex": pairing_aad(
            session_id=session_id,
            claim_id=claim_id,
            claim_lookup=claim_lookup,
            payload_type="delivery",
            alg=1,
        ).hex(),
        "claim_redeem_verifier_hex": claim_redeem_verifier(
            session_id=session_id,
            claim_id=claim_id,
            claim_lookup=claim_lookup,
            claim_redeem_auth=claim_redeem_auth,
        ).hex(),
    }


def contract_vectors() -> dict[str, object]:
    return {
        "schema_version": 1,
        "classification": "SYNTHETIC_ONLY",
        "key_derivation": documented_vector(),
        "field_aead": documented_aead_vector(),
        "recovery": documented_recovery_vector(),
        "pairing": documented_pairing_vector(),
    }


def canonical_vector_bytes() -> bytes:
    return (
        json.dumps(contract_vectors(), ensure_ascii=True, sort_keys=True, separators=(",", ":"))
        + "\n"
    ).encode("utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    payload = canonical_vector_bytes()
    if arguments.output is None:
        print(payload.decode("utf-8"), end="")
        return 0
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_bytes(payload)
    print(f"synthetic E2EE vector written: bytes={len(payload)} sha256={hashlib.sha256(payload).hexdigest()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
