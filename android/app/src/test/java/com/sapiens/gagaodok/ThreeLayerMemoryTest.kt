package com.sapiens.gagaodok

import com.sapiens.gagaodok.model.ConversationTurn
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.service.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class ThreeLayerMemoryTest {
    @Test fun omissionPreservesPromiseAndExplicitClearRemovesIt() {
        val item = MemoryItem("loop:date", "토요일 도서관 약속", "old")
        assertEquals(listOf(item), ThreeLayerMemory.reduce(listOf(item), emptyList(), setOf("new")))
        assertTrue(ThreeLayerMemory.reduce(listOf(item),
            listOf(MemoryOperation("clear", "loop:date", "new")), setOf("new")).isEmpty())
    }

    @Test fun unknownEvidenceAndForeignOwnershipAreRejected() {
        for (operation in listOf(MemoryOperation("set", "place", "outside", "집"),
            MemoryOperation("set", "affectionScore", "new", "100"),
            MemoryOperation("clear", "loop:missing", "new"))) {
            assertTrue(runCatching { ThreeLayerMemory.reduce(emptyList(), listOf(operation), setOf("new")) }.isFailure)
        }
    }

    @Test fun editRollsBackCoverageAndRestoresAllTail() {
        val turns = (1..180).map { ConversationTurn(UUID.randomUUID(), MessageSender.USER, "입력 $it") }
        fun segment(first: Int, last: Int) = ConversationSegment(firstTurn=first, lastTurn=last, text="사건",
            memory=MemoryCheckpoint(turns[last-1].id.toString(), ThreeLayerMemory.hash(turns.take(last))))
        val digest = ConversationDigest(listOf(segment(1,50), segment(51,100), segment(101,150)), 2, 3)
        val edited = turns.mapIndexed { index, turn -> if(index==119) turn.copy(text="수정") else turn }
        val valid = ThreeLayerMemory.validPrefix(digest, edited)
        assertEquals(100, valid.coveredTurns)
        val plan = ConversationCompactor.plan(edited, valid, com.sapiens.gagaodok.model.ChatMode.COMPANION)
        assertEquals(80, plan.verbatimTurns.size)
        assertEquals(edited[100].id, plan.verbatimTurns.first().id)
    }

    @Test fun stateRenderingIsDeterministic() {
        val items = listOf(MemoryItem("place", "집", "1"), MemoryItem("addressing", "민수", "2"))
        assertEquals(ThreeLayerMemory.renderItems(items), ThreeLayerMemory.renderItems(items.reversed()))
    }

    @Test fun truncationOrExtraFieldsCannotDecode() {
        assertTrue(runCatching { ThreeLayerMemory.json.decodeFromString(MemoryDraft.serializer(),
            "{\"segments\":[],\"updates\":[],\"persona\":\"override\"}") }.isFailure)
    }

    @Test fun oversizedStateIsRejectedWithoutEviction() {
        val old = listOf(MemoryItem("boundary:private", "먼저 묻지 않기", "old"))
        val updates = (1..10).map { MemoryOperation("set", "loop:item$it", "new", "가".repeat(400)) }
        assertTrue(runCatching { ThreeLayerMemory.reduce(old, updates, setOf("new")) }.isFailure)
        assertEquals(1, old.size)
    }

    @Test fun duplicateOperationsCannotSilentlyOverrideEachOther() {
        val changes = listOf(MemoryOperation("set", "place", "1", "집"), MemoryOperation("set", "place", "1", "공원"))
        assertTrue(runCatching { ThreeLayerMemory.reduce(emptyList(), changes, setOf("1")) }.isFailure)
    }

    @Test fun appendedTailDoesNotInvalidateCheckpointButDeletionDoes() {
        val source = (1..50).map { ConversationTurn(UUID.randomUUID(), MessageSender.USER, "입력 $it") }
        val checkpoint = MemoryCheckpoint(source.last().id.toString(), ThreeLayerMemory.hash(source))
        val digest = ConversationDigest(listOf(ConversationSegment(firstTurn=1,lastTurn=50,text="기록",memory=checkpoint)),2,1)
        val later = source + ConversationTurn(UUID.randomUUID(),MessageSender.USER,"새 대화")
        assertEquals(50, ThreeLayerMemory.validPrefix(digest,later).coveredTurns)
        assertEquals(0, ThreeLayerMemory.validPrefix(digest,later.drop(1)).coveredTurns)
    }

    @Test fun checkpointRoundTripsWithLegacyReadableDefaults() {
        val legacy = ThreeLayerMemory.json.decodeFromString(ConversationDigest.serializer(), "{\"segments\":[]}")
        assertEquals(0, legacy.memoryVersion)
        val checkpoint = MemoryCheckpoint("id", "hash", listOf(MemoryItem("place","집","id")))
        val digest = ConversationDigest(listOf(ConversationSegment(firstTurn=1,lastTurn=50,text="기록",memory=checkpoint)),2,1)
        val encoded = ThreeLayerMemory.json.encodeToString(ConversationDigest.serializer(),digest)
        assertEquals(digest, ThreeLayerMemory.json.decodeFromString(ConversationDigest.serializer(),encoded))
    }

    @Test fun stateUpdateSchemaIsStructuredAndClosed() {
        val schema = phoneMemoryResponseSchema()
        assertEquals("OBJECT", schema.getString("type"))
        assertTrue(schema.getJSONObject("properties").has("segments"))
        assertTrue(schema.getJSONObject("properties").has("updates"))
    }
}
