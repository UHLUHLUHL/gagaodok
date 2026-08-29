import json
from pathlib import Path
import unittest

import tools.e2ee_contract_vectors as vectors

from tools.e2ee_contract_vectors import (
    PROTOCOL_SALT,
    canonical_scope_context,
    claim_redeem_verifier,
    derive_scope_keys,
    encode_lp,
    hkdf_expand,
    hkdf_extract,
    hkdf_info,
    pairing_aad,
)


class E2EEContractVectorTests(unittest.TestCase):
    def test_aes256_gcm_reference_matches_nist_vector(self):
        sealed = vectors.aes256_gcm_seal(
            key=bytes(32),
            nonce=bytes(12),
            plaintext=bytes(16),
            aad=b"",
        )

        self.assertEqual(
            sealed.hex(),
            "cea7403d4d606b6e074ec5d3baf39d18"
            "d0d1c8a799996bf0265b98b5d48ab919",
        )

    def test_documented_aead_vector_matches_independent_literal(self):
        vector = vectors.documented_aead_vector()

        self.assertEqual(
            vector["aad_hex"],
            "47444b31000c0001010000000200010002010000000400000001"
            "0003010000002431313131313131312d313131312d343131312d383131312d313131313131313131313131"
            "000401000000094d41435f5350414345"
            "0005010000002432323232323232322d323232322d343232322d383232322d323232323232323232323232"
            "00060000000000"
            "00070100000004726f6f6d"
            "0008010000002432323232323232322d323232322d343232322d383232322d323232323232323232323232"
            "000901000000057469746c65"
            "000a0000000000000b0000000000000c010000000101",
        )
        self.assertEqual(
            vector["ciphertext_and_tag_hex"],
            "35919c70fd448ea18c5019e226f27d8c2b3cc8d162bc3dc189575ee7c4f0b158821504b3a5acaf770d389b7160",
        )
        self.assertEqual(
            vector["envelope_base64"],
            "AQEAAAABAAECAwQFBgcICQoLNZGccP1EjqGMUBniJvJ9jCs8yNFivD3BiVde58TwsViCFQSzpayvdw04m3Fg",
        )

    def test_committed_artifact_is_the_canonical_generator_output(self):
        artifact = (
            Path(__file__).resolve().parents[1]
            / "fixtures"
            / "e2ee_contract_vectors.json"
        )

        self.assertEqual(
            json.loads(artifact.read_text(encoding="utf-8")),
            vectors.contract_vectors(),
        )

    def test_lp_v1_distinguishes_null_from_present_empty(self):
        encoded = encode_lp([
            (1, b"\x00\x01"),
            (2, None),
            (3, b"A"),
            (4, b""),
        ])

        self.assertEqual(
            encoded.hex(),
            "47444b310004"
            "000101000000020001"
            "00020000000000"
            "0003010000000141"
            "00040100000000",
        )

    def test_lp_v1_rejects_duplicate_or_unsorted_fields(self):
        with self.assertRaises(ValueError):
            encode_lp([(1, b"a"), (1, b"b")])
        with self.assertRaises(ValueError):
            encode_lp([(2, b"a"), (1, b"b")])

    def test_rfc5869_extract_and_expand_vectors(self):
        ikm = bytes.fromhex("0b" * 22)
        salt = bytes.fromhex("000102030405060708090a0b0c")
        info = bytes.fromhex("f0f1f2f3f4f5f6f7f8f9")
        prk = hkdf_extract(salt, ikm)

        self.assertEqual(
            prk.hex(),
            "077709362c2e32df0ddc3f0dc47bba63"
            "90b6c73bb50f9c3122ec844ad7c2b3e5",
        )
        self.assertEqual(
            hkdf_expand(prk, info, 42).hex(),
            "3cb25f25faacd57a90434f64d0362f2a"
            "2d2d0a90cf1a5a4c5db02d56ecc4c5bf"
            "34007208d5b887185865",
        )

    def test_scope_context_and_hkdf_info_match_documented_bytes(self):
        context = canonical_scope_context(
            account_id="11111111-1111-4111-8111-111111111111",
            space_id="MAC_SPACE",
            room_id="22222222-2222-4222-8222-222222222222",
            worldline_id=None,
        )

        self.assertEqual(len(PROTOCOL_SALT), 26)
        self.assertEqual(len(context), 115)
        self.assertEqual(
            context.hex(),
            "47444b3100040001010000002431313131313131312d313131312d343131312d383131312d313131313131313131313131"
            "000201000000094d41435f5350414345"
            "0003010000002432323232323232322d323232322d343232322d383232322d323232323232323232323232"
            "00040000000000",
        )
        info = hkdf_info("gagaodok/e2ee/v1/scope-root", context)
        self.assertEqual(len(info), 171)
        self.assertEqual(
            info.hex(),
            "47444b310003000101000000020001"
            "0002010000001b676167616f646f6b2f653265652f76312f73636f70652d726f6f74"
            "00030100000073"
            "47444b3100040001010000002431313131313131312d313131312d343131312d383131312d313131313131313131313131"
            "000201000000094d41435f5350414345"
            "0003010000002432323232323232322d323232322d343232322d383232322d323232323232323232323232"
            "00040000000000",
        )

    def test_uuid_fields_reject_noncanonical_lowercase_text(self):
        with self.assertRaises(ValueError):
            canonical_scope_context(
                account_id="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                space_id="MAC_SPACE",
                room_id="22222222-2222-4222-8222-222222222222",
                worldline_id=None,
            )

    def test_scope_derivation_matches_documented_fixed_vectors(self):
        context = canonical_scope_context(
            account_id="11111111-1111-4111-8111-111111111111",
            space_id="MAC_SPACE",
            room_id="22222222-2222-4222-8222-222222222222",
            worldline_id=None,
        )
        keys = derive_scope_keys(bytes(range(32)), context)

        self.assertEqual(keys["scope_prk"].hex(), "d6f8acf0397895e14f62491a74bc964c9bee238cf4efab0016a1f5467b211048")
        self.assertEqual(keys["scope_root_key"].hex(), "5633eaf345979da613efa3c7a785a48f5e4c60473ca806f772d79c62cc3d93a0")
        self.assertEqual(keys["field_aead_key"].hex(), "c96df08f1224ca6f8b3e96ac87f1e7d7327a4e5f0ae250c8752656bbe31c793f")
        self.assertEqual(keys["checkpoint_aead_key"].hex(), "45759f66516548d112ef49ef261a49d8c5537f790772322c20afa560312c14bd")
        self.assertEqual(keys["attachment_wrap_key"].hex(), "2368e886dbfacce439bab98ec99c049f0d5130fe2e0eb2bbe6b62fbe72f0068d")
        self.assertEqual(keys["compat_tag_key"].hex(), "8cca8fd82e374d48e585bc3e250d317e0560905004bdd93f458d84f1713da9f4")

    def test_pairing_aad_authenticates_the_v1_algorithm_byte(self):
        aad = pairing_aad(
            session_id="33333333-3333-4333-8333-333333333333",
            claim_id="44444444-4444-4444-8444-444444444444",
            claim_lookup=bytes(range(32)),
            payload_type="claim",
            alg=1,
        )

        self.assertEqual(aad[:6], bytes.fromhex("47444b310006"))
        self.assertEqual(aad[-8:], bytes.fromhex("0006010000000101"))
        with self.assertRaises(ValueError):
            pairing_aad(
                session_id="33333333-3333-4333-8333-333333333333",
                claim_id="44444444-4444-4444-8444-444444444444",
                claim_lookup=bytes(range(32)),
                payload_type="claim",
                alg=2,
            )

    def test_claim_redeem_verifier_is_bound_to_session_and_claim(self):
        inputs = {
            "session_id": "33333333-3333-4333-8333-333333333333",
            "claim_id": "44444444-4444-4444-8444-444444444444",
            "claim_lookup": bytes(range(32)),
            "claim_redeem_auth": bytes(range(32, 64)),
        }
        verifier = claim_redeem_verifier(**inputs)

        self.assertEqual(
            verifier.hex(),
            "9f7c4f2294826ca2618ee42b6bb617dfd1699bb735fcd529c9725007a2bfdc88",
        )
        self.assertNotEqual(
            verifier,
            claim_redeem_verifier(
                **{
                    **inputs,
                    "claim_id": "55555555-5555-4555-8555-555555555555",
                }
            ),
        )


if __name__ == "__main__":
    unittest.main()
