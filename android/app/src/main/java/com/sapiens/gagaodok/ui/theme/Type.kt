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
/// 실기기 캡처에서 글자의 **잉크 높이**를 재어 맞췄습니다.
///
/// **잰 값을 그대로 믿으면 안 되는 자리입니다.** 같은 글자('대박')를 재니 우리 것이
/// 원조보다 8.5% 컸는데, 글자 크기가 아니라 **기기의 글꼴 배율**이 달랐던 것입니다.
/// 한 줄짜리 말풍선 높이로 갈라냈습니다. 같은 15sp인데 에뮬레이터에서 141화소,
/// 사용자 기기에서 134화소가 나왔고, 안쪽 여백을 빼면 배율이 0.94입니다.
/// 그 배율을 걷어내면 원조 본문은 14.7sp라 지금 값이 맞습니다.
/// 배율을 모르고 줄였으면 오히려 틀렸을 자리입니다.
///
/// 아래 sp 값은 전부 **배율 1.0으로 환산한** 원조 잉크 높이에 맞춘 것입니다.
///
/// | 자리 | 원조 잉크(0.94) | 환산(1.0) | 정한 값 |
/// |---|---|---|---|
/// | 말풍선 본문 | 47화소 | 50.0 | 15sp |
/// | 보낸이 이름 | 39화소 | 41.5 | 13sp |
/// | 말풍선 옆 시각 | 32화소 | 34.0 | 10sp |
/// | 목록 이름 | 47화소 | 50.0 | 15sp |
/// | 목록 미리보기 | 43화소 | 45.7 | 13sp |
/// | 대화방 제목 | 56화소 | 59.6 | 18sp 굵게 |
///
/// 카카오톡 자체의 '글자 크기' 설정이 기본값이 아닐 수도 있습니다. 그건 캡처만으로는
/// 알 수 없으므로, 위 값은 사용자의 지금 설정을 기준으로 맞춘 것입니다.
///
/// 글꼴은 여기서 지정하지 않습니다. Material 서체를 통째로 갈아 끼웠으므로
/// `Text`가 알아서 Pretendard로 그립니다.
object KakaoText {
    // 줄 높이는 한 줄짜리 말풍선 높이(원조 130화소)에서 되짚었습니다.
    val bubble = TextStyle(fontSize = 15.sp, lineHeight = 20.sp)

    /// 말풍선 위의 보낸이 이름입니다.
    ///
    /// **회색이 아닙니다.** 처음에 흐린 회색(`textSecondary`)으로 뒀는데,
    /// 원조를 재 보니 가장 어두운 화소가 `#191919`로 본문과 같은 검정이었습니다.
    /// (우리 것은 `#4E565E`까지밖에 안 갔습니다.)
    val senderName = TextStyle(fontSize = 13.sp)
    val narration = TextStyle(fontSize = 13.sp, lineHeight = 19.sp)
    val roomName = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.Medium)

    /// 대화방 상단 바의 이름. 실측 잉크 높이 56화소에 굵은 글씨입니다.
    val roomTitle = TextStyle(fontSize = 18.sp, fontWeight = FontWeight.Bold)
    // 실측 잉크 높이: 이름 47화소, 미리보기 43화소, 시각 31화소.
    val listName = TextStyle(fontSize = 15.sp)
    val listPreview = TextStyle(fontSize = 13.sp)
    val listTime = TextStyle(fontSize = 10.sp)
    val screenTitle = TextStyle(fontSize = 20.sp, fontWeight = FontWeight.Bold)
    val sectionHeader = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium)
    // 실측 잉크 29화소. 우리 11sp가 37화소였으므로 9sp입니다.
    val tabLabel = TextStyle(fontSize = 9.sp, fontWeight = FontWeight.Medium)
    val timestamp = TextStyle(fontSize = 10.sp)
    val body = TextStyle(fontSize = 14.sp, lineHeight = 20.sp)
    val caption = TextStyle(fontSize = 12.sp)

    /// 수식 말풍선의 웹뷰가 쓸 크기입니다. 네이티브 말풍선과 같아야
    /// 수식이 있는 말풍선만 글자가 달라 보이지 않습니다.
    const val BUBBLE_FONT_PX = 15
    const val BUBBLE_LINE_HEIGHT = 1.40
}
