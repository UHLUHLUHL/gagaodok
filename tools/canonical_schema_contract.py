#!/usr/bin/env python3
"""Phase 1 canonical schema contract checks (dependency-free).

Implements the contracts fixed by `docs/PHASE1_CANONICAL_SCHEMA_DRAFT.md` and
`docs/2026-08-27-phase1-canonical-schema-codex-review.md` so that the
acceptance tests can assert them mechanically.

This module never opens real conversation archives and never emits message
bodies, room titles, persona text, or any other user content. Fixtures are
synthetic and every failure message is content-free.
"""

from __future__ import annotations

import math
import re
import sqlite3
import uuid
from collections.abc import Iterable, Mapping, Sequence

from tools.e2ee_contract_vectors import canonical_scope_context


# --------------------------------------------------------------------------
# 0. Shared primitives
# --------------------------------------------------------------------------

#: Draft §0.3 / §2 — Worker boundary keeps integers inside the IEEE-754 range
#: that JavaScript `Number` can represent exactly.
MAX_SAFE_INTEGER = 2**53 - 1

#: Draft §14.2 — the all-zero UUID is explicitly *not* used as a worldline
#: sentinel. Kept here only so the contract can reject it on sight.
REJECTED_SENTINEL_UUIDS = frozenset({
    "00000000-0000-0000-0000-000000000000",
    "00000000-0000-4000-8000-000000000000",
})


class ContractError(ValueError):
    """Raised when a value violates the Phase 1 canonical schema contract."""


def canonical_uuid(value: object, *, field: str) -> str:
    """Return `value` if it is an uppercase hyphenated UUID.

    E2EE proposal §12.3 fixes the canonical UUID form as uppercase hyphenated
    ASCII, and `tools.e2ee_contract_vectors` enforces exactly that when it
    builds LP v1 AAD. Any identifier that reaches D1 or an AAD must already be
    in that form, so the schema layer applies the same rule rather than
    silently upper-casing (which would let two spellings map to one scope).
    """
    if not isinstance(value, str):
        raise ContractError(f"{field} must be a string UUID")
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError) as error:
        raise ContractError(f"{field} is not a valid UUID") from error
    if str(parsed).upper() != value:
        raise ContractError(f"{field} must use uppercase hyphenated ASCII")
    return value


def _require_safe_int(value: object, *, field: str, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ContractError(f"{field} must be an integer")
    if value < minimum:
        raise ContractError(f"{field} must be >= {minimum}")
    if value > MAX_SAFE_INTEGER:
        raise ContractError(f"{field} exceeds the 2^53-1 safe-integer bound")
    return value


# --------------------------------------------------------------------------
# 1. Space enum and raw source mapping  (draft §1.1)
# --------------------------------------------------------------------------

MAC_SPACE = "MAC_SPACE"
PHONE_SPACE = "PHONE_SPACE"
TABLET_SPACE = "TABLET_SPACE"

SPACE_IDS = frozenset({MAC_SPACE, PHONE_SPACE, TABLET_SPACE})

#: Draft §1.1 — the Phase 0 tablet report emitted the raw label ``"tablet"``.
#: The mapping is an exact-match table on purpose: no case folding, no
#: normalisation, no fallback for unknown labels.
_RAW_SOURCE_SPACE = {
    "mac": MAC_SPACE,
    "phone": PHONE_SPACE,
    "tablet": TABLET_SPACE,
}


def canonical_space_id(value: object, *, field: str = "space_id") -> str:
    """Validate an already-canonical space enum value."""
    if value not in SPACE_IDS:
        raise ContractError(f"{field} is not a canonical space enum value")
    return str(value)


def map_raw_source_space(raw: object) -> str:
    """Map a Phase 0 adapter label to the canonical enum, exactly once.

    Draft §1.1 forbids case correction and arbitrary-string fallback, so
    ``"Tablet"``, ``"TABLET"`` and unknown labels are rejected rather than
    coerced.
    """
    if not isinstance(raw, str):
        raise ContractError("raw source_space must be a string")
    if raw not in _RAW_SOURCE_SPACE:
        raise ContractError("raw source_space has no explicit canonical mapping")
    return _RAW_SOURCE_SPACE[raw]


# --------------------------------------------------------------------------
# 2. Nullable worldline: D1 key vs E2EE AAD  (draft §14.2, review "scope 결정")
# --------------------------------------------------------------------------

def worldline_key(worldline_id: str | None) -> str:
    """Materialised D1 key column: ``worldline_id ?? ""``.

    Never returns a UUID-shaped sentinel for the default worldline.
    """
    if worldline_id is None:
        return ""
    canonical = canonical_uuid(worldline_id, field="worldline_id")
    if canonical.lower() in REJECTED_SENTINEL_UUIDS:
        raise ContractError("sentinel UUID must not be used as a worldline_id")
    return canonical


def validate_worldline_binding(worldline_id: str | None, key: object) -> str:
    """Enforce ``CHECK (worldline_key = COALESCE(worldline_id, ''))``."""
    expected = worldline_key(worldline_id)
    if key != expected:
        raise ContractError("worldline_key does not match COALESCE(worldline_id, '')")
    return expected


class ConversationScope:
    """A canonical conversation scope with both representations.

    ``d1_key`` is the storage tuple (non-null ``worldline_key``);
    ``aad_context`` is the LP v1 byte string the E2EE layer binds, which keeps
    the nullable ``worldline_id`` with ``presence = 0``. Both are derived from
    the same source field so they can never drift.
    """

    __slots__ = ("account_id", "space_id", "room_id", "worldline_id")

    def __init__(
        self,
        *,
        account_id: str,
        space_id: str,
        room_id: str,
        worldline_id: str | None = None,
    ) -> None:
        self.account_id = canonical_uuid(account_id, field="account_id")
        self.space_id = canonical_space_id(space_id)
        self.room_id = canonical_uuid(room_id, field="room_id")
        self.worldline_id = None if worldline_id is None else worldline_key(worldline_id) or None

    @property
    def worldline_key(self) -> str:
        return worldline_key(self.worldline_id)

    def d1_key(self) -> tuple[str, str, str, str]:
        return (self.account_id, self.space_id, self.room_id, self.worldline_key)

    def aad_context(self) -> bytes:
        return canonical_scope_context(
            account_id=self.account_id,
            space_id=self.space_id,
            room_id=self.room_id,
            worldline_id=self.worldline_id,
        )

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, ConversationScope):
            return NotImplemented
        return self.d1_key() == other.d1_key()

    def __hash__(self) -> int:
        return hash(self.d1_key())


# --------------------------------------------------------------------------
# 3. bubble_order  (draft §2, review decision 3)
# --------------------------------------------------------------------------

MAX_BUBBLE_ORDER = MAX_SAFE_INTEGER


def initial_bubble_orders(message_count: int) -> list[int]:
    """First canonical import assigns the original array's 0-based index."""
    if isinstance(message_count, bool) or not isinstance(message_count, int):
        raise ContractError("message_count must be an integer")
    if message_count < 0:
        raise ContractError("message_count must be >= 0")
    if message_count - 1 > MAX_BUBBLE_ORDER:
        raise ContractError("import would exceed the bubble_order bound")
    return list(range(message_count))


def next_bubble_order(existing_orders: Iterable[int]) -> int:
    """Scope-wide ``max + 1``; an empty scope starts at 0."""
    orders = [_require_safe_int(value, field="bubble_order") for value in existing_orders]
    if not orders:
        return 0
    nxt = max(orders) + 1
    if nxt > MAX_BUBBLE_ORDER:
        raise ContractError("bubble_order would exceed the 2^53-1 bound")
    return nxt


def validate_scope_bubble_orders(orders: Sequence[int]) -> tuple[int, ...]:
    """Enforce the scope-wide UNIQUE constraint; gaps stay legal."""
    seen: set[int] = set()
    for value in orders:
        checked = _require_safe_int(value, field="bubble_order")
        if checked in seen:
            raise ContractError("bubble_order must be unique within a conversation scope")
        seen.add(checked)
    return tuple(orders)


def validate_bubble_order_immutable(
    previous: Mapping[str, int],
    current: Mapping[str, int],
) -> None:
    """Reject renumbering of any message_id already assigned an order."""
    for message_id, order in previous.items():
        if message_id in current and current[message_id] != order:
            raise ContractError("bubble_order is immutable once assigned")


# --------------------------------------------------------------------------
# 4. Extension namespace  (draft §3.3, review decision 4)
# --------------------------------------------------------------------------

_EXTENSION_SEGMENT = r"[a-z][a-z0-9_]*"
EXTENSION_KEY_PATTERN = re.compile(
    rf"^{_EXTENSION_SEGMENT}\.{_EXTENSION_SEGMENT}\.{_EXTENSION_SEGMENT}$"
)


def validate_extension_key(key: object) -> str:
    """Enforce the ``<owner>.<entity>.<field>`` lowercase dotted namespace."""
    if not isinstance(key, str):
        raise ContractError("extension key must be a string")
    if not EXTENSION_KEY_PATTERN.fullmatch(key):
        raise ContractError("extension key must match <owner>.<entity>.<field>")
    return key


def build_extension_envelopes(pairs: Iterable[tuple[str, bytes]]) -> dict[str, bytes]:
    """One independent envelope per key; duplicates are a hard error.

    Takes an iterable of pairs (not a mapping) so that a duplicate key is
    visible instead of being silently collapsed by dict construction.
    """
    envelopes: dict[str, bytes] = {}
    for key, envelope in pairs:
        validate_extension_key(key)
        if key in envelopes:
            raise ContractError("duplicate extension key")
        if not isinstance(envelope, (bytes, bytearray)):
            raise ContractError("extension envelope must be bytes")
        envelopes[key] = bytes(envelope)
    return envelopes


def round_trip_unknown_extensions(
    stored: Mapping[str, bytes],
    known_keys: Iterable[str],
) -> dict[str, bytes]:
    """Return the stored envelopes untouched for keys this client cannot read.

    A client that patches a known key must hand back every unknown key with
    byte-identical content; re-encrypting or dropping them is forbidden.
    """
    known = set(known_keys)
    return {key: bytes(value) for key, value in stored.items() if key not in known}


# --------------------------------------------------------------------------
# 5. Tenant-aware entity keys  (review "초안에서 추가로 고친 문제")
# --------------------------------------------------------------------------

def persona_snapshot_key(
    *, account_id: str, space_id: str, persona_snapshot_id: str, snapshot_revision: int
) -> tuple[str, str, str, int]:
    return (
        canonical_uuid(account_id, field="account_id"),
        canonical_space_id(space_id),
        canonical_uuid(persona_snapshot_id, field="persona_snapshot_id"),
        _require_safe_int(snapshot_revision, field="snapshot_revision", minimum=1),
    )


def engine_profile_key(
    *, account_id: str, space_id: str, engine_profile_id: str, profile_revision: int
) -> tuple[str, str, str, int]:
    return (
        canonical_uuid(account_id, field="account_id"),
        canonical_space_id(space_id),
        canonical_uuid(engine_profile_id, field="engine_profile_id"),
        _require_safe_int(profile_revision, field="profile_revision", minimum=1),
    )


def attachment_key(*, account_id: str, attachment_id: str) -> tuple[str, str]:
    return (
        canonical_uuid(account_id, field="account_id"),
        canonical_uuid(attachment_id, field="attachment_id"),
    )


# --------------------------------------------------------------------------
# 6. Turn / bubble ownership, projection and deletion  (draft §3.4, §9.2)
# --------------------------------------------------------------------------

AI_SENDERS = frozenset({"ai", "assistant"})

#: Turn-level source of truth. These never live on a canonical bubble row.
TURN_LEVEL_FIELDS = ("canonical_text", "heart_changes")


def project_turn_to_local(bubbles: Sequence[Mapping[str, object]]) -> list[dict[str, object]]:
    """Anchor turn-level fields onto local bubbles for legacy JSON output.

    Draft §9.2: ``canonical_text`` anchors to the first surviving AI bubble and
    ``heart_changes`` to the last; middle bubbles carry neither. The canonical
    turn keeps ownership either way — this is a projection, not a move.
    """
    ordered = sorted(bubbles, key=lambda b: _require_safe_int(b["bubble_order"], field="bubble_order"))
    ai_indexes = [i for i, b in enumerate(ordered) if b.get("sender") in AI_SENDERS]
    projected: list[dict[str, object]] = []
    for index, bubble in enumerate(ordered):
        row = dict(bubble)
        row["canonical_text_anchor"] = bool(ai_indexes) and index == ai_indexes[0]
        row["heart_changes_anchor"] = bool(ai_indexes) and index == ai_indexes[-1]
        projected.append(row)
    return projected


def resolve_delete_operation(
    *,
    op: str,
    surviving_bubble_count: int,
    targets_last_bubble: bool,
    phase5_initial: bool = True,
) -> str:
    """Resolve a delete request into the operation the contract permits.

    * Deleting the final bubble is promoted to ``delete_turn`` so no headless
      turn is ever created (draft §9.2, review decision 8).
    * Initial Phase 5 refuses ``delete_bubble`` outright (user decisions 10/15).
    """
    if op not in {"delete_bubble", "delete_turn"}:
        raise ContractError("unknown delete operation")
    _require_safe_int(surviving_bubble_count, field="surviving_bubble_count")

    if op == "delete_turn":
        return "delete_turn"

    if targets_last_bubble or surviving_bubble_count <= 1:
        return "delete_turn"
    if phase5_initial:
        raise ContractError("delete_bubble is not accepted in initial Phase 5")
    return "delete_bubble"


def assert_no_headless_turn(turn_deleted: bool, surviving_bubble_count: int) -> None:
    if surviving_bubble_count == 0 and not turn_deleted:
        raise ContractError("a turn with zero surviving bubbles must be tombstoned")


# --------------------------------------------------------------------------
# 7. Group / worldline space guard and relationship-reference secrecy
# --------------------------------------------------------------------------

#: Draft §13.1 / §13.2 and E2EE §8.2 — relationship edges, not identity.
ENCRYPTED_RELATIONSHIP_REFERENCES = (
    "GroupParticipant.roomId",
    "ParticipantHeart.participantRoomId",
    "ChatMessage.speakerRoomId",
    "MessageReaction.participantRoomId",
    "MessageHeartChange.participantRoomId",
    "GroupChatState.activeWorldlineId",
)


def require_phone_space(space_id: str, *, feature: str) -> str:
    """`group_state`, `worldline` and `relationship_policy = group` are PHONE_SPACE only."""
    canonical = canonical_space_id(space_id)
    if canonical != PHONE_SPACE:
        raise ContractError(f"{feature} is restricted to PHONE_SPACE in v1")
    return canonical


def validate_relationship_policy(policy: str, space_id: str) -> str:
    if policy not in {"none", "personal", "group"}:
        raise ContractError("relationship_policy is not an allowed value")
    if policy == "group":
        require_phone_space(space_id, feature="relationship_policy=group")
    return policy


def find_plaintext_leaks(payload: object, secret_values: Iterable[str]) -> list[str]:
    """Return which secret reference values appear anywhere in a plaintext blob.

    Only membership is reported. The offending value itself is never returned
    or logged, so a failing assertion cannot print user data.
    """
    secrets = [s for s in secret_values if s]
    found: set[str] = set()

    def walk(node: object) -> None:
        if isinstance(node, str):
            for secret in secrets:
                if secret in node:
                    found.add(secret)
        elif isinstance(node, Mapping):
            for key, value in node.items():
                walk(key)
                walk(value)
        elif isinstance(node, (list, tuple, set, frozenset)):
            for item in node:
                walk(item)

    walk(payload)
    # Report positions, not the secret text itself.
    return [f"secret#{index}" for index, secret in enumerate(secrets) if secret in found]


# --------------------------------------------------------------------------
# 8. Unsupported engine profile fallback  (draft §4)
# --------------------------------------------------------------------------

def resolve_generation_profile(
    *,
    room_profile_ref: tuple[str, int],
    supported: bool,
    announced_fallback_ref: tuple[str, int] | None,
    fallback_announced: bool,
) -> dict[str, object]:
    """Decide which profile an AI turn actually generated with.

    Silent fallback is forbidden. A fallback is only usable when it is both
    registered *and* announced to the user (user decision 8); otherwise the
    send is refused fail-closed.
    """
    if supported:
        return {
            "generation_profile_ref": room_profile_ref,
            "fallback_reason": None,
            "used_fallback": False,
        }
    if announced_fallback_ref is None:
        raise ContractError("unsupported profile with no registered fallback: fail closed")
    if not fallback_announced:
        raise ContractError("silent fallback is forbidden; the difference must be announced")
    return {
        "generation_profile_ref": announced_fallback_ref,
        "fallback_reason": "ENC(unsupported_engine_profile)",
        "used_fallback": True,
    }


# --------------------------------------------------------------------------
# 9. Account-wide server_seq with idempotent retry  (draft §14.3)
# --------------------------------------------------------------------------

_SEQUENCE_SCHEMA = """
CREATE TABLE account (
    account_id      TEXT PRIMARY KEY,
    next_server_seq INTEGER NOT NULL
);
CREATE TABLE operation_log (
    account_id   TEXT NOT NULL,
    operation_id TEXT NOT NULL,
    server_seq   INTEGER NOT NULL,
    PRIMARY KEY (account_id, operation_id)
);
CREATE TABLE change_log (
    account_id TEXT NOT NULL,
    server_seq INTEGER NOT NULL,
    PRIMARY KEY (account_id, server_seq)
);
"""


class SequenceAllocator:
    """Synthetic in-memory model of the account-wide sequence transaction.

    Uses `sqlite3` only as a local transactional store so the idempotency and
    uniqueness rules can be exercised. It creates no Cloudflare resource and
    reads no real data.
    """

    def __init__(self) -> None:
        self._db = sqlite3.connect(":memory:")
        self._db.isolation_level = None
        self._db.executescript(_SEQUENCE_SCHEMA)

    def close(self) -> None:
        self._db.close()

    def register_account(self, account_id: str) -> None:
        self._db.execute(
            "INSERT INTO account (account_id, next_server_seq) VALUES (?, 1)",
            (canonical_uuid(account_id, field="account_id"),),
        )

    def allocate(self, account_id: str, operation_id: str) -> int:
        """Allocate, or replay, the sequence value for one operation."""
        account_id = canonical_uuid(account_id, field="account_id")
        operation_id = canonical_uuid(operation_id, field="operation_id")

        self._db.execute("BEGIN IMMEDIATE")
        try:
            replay = self._db.execute(
                "SELECT server_seq FROM operation_log WHERE account_id = ? AND operation_id = ?",
                (account_id, operation_id),
            ).fetchone()
            if replay is not None:
                self._db.execute("COMMIT")
                return int(replay[0])

            row = self._db.execute(
                "SELECT next_server_seq FROM account WHERE account_id = ?",
                (account_id,),
            ).fetchone()
            if row is None:
                raise ContractError("unknown account")
            assigned = int(row[0])
            if assigned > MAX_SAFE_INTEGER:
                raise ContractError("server_seq exhausted the 2^53-1 bound: fail closed")

            self._db.execute(
                "UPDATE account SET next_server_seq = ? WHERE account_id = ?",
                (assigned + 1, account_id),
            )
            self._db.execute(
                "INSERT INTO operation_log (account_id, operation_id, server_seq) VALUES (?, ?, ?)",
                (account_id, operation_id, assigned),
            )
            self._db.execute(
                "INSERT INTO change_log (account_id, server_seq) VALUES (?, ?)",
                (account_id, assigned),
            )
            self._db.execute("COMMIT")
            return assigned
        except Exception:
            self._db.execute("ROLLBACK")
            raise

    def force_next_sequence(self, account_id: str, value: int) -> None:
        """Test hook: jump the counter to exercise gaps and the upper bound."""
        self._db.execute(
            "UPDATE account SET next_server_seq = ? WHERE account_id = ?",
            (value, canonical_uuid(account_id, field="account_id")),
        )

    def issued_sequences(self, account_id: str) -> list[int]:
        rows = self._db.execute(
            "SELECT server_seq FROM change_log WHERE account_id = ? ORDER BY server_seq",
            (canonical_uuid(account_id, field="account_id"),),
        ).fetchall()
        return [int(row[0]) for row in rows]


# --------------------------------------------------------------------------
# 10. D1 capacity estimate  (draft §14.4)
# --------------------------------------------------------------------------

PHASE0_ARCHIVE_TOTAL_BYTES = 40_355_530
PHASE0_AVATAR_BYTES = 20_800_577
PHASE0_LOCAL_ONLY_BYTES = 2_558_968
PHASE0_INLINE_ATTACHMENT_BASE64_BYTES = 12_494_244

#: AEAD envelope overhead per encrypted field instance (E2EE proposal §7.1:
#: version + alg + key_generation + nonce + tag, rounded as documented).
AEAD_FIELD_OVERHEAD_BYTES = 44


def phase0_message_json_bytes() -> int:
    return (
        PHASE0_ARCHIVE_TOTAL_BYTES
        - PHASE0_AVATAR_BYTES
        - PHASE0_LOCAL_ONLY_BYTES
    )


def phase0_text_bytes() -> int:
    return phase0_message_json_bytes() - PHASE0_INLINE_ATTACHMENT_BASE64_BYTES


def base64_expanded_bytes(plain_bytes: int) -> int:
    return math.ceil(plain_bytes * 4 / 3)


def estimate_d1_payload_bytes(field_count: int) -> int:
    """Reproduce ``6,002,322 + 44 x field_count`` from the draft."""
    _require_safe_int(field_count, field="field_count")
    return base64_expanded_bytes(phase0_text_bytes()) + AEAD_FIELD_OVERHEAD_BYTES * field_count
