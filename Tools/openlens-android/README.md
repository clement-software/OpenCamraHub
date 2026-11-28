# OpenCamraHub Webcam for Android

Streams one of an Android phone's cameras to OpenCamraHub over USB. Choose the
camera on the phone; OpenCamraHub lists the phone as **Android phone (USB)**.

The phone's hardware encoder sends H.264 at up to 1080p and 30 fps, and the
Mac's hardware decodes it. The app listens only on the phone's loopback
address, port 8765, which `adb forward` connects to the Mac's.

## Build and install

```bash
brew install openjdk@17
brew install --cask android-commandlinetools android-platform-tools
sdkmanager 'platforms;android-34' 'build-tools;34.0.0'
Tools/openlens-android/build.sh
adb install -r Tools/openlens-android/build/OpenCamraHubWebcam.apk
```

`build.sh` uses the SDK's own tools, with no Gradle and no dependencies, and
signs with the usual `~/.android/debug.keystore`, which it creates if needed.

## Use

1. On the phone, turn on **Developer options › USB debugging**, plug it in and
   allow the Mac.
2. Run `adb forward tcp:8765 tcp:8765`, again after every replug.
3. Open **OpenCamraHub Webcam** on the phone, hold it in landscape and pick a
   camera.
4. In OpenCamraHub, choose **Android phone (USB)** as the scene's camera.

Picking another camera on the phone switches the picture within a second. The
phone streams while the app is on screen, which keeps the screen on.

Apps that take the phone over USB for themselves, such as Camo Studio, switch
it into accessory mode, where `adb devices` lists nothing. Quit them first.
