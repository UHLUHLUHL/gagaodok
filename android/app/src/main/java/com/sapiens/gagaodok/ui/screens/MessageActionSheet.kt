package com.sapiens.gagaodok.ui.screens

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.sapiens.gagaodok.model.ChatMessage
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme

/// 말풍선을 길게 눌렀을 때 나오는 메뉴입니다.
///
/// 맥 판은 마우스를 올리면 나타나는 작은 버튼들과 오른쪽 클릭 메뉴였습니다.
/// 모바일에는 올림이 없으므로 길게 누르기 하나로 모읍니다.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MessageActionSheet(
    message: ChatMessage,
    onDismiss: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit
) {
    val colors = KakaoTheme.colors
    val context = LocalContext.current
    val sheetState = rememberModalBottomSheetState()

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = colors.surface
    ) {
        Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(bottom = 12.dp)) {
            ActionRow("복사") {
                copyToClipboard(context, message.text)
                onDismiss()
            }
            // 내가 보낸 것만 고칠 수 있습니다. 고치면 그 뒤의 대화를 지우고 다시 답을 받습니다.
            if (message.sender == MessageSender.USER) {
                ActionRow("메시지 수정 후 다시 받기", onClick = onEdit)
            }
            ActionRow("삭제", tint = Color(0xFFD05050), onClick = onDelete)
        }
    }
}

@Composable
private fun ActionRow(
    title: String,
    tint: Color? = null,
    onClick: () -> Unit
) {
    val colors = KakaoTheme.colors
    Text(
        title,
        style = KakaoText.body,
        color = tint ?: colors.textPrimary,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 20.dp, vertical = 15.dp)
    )
}

private fun copyToClipboard(context: Context, text: String) {
    val manager = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return
    manager.setPrimaryClip(ClipData.newPlainText("가가오독", text))
}
