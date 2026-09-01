package com.sapiens.gagaodok.sync

import java.io.File
import java.nio.file.Files
import okhttp3.Request
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Swift `SyncAttachmentTransferCoordinatorTests`와 같은 11가지를 확인한다. */
class SyncAttachmentTransferCoordinatorTest {
    private val account = "11111111-1111-4111-8111-111111111111"
    private val attachment = "70000000-0000-4000-8000-000000000001"
    private val master = ByteArray(32) { 0x22 }
    private val source = ByteArray(96) { it.toByte() }
    private val fixedRandom: (Int) -> ByteArray = { count -> ByteArray(count) { 0x40 } }

    /**
     * GET이 돌려줄 바이트를 지정할 수 있어야 한다. 빈 body를 쓰면 크기 검사에
     * 먼저 걸려 해시 검사를 시험할 수 없다.
     */
    private fun transport(
        order: MutableList<String>,
        completeStatus: Int = 204,
        downloadBody: ByteArray = ByteArray(0),
    ) = SyncHttpTransport { request: Request ->
        when {
            request.url.encodedPath.endsWith("/complete") -> {
                order += "complete"; SyncHttpResponse(completeStatus, ByteArray(0))
            }
            request.method == "GET" -> { order += "get"; SyncHttpResponse(200, downloadBody) }
            else -> { order += "put"; SyncHttpResponse(204, ByteArray(0)) }
        }
    }

    private fun coordinator(root: File, transport: SyncHttpTransport) =
        SyncAttachmentTransferCoordinator(
            account, master,
            SyncWorkerClient("https://sync.invalid", ByteArray(32) { 0x11 }, transport),
            root,
        )

    @Test fun `prepares uploads and downloads an attachment end to end`() {
        val root = Files.createTempDirectory("attach").toFile()
        try {
            val order = mutableListOf<String>()
            val plan = coordinator(root, transport(order)).prepare(
                source, attachment, SyncAttachmentKind.ATTACHMENT,
                "note.pdf", "application/pdf", fixedRandom,
            )
            // 1. 봉투 크기가 정확히 원본 + 34다.
            assertEquals(plan.sourceByteSize + 34, plan.ciphertextByteSize)
            assertEquals(plan.ciphertextByteSize, plan.ciphertext.size.toLong())
            assertEquals(64, plan.ciphertextHashHex.length)
            assertEquals(plan.ciphertextHashHex.lowercase(), plan.ciphertextHashHex)

            // 2. 업로드는 반드시 PUT 다음 complete 순서다.
            coordinator(root, transport(order)).upload(plan)
            assertEquals(listOf("put", "complete"), order)

            // 3. complete가 실패하면 오류가 나야 한다.
            assertThrows(SyncWorkerClientException::class.java) {
                coordinator(root, transport(mutableListOf(), completeStatus = 500)).upload(plan)
            }

            // 4. 크기가 다르면 거부한다.
            assertThrows(SyncAttachmentException::class.java) {
                coordinator(root, transport(mutableListOf())).download(
                    attachment, SyncAttachmentKind.ATTACHMENT, 96, 999,
                    plan.ciphertextHashHex, plan.wrappedFileKeyBase64,
                )
            }

            // 5. 해시가 다르면 거부한다. 크기가 맞는 실제 바이트를 돌려줘야
            //    크기 검사를 통과해 해시 검사에 닿는다.
            val real = coordinator(root, transport(mutableListOf(), downloadBody = plan.ciphertext))
            assertThrows(SyncAttachmentException::class.java) {
                real.download(
                    attachment, SyncAttachmentKind.ATTACHMENT, 96, plan.ciphertextByteSize,
                    "0".repeat(64), plan.wrappedFileKeyBase64,
                )
            }

            // 5b. 올바른 해시와 바이트면 왕복한다. 위 거부가 우연이 아님을 확인한다.
            val restored = real.download(
                attachment, SyncAttachmentKind.ATTACHMENT, 96, plan.ciphertextByteSize,
                plan.ciphertextHashHex, plan.wrappedFileKeyBase64,
            )
            assertArrayEquals(source, restored.readBytes())

            // 7. 복호화 결과는 sync/remote/attachments 아래에만 쓴다.
            val expected = File(File(root, "sync/remote/attachments"), attachment)
            assertEquals(expected.canonicalPath, restored.canonicalPath)
            assertTrue(restored.path.startsWith(File(root, "sync/remote/attachments").path))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test fun `refuses an attachment over the twelve megabyte ceiling`() {
        val root = Files.createTempDirectory("attach-big").toFile()
        try {
            // 조용히 자르지 않고 명시적으로 거부한다.
            val error = assertThrows(SyncAttachmentException::class.java) {
                coordinator(root, transport(mutableListOf())).prepare(
                    ByteArray((SyncAttachmentTransferCoordinator.MAX_SOURCE_BYTES + 1).toInt()),
                    attachment, SyncAttachmentKind.ATTACHMENT,
                    "big.bin", "application/octet-stream", fixedRandom,
                )
            }
            assertEquals("too_large", error.reason)
        } finally {
            root.deleteRecursively()
        }
    }
}
