package com.sapiens.gagaodok.model

import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import java.util.Locale
import java.util.UUID

/// 맥 판이 쓰는 JSON과 글자 하나까지 같은 형식으로 읽고 씁니다.
///
/// 저장 파일을 서로 옮길 수 있게 하려는 것이고, 그러려면 Swift `Codable`의 기본 규칙을
/// 그대로 흉내 내야 합니다. 두 군데가 다릅니다.
///
/// - 날짜: Swift는 2001-01-01 00:00:00 UTC를 0으로 삼는 실수 초입니다. 유닉스 기준시와
///   978,307,200초 차이가 납니다. 이걸 모르고 그냥 유닉스 초로 쓰면 31년이 어긋납니다.
/// - UUID: Swift는 대문자 하이픈 형식으로 씁니다.
object Codec {
    /// Swift 기준시(2001-01-01)와 유닉스 기준시(1970-01-01)의 차이입니다.
    const val SWIFT_EPOCH_OFFSET_SECONDS = 978_307_200.0

    val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
    }

    fun swiftTimeToEpochMillis(swiftSeconds: Double): Long =
        ((swiftSeconds + SWIFT_EPOCH_OFFSET_SECONDS) * 1000.0).toLong()

    fun epochMillisToSwiftTime(millis: Long): Double =
        millis / 1000.0 - SWIFT_EPOCH_OFFSET_SECONDS
}

/// 유닉스 밀리초를 담지만 JSON에는 Swift 기준시 실수 초로 오갑니다.
object SwiftDateSerializer : KSerializer<Long> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("SwiftDate", PrimitiveKind.DOUBLE)

    override fun serialize(encoder: Encoder, value: Long) {
        encoder.encodeDouble(Codec.epochMillisToSwiftTime(value))
    }

    override fun deserialize(decoder: Decoder): Long =
        Codec.swiftTimeToEpochMillis(decoder.decodeDouble())
}

/// Swift가 쓰는 대문자 UUID 문자열로 오갑니다.
object UuidSerializer : KSerializer<UUID> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("UUID", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: UUID) {
        encoder.encodeString(value.toString().uppercase(Locale.ROOT))
    }

    override fun deserialize(decoder: Decoder): UUID =
        UUID.fromString(decoder.decodeString())
}
