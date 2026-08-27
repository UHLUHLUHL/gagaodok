"""Acceptance tests for the Phase 1 canonical schema contract.

Every fixture in this file is synthetic. No real conversation archive is
opened and no assertion message can contain user content.
"""

import unittest

from tools.canonical_schema_contract import (
    AEAD_FIELD_OVERHEAD_BYTES,
    ENCRYPTED_RELATIONSHIP_REFERENCES,
    MAX_BUBBLE_ORDER,
    MAX_SAFE_INTEGER,
    PHONE_SPACE,
    ContractError,
    ConversationScope,
    SequenceAllocator,
    attachment_key,
    base64_expanded_bytes,
    build_extension_envelopes,
    canonical_space_id,
    canonical_uuid,
    engine_profile_key,
    estimate_d1_payload_bytes,
    find_plaintext_leaks,
    initial_bubble_orders,
    map_raw_source_space,
    next_bubble_order,
    persona_snapshot_key,
    phase0_message_json_bytes,
    phase0_text_bytes,
    project_turn_to_local,
    require_phone_space,
    resolve_delete_operation,
    resolve_generation_profile,
    round_trip_unknown_extensions,
    validate_bubble_order_immutable,
    validate_extension_key,
    validate_relationship_policy,
    validate_scope_bubble_orders,
    validate_worldline_binding,
    worldline_key,
)
from tools.e2ee_contract_vectors import canonical_scope_context

# Synthetic identifiers. Uppercase per E2EE proposal §12.3.
ACCOUNT_A = "A0000000-0000-4000-8000-000000000001"
ACCOUNT_B = "A0000000-0000-4000-8000-000000000002"
ROOM_1 = "10000000-0000-4000-8000-000000000001"
WORLDLINE_1 = "20000000-0000-4000-8000-000000000001"
TURN_1 = "30000000-0000-4000-8000-000000000001"
OPERATION_1 = "90000000-0000-4000-8000-000000000001"
OPERATION_2 = "90000000-0000-4000-8000-000000000002"
PROFILE_1 = "C0000000-0000-4000-8000-0000000000E1"


class NullableWorldlineTests(unittest.TestCase):
    """Item 1 — D1 key representation vs E2EE AAD representation."""

    def test_null_worldline_maps_to_empty_key(self):
        self.assertEqual(worldline_key(None), "")

    def test_real_uuid_maps_to_itself(self):
        self.assertEqual(worldline_key(WORLDLINE_1), WORLDLINE_1)

    def test_check_constraint_rejects_mismatched_pair(self):
        self.assertEqual(validate_worldline_binding(None, ""), "")
        self.assertEqual(validate_worldline_binding(WORLDLINE_1, WORLDLINE_1), WORLDLINE_1)
        with self.assertRaises(ContractError):
            validate_worldline_binding(None, WORLDLINE_1)
        with self.assertRaises(ContractError):
            validate_worldline_binding(WORLDLINE_1, "")

    def test_no_sentinel_uuid_is_used_or_accepted(self):
        # The default worldline key is the empty string, never a UUID shape.
        self.assertNotIn("-", worldline_key(None))
        for sentinel in (
            "00000000-0000-0000-0000-000000000000",
            "00000000-0000-4000-8000-000000000000",
        ):
            with self.assertRaises(ContractError):
                worldline_key(sentinel.upper())

    def test_d1_key_and_aad_describe_the_same_scope(self):
        scope = ConversationScope(
            account_id=ACCOUNT_A, space_id="MAC_SPACE", room_id=ROOM_1, worldline_id=None
        )
        # D1 side uses the non-null materialised key ...
        self.assertEqual(scope.d1_key(), (ACCOUNT_A, "MAC_SPACE", ROOM_1, ""))
        # ... while the AAD keeps LP v1 presence = 0 for the same scope.
        self.assertEqual(
            scope.aad_context(),
            canonical_scope_context(
                account_id=ACCOUNT_A,
                space_id="MAC_SPACE",
                room_id=ROOM_1,
                worldline_id=None,
            ),
        )
        # The empty key must never leak into the AAD as a present empty field.
        present_empty = canonical_scope_context(
            account_id=ACCOUNT_A, space_id="MAC_SPACE", room_id=ROOM_1, worldline_id=None
        )
        self.assertIn(b"\x00\x04\x00\x00\x00\x00\x00", present_empty)

    def test_default_and_named_worldline_are_distinct_scopes(self):
        default = ConversationScope(
            account_id=ACCOUNT_A, space_id=PHONE_SPACE, room_id=ROOM_1, worldline_id=None
        )
        named = ConversationScope(
            account_id=ACCOUNT_A, space_id=PHONE_SPACE, room_id=ROOM_1, worldline_id=WORLDLINE_1
        )
        self.assertNotEqual(default.d1_key(), named.d1_key())
        self.assertNotEqual(default.aad_context(), named.aad_context())


class BubbleOrderTests(unittest.TestCase):
    """Item 2 — range, initial import, append rule, gaps, uniqueness."""

    def test_bound_is_two_pow_53_minus_one(self):
        self.assertEqual(MAX_BUBBLE_ORDER, 9_007_199_254_740_991)

    def test_initial_import_uses_zero_based_index(self):
        self.assertEqual(initial_bubble_orders(4), [0, 1, 2, 3])
        self.assertEqual(initial_bubble_orders(0), [])

    def test_new_bubble_takes_scope_wide_max_plus_one(self):
        self.assertEqual(next_bubble_order([]), 0)
        self.assertEqual(next_bubble_order([0, 1, 2]), 3)
        # Gaps do not reset the counter: max+1, not count.
        self.assertEqual(next_bubble_order([0, 5, 9]), 10)

    def test_gaps_are_legal(self):
        self.assertEqual(validate_scope_bubble_orders([0, 3, 4, 9]), (0, 3, 4, 9))

    def test_duplicate_order_in_scope_is_rejected(self):
        with self.assertRaises(ContractError):
            validate_scope_bubble_orders([0, 1, 1])

    def test_out_of_range_is_rejected(self):
        with self.assertRaises(ContractError):
            validate_scope_bubble_orders([MAX_SAFE_INTEGER + 1])
        with self.assertRaises(ContractError):
            validate_scope_bubble_orders([-1])
        with self.assertRaises(ContractError):
            next_bubble_order([MAX_BUBBLE_ORDER])

    def test_renumbering_existing_message_is_rejected(self):
        before = {"m1": 0, "m2": 1}
        validate_bubble_order_immutable(before, {"m1": 0, "m2": 1, "m3": 2})
        with self.assertRaises(ContractError):
            validate_bubble_order_immutable(before, {"m1": 0, "m2": 5})


class TombstoneAndBubbleOrderTests(unittest.TestCase):
    """Item 2 (continued) — the tombstone-retention hazard.

    The draft mandates tombstones (§9) but §14.1 never says where the
    tombstone marker lives or that a tombstoned row is retained. These tests
    pin the only interpretation under which `max + 1` stays safe. See the
    review document, finding 2.
    """

    def test_max_plus_one_over_live_rows_only_reuses_a_retired_order(self):
        # Scope originally held orders 0, 1, 2; the turn holding 2 was deleted.
        assigned_orders = [0, 1, 2]
        live_orders_if_rows_were_hard_deleted = [0, 1]

        reused = next_bubble_order(live_orders_if_rows_were_hard_deleted)
        self.assertEqual(reused, 2)
        self.assertIn(reused, assigned_orders)  # collision with a retired order

    def test_max_plus_one_over_all_assigned_orders_is_monotonic(self):
        assigned_orders_including_tombstoned = [0, 1, 2]
        self.assertEqual(next_bubble_order(assigned_orders_including_tombstoned), 3)

    def test_reused_order_would_violate_scope_wide_uniqueness(self):
        # Both the tombstoned bubble and the new one would claim order 2.
        with self.assertRaises(ContractError):
            validate_scope_bubble_orders([0, 1, 2, 2])


class ExtensionNamespaceTests(unittest.TestCase):
    """Item 3 — grammar, per-key envelopes, opaque round-trip."""

    def test_valid_key_grammar(self):
        self.assertEqual(
            validate_extension_key("android.room_profile.base_affection"),
            "android.room_profile.base_affection",
        )

    def test_invalid_keys_are_rejected(self):
        for bad in (
            "Android.room_profile.base_affection",  # uppercase owner
            "android.room_profile",                  # only two segments
            "android.room_profile.base.affection",   # four segments
            "1android.room_profile.field",           # segment starts with digit
            "android..field",                        # empty segment
            "android.room-profile.field",            # hyphen not allowed
            "",
        ):
            with self.subTest(key=bad):
                with self.assertRaises(ContractError):
                    validate_extension_key(bad)

    def test_each_key_gets_an_independent_envelope(self):
        envelopes = build_extension_envelopes([
            ("android.room_profile.base_affection", b"ENV-A"),
            ("android.message.speaker_ref", b"ENV-B"),
        ])
        self.assertEqual(len(envelopes), 2)
        self.assertNotEqual(
            envelopes["android.room_profile.base_affection"],
            envelopes["android.message.speaker_ref"],
        )

    def test_duplicate_key_is_rejected(self):
        with self.assertRaises(ContractError):
            build_extension_envelopes([
                ("android.room_profile.base_affection", b"A"),
                ("android.room_profile.base_affection", b"B"),
            ])

    def test_unknown_extension_round_trips_byte_identically(self):
        stored = build_extension_envelopes([
            ("android.room_profile.base_affection", b"\x01\x02\xff\x00opaque"),
            ("android.group_state.participants", b"\x10\x20unknown-to-mac"),
        ])
        # A macOS client knows only the first key and patches it.
        preserved = round_trip_unknown_extensions(
            stored, known_keys=["android.room_profile.base_affection"]
        )
        self.assertEqual(preserved, {"android.group_state.participants": b"\x10\x20unknown-to-mac"})
        self.assertEqual(
            preserved["android.group_state.participants"],
            stored["android.group_state.participants"],
        )


class TenantAndIdentityTests(unittest.TestCase):
    """Item 4 — account isolation and explicit space mapping."""

    def test_same_uuid_under_two_accounts_does_not_collide(self):
        scope_a = ConversationScope(
            account_id=ACCOUNT_A, space_id="MAC_SPACE", room_id=ROOM_1, worldline_id=None
        )
        scope_b = ConversationScope(
            account_id=ACCOUNT_B, space_id="MAC_SPACE", room_id=ROOM_1, worldline_id=None
        )
        self.assertNotEqual(scope_a.d1_key(), scope_b.d1_key())
        self.assertNotEqual(scope_a.aad_context(), scope_b.aad_context())

    def test_persona_engine_attachment_keys_all_carry_account_id(self):
        persona = persona_snapshot_key(
            account_id=ACCOUNT_A,
            space_id=PHONE_SPACE,
            persona_snapshot_id="50000000-0000-4000-8000-000000000001",
            snapshot_revision=2,
        )
        profile = engine_profile_key(
            account_id=ACCOUNT_A,
            space_id="MAC_SPACE",
            engine_profile_id=PROFILE_1,
            profile_revision=3,
        )
        attachment = attachment_key(
            account_id=ACCOUNT_A, attachment_id="70000000-0000-4000-8000-000000000001"
        )
        for key in (persona, profile, attachment):
            with self.subTest(key=key[0]):
                self.assertEqual(key[0], ACCOUNT_A)

    def test_tablet_raw_label_maps_explicitly(self):
        self.assertEqual(map_raw_source_space("tablet"), "TABLET_SPACE")
        self.assertEqual(map_raw_source_space("mac"), "MAC_SPACE")
        self.assertEqual(map_raw_source_space("phone"), "PHONE_SPACE")

    def test_case_variants_and_unknown_labels_are_rejected(self):
        for bad in ("Tablet", "TABLET", "TABLET_SPACE", "desktop", "watch", ""):
            with self.subTest(raw=bad):
                with self.assertRaises(ContractError):
                    map_raw_source_space(bad)

    def test_canonical_space_enum_rejects_unknown(self):
        with self.assertRaises(ContractError):
            canonical_space_id("tablet")

    def test_lowercase_uuid_is_rejected_as_non_canonical(self):
        """E2EE proposal §12.3 fixes uppercase hyphenated ASCII.

        PROFILE_1 contains hex letters, so its lowercase spelling is a
        genuinely different byte string. The draft's JSON examples use exactly
        that lowercase form -- see the review document, finding 1.
        """
        self.assertNotEqual(PROFILE_1.lower(), PROFILE_1)
        with self.assertRaises(ContractError):
            canonical_uuid(PROFILE_1.lower(), field="engine_profile_id")
        # An all-digit UUID has no case, so it slips through unchanged.
        self.assertEqual(canonical_uuid(ROOM_1, field="room_id"), ROOM_1)


class TurnBubbleDeletionTests(unittest.TestCase):
    """Item 5 — turn-level ownership, projection anchors, delete promotion."""

    def _bubbles(self):
        return [
            {"message_id": "m0", "bubble_order": 0, "sender": "user"},
            {"message_id": "m1", "bubble_order": 1, "sender": "ai"},
            {"message_id": "m2", "bubble_order": 2, "sender": "ai"},
            {"message_id": "m3", "bubble_order": 3, "sender": "ai"},
        ]

    def test_projection_anchors_first_and_last_ai_bubble(self):
        projected = project_turn_to_local(self._bubbles())
        by_id = {row["message_id"]: row for row in projected}
        self.assertTrue(by_id["m1"]["canonical_text_anchor"])
        self.assertFalse(by_id["m1"]["heart_changes_anchor"])
        self.assertTrue(by_id["m3"]["heart_changes_anchor"])
        self.assertFalse(by_id["m3"]["canonical_text_anchor"])
        # Middle AI bubble carries neither turn-level field.
        self.assertFalse(by_id["m2"]["canonical_text_anchor"])
        self.assertFalse(by_id["m2"]["heart_changes_anchor"])
        # The user bubble is never an anchor for turn-level fields.
        self.assertFalse(by_id["m0"]["canonical_text_anchor"])
        self.assertFalse(by_id["m0"]["heart_changes_anchor"])

    def test_projection_reanchors_after_deletion(self):
        remaining = [b for b in self._bubbles() if b["message_id"] != "m1"]
        by_id = {row["message_id"]: row for row in project_turn_to_local(remaining)}
        self.assertTrue(by_id["m2"]["canonical_text_anchor"])
        self.assertTrue(by_id["m3"]["heart_changes_anchor"])

    def test_last_bubble_delete_is_promoted_to_delete_turn(self):
        self.assertEqual(
            resolve_delete_operation(
                op="delete_bubble", surviving_bubble_count=1, targets_last_bubble=True
            ),
            "delete_turn",
        )

    def test_delete_bubble_is_refused_in_initial_phase5(self):
        with self.assertRaises(ContractError):
            resolve_delete_operation(
                op="delete_bubble", surviving_bubble_count=4, targets_last_bubble=False
            )

    def test_delete_bubble_allowed_only_after_phase5_gate_opens(self):
        self.assertEqual(
            resolve_delete_operation(
                op="delete_bubble",
                surviving_bubble_count=4,
                targets_last_bubble=False,
                phase5_initial=False,
            ),
            "delete_bubble",
        )

    def test_delete_turn_passes_through(self):
        self.assertEqual(
            resolve_delete_operation(
                op="delete_turn", surviving_bubble_count=4, targets_last_bubble=False
            ),
            "delete_turn",
        )


class GroupWorldlineAndReferenceTests(unittest.TestCase):
    """Item 6 — PHONE_SPACE restriction and relationship-reference secrecy."""

    def test_group_entities_are_phone_space_only(self):
        self.assertEqual(require_phone_space(PHONE_SPACE, feature="group_state"), PHONE_SPACE)
        for space in ("MAC_SPACE", "TABLET_SPACE"):
            with self.subTest(space=space):
                with self.assertRaises(ContractError):
                    require_phone_space(space, feature="group_state")

    def test_relationship_policy_group_is_phone_space_only(self):
        self.assertEqual(validate_relationship_policy("group", PHONE_SPACE), "group")
        self.assertEqual(validate_relationship_policy("none", "MAC_SPACE"), "none")
        self.assertEqual(validate_relationship_policy("personal", "MAC_SPACE"), "personal")
        with self.assertRaises(ContractError):
            validate_relationship_policy("group", "MAC_SPACE")
        with self.assertRaises(ContractError):
            validate_relationship_policy("shared", PHONE_SPACE)

    def test_all_six_reference_values_are_classified_as_encrypted(self):
        self.assertEqual(len(ENCRYPTED_RELATIONSHIP_REFERENCES), 6)
        self.assertIn("GroupChatState.activeWorldlineId", ENCRYPTED_RELATIONSHIP_REFERENCES)

    def test_reference_values_do_not_appear_in_plaintext_row(self):
        speaker_room = "10000000-0000-4000-8000-0000000000AA"
        participant_room = "10000000-0000-4000-8000-0000000000BB"
        active_worldline = "20000000-0000-4000-8000-0000000000CC"

        # A conforming canonical row: identity plaintext, relationship edges sealed.
        bubble_row = {
            "account_id": ACCOUNT_A,
            "space_id": PHONE_SPACE,
            "room_id": ROOM_1,
            "worldline_key": "",
            "turn_id": TURN_1,
            "message_id": "40000000-0000-4000-8000-000000000001",
            "bubble_order": 7,
            "text_enc": "ENC(body)",
            "speaker_ref_enc": "ENC(speaker reference)",
            "reactions_enc": "ENC(reactions)",
        }
        group_row = {
            "account_id": ACCOUNT_A,
            "space_id": PHONE_SPACE,
            "room_id": ROOM_1,
            "participants_enc": "ENC(participants)",
            "active_worldline_id_enc": "ENC(active worldline)",
        }

        secrets = [speaker_room, participant_room, active_worldline]
        self.assertEqual(find_plaintext_leaks(bubble_row, secrets), [])
        self.assertEqual(find_plaintext_leaks(group_row, secrets), [])

    def test_leak_detector_catches_a_non_conforming_row(self):
        speaker_room = "10000000-0000-4000-8000-0000000000AA"
        leaking_row = {"speaker_room_id": speaker_room, "bubble_order": 7}
        leaks = find_plaintext_leaks(leaking_row, [speaker_room])
        self.assertEqual(leaks, ["secret#0"])
        # The detector reports a position, never the value itself.
        self.assertNotIn(speaker_room, "".join(leaks))

    def test_entity_room_and_worldline_identity_stay_plaintext(self):
        # room_id / worldline_id are routing identity and must remain readable.
        scope = ConversationScope(
            account_id=ACCOUNT_A, space_id=PHONE_SPACE, room_id=ROOM_1, worldline_id=WORLDLINE_1
        )
        self.assertIn(ROOM_1, scope.d1_key())
        self.assertIn(WORLDLINE_1, scope.d1_key())


class UnsupportedProfileTests(unittest.TestCase):
    """Item 7 — no silent fallback; provenance recorded on the turn."""

    def test_supported_profile_records_the_room_profile(self):
        result = resolve_generation_profile(
            room_profile_ref=(PROFILE_1, 3),
            supported=True,
            announced_fallback_ref=None,
            fallback_announced=False,
        )
        self.assertEqual(result["generation_profile_ref"], (PROFILE_1, 3))
        self.assertIsNone(result["fallback_reason"])
        self.assertFalse(result["used_fallback"])

    def test_unsupported_without_registered_fallback_fails_closed(self):
        with self.assertRaises(ContractError):
            resolve_generation_profile(
                room_profile_ref=(PROFILE_1, 3),
                supported=False,
                announced_fallback_ref=None,
                fallback_announced=True,
            )

    def test_unannounced_fallback_is_refused(self):
        with self.assertRaises(ContractError):
            resolve_generation_profile(
                room_profile_ref=(PROFILE_1, 3),
                supported=False,
                announced_fallback_ref=(PROFILE_1, 1),
                fallback_announced=False,
            )

    def test_announced_fallback_records_actual_profile_and_reason(self):
        fallback = ("C0000000-0000-4000-8000-0000000000E2", 1)
        result = resolve_generation_profile(
            room_profile_ref=(PROFILE_1, 3),
            supported=False,
            announced_fallback_ref=fallback,
            fallback_announced=True,
        )
        self.assertEqual(result["generation_profile_ref"], fallback)
        self.assertNotEqual(result["generation_profile_ref"], (PROFILE_1, 3))
        self.assertIsNotNone(result["fallback_reason"])
        self.assertTrue(result["used_fallback"])


class ServerSequenceTests(unittest.TestCase):
    """Item 8 — account-wide sequence, idempotency, gaps, fail-closed bound."""

    def setUp(self):
        self.allocator = SequenceAllocator()
        self.allocator.register_account(ACCOUNT_A)
        self.allocator.register_account(ACCOUNT_B)
        self.addCleanup(self.allocator.close)

    def test_sequence_is_account_wide_and_monotonic(self):
        first = self.allocator.allocate(ACCOUNT_A, OPERATION_1)
        second = self.allocator.allocate(ACCOUNT_A, OPERATION_2)
        self.assertEqual(first, 1)
        self.assertEqual(second, 2)
        self.assertEqual(self.allocator.issued_sequences(ACCOUNT_A), [1, 2])

    def test_accounts_have_independent_sequences(self):
        self.assertEqual(self.allocator.allocate(ACCOUNT_A, OPERATION_1), 1)
        self.assertEqual(self.allocator.allocate(ACCOUNT_B, OPERATION_1), 1)
        self.assertEqual(self.allocator.issued_sequences(ACCOUNT_A), [1])
        self.assertEqual(self.allocator.issued_sequences(ACCOUNT_B), [1])

    def test_retry_of_same_operation_consumes_no_new_sequence(self):
        first = self.allocator.allocate(ACCOUNT_A, OPERATION_1)
        replay = self.allocator.allocate(ACCOUNT_A, OPERATION_1)
        again = self.allocator.allocate(ACCOUNT_A, OPERATION_1)
        self.assertEqual(first, replay)
        self.assertEqual(first, again)
        self.assertEqual(self.allocator.issued_sequences(ACCOUNT_A), [1])
        following = self.allocator.allocate(ACCOUNT_A, OPERATION_2)
        self.assertEqual(following, 2)

    def test_sequences_never_duplicate(self):
        issued = [
            self.allocator.allocate(ACCOUNT_A, f"90000000-0000-4000-8000-{index:012X}")
            for index in range(25)
        ]
        self.assertEqual(len(issued), len(set(issued)))

    def test_gaps_are_allowed(self):
        self.assertEqual(self.allocator.allocate(ACCOUNT_A, OPERATION_1), 1)
        self.allocator.force_next_sequence(ACCOUNT_A, 100)
        self.assertEqual(self.allocator.allocate(ACCOUNT_A, OPERATION_2), 100)
        self.assertEqual(self.allocator.issued_sequences(ACCOUNT_A), [1, 100])

    def test_exceeding_safe_integer_bound_fails_closed(self):
        self.allocator.force_next_sequence(ACCOUNT_A, MAX_SAFE_INTEGER)
        self.assertEqual(self.allocator.allocate(ACCOUNT_A, OPERATION_1), MAX_SAFE_INTEGER)
        with self.assertRaises(ContractError):
            self.allocator.allocate(ACCOUNT_A, OPERATION_2)
        # It fails closed instead of wrapping to 0 or reusing a value.
        self.assertEqual(self.allocator.issued_sequences(ACCOUNT_A), [MAX_SAFE_INTEGER])


class CapacityEstimateTests(unittest.TestCase):
    """Item 9 — reproduce the documented D1 sizing chain."""

    def test_intermediate_chain_matches_the_document(self):
        self.assertEqual(phase0_message_json_bytes(), 16_995_985)
        self.assertEqual(phase0_text_bytes(), 4_501_741)
        self.assertEqual(base64_expanded_bytes(phase0_text_bytes()), 6_002_322)

    def test_overhead_constant(self):
        self.assertEqual(AEAD_FIELD_OVERHEAD_BYTES, 44)

    def test_documented_field_count_scenarios(self):
        self.assertEqual(estimate_d1_payload_bytes(10_000), 6_442_322)
        self.assertEqual(estimate_d1_payload_bytes(25_000), 7_102_322)
        self.assertEqual(estimate_d1_payload_bytes(50_000), 8_202_322)

    def test_zero_fields_is_the_base_payload(self):
        self.assertEqual(estimate_d1_payload_bytes(0), 6_002_322)

    def test_base64_expansion_uses_ceiling(self):
        self.assertEqual(base64_expanded_bytes(1), 2)
        self.assertEqual(base64_expanded_bytes(3), 4)
        self.assertEqual(base64_expanded_bytes(4), 6)


if __name__ == "__main__":
    unittest.main()
