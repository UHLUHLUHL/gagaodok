package com.sapiens.gagaodok.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
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
import androidx.compose.ui.unit.dp
import com.sapiens.gagaodok.GagaodokApp
import com.sapiens.gagaodok.model.ChatMode
import com.sapiens.gagaodok.model.PersonaStyle
import com.sapiens.gagaodok.service.AIService
import com.sapiens.gagaodok.service.analyzePersonaStyle
import com.sapiens.gagaodok.service.lookupPersona
import com.sapiens.gagaodok.service.previewPersona
import com.sapiens.gagaodok.service.refinePersonaStyle
import com.sapiens.gagaodok.ui.Metrics
import com.sapiens.gagaodok.ui.components.Hairline
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme
import kotlinx.coroutines.launch
import java.util.UUID

/// 방마다 다른 말투를 만드는 화면입니다.
///
/// 내용이 많아 시트 대신 전체화면으로 둡니다. 시트로 하면 키보드가 올라올 때
/// 남는 높이가 너무 적어 무엇을 쓰고 있는지 보이지 않습니다.
@Composable
fun PersonaEditorScreen(roomId: UUID, onBack: () -> Unit) {
    val context = LocalContext.current
    val app = context.applicationContext as GagaodokApp
    val colors = KakaoTheme.colors
    val scope = rememberCoroutineScope()
    val ai = AIService.get(context)

    val rooms by app.chatStore.rooms.collectAsState()
    val room = rooms.firstOrNull { it.id == roomId }
    if (room == null) {
        androidx.compose.runtime.LaunchedEffect(Unit) { onBack() }
        return
    }
    val mode = room.resolvedMode

    var enabled by remember { mutableStateOf(room.profile.persona.isEnabled) }
    var description by remember { mutableStateOf(room.profile.persona.description) }
    var styleGuide by remember { mutableStateOf(room.profile.persona.styleGuide) }
    var samplesText by remember {
        mutableStateOf(room.profile.persona.samples.joinToString("\n"))
    }
    var lookupQuery by remember { mutableStateOf("") }
    var refineInstruction by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf<String?>(null) }
    var status by remember { mutableStateOf<String?>(null) }
    // 지금 무엇을 하고 있는지 한 줄입니다. 조사처럼 오래 걸리는 일은 이 줄이
    // 실제로 도착한 내용에 따라 바뀝니다(`AIService.lookupProgressLabel`).
    var progress by remember { mutableStateOf<String?>(null) }

    // 미리보기는 물어본 말마다 답을 따로 답니다. 예전에는 마지막 답 하나만
    // 목록 아래에 떨어뜨려서, 무엇에 대한 답인지도 답이 왔는지도 알기 어려웠습니다.
    var previewAnswers by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var previewAsking by remember { mutableStateOf<String?>(null) }
    var customQuestion by remember { mutableStateOf("") }

    fun samples(): List<String> = samplesText.lines().map { it.trim() }.filter { it.isNotEmpty() }

    fun save() {
        app.chatStore.updatePersona(
            roomId,
            PersonaStyle(
                description = description.trim(),
                samples = samples(),
                styleGuide = styleGuide.trim(),
                isEnabled = enabled
            )
        )
    }

    fun run(label: String, block: suspend () -> Unit) {
        if (busy != null) return
        busy = label
        status = null
        progress = null
        scope.launch {
            try {
                block()
            } catch (e: Exception) {
                status = e.message ?: "실패했습니다."
            } finally {
                busy = null
                progress = null
                previewAsking = null
            }
        }
    }

    /// 미리보기 한 마디를 물어봅니다.
    fun ask(message: String) {
        if (message.isBlank()) return
        previewAsking = message
        run("preview") {
            val answer = ai.previewPersona(
                roomId,
                PersonaStyle(description, samples(), styleGuide, true),
                room.profile.name, message, mode
            )
            previewAnswers = previewAnswers + (message to answer)
        }
    }

    val statusInset = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()

    Column(
        Modifier
            .fillMaxSize()
            .background(colors.surface)
            .padding(top = statusInset)
            .imePadding()
    ) {
        Row(
            Modifier.fillMaxWidth().height(Metrics.topBarHeight).padding(end = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = { save(); onBack() }) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, "뒤로", tint = colors.textPrimary)
            }
            Text("말투 · ${room.profile.name}", style = KakaoText.screenTitle, color = colors.textPrimary)
            Spacer(Modifier.weight(1f))
            Text(
                "저장",
                style = KakaoText.roomName,
                color = colors.textPrimary,
                modifier = Modifier.clickable { save(); onBack() }
            )
        }
        Hairline()

        Column(
            Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Metrics.screenPadding)
                .navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Spacer(Modifier.height(4.dp))

            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("이 말투 사용", style = KakaoText.roomName, color = colors.textPrimary)
                    Text(
                        if (mode == ChatMode.COMPANION) "챗봇 모드에서는 인물 그 자체로 말합니다."
                        else "멘토 모드에서는 말투만 바뀌고 풀이 방식은 그대로입니다.",
                        style = KakaoText.caption,
                        color = colors.textTertiary
                    )
                }
                Switch(checked = enabled, onCheckedChange = { enabled = it })
            }

            Field("인물 설명", description, minHeight = 0.dp) { description = it }

            // MARK: - 이름으로 조사
            SectionTitle("이름이나 링크로 찾기")
            Text(
                "대사를 외우고 있지 않아도 됩니다. 이름을 넣으면 검색해서 대사와 말투를 모아 옵니다.",
                style = KakaoText.caption,
                color = colors.textTertiary
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) {
                    Field("", lookupQuery, placeholder = "예: 어떤 작품의 누구") { lookupQuery = it }
                }
                SheetButton(
                    "찾기",
                    filled = true,
                    enabled = busy == null && lookupQuery.isNotBlank()
                ) {
                    run("lookup") {
                        val result = ai.lookupPersona(
                            lookupQuery,
                            roomId,
                            onProgress = { progress = it }
                        )
                        if (!result.isUsable) {
                            status = "확신도 ${result.confidence}. ${result.note}"
                            return@run
                        }
                        if (result.samples.isNotEmpty()) samplesText = result.samples.joinToString("\n")
                        if (result.styleGuide.isNotEmpty()) styleGuide = result.styleGuide
                        if (description.isBlank()) description = lookupQuery.trim()
                        status = buildString {
                            append("확신도 ${result.confidence}")
                            if (result.note.isNotEmpty()) append(" · ${result.note}")
                            append("\n대사 ${result.samples.size}줄을 가져왔습니다.")
                            if (result.sources.isNotEmpty()) append("\n출처: ${result.sources.joinToString(", ")}")
                        }
                    }
                }
            }
            // 진행 줄은 누른 단추 **바로 아래**에 둡니다. 예전에는 화면 맨 끝에 있어서,
            // 긴 화면을 스크롤해 내려가지 않으면 뭔가 되고 있는지조차 안 보였습니다.
            if (busy == "lookup") {
                BusyLine(progress ?: "자료를 찾고 있습니다…")
            }

            // MARK: - 대사
            SectionTitle("실제 대사")
            Text(
                "한 줄에 하나씩 넣습니다. 설명보다 실제 대사가 훨씬 잘 먹힙니다.",
                style = KakaoText.caption,
                color = colors.textTertiary
            )
            Field("", samplesText, minHeight = 120.dp) { samplesText = it }
            SheetButton(
                "이 대사로 말투 규칙 뽑기",
                filled = false,
                enabled = busy == null && samples().isNotEmpty(),
                modifier = Modifier.fillMaxWidth()
            ) {
                run("analyze") {
                    styleGuide = ai.analyzePersonaStyle(roomId, description, samples())
                    status = "말투 규칙을 새로 만들었습니다."
                }
            }
            if (busy == "analyze") BusyLine("대사에서 말투를 뽑고 있습니다…")

            // MARK: - 규칙
            SectionTitle("말투 규칙")
            Field("", styleGuide, minHeight = 140.dp) { styleGuide = it }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) {
                    Field("", refineInstruction, placeholder = "예: 좀 더 무뚝뚝하게") { refineInstruction = it }
                }
                SheetButton(
                    "다듬기",
                    filled = false,
                    enabled = busy == null && refineInstruction.isNotBlank() && styleGuide.isNotBlank()
                ) {
                    run("refine") {
                        styleGuide = ai.refinePersonaStyle(
                            roomId, styleGuide, refineInstruction, description, samples()
                        )
                        refineInstruction = ""
                        status = "규칙을 고쳤습니다."
                    }
                }
            }
            if (busy == "refine") BusyLine("규칙을 고치고 있습니다…")

            // MARK: - 미리보기
            //
            // **예전에는 이름만 미리보기였습니다.** 상황을 누르면 요청은 나갔지만,
            // 답은 세 줄 아래 별도의 상자에 떨어졌습니다. 무엇에 대한 답인지 표시가
            // 없었고, 다른 상황을 누르면 앞의 답이 소리 없이 사라졌으며, 기다리는
            // 동안에는 아무 표시도 없었습니다. 눌러도 아무 일이 없는 것처럼 보였습니다.
            //
            // 지금은 물어본 말과 그 답을 대화방과 같은 모양으로 나란히 답니다.
            // 물어본 말마다 답이 따로 남고, 기다리는 동안에는 그 자리에 표시가 뜹니다.
            SectionTitle("미리보기")
            Text(
                "저장하기 전에 결을 확인합니다. 지금 화면에 있는 설정 그대로, 실제 대화와 같은 지침으로 물어봅니다.",
                style = KakaoText.caption,
                color = colors.textTertiary
            )
            AIService.previewPrompts(mode).forEach { (situation, message) ->
                PreviewExchange(
                    situation = situation,
                    message = message,
                    answer = previewAnswers[message],
                    asking = previewAsking == message,
                    enabled = busy == null,
                    onAsk = { ask(message) }
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) {
                    Field("", customQuestion, placeholder = "직접 물어보기") { customQuestion = it }
                }
                SheetButton(
                    "물어보기",
                    filled = false,
                    enabled = busy == null && customQuestion.isNotBlank()
                ) {
                    val asked = customQuestion.trim()
                    customQuestion = ""
                    ask(asked)
                }
            }
            // 직접 물어본 것들도 순서대로 남깁니다.
            previewAnswers.keys
                .filterNot { key -> AIService.previewPrompts(mode).any { it.second == key } }
                .forEach { question ->
                    PreviewExchange(
                        situation = "직접 물어봄",
                        message = question,
                        answer = previewAnswers[question],
                        asking = previewAsking == question,
                        enabled = busy == null,
                        onAsk = { ask(question) }
                    )
                }
            if (previewAsking != null && previewAnswers[previewAsking] == null &&
                AIService.previewPrompts(mode).none { it.second == previewAsking }
            ) {
                PreviewExchange(
                    situation = "직접 물어봄",
                    message = previewAsking!!,
                    answer = null,
                    asking = true,
                    enabled = false,
                    onAsk = {}
                )
            }

            status?.let {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .background(colors.sunken, RoundedCornerShape(10.dp))
                        .padding(12.dp),
                    verticalAlignment = Alignment.Top
                ) {
                    Text(it, style = KakaoText.caption, color = colors.textSecondary, modifier = Modifier.weight(1f))
                    Icon(
                        Icons.Filled.Close, "닫기",
                        tint = colors.textTertiary,
                        modifier = Modifier.size(16.dp).clickable { status = null }
                    )
                }
            }

            Spacer(Modifier.height(28.dp))
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(text, style = KakaoText.roomName, color = KakaoTheme.colors.textPrimary)
}

/// 지금 무엇을 하고 있는지 한 줄로 보여줍니다. 누른 단추 바로 아래에 놓습니다.
@Composable
private fun BusyLine(text: String) {
    val colors = KakaoTheme.colors
    Row(verticalAlignment = Alignment.CenterVertically) {
        CircularProgressIndicator(
            Modifier.size(14.dp),
            strokeWidth = 2.dp,
            color = colors.textSecondary
        )
        Text(
            text,
            style = KakaoText.caption,
            color = colors.textSecondary,
            modifier = Modifier.padding(start = 8.dp)
        )
    }
}

/// 미리보기 한 쌍입니다. 물어본 말은 오른쪽 노란 말풍선, 답은 왼쪽 흰 말풍선으로
/// 대화방과 같은 모양입니다. 여기서 보이는 결이 실제 대화의 결이라는 뜻입니다.
@Composable
private fun PreviewExchange(
    situation: String,
    message: String,
    answer: String?,
    asking: Boolean,
    enabled: Boolean,
    onAsk: () -> Unit
) {
    val colors = KakaoTheme.colors
    Column(Modifier.fillMaxWidth()) {
        Text(situation, style = KakaoText.caption, color = colors.textTertiary)
        Row(
            Modifier.fillMaxWidth().padding(top = 4.dp),
            horizontalArrangement = Arrangement.End
        ) {
            Box(
                Modifier
                    .background(colors.bubbleMine, RoundedCornerShape(12.dp))
                    .clickable(enabled = enabled, onClick = onAsk)
                    .padding(horizontal = 12.dp, vertical = 9.dp)
            ) {
                Text(message, style = KakaoText.bubble, color = colors.bubbleMineText)
            }
        }
        when {
            asking && answer == null -> Box(Modifier.padding(top = 6.dp)) {
                BusyLine("대답을 기다리고 있습니다…")
            }
            answer != null -> Row(Modifier.fillMaxWidth().padding(top = 6.dp)) {
                Box(
                    Modifier
                        .background(colors.bubbleTheirs, RoundedCornerShape(12.dp))
                        .padding(horizontal = 12.dp, vertical = 9.dp)
                ) {
                    Text(answer, style = KakaoText.bubble, color = colors.bubbleTheirsText)
                }
            }
            else -> Text(
                "눌러서 물어봅니다",
                style = KakaoText.caption,
                color = colors.textTertiary,
                modifier = Modifier.padding(top = 4.dp)
            )
        }
    }
}

@Composable
private fun Field(
    label: String,
    value: String,
    placeholder: String = "",
    minHeight: androidx.compose.ui.unit.Dp = 0.dp,
    onValueChange: (String) -> Unit
) {
    val colors = KakaoTheme.colors
    Column(Modifier.fillMaxWidth()) {
        if (label.isNotEmpty()) {
            Text(label, style = KakaoText.caption, color = colors.textSecondary)
        }
        Box(
            Modifier
                .fillMaxWidth()
                .padding(top = if (label.isEmpty()) 0.dp else 6.dp)
                .background(colors.sunken, RoundedCornerShape(10.dp))
                .heightIn(min = if (minHeight > 0.dp) minHeight else 46.dp)
                .padding(horizontal = 12.dp, vertical = 12.dp)
        ) {
            if (value.isEmpty() && placeholder.isNotEmpty()) {
                Text(placeholder, style = KakaoText.body, color = colors.textTertiary)
            }
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                singleLine = minHeight == 0.dp,
                textStyle = LocalTextStyle.current.merge(KakaoText.body).copy(color = colors.textPrimary),
                cursorBrush = SolidColor(colors.textPrimary),
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}
