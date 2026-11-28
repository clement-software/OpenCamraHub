#!/bin/bash
# Builds and signs OpenCamraHub Webcam with the Android SDK's own tools: no
# Gradle and no dependencies. Prints the path of the APK.
#
#   brew install openjdk@17 && brew install --cask android-commandlinetools
#   sdkmanager 'platforms;android-34' 'build-tools;34.0.0'
set -euo pipefail

sdk=${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}
java_home=${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}
tools=$sdk/build-tools/34.0.0
platform=$sdk/platforms/android-34/android.jar
export PATH=$java_home/bin:$PATH

for needed in "$tools/aapt2" "$tools/d8" "$tools/zipalign" "$tools/apksigner" "$platform" "$java_home/bin/javac"; do
  [[ -e $needed ]] || { echo "Missing $needed; see the top of $0." >&2; exit 1; }
done

cd "$(dirname "$0")"
rm -rf build
mkdir -p build/classes

# The lambda stubs stand in for the java.lang.invoke classes android.jar lacks;
# d8 then removes the lambdas.
javac -source 8 -target 8 -bootclasspath "$platform:$tools/core-lambda-stubs.jar" -Xlint:-options \
  -d build/classes \
  $(find src -name '*.java')
"$tools/d8" --lib "$platform" --min-api 28 --output build $(find build/classes -name '*.class')
"$tools/aapt2" link -I "$platform" --manifest AndroidManifest.xml -o build/unsigned.apk
(cd build && zip -q unsigned.apk classes.dex)
"$tools/zipalign" -f 4 build/unsigned.apk build/aligned.apk

# The SDK's usual debug key, so a later Android Studio build installs over this one.
keystore=$HOME/.android/debug.keystore
if [[ ! -f $keystore ]]; then
  mkdir -p "$(dirname "$keystore")"
  keytool -genkeypair -keystore "$keystore" -storepass android -alias androiddebugkey \
    -keypass android -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Android Debug,O=Android,C=US"
fi
"$tools/apksigner" sign --ks "$keystore" --ks-pass pass:android \
  --out build/OpenCamraHubWebcam.apk build/aligned.apk
echo "$PWD/build/OpenCamraHubWebcam.apk"
