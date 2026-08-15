package com.sapiens.gagaodok.service

/// 스트리밍으로 도착하는 글자를 모았다가, 말풍선 하나가 완성됐을 때만 내보냅니다.
///
/// 청크는 아무 데서나 끊깁니다. `$$\frac{1}` 까지만 온 상태에서 그리면 깨진 수식이 잠깐 보였다가
/// 고쳐지는 꼴이 됩니다. 그래서 글자 단위로 그리지 않고, **완성된 문단**만 내보냅니다.
///
/// 안전한 지점은 빈 줄(문단 경계)이면서 열어 둔 구분자가 하나도 없는 곳입니다.
/// 어차피 이 앱은 답변을 문단 단위 말풍선으로 쪼개 보여주므로, 문단이 완성되는 순간이
/// 곧 말풍선이 완성되는 순간입니다. 잃는 것 없이 깨진 화면만 피합니다.
class StreamingBubbleBuffer {
    private val pending = StringBuilder()

    /// 아직 내보내지 않고 쌓아 둔 글입니다.
    val buffered: String get() = pending.toString()

    /// 새로 도착한 조각을 넣고, 이번에 완성된 문단들을 돌려줍니다.
    fun append(chunk: String): List<String> {
        pending.append(chunk)
        val ready = mutableListOf<String>()
        while (true) {
            val cut = safeCutIndex(pending.toString()) ?: break
            val piece = pending.substring(0, cut).trim()
            pending.delete(0, cut)
            if (piece.isNotEmpty()) ready += piece
        }
        return ready
    }

    /// 스트림이 끝났을 때 남은 것을 모두 비웁니다. 여기서는 구분자가 안 닫혔어도 그대로 내보냅니다.
    /// 모델이 수식을 열어 놓고 끝낸 경우인데, 삼키는 것보다 보여주는 편이 낫습니다.
    fun flush(): String {
        val rest = pending.toString().trim()
        pending.setLength(0)
        return rest
    }

    companion object {
        /// 여기서 잘라도 되는 첫 지점을 찾습니다. 없으면 null입니다.
        fun safeCutIndex(text: String): Int? {
            var searchFrom = 0
            while (true) {
                val found = text.indexOf("\n\n", searchFrom)
                if (found < 0) return null
                if (isBalanced(text.substring(0, found))) return found + 2
                searchFrom = found + 2
            }
        }

        /// 이 글이 열어 둔 구분자 없이 끝나는지 봅니다.
        fun isBalanced(text: String): Boolean {
            var inFence = false          // ``` 코드 블록
            var inDisplayMath = false    // $$ 또는 \[
            var inlineMathOpen = false   // $ 하나
            var inGraphTag = false       // [GRAPH: ...]

            var i = 0
            val n = text.length
            while (i < n) {
                // 코드 블록 안에서는 수식 기호를 세지 않습니다.
                if (i + 2 < n && text[i] == '`' && text[i + 1] == '`' && text[i + 2] == '`') {
                    inFence = !inFence
                    i += 3
                    continue
                }
                if (inFence) { i += 1; continue }

                // 이스케이프된 달러는 수식이 아닙니다.
                if (text[i] == '\\' && i + 1 < n && text[i + 1] == '$') {
                    i += 2
                    continue
                }

                if (i + 1 < n && text[i] == '\\' && text[i + 1] == '[') {
                    inDisplayMath = true
                    i += 2
                    continue
                }
                if (i + 1 < n && text[i] == '\\' && text[i + 1] == ']') {
                    inDisplayMath = false
                    i += 2
                    continue
                }

                if (i + 1 < n && text[i] == '$' && text[i + 1] == '$') {
                    inDisplayMath = !inDisplayMath
                    // $$를 열고 닫을 때는 인라인 상태를 끌고 가지 않습니다.
                    inlineMathOpen = false
                    i += 2
                    continue
                }
                if (text[i] == '$') {
                    if (!inDisplayMath) inlineMathOpen = !inlineMathOpen
                    i += 1
                    continue
                }

                if (!inDisplayMath && !inGraphTag && text.startsWith("[GRAPH:", i)) {
                    inGraphTag = true
                    i += 1
                    continue
                }
                if (inGraphTag && text[i] == ']') {
                    inGraphTag = false
                    i += 1
                    continue
                }

                i += 1
            }
            return !inFence && !inDisplayMath && !inlineMathOpen && !inGraphTag
        }
    }
}
