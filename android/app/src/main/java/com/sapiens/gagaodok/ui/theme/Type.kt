package com.sapiens.gagaodok.ui.theme

import android.content.Context
import androidx.compose.material3.Typography
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
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
/// | 자리 | 원조 잉크 | 정한 값 |
/// |---|---|---|
/// | 말풍선 본문 | 47화소 | 15sp |
/// | 보낸이 이름 | 39화소 | 13sp |
/// | 말풍선 옆 시각 | 32화소 | 10sp |
/// | 목록 이름 | 47화소 | 15sp |
/// | 목록 미리보기 | 43화소 | 13sp |
/// | 대화방 제목 | 56화소 | 18sp 굵게 |
///
/// **기기의 글꼴 배율은 1.0입니다.** 한때 0.94로 봤지만 틀렸습니다.
/// 그때는 한 줄짜리 말풍선의 **전체 높이**를 견줬는데, 거기에는 우리가 정한
/// 안쪽 여백이 섞여 있어 배율만 갈라낼 수 없었습니다(순환 논증이었습니다).
///
/// 여백이 상쇄되는 **여러 줄 말풍선의 줄 간격**으로 다시 쟀습니다.
/// 원조 76화소, 우리 앱(배율 1.0) 75~76화소. 우리 줄 높이가 20sp이므로
/// 20 × 3.75 × 배율 = 76 → 배율 ≈ 1.01입니다. 0.94였다면 70.5화소여야 했습니다.
///
/// 잉크 높이는 여전히 우리가 8~9% 큽니다. 그건 배율이 아니라 **글꼴이 달라서**입니다
/// (Pretendard vs 카카오톡 글꼴). 같은 sp에서 잉크 비율이 다릅니다. 그래서 새 글자
/// 크기를 정할 때는 원조 잉크를 우리 말풍선 잉크(51화소)와 견줘 비율로 옮깁니다.
///
/// 카카오톡 자체의 '글자 크기' 설정이 기본값이 아닐 수도 있습니다. 그건 캡처만으로는
/// 알 수 없으므로, 위 값은 사용자의 지금 설정을 기준으로 맞춘 것입니다.
///
/// 글꼴은 여기서 지정하지 않습니다. Material 서체를 통째로 갈아 끼웠으므로
/// `Text`가 알아서 Pretendard로 그립니다.
/// 적어 둔 줄 높이를 **자르지 않고** 그대로 쓰게 하는 설정입니다.
/// 글자는 그 안에서 가운데에 놓입니다.
private val TightLine = LineHeightStyle(
    alignment = LineHeightStyle.Alignment.Center,
    trim = LineHeightStyle.Trim.None
)

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

    /// 길게 누르기 메뉴의 줄 글자입니다.
    ///
    /// 같은 캡처 안에서 메뉴 글자 잉크가 48화소, 말풍선 본문이 47화소였습니다.
    /// **같은 크기입니다.** 메뉴가 더 커 보이는 것은 줄 간격이 48dp로 넓어서입니다.
    val sheetItem = TextStyle(fontSize = 15.sp)

    /// 수정 바의 "메시지 수정" 제목과 그 아래 원문 미리보기입니다.
    ///
    /// 제목과 미리보기의 잉크 높이가 **둘 다 39화소로 같았습니다.** 크기가 아니라
    /// 굵기만 다릅니다. 색도 둘 다 #191919로 같습니다(미리보기가 흐려 보이는 것은
    /// 가는 획 때문입니다). 39화소는 말풍선 위 보낸이 이름과 같은 값이라 13sp입니다.
    ///
    /// **줄 높이를 반드시 적어야 합니다.** 안 적으면 Pretendard 기본값으로 한 줄이
    /// 80화소가 되는데, 원조는 63화소입니다(윗줄 잉크 위 1194 → 아랫줄 1257).
    /// 두 줄이라 그 차이가 34화소로 불어나 수정 바 전체가 그만큼 길어졌습니다.
    /// **한 `Text`에 두 줄로 담아야 합니다.** `Text`를 둘로 나누면 줄 높이가
    /// 먹지 않습니다. Compose는 첫 줄 위와 마지막 줄 아래의 여유를 잘라 내는데,
    /// 한 줄짜리 글은 그 둘이 곧 전부라 적어 둔 17sp가 통째로 없어지고 글꼴 본래
    /// 높이(70화소)만 남았습니다. 글꼴 여백을 끄고 `Trim.None`까지 줘도 70화소였습니다.
    /// 한 `Text` 안의 **줄 사이** 간격은 잘라 내는 대상이 아니라서 그대로 나옵니다.
    /// 굵기는 그래서 문단 스타일이 아니라 첫 줄에 얹는 `SpanStyle`로 줍니다.
    val editBanner = TextStyle(
        fontSize = 13.sp,
        lineHeight = 17.sp,
        platformStyle = PlatformTextStyle(includeFontPadding = false),
        lineHeightStyle = TightLine
    )

    /// 수식 말풍선의 웹뷰가 쓸 크기입니다. 네이티브 말풍선과 같아야
    /// 수식이 있는 말풍선만 글자가 달라 보이지 않습니다.
    const val BUBBLE_FONT_PX = 15
    const val BUBBLE_LINE_HEIGHT = 1.40
}
