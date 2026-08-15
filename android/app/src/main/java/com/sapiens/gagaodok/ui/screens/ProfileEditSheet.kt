package com.sapiens.gagaodok.ui.screens

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LocalTextStyle
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.sapiens.gagaodok.ui.Metrics
import com.sapiens.gagaodok.ui.components.RoomAvatar
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme

data class ProfileEditResult(
    val name: String,
    val statusMessage: String,
    val image: Bitmap?,
    val didChangeImage: Boolean
)

/// 프로필을 고치는 시트입니다. 맥 판은 창 위에 뜨는 모달이었는데, 모바일에서는
/// 아래에서 올라오는 시트가 표준이고 키보드와도 잘 맞습니다.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProfileEditSheet(
    title: String,
    confirmLabel: String,
    initialName: String,
    initialStatus: String,
    initialAvatar: Bitmap?,
    onDismiss: () -> Unit,
    onConfirm: (ProfileEditResult) -> Unit
) {
    val colors = KakaoTheme.colors
    val context = LocalContext.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    var name by remember { mutableStateOf(initialName) }
    var status by remember { mutableStateOf(initialStatus) }
    var image by remember { mutableStateOf(initialAvatar) }
    var imageChanged by remember { mutableStateOf(false) }

    // 사진 선택기는 권한이 필요 없습니다. 저장소 전체 권한을 받는 옛 방식은
    // 대화 상대 사진 한 장 고르자고 앨범 전체를 열어달라는 것이라 과합니다.
    val picker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia()
    ) { uri: Uri? ->
        if (uri != null) {
            runCatching {
                context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it) }
            }.getOrNull()?.let {
                image = it
                imageChanged = true
            }
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = colors.surface
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = Metrics.screenPadding)
                .padding(bottom = 24.dp)
                .imePadding()
                .navigationBarsPadding(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Text(title, style = KakaoText.screenTitle, color = colors.textPrimary)

            Box(
                Modifier.clickable {
                    picker.launch(
                        PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                    )
                }
            ) {
                RoomAvatar(image, 84.dp)
            }
            Text(
                "사진을 눌러 바꿉니다",
                style = KakaoText.caption,
                color = colors.textTertiary
            )

            SheetField(label = "이름", value = name, onValueChange = { name = it })
            SheetField(label = "상태 메시지", value = status, onValueChange = { status = it })

            Row(
                Modifier.fillMaxWidth().padding(top = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                SheetButton(
                    text = "취소",
                    filled = false,
                    modifier = Modifier.weight(1f),
                    onClick = onDismiss
                )
                SheetButton(
                    text = confirmLabel,
                    filled = true,
                    enabled = name.isNotBlank(),
                    modifier = Modifier.weight(1f),
                    onClick = {
                        onConfirm(ProfileEditResult(name.trim(), status.trim(), image, imageChanged))
                    }
                )
            }
        }
    }
}

@Composable
private fun SheetField(label: String, value: String, onValueChange: (String) -> Unit) {
    val colors = KakaoTheme.colors
    Column(Modifier.fillMaxWidth()) {
        Text(label, style = KakaoText.caption, color = colors.textSecondary)
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = true,
            textStyle = LocalTextStyle.current.merge(KakaoText.body).copy(color = colors.textPrimary),
            cursorBrush = SolidColor(colors.textPrimary),
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 6.dp)
                .background(colors.sunken, RoundedCornerShape(10.dp))
                .padding(horizontal = 12.dp, vertical = 12.dp)
        )
    }
}

@Composable
internal fun SheetButton(
    text: String,
    filled: Boolean,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    onClick: () -> Unit
) {
    val colors = KakaoTheme.colors
    Box(
        modifier
            .background(
                if (filled) colors.bubbleMine.copy(alpha = if (enabled) 1f else 0.4f) else colors.sunken,
                RoundedCornerShape(10.dp)
            )
            .clickable(enabled = enabled, onClick = onClick)
            .padding(vertical = 13.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text,
            style = KakaoText.roomName,
            color = if (filled) colors.bubbleMineText else colors.textPrimary
        )
    }
}
