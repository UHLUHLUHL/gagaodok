package com.sapiens.gagaodok

import com.sapiens.gagaodok.data.applyingAffection
import com.sapiens.gagaodok.data.initialRooms
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.ChatRoom
import com.sapiens.gagaodok.model.RoomProfile
import org.junit.Assert.assertNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatStoreDefaultsTest {
    @Test
    fun `empty storage stays empty instead of recreating Sapiens`() {
        assertTrue(initialRooms(emptyList()).isEmpty())
    }

    @Test
    fun `saved rooms are preserved and legacy personal room resolves as companion`() {
        val saved = listOf(ChatRoom(title = "기존 친구"))

        assertEquals(saved, initialRooms(saved))
        assertEquals(ChatMode.COMPANION, initialRooms(saved).single().resolvedMode)
    }

    @Test
    fun `호감도는 경계에서 잘리고 실제로 움직인 폭만 기록한다`() {
        val nearTop = RoomProfile(baseAffection = 99)

        // +2를 요청했지만 100이 천장이라 실제로는 +1만 움직입니다.
        val applied = nearTop.applyingAffection(2, "고백해줘서")!!
        assertEquals(100, applied.baseAffection)
        assertEquals(1, applied.lastAffectionDelta)
        assertEquals("고백해줘서", applied.lastAffectionReason)

        // 천장에 붙은 뒤로는 더 올릴 수 없으므로 이유도 덮지 않습니다.
        assertNull(applied.applyingAffection(2, "새 이유"))
        assertNull(RoomProfile(baseAffection = 0).applyingAffection(-3, "무례해서"))
        assertNull(nearTop.applyingAffection(0, "변화 없음"))
    }

    @Test
    fun `옛 저장의 방은 변한 적 없음으로 읽힌다`() {
        val legacy = RoomProfile()

        assertEquals(0, legacy.lastAffectionDelta)
        assertEquals("", legacy.lastAffectionReason)
    }
}
