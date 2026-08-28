package com.sapiens.gagaodok

import com.sapiens.gagaodok.service.ExifOrientation
import org.junit.Assert.assertEquals
import org.junit.Test

class ExifOrientationTest {

    @Test
    fun `카메라의 90도 EXIF 방향은 세로 크기와 회전으로 바뀐다`() {
        val transform = ExifOrientation.transform(6)

        assertEquals(90, transform.rotationDegrees)
        assertEquals(false, transform.flipHorizontal)
        assertEquals(ExifOrientation.Size(3024, 4032), transform.orientedSize(4032, 3024))
    }

    @Test
    fun `모든 EXIF 방향값을 회전과 반전으로 보존한다`() {
        assertEquals(ExifOrientation.Transform(0, false), ExifOrientation.transform(1))
        assertEquals(ExifOrientation.Transform(0, true), ExifOrientation.transform(2))
        assertEquals(ExifOrientation.Transform(180, false), ExifOrientation.transform(3))
        assertEquals(ExifOrientation.Transform(180, true), ExifOrientation.transform(4))
        assertEquals(ExifOrientation.Transform(90, true), ExifOrientation.transform(5))
        assertEquals(ExifOrientation.Transform(90, false), ExifOrientation.transform(6))
        assertEquals(ExifOrientation.Transform(270, true), ExifOrientation.transform(7))
        assertEquals(ExifOrientation.Transform(270, false), ExifOrientation.transform(8))
    }

    @Test
    fun `EXIF 방향값이 없거나 손상되면 원본 방향을 유지한다`() {
        assertEquals(ExifOrientation.Transform(0, false), ExifOrientation.transform(0))
        assertEquals(ExifOrientation.Transform(0, false), ExifOrientation.transform(99))
    }
}
