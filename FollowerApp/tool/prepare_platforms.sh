#!/usr/bin/env bash
#
# Generates the Flutter platform shells for the Trio Follower app and applies
# every platform patch the app needs, so neither CI nor a local build has to
# do any manual Xcode/AndroidManifest editing:
#
#   iOS:     camera + Face ID usage strings, remote-notification background
#            mode, the export compliance declaration TestFlight would otherwise
#            hold every build for, aps-environment + app group entitlements
#            file, and the home screen widget extension target
#   Android: USE_BIOMETRIC permission, FlutterFragmentActivity (required by
#            local_auth), the home screen widget provider, optional
#            google-services.json from the FOLLOWER_GOOGLE_SERVICES_JSON
#            environment variable (FCM status pushes)
#
# The iOS widget needs an app group, whose identifier carries the Apple team id,
# so set TEAMID to build it. Without TEAMID the iOS widget is skipped with a
# warning and everything else still works; the Android widget never needs it.
#
# Idempotent: safe to re-run at any time.

set -euo pipefail
cd "$(dirname "$0")/.."

# The follower shares Trio's app group rather than registering one of its own,
# so builders do not have to create a second group. Keep in sync with
# TRIO_APP_GROUP_ID in Config.xcconfig.
APP_GROUP_ID="group.org.nightscout.${TEAMID:-}.trio.trio-app-group"

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
plist['NSSupportsLiveActivities'] = True
# The host pushes a Live Activity update per CGM reading. Without this key the
# system holds those to its ordinary budget; with it, the user can also turn
# them back down in Settings, which is where that decision belongs.
plist['NSSupportsLiveActivitiesFrequentUpdates'] = True
# Export compliance, answered here rather than by hand in App Store Connect:
# without it every upload sits at "Missing Compliance" until someone answers
# the same question again. The answer matches Trio's own Info.plist, which is
# the app this one talks to: the encryption is AES-GCM and TLS from the
# platform's own libraries, used to protect this app's own data, which is
# exempt.
plist['ITSAppUsesNonExemptEncryption'] = False
modes = plist.setdefault('UIBackgroundModes', [])
if 'remote-notification' not in modes:
    modes.append('remote-notification')

with open(path, 'wb') as f:
    plistlib.dump(plist, f)
print('Info.plist patched')
PY

  echo "==> Writing ios/Runner/Runner.entitlements"
  if [ -n "${TEAMID:-}" ]; then
    cat > ios/Runner/Runner.entitlements <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>aps-environment</key>
	<string>development</string>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>${APP_GROUP_ID}</string>
	</array>
</dict>
</plist>
EOF
  else
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
fi

# --- iOS widget extension -----------------------------------------------------

if [ -f ios/Runner.xcodeproj/project.pbxproj ]; then
  if [ -z "${TEAMID:-}" ]; then
    echo "==> Skipping the iOS widget: TEAMID is not set, so the app group id is unknown"
  elif ! ruby -e "require 'xcodeproj'" >/dev/null 2>&1; then
    echo "==> Skipping the iOS widget: the xcodeproj gem is unavailable (run 'bundle install' at the repo root)"
  else
    echo "==> Installing the alert tones into the app bundle"
    mkdir -p ios/Runner/Sounds
    cp platform/sounds/*.wav ios/Runner/Sounds/

    echo "==> Installing the iOS widget extension sources"
    mkdir -p ios/TrioFollowerWidget
    for file in platform/ios/TrioFollowerWidget/*; do
      name=$(basename "$file")
      sed "s|__APP_GROUP_ID__|${APP_GROUP_ID}|g" "$file" > "ios/TrioFollowerWidget/$name"
    done

    # The Live Activity's attributes are compiled into both the widget extension
    # (which renders the activity) and the plugin pod (which starts it), from the
    # one source in platform/ios/Shared.
    cp platform/ios/Shared/*.swift ios/TrioFollowerWidget/
    cp platform/ios/Shared/*.swift platform/flutter_plugins/trio_live_activity/ios/Classes/

    ruby platform/ios/add_widget_target.rb "$APP_GROUP_ID"
  fi
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

  # Android 11 hides other apps from this one unless they are declared here,
  # so without this the suspension banner's call and message buttons quietly
  # do nothing on a modern phone - which is the one moment they exist for.
  if ! grep -q '<queries>' "$MANIFEST"; then
    echo "==> Declaring the dialer and messaging intents in AndroidManifest.xml"
    python3 - <<'QUERIES_PY'
import re

path = 'android/app/src/main/AndroidManifest.xml'
with open(path) as f:
    content = f.read()

queries = (
    '    <queries>\n        <intent>\n            <action android:name="android.intent.action.DIAL" />\n            <data android:scheme="tel" />\n        </intent>\n        <intent>\n            <action android:name="android.intent.action.VIEW" />\n            <data android:scheme="tel" />\n        </intent>\n        <intent>\n            <action android:name="android.intent.action.VIEW" />\n            <data android:scheme="sms" />\n        </intent>\n        <intent>\n            <action android:name="android.intent.action.SENDTO" />\n            <data android:scheme="smsto" />\n        </intent>\n    </queries>\n'
)
content = re.sub(r'(<manifest[^>]*>\n)', lambda m: m.group(1) + queries, content, count=1)

with open(path, 'w') as f:
    f.write(content)
print('AndroidManifest.xml queries patched')
QUERIES_PY
  fi
fi

# --- Android widget -----------------------------------------------------------

ANDROID_MAIN=android/app/src/main
if [ -d "$ANDROID_MAIN" ]; then
  echo "==> Installing the Android widget providers and resources"
  # Drop the sources next to MainActivity so they land in the app's package.
  PACKAGE_DIR=$(dirname "$(find "$ANDROID_MAIN/kotlin" -name 'MainActivity.kt' 2>/dev/null | head -1)")
  if [ -n "${PACKAGE_DIR:-}" ] && [ -d "$PACKAGE_DIR" ]; then
    cp platform/android/kotlin/*.kt "$PACKAGE_DIR/"
  else
    echo "    MainActivity.kt not found; skipping the widget providers"
  fi

  mkdir -p "$ANDROID_MAIN/res/layout" "$ANDROID_MAIN/res/xml" \
    "$ANDROID_MAIN/res/drawable" "$ANDROID_MAIN/res/values" "$ANDROID_MAIN/res/values-night" \
    "$ANDROID_MAIN/res/raw"
  cp -R platform/android/res/. "$ANDROID_MAIN/res/"

  # Alert tones. res/raw names may not carry an extension in the sound URI, so
  # the files keep their names and AlertChannels.kt refers to them without one.
  cp platform/sounds/*.wav "$ANDROID_MAIN/res/raw/"

  if [ -f "$ANDROID_MAIN/AndroidManifest.xml" ]; then
    echo "==> Registering the widget receivers in AndroidManifest.xml"
    python3 - <<'WIDGETS_PY'
import re

path = 'android/app/src/main/AndroidManifest.xml'
with open(path) as f:
    content = f.read()

# (class name, appwidget-provider xml, picker label)
WIDGETS = [
    ('GlucoseWidgetProvider', 'glucose_widget_info', 'widget_glucose_label'),
    ('TrendWidgetProvider', 'trend_widget_info', 'widget_trend_label'),
    ('LoopWidgetProvider', 'loop_widget_info', 'widget_loop_label'),
]

TEMPLATE = """        <receiver
            android:name=".{cls}"
            android:exported="false"
            android:label="@string/{label}">
            <intent-filter>
                <action android:name="android.appwidget.action.APPWIDGET_UPDATE" />
            </intent-filter>
            <meta-data
                android:name="android.appwidget.provider"
                android:resource="@xml/{info}" />
        </receiver>
"""

for cls, info, label in WIDGETS:
    block = TEMPLATE.format(cls=cls, info=info, label=label)
    pattern = r'[ \t]*<receiver[^>]*android:name="\.%s".*?</receiver>\n' % re.escape(cls)
    existing = re.search(pattern, content, re.DOTALL)
    if existing:
        # An earlier run of this script wrote this receiver without the picker
        # label; rewrite it rather than leaving the widget unlabelled.
        if existing.group(0) != block:
            content = content[:existing.start()] + block + content[existing.end():]
    else:
        content = content.replace('    </application>', block + '    </application>', 1)

with open(path, 'w') as f:
    f.write(content)
print('widget receivers registered')
WIDGETS_PY
  fi

  if [ -f "$ANDROID_MAIN/AndroidManifest.xml" ] && \
     ! grep -q 'AlertChannelsInitializer' "$ANDROID_MAIN/AndroidManifest.xml"; then
    echo "==> Registering the alert notification channels provider"
    python3 - <<'CHANNELS_PY'
path = 'android/app/src/main/AndroidManifest.xml'
with open(path) as f:
    content = f.read()

provider = '''        <provider
            android:name=".AlertChannelsInitializer"
            android:authorities="${applicationId}.alertchannels"
            android:exported="false"
            android:initOrder="100" />
'''

content = content.replace('    </application>', provider + '    </application>', 1)

with open(path, 'w') as f:
    f.write(content)
print('alert channels provider registered')
CHANNELS_PY
  fi
fi

# local_auth needs FlutterFragmentActivity instead of FlutterActivity.
MAIN_ACTIVITY=$(find android/app/src/main -name 'MainActivity.kt' 2>/dev/null | head -1 || true)
if [ -n "${MAIN_ACTIVITY:-}" ] && grep -q 'FlutterActivity' "$MAIN_ACTIVITY" && ! grep -q 'FlutterFragmentActivity' "$MAIN_ACTIVITY"; then
  echo "==> Switching MainActivity to FlutterFragmentActivity"
  sed -i.bak 's/FlutterActivity/FlutterFragmentActivity/g' "$MAIN_ACTIVITY" && rm -f "$MAIN_ACTIVITY.bak"
fi

# Some plugins (e.g. push) still pin an old compileSdk that current AndroidX
# libraries reject; force those plugin subprojects to a modern compileSdk.
python3 - <<'PY'
import os

# Delimits the block this script appends, so a re-run replaces an outdated
# version of it instead of leaving the stale one in place.
SENTINEL = '// >>> trio-follower: plugin compileSdk override (generated)'
# The pre-sentinel form of the block, so existing checkouts get migrated.
LEGACY_MARKER = '// Force plugin subprojects to a modern compileSdk'

# :app is deliberately left alone: the Flutter template's
# `subprojects { evaluationDependsOn(":app") }` force-evaluates it before this
# block runs, and AGP locks compileSdk as soon as it has been read, so assigning
# it again throws AgpDslLockedException. :app already gets a modern compileSdk
# from `flutter.compileSdkVersion` — only the plugin subprojects, which are
# still pending evaluation at this point, need patching.
KTS_BLOCK = SENTINEL + '''
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
    // Skip anything already evaluated (notably :app) — see the note above.
    if (!state.executed) afterEvaluate { forceCompileSdk(this) }
}
'''

GROOVY_BLOCK = SENTINEL + '''
def forceCompileSdk = { project ->
    if (project.hasProperty("android")) {
        project.android.compileSdkVersion 36
    }
}
subprojects { project ->
    // Skip anything already evaluated (notably :app) — see the note above.
    if (!project.state.executed) {
        project.afterEvaluate { forceCompileSdk(it) }
    }
}
'''


def patch(path, block):
    with open(path) as f:
        content = f.read()
    for marker in (SENTINEL, LEGACY_MARKER):
        index = content.find(marker)
        if index != -1:
            content = content[:index]
            break
    with open(path, 'w') as f:
        f.write(content.rstrip() + '\n\n' + block)
    print('compileSdk override written to ' + path)


if os.path.exists('android/build.gradle.kts'):
    patch('android/build.gradle.kts', KTS_BLOCK)
elif os.path.exists('android/build.gradle'):
    patch('android/build.gradle', GROOVY_BLOCK)
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
