package com.sapiens.gagaodok

import com.sapiens.gagaodok.data.ConversationScope
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.UUID

class ConversationScopeTest {
    @Test
    fun personalScopeKeepsLegacyNamesAndRoomConversationId() {
        val roomId = UUID.fromString("11111111-2222-3333-4444-555555555555")
        val scope = ConversationScope(roomId)

        assertEquals("room_11111111-2222-3333-4444-555555555555_messages.json", scope.messageFileName)
        assertEquals("room_11111111-2222-3333-4444-555555555555_digest.json", scope.digestFileName)
        assertEquals(roomId, scope.aiConversationId)
    }

    @Test
    fun groupScopeUsesWorldlineNamesAndConversationId() {
        val roomId = UUID.fromString("11111111-2222-3333-4444-555555555555")
        val worldlineId = UUID.fromString("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        val scope = ConversationScope(roomId, worldlineId)

        assertEquals("room_11111111-2222-3333-4444-555555555555_worldline_AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE_messages.json", scope.messageFileName)
        assertEquals("room_11111111-2222-3333-4444-555555555555_worldline_AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE_digest.json", scope.digestFileName)
        assertEquals(worldlineId, scope.aiConversationId)
    }
}
