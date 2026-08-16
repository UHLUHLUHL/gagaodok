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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.TheaterComedy
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
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
    /// 이 상대의 말투를 고치러 가는 길입니다. 새 상대를 만드는 시트에는 없습니다
    /// (아직 방이 없어 고칠 말투도 없습니다).
    onEditPersona: (() -> Unit)? = null,
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

            // 말투도 이 상대의 프로필입니다. 예전에는 대화방 메뉴에서만 갈 수 있었는데,
            // 프로필을 고치러 들어온 사람이 말투를 못 고치고 나가는 것이 이상했습니다.
            onEditPersona?.let { go ->
                Row(
                    Modifier
                        .fillMaxWidth()
                        .background(colors.sunken, RoundedCornerShape(10.dp))
                        .clickable(onClick = go)
                        .padding(horizontal = 14.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        Icons.Filled.TheaterComedy, contentDescription = null,
                        tint = colors.personaBadge,
                        modifier = Modifier.size(20.dp)
                    )
                    Column(Modifier.weight(1f).padding(start = 12.dp)) {
                        Text("말투 편집", style = KakaoText.roomName, color = colors.textPrimary)
                        Text(
                            "이 상대가 어떤 말씨로 말할지 정합니다.",
                            style = KakaoText.caption,
                            color = colors.textTertiary
                        )
                    }
                    Icon(
                        Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null,
                        tint = colors.textTertiary,
                        modifier = Modifier.size(20.dp)
                    )
                }
            }

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

/// 시트와 말투 편집 화면이 함께 쓰는 단추입니다.
///
/// **가로 여백을 단추가 직접 가집니다.** 예전에는 세로 여백만 있었습니다.
/// 폭을 밖에서 정해 주는 자리(시트 아래의 취소·저장)에서는 티가 안 났지만,
/// 말투 편집 화면의 '찾기'·'다듬기'처럼 폭을 안 주는 자리에서는 노란 판이
/// 글자를 그대로 문 네모가 됐습니다. 글자와 테두리 사이가 0이었습니다.
///
/// 높이도 최소 46dp로 잡습니다. 옆에 나란히 서는 입력 칸이 46dp라, 그 값과
/// 맞지 않으면 한 줄 안에서 단추만 낮아 보입니다.
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
            .heightIn(min = SheetControlHeight)
            .background(
                if (filled) colors.bubbleMine.copy(alpha = if (enabled) 1f else 0.4f) else colors.sunken,
                RoundedCornerShape(10.dp)
            )
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 18.dp, vertical = 10.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text,
            style = KakaoText.roomName,
            color = if (filled) colors.bubbleMineText else colors.textPrimary,
            maxLines = 1
        )
    }
}

/// 한 줄짜리 입력 칸과 그 옆 단추가 함께 쓰는 높이입니다.
internal val SheetControlHeight = 46.dp
