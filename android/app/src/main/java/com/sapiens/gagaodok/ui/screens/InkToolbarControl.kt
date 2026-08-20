package com.sapiens.gagaodok.ui.screens

internal enum class InkToolbarControl {
    NONE,
    PEN,
    ERASER;

    companion object {
        fun reduce(current: InkToolbarControl, event: InkToolbarEvent): InkToolbarControl = when (event) {
            InkToolbarEvent.OPEN_PEN -> PEN
            InkToolbarEvent.OPEN_ERASER -> ERASER
            InkToolbarEvent.ADJUSTMENT_FINISHED,
            InkToolbarEvent.CLOSE -> NONE
        }
    }
}

internal enum class InkToolbarEvent {
    OPEN_PEN,
    OPEN_ERASER,
    ADJUSTMENT_FINISHED,
    CLOSE
}
