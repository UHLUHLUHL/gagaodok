package com.sapiens.gagaodok.sync
import java.io.File
import org.junit.Assert.*
import org.junit.Test
class SyncRecoveryMnemonicTest {
 @Test fun `official zero entropy vector round trips and checksum fails closed`() { val words=SyncRecoveryMnemonic.words(File("../../Sources/KakaoSapiens/Resources/sync/english-bip39.txt").readText());val entropy=ByteArray(16);val expected=List(11){"abandon"}.joinToString(" ")+" about";assertEquals(expected,SyncRecoveryMnemonic.encode(entropy,words));assertArrayEquals(entropy,SyncRecoveryMnemonic.decode("  ${expected.uppercase()}  ",words));assertThrows(SyncRecoveryMnemonicException::class.java){SyncRecoveryMnemonic.decode(expected.removeSuffix("about")+"ability",words)} }
}
