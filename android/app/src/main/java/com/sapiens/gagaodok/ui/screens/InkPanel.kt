package com.sapiens.gagaodok.ui.screens

import android.view.MotionEvent
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Redo
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DeleteSweep
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.pointerInteropFilter
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.offset
import androidx.compose.ui.window.Dialog
import com.sapiens.gagaodok.model.InkDocument
import com.sapiens.gagaodok.model.InkPoint
import com.sapiens.gagaodok.model.InkStroke
import com.sapiens.gagaodok.service.InkStrokeMath
import com.sapiens.gagaodok.ui.components.Hairline
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import kotlin.math.max

/**
 * 필기 중에는 원본 벡터만 메모리에 두는 세션입니다. 화면 갱신은 move 이벤트당 한 번이고,
 * 파일 저장은 스트로크가 끝날 때만 호출자가 실행합니다.
 */
private class InkSession(initial: InkDocument) {
    var document by mutableStateOf(initial)
        private set

    private val activePoints = ArrayList<InkPoint>(256)
    private val redoStrokes = ArrayDeque<InkStroke>()
    private var activePointerId = MotionEvent.INVALID_POINTER_ID
    private var activeColorArgb = Color.Black.value.toLong()
    private var activeWidth = 4.5f
    private var activeEraser = false
    var activeRevision by mutableIntStateOf(0)
        private set

    val active: List<InkPoint> get() = activePoints
    val canUndo: Boolean get() = document.strokes.isNotEmpty()
    val canRedo: Boolean get() = redoStrokes.isNotEmpty()

    fun onMotionEvent(
        event: MotionEvent,
        surfaceSize: IntSize,
        colorArgb: Long,
        width: Float,
        eraser: Boolean
    ): Boolean {
        if (surfaceSize == IntSize.Zero) return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                activePointerId = event.getPointerId(0)
                activeColorArgb = colorArgb
                activeWidth = width
                activeEraser = eraser
                activePoints.clear()
                add(event.getX(0), event.getY(0), event.getPressure(0), surfaceSize, event.eventTime)
                return false
            }

            MotionEvent.ACTION_MOVE -> {
                val index = event.findPointerIndex(activePointerId)
                if (index < 0) return false
                for (historyIndex in 0 until event.historySize) {
                    add(
                        event.getHistoricalX(index, historyIndex),
                        event.getHistoricalY(index, historyIndex),
                        event.getHistoricalPressure(index, historyIndex),
                        surfaceSize,
                        event.getHistoricalEventTime(historyIndex)
                    )
                }
                add(event.getX(index), event.getY(index), event.getPressure(index), surfaceSize, event.eventTime)
                return false
            }

            MotionEvent.ACTION_UP -> {
                val index = event.findPointerIndex(activePointerId)
                if (index >= 0) add(event.getX(index), event.getY(index), event.getPressure(index), surfaceSize, event.eventTime)
                return finish()
            }

            MotionEvent.ACTION_CANCEL -> {
                activePoints.clear()
                activePointerId = MotionEvent.INVALID_POINTER_ID
                activeRevision++
            }
        }
        return false
    }

    fun undo(): Boolean {
        val last = document.strokes.lastOrNull() ?: return false
        redoStrokes.addLast(last)
        document = document.copy(strokes = document.strokes.dropLast(1))
        return true
    }

    fun redo(): Boolean {
        val stroke = redoStrokes.removeLastOrNull() ?: return false
        document = document.copy(strokes = document.strokes + stroke)
        return true
    }

    fun clear(): Boolean {
        if (document.strokes.isEmpty()) return false
        redoStrokes.clear()
        document = document.copy(strokes = emptyList())
        return true
    }

    private fun add(x: Float, y: Float, pressure: Float, size: IntSize, timeMillis: Long) {
        val point = InkStrokeMath.normalized(x, y, size.width.toFloat(), size.height.toFloat(), pressure, timeMillis)
        if (activePoints.lastOrNull()?.let { InkStrokeMath.shouldKeep(it, point) } != false) {
            activePoints += point
            // Snapshot 상태를 크게 복사하지 않고 숫자만 바꿉니다. Canvas는 다음 프레임에서
            // 같은 ArrayList를 읽습니다.
            activeRevision++
        }
    }

    private fun finish(): Boolean {
        activePointerId = MotionEvent.INVALID_POINTER_ID
        if (activePoints.isEmpty()) return false
        val stroke = InkStroke(
            colorArgb = activeColorArgb,
            baseWidth = activeWidth,
            eraser = activeEraser,
            points = activePoints.toList()
        )
        document = document.copy(strokes = document.strokes + stroke)
        redoStrokes.clear()
        activePoints.clear()
        activeRevision++
        return true
    }
}

@Composable
internal fun InkFloatingPanel(
    document: InkDocument,
    onDocumentChanged: (InkDocument) -> Unit,
    onAttachToChat: (InkDocument) -> Unit,
    onClose: () -> Unit
) {
    val colors = KakaoTheme.colors
    val localDensity = LocalDensity.current
    val session = remember(document.id) { InkSession(document) }
    val minWidth = 300.dp
    val minHeight = 250.dp

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val maximumWidth = maxWidth - 16.dp
        val maximumHeight = maxHeight - 16.dp
        val availableWidth = maxWidth.value
        val availableHeight = maxHeight.value
        val defaultWidth = minOf(620.dp, maximumWidth)
        val defaultHeight = minOf(460.dp, maximumHeight)
        var panelWidth by rememberSaveable(document.id) { mutableFloatStateOf(defaultWidth.value) }
        var panelHeight by rememberSaveable(document.id) { mutableFloatStateOf(defaultHeight.value) }
        var offsetX by rememberSaveable(document.id) { mutableFloatStateOf(8f) }
        var offsetY by rememberSaveable(document.id) { mutableFloatStateOf(72f) }
        // Color는 Bundle 저장 대상이 아니므로 도구 선택만 composition 동안 유지합니다.
        // 문서 원본은 InkStore가 저장하고 있어 회전/재시작 때도 필기 자체는 안전합니다.
        var color by remember(document.id) { mutableStateOf(Color(0xFF191919)) }
        var eraser by rememberSaveable(document.id) { mutableStateOf(false) }
        var penWidth by rememberSaveable(document.id) { mutableFloatStateOf(4.5f) }

        LaunchedEffect(maximumWidth, maximumHeight) {
            panelWidth = panelWidth.coerceIn(minOf(minWidth.value, maximumWidth.value), maximumWidth.value)
            panelHeight = panelHeight.coerceIn(minOf(minHeight.value, maximumHeight.value), maximumHeight.value)
            offsetX = offsetX.coerceIn(0f, max(0f, availableWidth - panelWidth))
            offsetY = offsetY.coerceIn(0f, max(0f, availableHeight - panelHeight))
        }

        val panelShape = RoundedCornerShape(14.dp)
        Box(
            Modifier
                .offset(x = offsetX.dp, y = offsetY.dp)
                .width(panelWidth.dp)
                .height(panelHeight.dp)
                .padding(0.dp)
                .clip(panelShape)
                .background(colors.surface)
                .border(1.dp, colors.border, panelShape)
                .align(Alignment.TopStart)
                .padding(0.dp)
        ) {
            // 위치 드래그는 헤더의 빈 영역에서만 받습니다. 도구 버튼과 충돌하지 않습니다.
            Column(Modifier.fillMaxSize()) {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .height(48.dp)
                        .background(colors.chatHeader),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Box(
                        Modifier
                            .weight(1f)
                            .fillMaxSize()
                            .pointerInput(panelWidth, panelHeight) {
                                detectDragGestures { change, drag ->
                                    change.consume()
                                    offsetX = (offsetX + drag.x / localDensity.density).coerceIn(0f, max(0f, availableWidth - panelWidth))
                                    offsetY = (offsetY + drag.y / localDensity.density).coerceIn(0f, max(0f, availableHeight - panelHeight))
                                }
                            }
                            .padding(start = 16.dp),
                        contentAlignment = Alignment.CenterStart
                    ) {
                        Column {
                            Text(document.title, style = KakaoText.body, color = colors.onChatHeader, fontWeight = FontWeight.Bold)
                            Text("필기", style = KakaoText.caption, color = colors.onChatHeaderDim)
                        }
                    }
                    InkIconButton(
                        label = "채팅에 첨부",
                        enabled = session.document.strokes.isNotEmpty(),
                        onClick = { onAttachToChat(session.document) }
                    ) {
                        Icon(Icons.AutoMirrored.Filled.Send, "채팅에 첨부", tint = colors.onChatHeader, modifier = Modifier.size(20.dp))
                    }
                    Box(Modifier.size(40.dp).clickable(onClick = onClose), contentAlignment = Alignment.Center) {
                        Icon(Icons.Filled.Close, "필기 닫기", tint = colors.onChatHeader, modifier = Modifier.size(20.dp))
                    }
                }

                InkToolbar(
                    penColor = color,
                    eraser = eraser,
                    penWidth = penWidth,
                    canUndo = session.canUndo,
                    canRedo = session.canRedo,
                    onChooseColor = { color = it; eraser = false },
                    onUsePen = { eraser = false },
                    onToggleEraser = { eraser = !eraser },
                    onWidthChange = { penWidth = it },
                    onUndo = { if (session.undo()) onDocumentChanged(session.document) },
                    onRedo = { if (session.redo()) onDocumentChanged(session.document) },
                    onClear = { if (session.clear()) onDocumentChanged(session.document) }
                )
                Hairline()
                InkWritingSurface(
                    session = session,
                    color = color,
                    penWidth = penWidth,
                    eraser = eraser,
                    modifier = Modifier.weight(1f),
                    onStrokeFinished = { onDocumentChanged(session.document) }
                )
                Hairline()
                Row(
                    Modifier.fillMaxWidth().height(30.dp).background(colors.surface).padding(horizontal = 12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text("벡터 원본 · 자동 저장", style = KakaoText.caption, color = colors.textTertiary)
                    Spacer(Modifier.weight(1f))
                    Text("모서리를 끌어 크기 조절", style = KakaoText.caption, color = colors.textTertiary)
                }
            }

            // 모서리만 32dp 손잡이로 잡습니다. 패널 전체의 펜 입력과 절대 겹치지 않습니다.
            Box(
                Modifier
                    .align(Alignment.BottomEnd)
                    .size(32.dp)
                    .pointerInput(maximumWidth, maximumHeight, panelWidth, panelHeight) {
                        detectDragGestures { change, drag ->
                            change.consume()
                            panelWidth = (panelWidth + drag.x / localDensity.density)
                                .coerceIn(minOf(minWidth.value, maximumWidth.value), maximumWidth.value)
                            panelHeight = (panelHeight + drag.y / localDensity.density)
                                .coerceIn(minOf(minHeight.value, maximumHeight.value), maximumHeight.value)
                        }
                    },
                contentAlignment = Alignment.Center
            ) {
                ResizeGrip(colors.textTertiary)
            }
        }
    }
}

@Composable
private fun ResizeGrip(color: Color) {
    Canvas(Modifier.size(18.dp)) {
        val spacing = size.width / 4f
        repeat(3) { index ->
            val inset = spacing * (index + 1)
            drawLine(
                color = color,
                start = Offset(size.width - inset, size.height),
                end = Offset(size.width, size.height - inset),
                strokeWidth = 1.35f * density,
                cap = StrokeCap.Round
            )
        }
    }
}

@Composable
private fun InkToolbar(
    penColor: Color,
    eraser: Boolean,
    penWidth: Float,
    canUndo: Boolean,
    canRedo: Boolean,
    onChooseColor: (Color) -> Unit,
    onUsePen: () -> Unit,
    onToggleEraser: () -> Unit,
    onWidthChange: (Float) -> Unit,
    onUndo: () -> Unit,
    onRedo: () -> Unit,
    onClear: () -> Unit
) {
    val colors = KakaoTheme.colors
    val palette = listOf(Color(0xFF191919), Color(0xFF2E6BF6), Color(0xFFE54343))
    Row(
        Modifier.fillMaxWidth().height(44.dp).background(colors.surface).padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(2.dp)
    ) {
        palette.forEach { swatch ->
            Box(
                Modifier
                    .size(32.dp)
                    .clip(CircleShape)
                    .clickable { onChooseColor(swatch) },
                contentAlignment = Alignment.Center
            ) {
                Box(
                    Modifier.size(16.dp).background(swatch, CircleShape)
                        .then(if (!eraser && swatch == penColor) Modifier.border(2.dp, colors.bubbleMine, CircleShape) else Modifier)
                )
            }
        }
        InkIconButton("펜", selected = !eraser, onClick = onUsePen) {
            Icon(Icons.Filled.Edit, "펜", tint = colors.textPrimary, modifier = Modifier.size(20.dp))
        }
        InkIconButton("지우개", selected = eraser, onClick = onToggleEraser) {
            Icon(Icons.Filled.DeleteSweep, "지우개", tint = colors.textPrimary, modifier = Modifier.size(20.dp))
        }
        InkIconButton("되돌리기", enabled = canUndo, onClick = onUndo) {
            Icon(Icons.AutoMirrored.Filled.Undo, "되돌리기", tint = if (canUndo) colors.textPrimary else colors.textTertiary, modifier = Modifier.size(20.dp))
        }
        InkIconButton("다시 실행", enabled = canRedo, onClick = onRedo) {
            Icon(Icons.AutoMirrored.Filled.Redo, "다시 실행", tint = if (canRedo) colors.textPrimary else colors.textTertiary, modifier = Modifier.size(20.dp))
        }
        InkIconButton("전체 지우기", onClick = onClear) {
            Icon(Icons.Filled.DeleteSweep, "전체 지우기", tint = colors.textPrimary, modifier = Modifier.size(20.dp))
        }
        Spacer(Modifier.weight(1f))
        listOf(3.2f, 4.5f, 6.5f).forEach { width ->
            Box(
                Modifier.size(28.dp).clip(CircleShape).clickable { onWidthChange(width) },
                contentAlignment = Alignment.Center
            ) {
                Box(
                    Modifier.size((width * 2.2f).dp).background(colors.textPrimary, CircleShape)
                        .then(if (width == penWidth) Modifier.border(1.dp, colors.bubbleMine, CircleShape) else Modifier)
                )
            }
        }
    }
}

@Composable
private fun InkIconButton(
    label: String,
    enabled: Boolean = true,
    selected: Boolean = false,
    onClick: () -> Unit = {},
    content: @Composable () -> Unit
) {
    val colors = KakaoTheme.colors
    Box(
        Modifier
            .size(36.dp)
            .clip(RoundedCornerShape(9.dp))
            .background(if (selected) colors.bubbleMine.copy(alpha = 0.6f) else Color.Transparent)
            .clickable(enabled = enabled, onClickLabel = label, onClick = onClick),
        contentAlignment = Alignment.Center
    ) { content() }
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun InkWritingSurface(
    session: InkSession,
    color: Color,
    penWidth: Float,
    eraser: Boolean,
    modifier: Modifier = Modifier,
    onStrokeFinished: () -> Unit
) {
    val colors = KakaoTheme.colors
    var surfaceSize by remember { mutableStateOf(IntSize.Zero) }
    // revision을 읽어야 ArrayList의 새 포인트가 한 프레임 안에 Canvas에 반영됩니다.
    val revision = session.activeRevision
    Canvas(
        modifier
            .fillMaxWidth()
            .background(colors.surface)
            .onSizeChanged { surfaceSize = it }
            .pointerInteropFilter { event ->
                val completed = session.onMotionEvent(event, surfaceSize, color.value.toLong(), penWidth, eraser)
                if (completed) onStrokeFinished()
                true
            }
    ) {
        revision
        session.document.strokes.forEach { drawStroke(it.points, it.colorArgb, it.baseWidth, it.eraser, colors.surface) }
        if (session.active.isNotEmpty()) drawStroke(session.active, color.value.toLong(), penWidth, eraser, colors.surface)
    }
}

private fun DrawScope.drawStroke(
    points: List<InkPoint>,
    colorArgb: Long,
    baseWidthDp: Float,
    eraser: Boolean,
    background: Color
) {
    if (points.isEmpty()) return
    val color = if (eraser) background else Color(colorArgb.toULong())
    val baseWidth = baseWidthDp * density
    fun widthAt(index: Int): Float {
        val pressure = points[index].pressure.coerceIn(0.15f, 1f)
        return max(1.2f * density, baseWidth * (0.38f + pressure * 0.62f))
    }
    if (points.size == 1) {
        val point = points.single()
        drawCircle(color, radius = widthAt(0) / 2f, center = Offset(point.x * size.width, point.y * size.height))
        return
    }
    for (index in 1 until points.size) {
        val from = points[index - 1]
        val to = points[index]
        drawLine(
            color = color,
            start = Offset(from.x * size.width, from.y * size.height),
            end = Offset(to.x * size.width, to.y * size.height),
            strokeWidth = (widthAt(index - 1) + widthAt(index)) / 2f,
            cap = StrokeCap.Round
        )
    }
}

@Composable
internal fun InkHistoryDialog(
    documents: List<InkDocument>,
    onOpen: (InkDocument) -> Unit,
    onAttach: (InkDocument) -> Unit,
    onRename: (UUID, String) -> Unit,
    onDelete: (UUID) -> Unit,
    onDismiss: () -> Unit
) {
    val colors = KakaoTheme.colors
    var renaming by remember { mutableStateOf<InkDocument?>(null) }
    Dialog(onDismissRequest = onDismiss) {
        Column(
            Modifier.widthIn(max = 520.dp).fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(colors.surface)
        ) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("필기 기록", style = KakaoText.roomTitle, color = colors.textPrimary, modifier = Modifier.weight(1f))
                Icon(Icons.Filled.Close, "닫기", tint = colors.textPrimary, modifier = Modifier.size(20.dp).clickable(onClick = onDismiss))
            }
            Hairline()
            if (documents.isEmpty()) {
                Box(Modifier.fillMaxWidth().padding(vertical = 48.dp), contentAlignment = Alignment.Center) {
                    Text("저장된 필기가 없어요.", style = KakaoText.body, color = colors.textSecondary)
                }
            } else {
                LazyColumn(Modifier.fillMaxWidth().height(380.dp)) {
                    items(documents, key = { it.id }) { item ->
                        Row(
                            Modifier.fillMaxWidth().clickable { onOpen(item) }.padding(horizontal = 16.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            InkPreview(item, Modifier.size(66.dp, 48.dp).clip(RoundedCornerShape(6.dp)).border(1.dp, colors.border, RoundedCornerShape(6.dp)))
                            Column(Modifier.weight(1f).padding(start = 12.dp)) {
                                Text(item.title, style = KakaoText.body, color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(SimpleDateFormat("M월 d일 a h:mm", Locale.KOREA).format(Date(item.updatedAtMillis)), style = KakaoText.caption, color = colors.textTertiary)
                            }
                            Icon(
                                Icons.AutoMirrored.Filled.Send,
                                "현재 채팅에 첨부",
                                tint = colors.textSecondary,
                                modifier = Modifier.size(18.dp).clickable { onAttach(item) }
                            )
                            Icon(Icons.Filled.Edit, "이름 변경", tint = colors.textSecondary, modifier = Modifier.size(18.dp).clickable { renaming = item })
                            Icon(Icons.Filled.DeleteSweep, "삭제", tint = colors.textSecondary, modifier = Modifier.padding(start = 16.dp).size(18.dp).clickable { onDelete(item.id) })
                        }
                    }
                }
            }
        }
    }
    renaming?.let { item ->
        var title by remember(item.id) { mutableStateOf(item.title) }
        AlertDialog(
            onDismissRequest = { renaming = null },
            title = { Text("필기 이름") },
            text = { BasicTextField(value = title, onValueChange = { title = it }, modifier = Modifier.fillMaxWidth()) },
            confirmButton = { Text("저장", modifier = Modifier.padding(16.dp).clickable { onRename(item.id, title); renaming = null }) },
            dismissButton = { Text("취소", modifier = Modifier.padding(16.dp).clickable { renaming = null }) }
        )
    }
}

@Composable
private fun InkPreview(document: InkDocument, modifier: Modifier = Modifier) {
    Canvas(modifier.background(Color.White)) {
        document.strokes.forEach { drawStroke(it.points, it.colorArgb, it.baseWidth, it.eraser, Color.White) }
    }
}
