# Infinite Ink Canvas Design

Date: 2026-08-20
Branch: `codex/obsidian-mentor-export`

## Goal

Turn the tablet handwriting panel into a stylus-first infinite vector canvas.
Resizing the panel must reveal more workspace instead of scaling existing ink.
Screen rendering, erasing, hover feedback, persistence, and exported PNGs must
share one coordinate and width model so the sent image matches what the user
saw.

This change also fixes attachment-only user messages so they can be resent from
their original point in the conversation.

## Confirmed interaction model

- S Pen or another stylus draws and erases.
- One finger pans the canvas and never creates ink.
- Two fingers pan and zoom around their focal point.
- Stylus hover shows the effective eraser footprint while erasing.
- A stylus barrel button temporarily uses the configured eraser width.
- Pen width and eraser width remain independent.
- Pen and eraser strokes use fixed width; pressure does not change thickness.
- Resizing the floating panel changes only the visible viewport.

## Coordinate system

### World space

New strokes are stored in unbounded world coordinates rather than normalized
`0...1` panel coordinates. Width is stored in the same logical world units.
The document records a coordinate-space version so old and new documents can
be decoded safely.

### Viewport

Each document stores its last viewport:

- world-space center or translation;
- zoom level;
- coordinate-space version.

Rendering uses one transform in both directions:

```text
world -> viewport translation -> zoom -> screen
screen -> inverse zoom -> inverse translation -> world
```

Changing panel dimensions does not mutate the transform or stroke geometry.
Zoom is clamped to a practical range, and its focal world point remains under
the gesture centroid.

### Legacy migration

Legacy normalized points are mapped once into a default logical canvas. Their
IDs, ordering, colors, timestamps, and eraser flags are preserved. Migration
is written only after successful conversion. Missing version and viewport
fields decode to legacy defaults, so previously stored history remains
readable.

## Input routing

Motion events are routed by tool and pointer count before they reach the ink
session:

- stylus down/move/up: draw or erase in world coordinates;
- stylus hover enter/move/exit: update or clear the hover cursor;
- one finger: pan;
- two or more fingers: pan and zoom;
- palm and finger contacts: never create strokes.

Starting a stylus stroke freezes that stroke's color, mode, and width until it
ends. The toolbar may change afterward without changing the active preview.

## Stroke rendering

Pressure remains available in decoded legacy data but is ignored for width.
Every segment uses the selected fixed world-space width, rounded caps, and
rounded joins. Consecutive input points are smoothed with a bounded curve or
midpoint interpolation that does not move endpoints or create overshoot.

The renderer accepts the same world-to-output transform for the live canvas
and PNG output. Eraser strokes use the same width path as their live preview.
This removes the current density mismatch where screen width is multiplied by
display density but export width is treated as raw pixels.

## Eraser hover

While the stylus is hovering and the effective input mode is eraser, the canvas
shows a circular cursor centered at the projected contact point. Its diameter
matches the actual screen-space eraser width at the current zoom. It uses a
neutral translucent fill and border, with no yellow glow. It disappears on
hover exit, contact, tool change, or panel close.

## Continuous elastic sliders

Material Slider remains only as the accessible gesture and semantics layer.
Its stock track and thumb are visually transparent. A single Canvas draws:

- the inactive rounded track;
- the active track;
- a thicker fluid-shaped current position;
- smooth curved shoulders joining the thick position to the track.

Because the visual track and thumb are one drawing, there is no Material thumb
gap or anti-aliased seam. During dragging, the thick position stretches in the
movement direction and compresses slightly across the track. On release it
returns with a short underdamped spring. No glow, blur, shader, or repeating
animation is used.

The pen-width button and eraser button both expand on a single tap. Finishing a
drag, tapping another control, or beginning a stroke collapses the active
control with the same spring. The expanded eraser control retains the clear-all
action. Clear-all still requires the deliberate sequence of opening the
control and pressing its destructive icon.

## Infinite canvas persistence and history

Undo and redo continue to operate on whole strokes. Panning, zooming, and hover
do not enter stroke history. Viewport changes are persisted separately and may
be coalesced so each gesture does not write repeatedly. Stroke data remains
vector-only during editing; no full-canvas bitmap is allocated.

## PNG export

An infinite canvas has no fixed page, so export is content-bounded:

1. find candidate bounds from non-eraser strokes;
2. add enough margin for stroke radii;
3. render pen and eraser strokes in order with the shared transform;
4. detect remaining non-white pixels after erasing;
5. crop to those pixels plus a consistent white margin;
6. encode PNG.

The short edge or content scale targets at least the current 1600-pixel quality
for ordinary notes. The long edge grows adaptively up to 4096 pixels while
preserving aspect ratio. Empty documents do not create attachments. Extremely
large content is proportionally reduced before bitmap allocation.

Single-point strokes use half the effective stroke width as their radius, the
same as the live renderer.

## Attachment-only resend

The current edit action is unusable for an attachment-only message because the
confirmation path rejects blank text. Message actions change as follows:

- user message with text: show `수정`;
- user message with an attachment and no text: show `다시 보내기`;
- resend reuses the original attachment;
- the conversation is truncated after that message;
- AI response generation restarts from that point;
- failed-message retry and attachment-only resend share the same internal
  resend-from-message operation.

Deleting and copying retain their current behavior. Copying an attachment-only
message may copy an empty string but does not affect resend availability.

## Error handling

- Invalid legacy coordinates are clamped or skipped per point; one malformed
  stroke must not make the document unreadable.
- A singular or non-finite viewport transform resets to the default viewport.
- Export failure leaves the vector document intact and shows the existing
  attachment-generation warning.
- A gesture cancellation clears active stylus and hover state without storing
  a partial navigation gesture as ink.

## Test strategy

Pure unit tests cover:

- legacy normalized-to-world migration;
- world/screen transform round trips;
- panel resize invariance;
- focal-point-preserving zoom;
- fixed-width rendering independent of pressure;
- eraser width parity between live and export transforms;
- hover diameter at multiple zoom levels;
- stylus/finger/palm routing;
- content-bound and margin calculations;
- empty and erased-content export behavior;
- toolbar expansion/collapse transitions;
- attachment-only resend and conversation truncation.

Android verification covers the full tablet unit suite and release build.
Physical Galaxy Tab verification covers S Pen drawing, barrel-button erasing,
hover cursor alignment, one-finger pan, two-finger pan/zoom, panel resizing,
undo/redo, PNG visual parity, and attachment-only resend.

## Completion criteria

- Screen and sent PNG show the same erased result.
- Existing ink never scales merely because the panel is resized.
- Stylus ink remains aligned after arbitrary pan and zoom.
- Finger gestures cannot create strokes.
- Eraser hover matches the actual erased footprint.
- Pen lines have constant selected width regardless of pressure.
- Pen and eraser sliders have no center seam and visibly deform and rebound.
- Existing saved notes reopen after migration.
- Export crops to remaining content with white margin and bounded resolution.
- Attachment-only messages can be resent from their original conversation
  point.
