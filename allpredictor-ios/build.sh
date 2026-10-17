#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
SDK_VERSION=$(xcrun --sdk iphoneos --show-sdk-version)
mkdir -p build/Payload/AllPredictor.app
APP=build/Payload/AllPredictor.app
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK_PATH" -miphoneos-version-min=15.0 -fobjc-arc -fmodules -O2 main.m -framework UIKit -framework Foundation -framework WebKit -o "$APP/AllPredictor"
for SIZE in 120 180 152 167; do sips -z "$SIZE" "$SIZE" site-icon.png --out "$APP/Icon${SIZE}.png" >/dev/null; done
APP_PATH="$APP" SDK_VERSION="$SDK_VERSION" python3 - <<'PY'
import os, plistlib
p = dict(CFBundleDevelopmentRegion='ru',CFBundleDisplayName='AllPredictor',CFBundleExecutable='AllPredictor',CFBundleIdentifier='com.miuiproking.allpredictor.web',CFBundleInfoDictionaryVersion='6.0',CFBundleName='AllPredictor',CFBundlePackageType='APPL',CFBundleShortVersionString='1.0',CFBundleVersion='1',MinimumOSVersion='15.0',LSRequiresIPhoneOS=True,UIDeviceFamily=[1,2],CFBundleSupportedPlatforms=['iPhoneOS'],DTPlatformName='iphoneos',DTSDKName='iphoneos'+os.environ['SDK_VERSION'],UILaunchScreen={},UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'],UIStatusBarStyle='UIStatusBarStyleLightContent',UIViewControllerBasedStatusBarAppearance=False,LSApplicationQueriesSchemes=['tg'])
p['CFBundleIcons']={'CFBundlePrimaryIcon':{'CFBundleIconFiles':['Icon120','Icon180'],'UIPrerenderedIcon':False}}
p['CFBundleIcons~ipad']={'CFBundlePrimaryIcon':{'CFBundleIconFiles':['Icon152','Icon167'],'UIPrerenderedIcon':False}}
with open(os.environ['APP_PATH']+'/Info.plist','wb') as f: plistlib.dump(p,f,fmt=plistlib.FMT_BINARY)
PY
codesign --force --sign - "$APP"
cd build
zip -qry AllPredictor.ipa Payload
shasum -a 256 AllPredictor.ipa
