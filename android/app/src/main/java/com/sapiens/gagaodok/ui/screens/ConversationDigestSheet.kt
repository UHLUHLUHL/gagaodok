package com.sapiens.gagaodok.ui.screens

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.updateTransition
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.sapiens.gagaodok.service.ConversationDigestStatus
import com.sapiens.gagaodok.ui.Metrics
import com.sapiens.gagaodok.ui.components.ExpandMotion
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme

/**
 * 이 방의 대화 요약이 어디까지 왔는지 보여줍니다.
 *
 * 읽기만 합니다. 요약을 만들거나 지우지 않습니다.
 *
 * 유리 재질을 쓰지 않습니다. 호감도 카드에서 가져온 것은 **모션뿐**이고
 * 재질과 색은 카카오 목록 화면의 것을 그대로 씁니다.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConversationDigestSheet(
    status: ConversationDigestStatus,
    onDismiss: () -> Unit,
) {
    val colors = KakaoTheme.colors
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = colors.surface,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = Metrics.screenPadding)
                .padding(bottom = 24.dp)
                .navigationBarsPadding()
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text("대화 요약", style = KakaoText.screenTitle, color = colors.textPrimary)

            DigestHeadline(status)

            if (status.segments.isEmpty()) {
                EmptyDigestNotice(status)
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    status.segments.forEach { segment ->
                        DigestSegmentRow(
                            label = "${segment.firstTurn}~${segment.lastTurn}턴",
                            length = segment.text.length,
                            body = segment.text,
                        )
                    }
                }
            }
        }
    }
}

/** 맨 위 한 줄. 표시등 색은 동기화 상태 표시와 같은 규칙입니다. */
@Composable
private fun DigestHeadline(status: ConversationDigestStatus) {
    val colors = KakaoTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier
                    .size(6.dp)
                    .background(
                        if (status.isActive) Color(0xFF34C759)
                        else colors.textSecondary.copy(alpha = 0.5f),
                        CircleShape,
                    ),
            )
            Text(
                if (status.segments.isEmpty()) "요약 없음"
                else "요약 ${status.segments.size}구간 · 1~${status.coveredTurns}턴",
                style = KakaoText.listName,
                color = colors.textPrimary,
                modifier = Modifier.padding(start = 6.dp),
            )
        }
        Text(
            buildString {
                append("전체 ${status.totalTurns}턴 · 원문 ${status.verbatimTurns}턴")
                if (status.isActive) {
                    append(
                        if (status.turnsUntilNext == 0) " · 다음 답변 뒤 요약"
                        else " · 다음 요약까지 ${status.turnsUntilNext}턴",
                    )
                }
            },
            style = KakaoText.caption,
            color = colors.textSecondary,
        )
    }
}

/** 아직 요약할 만큼 길지 않을 때. 왜 없는지를 화면이 스스로 답합니다. */
@Composable
private fun EmptyDigestNotice(status: ConversationDigestStatus) {
    val colors = KakaoTheme.colors
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(colors.chatBackground)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            if (status.isActive) "곧 첫 요약이 만들어집니다."
            else "아직 요약할 만큼 길지 않습니다.",
            style = KakaoText.listName,
            color = colors.textPrimary,
        )
        Text(
            if (status.isActive) "다음 답변 뒤에 앞부분이 요약으로 바뀝니다."
            else "${com.sapiens.gagaodok.service.ConversationCompactor.THRESHOLD_TURNS}턴부터 시작하며, 지금 ${status.totalTurns}턴입니다.",
            style = KakaoText.caption,
            color = colors.textSecondary,
        )
    }
}

/** 한 구간. 누르면 요약 본문이 펼쳐집니다. */
@Composable
private fun DigestSegmentRow(label: String, length: Int, body: String) {
    val colors = KakaoTheme.colors
    var expanded by remember { mutableStateOf(false) }
    val transition = updateTransition(expanded, label = "요약 구간")
    val bodyAlpha by transition.animateFloat(
        transitionSpec = { ExpandMotion.reveal(targetState) }, label = "본문",
    ) { if (it) 1f else 0f }
    val chevron by animateFloatAsState(
        targetValue = if (expanded) 90f else 0f,
        animationSpec = ExpandMotion.shape(),
        label = "화살표",
    )

    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(colors.chatBackground)
            .clickable { expanded = !expanded }
            .padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("›", style = KakaoText.listName, color = colors.textSecondary,
                modifier = Modifier.rotate(chevron))
            Text(label, style = KakaoText.listName, color = colors.textPrimary,
                modifier = Modifier.padding(start = 8.dp).weight(1f))
            Text("${length}자", style = KakaoText.caption, color = colors.textSecondary)
        }
        if (expanded || bodyAlpha > 0f) {
            Text(
                body,
                style = KakaoText.body,
                color = colors.textSecondary,
                modifier = Modifier.padding(top = 10.dp).alpha(bodyAlpha),
            )
        }
    }
}
