package com.sapiens.gagaodok.ui.theme

import android.content.Context
import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/// 맥에는 시스템에 깔려 있지만 안드로이드에는 없어서 앱에 넣었습니다.
/// OFL 라이선스라 함께 배포해도 됩니다. 세 굵기만 넣어 4.5MB입니다.
///
/// `res/font`가 아니라 `assets/fonts`에 둡니다. 수식 말풍선의 웹뷰도 같은 파일을
/// `@font-face`로 불러 쓰기 때문입니다. 양쪽에 따로 두면 같은 글꼴이 두 벌 들어가
/// APK가 그만큼 커집니다.
private var cachedFamily: FontFamily? = null

fun pretendardFamily(context: Context): FontFamily =
    cachedFamily ?: FontFamily(
        Font("fonts/pretendard_regular.otf", context.assets, FontWeight.Normal),
        Font("fonts/pretendard_medium.otf", context.assets, FontWeight.Medium),
        Font("fonts/pretendard_bold.otf", context.assets, FontWeight.Bold)
    ).also { cachedFamily = it }

/// 앱 전체가 이 글꼴을 쓰도록 Material 기본 서체를 통째로 갈아 끼웁니다.
/// 개별 `Text`에 매번 지정하는 것보다 빠뜨릴 여지가 없습니다.
fun kakaoTypography(family: FontFamily): Typography = Typography().run {
    copy(
        displayLarge = displayLarge.copy(fontFamily = family),
        displayMedium = displayMedium.copy(fontFamily = family),
        displaySmall = displaySmall.copy(fontFamily = family),
        headlineLarge = headlineLarge.copy(fontFamily = family),
        headlineMedium = headlineMedium.copy(fontFamily = family),
        headlineSmall = headlineSmall.copy(fontFamily = family),
        titleLarge = titleLarge.copy(fontFamily = family),
        titleMedium = titleMedium.copy(fontFamily = family),
        titleSmall = titleSmall.copy(fontFamily = family),
        bodyLarge = bodyLarge.copy(fontFamily = family),
        bodyMedium = bodyMedium.copy(fontFamily = family),
        bodySmall = bodySmall.copy(fontFamily = family),
        labelLarge = labelLarge.copy(fontFamily = family),
        labelMedium = labelMedium.copy(fontFamily = family),
        labelSmall = labelSmall.copy(fontFamily = family)
    )
}

/// 이 앱에서 쓰는 글자 크기입니다.
///
/// **맥 판의 pt 값을 그대로 옮기지 않았습니다.** 그건 데스크톱 카카오톡을 잰 숫자이고,
/// 모바일은 보는 거리와 화소 밀도가 달라 같은 숫자가 다른 크기로 읽힙니다.
/// 아래 값은 안드로이드 메신저에서 흔히 쓰는 범위로 정한 **짐작**이며,
/// 실제 안드로이드 카카오톡을 재서 확정한 값이 아닙니다.
///
/// 글꼴은 여기서 지정하지 않습니다. Material 서체를 통째로 갈아 끼웠으므로
/// `Text`가 알아서 Pretendard로 그립니다.
object KakaoText {
    val bubble = TextStyle(fontSize = 15.sp, lineHeight = 21.sp)
    val narration = TextStyle(fontSize = 13.sp, lineHeight = 19.sp)
    val roomName = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.Medium)
    val listName = TextStyle(fontSize = 15.sp)
    val listPreview = TextStyle(fontSize = 13.sp)
    val listTime = TextStyle(fontSize = 11.sp)
    val screenTitle = TextStyle(fontSize = 20.sp, fontWeight = FontWeight.Bold)
    val sectionHeader = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium)
    val tabLabel = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Medium)
    val timestamp = TextStyle(fontSize = 10.sp)
    val body = TextStyle(fontSize = 14.sp, lineHeight = 20.sp)
    val caption = TextStyle(fontSize = 12.sp)

    /// 수식 말풍선의 웹뷰가 쓸 크기입니다. 네이티브 말풍선과 같아야
    /// 수식이 있는 말풍선만 글자가 달라 보이지 않습니다.
    const val BUBBLE_FONT_PX = 15
    const val BUBBLE_LINE_HEIGHT = 1.40
}
