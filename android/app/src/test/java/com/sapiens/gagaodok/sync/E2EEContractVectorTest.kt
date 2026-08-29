package com.sapiens.gagaodok.sync

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class E2EEContractVectorTest {
    @Test
    fun producesAndOpensCanonicalFieldEnvelope() {
        val vector = loadVector()
        val scope = SyncE2EE.Scope(
            accountId = vector.accountId,
            spaceId = vector.spaceId,
            roomId = vector.roomId,
            worldlineId = null,
        )
        val context = SyncE2EE.AADContext(
            scope = scope,
            entityType = vector.entityType,
            entityId = vector.entityId,
            fieldPath = vector.fieldPath,
            bubbleOrder = null,
            recoveryVersion = null,
        )

        val keys = SyncE2EE.deriveScopeKeys(ByteArray(32) { it.toByte() }, scope)
        assertArrayEquals(vector.scopeRootKey, keys.scopeRootKey)
        assertArrayEquals(vector.fieldKey, keys.fieldAEADKey)
        assertArrayEquals(vector.aad, SyncE2EE.encodeAAD(context))

        val envelope = SyncE2EE.seal(vector.plaintext, vector.fieldKey, vector.nonce, context)
        assertArrayEquals(vector.envelope, envelope)
        assertEquals(vector.envelopeBase64, SyncE2EE.encodeBase64(envelope))
        assertArrayEquals(vector.envelope, SyncE2EE.decodeBase64(vector.envelopeBase64))
        assertArrayEquals(vector.plaintext, SyncE2EE.open(vector.envelope, vector.fieldKey, context))
    }

    @Test
    fun rejectsAADOrEnvelopeIdentityDrift() {
        val vector = loadVector()
        val scope = SyncE2EE.Scope(vector.accountId, vector.spaceId, vector.roomId, null)
        val mutations = listOf(
            SyncE2EE.AADContext(scope, "turn", vector.entityId, vector.fieldPath, null, null),
            SyncE2EE.AADContext(scope, vector.entityType, vector.roomId + "X", vector.fieldPath, null, null),
            SyncE2EE.AADContext(scope, vector.entityType, vector.entityId, "status_message", null, null),
            SyncE2EE.AADContext(scope, vector.entityType, vector.entityId, vector.fieldPath, 0, null),
        )

        mutations.forEach { mutation ->
            expectError(SyncE2EE.ContractError.AUTHENTICATION_FAILED) {
                SyncE2EE.open(vector.envelope, vector.fieldKey, mutation)
            }
        }
    }

    @Test
    fun rejectsUnsupportedHeaderBeforeAuthentication() {
        val vector = loadVector()
        val context = SyncE2EE.AADContext(
            SyncE2EE.Scope(vector.accountId, vector.spaceId, vector.roomId, null),
            vector.entityType,
            vector.entityId,
            vector.fieldPath,
            null,
            null,
        )

        val wrongAlgorithm = vector.envelope.copyOf().apply { this[1] = 2 }
        expectError(SyncE2EE.ContractError.UNSUPPORTED_ALGORITHM) {
            SyncE2EE.open(wrongAlgorithm, vector.fieldKey, context)
        }

        val wrongGeneration = vector.envelope.copyOf().apply { this[5] = 2 }
        expectError(SyncE2EE.ContractError.UNSUPPORTED_KEY_GENERATION) {
            SyncE2EE.open(wrongGeneration, vector.fieldKey, context)
        }
    }

    @Test
    fun rejectsNonCanonicalBase64() {
        listOf("AQ", "__8=", " AQ==", "AQ==\n").forEach { spelling ->
            expectError(SyncE2EE.ContractError.NON_CANONICAL_BASE64) {
                SyncE2EE.decodeBase64(spelling)
            }
        }
    }

    @Test
    fun derivesCanonicalRecoveryMaterial() {
        val recovery = loadRoot().getValue("recovery").jsonObject
        val material = SyncE2EE.deriveRecoveryMaterial(
            recovery.string("recovery_entropy_hex").hexBytes(),
        )
        assertArrayEquals(recovery.string("recovery_lookup_hex").hexBytes(), material.recoveryLookup)
        assertArrayEquals(recovery.string("recovery_auth_hex").hexBytes(), material.recoveryAuth)
        assertArrayEquals(recovery.string("recovery_wrap_key_hex").hexBytes(), material.recoveryWrapKey)
        assertArrayEquals(
            recovery.string("recovery_auth_verifier_hex").hexBytes(),
            SyncE2EE.recoveryAuthVerifier(material.recoveryAuth),
        )
        val context = SyncE2EE.RecoveryAADContext(
            accountId = recovery.string("account_id"),
            recoveryLookup = material.recoveryLookup,
            recoveryVersion = recovery.getValue("recovery_version").jsonPrimitive.content.toLong(),
        )
        assertArrayEquals(recovery.string("aad_hex").hexBytes(), SyncE2EE.encodeRecoveryAAD(context))
        val envelope = SyncE2EE.sealRecoveryWrappedMasterKey(
            accountMasterKey = recovery.string("account_master_key_hex").hexBytes(),
            recoveryWrapKey = material.recoveryWrapKey,
            nonce = recovery.string("nonce_hex").hexBytes(),
            context = context,
        )
        assertArrayEquals(recovery.string("envelope_hex").hexBytes(), envelope)
        assertArrayEquals(
            recovery.string("account_master_key_hex").hexBytes(),
            SyncE2EE.openRecoveryWrappedMasterKey(envelope, material.recoveryWrapKey, context),
        )
        expectError(SyncE2EE.ContractError.AUTHENTICATION_FAILED) {
            SyncE2EE.openRecoveryWrappedMasterKey(
                envelope,
                material.recoveryWrapKey,
                context.copy(recoveryVersion = context.recoveryVersion + 1),
            )
        }
    }

    @Test
    fun derivesCanonicalPairingMaterial() {
        val pairing = loadRoot().getValue("pairing").jsonObject
        val material = SyncE2EE.derivePairingMaterial(
            pairing.string("pairing_secret_hex").hexBytes(),
            pairing.string("claim_secret_hex").hexBytes(),
        )
        assertArrayEquals(
            pairing.string("pairing_session_lookup_hex").hexBytes(),
            material.pairingSessionLookup,
        )
        assertArrayEquals(pairing.string("pairing_claim_key_hex").hexBytes(), material.pairingClaimKey)
        assertArrayEquals(pairing.string("claim_lookup_hex").hexBytes(), material.claimLookup)
        assertArrayEquals(pairing.string("claim_redeem_auth_hex").hexBytes(), material.claimRedeemAuth)
        assertArrayEquals(
            pairing.string("pairing_delivery_key_hex").hexBytes(),
            material.pairingDeliveryKey,
        )
        assertEquals(pairing.string("pairing_sas"), material.pairingSAS)
        assertArrayEquals(
            pairing.string("claim_aad_hex").hexBytes(),
            SyncE2EE.encodePairingAAD(
                pairing.string("session_id"),
                pairing.string("claim_id"),
                material.claimLookup,
                SyncE2EE.PairingPayloadType.CLAIM,
            ),
        )
        assertArrayEquals(
            pairing.string("claim_redeem_verifier_hex").hexBytes(),
            SyncE2EE.claimRedeemVerifier(
                pairing.string("session_id"),
                pairing.string("claim_id"),
                material.claimLookup,
                material.claimRedeemAuth,
            ),
        )
    }

    private fun expectError(expected: SyncE2EE.ContractError, operation: () -> Unit) {
        try {
            operation()
            fail("expected $expected")
        } catch (error: SyncE2EE.ContractException) {
            assertEquals(expected, error.contractError)
        }
    }

    private fun loadVector(): Vector {
        val root = loadRoot()
        val field = root.getValue("field_aead").jsonObject
        val derivation = root.getValue("key_derivation").jsonObject
        return Vector(
            accountId = field.string("account_id"),
            spaceId = field.string("space_id"),
            roomId = field.string("room_id"),
            entityType = field.string("entity_type"),
            entityId = field.string("entity_id"),
            fieldPath = field.string("field_path"),
            fieldKey = field.string("field_aead_key_hex").hexBytes(),
            nonce = field.string("nonce_hex").hexBytes(),
            plaintext = field.string("plaintext_hex").hexBytes(),
            aad = field.string("aad_hex").hexBytes(),
            envelope = field.string("envelope_hex").hexBytes(),
            envelopeBase64 = field.string("envelope_base64"),
            scopeRootKey = derivation.string("scope_root_key").hexBytes(),
        )
    }

    private fun loadRoot(): Map<String, kotlinx.serialization.json.JsonElement> {
        val workingDirectory = System.getProperty("user.dir") ?: error("working directory missing")
        val fixture = generateSequence(File(workingDirectory)) { it.parentFile }
            .map { File(it, "tools/fixtures/e2ee_contract_vectors.json") }
            .firstOrNull(File::isFile)
            ?: error("repository E2EE fixture not found")
        return Json.parseToJsonElement(fixture.readText()).jsonObject
    }

    private data class Vector(
        val accountId: String,
        val spaceId: String,
        val roomId: String,
        val entityType: String,
        val entityId: String,
        val fieldPath: String,
        val fieldKey: ByteArray,
        val nonce: ByteArray,
        val plaintext: ByteArray,
        val aad: ByteArray,
        val envelope: ByteArray,
        val envelopeBase64: String,
        val scopeRootKey: ByteArray,
    )
}

private fun Map<String, kotlinx.serialization.json.JsonElement>.string(key: String): String =
    getValue(key).jsonPrimitive.content

private fun String.hexBytes(): ByteArray {
    require(length % 2 == 0)
    return chunked(2).map { it.toInt(16).toByte() }.toByteArray()
}
