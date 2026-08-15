package com.sapiens.gagaodok.ui.components

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.sapiens.gagaodok.ui.theme.KakaoTheme

/// 얇은 구분선입니다.
///
/// Material의 `HorizontalDivider`는 테마 색을 따라가서 다크 모드에서 너무 밝게 그려집니다.
/// 맥 판에서 같은 문제를 겪고 색을 직접 정했습니다. 여기서도 그렇게 합니다.
@Composable
fun Hairline(modifier: Modifier = Modifier, color: Color = KakaoTheme.colors.hairline) {
    Box(modifier.fillMaxWidth().height(1.dp).background(color))
}

@Composable
fun VerticalHairline(modifier: Modifier = Modifier, color: Color = KakaoTheme.colors.hairline) {
    Box(modifier.width(1.dp).background(color))
}

/// 방·사람의 프로필 사진입니다. 사진이 없으면 카카오톡 기본 아바타를 흉내 냅니다.
@Composable
fun RoomAvatar(
    bitmap: Bitmap?,
    size: Dp,
    modifier: Modifier = Modifier
) {
    Box(
        modifier
            .size(size)
            .clip(AvatarSquircle)
            .background(if (bitmap == null) DEFAULT_AVATAR_BACKGROUND else Color.Transparent),
        contentAlignment = Alignment.Center
    ) {
        if (bitmap != null) {
            Image(
                bitmap = bitmap.asImageBitmap(),
                contentDescription = null,
                modifier = Modifier.size(size),
                contentScale = ContentScale.Crop
            )
        } else {
            Icon(
                Icons.Filled.Person,
                contentDescription = null,
                tint = Color.White.copy(alpha = 0.96f),
                modifier = Modifier.size(size * 0.62f)
            )
        }
    }
}

// 카카오 민트-스카이블루. 맥 판에서 그대로 옮겼습니다.
private val DEFAULT_AVATAR_BACKGROUND = Color(0xFF82C2D9)
