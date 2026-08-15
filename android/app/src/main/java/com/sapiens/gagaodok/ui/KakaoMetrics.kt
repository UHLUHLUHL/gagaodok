package com.sapiens.gagaodok.ui

import androidx.compose.ui.unit.dp

/// 이 앱이 쓰는 치수입니다.
///
/// **맥 판의 pt 값을 그대로 옮기지 않았습니다.** 그 숫자들은 데스크톱 카카오톡을
/// 화소 단위로 재서 ±0.5pt까지 맞춘 것이지만, 그건 *데스크톱의* 숫자입니다.
/// 모바일은 보는 거리와 화소 밀도가 달라 같은 숫자가 다른 크기로 읽힙니다.
///
/// 아래 값은 **안드로이드 카카오톡을 재서 정한 것이 아닙니다.** 안드로이드 메신저에서
/// 흔히 쓰는 범위와 터치 목표 최소치(48dp)를 근거로 정한 짐작입니다.
/// 나중에 실측값으로 오해하지 않도록 여기 적어 둡니다.
object Metrics {
    /// 화면 좌우 여백. 안드로이드 목록에서 가장 흔한 값입니다.
    val screenPadding = 16.dp

    /// 손가락이 닿아야 하는 것의 최소 크기입니다. 이건 짐작이 아니라 접근성 기준입니다.
    val touchTarget = 48.dp

    /// 상단 바 높이. 시스템 상태 표시줄 아래에 놓입니다.
    val topBarHeight = 56.dp

    /// 아래 탭바 높이. 제스처 바 위에 놓입니다.
    val tabBarHeight = 56.dp

    /// 목록 한 줄의 아바타.
    val listAvatar = 48.dp
    val myProfileAvatar = 60.dp

    /// 대화방 말풍선 옆 아바타.
    val bubbleAvatar = 38.dp

    /// 말풍선 최대 폭을 화면 폭의 몇 배로 둘지입니다.
    ///
    /// 맥 판은 pt로 고정돼 있는데 그대로 옮기면 320dp에서는 넘치고 430dp에서는
    /// 왼쪽에 붙은 채 남습니다. 비율로 잡되 **이 값은 아직 근거가 없는 짐작입니다.**
    /// 실제 안드로이드 카카오톡을 재서 확정해야 합니다.
    const val bubbleMaxWidthFraction = 0.68f

    /// 말풍선 모서리. 카카오톡 말풍선은 꼬리 없이 둥근 사각형입니다.
    val bubbleCorner = 14.dp
    val bubblePaddingH = 12.dp
    val bubblePaddingV = 8.dp

    /// 말풍선 사이 간격. 같은 사람이 이어서 말할 때는 좁게 둡니다.
    val bubbleGap = 8.dp
    val bubbleGapSameSender = 3.dp

    /// 나레이션은 아바타도 이름도 없이 화면 가운데에 놓입니다.
    /// 좌우를 넉넉히 비워야 말풍선과 다른 것으로 읽힙니다.
    val narrationInset = 44.dp

    /// 아이콘 크기. 맥 판의 실측 비율은 그대로 두고 크기만 모바일에 맞게 키웠습니다.
    val headerIcon = 22.dp
    val tabIcon = 24.dp
}
