package com.sapiens.gagaodok.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier

/// 물결 효과 없이 누를 수 있게 합니다.
///
/// `clickable`에 `indication`을 주지 않으면 머티리얼 기본 물결이 그대로 새어 나옵니다.
/// 이 앱의 화면은 피그마 시안을 그대로 옮긴 것이고 시안에는 물결이 없으므로, 직접 그린
/// 아이콘과 카드 위에 안드로이드 기본 모션이 겹쳐 보입니다.
///
/// 특히 누르는 대상이 카드처럼 크면 물결 원이 카드를 통째로 덮어 반투명한 회색 원이
/// 퍼지는 것처럼 보입니다. 작은 아이콘에서는 반대로 물결이 아이콘보다 커서 어색합니다.
/// [onClickLabel]은 화면 낭독기가 "무엇을 하는 단추인지" 읽어 주는 말입니다.
/// 물결을 끄면서 이것까지 같이 떨어뜨리면 눈으로 못 보는 사용자에게는 이름 없는 단추가 됩니다.
@Composable
internal fun Modifier.clickableNoRipple(
    enabled: Boolean = true,
    onClickLabel: String? = null,
    onClick: () -> Unit
): Modifier {
    val interaction = remember { MutableInteractionSource() }
    return this.clickable(
        interactionSource = interaction,
        indication = null,
        enabled = enabled,
        onClickLabel = onClickLabel,
        onClick = onClick
    )
}
