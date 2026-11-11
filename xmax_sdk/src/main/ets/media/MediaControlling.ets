//
//  MediaControlling.ets
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-HarmonyOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import { image } from '@kit.ImageKit';
import { CameraPosition } from '../foundation/media/camera/CameraPosition';
import { CameraPreviewReadyHandler } from './camera/CameraPreviewReadyHandler';
import { RealtimeMediaStream } from '../service/realtime/RealtimeMediaStream';
import { RealtimeVideoFormat } from '../service/realtime/RealtimeVideoFormat';
import { RealtimeCameraZoom } from '../service/realtime/RealtimeCameraZoom';
import { RealtimeVideoTrack } from '../service/realtime/RealtimeVideoTrack';
import { LocalVideoPlaybackState } from '../service/realtime/LocalVideoPlaybackState';
import { InteractionControlling } from './interaction/InteractionControlling';
import { RealtimeExternalVideoSource } from './external/RealtimeExternalVideoSource';

/** The media layer interface used by Core. */
export interface MediaControlling extends InteractionControlling {

  /** The local file preview volume in 0 to 1; defaults to 0.45. */
  readonly localAudioVolume: number;

  /** @returns The active local track, or null without a source. */
  readonly currentTrack: RealtimeVideoTrack | null;

  /** @returns The local video format, or null without an active track. */
  readonly currentVideoFormat: RealtimeVideoFormat | undefined;

  /** The active camera's zoom, or undefined when adjustable zoom is unavailable. */
  readonly currentCameraZoom: RealtimeCameraZoom | undefined;

  /**
   * Images and videos use contain padding in the canvas; cameras require fixed supported
   * dimensions.
   */
  readonly usesContainPadding: boolean;

  /** @returns Whether the source includes SDK-managed local audio. */
  readonly hasAudio: boolean;

  /** The active video file playback state, absent for other sources. */
  readonly localVideoPlaybackState: LocalVideoPlaybackState | undefined;

  /**
   * Blocks local frame output and detaches preview immediately. Only synchronous silencing occurs
   * here; stopLocalStream completes resource release.
   */
  prepareForClose(): void;

  /**
   * Stops local input and waits for capture, decoding, and publication resources to release.
   *
   * The Promise fulfills after local media and RTC engine release.
   */
  stopLocalStream(): Promise<void>;

  /**
   * Sets the camera preview readiness listener.
   *
   * @param listener The preview readiness handler, or null to remove it.
   */
  setCameraPreviewReadyHandler(
    listener: CameraPreviewReadyHandler | null
  ): void;

  /**
   * Creates and owns a camera stream, starting capture and preview.
   *
   * @param videoFormat The camera capture and RTC encoding format.
   * @param position The initial camera position.
   * @param useMicrophone Whether to use the microphone, default false. Creation checks permission;
   * connection starts capture.
   * @param observeDisplayChange Whether to observe display changes, default true. False preserves
   * capture aspect ratio and orientation.
   *
   * @returns The local camera media stream.
   */
  createLocalCameraStream(
    videoFormat: RealtimeVideoFormat,
    position: CameraPosition,
    useMicrophone?: boolean,
    observeDisplayChange?: boolean
  ): Promise<RealtimeMediaStream>;

  /** Updates camera capture and track format for display orientation; other sources are unchanged. */
  updateCameraOrientation(): void;

  /**
   * Updates the active camera output while retaining its track and view bindings.
   *
   * @param videoFormat The new output dimensions, frame rate, and encoding settings.
   */
  updateCameraFormat(
    videoFormat: RealtimeVideoFormat
  ): Promise<void>;

  /** Submits a zoom multiplier within the active camera's supported range. */
  setCameraZoomRatio(
    ratio: number
  ): void;

  /** Starts the current camera microphone on connection, if enabled. */
  startMicrophoneCapture(): void;

  /** Stops camera microphone capture while retaining reconnection settings. */
  stopMicrophoneCapture(): void;

  /**
   * Stops the local camera stream and releases preview resources.
   *
   * The Promise fulfills after camera source release.
   */
  stopLocalCameraStream(): Promise<void>;

  /**
   * Switches cameras, retaining the connection and restoring cached conditions during generation.
   *
   * @returns The local stream after camera switching.
   */
  switchCamera(): Promise<RealtimeMediaStream>;

  /**
   * Creates and owns a local file video stream.
   *
   * @param filePath The readable local video file path.
   * @param videoFormat The optional target format, resolved from file metadata if omitted.
   * @param loop Whether to loop after file completion.
   *
   * @returns The local stream delivering file audio and video frames, looping if configured.
   */
  createLocalVideoStream(
    filePath: string,
    videoFormat?: RealtimeVideoFormat,
    loop?: boolean
  ): Promise<RealtimeMediaStream>;

  /**
   * Stops the local video stream and releases preview resources.
   *
   * The Promise fulfills after video file source release.
   */
  stopLocalVideoStream(): Promise<void>;

  /** Binds app-owned external frames for preview and generation, with optional PCM audio. */
  createExternalVideoStream(
    source: RealtimeExternalVideoSource
  ): Promise<RealtimeMediaStream>;

  /** Invalidates the external sink and unbinds its source, without releasing app-owned devices. */
  stopExternalVideoStream(): Promise<void>;

  /** Pauses the current video source and starts frozen-frame publication. */
  pauseLocalVideoStream(): Promise<void>;

  /** Resumes the video source at its paused media position. */
  resumeLocalVideoStream(): void;

  /**
   * Creates and owns a continuous image frame stream.
   *
   * @param source A local file path, encoded image bytes, or platform PixelMap.
   * @param videoFormat The optional target format, resolved from image metadata if omitted.
   *
   * @returns The local stream delivering continuous image frames.
   */
  createLocalImageStream(
    source: string | ArrayBuffer | Uint8Array | image.PixelMap,
    videoFormat?: RealtimeVideoFormat
  ): Promise<RealtimeMediaStream>;

  /**
   * Stops the local image stream and releases preview resources.
   *
   * The Promise fulfills after image source release.
   */
  stopLocalImageStream(): Promise<void>;

  /**
   * Checks whether the active source owns a media stream.
   *
   * @param stream The stream whose ownership is checked.
   *
   * @returns True if the active source owns the stream's video track.
   */
  owns(
    stream: RealtimeMediaStream
  ): boolean;

  /**
   * Enables local file audio preview independently of RTC audio output.
   *
   * @param enabled Whether to play local preview audio.
   */
  setLocalAudioPreviewEnabled(
    enabled: boolean
  ): void;

  /**
   * Sets and retains local file preview volume in 0 to 1.
   *
   * @param volume The volume in 0 to 1, from muted to original volume.
   */
  setLocalAudioVolume(
    volume: number
  ): Promise<void>;
}
