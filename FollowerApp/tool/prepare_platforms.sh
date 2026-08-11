#!/usr/bin/env bash
#
# Generates the Flutter platform shells for the Trio Follower app and applies
# every platform patch the app needs, so neither CI nor a local build has to
# do any manual Xcode/AndroidManifest editing:
#
#   iOS:     camera + Face ID usage strings, remote-notification background
#            mode, aps-environment entitlements file
#   Android: USE_BIOMETRIC permission, FlutterFragmentActivity (required by
#            local_auth), optional google-services.json from the
#            FOLLOWER_GOOGLE_SERVICES_JSON environment variable (FCM status
#            pushes)
#
# Idempotent: safe to re-run at any time.

set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> flutter create (platform shells)"
flutter create . --platforms=ios,android --project-name trio_follower --org org.nightscout

# flutter create drops a counter-app template test that references a MyApp
# widget this app doesn't have; it would break `flutter test`/`analyze`.
if [ -f test/widget_test.dart ] && grep -q 'MyApp' test/widget_test.dart; then
  rm test/widget_test.dart
fi

# --- iOS ---------------------------------------------------------------------

if [ -f ios/Runner/Info.plist ]; then
  echo "==> Patching ios/Runner/Info.plist"
  python3 - <<'PY'
import plistlib

path = 'ios/Runner/Info.plist'
with open(path, 'rb') as f:
    plist = plistlib.load(f)

plist.setdefault('NSCameraUsageDescription',
                 'Scan the pairing QR code shown on the Trio host.')
plist.setdefault('NSFaceIDUsageDescription',
                 'Confirm remote commands before they are sent.')
modes = plist.setdefault('UIBackgroundModes', [])
if 'remote-notification' not in modes:
    modes.append('remote-notification')

with open(path, 'wb') as f:
    plistlib.dump(plist, f)
print('Info.plist patched')
PY

  echo "==> Writing ios/Runner/Runner.entitlements"
  cat > ios/Runner/Runner.entitlements <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>aps-environment</key>
	<string>development</string>
</dict>
</plist>
EOF
fi

# --- Android -----------------------------------------------------------------

MANIFEST=android/app/src/main/AndroidManifest.xml
if [ -f "$MANIFEST" ]; then
  if ! grep -q 'android.permission.USE_BIOMETRIC' "$MANIFEST"; then
    echo "==> Adding USE_BIOMETRIC permission to AndroidManifest.xml"
    # Insert the permission right after the opening <manifest ...> tag.
    python3 - <<'PY'
import re

path = 'android/app/src/main/AndroidManifest.xml'
with open(path) as f:
    content = f.read()

permission = '    <uses-permission android:name="android.permission.USE_BIOMETRIC" />\n'
content = re.sub(r'(<manifest[^>]*>\n)', r'\1' + permission, content, count=1)

with open(path, 'w') as f:
    f.write(content)
print('AndroidManifest.xml patched')
PY
  fi
fi

# local_auth needs FlutterFragmentActivity instead of FlutterActivity.
MAIN_ACTIVITY=$(find android/app/src/main -name 'MainActivity.kt' 2>/dev/null | head -1 || true)
if [ -n "${MAIN_ACTIVITY:-}" ] && grep -q 'FlutterActivity' "$MAIN_ACTIVITY" && ! grep -q 'FlutterFragmentActivity' "$MAIN_ACTIVITY"; then
  echo "==> Switching MainActivity to FlutterFragmentActivity"
  sed -i.bak 's/FlutterActivity/FlutterFragmentActivity/g' "$MAIN_ACTIVITY" && rm -f "$MAIN_ACTIVITY.bak"
fi

# Some plugins (e.g. push) still pin an old compileSdk that current AndroidX
# libraries reject; force every Android subproject to a modern compileSdk.
python3 - <<'PY'
import os

MARKER = 'Force plugin subprojects to a modern compileSdk'

kts = 'android/build.gradle.kts'
groovy = 'android/build.gradle'

if os.path.exists(kts):
    with open(kts) as f:
        content = f.read()
    if MARKER not in content:
        content += '''
// Force plugin subprojects to a modern compileSdk (some plugins still pin an
// old one that current AndroidX libraries no longer accept).
fun forceCompileSdk(project: org.gradle.api.Project) {
    project.extensions.findByName("android")?.let { androidExt ->
        val methods = androidExt.javaClass.methods
        val setCompileSdk = methods.firstOrNull { it.name == "setCompileSdk" }
        val compileSdkVersion = methods.firstOrNull {
            it.name == "compileSdkVersion" && it.parameterTypes.size == 1 &&
                it.parameterTypes[0] == Int::class.javaPrimitiveType
        }
        if (setCompileSdk != null) {
            setCompileSdk.invoke(androidExt, 36)
        } else {
            compileSdkVersion?.invoke(androidExt, 36)
        }
    }
}
subprojects {
    // The Flutter template forces early evaluation of :app, so afterEvaluate
    // would throw "project is already evaluated" there — apply immediately in
    // that case.
    if (state.executed) forceCompileSdk(this) else afterEvaluate { forceCompileSdk(this) }
}
'''
        with open(kts, 'w') as f:
            f.write(content)
        print('compileSdk override appended to build.gradle.kts')
elif os.path.exists(groovy):
    with open(groovy) as f:
        content = f.read()
    if MARKER not in content:
        content += '''
// Force plugin subprojects to a modern compileSdk (some plugins still pin an
// old one that current AndroidX libraries no longer accept).
def forceCompileSdk = { project ->
    if (project.hasProperty("android")) {
        project.android.compileSdkVersion 36
    }
}
subprojects { project ->
    if (project.state.executed) {
        forceCompileSdk(project)
    } else {
        project.afterEvaluate { forceCompileSdk(it) }
    }
}
'''
        with open(groovy, 'w') as f:
            f.write(content)
        print('compileSdk override appended to build.gradle')
PY

# Optional: Firebase config for FCM status pushes on Android. CI provides the
# file contents via a secret; local builds can drop the file in manually.
if [ -n "${FOLLOWER_GOOGLE_SERVICES_JSON:-}" ]; then
  echo "==> Writing android/app/google-services.json from environment"
  printf '%s' "$FOLLOWER_GOOGLE_SERVICES_JSON" > android/app/google-services.json
fi

if [ -f android/app/google-services.json ]; then
  echo "==> Enabling google-services Gradle plugin"
  python3 - <<'PY'
import os, re

settings = 'android/settings.gradle'
app = 'android/app/build.gradle'
# Newer Flutter templates use the declarative plugins block in .kts files.
if not os.path.exists(settings):
    settings = 'android/settings.gradle.kts'
if not os.path.exists(app):
    app = 'android/app/build.gradle.kts'

with open(settings) as f:
    content = f.read()
if 'com.google.gms.google-services' not in content:
    content = re.sub(
        r'(id[ (]"dev\.flutter\.flutter-plugin-loader"[^\n]*\n)',
        r'\1    id("com.google.gms.google-services") version "4.4.2" apply false\n',
        content, count=1)
    with open(settings, 'w') as f:
        f.write(content)

with open(app) as f:
    content = f.read()
if 'com.google.gms.google-services' not in content:
    content = re.sub(
        r'(id[ (]"dev\.flutter\.flutter-gradle-plugin"[^\n]*\n)',
        r'\1    id("com.google.gms.google-services")\n',
        content, count=1)
    with open(app, 'w') as f:
        f.write(content)
print('Gradle plugin wired')
PY
fi

echo "==> Done. Build with: flutter run | flutter build apk | flutter build ios"
