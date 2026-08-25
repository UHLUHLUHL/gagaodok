package com.sapiens.gagaodok.ui.components

import android.graphics.RenderEffect
import android.graphics.RuntimeShader
import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.asComposeRenderEffect
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

/// 유리 뒤의 배경을 **흐리고, 가장자리에서 휘고, 빛나게** 만듭니다.
///
/// 안드로이드 13(API 33)부터 걸립니다. 그 아래에서는 예전 불투명 카드로 물러납니다.
///
/// ## 왜 그림을 두 번 그리는가
///
/// 앞 판은 셰이더 하나가 흐리기까지 다 했습니다. 표본을 40개 집어 평균 내는 방식이라
/// 반경을 넓힐수록 흐려지는 게 아니라 **얼룩덜룩해집니다.** 그래서 반경을 20dp(밀도
/// 3.75에서 75화소)까지밖에 못 올렸는데, 뒤에 있는 말풍선은 폭이 790화소입니다.
/// **자기보다 열 배 큰 도형은 75화소로 흐려도 네모로 남습니다.** 유리 너머에서 말풍선이
/// 말풍선인 채로 비치면 재질이 아니라 반투명 판으로 읽힙니다.
///
/// 지금은 배경을 한 번 기록해 두고 두 번 씁니다. 한 번은 그대로(선명한 대화), 한 번은
/// **안드로이드가 만들어 주는 진짜 가우시안 블러**를 걸어 유리 자리에만 덧그립니다.
/// 시스템 블러는 축소해서 흐리므로 40dp도 얼룩 없이 싸게 됩니다. 셰이더는 이제 흐리기를
/// 안 하고 굴절과 빛만 맡습니다. 화소마다 돌던 40번 반복이 통째로 사라져 더 빠릅니다.
///
/// 두 판은 **크기가 같고**, 유리 판은 **잘라내지 않고** 통째로 얹습니다. 모양은 셰이더가
/// 알파로 냅니다. 옮기지도 자르지도 않으니 좌표가 어긋날 자리가 없습니다.
/// 전면 블러 비용이 문제가 되면 그때 재서 줄입니다.
///
/// ## 카드 안의 네모 상자는 유리가 아니라 그림자였습니다
///
/// 오래 헤맨 결함이라 적어 둡니다. 카드 안쪽 **104화소** 자리에 1화소짜리 세로 이음매가
/// 좌우 대칭으로 섰고, 밝기 차는 22%였습니다. 블러 반경을 절반으로 줄여도, 셰이더를
/// 통째로 빼도, 클립을 빼도, 뒤 대화를 스크롤해도 **늘 같은 자리**였습니다.
///
/// 범인은 카드에 걸린 `Modifier.shadow`였습니다. 유리를 켜면 카드에 배경색이 없어서,
/// 안드로이드가 그 카드를 "속이 안 비치는 판"으로 못 보고 그림자를 **카드 밑으로도**
/// 그립니다. 가장자리에서 안으로 옅어지는 그 띠가 끝나는 자리에 경계가 섭니다.
///
/// 그래서 그림자는 여기서 따로 만듭니다 — 유리 밑에 카드 모양 판을 깔아 그림자만 받게
/// 하고, 유리가 그 판을 통째로 덮습니다. 바깥으로 번진 그림자만 남습니다.
///
/// ## 재질을 만드는 것은 굴절이지 반투명이 아니다
///
/// 앞 판은 읽기를 살리려고 배경의 명암을 34%까지 눌렀습니다. 그랬더니 글자는 읽혔지만
/// **휠 것이 없어졌습니다.** 평평한 바탕을 아무리 휘어도 아무 일도 안 일어납니다.
/// 리퀴드글래스가 아니라 그냥 반투명 카드로 보인 이유입니다.
///
/// 그래서 방향을 바꿨습니다. 배경은 넉넉히 살리고(55%), 대신 **흰 것이 유리 아래를 지날
/// 때만** 눌러 줍니다. 노란 내 말풍선이 카드 밑으로 지나가도 바닥이 들뜨지 않으면서,
/// 평소의 명암과 색은 그대로 남습니다.
private const val LIQUID_GLASS_SHADER = """
uniform shader contents;
uniform float2 resolution;
uniform float2 cardCenter;
uniform float2 cardHalfSize;
uniform float cornerRadius;
uniform float edgeBand;
uniform float refraction;
uniform float rimWidth;
uniform float4 tint;
uniform float backdrop;
uniform float desaturation;
uniform float highlightRolloff;

// 둥근 사각형까지의 거리입니다. 안쪽이 음수, 바깥이 양수입니다.
float sdRoundRect(float2 p, float2 halfSize, float r) {
    float2 d = abs(p) - halfSize + r;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

// 그 자리에서 면이 바깥을 보는 방향입니다. 거리장의 기울기를 차분으로 구합니다.
//
// **카드 중심에서 뻗는 방향으로 대신할 수 없습니다.** 336×154dp처럼 가로로 긴 카드에서는
// 둘이 크게 어긋나서, 왼쪽 가장자리가 옆이 아니라 비스듬히 끌립니다. 뒤에 있던 프로필
// 사진이 대각선 꼬리를 남기던 것이 그것이었습니다.
float2 surfaceNormal(float2 p, float2 halfSize, float r) {
    float e = 1.0;
    float dx = sdRoundRect(p + float2(e, 0.0), halfSize, r) - sdRoundRect(p - float2(e, 0.0), halfSize, r);
    float dy = sdRoundRect(p + float2(0.0, e), halfSize, r) - sdRoundRect(p - float2(0.0, e), halfSize, r);
    float2 n = float2(dx, dy);
    float len = length(n);
    return len > 0.0001 ? n / len : float2(0.0, -1.0);
}

half4 main(float2 fragCoord) {
    float2 local = fragCoord - cardCenter;
    float dist = sdRoundRect(local, cardHalfSize, cornerRadius);

    // 카드 밖은 아예 안 그립니다. **자르는 일을 셰이더가 직접 합니다.**
    // 캔버스로 잘라낼 일이 없으니 클립 경계에서 생길 수 있는 문제도 없고, 화면 대부분을
    // 차지하는 바깥은 여기서 바로 돌려보내므로 비용도 안 듭니다.
    if (dist > 1.0) return half4(0.0);

    float depth = max(-dist, 0.0);
    float2 normal = surfaceNormal(local, cardHalfSize, cornerRadius);

    // 유리 두께가 만드는 렌즈입니다. 가장자리에서 가장 세게 꺾이고 안으로 갈수록 없어집니다.
    // 띠를 넓게 잡으면 굴절이 아니라 얼룩이 되므로 좁게 둡니다.
    float t = clamp(depth / edgeBand, 0.0, 1.0);
    float lens = (1.0 - t) * (1.0 - t);
    float2 sampleAt = clamp(fragCoord + normal * lens * refraction, float2(0.5), resolution - float2(0.5));

    half4 tap = contents.eval(sampleAt);
    // 스킨의 색은 미리 곱해져 있습니다. 되돌린 뒤에 섞어야 테두리가 검게 뜨지 않습니다.
    // 뒤가 비어 있는 자리는 유리 자체 색으로 채웁니다. 안 그러면 카드에 구멍이 뚫립니다.
    float cover = clamp(float(tap.a), 0.0, 1.0);
    float3 color = mix(tint.rgb, cover > 0.003 ? float3(tap.rgb) / cover : tint.rgb, cover);

    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    color = mix(color, float3(luma), desaturation);
    // **밝은 쪽만** 누릅니다. 노란 말풍선이 유리 아래를 지날 때 바닥이 들뜨는 것을 막습니다.
    // 전체를 누르면 휠 것이 없어져 그냥 반투명 판이 됩니다.
    color *= 1.0 - highlightRolloff * smoothstep(0.35, 0.95, luma);
    color = mix(tint.rgb, color, backdrop);

    // 가장자리 빛. 위 왼쪽에서 빛이 든다고 보고, 그쪽을 향한 면을 밝힙니다.
    // 반대쪽에도 옅게 남겨 둡니다 — 실제 유리는 아래쪽에서 되비친 빛을 받습니다.
    // 유리로 읽히는 느낌의 상당 부분이 이 한 줄에서 나옵니다.
    float rim = 1.0 - smoothstep(0.0, rimWidth, depth);
    float2 lightDir = normalize(float2(-0.45, -1.0));
    float lit = clamp(dot(normal, lightDir), 0.0, 1.0);
    float bounce = clamp(-dot(normal, lightDir), 0.0, 1.0);
    color += float3(rim * (0.40 * lit * lit + 0.10 * bounce * bounce));

    // 모서리 띠를 아주 살짝 눌러 두께를 만듭니다. 띠가 좁아야 상자로 안 보입니다.
    color *= 1.0 - 0.08 * (1.0 - t) * (1.0 - rim);

    // 스킨은 미리 곱해진 색을 기대하므로 알파를 색에도 곱해서 내보냅니다.
    // 경계 1화소만 부드럽게 이어 붙입니다.
    float coverage = clamp(0.5 - dist, 0.0, 1.0);
    return half4(half3(clamp(color, 0.0, 1.0) * coverage), half(coverage));
}
"""

/// 유리가 자리잡을 곳입니다. 화면 좌표(px)로 받습니다.
data class LiquidGlassRegion(
    val bounds: Rect,
    val cornerRadiusPx: Float
)

/// 유리의 세기입니다. 전부 **짐작한 값**입니다. 애플 원본을 화소로 재서 옮긴 것이 아니라
/// 실기기에서 보면서 맞춘 것입니다. 나중에 실측값으로 오해해서 지우지 않도록 적어 둡니다.
object LiquidGlassDefaults {
    /// 서리의 크기입니다. **뒤에 있는 말풍선보다 충분히 커야** 도형이 도형으로 안 남습니다.
    /// 시스템 블러라 넓혀도 얼룩이 안 생기고 비용도 거의 안 오릅니다.
    val blurRadius = 40.dp

    /// 가장자리에서 배경을 얼마나 끌어당기는지입니다.
    val refraction = 18.dp

    /// 휘는 띠의 두께입니다. **좁아야 모서리로 읽힙니다.** 넓히면 카드 안에 도형이 생깁니다.
    val edgeBand = 16.dp

    /// 가장자리 빛이 번지는 폭입니다.
    val rimWidth = 2.5.dp

    /// 배경의 명암을 얼마나 남길지입니다. 0이면 불투명 카드, 1이면 그냥 흐린 판입니다.
    /// **여기를 낮추면 휠 것이 없어져 유리가 아니라 반투명 카드가 됩니다.**
    const val backdrop = 0.55f

    /// 배경에서 색을 걷어내는 정도입니다. 색은 재질의 일부라 조금만 덜어냅니다.
    const val desaturation = 0.20f

    /// 밝은 쪽을 누르는 정도입니다. 노란 내 말풍선이 유리 아래를 지날 때를 위한 값입니다.
    const val highlightRolloff = 0.55f
}

/// 이 요소가 그린 것을 배경 삼아, [region] 자리에 유리를 만듭니다.
///
/// **대화 배경과 목록을 함께 담은 상자에 붙입니다.** 목록에만 붙이면 말풍선 사이 빈 자리가
/// 투명이라 유리가 그 자리에서 뚫립니다. 카드의 글자와 게이지는 이 효과 **위에** 따로
/// 그립니다. 같이 넣으면 카드 글자까지 휘어 읽을 수 없게 됩니다.
///
/// [tint]는 유리 자체의 색입니다. 배경을 이 색 쪽으로 모으므로, 이 값이 곧 글자가 놓일
/// 바닥이 됩니다. **카드가 불투명일 때 쓰던 색을 넣으면** 최악의 자리에서도 그때만큼은 읽힙니다.
@Composable
fun LiquidGlassBackdrop(
    region: LiquidGlassRegion?,
    backgroundColor: Color,
    tint: Color,
    blurRadiusPx: Float,
    refractionPx: Float,
    edgeBandPx: Float,
    rimWidthPx: Float,
    shadowElevation: Dp,
    modifier: Modifier = Modifier,
    backdrop: Float = LiquidGlassDefaults.backdrop,
    desaturation: Float = LiquidGlassDefaults.desaturation,
    highlightRolloff: Float = LiquidGlassDefaults.highlightRolloff,
    content: @Composable BoxScope.() -> Unit
) {
    // 카드는 **창 기준** 자리를 알려주는데, 그림은 이 요소의 **자기 좌표**로 그립니다.
    // 대화 목록은 앱바 아래에서 시작하므로 그 차이만큼 어긋납니다. 처음에 이걸 안 맞춰서
    // 유리가 화면 밖 엉뚱한 자리에 걸렸고, 아무 일도 안 일어나는 것처럼 보였습니다.
    var origin by remember { mutableStateOf(Offset.Zero) }
    val backdropLayer = rememberGraphicsLayer()
    val usable = region != null && region.bounds.width > 1f && region.bounds.height > 1f &&
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU

    Box(modifier.onGloballyPositioned { origin = it.boundsInWindow().topLeft }) {
        Box(
            Modifier.fillMaxSize().drawWithContent {
                // 대화를 한 번만 기록해 두고 두 번 씁니다.
                //
                // **바닥은 여기서 칠해야 합니다.** `Modifier.background`를 앞에 붙이면 그건
                // `drawContent()`보다 먼저 그려지므로 기록에 안 들어갑니다. 그래서 말풍선
                // 사이 빈 자리가 투명인 채로 기록됐고, 유리가 그 자리에서 제 색만 냈습니다.
                backdropLayer.record {
                    drawRect(backgroundColor)
                    this@drawWithContent.drawContent()
                }
                drawLayer(backdropLayer)
            },
            content = content
        )

        // 그림자만 받는 판입니다. 유리가 이 판을 통째로 덮으므로 판 자체는 안 보이고,
        // 바깥으로 번진 그림자만 남습니다. 그게 곧 드롭 섀도입니다.
        //
        // **카드에 직접 `shadow`를 걸면 안 됩니다.** 유리를 켜면 카드에 배경색이 없어서
        // 안드로이드가 그 카드를 "속이 안 비치는 판"으로 못 봅니다. 그래서 그림자를 카드
        // **밑으로도** 그리고, 가장자리에서 옅어지는 그 띠가 끝나는 자리에 1화소짜리
        // 경계가 섭니다. 실기기에서 카드 안쪽 104화소, 밝기 차 22%로 섰습니다.
        // 카드 안에 네모 상자가 보인다던 것이 이것이었습니다 — 유리가 아니라 그림자입니다.
        //
        // 블러 반경을 절반으로 줄여도, 셰이더를 통째로 빼도, 클립을 빼도, 뒤 대화를
        // 스크롤해도 **늘 같은 자리**였습니다. 원인을 유리 안에서만 찾으면 못 찾습니다.
        if (usable && shadowElevation > 0.dp) {
            val card = region!!.bounds.translate(-origin.x, -origin.y)
            val density = LocalDensity.current
            Box(
                Modifier
                    .offset { IntOffset(card.left.roundToInt(), card.top.roundToInt()) }
                    .size(
                        with(density) { card.width.toDp() },
                        with(density) { card.height.toDp() }
                    )
                    .shadow(
                        shadowElevation,
                        RoundedCornerShape(with(density) { region.cornerRadiusPx.toDp() })
                    )
                    .background(backgroundColor)
            )
        }

        // 같은 그림을 유리로 한 번 더 얹습니다.
        //
        // 효과를 **`Modifier.graphicsLayer`에 겁니다.** `GraphicsLayer.renderEffect`에
        // 걸었더니 실기기에서 카드를 0.835배 줄인 자리에 1화소짜리 세로 이음매가 섰습니다.
        // 블러 반경을 절반으로 줄여도, 셰이더를 빼도, 뒤 내용을 바꿔도 같은 자리였고,
        // 유리를 옆으로 밀자 이음매도 따라 움직였습니다. 그 경로가 원인입니다.
        if (usable) Box(
            Modifier.fillMaxSize()
                .graphicsLayer {
                    val card = region!!.bounds.translate(-origin.x, -origin.y)
                    val shader = RuntimeShader(LIQUID_GLASS_SHADER)
                    shader.setFloatUniform("resolution", size.width, size.height)
                    shader.setFloatUniform("cardCenter", card.center.x, card.center.y)
                    shader.setFloatUniform("cardHalfSize", card.width / 2f, card.height / 2f)
                    shader.setFloatUniform("cornerRadius", region.cornerRadiusPx)
                    shader.setFloatUniform("edgeBand", edgeBandPx)
                    shader.setFloatUniform("refraction", refractionPx)
                    shader.setFloatUniform("rimWidth", rimWidthPx)
                    shader.setFloatUniform("tint", tint.red, tint.green, tint.blue, tint.alpha)
                    shader.setFloatUniform("backdrop", backdrop)
                    shader.setFloatUniform("desaturation", desaturation)
                    shader.setFloatUniform("highlightRolloff", highlightRolloff)
                    // 흐린 다음에 휩니다. 실제 유리도 서린 빛이 모서리에서 꺾입니다.
                    // `createChainEffect`는 **뒤 인자가 먼저** 걸립니다.
                    renderEffect = RenderEffect.createChainEffect(
                        RenderEffect.createRuntimeShaderEffect(shader, "contents"),
                        RenderEffect.createBlurEffect(
                            blurRadiusPx, blurRadiusPx, android.graphics.Shader.TileMode.CLAMP
                        )
                    ).asComposeRenderEffect()
                }
                .drawBehind { drawLayer(backdropLayer) }
        )
    }
}

/// 이 기기에서 유리를 쓸 수 있는지입니다. 안 되면 예전 불투명 카드로 갑니다.
val liquidGlassSupported: Boolean
    get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU

/// 유리를 못 쓰는 기기에서 대신 칠하는 불투명 판입니다.
///
/// 유리는 뒤에 무엇이 있어야 성립합니다. 셰이더를 못 쓰는 자리에서 흉내만 내면
/// 아무것도 안 비치는 흐릿한 판이 되어 그냥 못생긴 카드가 됩니다. 그때는 원래 색으로 갑니다.
fun Modifier.opaqueCardSurface(
    color: Color,
    borderColor: Color,
    shape: Shape,
    elevation: Dp
): Modifier = this
    .shadow(elevation, shape, clip = false)
    .clip(shape)
    .background(color)
    .border(1.dp, borderColor, shape)
