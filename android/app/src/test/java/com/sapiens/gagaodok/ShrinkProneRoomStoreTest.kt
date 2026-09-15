package com.sapiens.gagaodok

import com.sapiens.gagaodok.service.readShrinkProneRooms
import com.sapiens.gagaodok.service.writeShrinkProneRooms
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/// "이 방은 답을 다시 받는 방"이라는 표시를 파일에 남깁니다.
///
/// **메모리에만 두었더니 사실상 꺼져 있었습니다.** 표시는 `SHRUNK`을 한 번 겪어야
/// 켜지는데, 앱 프로세스가 죽으면 지워져 다음에 다시 처음부터입니다. 실기기
/// 계측에서 저녁부터 아침 사이에 대화 묶음이 5번, 프로세스 재시작이 최소 2번
/// 있었고, 그 구간의 캐시는 `lagEntries = 0`이었습니다 — 어제 넣은 물림이 실사용에서
/// 한 번도 켜지지 않았습니다.
///
/// 그 사이 다시 받기 12회 중 2회가 캐시를 깼습니다. 수정 전 비율(17.7%)과 같습니다.
/// 방마다 **한 번만** 내면 되는 값을 앱을 켤 때마다 다시 내고 있었습니다.
class ShrinkProneRoomStoreTest {

    private fun tempFile() = File.createTempFile("shrink-prone", ".json").also { it.delete() }

    @Test
    fun `적어 두면 다음에 읽힌다`() {
        val file = tempFile()
        writeShrinkProneRooms(file, setOf("room-a|gemini-3.8-flash", "room-b|gemini-3.8-flash"))

        assertEquals(
            setOf("room-a|gemini-3.8-flash", "room-b|gemini-3.8-flash"),
            readShrinkProneRooms(file)
        )
    }

    @Test
    fun `파일이 없으면 빈 것으로 시작한다`() {
        // 처음 켜는 기기입니다. 오류가 아닙니다.
        assertTrue(readShrinkProneRooms(tempFile()).isEmpty())
    }

    @Test
    fun `깨진 파일은 빈 것으로 친다`() {
        // 캐시 최적화용 표시일 뿐이라, 못 읽으면 예전처럼 동작하면 됩니다.
        // 여기서 예외를 던지면 그 방은 대화 자체가 안 됩니다.
        val file = tempFile().also { it.writeText("{ 이건 JSON이 아니다") }
        assertTrue(readShrinkProneRooms(file).isEmpty())
    }

    @Test
    fun `방마다 따로 기억한다`() {
        val file = tempFile()
        writeShrinkProneRooms(file, setOf("room-a|gemini-3.8-flash"))
        val loaded = readShrinkProneRooms(file)

        assertTrue("고쳐 쓴 방", "room-a|gemini-3.8-flash" in loaded)
        assertTrue("고쳐 쓴 적 없는 방", "room-b|gemini-3.8-flash" !in loaded)
    }

    @Test
    fun `모델이 다르면 다른 표시다`() {
        // 키가 `방ID|모델`입니다. 모델을 바꾸면 캐시도 새로 만들어지므로
        // 그 조합에서 다시 한 번 겪어야 켜집니다.
        val file = tempFile()
        writeShrinkProneRooms(file, setOf("room-a|gemini-3.8-flash"))
        val loaded = readShrinkProneRooms(file)

        assertTrue("room-a|gemini-3.8-flash" in loaded)
        assertTrue("room-a|gemini-3.7-flash" !in loaded)
    }

    @Test
    fun `쓰다가 실패해도 예외를 던지지 않는다`() {
        // 저장 실패는 다음 실행에서 한 번 더 겪는 것일 뿐입니다. 대화를 막을 일이 아닙니다.
        val directory = File.createTempFile("shrink-prone-dir", "").also {
            it.delete(); it.mkdirs()
        }
        writeShrinkProneRooms(directory, setOf("room-a|gemini-3.8-flash"))
    }
}
