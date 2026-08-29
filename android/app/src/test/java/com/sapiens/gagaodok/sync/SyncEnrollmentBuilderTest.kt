package com.sapiens.gagaodok.sync
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.*
import org.junit.Test
class SyncEnrollmentBuilderTest{
 @Test fun `builds canonical enrollment without raw token`() {val words=SyncRecoveryMnemonic.words(File("../../Sources/KakaoSapiens/Resources/sync/english-bip39.txt").readText());val result=SyncEnrollmentBuilder.build("11111111-1111-4111-8111-111111111111","22222222-2222-4222-8222-222222222222","33333333-3333-4333-8333-333333333333","PHONE_SPACE","android_phone",ByteArray(32){it.toByte()},ByteArray(32){(it+32).toByte()},ByteArray(16){(it+64).toByte()},ByteArray(12){(it+32).toByte()},words);val json=Json.parseToJsonElement(result.rawRequestBody.decodeToString()).jsonObject;assertEquals(result.accountId,json["account_id"]!!.jsonPrimitive.content);assertEquals("72dbb7336c76780023f83da4c355f2eeea85733b13d3477697917790c1229084",json["device"]!!.jsonObject["device_token_hash"]!!.jsonPrimitive.content);assertEquals(12,result.recoveryPhrase.split(" ").size);assertFalse(result.rawRequestBody.decodeToString().contains(java.util.Base64.getEncoder().encodeToString(result.secrets.deviceToken)))}
}
