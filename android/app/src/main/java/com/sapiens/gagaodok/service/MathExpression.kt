package com.sapiens.gagaodok.service

import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.asin
import kotlin.math.atan
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.cosh
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.pow
import kotlin.math.roundToLong
import kotlin.math.sin
import kotlin.math.sinh
import kotlin.math.sqrt
import kotlin.math.tan
import kotlin.math.tanh

/// 그래프용 수식 파서.
///
/// 예전 평가기는 문자열에 `sin(x)`가 들어 있는지 훑어보는 방식이라
/// `2*sin(x)`의 계수를 무시했고, 무엇보다 **해석하지 못한 식을 `y = x`로 그렸습니다.**
/// 수학 학습 앱에서 조용히 틀린 그래프를 내보내는 건 안 그리느니만 못하므로,
/// 이제는 제대로 파싱하고 실패하면 null을 돌려줍니다.
class MathExpression private constructor(private val root: Node) {

    /// 변수 값을 넣어 계산합니다. 정의역을 벗어나면(예: `ln(-1)`) null입니다.
    fun value(variables: Map<String, Double>): Double? {
        val result = root.evaluate(variables) ?: return null
        return if (result.isFinite()) result else null
    }

    // MARK: - 구문 트리

    private sealed interface Node {
        fun evaluate(variables: Map<String, Double>): Double?

        data class Num(val value: Double) : Node {
            override fun evaluate(variables: Map<String, Double>) = value
        }

        data class Variable(val name: String) : Node {
            override fun evaluate(variables: Map<String, Double>) = variables[name]
        }

        data class Unary(val op: Char, val operand: Node) : Node {
            override fun evaluate(variables: Map<String, Double>): Double? {
                val value = operand.evaluate(variables) ?: return null
                return if (op == '-') -value else value
            }
        }

        data class Binary(val op: Char, val lhs: Node, val rhs: Node) : Node {
            override fun evaluate(variables: Map<String, Double>): Double? {
                val left = lhs.evaluate(variables) ?: return null
                val right = rhs.evaluate(variables) ?: return null
                return when (op) {
                    '+' -> left + right
                    '-' -> left - right
                    '*' -> left * right
                    '/' -> if (right == 0.0) null else left / right
                    '^' -> {
                        // 음수의 분수 거듭제곱은 실수 범위에서 정의되지 않습니다.
                        if (left < 0 && right != right.roundToLong().toDouble()) null
                        else left.pow(right)
                    }
                    else -> null
                }
            }
        }

        data class Call(val name: String, val argument: Node) : Node {
            override fun evaluate(variables: Map<String, Double>): Double? {
                val v = argument.evaluate(variables) ?: return null
                return when (name) {
                    "sin" -> sin(v)
                    "cos" -> cos(v)
                    "tan" -> tan(v)
                    "asin" -> if (abs(v) <= 1) asin(v) else null
                    "acos" -> if (abs(v) <= 1) acos(v) else null
                    "atan" -> atan(v)
                    "sinh" -> sinh(v)
                    "cosh" -> cosh(v)
                    "tanh" -> tanh(v)
                    "exp" -> exp(v)
                    "ln" -> if (v > 0) ln(v) else null
                    "log", "log10" -> if (v > 0) log10(v) else null
                    "sqrt" -> if (v >= 0) sqrt(v) else null
                    "abs" -> abs(v)
                    "floor" -> floor(v)
                    "ceil" -> ceil(v)
                    else -> null
                }
            }
        }
    }

    // MARK: - 파서

    private class Parser(source: String) {
        private val characters: List<Char> =
            source.replace(" ", "").lowercase().toList()
        private var index = 0

        val isAtEnd: Boolean get() = index >= characters.size

        private fun peek(): Char? = characters.getOrNull(index)

        private fun match(character: Char): Boolean {
            if (peek() != character) return false
            index += 1
            return true
        }

        fun parseExpression(): Node? {
            var node = parseTerm() ?: return null
            while (true) {
                val op = peek() ?: break
                if (op != '+' && op != '-') break
                index += 1
                val rhs = parseTerm() ?: return null
                node = Node.Binary(op, node, rhs)
            }
            return node
        }

        private fun parseTerm(): Node? {
            var node = parseUnary() ?: return null
            while (true) {
                val op = peek()
                if (op != null && (op == '*' || op == '/')) {
                    index += 1
                    val rhs = parseUnary() ?: return null
                    node = Node.Binary(op, node, rhs)
                } else if (startsImplicitMultiplication()) {
                    // 2x, 3sin(x), 2(x+1) 처럼 곱셈 기호를 생략한 표기를 받아줍니다.
                    val rhs = parseUnary() ?: return null
                    node = Node.Binary('*', node, rhs)
                } else {
                    return node
                }
            }
        }

        private fun startsImplicitMultiplication(): Boolean {
            val next = peek() ?: return false
            return next.isLetter() || next == '(' || next == 'π'
        }

        // 단항 마이너스는 거듭제곱보다 느슨하게 묶입니다: -x^2 는 -(x^2) 입니다.
        private fun parseUnary(): Node? {
            if (match('-')) {
                val operand = parseUnary() ?: return null
                return Node.Unary('-', operand)
            }
            if (match('+')) return parseUnary()
            return parsePower()
        }

        private fun parsePower(): Node? {
            val base = parsePrimary() ?: return null
            if (match('^')) {
                // 오른쪽 결합이고, 지수에도 부호가 올 수 있습니다: 2^3^2, x^-2
                val exponent = parseUnary() ?: return null
                return Node.Binary('^', base, exponent)
            }
            return base
        }

        private fun parsePrimary(): Node? {
            val character = peek() ?: return null

            if (match('(')) {
                val inner = parseExpression() ?: return null
                if (!match(')')) return null
                return inner
            }

            if (character.isDigit() || character == '.') {
                val literal = StringBuilder()
                while (true) {
                    val next = peek() ?: break
                    if (!next.isDigit() && next != '.') break
                    literal.append(next)
                    index += 1
                }
                val value = literal.toString().toDoubleOrNull() ?: return null
                return Node.Num(value)
            }

            if (character.isLetter() || character == 'π') {
                val name = StringBuilder()
                while (true) {
                    val next = peek() ?: break
                    if (!next.isLetter() && next != 'π') break
                    name.append(next)
                    index += 1
                }
                val text = name.toString()

                if (text in FUNCTIONS) {
                    if (!match('(')) return null
                    val argument = parseExpression() ?: return null
                    if (!match(')')) return null
                    return Node.Call(text, argument)
                }
                CONSTANTS[text]?.let { return Node.Num(it) }
                // 한 글자짜리는 변수로 봅니다. 여러 글자면 모르는 이름이므로 실패시킵니다.
                if (text.length != 1) return null
                return Node.Variable(text)
            }

            return null
        }

        companion object {
            private val FUNCTIONS = setOf(
                "sin", "cos", "tan", "asin", "acos", "atan",
                "sinh", "cosh", "tanh", "exp", "ln", "log", "log10",
                "sqrt", "abs", "floor", "ceil"
            )
            private val CONSTANTS = mapOf(
                "pi" to Math.PI, "π" to Math.PI, "e" to Math.E
            )
        }
    }

    companion object {
        /// 해석에 실패하면 null입니다. 틀린 그래프를 그리느니 아무것도 그리지 않습니다.
        fun parse(source: String): MathExpression? {
            val parser = Parser(source)
            val node = parser.parseExpression() ?: return null
            if (!parser.isAtEnd) return null
            return MathExpression(node)
        }
    }
}
