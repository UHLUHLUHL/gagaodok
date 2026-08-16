package com.sapiens.gagaodok.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

/// 라이트·다크에서 각각 쓸 색입니다.
///
/// 처음에는 맥 판에서 그대로 옮겨 왔지만, **모바일 카카오톡은 팔레트가 다릅니다.**
/// 실기기 캡처를 재 보니 대화방 바탕과 내 말풍선이 데스크톱과 달랐습니다.
/// 지금 값은 `MEASURED.md`의 실측표를 따릅니다.
///
/// 캡처 경로가 색을 바꾸지 않았는지 먼저 확인했습니다. 원조와 우리 앱 캡처 양쪽에서
/// 흰 말풍선이 모두 `#FFFFFF`로 나왔으므로 아래 값들을 그대로 믿어도 됩니다.
data class KakaoColors(
    // MARK: - 바탕
    /// 대화방 바탕. 라이트는 카카오톡 시그니처 하늘색입니다.
    val chatBackground: Color,
    /// 대화방 상단 바. 라이트에서는 바탕과 같은 색으로 이어집니다.
    val chatHeader: Color,
    /// 목록·설정 등 흰 판.
    val surface: Color,
    /// 살짝 눌린 판. 검색창 안이나 카드 배경에 씁니다.
    val sunken: Color,
    /// 눌린 행.
    val rowPressed: Color,
    /// 아래 탭바.
    val tabBar: Color,

    // MARK: - 말풍선
    /// 내 말풍선. 카카오 옐로우는 브랜드 색이라 다크에서도 그대로 둡니다.
    val bubbleMine: Color,
    /// 상대 말풍선.
    val bubbleTheirs: Color,
    val bubbleMineText: Color,
    val bubbleTheirsText: Color,
    /// 날짜 구분선 알약.
    val dateDivider: Color,
    val dateDividerText: Color,

    // MARK: - 글자
    val textPrimary: Color,
    val textSecondary: Color,
    val textTertiary: Color,
    /// 대화방 상단 바 위의 글자·아이콘. 라이트에서는 하늘색 위라 검정 계열입니다.
    val onChatHeader: Color,
    val onChatHeaderDim: Color,
    /// 말풍선 옆 보낸 시각. 하늘색 바탕 위에서 재서 뽑은 값이라
    /// 투명도로 흉내 내지 않고 따로 둡니다.
    val chatTimestamp: Color,

    // MARK: - 선과 강조
    val hairline: Color,
    val border: Color,
    /// 고른 말풍선에 덧씌우는 색.
    val selection: Color,
    /// 검색 결과 표시. 노란 말풍선 위에서도 보이도록 파랑을 씁니다.
    val searchHit: Color,
    val searchHitCurrent: Color,
    /// 말투가 켜진 방에 붙는 표시.
    val personaBadge: Color,
    /// 수정 바의 확인 단추입니다.
    ///
    /// 내 말풍선(#FFEB33)과 **다른 노랑입니다.** 실측 #FEE500으로 브랜드 노랑
    /// 그대로였습니다. 말풍선 색을 재사용하면 나란히 놓였을 때 미세하게 어긋납니다.
    val editConfirm: Color,

    val isDark: Boolean
)

private val LightColors = KakaoColors(
    // 실측: 맥 판은 #B2C7D9지만 모바일은 이 값입니다.
    chatBackground = Color(0xFFABC1D1),
    chatHeader = Color(0xFFABC1D1),
    surface = Color(0xFFFFFFFF),
    sunken = Color(0xFFF2F3F5),
    rowPressed = Color(0xFFF0F2F5),
    tabBar = Color(0xFFFFFFFF),

    // 실측: 브랜드 노랑 #FEE500이 아니라 조금 옅은 이 값입니다.
    bubbleMine = Color(0xFFFFEB33),
    bubbleTheirs = Color(0xFFFFFFFF),
    bubbleMineText = Color(0xFF191919),
    bubbleTheirsText = Color(0xFF191919),
    dateDivider = Color(0x1A000000),
    dateDividerText = Color(0x8C000000),

    textPrimary = Color(0xFF191919),
    textSecondary = Color(0x94000000),
    textTertiary = Color(0x66000000),
    onChatHeader = Color(0xFF191919),
    onChatHeaderDim = Color(0x73000000),
    chatTimestamp = Color(0xFF444D54),

    hairline = Color(0x14000000),
    border = Color(0x24000000),
    selection = Color(0x29000000),
    searchHit = Color(0xFFA8D9FF),
    searchHitCurrent = Color(0xFF59A8FF),
    personaBadge = Color(0xFFDBB800),
    // 실측 #FEE500.
    editConfirm = Color(0xFFFEE500),

    isDark = false
)

// 값은 실제 카카오톡을 다크 모드로 바꿔 화면에서 뽑았습니다.
// 채팅방 배경 #111111, 목록·헤더 #1A1A1A입니다.
private val DarkColors = KakaoColors(
    chatBackground = Color(0xFF111111),
    chatHeader = Color(0xFF1A1A1A),
    surface = Color(0xFF1A1A1A),
    sunken = Color(0xFF262626),
    rowPressed = Color(0xFF2A2A2A),
    // 맥 판에서는 왼쪽 세로 막대에 쓰던 색입니다. 모바일에는 막대가 없고 대신
    // 아래 탭바가 그 자리를 대신하므로 같은 값을 씁니다.
    tabBar = Color(0xFF222222),

    bubbleMine = Color(0xFFFEE500),
    // 이 값만 화면에서 못 재 추정했습니다. 나와의 채팅에는 받은 말풍선이 없어서,
    // 바탕(#111)에서 한 단 떠 보이는 값으로 잡았습니다. (짐작)
    bubbleTheirs = Color(0xFF2B2B2B),
    bubbleMineText = Color(0xFF1A1A1A),
    bubbleTheirsText = Color(0xFFECECEC),
    dateDivider = Color(0xFF2E2E2E),
    dateDividerText = Color(0xFFB8B8B8),

    textPrimary = Color(0xFFECECEC),
    textSecondary = Color(0xFF9A9A9A),
    textTertiary = Color(0xFF6E6E6E),
    onChatHeader = Color(0xFFE4E4E4),
    onChatHeaderDim = Color(0xFF9A9A9A),
    // 다크 모드 대화방은 원조를 재지 못했습니다. 라이트에서 잰 #444D54가
    // 바탕 대비 어느 정도인지를 보고 어두운 바탕에 옮긴 값입니다. (짐작)
    chatTimestamp = Color(0xFF9A9A9A),

    hairline = Color(0x1AFFFFFF),
    border = Color(0x29FFFFFF),
    selection = Color(0x2EFFFFFF),
    searchHit = Color(0xFF2C5A88),
    searchHitCurrent = Color(0xFF1F6FBF),
    personaBadge = Color(0xFFDBB800),
    // 브랜드 색이라 다크에서도 그대로 둡니다.
    editConfirm = Color(0xFFFEE500),

    isDark = true
)

val LocalKakaoColors = staticCompositionLocalOf { LightColors }

/// 앱 전체 화면 모드입니다. 카카오톡 환경설정의 '화면 모드'와 같은 구성입니다.
enum class AppearanceMode(val rawValue: String) {
    SYSTEM("system"),
    LIGHT("light"),
    DARK("dark");

    val displayName: String
        get() = when (this) {
            SYSTEM -> "시스템 설정"
            LIGHT -> "라이트 모드"
            DARK -> "다크 모드"
        }

    companion object {
        fun fromRawValue(value: String?): AppearanceMode =
            entries.firstOrNull { it.rawValue == value } ?: SYSTEM
    }
}

object KakaoTheme {
    val colors: KakaoColors
        @Composable get() = LocalKakaoColors.current
}

@Composable
fun GagaodokTheme(
    mode: AppearanceMode = AppearanceMode.SYSTEM,
    content: @Composable () -> Unit
) {
    val dark = when (mode) {
        AppearanceMode.SYSTEM -> isSystemInDarkTheme()
        AppearanceMode.LIGHT -> false
        AppearanceMode.DARK -> true
    }
    val colors = if (dark) DarkColors else LightColors
    val family = pretendardFamily(androidx.compose.ui.platform.LocalContext.current)

    CompositionLocalProvider(LocalKakaoColors provides colors) {
        MaterialTheme(
            // 기본 컨트롤(커서, 물결 효과, 선택 핸들)이 카카오 팔레트를 따라오게 합니다.
            colorScheme = if (dark) {
                darkColorScheme(
                    primary = colors.textPrimary,
                    background = colors.surface,
                    surface = colors.surface,
                    onSurface = colors.textPrimary
                )
            } else {
                lightColorScheme(
                    primary = colors.textPrimary,
                    background = colors.surface,
                    surface = colors.surface,
                    onSurface = colors.textPrimary
                )
            },
            typography = kakaoTypography(family),
            content = content
        )
    }
}
