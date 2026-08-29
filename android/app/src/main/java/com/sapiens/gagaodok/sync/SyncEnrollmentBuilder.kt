package com.sapiens.gagaodok.sync

import java.security.MessageDigest
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

data class SyncEnrollmentPackage(
    val accountId:String,val deviceId:String,val enrollmentId:String,val recoveryPhrase:String,
    val secrets:SyncSecretBundle,val rawRequestBody:ByteArray,
)
object SyncEnrollmentBuilder {
 fun build(accountId:String,deviceId:String,enrollmentId:String,spaceId:String,platform:String,accountMasterKey:ByteArray,deviceToken:ByteArray,recoveryEntropy:ByteArray,recoveryNonce:ByteArray,words:List<String>):SyncEnrollmentPackage{
  val secrets=SyncSecretBundle(accountMasterKey,deviceToken);val recovery=SyncE2EE.deriveRecoveryMaterial(recoveryEntropy);val verifier=SyncE2EE.recoveryAuthVerifier(recovery.recoveryAuth);val wrapped=SyncE2EE.sealRecoveryWrappedMasterKey(accountMasterKey,recovery.recoveryWrapKey,recoveryNonce,SyncE2EE.RecoveryAADContext(accountId,recovery.recoveryLookup,1));val tokenHash=MessageDigest.getInstance("SHA-256").digest(deviceToken).joinToString(""){"%02x".format(it)}
  val body=buildJsonObject{put("protocol_version",1);put("enrollment_id",enrollmentId);put("account_id",accountId);put("device",buildJsonObject{put("device_id",deviceId);put("space_id",spaceId);put("platform",platform);put("display_name",JsonNull);put("device_token_hash",tokenHash)});put("recovery",buildJsonObject{put("recovery_version",1);put("recovery_lookup",SyncE2EE.encodeBase64(recovery.recoveryLookup));put("recovery_auth_verifier",SyncE2EE.encodeBase64(verifier));put("wrapped_master_key",SyncE2EE.encodeBase64(wrapped))})}
  return SyncEnrollmentPackage(accountId,deviceId,enrollmentId,SyncRecoveryMnemonic.encode(recoveryEntropy,words),secrets,body.toString().toByteArray())
 }
}
