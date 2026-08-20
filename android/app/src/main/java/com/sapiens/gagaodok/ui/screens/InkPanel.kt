package com.sapiens.gagaodok.ui.screens

import android.graphics.Color as AndroidColor
import android.view.MotionEvent
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsDraggedAsState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
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
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.pointerInteropFilter
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.sapiens.gagaodok.model.InkDocument
import com.sapiens.gagaodok.model.InkPoint
import com.sapiens.gagaodok.service.InkGestureIntent
import com.sapiens.gagaodok.service.InkGestureRouter
import com.sapiens.gagaodok.service.InkInputMode
import com.sapiens.gagaodok.service.InkPoint2D
import com.sapiens.gagaodok.service.InkViewportTransform
import com.sapiens.gagaodok.ui.components.Hairline
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import kotlin.math.hypot

@Composable
internal fun InkFloatingPanel(
    document: InkDocument,
    onDocumentChanged: (InkDocument) -> Unit,
    onAttachToChat: (InkDocument) -> Unit,
    onClose: () -> Unit
) {
    val density = LocalDensity.current.density
    val session = remember(document.id) { InkCanvasState(document) }
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
        var color by remember(document.id) { mutableStateOf(Color(0xFF191919)) }
        var customColorValue by rememberSaveable(document.id) {
            mutableLongStateOf(Color(0xFF7757D6).value.toLong())
        }
        var eraser by rememberSaveable(document.id) { mutableStateOf(false) }
        var penWidth by rememberSaveable(document.id) { mutableFloatStateOf(4.5f) }
        var eraserWidth by rememberSaveable(document.id) { mutableFloatStateOf(18f) }
        var toolbarControl by rememberSaveable(document.id) { mutableStateOf(InkToolbarControl.NONE) }
        var colorPickerVisible by remember(document.id) { mutableStateOf(false) }

        fun dispatchToolbar(event: InkToolbarEvent) {
            toolbarControl = InkToolbarControl.reduce(toolbarControl, event)
        }

        fun currentBounds() = InkPanelBounds(offsetX, offsetY, panelWidth, panelHeight)
        fun applyBounds(next: InkPanelBounds) {
            offsetX = next.x
            offsetY = next.y
            panelWidth = next.width
            panelHeight = next.height
        }

        LaunchedEffect(maximumWidth, maximumHeight) {
            applyBounds(
                currentBounds().constrained(
                    availableWidth,
                    availableHeight,
                    minOf(minWidth.value, maximumWidth.value),
                    minOf(minHeight.value, maximumHeight.value)
                )
            )
        }

        val panelShape = RoundedCornerShape(16.dp)
        Box(
            Modifier
                .offset(x = offsetX.dp, y = offsetY.dp)
                .width(panelWidth.dp)
                .height(panelHeight.dp)
                .background(InkPaper, panelShape)
                .border(1.dp, InkBorder, panelShape)
                .clip(panelShape)
                .align(Alignment.TopStart)
        ) {
            Column(Modifier.fillMaxSize()) {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .height(52.dp)
                        .background(InkPaper),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Box(
                        Modifier
                            .weight(1f)
                            .fillMaxSize()
                            .pointerInput(density, availableWidth, availableHeight) {
                                detectDragGestures { change, drag ->
                                    change.consume()
                                    applyBounds(currentBounds().movedBy(
                                        drag.x / density,
                                        drag.y / density,
                                        availableWidth,
                                        availableHeight
                                    ))
                                }
                            }
                            .padding(start = 18.dp),
                        contentAlignment = Alignment.CenterStart
                    ) {
                        Text(
                            document.title,
                            style = KakaoText.body,
                            color = InkText,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    InkIconButton(
                        label = "채팅에 첨부",
                        enabled = session.document.strokes.isNotEmpty(),
                        onClick = { onAttachToChat(session.document) }
                    ) {
                        Icon(
                            Icons.AutoMirrored.Filled.Send,
                            "채팅에 첨부",
                            tint = if (session.document.strokes.isNotEmpty()) InkText else InkMuted,
                            modifier = Modifier.size(20.dp)
                        )
                    }
                    Box(Modifier.size(42.dp).clickable(onClick = onClose), contentAlignment = Alignment.Center) {
                        Icon(Icons.Filled.Close, "필기 닫기", tint = InkText, modifier = Modifier.size(20.dp))
                    }
                    // 오른쪽 위 모서리의 넓은 리사이즈 영역과 닫기 버튼이 겹치지 않게 둡니다.
                    Spacer(Modifier.width(44.dp))
                }
                Hairline(color = InkDivider)

                InkToolbar(
                    penColor = color,
                    customColor = Color(customColorValue.toULong()),
                    eraser = eraser,
                    penWidth = penWidth,
                    eraserWidth = eraserWidth,
                    expandedControl = toolbarControl,
                    onControlEvent = ::dispatchToolbar,
                    canUndo = session.canUndo,
                    canRedo = session.canRedo,
                    onChooseColor = { color = it; eraser = false },
                    onOpenColorPicker = { colorPickerVisible = true },
                    onToggleEraser = { eraser = !eraser },
                    onWidthChange = { penWidth = it },
                    onEraserWidthChange = { eraserWidth = it },
                    onUndo = { if (session.undo()) onDocumentChanged(session.document) },
                    onRedo = { if (session.redo()) onDocumentChanged(session.document) },
                    onClear = { if (session.clear()) onDocumentChanged(session.document) }
                )
                Hairline(color = InkDivider)
                InkWritingSurface(
                    session = session,
                    color = color,
                    penWidth = penWidth,
                    eraserWidth = eraserWidth,
                    eraser = eraser,
                    modifier = Modifier.weight(1f),
                    onInteractionStarted = { dispatchToolbar(InkToolbarEvent.CLOSE) },
                    onStrokeFinished = { onDocumentChanged(session.document) }
                )
            }

            InkResizeCorner.entries.forEach { corner ->
                InkResizeHandle(corner, density) { dx, dy ->
                    applyBounds(
                        currentBounds().resized(
                            corner,
                            dx,
                            dy,
                            availableWidth,
                            availableHeight,
                            minOf(minWidth.value, maximumWidth.value),
                            minOf(minHeight.value, maximumHeight.value)
                        )
                    )
                }
            }
        }

        if (colorPickerVisible) {
            InkColorPicker(
                initial = Color(customColorValue.toULong()),
                onDismiss = { colorPickerVisible = false },
                onRegister = {
                    customColorValue = it.value.toLong()
                    color = it
                    eraser = false
                    colorPickerVisible = false
                }
            )
        }
    }
}

@Composable
private fun BoxScope.InkResizeHandle(
    corner: InkResizeCorner,
    density: Float,
    onResize: (Float, Float) -> Unit
) {
    val currentResize by rememberUpdatedState(onResize)
    val alignment = when (corner) {
        InkResizeCorner.TOP_LEFT -> Alignment.TopStart
        InkResizeCorner.TOP_RIGHT -> Alignment.TopEnd
        InkResizeCorner.BOTTOM_LEFT -> Alignment.BottomStart
        InkResizeCorner.BOTTOM_RIGHT -> Alignment.BottomEnd
    }
    Box(
        Modifier
            .align(alignment)
            .size(44.dp)
            .pointerInput(corner, density) {
                detectDragGestures { change, drag ->
                    change.consume()
                    currentResize(drag.x / density, drag.y / density)
                }
            }
    )
}

@Composable
private fun InkToolbar(
    penColor: Color,
    customColor: Color,
    eraser: Boolean,
    penWidth: Float,
    eraserWidth: Float,
    expandedControl: InkToolbarControl,
    onControlEvent: (InkToolbarEvent) -> Unit,
    canUndo: Boolean,
    canRedo: Boolean,
    onChooseColor: (Color) -> Unit,
    onOpenColorPicker: () -> Unit,
    onToggleEraser: () -> Unit,
    onWidthChange: (Float) -> Unit,
    onEraserWidthChange: (Float) -> Unit,
    onUndo: () -> Unit,
    onRedo: () -> Unit,
    onClear: () -> Unit
) {
    val palette = listOf(Color(0xFF191919), Color(0xFF2E6BF6), Color(0xFFE54343), customColor)
    Column(Modifier.fillMaxWidth().background(InkPaper)) {
        Row(
            Modifier
                .fillMaxWidth()
                .height(48.dp)
                .horizontalScroll(rememberScrollState())
                .padding(horizontal = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(2.dp)
        ) {
            palette.forEach { swatch ->
                InkColorSwatch(
                    color = swatch,
                    selected = !eraser && swatch.value == penColor.value,
                    onClick = { onControlEvent(InkToolbarEvent.CLOSE); onChooseColor(swatch) }
                )
            }
            InkIconButton("사용자 색상 등록", onClick = { onControlEvent(InkToolbarEvent.CLOSE); onOpenColorPicker() }) {
                Icon(Icons.Filled.Palette, "사용자 색상 등록", tint = InkSecondary, modifier = Modifier.size(20.dp))
            }
            InkThicknessControl(
                penColor = penColor,
                eraser = eraser,
                penWidth = penWidth,
                expanded = expandedControl == InkToolbarControl.PEN,
                onExpand = { onControlEvent(InkToolbarEvent.OPEN_PEN) },
                onCollapse = { onControlEvent(InkToolbarEvent.ADJUSTMENT_FINISHED) },
                onWidthChange = onWidthChange
            )
            Spacer(Modifier.width(6.dp))
            Box(Modifier.width(1.dp).height(22.dp).background(InkDivider))
            Spacer(Modifier.width(4.dp))
            EraserMorphControl(
                selected = eraser,
                expanded = expandedControl == InkToolbarControl.ERASER,
                eraserWidth = eraserWidth,
                onClick = { onControlEvent(InkToolbarEvent.CLOSE); onToggleEraser() },
                onLongClick = { onControlEvent(InkToolbarEvent.OPEN_ERASER) },
                onWidthChange = onEraserWidthChange,
                onAdjustmentFinished = { onControlEvent(InkToolbarEvent.ADJUSTMENT_FINISHED) },
                onClear = { onControlEvent(InkToolbarEvent.CLOSE); onClear() }
            )
            InkIconButton("되돌리기", enabled = canUndo, onClick = { onControlEvent(InkToolbarEvent.CLOSE); onUndo() }) {
                Icon(Icons.AutoMirrored.Filled.Undo, "되돌리기", tint = if (canUndo) InkText else InkMuted, modifier = Modifier.size(20.dp))
            }
            InkIconButton("다시 실행", enabled = canRedo, onClick = { onControlEvent(InkToolbarEvent.CLOSE); onRedo() }) {
                Icon(Icons.AutoMirrored.Filled.Redo, "다시 실행", tint = if (canRedo) InkText else InkMuted, modifier = Modifier.size(20.dp))
            }
        }
    }
}

@Composable
private fun InkThicknessControl(
    penColor: Color,
    eraser: Boolean,
    penWidth: Float,
    expanded: Boolean,
    onExpand: () -> Unit,
    onCollapse: () -> Unit,
    onWidthChange: (Float) -> Unit
) {
    val animatedWidth by animateDpAsState(
        targetValue = if (expanded) 224.dp else 38.dp,
        animationSpec = spring(dampingRatio = 0.54f, stiffness = 430f),
        label = "필기 굵기 조절 너비"
    )
    Box(
        Modifier
            .width(animatedWidth)
            .height(38.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(if (expanded) Color(0xFFF3F4F6) else Color.Transparent)
            .border(if (expanded) 1.dp else 0.dp, InkBorder, RoundedCornerShape(10.dp)),
        contentAlignment = Alignment.CenterStart
    ) {
        Crossfade(targetState = expanded, animationSpec = tween(120), label = "필기 굵기 조절 내용") { isExpanded ->
            if (!isExpanded) {
                Box(
                    Modifier.fillMaxSize().clickable(onClick = onExpand),
                    contentAlignment = Alignment.Center
                ) {
                    ThicknessGlyph(penWidth, if (eraser) InkSecondary else penColor)
                }
            } else {
                Row(
                    Modifier.fillMaxSize().padding(start = 5.dp, end = 7.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Box(
                        Modifier.size(30.dp).clip(CircleShape).clickable(onClick = onCollapse),
                        contentAlignment = Alignment.Center
                    ) {
                        ThicknessGlyph(penWidth, if (eraser) InkSecondary else penColor)
                    }
                    ElasticThicknessSlider(
                        value = penWidth,
                        onValueChange = onWidthChange,
                        onValueChangeFinished = onCollapse,
                        valueRange = 1.5f..14f,
                        modifier = Modifier.weight(1f)
                    )
                }
            }
        }
    }
}

@Composable
private fun EraserMorphControl(
    selected: Boolean,
    expanded: Boolean,
    eraserWidth: Float,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    onWidthChange: (Float) -> Unit,
    onAdjustmentFinished: () -> Unit,
    onClear: () -> Unit
) {
    val animatedWidth by animateDpAsState(
        targetValue = if (expanded) 286.dp else 38.dp,
        animationSpec = spring(dampingRatio = 0.5f, stiffness = 390f),
        label = "지우개 설정 탄성 너비"
    )
    val animatedCorner by animateDpAsState(
        targetValue = if (expanded) 19.dp else 10.dp,
        animationSpec = spring(dampingRatio = 0.55f, stiffness = 460f),
        label = "지우개 설정 모서리"
    )
    val shape = RoundedCornerShape(animatedCorner)
    Box(
        Modifier
            .width(animatedWidth)
            .height(38.dp)
            .clip(shape)
            .background(if (expanded) Color(0xFFF3F4F6) else if (selected) InkSelected else Color.Transparent)
            .border(if (expanded) 1.dp else 0.dp, InkBorder, shape),
        contentAlignment = Alignment.CenterStart
    ) {
        Crossfade(targetState = expanded, animationSpec = tween(110), label = "지우개 설정 내용") { isExpanded ->
            if (!isExpanded) {
                Box(
                    Modifier
                        .fillMaxSize()
                        .combinedClickable(
                            onClickLabel = "지우개",
                            onLongClickLabel = "지우개 굵기 설정",
                            onLongClick = onLongClick,
                            onClick = onClick
                        ),
                    contentAlignment = Alignment.Center
                ) {
                    EraserGlyph(if (selected) InkText else InkSecondary)
                }
            } else {
                Row(
                    Modifier.fillMaxSize().padding(horizontal = 4.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Box(
                        Modifier.size(30.dp).clip(CircleShape).clickable(onClick = onAdjustmentFinished),
                        contentAlignment = Alignment.Center
                    ) {
                        EraserGlyph(InkText)
                    }
                    ElasticThicknessSlider(
                        value = eraserWidth,
                        onValueChange = onWidthChange,
                        onValueChangeFinished = onAdjustmentFinished,
                        valueRange = 6f..48f,
                        modifier = Modifier.weight(1f)
                    )
                    Box(
                        Modifier.size(34.dp).clip(CircleShape).clickable(onClick = onClear),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            Icons.Filled.DeleteSweep,
                            "전체 지우기",
                            tint = Color(0xFFE54848),
                            modifier = Modifier.size(18.dp)
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ElasticThicknessSlider(
    value: Float,
    onValueChange: (Float) -> Unit,
    onValueChangeFinished: () -> Unit,
    valueRange: ClosedFloatingPointRange<Float>,
    modifier: Modifier = Modifier
) {
    val interactionSource = remember { MutableInteractionSource() }
    val dragged by interactionSource.collectIsDraggedAsState()
    val morphProgress by animateFloatAsState(
        targetValue = if (dragged) 1f else 0f,
        animationSpec = spring(dampingRatio = 0.42f, stiffness = 560f),
        label = "굵기 슬라이더 탄성 변형"
    )
    val valueScale by animateFloatAsState(
        targetValue = if (dragged) 1.1f else 1f,
        animationSpec = spring(dampingRatio = 0.48f, stiffness = 720f),
        label = "굵기 수치 탄성"
    )

    Row(modifier.height(38.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.weight(1f).fillMaxHeight()) {
            Slider(
                value = value,
                onValueChange = onValueChange,
                onValueChangeFinished = onValueChangeFinished,
                valueRange = valueRange,
                interactionSource = interactionSource,
                colors = SliderDefaults.colors(
                    thumbColor = Color.Transparent,
                    activeTrackColor = InkText,
                    inactiveTrackColor = InkDivider
                ),
                modifier = Modifier.fillMaxSize()
            )
            Canvas(Modifier.fillMaxSize()) {
                val span = valueRange.endInclusive - valueRange.start
                val progress = if (span == 0f) 0f else ((value - valueRange.start) / span).coerceIn(0f, 1f)
                val edgeInset = 10.dp.toPx()
                val center = Offset(edgeInset + (size.width - edgeInset * 2f) * progress, size.height / 2f)
                val morph = morphProgress.coerceIn(-0.25f, 1.15f)
                val thumbWidth = (20f + morph * 12f).dp.toPx()
                val thumbHeight = (20f - morph * 4f).dp.toPx()
                drawRoundRect(
                    color = InkText,
                    topLeft = Offset(center.x - thumbWidth / 2f, center.y - thumbHeight / 2f),
                    size = androidx.compose.ui.geometry.Size(thumbWidth, thumbHeight),
                    cornerRadius = CornerRadius(thumbHeight / 2f, thumbHeight / 2f)
                )
            }
        }
        Text(
            String.format(Locale.US, "%.1f", value),
            style = KakaoText.caption,
            color = InkSecondary,
            modifier = Modifier.width(34.dp).scale(valueScale)
        )
    }
}

@Composable
private fun ThicknessGlyph(width: Float, color: Color) {
    Canvas(Modifier.size(21.dp)) {
        drawLine(
            color = color,
            start = Offset(2.dp.toPx(), center.y),
            end = Offset(size.width - 2.dp.toPx(), center.y),
            strokeWidth = width.coerceIn(1.5f, 7f) * density * 0.58f,
            cap = StrokeCap.Round
        )
    }
}

@Composable
private fun InkColorSwatch(color: Color, selected: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(34.dp).clip(CircleShape).clickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Box(
            Modifier
                .size(19.dp)
                .background(color, CircleShape)
                .border(if (selected) 3.dp else 1.dp, if (selected) InkAccent else InkBorder, CircleShape)
        )
    }
}

@Composable
private fun EraserGlyph(color: Color) {
    Canvas(Modifier.size(21.dp)) {
        rotate(-38f, pivot = center) {
            drawRoundRect(
                color = color,
                topLeft = Offset(size.width * 0.27f, size.height * 0.10f),
                size = androidx.compose.ui.geometry.Size(size.width * 0.46f, size.height * 0.80f),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(2.dp.toPx()),
                style = Stroke(width = 2.dp.toPx())
            )
            drawLine(
                color,
                Offset(size.width * 0.27f, size.height * 0.59f),
                Offset(size.width * 0.73f, size.height * 0.59f),
                2.dp.toPx()
            )
        }
    }
}

@Composable
private fun InkColorPicker(initial: Color, onDismiss: () -> Unit, onRegister: (Color) -> Unit) {
    val initialHsv = remember(initial.value) {
        FloatArray(3).also { AndroidColor.colorToHSV(initial.toArgb(), it) }
    }
    var hue by remember(initial.value) { mutableFloatStateOf(initialHsv[0]) }
    var saturation by remember(initial.value) { mutableFloatStateOf(initialHsv[1]) }
    var brightness by remember(initial.value) { mutableFloatStateOf(initialHsv[2]) }
    val selected = Color(AndroidColor.HSVToColor(floatArrayOf(hue, saturation, brightness)))

    Dialog(onDismissRequest = onDismiss) {
        Column(
            Modifier
                .widthIn(max = 410.dp)
                .fillMaxWidth()
                .clip(RoundedCornerShape(18.dp))
                .background(InkPaper)
                .padding(20.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("사용자 색상", style = KakaoText.roomTitle, color = InkText, modifier = Modifier.weight(1f))
                Box(Modifier.size(34.dp).background(selected, CircleShape).border(1.dp, InkBorder, CircleShape))
            }
            Spacer(Modifier.height(18.dp))
            ColorPickerSlider(
                label = "색상",
                value = hue,
                range = 0f..360f,
                brush = Brush.horizontalGradient(
                    listOf(Color.Red, Color.Yellow, Color.Green, Color.Cyan, Color.Blue, Color.Magenta, Color.Red)
                ),
                thumbColor = selected,
                onValueChange = { hue = it }
            )
            ColorPickerSlider(
                label = "채도",
                value = saturation,
                range = 0f..1f,
                brush = Brush.horizontalGradient(
                    listOf(
                        Color(AndroidColor.HSVToColor(floatArrayOf(hue, 0f, brightness))),
                        Color(AndroidColor.HSVToColor(floatArrayOf(hue, 1f, brightness)))
                    )
                ),
                thumbColor = selected,
                onValueChange = { saturation = it }
            )
            ColorPickerSlider(
                label = "밝기",
                value = brightness,
                range = 0f..1f,
                brush = Brush.horizontalGradient(
                    listOf(Color.Black, Color(AndroidColor.HSVToColor(floatArrayOf(hue, saturation, 1f))))
                ),
                thumbColor = selected,
                onValueChange = { brightness = it }
            )
            Spacer(Modifier.height(14.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                Text(
                    "취소",
                    style = KakaoText.body,
                    color = InkSecondary,
                    modifier = Modifier.clip(RoundedCornerShape(10.dp)).clickable(onClick = onDismiss).padding(horizontal = 18.dp, vertical = 10.dp)
                )
                Text(
                    "등록",
                    style = KakaoText.body,
                    color = InkText,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier
                        .padding(start = 6.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .background(InkAccent)
                        .clickable { onRegister(selected) }
                        .padding(horizontal = 18.dp, vertical = 10.dp)
                )
            }
        }
    }
}

@Composable
private fun ColorPickerSlider(
    label: String,
    value: Float,
    range: ClosedFloatingPointRange<Float>,
    brush: Brush,
    thumbColor: Color,
    onValueChange: (Float) -> Unit
) {
    Text(label, style = KakaoText.caption, color = InkSecondary)
    Box(Modifier.fillMaxWidth().height(42.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize().padding(horizontal = 10.dp, vertical = 17.dp)) {
            drawRoundRect(brush = brush, cornerRadius = androidx.compose.ui.geometry.CornerRadius(size.height / 2f))
        }
        Slider(
            value = value,
            onValueChange = onValueChange,
            valueRange = range,
            colors = SliderDefaults.colors(
                thumbColor = thumbColor,
                activeTrackColor = Color.Transparent,
                inactiveTrackColor = Color.Transparent
            )
        )
    }
}

@Composable
private fun InkIconButton(
    label: String,
    enabled: Boolean = true,
    selected: Boolean = false,
    onClick: () -> Unit = {},
    onLongClick: (() -> Unit)? = null,
    content: @Composable () -> Unit
) {
    Box(
        Modifier
            .size(38.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(if (selected) InkSelected else Color.Transparent)
            .combinedClickable(
                enabled = enabled,
                onClickLabel = label,
                onLongClickLabel = if (onLongClick != null) "지우개 설정" else null,
                onLongClick = onLongClick,
                onClick = onClick
            ),
        contentAlignment = Alignment.Center
    ) { content() }
}

private val InkPaper = Color.White
private val InkText = Color(0xFF191919)
private val InkSecondary = Color(0xFF69707A)
private val InkMuted = Color(0xFFB7BBC1)
private val InkBorder = Color(0xFFD9DDE3)
private val InkDivider = Color(0xFFE9EBEF)
private val InkAccent = Color(0xFFFEE500)
private val InkSelected = Color(0xFFFFF4A8)

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun InkWritingSurface(
    session: InkCanvasState,
    color: Color,
    penWidth: Float,
    eraserWidth: Float,
    eraser: Boolean,
    modifier: Modifier = Modifier,
    onInteractionStarted: () -> Unit,
    onStrokeFinished: () -> Unit
) {
    var surfaceSize by remember { mutableStateOf(IntSize.Zero) }
    var activeStylusPointerId by remember { mutableStateOf(MotionEvent.INVALID_POINTER_ID) }
    var lastTouchCentroid by remember { mutableStateOf<InkPoint2D?>(null) }
    var lastTouchSpan by remember { mutableFloatStateOf(0f) }
    // revision을 읽어야 ArrayList의 새 포인트가 한 프레임 안에 Canvas에 반영됩니다.
    val revision = session.activeRevision
    val sizePoint = InkPoint2D(surfaceSize.width.toFloat(), surfaceSize.height.toFloat())
    Canvas(
        modifier
            .fillMaxWidth()
            .background(InkPaper)
            .onSizeChanged {
                surfaceSize = it
                session.onViewportSizeChanged(it.width.toFloat(), it.height.toFloat())
            }
            .pointerInteropFilter { event ->
                if (surfaceSize == IntSize.Zero) return@pointerInteropFilter true
                val tools = IntArray(event.pointerCount) { event.getToolType(it) }
                when (InkGestureRouter.classify(event.actionMasked, tools, event.pointerCount)) {
                    InkGestureIntent.HOVER -> {
                        val index = event.actionIndex.coerceIn(0, event.pointerCount - 1)
                        val hoveringEraser = InkInputMode.shouldErase(
                            event.getToolType(index),
                            event.buttonState,
                            eraser
                        )
                        if (event.actionMasked == MotionEvent.ACTION_HOVER_EXIT || !hoveringEraser) {
                            session.clearHover()
                        } else {
                            session.updateHover(event.getX(index), event.getY(index), eraserWidth, sizePoint)
                        }
                    }
                    InkGestureIntent.STROKE -> when (event.actionMasked) {
                        MotionEvent.ACTION_DOWN -> {
                            onInteractionStarted()
                            activeStylusPointerId = event.getPointerId(0)
                            val style = InkInputMode.resolveStrokeStyle(
                                event.getToolType(0), event.buttonState, eraser,
                                color.value.toLong(), penWidth, eraserWidth
                            )
                            session.updateToolbarStyle(style)
                            session.beginStroke(style)
                            session.appendScreenPoint(event.x, event.y, event.pressure, sizePoint, event.eventTime)
                        }
                        MotionEvent.ACTION_MOVE -> {
                            val index = event.findPointerIndex(activeStylusPointerId)
                            if (index >= 0) {
                                for (historyIndex in 0 until event.historySize) {
                                    session.appendScreenPoint(
                                        event.getHistoricalX(index, historyIndex),
                                        event.getHistoricalY(index, historyIndex),
                                        event.getHistoricalPressure(index, historyIndex),
                                        sizePoint,
                                        event.getHistoricalEventTime(historyIndex)
                                    )
                                }
                                session.appendScreenPoint(
                                    event.getX(index), event.getY(index), event.getPressure(index),
                                    sizePoint, event.eventTime
                                )
                            }
                        }
                        MotionEvent.ACTION_UP -> {
                            val index = event.findPointerIndex(activeStylusPointerId)
                            if (index >= 0) {
                                session.appendScreenPoint(
                                    event.getX(index), event.getY(index), event.getPressure(index),
                                    sizePoint, event.eventTime
                                )
                            }
                            activeStylusPointerId = MotionEvent.INVALID_POINTER_ID
                            if (session.finishStroke()) onStrokeFinished()
                        }
                        MotionEvent.ACTION_CANCEL -> {
                            activeStylusPointerId = MotionEvent.INVALID_POINTER_ID
                            session.cancelInteraction()
                        }
                    }
                    InkGestureIntent.PAN,
                    InkGestureIntent.PAN_ZOOM -> {
                        session.clearHover()
                        val centroid = event.touchCentroid()
                        val span = event.touchSpan(centroid)
                        when (event.actionMasked) {
                            MotionEvent.ACTION_DOWN,
                            MotionEvent.ACTION_POINTER_DOWN -> {
                                onInteractionStarted()
                                lastTouchCentroid = centroid
                                lastTouchSpan = span
                            }
                            MotionEvent.ACTION_MOVE -> {
                                lastTouchCentroid?.let { previous ->
                                    session.panBy(centroid.x - previous.x, centroid.y - previous.y)
                                }
                                if (event.pointerCount >= 2 && lastTouchSpan > 0f && span > 0f) {
                                    session.zoomAt(span / lastTouchSpan, centroid, sizePoint)
                                }
                                lastTouchCentroid = centroid
                                lastTouchSpan = span
                            }
                            MotionEvent.ACTION_UP,
                            MotionEvent.ACTION_POINTER_UP -> {
                                lastTouchCentroid = null
                                lastTouchSpan = 0f
                                onStrokeFinished()
                            }
                            MotionEvent.ACTION_CANCEL -> {
                                lastTouchCentroid = null
                                lastTouchSpan = 0f
                                session.cancelInteraction()
                            }
                        }
                    }
                    InkGestureIntent.IGNORE -> if (event.actionMasked == MotionEvent.ACTION_CANCEL) {
                        session.cancelInteraction()
                    }
                }
                true
            }
    ) {
        revision
        val viewport = session.document.viewport
        session.document.strokes.forEach {
            drawWorldStroke(it.points, it.colorArgb, it.baseWidth, it.eraser, InkPaper, viewport)
        }
        if (session.active.isNotEmpty()) {
            val style = session.activeStyle
            drawWorldStroke(session.active, style.colorArgb, style.width, style.eraser, InkPaper, viewport)
        }
        session.hover?.let { hover ->
            val center = InkViewportTransform.worldToScreen(
                InkPoint2D(hover.worldX, hover.worldY),
                viewport,
                InkPoint2D(size.width, size.height)
            )
            val radius = session.hoverScreenDiameter / 2f
            drawCircle(Color(0x1A31343A), radius, Offset(center.x, center.y))
            drawCircle(
                color = Color(0x9931343A),
                radius = radius,
                center = Offset(center.x, center.y),
                style = Stroke(width = 1.2.dp.toPx())
            )
        }
    }
}

private fun MotionEvent.touchCentroid(): InkPoint2D {
    var x = 0f
    var y = 0f
    for (index in 0 until pointerCount) {
        x += getX(index)
        y += getY(index)
    }
    return InkPoint2D(x / pointerCount.coerceAtLeast(1), y / pointerCount.coerceAtLeast(1))
}

private fun MotionEvent.touchSpan(centroid: InkPoint2D): Float {
    if (pointerCount < 2) return 0f
    var distance = 0f
    for (index in 0 until pointerCount) {
        distance += hypot((getX(index) - centroid.x).toDouble(), (getY(index) - centroid.y).toDouble()).toFloat()
    }
    return distance / pointerCount
}

private fun DrawScope.drawWorldStroke(
    points: List<InkPoint>,
    colorArgb: Long,
    baseWidth: Float,
    eraser: Boolean,
    background: Color,
    viewport: com.sapiens.gagaodok.model.InkViewport
) {
    if (points.isEmpty()) return
    val color = if (eraser) background else Color(colorArgb.toULong())
    val strokeWidth = (baseWidth * viewport.zoom).coerceAtLeast(0.5f)
    fun screen(point: InkPoint): Offset {
        val transformed = InkViewportTransform.worldToScreen(
            InkPoint2D(point.x, point.y),
            viewport,
            InkPoint2D(size.width, size.height)
        )
        return Offset(transformed.x, transformed.y)
    }
    if (points.size == 1) {
        drawCircle(color, radius = strokeWidth / 2f, center = screen(points.single()))
        return
    }
    val path = Path().apply {
        val first = screen(points.first())
        moveTo(first.x, first.y)
        if (points.size == 2) {
            val last = screen(points.last())
            lineTo(last.x, last.y)
        } else {
            for (index in 1 until points.lastIndex) {
                val current = screen(points[index])
                val next = screen(points[index + 1])
                quadraticTo(current.x, current.y, (current.x + next.x) / 2f, (current.y + next.y) / 2f)
            }
            val last = screen(points.last())
            lineTo(last.x, last.y)
        }
    }
    drawPath(path, color, style = Stroke(width = strokeWidth, cap = StrokeCap.Round, join = StrokeJoin.Round))
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
        document.strokes.forEach {
            drawWorldStroke(it.points, it.colorArgb, it.baseWidth, it.eraser, Color.White, document.viewport)
        }
    }
}
