package com.sapiens.gagaodok

import com.sapiens.gagaodok.data.MeasurementPolicy
import com.sapiens.gagaodok.data.OptimizationMeasurementStore
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/// 저장된 계측 장부를 읽고 다시 쓸 때 옛 기록이 사라지지 않아야 합니다.
///
/// **실제로 잃었습니다.** `8a848b5`에서 `finishReasons`를 `failureDetails`로
/// 이름만 바꾸고 별칭도, schema 버전 올림도 두지 않았습니다. `Codec.json`은
/// `ignoreUnknownKeys = true`라 옛 키를 **오류 없이 버리고**, 다음 저장 때
/// 파일에서 영영 사라집니다. 기기 장부의 run-7에 `NOT_STOP` 8건이 남아 있는데
/// 그것이 `MAX_TOKENS`였다는 기록은 없습니다 — 출력 예산 결함의 직접 증거였습니다.
///
/// 그 데이터는 되찾을 수 없습니다. 이 테스트는 **되풀이를 막습니다.**
class MeasurementLedgerMigrationTest {

    private fun tempFile() = File.createTempFile("ledger-migration", ".json")

    @Test
    fun `옛 이름으로 저장된 실패 사유를 읽어 온다`() {
        val file = tempFile()
        file.writeText(OLD_FORMAT_LEDGER)

        val store = OptimizationMeasurementStore(file) { 2_000L }

        assertEquals(mapOf("MAX_TOKENS" to 7), store.state.value.completedRuns.single().memory.failureDetails)
    }

    @Test
    fun `읽고 다시 저장해도 옛 기록이 남는다`() {
        val file = tempFile()
        file.writeText(OLD_FORMAT_LEDGER)

        // 읽고 → 새 측정을 시작하고 → 저장한다. 예전에는 이 지점에서 사라졌다.
        val store = OptimizationMeasurementStore(file) { 2_000L }
        store.start(MeasurementPolicy.current())
        store.stop()

        val reloaded = OptimizationMeasurementStore(file) { 3_000L }
        val old = reloaded.state.value.completedRuns.first { run -> run.id == 1 }
        assertEquals(mapOf("MAX_TOKENS" to 7), old.memory.failureDetails)
    }

    private companion object {
        /// `8a848b5` 이전 형식입니다. `failureDetails` 대신 `finishReasons`가 있습니다.
        val OLD_FORMAT_LEDGER = """
            {
              "schemaVersion": 1,
              "completedRuns": [
                {
                  "id": 1,
                  "startedAtMillis": 1000,
                  "endedAtMillis": 1500,
                  "policy": {
                    "minimumCacheTokens": 4600,
                    "officialMinimumCacheTokens": 4096,
                    "cacheTtlSeconds": 1800,
                    "burstWindowSeconds": 300,
                    "refreshTailMinimumTokens": 2000
                  },
                  "memory": {
                    "attempts": 8,
                    "paidAttempts": 8,
                    "committed": 0,
                    "outcomeCounts": { "NOT_STOP": 8 },
                    "finishReasons": { "MAX_TOKENS": 7 }
                  }
                }
              ]
            }
        """.trimIndent()
    }
}
