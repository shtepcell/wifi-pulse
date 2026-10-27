# Compatibility

## Runtime and build requirements

`Package.swift` declares macOS 13 as the deployment target. `build-app.sh` reads that value when generating `LSMinimumSystemVersion`, rather than maintaining a separate minimum OS value.

Building the UI requires Xcode 26 or later with a macOS 26+ SDK because it references SwiftUI Liquid Glass. Those calls are guarded by `if #available(macOS 26.0, *)`; older systems use material and bordered-button fallbacks. A modern SDK is needed to compile even when its newer APIs are guarded at runtime.

The scripts use SwiftPM's native build system so the generated binaries honor the package deployment target. Newer Swift toolchains may print a deprecation notice for this build-system option; the produced binary's deployment target should be checked when changing toolchains.

## Verification boundary

- Runtime recording, native UI, fullscreen panel placement, and physical microphone key: tested on Apple Silicon with macOS 27.0.1.
- Compatibility builds target macOS 13 for Apple Silicon and Intel using the installed SDK. These detect unavailable API use and linking problems; they do not prove behavior on an older OS or Intel hardware.
- macOS 13–26 runtime behavior and Intel hardware still need direct validation. Keyboard availability depends on hardware and system settings.

No claim is made that older-runtime testing was performed.

## Repeatable compile checks

```sh
swift build --build-system native --disable-sandbox \
  --scratch-path work/compatibility-arm64 \
  --triple arm64-apple-macosx13.0 -c release -Xswiftc -warnings-as-errors

swift build --build-system native --disable-sandbox \
  --scratch-path work/compatibility-intel \
  --triple x86_64-apple-macosx13.0 -c release -Xswiftc -warnings-as-errors
```

The normal app build produces a binary for the host architecture; it is not a universal binary. Run the build on the intended architecture, or package a universal binary separately if distributing compiled releases.
