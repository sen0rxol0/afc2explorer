# AFC2 Utility – Technical Reference

## Architecture Overview

```
AppDelegate
└── MainWindowController
    ├── MacBrowserViewController     (left pane – Mac filesystem)
    ├── iPadBrowserViewController    (right pane – iPad filesystem)
    ├── TransferPanelViewController  (bottom – live queue)
    └── DeviceManager (singleton)
        └── AFC2Client
            └── TransferEngine
```

### Threading model

| Layer | Queue |
|---|---|
| libimobiledevice C callbacks | usbmuxd background thread |
| DeviceManager.connectionQueue | Serial, private (`com.afc2util.device`) |
| AFC2Client.queue | Serial, private (`com.afc2util.afc2client`) |
| TransferEngine.queue | NSOperationQueue, maxConcurrent=1 |
| All UI / notifications | Main queue (always dispatched via `dispatch_async(main)`) |

The main thread **never** blocks on I/O.

---

## Component Descriptions

### DeviceManager
- Subscribes to `idevice_event_subscribe` on launch.
- On USB plug: performs lockdown handshake → starts `com.apple.afc2` → creates `AFC2Client`.
- On USB unplug: calls `AFC2Client.invalidate`, posts `DeviceDidDisconnectNotification`.
- Reconnection is automatic: the next plug event triggers a fresh connect cycle.

### AFC2Client
Thin Objective-C wrapper around `libafc`. All calls are serialised onto its private serial queue then complete via a main-thread callback. Owns the `afc_client_t` and `idevice_t` handles.

Key methods:
- `listDirectory:completion:` – calls `afc_read_directory` then `afc_get_file_info` for each entry.
- `uploadLocalFile:toDevicePath:progress:completion:` – chunked 256 KB reads from `FILE*`, writes via `afc_file_write`.
- `downloadDeviceFile:toLocalPath:progress:completion:` – chunked reads via `afc_file_read`.
- `deletePath:recursive:completion:` – recursive delete walks the tree with `afc_read_directory`.
- `invalidate` – safe to call multiple times; subsequent API calls return "device disconnected" error.

### TransferEngine
- Wraps `AFC2Client` operations into `TransferItem` objects queued on an `NSOperationQueue`.
- **Serial queue** (maxConcurrent=1) prevents USB 2.0 saturation from concurrent reads+writes.
- **Retry logic** – up to 3 retries with exponential backoff on transient I/O errors.
- **Cancellation** – each `NSBlockOperation` is held weakly; `TransferItem.cancel` cancels the op.
- Broadcasts `TransferEngineItemDidUpdateNotification` after every state change for UI binding.

### FileSafetyLayer
Two tiers of protection:

| Tier | Paths | Behaviour |
|---|---|---|
| **Hard block** | `/System /bin /usr /sbin /boot /dev` | Returns `NSError`; operation never executes |
| **Soft warn** | `/Library /etc /private` + root-level paths | Caller must call `presentConfirmationForPath:action:` and check return |

All path checks normalise via `stringByStandardizingPath` to prevent `/../` bypass attempts.

---

## Xcode Project Setup

1. Run `Scripts/bootstrap.sh` to install dependencies and copy dylibs.

2. Create a new **macOS > App** project in Xcode:
   - Language: Objective-C
   - Organisation Identifier: `com.yourname`
   - Bundle ID: `com.yourname.AFC2Utility`
   - Uncheck "Create Git repository", "Include Tests"

3. Add all `.h` / `.m` files from `Source/` to the target.

4. **Build Settings**:
   ```
   HEADER_SEARCH_PATHS = $(SRCROOT)/Frameworks/libimobiledevice/include
                         /opt/homebrew/include          (Apple Silicon)
                         /usr/local/include             (Intel)
   OTHER_LDFLAGS       = -L$(SRCROOT)/AFC2Utility/Frameworks
                         -limobiledevice-1.0
                         -lusbmuxd-2.0
                         -lplist-2.0
   LD_RUNPATH_SEARCH_PATHS = @executable_path/../Frameworks
   ENABLE_HARDENED_RUNTIME = YES
   CODE_SIGN_ENTITLEMENTS  = Resources/AFC2Utility.entitlements
   MACOSX_DEPLOYMENT_TARGET = 10.13
   ```

5. Add the three `.dylib` files from `AFC2Utility/Frameworks/` as **Copy Files** build phase
   (Destination: Frameworks).

6. Set `Info.plist` path to `Resources/Info.plist`.

---

## Notarization Checklist

### Before submission
- [ ] Valid Apple Developer account with active certificate.
- [ ] App signed with **Developer ID Application** certificate (not Mac Developer).
- [ ] Hardened runtime enabled (`ENABLE_HARDENED_RUNTIME = YES`).
- [ ] All entitlements in `.entitlements` are legitimate and minimal.
- [ ] No private API symbols (`nm -u AFC2Utility.app/Contents/MacOS/AFC2Utility | grep _SPI`).
- [ ] All bundled dylibs are also signed:
  ```bash
  codesign --sign "Developer ID Application: You (TEAMID)" \
           --timestamp --options runtime \
           AFC2Utility.app/Contents/Frameworks/*.dylib
  ```
- [ ] Sign the app bundle **after** signing dylibs:
  ```bash
  codesign --sign "Developer ID Application: You (TEAMID)" \
           --timestamp --options runtime \
           --entitlements Resources/AFC2Utility.entitlements \
           --deep AFC2Utility.app
  ```
- [ ] Verify signature: `codesign -vvv --deep AFC2Utility.app`
- [ ] Check for restricted entitlements with `codesign -d --entitlements :- AFC2Utility.app`.

### Submission
```bash
# Create a zip for notarization
ditto -c -k --keepParent AFC2Utility.app AFC2Utility.zip

# Submit (requires Xcode 13+ / notarytool)
xcrun notarytool submit AFC2Utility.zip \
      --apple-id your@email.com \
      --team-id YOURTEAMID \
      --password "@keychain:AC_PASSWORD" \
      --wait

# Staple the ticket
xcrun stapler staple AFC2Utility.app
```

### Known notarization gotchas with libimobiledevice
- `libimobiledevice` uses POSIX sockets to talk to `usbmuxd` — this is fine.
- The `com.apple.security.cs.disable-library-validation` entitlement is required because
  the Homebrew dylibs are signed by Homebrew, not by you. Without it, dylib loading fails
  under hardened runtime. Apple accepts this for utilities that explicitly bundle third-party dylibs.
- If notarization rejects due to unsigned dylibs, re-sign them all with your Developer ID.

---

## Performance Tuning

| Parameter | Location | Default | Notes |
|---|---|---|---|
| Chunk size | `AFC2Client.m:kChunkSize` | 256 KB | Increase to 512 KB for USB 3 hosts; decrease if stability issues |
| Max queue concurrency | `TransferEngine.m` | 1 | Keep at 1 for USB 2.0; iPad 2 saturates at ~12 MB/s |
| Max retries | `TransferEngine.m:kMaxRetries` | 3 | Increase for flaky cables |
| Retry backoff | `TransferEngine.m` | `1s × (retry+1)` | Linear; change to exponential if needed |

Expected throughput on USB 2.0: **8–14 MB/s** for sequential writes, **6–12 MB/s** reads.

---

## Error Reference

| Domain | Code | Meaning |
|---|---|---|
| `AFC2ClientErrorDomain` | -1 | Device disconnected (post-invalidate) |
| `AFC2ClientErrorDomain` | AFC_E_OBJECT_NOT_FOUND (8) | Path does not exist on device |
| `AFC2ClientErrorDomain` | AFC_E_PERM_DENIED (3) | Not jailbroken, or AFC2 not installed |
| `AFC2ClientErrorDomain` | AFC_E_IO_ERROR (6) | USB I/O error – retry or reconnect |
| `AFC2SafetyErrorDomain` | 1 | Write/delete blocked by FileSafetyLayer |
| `NSPOSIXErrorDomain` | errno | Local file I/O failure |

---

## Extending the App

### Add directory upload
In `iPadBrowserViewController.m`, after accepting a drop, check `isDirectory` on the dragged URL.
Recursively enumerate with `NSDirectoryEnumerator` and enqueue one `TransferItem` per file,
creating device directories first with `AFC2Client.createDirectory:completion:`.

### Add transfer speed display
In `TransferPanelViewController`, store a `lastBytes` + `lastTime` per item and compute
`(ΔBytes / Δtime)` in `itemUpdated:`. Display as an additional `NSTableColumn`.

### Add Bonjour/Wi-Fi support
Change the `idevice_new_with_options` call in `DeviceManager` to use `IDEVICE_LOOKUP_NETWORK`
or both flags. Note: AFC2 over Wi-Fi is significantly slower and less reliable.
