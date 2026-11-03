# Usage guide

Start with the [Quick Start](../README.md#quick-start) for camera input and ArkUI
rendering. Unless stated otherwise, these examples reuse its `client`, `realtime`
and `localStream`, and the component's local and remote track state. File paths
refer to files supplied by your app. Run realtime operations from a lifecycle-aware
component and handle rejected promises.

- [Configure permissions](#configure-permissions)
- [Query remaining credits](#query-remaining-credits)
- [Create an input stream](#create-an-input-stream)
- [External video input](#external-video-input)
- [Model capabilities](#model-capabilities)
- [Service environments](#service-environments)
- [Reference Image Upload](#reference-image-upload)
- [Render local preview and generated video](#render-local-preview-and-generated-video)
- [Receive remote audio and video frames](#receive-remote-audio-and-video-frames)
- [Start generation in one call](#start-generation-in-one-call)
- [Touch Interaction](#touch-interaction)
- [Adjust playback volume](#adjust-playback-volume)
- [Adaptive transmission quality](#adaptive-transmission-quality)
- [Switch cameras or change capture specifications](#switch-cameras-or-change-capture-specifications)
- [Stop and release resources](#stop-and-release-resources)
- [Observe lifecycle and failures](#observe-lifecycle-and-failures)
- [Configure SDK logging](#configure-sdk-logging)
- [Generation startup timing](#generation-startup-timing)
- [Runtime information and task IDs](#runtime-information-and-task-ids)

<br>

## Configure permissions

For camera-based input, declare the following permissions in the application
module's `module.json5`:

```json5
{
  "module": {
    "requestPermissions": [
      {
        "name": "ohos.permission.INTERNET"
      },
      {
        "name": "ohos.permission.GET_NETWORK_INFO"
      },
      {
        "name": "ohos.permission.CAMERA",
        "reason": "$string:reason_camera",
        "usedScene": {
          "abilities": [
            "EntryAbility"
          ],
          "when": "inuse"
        }
      }
    ]
  }
}
```

Replace `EntryAbility` with the UIAbility that uses XmaxSDK when the application
uses a different ability name. Define the permission reason in
`resources/base/element/string.json`:

```json
{
  "string": [
    {
      "name": "reason_camera",
      "value": "Camera access is required for realtime video input."
    }
  ]
}
```

If camera microphone input is enabled (`useMicrophone` set to `true`) or an input source
contains audio, also declare `ohos.permission.MICROPHONE` with
an appropriate permission reason and `usedScene` configuration. XmaxSDK checks and
requests the required runtime permissions when a local media stream is created. If
permission is unavailable, the SDK reports an `XmaxError`.

Before deploying to a device, configure application signing in DevEco Studio under
**File > Project Structure > Signing Configs**.

<br>

## Query remaining credits

Query the remaining credits for the account owning your client's API key:

```ts
const balance = await client.getCreditBalance();
console.info(`Remaining credits: ${balance.currentBalance}`);
```

Each call fetches the current server balance using the client's configured
`XmaxEnvironment`. Fractional credits are preserved. No realtime manager, session,
or platform context is required; declare `ohos.permission.INTERNET` in your app.
Handle rejected promises as `XmaxError` for invalid credentials, network failures,
or invalid server responses. A failed query is not reported as a zero balance.

<br>

## External video input

Implement `RealtimeExternalVideoSource` to supply frames from your own camera,
decoder, or image-processing pipeline. The app owns permissions, producer pacing,
and resource cleanup; XmaxSDK does not capture microphone audio or play submitted
audio locally.

```ts
import {
  RealtimeExternalVideoSource,
  RealtimeExternalFrameSink,
  RealtimeVideoFormat
} from '@xmax/sdk';

class MyVideoSource implements RealtimeExternalVideoSource {
  readonly videoFormat: RealtimeVideoFormat = new RealtimeVideoFormat(1280, 720, 30);
  readonly hasAudio: boolean = false;
  private sink: RealtimeExternalFrameSink | null = null;

  async start(sink: RealtimeExternalFrameSink): Promise<void> {
    this.sink = sink;
    // Install your producer callback; call sink.pushVideo(frame) for each decoded frame.
  }

  async stop(): Promise<void> {
    // Remove the producer callback and cancel any pending startup before returning.
    this.sink = null;
  }
}

const source = new MyVideoSource();
const localStream = await realtime.createExternalVideoStream(source);
this.localVideoTrack = localStream.videoTrack;
```

Submit a `RealtimeVideoFrame` containing upright NV12 video-range or BGRA pixels
at the declared `source.videoFormat` dimensions. Apply orientation and mirroring
to the pixels before submission. `VideoFramePlane` describes each plane's
ArrayBuffer, row stride, byte offset, and valid byte length. NV12 has Y and
interleaved UV planes; BGRA has one packed plane.
Source dimensions must be even, at most 32768 per side, and at most 16777216 pixels in total.

The sink synchronously copies or resizes pixels, so buffers can be reused after
`pushVideo` returns. `sink.videoFormat` exposes the processed dimensions within
model pixel limits and four-pixel alignment, retaining source FPS and encoding
options. The processed pixels drive both preview and uplink.

For optional audio, declare `hasAudio = true` and call `sink.pushAudio` with a
`RealtimeAudioFrame`: interleaved little-endian PCM16, 8–192 kHz, 1–8 channels,
and the number of samples per channel. The SDK converts this to 48 kHz mono PCM16
in 10 ms packets. Source sample rate and channel count must not change while bound.
Compressed audio must be decoded first. Remote playback starts muted; call
`setRemoteAudioVolume` after binding if needed.

Both frame types use nonnegative microsecond timestamps on the same monotonic
timeline. Preserve their original offset and keep time increasing across loops
and seeks. Invalid or nonincreasing video timestamps and overlapping audio buffers
are ignored; audio gaps begin a new segment without silence insertion.

Lifecycle and sink calls run in the manager's ArkTS environment. Marshal Worker
output through messages before calling the sink; do not share a sink across
isolated environments. Keep source settings immutable while bound and use
`isRequestingFrames` to avoid unnecessary work after detachment.

Binding completion marks `READY` without waiting for the first frame. Continue
delivering frames before generation and after `disconnect()` to retain preview.
After disconnecting, `stopExternalVideoStream()` invalidates the sink, clears the
SDK preview, and calls `source.stop()`; `close()` also unbinds it. Stopping must
cancel pending source startup and detach producer callbacks, but the app decides
when to release its devices or player. `reportError(error)` permanently ends the
binding and triggers normal SDK media-error cleanup.

XLab's **External Capture** card uses app-owned native system decoders for video
and PCM audio, including looping and upright pixels. HDR Vivid videos use Surface
decoding with BT.709 limited-range SDR output before frames reach the sink.
The example selects model-sized output before binding and filters the target
frame rate in native decoding, before rotation and ArkTS copies. HDR Surface
output is downscaled before CPU mapping, with two Surface frames in flight
at most; remaining nonexpired frames are delivered before a playback loop restarts.
Late video frames exceeding one target frame interval and audio buffers exceeding
100 ms are dropped without reporting a source failure. Deadlines are also checked
after waiting in the ArkTS callback queue. Dropped frames do not reset the shared
audio/video timeline or shift the timestamps of subsequent frames.
Byte-buffer output still requires NV12; arbitrary HDR/P010 producers must convert
their pixels to supported SDR first.

<br>


## Create an input stream

Create a live camera stream after declaring the required permissions:

```ts
const localStream = await realtime.createLocalCameraStream();
// For explicit capture settings, pass a RealtimeVideoFormat and CameraPosition.
```

Camera microphone input is optional and defaults to `false`. To enable it:

```ts
import { CameraPosition } from '@xmax/sdk';

const localStream = await realtime.createLocalCameraStream(
  undefined, CameraPosition.FRONT, true
);
```

Declare `ohos.permission.MICROPHONE` in the application's permission configuration.
The SDK checks microphone permission when creating the camera stream and rejects
with `MICROPHONE_PERMISSION_DENIED` if permission is unavailable. Local preview
alone does not capture microphone audio. Connecting starts RTC's internal audio
capture and publishes it alongside CameraKit video; disconnecting, connection
failure, or closing stops capture. Reconnecting reuses the microphone setting.
Camera switching preserves it. Microphone audio is not played back locally, and
`localAudioVolume` continues to control file-video preview audio only.


For both models, still images and local video files can also be used as input sources:

```ts
const imageStream = await realtime.createLocalImageStream(imageFilePath);
const videoStream = await realtime.createLocalVideoStream(videoFilePath);
```

Only one local input stream may be active at a time.

## Model capabilities

`RealtimeModels.realtime(model)` returns a `ModelDefinition` describing supported
input resolutions, pixel bounds, alignment, default frame rate and camera format.
Camera, video and image inputs are available for both models.

| Model | Generation canvas | Local media pixel limit | Default FPS | Default camera |
| --- | --- | --- | --- | --- |
| `x2.0` | 600,000–1,280,000 pixels, width and height aligned to 32 | 1,280,000 | 30 | 832 × 1472 |
| `x2.0-sla` | 1920 × 1080, 1080 × 1920, 1408 × 1408, 1152 × 1536, or 1536 × 1152 | 2,100,000 | 30 | 1080 × 1920 |

Use `RealtimeModel.X2_1` for X2.1. Its backend model ID remains `x2.0-sla`.

```ts
import { ImageSize, RealtimeMediaSource } from '@xmax/sdk';

const model = RealtimeModels.realtime(RealtimeModel.X2_1);
const realtime = client.createRealtimeManager(new RealtimeConfiguration(model));
const localStream = await realtime.createLocalImageStream(imageFilePath);

// SDK preparation and generation already apply these rules automatically.
const mediaService = client.createMediaService(RealtimeModel.X2_1);
const mediaSize = mediaService.resolveMediaSize(new ImageSize(3840, 2160), RealtimeMediaSource.IMAGE);
// mediaSize: 1920 × 1080
const generationSize = mediaService.resolveGenerationSize(mediaSize);
// generationSize: 1920 × 1080
const targetSize = mediaService.resolveTargetSize(mediaSize, mediaSize);
// targetSize: 1920 × 1080
```

### Media, generation, and return sizes

`resolveMediaSize(size, source)` limits local frames to the model's maximum pixel
area without enlarging smaller inputs. Dimensions are aligned to multiples of 4,
with the exact source aspect ratio preserved whenever possible. Only camera
requests must exactly match a configured resolution bucket. Image and video
sources do not need to match a bucket. Video rotation is applied before sizing.
An explicitly supplied image/video output format still overrides source dimensions;
omit it to preserve the source's display ratio automatically.

`resolveGenerationSize(size)` selects the closest generation bucket by aspect
ratio. When the model has no buckets, its generation pixel bounds and 32-pixel
alignment apply. This does not resize or crop the local media into that canvas.
Image and video generation signals include `padding: "contain"`, and the initial
`start` includes a separate `target_size` derived from the media dimensions.
Condition updates preserve containment and the existing return size.

`resolveTargetSize(size, maximumSize, frameInterpolationEnabled)` calculates a
separate return size without upscaling. It combines the width/height bound and an
optional 900,000-pixel interpolation bound before applying 4-pixel alignment.
Harmony applies its current downlink tier to the bounded media size; it does not
enable iOS frame interpolation. Interaction geometry and coordinates
use the processed local media size, independently of the return frame dimensions.

`createMediaService()` continues to default to `x2.0`. Use the three sizing
methods above for local media, generation canvases, and return frames respectively.
These frame limits do not limit memory needed to decode the original file.

The former `x2.0-pro` model is replaced by X2.1 (`x2.0-sla`). XLab migrates a saved Pro
selection to X2.1 and keeps all three media entries available.

## Service environments

The China service environment is used by default. Select the global environment
when creating the client to route realtime-session and storage API requests to
Xmax's global service:

```ts
import { XmaxConfiguration, XmaxEnvironment } from '@xmax/sdk';

const configuration = new XmaxConfiguration(
  'YOUR_API_KEY',
  XmaxEnvironment.GLOBAL
);
```

Use `XmaxEnvironment.CHINA` to select the China service explicitly. RTC room
credentials and storage configuration are returned by the selected service.

`XmaxConfiguration(apiKey, environment, loggerOptions)` uses the second argument
for the service environment and the third for logging options. Omitting them
selects `CHINA` and `XmaxLoggerOption.NONE` respectively.

SDK log details use Chinese for `CHINA` and English for `GLOBAL`; bilingual log
headings are retained. Logging options and language are global: the most recently
created client's configuration takes effect. Original server/platform error
messages and error codes are preserved, and credential redaction still applies.

The globe button at the top right of XLab's home page offers **Follow System**,
**简体中文**, and **English**. The
selection persists across launches. System Chinese uses Simplified Chinese;
other system languages fall back to English. Chinese selects the China service
and API-key portal; English selects the global service and portal. Realtime,
reference-image upload, and storage clients use this selection when created.
Changing language updates UI text without rebuilding an active media pipeline.
Preset generation prompts and user/server content are not translated.

Omitting a camera format uses `defaultCameraVideoFormat`. For images and videos,
omitting the format derives dimensions from the source's display size and uses
`defaultFrameRate`; an explicit format preserves the requested frame rate while
resolving dimensions against model bounds. HarmonyOS XLab uses model camera
defaults directly; frame interpolation is not currently supported.

## Reference Image Upload

`RealtimeContext.referencePath` requires a remote image URL. To use an on-device
image, upload it through the storage manager and supply the resulting URL:

```ts
const storage = client.createStorageManager();

const uploaded = await storage.uploadImageFile(
  imageFilePath,
  'image/jpeg'
);

const referenceImageUrl = uploaded.url;
```

The storage manager uses temporary credentials obtained from Xmax. Tencent Cloud
credentials are not embedded in the host application.

## Render local preview and generated video

Store the tracks in component state and render them with `XmaxRealtimeDualVideo`:

```ts
import {
  RealtimeVideoTrack,
  VideoContentMode,
  XmaxRealtimeDualVideo
} from '@xmax/sdk';

@State private localVideoTrack: RealtimeVideoTrack | undefined = undefined;
@State private remoteVideoTrack: RealtimeVideoTrack | undefined = undefined;

// After creating the input stream:
this.localVideoTrack = localStream.videoTrack;

build() {
  XmaxRealtimeDualVideo({
    localTrack: this.localVideoTrack,
    remoteTrack: this.remoteVideoTrack,
    contentMode: VideoContentMode.FILL
  })
    .width('100%')
    .height('100%')
}
```

The component keeps the local preview underneath the remote video. A new remote
track fades in over 300 ms after RTC reports its first rendered frame. Clearing
`remoteTrack` to `undefined` immediately restores the local preview. For a reused
RTC stream, the component can reuse its existing rendered-frame readiness; this
state is cleared when the remote publisher stops or the session ends.

Use `VideoContentMode.FIT` to preserve the aspect ratio of image and local video
inputs. `isInteractionEnabled` controls remote touch interaction; a custom
`trajectoryRenderer` may be supplied when creating the component. The existing
`XmaxRealtimeVideo` remains available for displaying one track. Both components react
to track replacements, including streams recreated with different dimensions.

## Control local video playback

For a stream created by `createLocalVideoStream`, use the realtime manager's
`pauseLocalVideoStream`, `resumeLocalVideoStream`, or
`toggleLocalVideoStreamPlayback` methods. Bind them to your own controls, for
example a tap on the video view:

```ts
XmaxRealtimeDualVideo({
  localTrack: this.localVideoTrack,
  remoteTrack: this.remoteVideoTrack,
  contentMode: VideoContentMode.FIT,
  // Reserve taps for playback control in this example.
  isInteractionEnabled: false
})
  .width('100%')
  .height('100%')
  .onClick((): void => {
    void realtime.toggleLocalVideoStreamPlayback().catch((error: Object): void => {
      console.error(`Playback control failed: ${error}`);
    });
  })
```

If you need touch interaction for generation, use a separate playback button.
Register a manager listener to update your controls when playback changes:

```ts
realtime.setLocalVideoPlaybackStateListener((state): void => {
  console.info(`Local video playback: ${state}`); // "playing", "pause", or "ended"
});

// Remove the listener when it is no longer needed.
realtime.setLocalVideoPlaybackStateListener(null);
```

`localVideoPlaybackState` returns the current state, or `undefined` when there is
no local video file stream. Registering a listener immediately reports the current
state if a video file stream exists. Camera and image streams do not support these
playback operations.

### Play a video once

Videos loop by default. Pass `false` as the third argument to play a file once:

```ts
realtime.setLocalVideoPlaybackStateListener((state): void => {
  if (state === LocalVideoPlaybackState.ENDED) {
    // Local video and audio playback have finished.
  }
});

const localStream = await realtime.createLocalVideoStream(videoPath, undefined, false);
```

`ENDED` is reported once after both tracks finish and buffered local audio has
played. Stopping, replacing the file, or closing the manager does not count as
natural completion. Looping videos do not report `ENDED` on each cycle.

The SDK stops local playback and audio/video frame submission, retaining the last
local picture. Remote results already in flight continue to render; the SDK does
not freeze the remote view on completion. An active generation task remains in
`GENERATING` until explicitly stopped or the session state changes. This callback
describes the local file, not completion of cloud processing. Pause, resume, and toggle reject
after `ENDED`; to replay, disconnect if needed, stop the local video stream, and
create it again.

While paused, the SDK holds the file's playback position, continues publishing
the last input frame and silent audio with advancing timestamps, and overlays a
still image on the generated video. The generation task remains active. Resuming
continues file playback from the paused position.

## Receive remote audio and video frames

Use one listener for copied remote PCM and post-processed video from the current
generation result:

```ts
import { RealtimeAudioFrame, RealtimeMediaFrame } from '@xmax/sdk';

realtime.setRemoteMediaFrameListener((frame: RealtimeMediaFrame): void => {
  if (frame.content instanceof RealtimeAudioFrame) {
    const audio = frame.content;
    // Interleaved signed PCM16, little-endian. Use audio.sampleRate,
    // audio.channels, audio.samplesPerChannel and audio.data for processing.
  } else {
    const video = frame.content;
    // I420 pixels, dimensions and rotation follow RealtimeVideoFrame.
  }

  // frame.streamId identifies this result binding. frame.timestampUs is
  // media time; frame.durationUs is supplied for audio only.
  // Reset this track's continuity when frame.isDiscontinuous is true.
});

// Remove unified delivery and discard queued packets.
realtime.setRemoteMediaFrameListener(null);
```

Register before or during generation. This listener does not start a session,
subscribe to audio, change playback volume, or change whether remote sound plays.
It receives the bound user's subscribed, unmixed PCM in its actual sample rate
and channel layout. Video excludes view-level cropping, mirroring and overlays.
Buffers are copied before the native RTC callback returns and remain valid
after your callback. Treat all delivered data as read-only.

Each result binding gets a new `streamId`, even when it reuses the same RTC user.
The first event of each track, format changes, timestamp discontinuities and
discarded packets mark `isDiscontinuous`. Stopping generation, disconnecting,
closing or replacing the binding clears pending output. Replacing or removing
the listener also clears it. Registration remains configured across sessions
until explicitly removed.

Callbacks are serialized in arrival order on the ArkTS event loop. An event
contains audio **or** video, not an aligned pair, and events are not sorted by
timestamp. The unified queue retains at most 256 packets or 32 MiB, including
the callback in progress. Overflow discards incoming packets and marks the next
admitted event of that track as discontinuous. Delivery yields after at most
16 events per turn. Keep callbacks short and send expensive work to a Worker.
Listener exceptions are logged without stopping generation. Native observation
setup failures throw from the setter when a result is already bound; later
binding failures follow the normal realtime operation error path.

**Timestamp limitation:** audio time advances by sample count from its native RTC
anchor; video keeps its native RTC timestamp. These are provider-defined clocks,
not wall-clock or source-file timecodes. The current RTC integration has not been
verified to expose a common audio/video render clock. A unified callback alone
does not guarantee synchronized recording. Validate their cross-track offset on
target devices before using them for that purpose; do not independently reset
each track's first timestamp to zero.

### XLab recording example

The Realtime page's **Record** button is available while generating. It installs
the unified listener only during recording, encodes the generated I420 video as
H.264 and remote PCM as AAC, and removes the listener on stop. Playback volume
does not change the recorded audio. Without remote PCM, the output is video-only.
The saved video contains generated frames, not UI overlays or a screen capture.

Tap **Stop** to finalize MP4 in the background and choose whether to save it
through the system photo-library dialog. Ending generation also finalizes the
recording. Leaving the page or backgrounding the app cancels an unfinished
recording and cleans up its temporary files without opening a save dialog.
Changing the result binding, video format or audio timeline ends recording with
an error rather than combining incompatible media. Clearly incompatible native
audio/video clock origins are also rejected, rather than corrected using arrival
times. Recording failures do not
stop generation. The timestamp limitation above still applies; verify audio/video
sync on target devices.

## Start generation in one call

Pass the local stream and generation context. The SDK establishes a connection on
demand and returns the remote media stream when generation starts:

```ts
import { RealtimeContext } from '@xmax/sdk';

const remoteStream = await realtime.startGeneration(
  localStream,
  new RealtimeContext('视频中角色替换成参考图中角色', referenceImageUrl)
);
this.remoteVideoTrack = remoteStream.videoTrack;
```

The SDK matches the task's SEI, waits for a usable remote video frame,
activates remote audio, and then emits `RealtimeConnectionState.GENERATING` before
the call returns. While waiting for the frame, the state remains `CONNECTED`.
Frame readiness does not require a mounted video view and has a 10-second timeout
after SEI confirmation. Each new generation waits for a new frame, including when
reusing the same RTC stream. A timeout or cancellation stops that generation;
remote audio is also unsubscribed when generation stops.

Creating a local stream only starts local preview. The call above creates the
server session; subsequent calls reuse the connection and remote track. During
an active generation, a new context updates the current task. To cancel generation,
call `disconnect()`. Starting again creates a new session and requires a context:

```ts
await realtime.disconnect();
this.remoteVideoTrack = undefined;

const resumedStream = await realtime.startGeneration(localStream, generationContext);
this.remoteVideoTrack = resumedStream.videoTrack;
```

A new connection requires a context. The local stream must still belong to this
manager. A usable first frame and its actual display are separate events:
assign the returned remote track to the component so RTC can render it.

The explicit connection and context-only generation APIs remain supported:

```ts
const remoteStream = await realtime.connect(localStream);
await realtime.startGeneration(new RealtimeContext('将人物服装替换成参考图中的服装', referenceImageUrl));
this.remoteVideoTrack = remoteStream.videoTrack;
```

Only one local-media, connection, generation, or camera-switch operation may run
at a time. Overlapping operations and new operations during cleanup reject with
`XmaxErrorCode.INVALID_CONFIGURATION`; await the current operation before retrying.
`disconnect()` cancels an in-flight connection or generation, stops microphone
capture and retains local preview. `close()` additionally releases local media.
A cancelled operation rejects with `XmaxErrorCode.CANCELLED`.

## Touch Interaction

During an active generation task, the remote view in `XmaxRealtimeDualVideo` (or
a standalone `XmaxRealtimeVideo`) captures multi-touch trajectories
over the generated video and submits them to the active task. The host application
does not need to implement gesture tracking or coordinate conversion.

Camera, image, and video trajectories use the processed local media size returned
by `resolveMediaSize` as their coordinate basis. Fit/Fill geometry and the effect
renderer use this same media region; source-file dimensions, generation buckets,
return dimensions and remote track metadata do not change it. A local camera
orientation change updates the basis to the new local media dimensions.

The SDK sends `"tracks": [[x, y], ...]` with normalized coordinates in `[0, 1]`,
retaining fractional precision. The top-left corner is `(0, 0)` and the bottom-right
corner is `(1, 1)`. The server must interpret these as normalized media coordinates
and map them to the actual uplink frame dimensions, rather than treating them as
pixel coordinates. Fit letterbox taps are ignored; Fill includes the crop offset.

Trajectory interaction is enabled by default. Disable it when touch input must be
handled by the surrounding user interface:

```ts
import { XmaxRealtimeVideo } from '@xmax/sdk';

XmaxRealtimeVideo({
  track: this.remoteVideoTrack,
  contentMode: VideoContentMode.FILL,
  isInteractionEnabled: false
})
```

## Adjust playback volume

Control local video preview and generated audio separately, including before creating a stream or connecting:

```ts
await realtime.setLocalAudioVolume(0.45); // Local video preview; default 45%.
await realtime.setRemoteAudioVolume(1);   // Set after creating the local stream.
const localVolume: number = realtime.localAudioVolume;
const remoteVolume: number = realtime.remoteAudioVolume;
```

Both methods accept finite values from `0` (mute) to `1` (original volume) and reject invalid values with `INVALID_CONFIGURATION`. Local volume persists across stream replacement and reconnection on the same manager. Remote volume starts at `1`; successfully creating a camera or image stream resets it to `0`, while creating a video stream resets it to `1`. Set custom remote volume after creating the local stream; it persists through camera switching and reconnection. The remote getter returns the applied RTC percentage normalized to `0`–`1` (for example, `0.356` becomes `0.36`). Local volume does not affect uploaded audio or override automatic preview muting during generation. XLab's video input page exposes both sliders and a shared mute switch in its top bar. Camera input exposes a remote-volume slider beneath the camera flip button, initialized from the SDK's current volume.

## Video statistics

Register independent listeners on `XmaxRealtimeManaging`, matching the iOS SDK:

```ts
import { UplinkVideoStatistics, DownlinkVideoStatistics } from '@xmax/sdk';

realtime.setUplinkVideoStatisticsListener((stats: UplinkVideoStatistics | undefined): void => {
  // Actual encoded width/height, capture/encode/send FPS, bitrateKbps, packetLossPercent.
  this.uplinkStatistics = stats;
});
realtime.setDownlinkVideoStatisticsListener((stats: DownlinkVideoStatistics | undefined): void => {
  // userId, received width/height, decode/render FPS, bitrate, loss and endToEndDelayMs.
  this.downlinkStatistics = stats;
});
// Detach listeners when the host view is disposed.
realtime.setUplinkVideoStatisticsListener(null);
realtime.setDownlinkVideoStatisticsListener(null);
```

Callbacks run asynchronously on the ArkTS event loop, independently of RTC log
settings. Uplink samples are delivered while local video is published. Downlink
samples are delivered only after the current generation stream has been matched
by task SEI; unrelated users and screen streams are excluded. A lifecycle change
clears the corresponding statistics with `undefined`. Disconnect preserves the
registered listeners for a later connection. Replacing or removing a listener
invalidates its queued callbacks. Statistics are not cached or replayed when a
listener is installed.

Individual unavailable metrics are `undefined`; valid zero values are preserved.
Dimensions are in pixels, frame rates in fps, bitrates in kbps, and packet loss
is a percentage from 0 to 100 (VolcEngine's fractional precision is retained).
`renderFrameRate` is the RTC render rate before SDK interpolation.
`endToEndDelayMs` measures RTC media transport, not the full AI generation time.
The Harmony `userId` field follows the platform's existing identifier naming.

For each main-stream RTC statistics event, the adapter converts the native data
once and passes the same `UplinkVideoStatistics` / `DownlinkVideoStatistics`
instance to the public video logger and quality listener. Public video logs
therefore share the callback values, units, and unavailable-value semantics;
missing metrics display `—`, and valid zero values remain zero. The logger runs
at the RTC layer, while business callbacks are additionally filtered by the
publication/current-generation lifecycle described above.

Native video RTT/jitter, stalls and audio extension statistics are not logged.
VolcEngine network-quality details and performance alarms remain under
`[RTC/VolcEngine]`. Both log categories use `XmaxLoggerOption.PERFORMANCE`;
disabling logs does not disable statistics callbacks, and log bodies are not
formatted when logging is off.

XLab's Realtime camera, image and video pages have a **Stats** button. The panel
is hidden by default and shows both video directions, network quality and RTC
latency; missing values display `—`. Hiding it keeps the listeners installed so
it shows the latest sample when reopened. Leaving the page detaches all three
listeners and clears their values.

## Adaptive transmission quality

The SDK automatically manages independent uplink and downlink tiers while
`GENERATING`, using VolcEngine network quality events (normally every two seconds).
No application listener is required; `setNetworkQualityListener` still receives
all events independently of adaptation. Both directions start at L2 unless a
successful tier was saved within the last hour for the same model and direction.
History uses SDK-private Preferences with a `volcengine` namespace.

| Tier | Dimension scale | Uplink FPS cap | Downlink bitrate calculation FPS |
| --- | --- | --- | --- |
| L1 | 1.0 | 30 | 24 |
| L2 | 0.9 | 24 | 24 |
| L3 | 0.75 | 24 | 24 |
| L4 | 0.6 | 20 | 24 |
| L5 | 0.5 | 16 | 24 |

Scales apply to the processed local media baseline. The short side is bounded
below by `min(originalShortSide, 240)` without upscaling. Upload dimensions use
four-pixel alignment and retain the model's minimum input area, capped at the
source area so smaller media is not enlarged. Return dimensions use the media
service's four-pixel alignment without the uplink minimum-area constraint.
Exact aspect ratio is preserved when possible. Uplink FPS never exceeds the source FPS. Explicit uplink
bitrates and encoder preferences survive tier changes; tiers whose merged bitrate
bounds are invalid are skipped.

Three consecutive BAD/VERY_BAD samples propose one downgrade; five consecutive
EXCELLENT/GOOD samples propose one upgrade. POOR, DOWN and UNKNOWN clear the
continuous counters. Duplicate, out-of-order and stale samples cannot trigger a
change, and a gap greater than five seconds restarts counting. Every attempt has
a four-second stable window. If an upgrade falls back within twenty seconds,
further upgrades wait sixty seconds. Identical adjacent formats are skipped.

Uplink changes use VolcEngine's video encoder configuration. Downlink changes send
`change_target_size` with `target_size`, `min_bitrate: 100` and a calculated
`max_bitrate` capped at 10000 kbps. Initial `start` signals also include the return
bitrate budget. The server-side VolcEngine generation pipeline must support these
fields and the update event; local RTC enqueue success does not acknowledge server
application. Model generation dimensions, local capture, reference conditions,
task identity and normalized interaction coordinates remain independent of tiers.

Adaptation skips active user operations, never queues stale samples into a new
task, and stops on disconnect or generation restart. Encoding or signaling failure
keeps that direction's previous tier and does not interrupt generation. Successful
RTC configuration/enqueue results are recorded in history; persistence failures
are logged without interrupting streaming. Camera orientation updates rebase the
same tiers onto the new processed media dimensions.

### Manual quality levels

After `await realtime.startGeneration(...)` succeeds, select either direction
using `RealtimeQualityLevel.L1` through `L5`. L1 is the highest quality; these
levels are not network quality ratings.

```ts
import { RealtimeQualityLevel } from '@xmax/sdk';

await realtime.setUplinkQualityLevel(RealtimeQualityLevel.L2);
await realtime.setDownlinkQualityLevel(RealtimeQualityLevel.L3);

console.info(`Uplink: ${realtime.uplinkQualityLevel}`);
console.info(`Downlink: ${realtime.downlinkQualityLevel}`);
```

The getters return `undefined` before connection completes and after cleanup
begins. Manual setters require `GENERATING` and reject during conflicting
operations. Await each change before submitting another. A failed change rejects
without committing its level or history or ending generation. A successful
downlink change means its signal was submitted, not that the server has already
started returning the new dimensions. Neither setter recreates the task, changes
local capture or generation dimensions, or locks out later automatic adaptation.

### Disable automatic adaptation

Pass `false` as the second `RealtimeConfiguration` argument when creating a new
manager. The default is `true`.

```ts
const realtime = client.createRealtimeManager(new RealtimeConfiguration(
  RealtimeModels.realtime(RealtimeModel.X2_1),
  false
));
```

With adaptation disabled, each connection starts at L1 without reading or writing
quality history. Manual setters remain available during generation, and network
quality, performance, and video statistics listeners continue to work. To change
this configuration, close the old manager and create another one.

## Switch cameras or change capture specifications

On initial creation, camera output follows the current display orientation: the
short side is the width in portrait, and the long side is the width in landscape. For example,
`1080 × 1920` becomes `1920 × 1080`, with the frame rate unchanged. CameraKit
prefers 16:9 YUV capture profiles, starting at `1920 × 1080` and trying smaller
profiles until one supports 30 fps. If none does, it falls back to 4:3 profiles
starting at `1920 × 1440`. A 16:9 capture corresponds to 9:16 in portrait.
Native rotation and cropping still produce the model's required input dimensions.

`updateCameraFormat(format)` changes a camera's output while keeping its stream,
track, preview bindings, camera position, and microphone setting. It is available
only in `READY`, before connecting or after disconnection completes. The call
rejects during preparation, connection, generation, disconnection, or another
realtime operation. Output frame rates must not exceed 30 fps.

```ts
const current = realtime.currentCameraVideoFormat;
if (realtime.currentState.connectionState === RealtimeConnectionState.READY && current !== undefined) {
  // X2.1 supports this square format; retain the current fps and encoding settings.
  await realtime.updateCameraFormat(current.resized(1408, 1408));
}
```

The chosen width and height are applied exactly, even when their orientation
differs from the display. Subsequent display rotations transpose those dimensions
rather than resetting the chosen ratio. Camera switching and connection preserve
the selection. Invalid formats leave the preview unchanged; configuration failures
attempt to restore the previous format. Queued frames with old dimensions are
discarded. `currentCameraVideoFormat` returns the actual local camera format, or
`undefined` for other sources; transmission quality changes do not affect it.

XLab's X2.1 camera page exposes a **Ratio** menu for `16:9`, `9:16`, `1:1`, `3:4`,
and `4:3`. The menu is disabled outside `READY` and during camera switching.
Generation controls and camera flipping are disabled while a ratio update is pending.

`XmaxRealtimeVideo` and `XmaxRealtimeDualVideo` observe the orientation of their
window. When camera input flips between portrait and landscape during
`GENERATING`, the SDK stops the current generation task while keeping the RTC
connection and remote track, waits 500 ms for capture to settle, then restarts
generation with the latest successful context — the same policy as
`switchCamera()`. The state briefly returns to `CONNECTED` with
`state.reason` set to `RealtimeReason.ORIENTATION_CHANGED` and becomes
`GENERATING` again once the restarted task is confirmed. The settle wait does
not occupy the operation channel: calling `startGeneration` with new conditions
(for example a new reference image) during the window takes effect immediately
with the latest capture dimensions, and the pending restart is discarded. While
the restarted task is awaiting confirmation, new conditions are merged into it
through `change_condition` — dimensions are already correct at that point, and
`change_condition` can update everything else — so the call follows the restart
to completion instead of failing with a concurrent-operation error. If
the device rotates again while the restart is awaiting confirmation, the SDK
terminates the mismatched task and resubmits until the submitted orientation
matches capture. Frames queued with the previous dimensions are discarded
before pushing to RTC.

Rotation while `CONNECTING` or `CONNECTED` no longer cancels the in-flight
operation: the connection completes and the new dimensions are applied by the
next generation start. If the device rotates while a start is awaiting
confirmation, the confirmed task still carries the stale dimensions —
`change_condition` cannot resize a task — so the SDK terminates it and
resubmits with the latest orientation, briefly returning to `CONNECTED` with
`RealtimeReason.ORIENTATION_CHANGED` just like a rotation during `GENERATING`.
Only resolution changes within the same portrait/landscape axis use
`change_condition`-style updates. Rotation during local preview only updates
the capture dimensions, and rotation within the same axis or from a replaced
track is ignored. Image and video-file input retain their source dimensions
and are not interrupted by window rotation. The camera also detects capture
orientation changes without an attached SDK view.

```ts
realtime.setStateListener((state: RealtimeState): void => {
  if (state.reason?.kind === RealtimeReasonKind.ORIENTATION_CHANGED) {
    // Generation is restarting automatically with the preserved connection.
  }
});
```

To keep a fixed capture ratio regardless of window rotation, pass
`observeDisplayChange: false` when creating the camera stream. The SDK then
skips display-orientation listening: rotating the window neither flips the
capture dimensions and rotation nor restarts generation.

```ts
const fixedStream = await realtime.createLocalCameraStream(
  undefined, CameraPosition.FRONT, false, false
);
```

`switchCamera()` changes front/back position while preserving the local track and
its frame rate and orientation-dependent dimensions. During generation, the SDK stops the current task,
switches cameras, waits 500 ms for capture to settle, then starts a new task with
the latest successful context. The connection and remote track are retained.
Do not switch while a connection or generation start is pending. Calling
`disconnect()` during the switch prevents automatic restart.

```ts
const switchedStream = await realtime.switchCamera();
this.localVideoTrack = switchedStream.videoTrack;
```

`replaceLocalCameraStream()` has been removed. Use `updateCameraFormat()` to
change dimensions or frame rate without recreating the local stream. If realtime
is connected, disconnect first and wait for `READY`. A stream stopped with
`stopLocalCameraStream()` is still invalid and must not be reused.

X2.1 camera requests must
match one of its five supported resolutions exactly; unsupported camera dimensions
are rejected rather than rounded to a bucket. Images and videos retain their media
aspect ratio and select the closest generation canvas. Use the returned track's
`videoFormat` to inspect the resolved local dimensions.

## Upload encoding configuration

`RealtimeVideoFormat` also accepts `minimumBitrate`, `maximumBitrate` (in kbps),
and `encoderPreference`. These settings apply to camera, video and image streams:

```ts
import { RealtimeVideoFormat, RealtimeVideoEncoderPreference } from '@xmax/sdk';

const format = new RealtimeVideoFormat(
  1080, 1920, 30,
  1500, 6000,
  RealtimeVideoEncoderPreference.MAINTAIN_FRAMERATE
);
const stream = await realtime.createLocalCameraStream(format);
```

Omit the minimum bitrate to use `100 kbps`. Omit the maximum bitrate to use
`max(100, roundToNearestEven(referenceMaximum × 0.6))`, calculated from the final
upload dimensions and frame rate using the same reference table as iOS. A minimum of `0`
disables the lower bound; an explicit maximum must be positive. The minimum must
not exceed the maximum, including after SDK defaults are applied. Invalid
configurations throw `INVALID_CONFIGURATION`.

`AUTO` (default) balances frame rate and resolution, `MAINTAIN_FRAMERATE` prioritizes
frame rate, and `MAINTAIN_QUALITY` prioritizes resolution. Resizing and camera
orientation changes preserve these settings. To change encoding settings, recreate
the local stream after disconnecting, as shown above.

## Stop and release resources

```ts
import { RealtimeReason } from '@xmax/sdk';

// Cancel generation and end the remote session while retaining local preview:
await realtime.disconnect();

// Or disconnect with a business reason:
await realtime.disconnect(RealtimeReason.ORIENTATION_CHANGED);

// Or leave the screen and release all resources:
await realtime.close();
```

`disconnect()` ends generation, stops microphone capture and closes the remote
session while preserving local preview. `close()` releases all local media and RTC
resources and should be called when the realtime workflow is no longer required.

`disconnect(reason?: RealtimeReason)` defaults to `RealtimeReason.NORMAL`.
When a disconnection occurs, the final `READY` (or `IDLE` if no local media remains)
state carries the reason in `state.reason`; `DISCONNECTING` has no reason yet.
`RealtimeReason.failure(error)` preserves the supplied `XmaxError` in that state.
Calling disconnect without a connection or an affected operation is a no-op,
including during local media preparation. Concurrent requests retain the first
disconnection reason; late connection errors do not overwrite it. A local media
failure can still require full cleanup and replace the reason with that failure.

When applicable, these methods wait for affected operations and resource cleanup to finish.
For example, closing while a session request is pending waits for the late session
to be rolled back. Concurrent disconnect/close requests share a cleanup task
and expand its scope as needed. Cleanup failures are logged while the remaining
resources continue to be released.

## Observe lifecycle and failures

`setStateListener()` is the single public callback for lifecycle state, local
preview readiness and failures. Register it before creating local media.

| State | Meaning |
| --- | --- |
| `IDLE` | No available local media. |
| `PREPARING` | Preparing local media; camera preview awaits a valid frame and view binding. |
| `READY` | Local media is ready; no active realtime connection. |
| `CONNECTING` | Creating the session and joining the room. |
| `CONNECTED` | Connected without an active generation task. |
| `GENERATING` | The generated stream and a usable remote frame are ready. |
| `DISCONNECTING` | Cleaning up resources. |

Image/video creation enters `READY` when preparation completes. Camera creation
returns a track while `PREPARING`; bind it to a preview view to receive `READY`.
A generation or connection failure closes the connection and returns to `READY`
if local media remains available. Failed local preparation rolls back the partial
media and returns directly from `PREPARING` to `IDLE`, without `DISCONNECTING` or
`state.reason`; catch the original error from the creation call. A local-media
runtime error releases local resources and returns to `IDLE` with a failure reason.

States completing a disconnection or full cleanup carry `reason`: `RealtimeReason.NORMAL`,
`RealtimeReason.ORIENTATION_CHANGED`, or `RealtimeReason.failure(error)`.
Use `reason.kind` to distinguish cases and `reason.error` to read the original
`XmaxError`, including its code, API code and HTTP status.
The SDK finishes internal cleanup before notifying the terminal state, so the
listener can start a new operation or close the manager safely.

```ts
const reportedErrors = new WeakSet<XmaxError>();
realtime.setStateListener((state: RealtimeState): void => {
  const error = state.reason?.error;
  if (error !== undefined) {
    reportedErrors.add(error);
    console.error(`${error.code}: ${error.message}`);
  }
});

try {
  const remoteStream = await realtime.startGeneration(localStream, generationContext);
  this.remoteVideoTrack = remoteStream.videoTrack;
} catch (error) {
  const sdkError = XmaxError.from(error);
  if (sdkError.code !== XmaxErrorCode.CANCELLED && !reportedErrors.has(sdkError)) {
    console.error(`Operation failed: ${sdkError.message}`);
  }
}
```

Awaited operations still reject with the original error. Local preparation, validation
or configuration-update failures that do not end a lifecycle remain on the
operation's rejection path. Cancellation rejects with `CANCELLED`; cleanup
failures are logged while cleanup continues. State notifications work even when
logging is disabled; passing `null` to `setStateListener()` removes the listener.

Errors do not carry a severity level. Cleanup depends on the operation and its
stage: connection and generation-start failures close the connection; preparation
failures roll back partially created media, while local runtime failures release
all media. Validation and configuration
update failures leave the current lifecycle intact. Use the state listener for
lifecycle failures and camera readiness.

## Configure SDK logging

SDK logging is **off by default**, in both debug and release builds. Set
`loggerOptions` when creating a client to opt in:

```ts
import {
  XmaxClient,
  XmaxConfiguration,
  XmaxEnvironment,
  XmaxLoggerOption
} from '@xmax/sdk';

const client = new XmaxClient(
  new XmaxConfiguration(
    'YOUR_API_KEY',
    XmaxEnvironment.CHINA,
    XmaxLoggerOption.BUSINESS | XmaxLoggerOption.PERFORMANCE
  ),
  context
);
```

| Option | Output |
| --- | --- |
| `NONE` | No SDK logs (default) |
| `BUSINESS` | API, Room, Realtime, Storage and other operation logs, including errors |
| `PERFORMANCE` | Generation startup timing, RTC stream statistics, network quality and performance alarms |
| `ALL` | Both business and performance logs |

This is an SDK-global setting: the most recently created client's
configuration replaces the previous setting, including `NONE`. Use consistent
options across clients. The XLab example explicitly enables `ALL` for diagnostics.
The switch controls XmaxSDK's HiLog output; host-application logging and the
third-party RTC SDK's own logs have separate controls. Network-quality and
performance-alarm listeners continue to work when their logs are disabled.

## Generation startup timing

Enable `XmaxLoggerOption.PERFORMANCE` or `ALL` to receive `[Xmax][Timing]` HiLog
reports. XLab uses `ALL`, so timing is already enabled there. The internal
`RealtimeTiming` component measures each admitted generation start with a
monotonic clock, from startup through committing `GENERATING` after a usable
remote frame arrives. This is separate from the frame actually appearing in a view.

Successful reports include total startup time and these stages when applicable:

- Realtime connection, including session creation, RTC room join and connection preparation.
- Waiting for matching task SEI, including local request sending.
- Matching the result stream through first-frame readiness.

Successful reports show only the total and these stage durations, without
substage details. A start using an existing connection omits connection setup.
Updating generation conditions and rejected overlapping calls
do not reset the current measurement or create another startup report.

Failures report elapsed time, the pending stage and the failure reason after
operation cleanup; elapsed failure time therefore includes rollback. Cancelled
starts emit no failure timing report. Retries have independent records, and late
SEI or completion from an old task cannot alter a new task's timing. Timing does
not change the operation's error or connection state.

## Runtime information and task IDs

The SDK automatically adds the same cached runtime information to every Xmax API
request and to the top-level `runtime` object in all five room events: `start`,
`change_condition`, `stop`, `tracks`, and `heartbeat`.

| API header | Room `runtime` field | HarmonyOS value |
| --- | --- | --- |
| `X-Platform` | `platform` | `harmonyos` |
| `X-OS-Version` | `os_version` | Distribution OS version, falling back to the full OS name |
| `X-SDK-Version` | `sdk_version` | HAR version, also exported as `XMAX_SDK_VERSION` |
| `X-Device-Model` | `device_model` | Device product model |

Unavailable OS or device information is reported as `unknown`. No application
configuration is required. Runtime metadata is added to API headers, without
changing API request bodies.

Generation task IDs use `task-<id>?os=harmonyos`, where `<id>` contains the full
16 UUID bytes encoded as 22 unpadded Base64URL characters. Room events use that
complete task ID as their `uid`. During camera, image, and video generation, each
outgoing video frame carries UTF-8 SEI in the form
`task-<id>?os=harmonyos&index=<frame-index>`, with the zero-based frame index reset
for each generation task. Incoming SEI is matched by the task identity before `?`; query parameters such
as `os` and `index` do not affect matching. The bare task identity is also accepted.


### 静态图生成与任务重启

使用生成选项可从固定图片开始生成，并在同一 RTC 连接内替换生成任务。本地图片流、静态图和界面展示应保持相同比例。

```typescript
const remote = await manager.startGeneration({
  localStream,
  context: new RealtimeContext(''),
  extraParams: {
    static_generate: true,
    static_image_path: uploadedImageUrl
  }
});

// 复用本地流、RTC 连接及生成条件；静态任务确认后即可交互，普通任务还会等待首帧。
await manager.startGeneration({ restart: true });
```

静态生成参数只通过 `startGeneration(options.extraParams)` 传入，并需要同时提供 `context`；`RealtimeContext` 只包含提示词、参考图和人脸检测配置。SDK 独立缓存静态生成参数，省略 `context` 时可通过 `{ restart: true }` 复用缓存条件；切回常规生成时显式传入 `context`、省略 `extraParams`，并指定 `restart: true`。瞬动与连动均可通过 `RealtimeContext.referencePath` 传参考图。

`XmaxRealtimeVideo` 与 `XmaxRealtimeDualVideo` 支持 `onInteractionChanged`，按有效触点整体通知 `began`、`ended`、`cancelled`；多指交互在末指抬起后才通知结束。`isVideoVisible` 默认 `true`，设为 `false` 可立即隐藏视频画面（组合组件仅隐藏远端画面），保持视频渲染、轨迹绘制和交互绑定，不改变视频容器尺寸。需要原图兜底时，由接入页面在视频组件下方绘制图片；SDK 不接收或绘制业务原图。此前的 `stillImage`、`showsStillImage` 参数已移除，改为由页面管理原图并通过 `isVideoVisible` 控制视频显隐。

静态任务收到当前服务端发来的、任务 ID 匹配的 `video_started`，或匹配当前任务的 SEI 后返回。视频可能要收到拖拽轨迹才开始输出，因此不要求先收到视频 SEI 才允许发送交互。启动信令只确认任务可接收交互，不代表视频已就绪；SDK 仍在匹配新任务 SEI 后绑定结果流。请通过 `onVideoReadyChanged` 判断画面是否可见；进入交互页面时可以先 `connect(localStream)`，首次拖拽时再调用 `startGeneration()`。

任务准备或重建期间可保持 `XmaxRealtimeVideo.isInteractionEnabled` 开启，让本地轨迹持续跟手绘制。没有已确认任务时，SDK 直接丢弃交互采样，不缓存或补发；任务确认后发送后续实时采样。视频是否显示应单独通过 `isVideoVisible` 控制。默认关闭松手续发时，若首次短拖在任务确认前已结束，该次拖拽只有本地轨迹反馈，不会补发到生成任务。

`XmaxRealtimeVideo` 和 `XmaxRealtimeDualVideo` 的 `continuesInteractionAfterRelease` 默认 `false`。开启时，末指松手后仍按 30ms 周期发送最后触点，轨迹绘制和 `ended` 通知仍在实际松手时结束。接入方应在画面保留结束时设回 `false`；新拖拽立即替换旧触点，禁用交互、取消、换轨或卸载会清理续发。该功能发送当前保留的触点，不回放历史轨迹。PetTrack 仅在瞬动期间开启，并与首帧就绪后松手保留 750ms、切回原图的时机同步。

刷新替换任务时，页面应立即隐藏视频并保留原图，直到生成请求完成且 `onVideoReadyChanged(true)` 到达。SDK 不复用上一任务的渲染就绪记录；匹配新任务后，若 RTC 流曾渲染过画面，会重新订阅远端视频并等待新的原生首帧渲染事件。任务确认和解码完成都不会单独触发画面可见通知。同一任务内重新挂载视图仍可复用该任务已经确认的渲染状态。
