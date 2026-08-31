package com.sapiens.gagaodok

import com.sapiens.gagaodok.data.initialRooms
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.ChatRoom
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
}
