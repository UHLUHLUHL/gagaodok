package com.sapiens.gagaodok.ui

import androidx.compose.ui.unit.dp

/// 이 앱이 쓰는 치수입니다.
///
/// 처음에는 전부 짐작이었습니다. 지금은 **대부분 실측값입니다.**
/// 사용자가 보낸 실기기 캡처(1440×2936, 밀도 3.75, 화면 폭 384dp)를 화소 단위로 재서
/// 옮겼고, 재는 방법과 원본 화소값은 `MEASURED.md`에 남겼습니다.
///
/// 아직 못 잰 값은 그 자리에 **(짐작)**이라고 적어 두었습니다. 나중에 실측값으로
/// 오해받아 지워지지 않게 하려는 것입니다.
object Metrics {
    /// 목록 화면 좌우 여백. 실측 60화소.
    val screenPadding = 16.dp

    /// 손가락이 닿아야 하는 것의 최소 크기입니다. 접근성 기준이라 실측 대상이 아닙니다.
    val touchTarget = 48.dp

    /// 상단 바 높이. 시스템 상태 표시줄 아래에 놓입니다. 실측 210화소.
    val topBarHeight = 56.dp

    /// 아래 탭바 높이. 제스처 바 위에 놓입니다. 실측 206화소.
    val tabBarHeight = 55.dp

    // MARK: - 목록

    /// 목록 한 줄의 아바타. 실측 180화소.
    val listAvatar = 48.dp
    /// 친구 목록 맨 위 내 프로필. 실측 210화소.
    val myProfileAvatar = 56.dp
    /// 친구 목록의 친구 한 줄. 실측 150화소이고 행 간격은 211화소입니다.
    /// 채팅 목록(48dp)보다 작습니다.
    val friendAvatar = 40.dp
    val friendRowPaddingV = 8.dp
    /// 목록 한 줄의 위아래 여백. 실측 행 간격 285화소에서 아바타를 뺀 값의 절반.
    val listRowPaddingV = 14.dp
    /// 아바타와 글자 사이. 실측 45화소.
    val listAvatarGap = 12.dp
    /// 시각이 놓이는 오른쪽 여백. 실측 63화소.
    val listTrailingPadding = 17.dp
    /// 이름 옆에 붙는 작은 표시(상단 고정·말투). 이름 글자(15sp)보다 작아야 하되
    /// 너무 작으면 무슨 그림인지 안 보입니다. (짐작)
    val rowBadge = 13.dp

    // MARK: - 대화방

    /// 말풍선 옆 아바타. 실측 143화소.
    val bubbleAvatar = 38.dp
    /// 대화방 좌우 여백. 실측: 아바타 왼쪽 끝이 23화소.
    val roomPadding = 6.dp
    /// 아바타 오른쪽 끝과 말풍선 왼쪽 끝 사이. 실측 22화소.
    ///
    /// 6 + 38 + 6 = 50dp이고, 실측한 말풍선 왼쪽 끝 188화소(50.1dp)와 맞습니다.
    val bubbleAvatarGap = 6.dp

    /// 말풍선 최대 폭을 화면 폭의 몇 배로 둘지입니다.
    ///
    /// **(짐작)** 받은 캡처에는 줄바꿈까지 간 말풍선이 없어서 못 쟀습니다.
    /// 긴 답변이 담긴 화면을 한 장 받으면 확정할 수 있습니다.
    const val bubbleMaxWidthFraction = 0.68f

    /// 말풍선 모서리. 실측 49화소.
    val bubbleCorner = 13.dp
    /// 말풍선 안쪽 여백. 가로는 실측 40화소.
    /// 세로는 한 줄짜리 말풍선 높이 130화소에서 되짚은 값입니다.
    val bubblePaddingH = 11.dp
    val bubblePaddingV = 8.dp

    /// 말풍선 사이 간격. 같은 사람이 이어서 말할 때는 좁게 둡니다.
    /// 실측: 같은 묶음 안이 27화소, 묶음 사이가 46화소.
    /// 위아래로 나눠 붙으므로 절반씩 적습니다.
    val bubbleGap = 6.dp
    val bubbleGapSameSender = 3.5.dp
    /// 이름 아래와 첫 말풍선 사이. 실측 27.5화소.
    val bubbleNameGap = 7.dp
    /// 말풍선과 그 옆 시각 사이. 실측 16화소.
    val bubbleTimeGap = 4.dp

    /// 나레이션은 아바타도 이름도 없이 화면 가운데에 놓입니다.
    /// 좌우를 넉넉히 비워야 말풍선과 다른 것으로 읽힙니다. (짐작)
    val narrationInset = 44.dp

    // MARK: - 입력바

    /// 입력바 전체 높이. 실측 181화소.
    val inputBarHeight = 48.dp
    /// 가운데 알약 필드 높이. 실측 135화소. 모서리는 높이의 절반(완전 알약)입니다.
    val inputFieldHeight = 36.dp
    /// 좌우의 둥근 단추 지름. 실측 105화소.
    val inputButton = 28.dp
    /// 그 단추 안의 그림 크기입니다.
    ///
    /// **이 값은 잉크가 아니라 상자입니다.** 원조의 글리프 잉크는 49화소인데,
    /// Material 아이콘은 제 상자를 다 채우지 않고 0.8쯤만 씁니다.
    /// 그래서 13dp를 주었더니 잉크가 39화소밖에 안 나왔습니다. 49 ÷ 0.8 ÷ 3.75 ≈ 16dp.
    val inputButtonGlyph = 16.dp

    /// 입력바 오른쪽 여백입니다.
    ///
    /// 왼쪽과 단추 사이는 여백을 따로 주지 않습니다. 48dp 터치 상자가 28dp 원보다
    /// 사방 10dp씩 커서 그것만으로 원조의 여백(왼쪽 36화소, 사이 33화소)이 나옵니다.
    /// 원조는 오른쪽만 59화소로 왼쪽(36)보다 넓어서 그 차이만 여기서 줍니다.
    val inputBarEndPadding = 6.dp

    /// 아이콘 크기. 목록과 대화방이 다릅니다.
    /// 실측: 목록 돋보기 74화소·톱니 78화소, 대화방 돋보기 66화소.
    val headerIcon = 20.dp
    val roomHeaderIcon = 18.dp
    /// 뒤로 화살표. 실측 72화소로 돋보기(66)보다 조금 큽니다.
    ///
    /// Material 화살표는 상자를 다 채우지 않고 잉크가 상자의 0.67쯤이라
    /// 잉크 72화소를 내려면 상자를 그만큼 키워야 합니다. 72 ÷ 0.67 ÷ 3.75 ≈ 28.7dp.
    val backIcon = 29.dp
    /// 아래 탭바 아이콘. 실측 63화소.
    val tabIcon = 17.dp
}
