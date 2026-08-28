# Android Phone Attachment Menu Design

## Goal

Expose the Android app's existing photo-library, camera-capture, and PDF attachment flows on the phone chat input bar. Keep tablet handwriting tablet-only and preserve the current single-pending-attachment behavior.

## Current state

- `ChatRoomScreen` already owns launchers for photo selection, camera capture, and PDF selection.
- `readAttachment` already accepts images and PDFs, applies the 12 MiB source limit, scales images, and creates `ChatAttachment`.
- `ChatInputBar` exposes the four-action attachment popover only when `enhancedAttachments` is true. `ChatRoomScreen` currently passes `tabletLayout`, so a phone receives only the direct photo-library button.
- No new Android permission, picker, storage model, or AI request format is required.

## Approved phone behavior

Replace the phone input bar's direct photo icon with the same `+` attachment-menu interaction used by the tablet. The phone menu contains exactly, in this order:

1. `사진` — existing photo-library launcher
2. `사진 촬영` — existing camera launcher
3. `파일` — existing PDF launcher

The phone menu does not contain `필기`. The tablet menu remains `사진`, `사진 촬영`, `파일`, `필기`.

Selecting an action dismisses the popover before launching the external picker or camera. Selection errors continue to use the existing Korean notices. A selected attachment continues to replace any earlier pending attachment, and the user may clear it before sending.

## Code boundary

- Change `ChatRoomInputBar.kt` to define a phone action list and render the attachment popover on both layouts.
- Keep `ChatRoomScreen.kt` launchers and callbacks unchanged unless a focused test proves a wiring defect.
- Extend the existing attachment-action unit test to assert the exact phone and tablet action lists and ordering.
- Do not change `ChatAttachment`, persistence, AI payloads, sync payloads, M05 Worker code, or R2 behavior in this feature.

## Verification and APK delivery gate

1. A unit test first fails because the phone action list does not exist or lacks camera/PDF.
2. The focused Android unit test passes with exact phone/tablet actions and ordering.
3. The affected phone-debug unit-test task passes under the repository's required JDK.
4. A local phone debug APK builds successfully.
5. No APK is installed and no app data is cleared. The verified APK artifact is then delivered to the user.

The APK does not depend on completing M05 cloud sync. It enables local phone attachment selection and the existing AI-send flow; cross-device attachment upload remains a separate M05/M06 integration gate.

## Non-goals

- Multiple simultaneous attachments
- Arbitrary non-PDF files
- Phone handwriting UI
- Background upload, R2 synchronization, remote deployment, or real-data migration
- Redesigning the input bar beyond replacing the phone attachment entry point
