package com.sapiens.gagaodok.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.sapiens.gagaodok.GagaodokApp
import com.sapiens.gagaodok.data.SecureStore
import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.ui.Metrics
import com.sapiens.gagaodok.ui.components.RoomAvatar
import com.sapiens.gagaodok.ui.theme.AppearanceMode
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme
import java.text.NumberFormat
import java.util.Locale

@Composable
fun SettingsScreen() {
    val context = LocalContext.current
    val app = context.applicationContext as GagaodokApp
    val colors = KakaoTheme.colors
    val statusInset = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()

    val appearance by app.settings.appearance.collectAsState()
    val selectedModel by app.settings.selectedModel.collectAsState()
    val exchangeRate by app.settings.exchangeRate.collectAsState()
    val usageByRoom by app.usage.usageByRoom.collectAsState()
    val rooms by app.chatStore.rooms.collectAsState()

    Column(
        Modifier
            .fillMaxSize()
            .background(colors.surface)
            .padding(top = statusInset)
            .verticalScroll(rememberScrollState())
            .imePadding()
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(Metrics.topBarHeight)
                .padding(horizontal = Metrics.screenPadding),
            contentAlignment = Alignment.CenterStart
        ) {
            Text("설정", style = KakaoText.screenTitle, color = colors.textPrimary)
        }

        // MARK: - 요금
        SettingsSection("API 사용 금액") {
            val totalUSD = app.usage.totalCostUSD
            val savingsUSD = app.usage.totalSavingsUSD
            Column(Modifier.padding(14.dp)) {
                Row(verticalAlignment = Alignment.Bottom) {
                    Text(
                        "₩" + NumberFormat.getNumberInstance(Locale.KOREA)
                            .apply { maximumFractionDigits = 2 }
                            .format(totalUSD * exchangeRate),
                        style = KakaoText.screenTitle.copy(fontSize = 26.sp),
                        color = colors.textPrimary
                    )
                    Text(
                        String.format(Locale.US, " (\$%.4f)", totalUSD),
                        style = KakaoText.caption,
                        color = colors.textTertiary,
                        modifier = Modifier.padding(bottom = 3.dp)
                    )
                }
                InfoRow("누적 토큰", "${formatCount(app.usage.totalTokens)} tokens")
                InfoRow(
                    "입력 / 출력",
                    "${formatCount(app.usage.totalPromptTokens)} / ${formatCount(app.usage.totalCandidatesTokens)}"
                )
                if (savingsUSD > 0) {
                    InfoRow(
                        "캐시로 아낀 금액",
                        "₩" + NumberFormat.getNumberInstance(Locale.KOREA)
                            .apply { maximumFractionDigits = 2 }
                            .format(savingsUSD * exchangeRate)
                    )
                }
                InfoRow("적용 환율", "1 USD = ${formatCount(exchangeRate.toInt())} KRW")
            }
        }

        // MARK: - 대화방별
        if (usageByRoom.isNotEmpty()) {
            SettingsSection("대화방별 사용 내역") {
                Column(Modifier.padding(vertical = 4.dp)) {
                    rooms.forEach { room ->
                        val total = app.usage.roomTotal(room.id)
                        if (total.totalTokens == 0) return@forEach
                        Row(
                            Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            RoomAvatar(app.chatStore.avatar(room.id, room.profile), 34.dp)
                            Column(Modifier.weight(1f).padding(start = 10.dp)) {
                                Text(room.profile.name, style = KakaoText.listPreview, color = colors.textPrimary)
                                Text(
                                    "${formatCount(total.totalTokens)} tokens",
                                    style = KakaoText.timestamp,
                                    color = colors.textTertiary
                                )
                            }
                            Text(
                                "₩" + NumberFormat.getNumberInstance(Locale.KOREA)
                                    .apply { maximumFractionDigits = 2 }
                                    .format(app.usage.costUSD(room.id) * exchangeRate),
                                style = KakaoText.listPreview.copy(fontWeight = FontWeight.Bold),
                                color = colors.textPrimary
                            )
                        }
                    }
                }
            }
        }

        // MARK: - 모델
        SettingsSection("기본 모델") {
            Column {
                AIModel.entries.forEach { model ->
                    ChoiceRow(
                        title = model.displayName,
                        subtitle = model.providerName,
                        selected = model == selectedModel,
                        onClick = { app.settings.setSelectedModel(model) }
                    )
                }
            }
        }

        // MARK: - 화면 모드
        SettingsSection("화면 모드") {
            Column {
                AppearanceMode.entries.forEach { mode ->
                    ChoiceRow(
                        title = mode.displayName,
                        subtitle = null,
                        selected = mode == appearance,
                        onClick = { app.settings.setAppearance(mode) }
                    )
                }
            }
        }

        // MARK: - API 키
        SettingsSection("API 키") {
            Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Text(
                    "키는 이 기기 안에서만 암호화해 보관합니다. 앱에 미리 넣어 둔 키는 없습니다.",
                    style = KakaoText.caption,
                    color = colors.textTertiary
                )
                SecureStore.Credential.entries.forEach { credential ->
                    ApiKeyField(credential)
                }
            }
        }

        // MARK: - 초기화
        Box(
            Modifier
                .fillMaxWidth()
                .clickable { app.usage.resetAll() }
                .padding(vertical = 16.dp),
            contentAlignment = Alignment.Center
        ) {
            Text("사용량 초기화", style = KakaoText.body, color = androidx.compose.ui.graphics.Color(0xFFD05050))
        }

        Box(Modifier.height(24.dp))
    }
}

@Composable
private fun ApiKeyField(credential: SecureStore.Credential) {
    val context = LocalContext.current
    val colors = KakaoTheme.colors
    var value by remember { mutableStateOf(SecureStore.apiKey(context, credential) ?: "") }
    var saved by remember { mutableStateOf(false) }

    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(credential.displayName, style = KakaoText.sectionHeader, color = colors.textPrimary)
            Box(Modifier.weight(1f))
            if (saved) {
                Text("저장됨", style = KakaoText.timestamp, color = colors.textTertiary)
            }
        }
        Row(
            Modifier.padding(top = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                Modifier
                    .weight(1f)
                    // 카드도 sunken이라 입력칸까지 같은 색이면 어디가 칸인지 안 보입니다.
                    // 실제로 처음에 그렇게 만들어 칸이 통째로 사라졌습니다.
                    .background(colors.surface, RoundedCornerShape(10.dp))
                    .border(1.dp, colors.hairline, RoundedCornerShape(10.dp))
                    .padding(horizontal = 12.dp, vertical = 12.dp)
            ) {
                if (value.isEmpty()) {
                    Text("키를 붙여 넣으세요", style = KakaoText.body, color = colors.textTertiary)
                }
                BasicTextField(
                    value = value,
                    onValueChange = { value = it; saved = false },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    textStyle = LocalTextStyle.current.merge(KakaoText.body).copy(color = colors.textPrimary),
                    cursorBrush = SolidColor(colors.textPrimary),
                    modifier = Modifier.fillMaxWidth()
                )
            }
            SheetButton(
                text = "저장",
                filled = true,
                modifier = Modifier.widthIn(min = 76.dp)
            ) {
                SecureStore.save(context, credential, value)
                saved = true
            }
        }
    }
}

@Composable
private fun SettingsSection(title: String, content: @Composable () -> Unit) {
    val colors = KakaoTheme.colors
    Column(Modifier.fillMaxWidth().padding(horizontal = Metrics.screenPadding, vertical = 8.dp)) {
        Text(
            title,
            style = KakaoText.sectionHeader,
            color = colors.textSecondary,
            modifier = Modifier.padding(bottom = 6.dp, start = 2.dp)
        )
        Box(Modifier.fillMaxWidth().background(colors.sunken, RoundedCornerShape(12.dp))) {
            content()
        }
    }
}

@Composable
private fun InfoRow(label: String, value: String) {
    val colors = KakaoTheme.colors
    Row(Modifier.fillMaxWidth().padding(top = 6.dp)) {
        Text(label, style = KakaoText.caption, color = colors.textSecondary)
        Box(Modifier.weight(1f))
        Text(value, style = KakaoText.caption, color = colors.textPrimary)
    }
}

@Composable
private fun ChoiceRow(title: String, subtitle: String?, selected: Boolean, onClick: () -> Unit) {
    val colors = KakaoTheme.colors
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = KakaoText.body, color = colors.textPrimary)
            if (subtitle != null) {
                Text(subtitle, style = KakaoText.timestamp, color = colors.textTertiary)
            }
        }
        if (selected) {
            Icon(
                Icons.Filled.Check,
                contentDescription = "선택됨",
                tint = colors.textPrimary,
                modifier = Modifier.size(18.dp)
            )
        }
    }
}

internal fun formatCount(value: Int): String =
    NumberFormat.getNumberInstance(Locale.KOREA).format(value)
