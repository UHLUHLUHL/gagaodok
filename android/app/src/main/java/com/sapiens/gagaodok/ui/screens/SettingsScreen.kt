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
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.sapiens.gagaodok.GagaodokApp
import com.sapiens.gagaodok.BuildConfig
import com.sapiens.gagaodok.data.MeasurementPolicy
import com.sapiens.gagaodok.data.SecureStore
import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.service.buildOptimizationExport
import com.sapiens.gagaodok.service.shareUsagePatternExport
import com.sapiens.gagaodok.service.writeUsagePatternExport
import com.sapiens.gagaodok.ui.Metrics
import com.sapiens.gagaodok.ui.components.RoomAvatar
import com.sapiens.gagaodok.ui.theme.AppearanceMode
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme
import java.text.NumberFormat
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

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
    val measurement by app.optimizationMeasurement.state.collectAsState()
    val scope = rememberCoroutineScope()
    var exportState by remember { mutableStateOf<String?>(null) }
    var isExporting by remember { mutableStateOf(false) }
    var showUsageReset by remember { mutableStateOf(false) }
    var showMeasurementClear by remember { mutableStateOf(false) }

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

        // MARK: - 데이터
        SettingsSection("데이터") {
            val totalUSD = app.usage.totalCostUSD
            val savingsUSD = app.usage.totalSavingsUSD
            Column {
                Column(Modifier.padding(14.dp)) {
                    Text("API 사용 금액", style = KakaoText.sectionHeader, color = colors.textSecondary)
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
                val cacheCreated = AIModel.entries.sumOf { app.usage.totalUsage(it).cacheCreateTokens }
                if (cacheCreated > 0) {
                    // 캐시를 새로 올리는 데 쓴 몫입니다. 위 '입력'에는 안 들어갑니다 —
                    // 별개의 요청이라 어떤 promptTokenCount에도 안 잡히기 때문입니다.
                    InfoRow("캐시에 올린 토큰", "${formatCount(cacheCreated)} tokens")
                }
                if (savingsUSD > 0) {
                    InfoRow(
                        "캐시로 아낀 금액",
                        "₩" + NumberFormat.getNumberInstance(Locale.KOREA)
                            .apply { maximumFractionDigits = 2 }
                            .format(savingsUSD * exchangeRate)
                    )
                }
                InfoRow("적용 환율", "1 USD = ${formatCount(exchangeRate.toInt())} KRW")

                // 여기 숫자가 실제 청구액보다 적을 수 있는 이유를 숨기지 않습니다.
                val unreported = app.usage.totalUnreportedRequests
                if (unreported > 0) {
                    Text(
                        "사용량을 못 받은 요청이 ${unreported}건 있습니다. 도중에 멈췄거나 실패한 요청이라 " +
                            "청구서에는 있고 위 금액에는 빠져 있습니다.",
                        style = KakaoText.caption,
                        color = colors.textTertiary,
                        modifier = Modifier.padding(top = 8.dp)
                    )
                }
                }
                if (usageByRoom.isNotEmpty()) {
                    Box(Modifier.fillMaxWidth().height(1.dp).background(colors.surface))
                    Text(
                        "대화방별 사용 내역",
                        style = KakaoText.sectionHeader,
                        color = colors.textSecondary,
                        modifier = Modifier.padding(start = 14.dp, top = 12.dp)
                    )
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
                if (!BuildConfig.TABLET_MENTOR) {
                    Box(Modifier.fillMaxWidth().height(1.dp).background(colors.surface))
                    val active = measurement.activeRun
                    val latest = measurement.completedRuns.lastOrNull()
                    Column(
                        Modifier
                            .fillMaxWidth()
                            .clickable {
                                if (active == null) app.optimizationMeasurement.start(MeasurementPolicy.current())
                                else app.optimizationMeasurement.stop()
                            }
                            .padding(horizontal = 14.dp, vertical = 13.dp)
                    ) {
                        Text(
                            if (active == null) "최적화 측정 시작" else "측정 종료",
                            style = KakaoText.body,
                            color = colors.textPrimary
                        )
                        Text(
                            when {
                                active != null -> "측정 중 · ${active.requests.requestCount}개 요청 기록됨"
                                latest != null -> "${measurement.completedRuns.size}개 측정 회차 보존됨"
                                else -> "추가 API 호출 없이 실제 요청의 캐시 판단만 기록합니다."
                            },
                            style = KakaoText.timestamp,
                            color = colors.textTertiary
                        )
                    }
                }
                Column(
                Modifier
                    .fillMaxWidth()
                    .clickable(enabled = !isExporting) {
                        isExporting = true
                        exportState = "통계를 만드는 중…"
                        scope.launch {
                            runCatching {
                                withContext(Dispatchers.IO) {
                                    val messages = rooms.associate { room ->
                                        room.id to app.chatStore.loadMessages(room.id)
                                    }
                                    val json = buildOptimizationExport(
                                        rooms, messages, usageByRoom, measurement
                                    )
                                    writeUsagePatternExport(context, json)
                                }
                            }.onSuccess { (fileName, uri) ->
                                exportState = "Downloads/Gagaodok에 저장됨"
                                shareUsagePatternExport(context, fileName, uri)
                            }.onFailure {
                                exportState = "내보내기에 실패했습니다."
                            }
                            isExporting = false
                        }
                    }
                    .padding(horizontal = 14.dp, vertical = 13.dp)
            ) {
                Text("분석 데이터 내보내기", style = KakaoText.body, color = colors.textPrimary)
                Text(
                    "측정 중에도 대화 내용 없이 회차별 JSON을 공유할 수 있습니다.",
                    style = KakaoText.timestamp,
                    color = colors.textTertiary
                )
                exportState?.let {
                    Text(it, style = KakaoText.timestamp, color = colors.textSecondary)
                }
            }
                if (!BuildConfig.TABLET_MENTOR &&
                    (measurement.activeRun != null || measurement.completedRuns.isNotEmpty())
                ) {
                    Box(
                        Modifier.fillMaxWidth().clickable { showMeasurementClear = true }.padding(14.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text("측정 기록 삭제", style = KakaoText.body, color = Color(0xFFD05050))
                    }
                }
                Box(
                    Modifier.fillMaxWidth().clickable { showUsageReset = true }.padding(14.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text("사용량 초기화", style = KakaoText.body, color = Color(0xFFD05050))
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

        Box(Modifier.height(24.dp))
    }

    if (showUsageReset) {
        AlertDialog(
            onDismissRequest = { showUsageReset = false },
            title = { Text("사용량을 초기화할까요?") },
            text = { Text("누적 토큰과 금액만 지웁니다. 채팅과 최적화 측정 기록은 유지됩니다.") },
            confirmButton = {
                TextButton(onClick = { app.usage.resetAll(); showUsageReset = false }) { Text("초기화") }
            },
            dismissButton = { TextButton(onClick = { showUsageReset = false }) { Text("취소") } }
        )
    }
    if (showMeasurementClear) {
        AlertDialog(
            onDismissRequest = { showMeasurementClear = false },
            title = { Text("측정 기록을 삭제할까요?") },
            text = { Text("완료된 회차와 진행 중인 측정이 모두 삭제됩니다. API 사용량은 유지됩니다.") },
            confirmButton = {
                TextButton(onClick = {
                    app.optimizationMeasurement.clear(); showMeasurementClear = false
                }) { Text("삭제") }
            },
            dismissButton = { TextButton(onClick = { showMeasurementClear = false }) { Text("취소") } }
        )
    }
}

@Composable
private fun ApiKeyField(credential: SecureStore.Credential) {
    val context = LocalContext.current
    val colors = KakaoTheme.colors
    var value by remember { mutableStateOf(SecureStore.apiKey(context, credential) ?: "") }
    // null이면 아직 안 눌렀고, 참이면 저장됐고, 거짓이면 저장에 실패했습니다.
    var saved by remember { mutableStateOf<Boolean?>(null) }

    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(credential.displayName, style = KakaoText.sectionHeader, color = colors.textPrimary)
            Box(Modifier.weight(1f))
            when (saved) {
                true -> Text("저장됨", style = KakaoText.timestamp, color = colors.textTertiary)
                // 조용히 실패하면 사용자는 키를 넣었다고 믿은 채로 계속 오류만 봅니다.
                false -> Text(
                    "저장하지 못했습니다",
                    style = KakaoText.timestamp,
                    color = Color(0xFFD05050)
                )
                null -> Unit
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
                    onValueChange = { value = it; saved = null },
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
                saved = SecureStore.save(context, credential, value)
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
