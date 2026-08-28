# Android Phone Attachment Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose photo-library, camera, and PDF attachment actions from the Android phone chat input and produce a verified phone debug APK.

**Architecture:** Reuse the existing activity-result launchers and `readAttachment` pipeline. Give `ChatInputBar` an exact phone action list and render the existing popover for both layouts; tablet alone retains `INK`.

**Tech Stack:** Kotlin, Jetpack Compose, Android Activity Result APIs, JUnit, Gradle Android plugin

**Spec:** `docs/superpowers/specs/2026-08-28-android-phone-attachment-menu-design.md`

## Global Constraints

- Phone actions are exactly `PHOTO_LIBRARY`, `CAMERA`, `PDF` in that order.
- Tablet actions remain exactly `PHOTO_LIBRARY`, `CAMERA`, `PDF`, `INK`.
- Preserve one pending attachment, existing Korean errors, 12 MiB source limit, picker callbacks, and AI payload behavior.
- Do not install the APK, clear app data, change sync/R2 code, add permissions, add dependencies, or change lockfiles.
- Preserve unrelated dirty and untracked files; do not push or merge.

---

### Task 1: Phone attachment action menu and APK

**Files:**
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/ChatRoomInputBar.kt`
- Modify: `android/app/src/test/java/com/sapiens/gagaodok/TabletAttachmentActionsTest.kt`

**Interfaces:**
- Consumes: existing `AttachmentAction`, `AttachmentPopover`, and callbacks `onPickImage`, `onTakePhoto`, `onPickPdf`, `onOpenInk`
- Produces: `phoneAttachmentActions(): List<AttachmentAction>` and layout-selected popover actions

- [x] **Step 1: Write the failing phone action-list test**

```kotlin
@Test
fun `phone offers photo camera and pdf without ink`() {
    assertEquals(
        listOf(AttachmentAction.PHOTO_LIBRARY, AttachmentAction.CAMERA, AttachmentAction.PDF),
        phoneAttachmentActions()
    )
}
```

- [x] **Step 2: Run the focused test and verify RED**

Run with the repository-required JDK:

```bash
cd android
./gradlew :app:testPhoneDebugUnitTest --tests com.sapiens.gagaodok.TabletAttachmentActionsTest
```

Expected: compilation failure because `phoneAttachmentActions` does not exist.

- [x] **Step 3: Implement the minimal phone action list and shared popover**

Add:

```kotlin
internal fun phoneAttachmentActions(): List<AttachmentAction> = listOf(
    AttachmentAction.PHOTO_LIBRARY,
    AttachmentAction.CAMERA,
    AttachmentAction.PDF
)
```

Select `tabletAttachmentActions()` or `phoneAttachmentActions()` from `enhancedAttachments`, always render the existing `+` button and `AttachmentPopover`, and retain the existing callback mapping. Only the tablet list may contain `INK`.

- [x] **Step 4: Run the focused test and verify GREEN**

```bash
cd android
./gradlew :app:testPhoneDebugUnitTest --tests com.sapiens.gagaodok.TabletAttachmentActionsTest
```

Expected: focused test class passes.

- [x] **Step 5: Run the affected phone unit suite and static diff check**

```bash
cd android
./gradlew :app:testPhoneDebugUnitTest
cd ..
git diff --check -- android/app/src/main/java/com/sapiens/gagaodok/ui/screens/ChatRoomInputBar.kt android/app/src/test/java/com/sapiens/gagaodok/TabletAttachmentActionsTest.kt
```

Expected: phone-debug unit tests pass and diff check is silent.

- [x] **Step 6: Build and identify the phone debug APK**

```bash
cd android
./gradlew :app:assemblePhoneDebug
find app/build/outputs/apk/phone/debug -maxdepth 1 -type f -name '*.apk' -print
```

Expected: Gradle exits successfully and prints one local APK path. Do not install it.

- [x] **Step 7: Commit the scoped implementation**

```bash
git add android/app/src/main/java/com/sapiens/gagaodok/ui/screens/ChatRoomInputBar.kt android/app/src/test/java/com/sapiens/gagaodok/TabletAttachmentActionsTest.kt docs/superpowers/plans/2026-08-28-android-phone-attachment-menu.md
git commit -m "feat(android): 폰 첨부 메뉴에 카메라와 PDF를 연다"
```
