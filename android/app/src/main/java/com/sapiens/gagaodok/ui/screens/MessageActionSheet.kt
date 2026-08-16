package com.sapiens.gagaodok.ui.screens

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import com.sapiens.gagaodok.model.ChatMessage
import com.sapiens.gagaodok.model.MessageSender
import com.sapiens.gagaodok.ui.components.KakaoMenuItem

/// 말풍선을 길게 눌렀을 때 나오는 메뉴의 줄들입니다.
///
/// 카드의 모양과 치수는 `KakaoActionCard`에 있고, 카드를 띄우는 자리는
/// `KakaoMenuHost` 한 곳뿐입니다. 여기서는 줄만 만듭니다.
///
/// 원조 카드에는 태그 칩 줄과 우리에게 없는 기능(답장·전달·공지 등)이 더 있습니다.
/// **모양만 가져오고 줄은 우리 기능만 둡니다.**
fun messageMenuItems(
    context: Context,
    message: ChatMessage,
    onDone: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit
): List<KakaoMenuItem> = buildList {
    add(KakaoMenuItem("복사") { copyToClipboard(context, message.text); onDone() })
    // 내가 보낸 것만 고칠 수 있습니다.
    if (message.sender == MessageSender.USER) add(KakaoMenuItem("수정", onClick = onEdit))
    // 원조의 '삭제'도 다른 줄과 같은 검정입니다. 빨강으로 두면
    // 이 카드에서 그 줄만 다른 앱처럼 보입니다.
    add(KakaoMenuItem("삭제", onClick = onDelete))
}

private fun copyToClipboard(context: Context, text: String) {
    val manager = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return
    manager.setPrimaryClip(ClipData.newPlainText("가가오독", text))
}
