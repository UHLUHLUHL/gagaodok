package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.ChatRoom
import org.junit.Assert.assertEquals
import org.junit.Test

/// 보조 호출(기억 요약·말투 조사·대화 요약)이 어느 모델을 쓰는지 정하는 규칙입니다.
///
/// **예전에는 `AIServiceTransport`가 3.7을 박아 두었습니다.** 모델이 하나뿐이던
/// 시절의 코드가 남은 것이라, 대화는 3.8인데 그 대화를 요약하는 것은 3.7이었습니다.
/// 실제 청구서(2026-09-15)에서 3.7 입력 24,667토큰이 잡혔고, 그것이 680턴 압축의
/// 기억 요약 한 번과 토큰까지 일치했습니다.
///
/// 단가가 같아 돈 문제는 아니었습니다. 문제는 **M2 구간 요약이 영구 보존**이라,
/// 3.8이 읽을 기억을 3.7이 쓰고 있었다는 것입니다.
class AuxiliaryModelTest {

    private fun room(modelIdentifier: String? = null, mode: ChatMode? = null) = ChatRoom(
        modelIdentifier = modelIdentifier,
        modeIdentifier = mode?.rawValue
    )

    @Test
    fun `고른 적 없는 개인방은 3_8을 쓴다`() {
        assertEquals(
            AIModel.GEMINI_38_FLASH,
            room().resolvedModel(AIModel.GEMINI_38_FLASH)
        )
    }

    @Test
    fun `방이 고른 모델을 그대로 따른다`() {
        // 보조 호출이 대화와 다른 모델을 쓰면, 요약을 쓰는 쪽과 읽는 쪽이 갈린다.
        assertEquals(
            AIModel.GEMINI_38_FLASH,
            room(AIModel.GEMINI_38_FLASH.rawValue).resolvedModel(AIModel.GEMINI_38_FLASH)
        )
        assertEquals(
            AIModel.GEMINI_37_FLASH,
            room(AIModel.GEMINI_37_FLASH.rawValue).resolvedModel(AIModel.GEMINI_38_FLASH)
        )
    }

    @Test
    fun `옛 식별자로 저장된 방도 이어 붙는다`() {
        // 이 표가 없으면 그 방은 전역 기본값으로 튀고 옛 요금 기록이 사라진다.
        assertEquals(
            AIModel.GEMINI_37_FLASH,
            room("gemini-3.6-flash").resolvedModel(AIModel.GEMINI_38_FLASH)
        )
    }

    @Test
    fun `수학 멘토는 3_7로 고정된다`() {
        // 멘토는 태블릿이고 이번 범위 밖이다. 대화와 보조 호출이 함께 3.7로 남는다.
        assertEquals(
            AIModel.GEMINI_37_FLASH,
            room(AIModel.GEMINI_38_FLASH.rawValue, ChatMode.MATH_MENTOR)
                .resolvedModel(AIModel.GEMINI_38_FLASH)
        )
    }

    @Test
    fun `설정 화면은 개인방에 쓸 수 있는 모델을 모두 보여 준다`() {
        // 3.8이 들어올 때 목록을 같이 안 고쳐서 고를 수 있는 것이 3.7뿐이었다.
        // 저장된 기본값은 이미 3.8인데 화면에는 안 보였다.
        assertEquals(
            listOf(AIModel.GEMINI_38_FLASH, AIModel.GEMINI_37_FLASH),
            AIModel.personalCompanionModels
        )
    }
}
