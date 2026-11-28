package com.trsdn.openlens.phone;

import android.Manifest;
import android.app.Activity;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.params.OutputConfiguration;
import android.hardware.camera2.params.SessionConfiguration;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;
import android.util.Range;
import android.util.Size;
import android.util.SizeF;
import android.view.Surface;
import android.view.View;
import android.view.WindowManager;
import android.widget.LinearLayout;
import android.widget.RadioButton;
import android.widget.RadioGroup;
import android.widget.TextView;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.Collections;
import java.util.Locale;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * Streams one of the phone's cameras to OpenCamraHub on a Mac, over USB.
 *
 * <p>The phone listens on its own loopback address, which only {@code adb forward tcp:8765
 * tcp:8765} reaches: nothing is exposed on the Wi-Fi. Each message is a 4-byte big-endian length
 * followed by one buffer of the hardware H.264 encoder, in Annex B: the parameter sets first, then
 * one frame per message. The Mac's {@code AndroidStream} reads it.
 *
 * <p>The camera streams while this screen is open, which Android requires of a camera app without
 * a foreground service.
 */
public final class MainActivity extends Activity {
    private static final String TAG = "OpenCamraHub";
    private static final int PORT = 8765;
    private static final int MAX_WIDTH = 1920;
    private static final int FRAME_RATE = 30;
    private static final int BIT_RATE = 12_000_000;
    private static final String WAITING =
            "Waiting for OpenCamraHub.\n\nOn the Mac, run  adb forward tcp:8765 tcp:8765  and choose"
                    + " “Android phone (USB)” as the scene’s camera.";

    private CameraManager cameras;
    private SharedPreferences preferences;
    private TextView status;
    private volatile String cameraId;
    private Server server;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        cameras = getSystemService(CameraManager.class);
        preferences = getPreferences(MODE_PRIVATE);

        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        int padding = (int) (24 * getResources().getDisplayMetrics().density);
        layout.setPadding(padding, padding, padding, padding);
        status = new TextView(this);
        status.setTextSize(18);
        status.setPadding(0, 0, 0, padding);
        layout.addView(status);
        RadioGroup choices = new RadioGroup(this);
        layout.addView(choices);
        setContentView(layout);

        String[] ids;
        try {
            ids = cameras.getCameraIdList();
        } catch (CameraAccessException e) {
            ids = new String[0];
        }
        String saved = preferences.getString("camera", null);
        cameraId = Arrays.asList(ids).contains(saved) ? saved : ids.length > 0 ? ids[0] : null;
        for (String id : ids) {
            RadioButton choice = new RadioButton(this);
            choice.setId(View.generateViewId());
            choice.setTag(id);
            choice.setText(describe(id));
            choice.setTextSize(18);
            choices.addView(choice);
            if (id.equals(cameraId)) choices.check(choice.getId());
        }
        // A new camera needs a new encoder: dropping the Mac makes it reconnect to it.
        choices.setOnCheckedChangeListener(
                (group, checked) -> {
                    cameraId = (String) group.findViewById(checked).getTag();
                    preferences.edit().putString("camera", cameraId).apply();
                    if (server != null) server.dropClient();
                });
        if (ids.length == 0) status.setText("This phone offers no camera to apps.");
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            startServer();
        } else {
            requestPermissions(new String[] {Manifest.permission.CAMERA}, 1);
        }
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] permissions, int[] results) {
        if (results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED) {
            startServer();
        } else {
            status.setText("OpenCamraHub Webcam needs the camera permission to stream.");
        }
    }

    @Override
    protected void onPause() {
        super.onPause();
        if (server != null) {
            server.close();
            server = null;
        }
    }

    private void startServer() {
        if (server != null || cameraId == null) return;
        try {
            server = new Server();
            server.start();
        } catch (IOException e) {
            status.setText("Port " + PORT + " is not available: " + e.getMessage());
        }
    }

    private void setStatus(String text) {
        runOnUiThread(() -> status.setText(text));
    }

    /** "Back 0, 26 mm": the 35 mm equivalent tells the main camera from the wide and tele ones. */
    private String describe(String id) {
        try {
            CameraCharacteristics camera = cameras.getCameraCharacteristics(id);
            Integer facing = camera.get(CameraCharacteristics.LENS_FACING);
            String side =
                    facing == null
                            ? "Camera"
                            : facing == CameraCharacteristics.LENS_FACING_FRONT
                                    ? "Front"
                                    : facing == CameraCharacteristics.LENS_FACING_BACK ? "Back" : "External";
            float[] focal = camera.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS);
            SizeF sensor = camera.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE);
            if (focal == null || focal.length == 0 || sensor == null) return side + " " + id;
            double equivalent = focal[0] * 43.27 / Math.hypot(sensor.getWidth(), sensor.getHeight());
            return String.format(Locale.US, "%s %s, %.0f mm", side, id, equivalent);
        } catch (CameraAccessException e) {
            return "Camera " + id;
        }
    }

    /** The largest 16:9 size up to 1080p that the camera can hand an encoder. */
    private static Size videoSize(CameraCharacteristics camera) {
        StreamConfigurationMap map = camera.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
        Size best = new Size(1280, 720);
        if (map == null) return best;
        for (Size size : map.getOutputSizes(MediaCodec.class)) {
            boolean wide = size.getWidth() * 9 == size.getHeight() * 16;
            if (wide && size.getWidth() <= MAX_WIDTH && size.getWidth() > best.getWidth()) best = size;
        }
        return best;
    }

    /** 30 fps exactly where the camera offers it, so the auto exposure does not slow it down. */
    private static Range<Integer> frameRate(CameraCharacteristics camera) {
        Range<Integer>[] ranges = camera.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES);
        Range<Integer> best = null;
        if (ranges == null) return null;
        for (Range<Integer> range : ranges) {
            if (range.getUpper() != FRAME_RATE) continue;
            if (best == null || range.getLower() > best.getLower()) best = range;
        }
        return best;
    }

    /** Accepts one Mac at a time and streams the chosen camera to it until either side stops. */
    private final class Server extends Thread {
        private final ServerSocket listener =
                new ServerSocket(PORT, 1, InetAddress.getLoopbackAddress());
        private volatile Socket client;
        private volatile boolean closed;

        Server() throws IOException {
            super("server");
        }

        /** Why the last stream could not start; a Mac going away is not a problem. */
        private volatile String problem;

        @Override
        public void run() {
            while (!closed) {
                setStatus(problem == null ? WAITING : "Could not stream: " + problem + "\n\n" + WAITING);
                try (Socket accepted = listener.accept()) {
                    client = accepted;
                    accepted.setTcpNoDelay(true);
                    stream(cameraId, accepted.getOutputStream());
                } catch (Exception e) {
                    if (!closed) Log.w(TAG, "Stream ended", e);
                } finally {
                    client = null;
                }
            }
        }

        void dropClient() {
            Socket current = client;
            if (current == null) return;
            try {
                current.close();
            } catch (IOException ignored) {
                // Already closed.
            }
        }

        void close() {
            closed = true;
            try {
                listener.close();
            } catch (IOException ignored) {
                // Already closed.
            }
            dropClient();
        }

        private void stream(String id, OutputStream out) throws Exception {
            CameraCharacteristics characteristics = cameras.getCameraCharacteristics(id);
            Size size = videoSize(characteristics);
            MediaFormat format =
                    MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, size.getWidth(), size.getHeight());
            format.setInteger(
                    MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
            format.setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE);
            format.setInteger(MediaFormat.KEY_FRAME_RATE, FRAME_RATE);
            format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1);
            format.setInteger(MediaFormat.KEY_PRIORITY, 0);
            // What the Mac's renderer assumes for its YCbCr conversion.
            format.setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT709);
            format.setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED);
            format.setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_SDR_VIDEO);

            MediaCodec encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
            HandlerThread thread = new HandlerThread("camera");
            thread.start();
            Handler handler = new Handler(thread.getLooper());
            Surface input = null;
            CameraDevice camera = null;
            try {
                try {
                    encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
                    input = encoder.createInputSurface();
                    encoder.start();
                    camera = open(id, handler);
                    capture(camera, input, frameRate(characteristics), handler);
                    problem = null;
                } catch (Exception e) {
                    problem = e.getMessage();
                    throw e;
                }
                setStatus(
                        String.format(
                                Locale.US,
                                "Streaming %s at %d×%d to OpenCamraHub.",
                                describe(id),
                                size.getWidth(),
                                size.getHeight()));
                send(encoder, out);
            } finally {
                if (camera != null) camera.close();
                try {
                    encoder.stop();
                } catch (IllegalStateException ignored) {
                    // Never started.
                }
                encoder.release();
                if (input != null) input.release();
                thread.quitSafely();
            }
        }

        private CameraDevice open(String id, Handler handler) throws Exception {
            CountDownLatch opened = new CountDownLatch(1);
            CameraDevice[] result = new CameraDevice[1];
            cameras.openCamera(
                    id,
                    new CameraDevice.StateCallback() {
                        @Override
                        public void onOpened(CameraDevice camera) {
                            result[0] = camera;
                            opened.countDown();
                        }

                        @Override
                        public void onDisconnected(CameraDevice camera) {
                            camera.close();
                            opened.countDown();
                            dropClient();
                        }

                        @Override
                        public void onError(CameraDevice camera, int error) {
                            camera.close();
                            opened.countDown();
                            dropClient();
                        }
                    },
                    handler);
            if (!opened.await(5, TimeUnit.SECONDS) || result[0] == null) {
                throw new IOException("the camera did not open; another app may be using it");
            }
            return result[0];
        }

        private void capture(CameraDevice camera, Surface input, Range<Integer> rate, Handler handler)
                throws Exception {
            CountDownLatch configured = new CountDownLatch(1);
            boolean[] repeating = new boolean[1];
            CameraCaptureSession.StateCallback callback =
                    new CameraCaptureSession.StateCallback() {
                        @Override
                        public void onConfigured(CameraCaptureSession session) {
                            try {
                                CaptureRequest.Builder request =
                                        camera.createCaptureRequest(CameraDevice.TEMPLATE_RECORD);
                                request.addTarget(input);
                                if (rate != null) {
                                    request.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, rate);
                                }
                                session.setRepeatingRequest(request.build(), null, handler);
                                repeating[0] = true;
                            } catch (CameraAccessException | IllegalStateException e) {
                                // Reported below.
                            }
                            configured.countDown();
                        }

                        @Override
                        public void onConfigureFailed(CameraCaptureSession session) {
                            configured.countDown();
                        }
                    };
            camera.createCaptureSession(
                    new SessionConfiguration(
                            SessionConfiguration.SESSION_REGULAR,
                            Collections.singletonList(new OutputConfiguration(input)),
                            handler::post,
                            callback));
            if (!configured.await(5, TimeUnit.SECONDS) || !repeating[0]) {
                throw new IOException("the camera refused to stream to the encoder");
            }
        }

        /** Forwards the encoder's buffers until the Mac, the camera or this screen goes away. */
        private void send(MediaCodec encoder, OutputStream out) throws IOException {
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            byte[] message = new byte[0];
            while (true) {
                int index = encoder.dequeueOutputBuffer(info, 250_000);
                if (index < 0) {
                    Socket current = client;
                    if (closed || current == null || current.isClosed()) throw new IOException("closed");
                    continue;
                }
                ByteBuffer buffer = encoder.getOutputBuffer(index);
                int length = info.size;
                if (message.length < 4 + length) message = new byte[4 + length];
                message[0] = (byte) (length >>> 24);
                message[1] = (byte) (length >>> 16);
                message[2] = (byte) (length >>> 8);
                message[3] = (byte) length;
                buffer.position(info.offset);
                buffer.get(message, 4, length);
                encoder.releaseOutputBuffer(index, false);
                if (length > 0) out.write(message, 0, 4 + length);
            }
        }
    }
}
