package com.sapiens.gagaodok.ui.components

import android.graphics.RenderEffect
import android.graphics.RuntimeShader
import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.asComposeRenderEffect
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/// 유리 뒤에 깔린 배경을 **휘고, 흐리고, 고르게** 만드는 셰이더입니다.
///
/// 안드로이드 13(API 33)부터 쓸 수 있습니다. 그 아래에서는 이 효과를 걸지 않습니다.
///
/// 실기기(S25 Ultra, 1440×3120, 밀도 3.75)에서 세 가지가 잘못 보였고, 원인이 모두 달랐습니다.
///
/// **하나. 굴절이 혜성처럼 번졌습니다.** 밀어내는 방향을 카드 중심에서 뻗는 방향으로
/// 잡았기 때문입니다. 유리는 **면에 수직으로** 빛을 꺾습니다. 가로로 긴 카드(336×154dp)에서는
/// 중심 방향과 면의 법선이 크게 어긋나서, 왼쪽 가장자리가 옆이 아니라 비스듬히 끌렸습니다.
/// 뒤에 있던 프로필 사진이 대각선으로 늘어나 꼬리를 남겼습니다. 이제는 거리장의 기울기를
/// 그 자리에서 구해 **진짜 법선**으로 밉니다.
///
/// **둘. 카드 안에 네모 상자가 보였습니다.** 굴절 띠를 22dp로 잡고 그 띠 안에서만 흐림의
/// 세기까지 같이 바꿨기 때문입니다. 가장자리 22dp는 바깥의 어두운 화면을 깊이 끌어와
/// 매끈하게 뭉갠 띠가 되고, 그 안쪽은 뒤의 밝은 말풍선이 그대로 비쳤습니다. 수식은
/// 이어져 있었지만 **양쪽의 밝기 차이가 커서** 경계가 사각형으로 읽혔습니다. 지금은
/// 흐림을 카드 전체에 **똑같이** 걸고, 휘는 것만 좁은 모서리 띠에서 합니다. 실제 유리도
/// 서리는 판 전체에 고르고 빛은 테두리에서만 꺾입니다.
///
/// **셋. 글씨가 묻혔습니다.** 흐리기만 해서는 뒤의 흰 말풍선이 지나갈 때 바닥이 통째로
/// 들뜹니다. 같은 색 글자가 어떤 자리에서는 읽히고 어떤 자리에서는 사라집니다. 유리 너머가
/// "무언가 움직인다"로는 남되 읽히지는 않도록, 채도를 걷고 밝은 쪽을 누르고 명암 폭을
/// 좁혀 **카드 원래 색**으로 모읍니다. 목표는 불투명 카드였을 때보다 읽기 어렵지 않은 것입니다.
private const val LIQUID_GLASS_SHADER = """
uniform shader contents;
uniform float2 resolution;
uniform float2 cardCenter;
uniform float2 cardHalfSize;
uniform float cornerRadius;
uniform float edgeBand;
uniform float refraction;
uniform float blurRadius;
uniform float rimWidth;
uniform float4 tint;
uniform float backdrop;
uniform float desaturation;
uniform float highlightRolloff;

const int TAPS = 40;

// 둥근 사각형까지의 거리입니다. 안쪽이 음수, 바깥이 양수입니다.
float sdRoundRect(float2 p, float2 halfSize, float r) {
    float2 d = abs(p) - halfSize + r;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

// 그 자리에서 면이 바깥을 보는 방향입니다. 거리장의 기울기를 좌우·상하 차분으로 구합니다.
// 모서리에서도 맞는 값이 나옵니다. 중심에서 뻗는 방향으로는 절대 대신할 수 없습니다.
float2 surfaceNormal(float2 p, float2 halfSize, float r) {
    float e = 1.0;
    float dx = sdRoundRect(p + float2(e, 0.0), halfSize, r) - sdRoundRect(p - float2(e, 0.0), halfSize, r);
    float dy = sdRoundRect(p + float2(0.0, e), halfSize, r) - sdRoundRect(p - float2(0.0, e), halfSize, r);
    float2 n = float2(dx, dy);
    float len = length(n);
    return len > 0.0001 ? n / len : float2(0.0, -1.0);
}

// 배경을 벗어난 자리를 집으면 아무것도 안 딸려 옵니다. 가장자리 안쪽으로 붙잡아 둡니다.
float2 clampToLayer(float2 p) {
    return clamp(p, float2(0.5), resolution - float2(0.5));
}

half4 main(float2 fragCoord) {
    float2 local = fragCoord - cardCenter;
    float dist = sdRoundRect(local, cardHalfSize, cornerRadius);

    // 유리 밖은 손대지 않습니다. 화면 전체에 걸리는 효과라 여기가 대부분입니다.
    if (dist > 0.5) return contents.eval(fragCoord);

    float depth = -dist;
    float2 normal = surfaceNormal(local, cardHalfSize, cornerRadius);

    // 모서리 띠 안에서만 휩니다. 유리 두께가 만드는 렌즈입니다. 가장자리에서 가장 세고
    // 안으로 들어가면 사라집니다. 띠를 넓게 잡으면 굴절이 아니라 얼룩이 됩니다.
    float bevel = 1.0 - clamp(depth / edgeBand, 0.0, 1.0);
    float warp = bevel * bevel;
    float2 sampleAt = fragCoord + normal * warp * refraction;

    // 서리는 **카드 전체에 똑같이** 겁니다. 자리마다 세기를 바꾸면 그 경계가 도형으로 보입니다.
    //
    // 표본을 황금각으로 원반에 뿌리되, 시작 각도를 화소마다 흩뜨립니다. 고정된 각도로만
    // 돌리면 표본 자리가 규칙적으로 겹쳐 뒤의 글자와 어긋나며 **격자무늬**가 생깁니다.
    // 앞 판에서 카드 안이 천 짜인 것처럼 보였던 것이 이것입니다.
    float jitter = fract(sin(dot(fragCoord, float2(12.9898, 78.233))) * 43758.5453) * 6.2831853;
    float3 sum = float3(0.0);
    float alpha = 0.0;
    for (int i = 0; i < TAPS; i++) {
        float fi = float(i);
        float angle = jitter + fi * 2.39996;
        float r = blurRadius * sqrt((fi + 0.5) / float(TAPS));
        half4 tap = contents.eval(clampToLayer(sampleAt + float2(cos(angle), sin(angle)) * r));
        sum += float3(tap.rgb);
        alpha += float(tap.a);
    }
    float3 blurred = sum / float(TAPS);
    float cover = clamp(alpha / float(TAPS), 0.0, 1.0);

    // 뒤가 비어 있는 자리는 유리 자체 색으로 채웁니다. 안 그러면 카드에 구멍이 뚫립니다.
    // 스킨은 미리 곱해진 색이라 나눠서 되돌린 뒤 섞어야 테두리가 검게 뜨지 않습니다.
    float3 color = mix(tint.rgb, cover > 0.003 ? blurred / cover : tint.rgb, cover);

    // 여기서부터가 "읽을 수 있는 유리"를 만드는 세 단계입니다.
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    color = mix(color, float3(luma), desaturation);                          // 색을 걷어냅니다.
    color *= 1.0 - highlightRolloff * smoothstep(0.25, 0.95, luma);          // 흰 쪽을 누릅니다.
    color = mix(tint.rgb, color, backdrop);                                  // 명암 폭을 좁힙니다.

    // 가장자리 빛. 위에서 빛이 든다고 보고 **면이 위를 향한** 쪽을 밝힙니다.
    // 카드 위아래 위치로 가늠하던 앞 판과 달리, 모서리에서도 방향이 맞습니다.
    float rim = 1.0 - smoothstep(0.0, rimWidth, depth);
    float facing = 0.5 - 0.5 * normal.y;
    color += float3(rim * (0.05 + 0.18 * facing));

    // 유리는 불투명한 재질입니다. 경계 1화소만 부드럽게 이어 붙입니다.
    float coverage = clamp(0.5 - dist, 0.0, 1.0);
    return mix(contents.eval(fragCoord), half4(half3(color), 1.0), half(coverage));
}
"""

/// 유리가 자리잡을 곳입니다. 화면 좌표(px)로 받습니다.
data class LiquidGlassRegion(
    val bounds: Rect,
    val cornerRadiusPx: Float
)

/// 유리의 세기입니다. 전부 **짐작한 값**입니다. 애플 원본을 화소로 재서 옮긴 것이 아니라,
/// 실기기에서 보면서 맞춘 것입니다. 나중에 실측값으로 오해하지 않도록 여기 적어 둡니다.
object LiquidGlassDefaults {
    /// 서리의 크기입니다. 카드 전체에 똑같이 걸립니다.
    val blurRadius = 20.dp

    /// 가장자리에서 배경을 얼마나 끌어당기는지입니다.
    val refraction = 10.dp

    /// 휘는 띠의 두께입니다. **좁아야 모서리로 읽힙니다.** 넓히면 카드 안에 도형이 생깁니다.
    val edgeBand = 12.dp

    /// 가장자리 빛이 번지는 폭입니다.
    val rimWidth = 2.dp

    /// 배경의 명암을 얼마나 남길지입니다. 0이면 불투명 카드, 1이면 그냥 흐린 판입니다.
    const val backdrop = 0.34f

    /// 배경에서 색을 얼마나 걷어낼지입니다.
    const val desaturation = 0.45f

    /// 밝은 쪽을 얼마나 누를지입니다. 흰 말풍선이 유리 아래를 지나갈 때를 위한 값입니다.
    const val highlightRolloff = 0.55f
}

/// 이 요소가 그린 것을 배경 삼아, [region] 자리에 유리를 만듭니다.
///
/// **대화 배경과 목록을 함께 담은 상자에 붙입니다.** 유리는 뒤에 무엇이 있어야 성립하므로,
/// 흐리고 휠 대상이 이 요소가 그린 그림입니다. 목록에만 붙이면 말풍선 사이 빈 자리가
/// 투명이라 유리가 그 자리에서 뚫립니다. 카드의 글자와 게이지는 이 효과 **위에** 따로
/// 그립니다. 같이 넣으면 카드 글자까지 휘어 읽을 수 없게 됩니다.
///
/// [tint]는 유리 자체의 색입니다. **카드가 불투명일 때 쓰던 색을 그대로 넣습니다.**
/// 배경을 이 색으로 모으기 때문에, 글자가 놓일 바닥이 불투명 카드와 같아집니다.
@Composable
fun Modifier.liquidGlassBackdrop(
    region: LiquidGlassRegion?,
    tint: Color,
    blurRadiusPx: Float,
    refractionPx: Float,
    edgeBandPx: Float,
    rimWidthPx: Float,
    backdrop: Float = LiquidGlassDefaults.backdrop,
    desaturation: Float = LiquidGlassDefaults.desaturation,
    highlightRolloff: Float = LiquidGlassDefaults.highlightRolloff
): Modifier {
    // 카드는 **창 기준** 자리를 알려주는데, 셰이더가 받는 좌표는 이 요소의 **자기 좌표**입니다.
    // 대화 목록은 앱바 아래에서 시작하므로 그 차이만큼 어긋납니다. 처음에 이걸 안 맞춰서
    // 유리가 화면 밖 엉뚱한 자리에 걸렸고, 아무 일도 안 일어나는 것처럼 보였습니다.
    var origin by remember { mutableStateOf(Offset.Zero) }
    val positioned = this.onGloballyPositioned { origin = it.boundsInWindow().topLeft }

    if (region == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return positioned
    if (region.bounds.width <= 1f || region.bounds.height <= 1f) return positioned
    val local = region.bounds.translate(-origin.x, -origin.y)
    return positioned.graphicsLayer {
        val shader = RuntimeShader(LIQUID_GLASS_SHADER)
        shader.setFloatUniform("resolution", size.width, size.height)
        shader.setFloatUniform("cardCenter", local.center.x, local.center.y)
        shader.setFloatUniform("cardHalfSize", local.width / 2f, local.height / 2f)
        shader.setFloatUniform("cornerRadius", region.cornerRadiusPx)
        shader.setFloatUniform("edgeBand", edgeBandPx)
        shader.setFloatUniform("refraction", refractionPx)
        shader.setFloatUniform("blurRadius", blurRadiusPx)
        shader.setFloatUniform("rimWidth", rimWidthPx)
        shader.setFloatUniform("tint", tint.red, tint.green, tint.blue, tint.alpha)
        shader.setFloatUniform("backdrop", backdrop)
        shader.setFloatUniform("desaturation", desaturation)
        shader.setFloatUniform("highlightRolloff", highlightRolloff)
        renderEffect = RenderEffect
            .createRuntimeShaderEffect(shader, "contents")
            .asComposeRenderEffect()
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
