# M12 notes — Camera (B2)

Scope (design §7.2 M12, slice B2): the `+` menu's Camera entry. One photograph through the system
camera picker lands in the composer like any photo from the library — the ordinary attachment
import shrinks it, bounds it and shows its chip. Out of this slice: video capture, and B3 (the
outbox) entirely.

**Status: verified offline and on the emulator; the shutter itself belongs to a real-device pass.**
The contract suite, codegen, both builds and the repository checks ran green in this worktree, the
new hypium describe ran 3/3 on the emulator, and the walkthrough below was driven on it. The
emulator image has no system camera app at all, so a real shot — the photo bytes, the saveUri
write, the cancel without residue — is recorded here as the documented platform contract, not as
an observed device fact.

## What ships

| Layer | File | What it does |
| --- | --- | --- |
| capture | `thread/camera-capture.ets` | one photo through `cameraPicker.pick` into a sandbox draft file: the capability gate, the pre-created `saveUri`, the cancel/failure cleanup, the test seams (`setCameraPickerForTest`, `setCameraCapabilityForTest`) |
| UI | `features/chat/ThreadPage.ets` (extended) | the Camera menu entry (between Photo library and File, mobile's order and msgids), `pickFiles('photos' \| 'files' \| 'camera')`, the capture file dropped once the import has read it |
| tests | `ohosTest/ets/test/CameraCapture.test.ets`, `List.test.ets` | the capture contract over a scripted picker: no capability answers null without calling the picker; a cancel leaves no capture file; a successful shot returns the JPEG source and it feeds `importAttachmentSources` unchanged |

## The capability probe (before any product code)

The probes ran as temporary app/hypium code and were deleted afterwards; the findings below are
what the shipped code relies on.

| Probe | Finding |
| --- | --- |
| P1 `canIUse('SystemCapability.Multimedia.Camera.Core')` | **true** on the emulator, in both the hypium process and the app process |
| P2 `pick()` without `ohos.permission.CAMERA` | no permission error surfaces: the app (permission undeclared) calls `pick` and gets no 201-style rejection. The call fails within a millisecond with the picker resolving nothing (`Cannot read property resultCode of undefined`) — see P5. The CameraPicker guide settles the question outright: 应用可调用CameraPicker拍摄照片或录制视频，**无需申请相机权限** — the picker's UI is the system's own, and the user's shutter press is the consent |
| P3 permission prompt | `requestPermissionsFromUser(['ohos.permission.CAMERA'])` from the EntryAbility context with the permission undeclared answers `authResults=[2]` with no dialog. Moot: the permission is not declared, so no `camera_reason` resource was added to module.json5 or the string tables |
| P4 `saveUri` into the sandbox | the picker never starts here (P5), so the write itself is not observable on the emulator. The contract is the CameraPicker guide's: the sandbox file must **exist and be writable** before the pick, the passed URI grants the system camera read/write on it, and the camera overwrites it at the end of the shot. The shipped code pre-creates `${cacheDir}/attachment-drafts/<nonce>.jpg` and passes `fileUri.getUriFromPath(path)` |
| P5 the emulator's camera | **the emulator cannot photograph.** `bm dump -a` lists no camera bundle, and both `pick` attempts (with and without `saveUri`) resolve to nothing in ~1 ms with no camera UI. `canIUse` answers true regardless, so the entry shows and the failure surfaces as the composer's attach error |
| SDK quirk | `cameraPicker.PickerProfile`'s fields are read-only in the runtime (`Cannot assign to read only property` on `profile.cameraPosition = …`); the guide's object literal (`const profile: PickerProfile = { … }`) is the way |

## Key decisions

- **No permission, no reason strings.** The CameraPicker guide names no permission, and the probe
  confirmed no rejection without one. module.json5 and the three string tables are untouched.
- **The photo never reaches the media library.** The d.ts is explicit: without `saveUri` the shot
  is saved into the user's gallery. Capture always pre-creates a sandbox file in the attachment
  drafts directory and passes its URI, so the app's sandbox holds the only copy. The caller
  removes the capture file once the import has read it, and the cold-start sweep already clears
  that directory, so nothing lingers either way.
- **The capture imports like a library photo.** `capturePhoto` returns an `AttachmentSource`
  (`image/jpeg`, named `photo-<timestamp>.jpg` like mobile's `photoName`); the composer feeds it
  through the same `importAttachmentSources(..., photos=true, ...)` as the photo-library picker, so
  shrinking, type inference and the byte/count limits are one code path, not a camera-specific one.
- **A device without a camera hides the entry and answers null.** `cameraCaptureAvailable()`
  (`canIUse`) gates the menu item; `capturePhoto` checks it first and returns null without opening
  anything. A non-zero result (the SDK documents `-1` as a failure; a cancel reaches here too) also answers null after deleting the pre-created file; a
  picker failure deletes it and throws the composer's `Could not attach files`.
- **The picker sits behind a seam, M7-style.** `setCameraPickerForTest` swaps the pick function,
  `setCameraCapabilityForTest` answers the capability question; both reset to the real device.

## Verification

| Gate | Result |
| --- | --- |
| `pnpm --filter @rakazo/harmony harmony:codegen` | regenerated with no diff in tracked files |
| `pnpm exec vitest run apps/harmony/contract` | **195 / 195** (20 files) |
| `pnpm checks` | all green (172) |
| `devecocli build`, `devecocli build --modules entry@ohosTest` | both **BUILD SUCCESSFUL**; **no ArkTS warning in any file changed here** |
| hypium on the emulator | `CameraCapture` **3 / 3**; the full suite **299 / 299** (0 failures, 0 errors) |
| device walkthrough | the `+` menu shows 相册 / 相机 / 文件 (`m12-camera-menu`); tapping 相机 on this emulator reports 无法添加附件 above the composer and the sandbox holds no leftover capture file (`m12-camera-error`) |

"No warning in a changed file" is not "no warning in the build": the six remaining ones are the
M0/M1/M3 files earlier notes list (`asset-store.ets:56`, `server-store.ets:33` and `:34`,
`sse.ets:200`, `consent-dialog.ets:56` twice), untouched here, plus `SseSmoke.test.ets:33` (M0) in
the test build.

Screenshots in `apps/harmony/screenshots/`: `m12-camera-menu.png` (the menu with the Camera
entry), `m12-camera-error.png` (the emulator's honest failure, the attach error notice).

## Known gaps

- **The shutter is unverified by this round.** The emulator has no camera app, so the four real
  device facts are open: the picker's UI appears and accepts a shot; the photo lands in the
  pre-created sandbox file (P4's write); a cancel leaves no file; a real photo then travels the
  import into a sent image message. Everything in the app's own control (the gate, the file
  lifecycle, the import leg) is covered by the scripted-picker suite; what remains is the system
  side of the documented contract.
- **A device that reports the capability but cannot start the picker** (this emulator) shows the
  composer's `Could not attach files` rather than a hidden entry. The capability probe answers
  true on any camera-capable system image, so a menu-driven failure can only mean the picker
  failed to start; distinguishing "no camera app" from a transient failure would need a system
  API that does not exist.
