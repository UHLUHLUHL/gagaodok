# Android Phone Group Conversation and Relationship Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the approved Android phone relationship UI and natural multi-character group conversation as a size-optimized signed release APK.

**Architecture:** Gemini 3.7 Flash remains a single semantic planner for each group turn, while a deterministic local scheduler owns typing and reveal timing. Hidden transport markers are parsed into persistent message reactions and bounded affection deltas. A floating Compose overlay reproduces Figma concept 2 with one shared animation progress.

**Tech Stack:** Kotlin, coroutines/StateFlow, kotlinx.serialization, Jetpack Compose, JUnit 4, Gradle/R8

**Spec:** `docs/superpowers/specs/2026-08-24-group-chat-relationship-release-design.md`

## Global Constraints

- Android phone `COMPANION` only; do not alter tablet mentor or macOS behavior.
- Group turns use one Gemini 3.7 Flash request and no secondary model calls.
- Existing rooms use stored `baseAffection` (default 50); do not analyse old history.
- Preserve `turnId` and `canonicalText` grouping.
- All timing work is cancellable and all hidden markers remain invisible.
- Build the signed, minified `phoneRelease` artifact with JDK 17.

---

### Task 1: Protocol metadata and deterministic scheduler

**Files:**
- Create: `android/app/src/main/java/com/sapiens/gagaodok/service/GroupReplyScheduler.kt`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/service/GroupConversationProtocol.kt`
- Test: `android/app/src/test/java/com/sapiens/gagaodok/GroupConversationProtocolTest.kt`
- Test: `android/app/src/test/java/com/sapiens/gagaodok/GroupReplySchedulerTest.kt`

**Interfaces:**
- Produces `ParsedBubble.reactions: List<PlannedReaction>`.
- Produces `GroupReplyScheduler.plan(turnId, bubbles): List<GroupReplyEvent>` with typing-start, message and reaction events.

- [ ] Add failing protocol tests proving reaction markers are stripped, all participant participation is requested, and heart deltas clamp per participant to `-3..+3`.
- [ ] Add failing scheduler tests proving deterministic output, ordered reveals, overlapping typing windows, bounded durations and reaction-after-message ordering.
- [ ] Run the two focused test classes and confirm failures are caused by missing behavior.
- [ ] Implement the minimal parser, prompt rules and pure scheduler.
- [ ] Re-run the focused tests and confirm they pass.

### Task 2: Persistent reactions and personal affection

**Files:**
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/model/Message.kt`
- Create: `android/app/src/main/java/com/sapiens/gagaodok/service/PersonalAffectionProtocol.kt`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/data/ChatStore.kt`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/ChatRoomViewModel.kt`
- Test: `android/app/src/test/java/com/sapiens/gagaodok/PersonalAffectionProtocolTest.kt`
- Test: `android/app/src/test/java/com/sapiens/gagaodok/ConversationTurnTest.kt`

**Interfaces:**
- Adds serializable `MessageReaction(participantRoomId, emoji)` and `ChatMessage.reactions` with an empty default for backward compatibility.
- Produces `PersonalAffectionProtocol.systemPrompt(basePrompt)` and `parse/strip` helpers.
- Produces `ChatStore.adjustBaseAffection(roomId, delta)`.
- Exposes `typingParticipantIds: StateFlow<Set<UUID>>` from `ChatRoomViewModel`.

- [ ] Add failing tests for old-message compatibility, marker invisibility, `-3..+3` delta clamping and prompt non-censorship language.
- [ ] Run the focused tests and confirm expected failures.
- [ ] Implement persistent reactions, personal affection protocol and store mutation.
- [ ] Integrate group scheduling and personal completed-response affection into the ViewModel while preserving cancellation and canonical text.
- [ ] Re-run focused protocol, turn and ViewModel-adjacent pure tests.

### Task 3: Figma concept 2 Compose UI

**Files:**
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/GroupChatPanels.kt`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/ChatRoomScreen.kt`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/ChatRoomTyping.kt`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/ui/components/MessageBubble.kt`
- Test: `android/app/src/test/java/com/sapiens/gagaodok/GroupChatUiStateTest.kt`

**Interfaces:**
- Replaces `HeartGaugePanel` with a floating relationship overlay that also accepts personal-room participants.
- Replaces the single typing indicator input with a list of active participant presentations.
- Renders `ChatMessage.reactions` below incoming bubbles.

- [ ] Add or update pure UI-state tests proving personal gauge visibility and removal of duplicate worldline-pill state.
- [ ] Run the focused UI-state test and confirm it fails for the new behavior.
- [ ] Implement the neutral concept-2 card with a single 380 ms transition and no message-list remeasurement.
- [ ] Remove `WorldlinePill`, use the header worldline action only, render individual typing indicators and reaction chips, and convert app-authored group guidance to honorific Korean.
- [ ] Re-run focused UI-state tests and compile the phone debug variant.

### Task 4: Regression verification and release packaging

**Files:**
- Modify: `android/app/build.gradle.kts`
- Update: `docs/affection-event-criteria.md`

**Interfaces:**
- Produces the next `phone` version and a signed, minified `phoneRelease` APK.

- [ ] Update the phone version and the affection criteria document to match personal-room and bounded-delta behavior.
- [ ] Run `./gradlew --version` and confirm Gradle is using JDK 17.
- [ ] Run `./gradlew :app:testPhoneDebugUnitTest` and resolve all failures.
- [ ] Run `./gradlew :app:assemblePhoneRelease` once after coherent changes are complete.
- [ ] Verify APK package/version, signing, byte size and SHA-256; copy the release artifact to the requested delivery location with a versioned filename.
- [ ] Run `git diff --check`, review the focused diff and report remaining device-only motion risk if no device flow was available.
