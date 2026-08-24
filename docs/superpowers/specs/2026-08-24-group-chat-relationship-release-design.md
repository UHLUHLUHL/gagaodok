# Android Phone Group Conversation and Relationship Release Design

## Scope

This release affects only the Android phone `COMPANION` experience. It does not change the tablet mentor prompt, the macOS app, model routing outside group chat, or the explicit-cache token policy. Group chat continues to use exactly one Gemini 3.7 Flash request per user turn.

## Approved product behavior

### Relationship UI

- Personal rooms show the relationship control using `RoomProfile.baseAffection`; existing rooms begin from their already stored value, which defaults to 50. Existing history is not re-analysed.
- Group rooms show the active worldline's per-character values. Branching copies those values and subsequent changes remain worldline-local.
- The duplicate purple `WorldlinePill` is removed. The header subtitle remains `<count>명 · <worldline>`, and the top-right worldline icon remains the only worldline entry point.
- The approved Figma concept 2 is the visual source: a centered 84x36 collapsed neutral-surface chip and a 336x154 neutral-surface expanded card with individual rows.
- The control floats over the conversation. Expanding or collapsing it must not resize or reposition the message list.
- One shared animation progress drives bounds, corner radius, icon/labels, row opacity and chevron rotation. Do not combine `animateContentSize` with `AnimatedContent` size transforms.
- Motion target is the Figma Smart Animate prototype: 380 ms and cubic bezier `(0.22, 1, 0.36, 1)`. Reduced-motion users receive an effectively immediate state change.

### Group conversation choreography

- Gemini produces one ordered group turn. Every participant normally contributes; a participant may contribute only an emoji reaction when speech would be unnatural.
- The prompt requires participants to address or react to prior participant messages, not independently deliver parallel monologues to the user.
- Each participant may produce one speech bubble by default and at most one short follow-up. At least one participant speaks.
- The model chooses dialogue, order, dependencies and reaction intent. It never chooses millisecond timings.
- The local scheduler derives bounded delays from visible grapheme count, creates overlapping per-character typing windows, reveals messages in order, and applies reactions shortly after their target bubble appears.
- Scheduling must be cancellable on response cancellation, room/worldline rebinding or screen lifecycle cancellation. Timing jitter is deterministic for a response turn so recomposition does not change the schedule.
- Typing UI displays each active character with their own avatar and name. Multiple indicators may coexist and independently disappear as messages arrive.

### Reactions and persistence

- A group-only hidden marker attaches a participant reaction to the speech bubble containing the marker.
- Hidden speaker, heart and reaction markers never appear in visible bubble or narration text.
- Reactions are stored on `ChatMessage` so they survive relaunch and worldline switching. The visible UI is a small Kakao-style emoji chip below the target bubble.

### Affection changes

- Personal companion prompts may emit one hidden signed affection marker. The marker changes `baseAffection` only after a fully successful response.
- Group heart markers continue to affect only the request's worldline after a fully successful response.
- Per participant and per turn, applied deltas are clamped to `-3..+3`; stored values remain `0..100`.
- Routine conversation defaults to zero. Meaningful trust, care, conflict or boundary events may change the value. Sexual explicitness alone is neither a positive nor negative event.
- Affection metadata must not censor, shorten, soften or otherwise alter the visible roleplay response.

### Korean copy

- App-authored guidance, descriptions and confirmations use honorific Korean. Character dialogue retains each character's configured speech style.

### Release artifact

- Increment the phone app release version.
- Produce `phoneRelease` with R8 code shrinking and resource shrinking enabled.
- The delivered APK must be the signed release artifact, not a debug/universal APK. Report its exact byte size and SHA-256.

## Verification

- Unit-test marker stripping, participant coverage instructions, reaction parsing, affection clamping and deterministic scheduling.
- Run the phone debug unit-test suite, then `assemblePhoneRelease` under Gradle's JDK 17.
- Inspect the release APK with `apkanalyzer` or equivalent for package/version and compare its size against any available prior artifact without claiming a comparison when no baseline exists.
- Perform a real installed-device flow when an authorized connected device is available: existing personal room gauge, group expand/collapse without message movement, per-character typing, reaction persistence and worldline switching.
