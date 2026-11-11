//
//  XmaxRealtimeManaging.ets
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-HarmonyOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import { RealtimeGenerationOptions } from '../../service/realtime/RealtimeGenerationOptions';
import { UplinkVideoStatisticsListener, DownlinkVideoStatisticsListener } from '../../foundation/rtc/VideoStatistics';
import { RealtimeMediaFrameListener } from '../../service/realtime/RealtimeMediaFrame';
import { image } from '@kit.ImageKit';
import { CameraPosition } from '../../foundation/media/camera/CameraPosition';
import { RealtimeContext } from '../../service/realtime/RealtimeContext';
import { RealtimeMediaStream } from '../../service/realtime/RealtimeMediaStream';
import { RealtimeNetworkQualityListener } from '../../service/realtime/RealtimeNetworkQuality';
import { RealtimePerformanceAlarmListener } from '../../service/realtime/RealtimePerformanceAlarm';
import {
  RealtimeReason,
  RealtimeState,
  RealtimeStateListener
} from '../../service/realtime/RealtimeState';
import { RealtimeVideoFormat } from '../../service/realtime/RealtimeVideoFormat';
import { RealtimeCameraZoom } from '../../service/realtime/RealtimeCameraZoom';
import {
  LocalVideoPlaybackState,
  LocalVideoPlaybackStateListener
} from '../../service/realtime/LocalVideoPlaybackState';
import { RealtimeConfiguration } from './RealtimeConfiguration';
import { RealtimeExternalVideoSource } from '../../media/external/RealtimeExternalVideoSource';
import { RealtimeQualityLevel } from '../../stream/quality/RealtimeQualityLevel';

/** An interface for local media, realtime connections, and video generation. */
export interface XmaxRealtimeManaging {

  /** The realtime configuration. */
  readonly options: RealtimeConfiguration;

  /** The current realtime connection state. */
  readonly currentState: RealtimeState;

  /** The camera's local output format, or undefined without a camera stream. Uplink quality does not affect it. */
  readonly currentCameraVideoFormat: RealtimeVideoFormat | undefined;

  /**
   * The active camera's zoom, or undefined when adjustable zoom is unavailable.
   *
   * Read again after switching cameras. A newly submitted ratio may take a few frames to appear.
   */
  readonly currentCameraZoom: RealtimeCameraZoom | undefined;

  /** The applied uplink level, or undefined before connection completes or after cleanup begins. */
  readonly uplinkQualityLevel: RealtimeQualityLevel | undefined;

  /**
   * The submitted downlink level, or undefined before connection completes or after cleanup begins.
   * The server may start returning the new dimensions after this value changes.
   */
  readonly downlinkQualityLevel: RealtimeQualityLevel | undefined;

  /**
   * Changes uplink encoding during generation without changing capture or generation dimensions.
   * Automatic adaptation may subsequently change the level; manual selection does not lock it.
   *
   * The Promise rejects for an invalid level or state, a conflicting or cancelled operation, or
   * encoder configuration failure. It fulfills after local encoder configuration is submitted.
   *
   * @param level The requested uplink quality level.
   */
  setUplinkQualityLevel(
    level: RealtimeQualityLevel
  ): Promise<void>;

  /**
   * Changes returned dimensions and bitrate during generation without restarting the task.
   * Automatic adaptation may subsequently change the level; manual selection does not lock it.
   *
   * The Promise rejects for an invalid level or state, a conflicting or cancelled operation, or
   * signaling failure. It fulfills after signal submission, not after the server applies it.
   *
   * @param level The requested downlink quality level.
   */
  setDownlinkQualityLevel(
    level: RealtimeQualityLevel
  ): Promise<void>;

  /**
   * The configured local file preview volume in 0 to 1, default 0.45, independent of automatic
   * generation muting.
   */
  readonly localAudioVolume: number;

  /**
   * The remote volume in 0 to 1 at RTC percentage precision; camera/image creation resets it to
   * zero, video creation to one.
   */
  readonly remoteAudioVolume: number;

  /** The local file playback state, or undefined before creation or for another media source. */
  readonly localVideoPlaybackState: LocalVideoPlaybackState | undefined;

  /**
   * Sets lifecycle notifications for local preparation, preview readiness, and termination or
   * failure through state.reason.
   *
   * @param listener The state handler, or null to remove it.
   */
  setStateListener(
    listener: RealtimeStateListener | null
  ): void;

  /**
   * Sets the local file playback listener and immediately delivers the current valid state.
   *
   * @param listener The event handler, or null to remove it.
   */
  setLocalVideoPlaybackStateListener(
    listener: LocalVideoPlaybackStateListener | null
  ): void;

  /**
   * Delivers copied PCM and processed video for the current result binding without changing audio
   * subscriptions or playback volume. Null removes the receiver and queued unified output.
   *
   * Callbacks run in arrival order on the ArkTS event loop, not in cross-track timestamp order.
   * At most 256 packets and 32 MiB are retained; overflow drops new packets and marks the next
   * admitted event of that track as discontinuous. Buffers remain valid after callback return.
   * Delivery stops immediately on disconnect or close; registration remains for later generation.
   *
   * Audio time advances by sample count from RTC audio time; video retains RTC video time. The
   * provider's cross-track clock relationship is not guaranteed by this API. Validate it before
   * using these timestamps for synchronized recording. Move expensive callback work to a Worker.
   *
   * @param listener The unified media receiver, or null to remove it.
   *
   * @throws An error if observation of an already-bound result cannot be enabled.
   */
  setRemoteMediaFrameListener(
    listener: RealtimeMediaFrameListener | null
  ): void;

  /**
   * Sets the realtime network quality listener.
   *
   * @param listener The network quality handler, or null to remove it.
   */
  setNetworkQualityListener(
    listener: RealtimeNetworkQualityListener | null
  ): void;

  /**
   * Sets uplink statistics delivery; null removes it. Unpublishing or disconnecting delivers
   * undefined to clear statistics.
   *
   * @param listener The uplink statistics handler, receiving undefined to clear values; null
   * removes it.
   */
  setUplinkVideoStatisticsListener(
    listener: UplinkVideoStatisticsListener | null
  ): void;

  /**
   * Sets current result-stream statistics delivery; null removes it. Stream cleanup delivers
   * undefined.
   *
   * @param listener The current result-stream statistics handler, receiving undefined to clear
   * values; null removes it.
   */
  setDownlinkVideoStatisticsListener(
    listener: DownlinkVideoStatisticsListener | null
  ): void;

  /**
   * Sets the device performance alarm listener.
   *
   * @param listener The performance alarm handler, or null to remove it.
   */
  setPerformanceAlarmListener(
    listener: RealtimePerformanceAlarmListener | null
  ): void;

  /**
   * Sets local file preview volume without affecting uploaded audio or automatic generation muting.
   * Can be set before local stream creation and is retained after stopping or replacing video.
   *
   * The Promise rejects for invalid input or configuration failure.
   *
   * @param volume A finite volume in 0 to 1; zero mutes, one uses original volume, and the default
   * is 0.45.
   */
  setLocalAudioVolume(
    volume: number
  ): Promise<void>;

  /**
   * Sets remote playback volume, retained for later subscriptions and reconnections. Successful
   * camera/image creation resets it to zero; video creation resets it to one. Override volume after
   * stream creation.
   *
   * The Promise rejects for invalid input or configuration failure.
   *
   * @param volume A finite volume in 0 to 1; zero mutes, one uses original volume, and the value
   * before local stream creation is one.
   */
  setRemoteAudioVolume(
    volume: number
  ): Promise<void>;

  /**
   * Creates a camera stream for preview. Bind its track to a view; READY requires a valid frame and
   * preview binding.
   *
   * @param videoFormat The local video format; defaults to the model's camera format.
   * @param position The initial camera position; defaults to front.
   * @param useMicrophone Whether to use the microphone, default false. Creation requests
   * permission; connection starts capture and disconnection stops it.
   * @param observeDisplayChange Whether to observe display changes, default true. False preserves
   * capture orientation and ratio without rotation-triggered generation restarts.
   *
   * @returns The local media stream.
   */
  createLocalCameraStream(
    videoFormat?: RealtimeVideoFormat,
    position?: CameraPosition,
    useMicrophone?: boolean,
    observeDisplayChange?: boolean
  ): Promise<RealtimeMediaStream>;

  /**
   * Updates a ready, disconnected camera stream while retaining its track and view bindings.
   *
   * The Promise fulfills after output and track configuration. It rejects for an invalid state or
   * format, a conflicting or cancelled operation, or configuration failure.
   *
   * @param videoFormat The new output dimensions, frame rate, and encoding settings. Dimensions
   * must satisfy the model's camera constraints.
   */
  updateCameraFormat(
    videoFormat: RealtimeVideoFormat
  ): Promise<void>;

  /**
   * Submits a zoom change to the active camera without replacing the local stream or generation task.
   *
   * Available in READY, CONNECTED, and GENERATING when no other realtime operation is active.
   * The change affects both local preview and uplink; the camera may apply it on a later frame.
   *
   * @param ratio A finite multiplier within the current camera's supported range. CameraKit uses
   * up to two decimal places of precision.
   *
   * @throws XmaxError If zoom is unavailable, the ratio is out of range, or the camera rejects it.
   */
  setCameraZoomRatio(
    ratio: number
  ): void;

  /**
   * Stops the local camera stream and releases local preview resources.
   *
   * The Promise fulfills after stopping completes.
   */
  stopLocalCameraStream(): Promise<void>;

  /**
   * Switches front and rear cameras. During generation, replaces the task using cached conditions
   * while retaining the RTC connection. Unavailable while connection or generation startup is in
   * progress.
   *
   * @returns The local stream with its updated camera position.
   */
  switchCamera(): Promise<RealtimeMediaStream>;

  /**
   * Creates a local media stream from a device video file.
   *
   * The Promise rejects with INVALID_CONFIGURATION if output dimensions violate model constraints.
   *
   * @param filePath The local video file path.
   * @param videoFormat The output format; defaults to dimensions resolved from video display size
   * and the model frame rate. An explicit frame rate is preserved.
   * @param loop Whether to loop, default true. False stops audio/video delivery and reports ENDED
   * at completion, preserving generation and connection.
   *
   * @returns The local media stream for connection.
   */
  createLocalVideoStream(
    filePath: string,
    videoFormat?: RealtimeVideoFormat,
    loop?: boolean
  ): Promise<RealtimeMediaStream>;

  /**
   * Stops the local file video stream and releases local preview resources.
   *
   * The Promise fulfills after stopping completes.
   */
  stopLocalVideoStream(): Promise<void>;

  /**
   * Binds app-owned external video and optional PCM audio for preview and generation.
   * Preserves source frame rate and encoding settings while resolving model pixel limits and
   * four-pixel alignment. Submit original dimensions; sink.videoFormat exposes processed dimensions.
   * Binding completion marks READY without waiting for a frame or establishing a connection.
   * Disconnect preserves input and preview. No camera or microphone permission is requested.
   *
   * @param source The app-owned producer with immutable videoFormat and hasAudio while bound.
   * @returns A local stream for SDK views, connection, and generation.
   */
  createExternalVideoStream(
    source: RealtimeExternalVideoSource
  ): Promise<RealtimeMediaStream>;

  /**
   * Invalidates the sink, clears preview, and calls source.stop without releasing app-owned devices.
   * Disconnect first; rejects conflicting or cancelled operations and active connections.
   */
  stopExternalVideoStream(): Promise<void>;

  /** Pauses local video while RTC continues sending a frozen frame and silent audio. */
  pauseLocalVideoStream(): Promise<void>;

  /** Resumes local video from its paused position. */
  resumeLocalVideoStream(): Promise<void>;

  /** Toggles local video between playing and paused. */
  toggleLocalVideoStreamPlayback(): Promise<void>;

  /**
   * Creates a continuous video frame stream from image input.
   *
   * The Promise rejects with INVALID_CONFIGURATION if output dimensions violate model constraints.
   *
   * @param source A local file path, encoded image bytes, or platform PixelMap.
   * @param videoFormat The output format; defaults to dimensions resolved from the image and the
   * model frame rate. An explicit frame rate is preserved.
   *
   * @returns The local media stream for connection.
   */
  createLocalImageStream(
    source: string | ArrayBuffer | Uint8Array | image.PixelMap,
    videoFormat?: RealtimeVideoFormat
  ): Promise<RealtimeMediaStream>;

  /**
   * Stops the local image stream and releases local preview resources.
   *
   * The Promise fulfills after stopping completes.
   */
  stopLocalImageStream(): Promise<void>;

  /**
   * Establishes a realtime connection using an existing local stream.
   *
   * @param localStream The local media stream created by this manager.
   *
   * @returns The remote stream after connection completes.
   */
  connect(
    localStream: RealtimeMediaStream
  ): Promise<RealtimeMediaStream>;

  /**
   * Disconnects realtime while preserving the local stream and preview. Cancels pending connection
   * and generation work, reporting the cleanup reason through state.reason. Returns immediately
   * without changing local preparation or preview state if no connection-related work exists.
   *
   * The Promise fulfills after affected work, session rollback, and connection cleanup complete.
   *
   * @param reason The disconnection reason; defaults to RealtimeReason.NORMAL.
   */
  disconnect(
    reason?: RealtimeReason
  ): Promise<void>;

  /**
   * Closes the realtime lifecycle and releases local media, the connection, and the RTC engine.
   * Stops frame delivery and detaches rendering immediately; remaining resources are released
   * asynchronously.
   *
   * Concurrent calls share a Promise that fulfills after all realtime resources are released.
   */
  close(): Promise<void>;

  /**
   * Starts generation or updates conditions for the active task.
   *
   * Requires an existing connection. New tasks await result confirmation and, unless static,
   * first-frame readiness. Condition updates complete after signal submission, not after display.
   *
   * @param context The generation conditions, required for the first request.
   * @param faceRestoration Whether to restore the original face; defaults to false per call and can
   * change during generation.
   */
  startGeneration(
    context?: RealtimeContext,
    faceRestoration?: boolean
  ): Promise<void>;

  /**
   * Starts or updates generation; restart replaces the task while preserving the connection and
   * local stream.
   *
   * Static-task display readiness is reported by the view. Condition updates complete after their
   * signal is submitted, not after the result is displayed.
   *
   * @param options The local stream, generation conditions, static image parameters, and restart
   * settings.
   *
   * @returns The remote stream after confirmation; ordinary tasks also await the first frame.
   */
  startGeneration(
    options: RealtimeGenerationOptions
  ): Promise<RealtimeMediaStream>;

  /**
   * Connects the local stream if necessary, reuses connections, and updates active generation
   * conditions.
   *
   * @param localStream The current local stream owned by this manager.
   * @param context The initial conditions, required for the first request; omission reuses
   * conditions within the same connection.
   * @param faceRestoration Whether to restore the original face; defaults to false per call and can
   * change during generation.
   *
   * @returns The remote stream after startup confirmation and first-frame readiness, or condition
   * signal submission when updating an active task.
   */
  startGeneration(
    localStream: RealtimeMediaStream,
    context?: RealtimeContext,
    faceRestoration?: boolean
  ): Promise<RealtimeMediaStream>;
}
