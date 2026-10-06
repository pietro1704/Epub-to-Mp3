# Deploy & Verify

After every iOS build, always: build → install → **launch** on the physical iPhone. Never stop at just build or install.

```bash
# 1. Generate project
cd /Users/pietropugliesi/Developer/Epub-to-Mp3/ios/EpubToMp3
xcodegen generate

# 2. Build
xcodebuild \
  -project EpubToMp3.xcodeproj \
  -scheme EpubToMp3 \
  -configuration Debug \
  -destination 'platform=iOS,id=00008140-001128A022BA801C' \
  -derivedDataPath .build \
  build 2>&1 | tail -5

# 3. Install
xcrun devicectl device install app \
  --device 00008140-001128A022BA801C \
  .build/Build/Products/Debug-iphoneos/EpubToMp3.app 2>&1 | tail -5

# 4. Launch
xcrun devicectl device process launch \
  --device 00008140-001128A022BA801C \
  com.pietrocode.epubtomp3 2>&1 | tail -5
```

Only declare a fix done after the user confirms on-device.
