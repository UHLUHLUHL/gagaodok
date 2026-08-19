# Shared Numerical Graph Renderer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build one safe local numerical graph engine that renders 2,400px-wide PNGs for math-mentor chat and Obsidian exports, including implicit curves, numerical-integral families, first-order ODE solutions, and the existing 2D/3D diagrams.

**Architecture:** Models emit declarative graph specifications, never executable code or sampled point dumps. A shared Swift expression compiler and bounded sampler produce geometry, and the existing bundled WebKit/SVG sheet renders that geometry to PNG for chat and Obsidian adapters.

**Tech Stack:** Swift 5.9, Foundation, AppKit, WebKit, SVG/HTML bundle resources, direct `swiftc` test executables, Swift Package Manager

**Spec:** `docs/superpowers/specs/2026-08-19-shared-numerical-graph-renderer-design.md`

## Global Constraints

- Change only the macOS math mentor and Obsidian export; do not change companion mode or Android.
- Preserve the current `[GRAPH: ...]` syntax for elementary Cartesian and parametric graphs.
- Do not bundle Python, NumPy, SciPy, or Matplotlib; do not run model-authored code or call an external graph service.
- Accept only bounded declarative specifications and the existing arithmetic/functions over `x`, `y`, and `t`.
- Keep graph failures isolated so text replies and Obsidian notes still complete.
- Keep rendering resources inside the app bundle with no external URLs.
- Preserve all pre-existing Obsidian visual-export changes before refactoring them.
- Render at a logical width of 1,200px and a PNG pixel width of 2,400px.

---

### Task 1: Preserve the Existing Obsidian PNG Baseline

**Files:**
- Verify and commit: the current modified/untracked Obsidian model, service, view, resource, and test files shown by `git status --short`

**Interfaces:**
- Consumes: the complete uncommitted Obsidian visual-export feature already in this worktree.
- Produces: a green baseline commit that later refactors can compare against.

- [ ] **Step 1: Verify the current baseline**

Run:

```bash
swift build
git diff --check
```

Expected: build exit 0 and no whitespace errors.

- [ ] **Step 2: Stage only the known Obsidian visual feature**

```bash
git add Sources/KakaoSapiens/Models/ObsidianExport.swift \
  Sources/KakaoSapiens/Services/GeminiService+Obsidian.swift \
  Sources/KakaoSapiens/Services/ObsidianBatchExportCoordinator.swift \
  Sources/KakaoSapiens/Services/ObsidianExportCoordinator.swift \
  Sources/KakaoSapiens/Services/ObsidianStructuredOutput.swift \
  Sources/KakaoSapiens/Services/ObsidianVaultManager.swift \
  Sources/KakaoSapiens/Services/ObsidianVisualMath.swift \
  Sources/KakaoSapiens/Services/ObsidianVisualRenderer.swift \
  Sources/KakaoSapiens/Resources/visual-sheet.html \
  Sources/KakaoSapiens/Views/ObsidianBatchExportSheet.swift \
  Sources/KakaoSapiens/Views/ObsidianExportSheet.swift \
  Tests/KakaoSapiensTests/ObsidianExportCoreTests.swift \
  Tests/KakaoSapiensTests/ObsidianProblemCardRendererTests.swift \
  Tests/KakaoSapiensTests/ObsidianProviderSchemaTests.swift
git diff --cached --check
git diff --cached --stat
```

Expected: only the previously implemented Obsidian PNG feature is staged.

- [ ] **Step 3: Commit the baseline**

```bash
git commit -m "feat: attach generated visuals to Obsidian exports"
```

Expected: no remaining source changes before the common-engine edits.

### Task 2: Introduce the Neutral Graph Specification

**Files:**
- Create: `Sources/KakaoSapiens/Models/MathVisual.swift`
- Create: `Tests/KakaoSapiensTests/MathVisualModelTests.swift`
- Modify: `Sources/KakaoSapiens/Models/ObsidianExport.swift`
- Modify: `Sources/KakaoSapiens/Services/ObsidianStructuredOutput.swift`
- Modify: `Tests/KakaoSapiensTests/ObsidianProviderSchemaTests.swift`

**Interfaces:**
- Consumes: existing Obsidian visual JSON fields.
- Produces: `MathVisualKind`, `MathVisualPoint`, `MathVisualSegment`, `MathVisualSpec`, plus source-compatible Obsidian type aliases.

- [ ] **Step 1: Write a failing standalone model test**

Use every literal kind and round-trip the complete specification:

```swift
let kinds: [MathVisualKind] = [
    .function2D, .parametric2D, .implicit2D, .integral2D,
    .ode2D, .surface3D, .coordinateDiagram
]
for kind in kinds {
    let spec = MathVisualSpec(
        id: "graph-1", kind: kind, title: "제목", caption: "설명",
        expression: "x+t", xExpression: "cos(t)", yExpression: "sin(t)",
        legend: "해 곡선", xLabel: "x", yLabel: "y", zLabel: "z",
        xMin: -2, xMax: 2, yMin: -2, yMax: 2, zMin: -2, zMax: 2,
        parameterMin: 0, parameterMax: 1, initialX: 0, initialY: 1,
        contourValue: 0, points: [], segments: []
    )
    let data = try JSONEncoder().encode(spec)
    precondition(try JSONDecoder().decode(MathVisualSpec.self, from: data) == spec)
}
```

Decode one legacy visual without new keys and assert exact defaults: empty added strings, `parameterMin == 0`, `parameterMax == 1`, and numeric initial/contour fields equal zero.

- [ ] **Step 2: Run RED**

```bash
swiftc -parse-as-library \
  Sources/KakaoSapiens/Models/MathVisual.swift \
  Tests/KakaoSapiensTests/MathVisualModelTests.swift \
  -o /tmp/math-visual-model-tests
```

Expected: compile failure because the common model does not exist.

- [ ] **Step 3: Implement the common model**

Define these exact kinds and fields:

```swift
public enum MathVisualKind: String, Codable, Equatable, CaseIterable {
    case function2D, parametric2D, implicit2D, integral2D, ode2D
    case surface3D, coordinateDiagram
}

public struct MathVisualSpec: Codable, Equatable, Identifiable {
    public var id: String
    public var kind: MathVisualKind
    public var title: String
    public var caption: String
    public var expression: String
    public var xExpression: String
    public var yExpression: String
    public var legend: String
    public var xLabel: String
    public var yLabel: String
    public var zLabel: String
    public var xMin, xMax, yMin, yMax, zMin, zMax: Double
    public var parameterMin, parameterMax: Double
    public var initialX, initialY, contourValue: Double
    public var points: [MathVisualPoint]
    public var segments: [MathVisualSegment]
}
```

Move the existing point/segment shapes unchanged, implement backward-compatible decoding, and replace old Obsidian declarations with public type aliases.

- [ ] **Step 4: Expand strict provider schemas and run GREEN**

Require every field for new responses and permit all seven kinds. Extend provider tests to inspect the nested visual item for `xExpression`, `parameterMin`, `initialX`, and `contourValue` in both Gemini and OpenAI schemas.

```bash
swiftc -parse-as-library \
  Sources/KakaoSapiens/Models/MathVisual.swift \
  Tests/KakaoSapiensTests/MathVisualModelTests.swift \
  -o /tmp/math-visual-model-tests && /tmp/math-visual-model-tests
swift build
```

Expected: model executable and build succeed.

- [ ] **Step 5: Commit**

```bash
git add Sources/KakaoSapiens/Models/MathVisual.swift \
  Sources/KakaoSapiens/Models/ObsidianExport.swift \
  Sources/KakaoSapiens/Services/ObsidianStructuredOutput.swift \
  Tests/KakaoSapiensTests/MathVisualModelTests.swift \
  Tests/KakaoSapiensTests/ObsidianProviderSchemaTests.swift
git commit -m "refactor: share math visual specifications"
```

### Task 3: Build the Safe Numerical Sampler

**Files:**
- Create: `Sources/KakaoSapiens/Services/MathVisualSampler.swift`
- Create: `Tests/KakaoSapiensTests/MathVisualSamplerTests.swift`
- Modify: `Sources/KakaoSapiens/Services/MathExpression.swift`
- Modify: `Sources/KakaoSapiens/Services/ObsidianVisualMath.swift`

**Interfaces:**
- Consumes: `MathVisualSpec` and compiled `MathExpression` values.
- Produces: `MathVisualSampler.validate(_:) throws` and `MathVisualSampler.sample(_:) throws -> MathVisualSample`, with curves and depth-sorted surface triangles.

- [ ] **Step 1: Write failing numerical behavior tests**

Assert these hand-derived outcomes:

```swift
precondition(MathExpression("sin(x)+t")?.value(["x": .pi/2, "t": 2]) == 3)
precondition(MathExpression("Process(x)") == nil)
precondition(MathExpression("x;system(t)") == nil)

let reciprocal = try MathVisualSampler.sample(functionSpec("1/x", x: -1...1, y: -5...5))
precondition(reciprocal.curves.count == 2)

let circle = try MathVisualSampler.sample(implicitSpec("x^2+y^2", level: 1))
let circlePoints = circle.curves.flatMap { $0 }
precondition(circlePoints.count > 100)
precondition(circlePoints.allSatisfy { abs($0.x*$0.x + $0.y*$0.y - 1) < 0.03 })

let integral = try MathVisualSampler.sample(integralSpec("x*t", t: 0...1, x: 2...2.01))
precondition(abs(integral.curves[0][0].y - 1) < 1e-6)

let ode = try MathVisualSampler.sample(odeSpec("y", initialX: 0, initialY: 1, x: 0...1))
precondition(abs(ode.curves[0].last!.y - M_E) < 1e-4)
```

Also test reversed bounds, a source longer than 300 UTF-8 bytes, non-finite results, and evaluation-budget exhaustion.

- [ ] **Step 2: Run RED**

```bash
swiftc -parse-as-library \
  Sources/KakaoSapiens/Models/MathVisual.swift \
  Sources/KakaoSapiens/Services/MathExpression.swift \
  Sources/KakaoSapiens/Services/MathVisualSampler.swift \
  Tests/KakaoSapiensTests/MathVisualSamplerTests.swift \
  -o /tmp/math-visual-sampler-tests
```

Expected: compile failure because the sampler does not exist.

- [ ] **Step 3: Unify expression validation**

Keep the AST private and add:

```swift
public static func compile(_ source: String, allowedVariables: Set<String>) throws -> MathExpression
public func value(_ variables: [String: Double]) -> Double?
```

Enforce a 300-byte limit and allowed-variable set. Make `ObsidianVisualMath` delegate to this parser instead of maintaining a second evaluator.

- [ ] **Step 4: Implement bounded algorithms**

- function/parametric: 1,200 samples with discontinuity splitting
- implicit: at most 320 × 240 marching-squares cells with interpolated edges
- integral: adaptive Simpson tolerance `1e-7`, depth 12, at most 250,000 expression evaluations
- ODE: bidirectional RK4, at most 2,400 steps, derived step clamped to `[1e-5, width/200]`
- surface: 48 × 48 grid and two triangles per valid cell

Reject missing type-specific expressions. Coordinate diagrams require points or segments and no sampling.

- [ ] **Step 5: Run GREEN and mutation check**

```bash
swiftc -parse-as-library \
  Sources/KakaoSapiens/Models/MathVisual.swift \
  Sources/KakaoSapiens/Services/MathExpression.swift \
  Sources/KakaoSapiens/Services/MathVisualSampler.swift \
  Tests/KakaoSapiensTests/MathVisualSamplerTests.swift \
  -o /tmp/math-visual-sampler-tests && /tmp/math-visual-sampler-tests
swift build
```

Expected: both succeed. Temporarily changing RK4's fourth weight must fail the `e^x` assertion; restore it before commit.

- [ ] **Step 6: Commit**

```bash
git add Sources/KakaoSapiens/Services/MathExpression.swift \
  Sources/KakaoSapiens/Services/MathVisualSampler.swift \
  Sources/KakaoSapiens/Services/ObsidianVisualMath.swift \
  Tests/KakaoSapiensTests/MathVisualSamplerTests.swift
git commit -m "feat: sample bounded numerical graph specifications"
```

### Task 4: Create the Shared WebKit PNG Renderer

**Files:**
- Create: `Sources/KakaoSapiens/Services/MathVisualRenderer.swift`
- Modify: `Sources/KakaoSapiens/Services/ObsidianVisualRenderer.swift`
- Modify: `Sources/KakaoSapiens/Resources/visual-sheet.html`
- Create: `Tests/KakaoSapiensTests/MathVisualRendererTests.swift`

**Interfaces:**
- Consumes: `MathVisualSampler.sample(_:)` and `visual-sheet.html`.
- Produces: `@MainActor MathVisualRenderer.render(spec:) async throws -> Data`; compatibility alias `ObsidianVisualRenderer`.

- [ ] **Step 1: Add failing real-render tests**

Render one implicit, integral, and ODE specification and assert each result:

```swift
precondition(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
let image = NSImage(data: data)!
let bitmap = image.representations.compactMap { $0 as? NSBitmapImageRep }.first!
precondition(bitmap.pixelsWide == 2_400)
```

Assert the HTML has legend/axis label elements and no `http://` or `https://`.

- [ ] **Step 2: Run RED**

```bash
swiftc -parse-as-library \
  Sources/KakaoSapiens/Models/MathVisual.swift \
  Sources/KakaoSapiens/Services/MathExpression.swift \
  Sources/KakaoSapiens/Services/MathVisualSampler.swift \
  Sources/KakaoSapiens/Services/MathVisualRenderer.swift \
  Tests/KakaoSapiensTests/MathVisualRendererTests.swift \
  -framework AppKit -framework WebKit \
  -o /tmp/math-visual-renderer-tests
```

Expected: compile failure because `MathVisualRenderer` does not exist.

- [ ] **Step 3: Move rendering orchestration into the common renderer**

The renderer must call the sampler and retain:

```swift
public static let logicalWidth: CGFloat = 1_200
public static let pixelWidth = 2_400
public func render(spec: MathVisualSpec) async throws -> Data
```

Keep `ObsidianVisualRenderer` as a source-compatible alias during migration.

- [ ] **Step 4: Upgrade SVG output**

Escape and render `xLabel`, `yLabel`, `zLabel`, and `legend`. Use common curve geometry for function, parametric, implicit, integral, and ODE kinds. Preserve the 3D mesh and coordinate layers.

- [ ] **Step 5: Run GREEN and commit**

```bash
swiftc -parse-as-library \
  Sources/KakaoSapiens/Models/MathVisual.swift \
  Sources/KakaoSapiens/Services/MathExpression.swift \
  Sources/KakaoSapiens/Services/MathVisualSampler.swift \
  Sources/KakaoSapiens/Services/MathVisualRenderer.swift \
  Tests/KakaoSapiensTests/MathVisualRendererTests.swift \
  -framework AppKit -framework WebKit \
  -o /tmp/math-visual-renderer-tests && /tmp/math-visual-renderer-tests
swift build
```

Expected: renderer executable and build succeed.

```bash
git add Sources/KakaoSapiens/Services/MathVisualRenderer.swift \
  Sources/KakaoSapiens/Services/ObsidianVisualRenderer.swift \
  Sources/KakaoSapiens/Resources/visual-sheet.html \
  Tests/KakaoSapiensTests/MathVisualRendererTests.swift
git commit -m "refactor: share high resolution graph rendering"
```

### Task 5: Extend Obsidian to Numerical Visual Kinds

**Files:**
- Modify: `Sources/KakaoSapiens/Services/GeminiService+Obsidian.swift`
- Modify: `Sources/KakaoSapiens/Services/ObsidianExportCoordinator.swift`
- Modify: `Sources/KakaoSapiens/Services/ObsidianBatchExportCoordinator.swift`
- Modify: `Tests/KakaoSapiensTests/MathVisualSamplerTests.swift`
- Modify: `Tests/KakaoSapiensTests/ObsidianProviderSchemaTests.swift`

**Interfaces:**
- Consumes: all `MathVisualKind` values and `MathVisualRenderer.shared`.
- Produces: validated numerical visuals with unchanged filenames, selection state, stale state, and Markdown links.

- [ ] **Step 1: Add failing decoding/validation fixtures**

Add literal `implicit2D`, `integral2D`, and `ode2D` specifications. Assert valid fixtures survive `MathVisualSampler.validate(_:)` while reversed bounds, empty ODE RHS, non-finite initial values, and equal integration bounds are rejected individually.

- [ ] **Step 2: Run focused core/schema tests and verify RED**

```bash
swiftc -parse-as-library \
  Sources/KakaoSapiens/Services/ObsidianStructuredOutput.swift \
  Tests/KakaoSapiensTests/ObsidianProviderSchemaTests.swift \
  -o /tmp/obsidian-schema-tests && /tmp/obsidian-schema-tests
swiftc -parse-as-library \
  Sources/KakaoSapiens/Models/MathVisual.swift \
  Sources/KakaoSapiens/Services/MathExpression.swift \
  Sources/KakaoSapiens/Services/MathVisualSampler.swift \
  Tests/KakaoSapiensTests/MathVisualSamplerTests.swift \
  -o /tmp/math-visual-sampler-tests && /tmp/math-visual-sampler-tests
```

Expected: schema test fails because advanced required fields are absent, or sampler test fails because type-specific validation is incomplete.

- [ ] **Step 3: Update the prepared-note contract**

List all seven kinds and every required field. Instruct the model to use only source-supported equations/bounds/initial conditions, return `visuals: []` when unhelpful, and distinguish implicit, fixed-bound integral-family, and first-order IVP specs.

- [ ] **Step 4: Use the common renderer in single and batch export**

Replace compatibility-name calls with `MathVisualRenderer.shared`. Preserve per-visual failure isolation and all existing export behavior.

- [ ] **Step 5: Run GREEN and commit**

```bash
swiftc -parse-as-library \
  Sources/KakaoSapiens/Services/ObsidianStructuredOutput.swift \
  Tests/KakaoSapiensTests/ObsidianProviderSchemaTests.swift \
  -o /tmp/obsidian-schema-tests && /tmp/obsidian-schema-tests
swiftc -parse-as-library \
  Sources/KakaoSapiens/Models/MathVisual.swift \
  Sources/KakaoSapiens/Services/MathExpression.swift \
  Sources/KakaoSapiens/Services/MathVisualSampler.swift \
  Tests/KakaoSapiensTests/MathVisualSamplerTests.swift \
  -o /tmp/math-visual-sampler-tests && /tmp/math-visual-sampler-tests
swift build
```

Expected: both executables and build succeed.

```bash
git add Sources/KakaoSapiens/Services/GeminiService+Obsidian.swift \
  Sources/KakaoSapiens/Services/ObsidianExportCoordinator.swift \
  Sources/KakaoSapiens/Services/ObsidianBatchExportCoordinator.swift \
  Tests/KakaoSapiensTests/MathVisualSamplerTests.swift \
  Tests/KakaoSapiensTests/ObsidianProviderSchemaTests.swift
git commit -m "feat: export numerical graph visuals to Obsidian"
```

### Task 6: Parse Advanced Chat Tags and Attach PNG Bubbles

**Files:**
- Create: `Sources/KakaoSapiens/Services/MathVisualTagParser.swift`
- Create: `Sources/KakaoSapiens/Services/MathVisualAttachmentFactory.swift`
- Create: `Tests/KakaoSapiensTests/MathVisualChatTests.swift`
- Modify: `Sources/KakaoSapiens/Services/MathGraphRenderer.swift`
- Modify: `Sources/KakaoSapiens/Services/GeminiService+Bubbles.swift`
- Modify: `Sources/KakaoSapiens/Services/GeminiService.swift`

**Interfaces:**
- Consumes: legacy `[GRAPH: ...]` and JSON `[NUMERIC_GRAPH]...[/NUMERIC_GRAPH]` blocks.
- Produces: cleaned text, validated common specs, and `.png`/`image/png` `ChatAttachment` values.

- [ ] **Step 1: Write failing parser tests**

For legacy input, assert `sin(x)` becomes `function2D` and ordinary text remains. For advanced input, decode this block and assert `implicit2D` with contour 1:

```text
[NUMERIC_GRAPH]
{"id":"graph-1","kind":"implicit2D","title":"단위원","caption":"","expression":"x^2+y^2","xExpression":"","yExpression":"","legend":"F(x,y)=1","xLabel":"x","yLabel":"y","zLabel":"","xMin":-2,"xMax":2,"yMin":-2,"yMax":2,"zMin":-1,"zMax":1,"parameterMin":0,"parameterMax":1,"initialX":0,"initialY":0,"contourValue":1,"points":[],"segments":[]}
[/NUMERIC_GRAPH]
```

Assert malformed JSON, unknown kinds, duplicate IDs, payloads over 16KB, and executable-looking fields are rejected without deleting ordinary text.

- [ ] **Step 2: Run RED**

```bash
swiftc -parse-as-library \
  Sources/KakaoSapiens/Models/MathVisual.swift \
  Sources/KakaoSapiens/Models/Message.swift \
  Sources/KakaoSapiens/Services/ImageBudget.swift \
  Sources/KakaoSapiens/Services/MathExpression.swift \
  Sources/KakaoSapiens/Services/MathVisualSampler.swift \
  Sources/KakaoSapiens/Services/MathVisualRenderer.swift \
  Sources/KakaoSapiens/Services/MathVisualTagParser.swift \
  Sources/KakaoSapiens/Services/MathVisualAttachmentFactory.swift \
  Tests/KakaoSapiensTests/MathVisualChatTests.swift \
  -framework AppKit -framework WebKit -framework UniformTypeIdentifiers \
  -o /tmp/math-visual-chat-tests
```

Expected: compile failure because parser/factory files do not exist.

- [ ] **Step 3: Implement strict parsing and legacy adaptation**

Move legacy tag parsing from `MathGraphRenderer` into `MathVisualTagParser`. Decode one JSON object per advanced block, enforce the 16KB limit, validate every spec, and return one warning flag when any graph is rejected.

- [ ] **Step 4: Implement PNG attachment creation**

```swift
public static func make(title: String, png: Data) -> ChatAttachment {
    ChatAttachment(
        type: .image, fileName: sanitized(title) + ".png",
        fileSize: Int64(png.count), fileExtension: "png",
        dataBase64: png.base64EncodedString(), mimeType: "image/png"
    )
}
```

- [ ] **Step 5: Await shared rendering in bubble parsing**

Make `parseResponseIntoBubbles` async and update both call sites. Preserve text, append one image bubble per successful graph, and append `그래프 이미지를 만들지 못했습니다.` once if any requested graph fails. Never retry with a substituted function.

- [ ] **Step 6: Run GREEN and commit**

Use the real renderer in the chat test. Base64-decode the attachment and assert PNG signature, `.png`, and `image/png`, then run:

```bash
swiftc -parse-as-library \
  Sources/KakaoSapiens/Models/MathVisual.swift \
  Sources/KakaoSapiens/Models/Message.swift \
  Sources/KakaoSapiens/Services/ImageBudget.swift \
  Sources/KakaoSapiens/Services/MathExpression.swift \
  Sources/KakaoSapiens/Services/MathVisualSampler.swift \
  Sources/KakaoSapiens/Services/MathVisualRenderer.swift \
  Sources/KakaoSapiens/Services/MathVisualTagParser.swift \
  Sources/KakaoSapiens/Services/MathVisualAttachmentFactory.swift \
  Tests/KakaoSapiensTests/MathVisualChatTests.swift \
  -framework AppKit -framework WebKit -framework UniformTypeIdentifiers \
  -o /tmp/math-visual-chat-tests && /tmp/math-visual-chat-tests
swift build
```

Expected: chat executable and build succeed.

```bash
git add Sources/KakaoSapiens/Services/MathVisualTagParser.swift \
  Sources/KakaoSapiens/Services/MathVisualAttachmentFactory.swift \
  Sources/KakaoSapiens/Services/MathGraphRenderer.swift \
  Sources/KakaoSapiens/Services/GeminiService+Bubbles.swift \
  Sources/KakaoSapiens/Services/GeminiService.swift \
  Tests/KakaoSapiensTests/MathVisualChatTests.swift
git commit -m "feat: attach numerical graph PNGs to mentor replies"
```

### Task 7: Update the Math-Mentor System Prompt

**Files:**
- Modify: `Sources/KakaoSapiens/Models/ChatMode.swift`

**Interfaces:**
- Consumes: tag contracts implemented in Task 6.
- Produces: accurate instructions that never claim Python execution.

- [ ] **Step 1: Replace graph guidance with the implemented contract**

Keep both existing legacy examples. Add compact complete examples for `implicit2D`, `integral2D`, and `ode2D`. State that the app performs local bounded calculation and PNG rendering; require accurate bounds, labels, legends, and source-supported feature points; forbid invented conditions and unnecessary graphs.

- [ ] **Step 2: Build and validate examples**

Run `swift build`, then feed each prompt example to `MathVisualTagParser` in the chat executable. Expected: build succeeds and every example produces exactly one spec. Do not add a brittle source-text grep test for prose.

- [ ] **Step 3: Commit**

```bash
git add Sources/KakaoSapiens/Models/ChatMode.swift
git commit -m "feat: request numerical graph PNGs from mentor"
```

### Task 8: Final Build, Installation, and Real-Flow Verification

**Files:**
- Review: all files changed by Tasks 1–7
- Verify: `/Applications/가가오독.app`

**Interfaces:**
- Consumes: the complete shared graph pipeline.
- Produces: a signed installed app and evidence for supported graph flows.

- [ ] **Step 1: Run all focused executables**

```bash
swiftc -parse-as-library Sources/KakaoSapiens/Models/MathVisual.swift \
  Tests/KakaoSapiensTests/MathVisualModelTests.swift \
  -o /tmp/math-visual-model-tests && /tmp/math-visual-model-tests
swiftc -parse-as-library Sources/KakaoSapiens/Models/MathVisual.swift \
  Sources/KakaoSapiens/Services/MathExpression.swift \
  Sources/KakaoSapiens/Services/MathVisualSampler.swift \
  Tests/KakaoSapiensTests/MathVisualSamplerTests.swift \
  -o /tmp/math-visual-sampler-tests && /tmp/math-visual-sampler-tests
swiftc -parse-as-library Sources/KakaoSapiens/Models/MathVisual.swift \
  Sources/KakaoSapiens/Services/MathExpression.swift \
  Sources/KakaoSapiens/Services/MathVisualSampler.swift \
  Sources/KakaoSapiens/Services/MathVisualRenderer.swift \
  Tests/KakaoSapiensTests/MathVisualRendererTests.swift \
  -framework AppKit -framework WebKit \
  -o /tmp/math-visual-renderer-tests && /tmp/math-visual-renderer-tests
swiftc -parse-as-library Sources/KakaoSapiens/Services/ObsidianStructuredOutput.swift \
  Tests/KakaoSapiensTests/ObsidianProviderSchemaTests.swift \
  -o /tmp/obsidian-schema-tests && /tmp/obsidian-schema-tests
swiftc -parse-as-library Sources/KakaoSapiens/Models/MathVisual.swift \
  Sources/KakaoSapiens/Models/Message.swift Sources/KakaoSapiens/Services/ImageBudget.swift \
  Sources/KakaoSapiens/Services/MathExpression.swift \
  Sources/KakaoSapiens/Services/MathVisualSampler.swift \
  Sources/KakaoSapiens/Services/MathVisualRenderer.swift \
  Sources/KakaoSapiens/Services/MathVisualTagParser.swift \
  Sources/KakaoSapiens/Services/MathVisualAttachmentFactory.swift \
  Tests/KakaoSapiensTests/MathVisualChatTests.swift \
  -framework AppKit -framework WebKit -framework UniformTypeIdentifiers \
  -o /tmp/math-visual-chat-tests && /tmp/math-visual-chat-tests
```

Expected: all five executables exit 0.

- [ ] **Step 2: Build, install, and verify signing**

```bash
swift build
./build_app.sh
codesign --verify --deep --strict /Applications/가가오독.app
```

Expected: all exit 0.

- [ ] **Step 3: Relaunch the installed app**

Quit the old process, launch `/Applications/가가오독.app`, and verify its process start is later than the installed bundle modification time.

- [ ] **Step 4: Verify chat flows**

In a disposable mentor room inspect an elementary `sin(x)` graph, unit-circle implicit graph, parameter-dependent fixed-bound integral, `y'=y, y(0)=1`, and a conceptual reply where no graph is useful. If a live provider call lacks a configured key or would incur unapproved cost, record it as skipped and drive the same literal tags through the real parser/renderer executable.

- [ ] **Step 5: Verify Obsidian flows**

Export an advanced visual, deselect one visual, and inspect Markdown plus files. Confirm the selected PNG opens at 2,400px width with an `attachments/visual-...png` wikilink and the deselected file is absent.

- [ ] **Step 6: Finish with repository hygiene**

```bash
git diff --check
git status --short --branch
git log --oneline -8
```

Expected: no unstaged implementation changes, no whitespace errors, and no Android changes.
