package com.sapiens.gagaodok

import com.sapiens.gagaodok.service.LOOP_RULE_LIMIT
import com.sapiens.gagaodok.service.MemoryItem
import com.sapiens.gagaodok.service.MemoryOperation
import com.sapiens.gagaodok.service.ThreeLayerMemory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/// 상태가 가득 찼을 때 멈추지 않고 가장 덜 중요한 것을 놓아주는 규칙입니다.
///
/// **영원히 안 차는 설계는 불가능합니다.** 규칙(`boundary`/`loop`)은 대화가 길어질수록
/// 쌓이기만 하고, 실측 250턴 동안 삭제가 0건이었습니다. 어떤 상한을 두든 언젠가
/// 만납니다. 가능한 것은 **차도 멈추지 않는 설계**입니다.
///
/// 예전에는 넘치면 전체를 거부했습니다. 그러면 규칙 하나가 몇십 토큰 넘쳤다는
/// 이유로 **그 시도의 50턴짜리 구간 요약까지 함께 버려졌고**, 입력이 같으니 다음
/// 시도도 같은 결과라 요약 범위가 영구히 멈췄습니다. 실제로 300턴에서 멈춰 있었습니다.
class MemoryDegradationTest {
    private fun loop(n: Int, at: Int) =
        MemoryItem("loop:pattern_$n", "패턴 $n 에 대한 기록", "ev$n", setAtTurn = at)

    private fun boundary(n: Int, at: Int) =
        MemoryItem("boundary:rule_$n", "지켜야 하는 약속 $n", "ev$n", setAtTurn = at)

    @Test
    fun `반복 패턴은 개수를 넘으면 가장 오래 갱신 안 된 것부터 놓는다`() {
        // `loop`은 상태의 41%를 차지하면서 가장 빨리 자라고(50턴당 1개) 가장 덜
        // 영구적입니다. 몇 달 전 한 번 나온 패턴이 지금도 유효할 이유는 없습니다.
        val previous = (1..LOOP_RULE_LIMIT).map { loop(it, at = it * 10) }
        val result = ThreeLayerMemory.reduce(
            previous,
            listOf(MemoryOperation("set", "loop:pattern_new", "fresh", "새 패턴")),
            setOf("fresh"),
            throughTurn = 500
        )

        assertEquals(LOOP_RULE_LIMIT, result.items.count { it.key.startsWith("loop:") })
        assertEquals(1, result.droppedLoops)
        // 가장 오래된 것(setAtTurn 10)이 나가고 새것이 들어온다.
        assertTrue(result.items.none { it.key == "loop:pattern_1" })
        assertTrue(result.items.any { it.key == "loop:pattern_new" })
    }

    @Test
    fun `경계는 개수 제한을 받지 않는다`() {
        // 경계는 지켜야 하는 약속입니다. 오래됐다고 버리면 안 됩니다 — 중요한 것일수록
        // 일찍 정해지므로, 오래된 순으로 버리면 가장 중요한 것부터 사라집니다.
        val previous = (1..30).map { boundary(it, at = it * 10) }
        val result = ThreeLayerMemory.reduce(previous, emptyList(), emptySet(), throughTurn = 500)

        assertEquals(30, result.items.count { it.key.startsWith("boundary:") })
        assertEquals(0, result.droppedLoops)
    }

    @Test
    fun `분량이 넘치면 반복 패턴을 더 놓아서라도 저장은 성사시킨다`() {
        // **이것이 핵심입니다.** 넘쳤다고 거부하면 그 시도의 구간 요약까지 날아가고
        // 요약 범위가 영구히 멈춥니다. 규칙 하나를 놓는 손실이 훨씬 작습니다.
        val fat = (1..LOOP_RULE_LIMIT).map {
            MemoryItem("loop:pattern_$it", "가".repeat(500), "ev$it", setAtTurn = it * 10)
        }
        val result = ThreeLayerMemory.reduce(fat, emptyList(), emptySet(), throughTurn = 500)

        assertTrue("저장은 성사되어야 한다", result.items.isNotEmpty())
        assertTrue("분량 안에 들어와야 한다",
            ThreeLayerMemory.stateTokens(result.items) <= ThreeLayerMemory.STATE_TOKEN_BUDGET)
        assertTrue("몇 개를 놓았는지 남아야 한다", result.droppedLoops > 0)
    }

    @Test
    fun `놓을 반복 패턴이 없으면 그때는 거부한다`() {
        // 경계만으로 상한을 넘는 상황은 사람이 봐야 합니다. 조용히 경계를 버리는 것이
        // 가장 나쁜 결말입니다.
        val onlyBoundaries = (1..40).map {
            MemoryItem("boundary:rule_$it", "가".repeat(500), "ev$it", setAtTurn = it * 10)
        }
        val error = runCatching {
            ThreeLayerMemory.reduce(onlyBoundaries, emptyList(), emptySet(), throughTurn = 500)
        }.exceptionOrNull()

        assertEquals("State too large", error?.message)
    }

    @Test
    fun `새로 설정한 항목에는 그 시점의 턴이 박힌다`() {
        // 무엇을 먼저 놓을지 정하려면 언제 마지막으로 갱신됐는지 알아야 합니다.
        // 규칙이 다시 언급되면 다시 `set`되므로 이 값이 "최근 활동" 신호가 됩니다.
        val result = ThreeLayerMemory.reduce(
            emptyList(),
            listOf(MemoryOperation("set", "loop:new", "ev", "내용")),
            setOf("ev"),
            throughTurn = 450
        )
        assertEquals(450, result.items.single().setAtTurn)
    }

    @Test
    fun `옛 기록에는 턴이 없으므로 가장 오래된 것으로 친다`() {
        // 이번 변경 전에 저장된 항목에는 `setAtTurn`이 없습니다(기본 0). 그것들을
        // 먼저 놓는 것이 맞습니다 — 실제로 가장 오래된 것들입니다.
        val old = MemoryItem("loop:legacy", "옛 기록", "ev0")
        assertEquals(0, old.setAtTurn)

        val previous = listOf(old) + (2..LOOP_RULE_LIMIT).map { loop(it, at = it * 10) }
        val result = ThreeLayerMemory.reduce(
            previous,
            listOf(MemoryOperation("set", "loop:fresh", "ev", "새것")),
            setOf("ev"),
            throughTurn = 500
        )
        assertTrue(result.items.none { it.key == "loop:legacy" })
    }
}
