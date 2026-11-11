//
//  MediaController.ets
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-HarmonyOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import { MediaService } from '../service/media/MediaService';
import { MediaServicing } from '../service/media/MediaServicing';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import {
  XmaxError,
  XmaxErrorCode
} from '../foundation/errors/XmaxError';
import { XmaxLogger } from '../foundation/logging/XmaxLogger';
import { CameraPosition } from '../foundation/media/camera/CameraPosition';
import { RtcManaging } from '../foundation/rtc/RtcManaging';
import { CameraPreviewReadyHandler } from './camera/CameraPreviewReadyHandler';
import { RealtimeMediaStream } from '../service/realtime/RealtimeMediaStream';
import { RealtimePoint } from '../service/realtime/RealtimePoint';
import { RealtimeVideoFormat } from '../service/realtime/RealtimeVideoFormat';
import { RealtimeCameraZoom } from '../service/realtime/RealtimeCameraZoom';
import { RealtimeVideoTrack } from '../service/realtime/RealtimeVideoTrack';
import { LocalVideoPlaybackState } from '../service/realtime/LocalVideoPlaybackState';
import { StreamControlling } from '../stream/StreamControlling';
import { CameraController } from './camera/CameraController';
import { ImageController } from './image/ImageController';
import { InteractionController } from './interaction/InteractionController';
import { InteractionControlling } from './interaction/InteractionControlling';
import { InteractionFrame } from './interaction/InteractionFrame';
import { MediaControlling } from './MediaControlling';
import { VideoController } from './video/VideoController';
import { ExternalVideoController } from './external/ExternalVideoController';
import { RealtimeExternalVideoSource } from './external/RealtimeExternalVideoSource';

/** A local camera, image, file video, or app-owned external source controller. */
type LocalMediaController = CameraController |
  VideoController |
  ImageController |
  ExternalVideoController;

/**
 * An asynchronous operation creating a local media stream.
 *
 * @returns The local stream for connection, generation, or display.
 */
type LocalMediaCreation = () => Promise<RealtimeMediaStream>;

/** The active local source and its creation, camera update, and stop tasks. */
class ActiveLocalMediaSource {

  // Current media controller

  /** The controller owning this local media source. */
  readonly controller: LocalMediaController;

  // Media operation and stop wait

  /** Whether local media ownership is being released. */
  closing: boolean = false;

  /** The in-flight operation on this media source. */
  operationPromise: Promise<RealtimeMediaStream> | null = null;

  /** The shared Promise for stopping the active source. */
  stopPromise: Promise<void> | null = null;

  /** Creates an active media source record. */
  constructor(
    controller: LocalMediaController
  ) {
    this.controller = controller;
  }
}

/** Coordinates local media ownership and the RTC engine lifecycle. */
export class MediaController implements MediaControlling {

  // Platform media and business components

  /** The adapter for RTC engine, room, and media services. */
  private readonly rtcManager: RtcManaging;

  // Local media components

  /** The controller owning camera capture and preview. */
  private readonly cameraController: CameraController;

  /** The controller owning local image media. */
  private readonly imageController: ImageController;

  /** The controller mapping and sending task interactions. */
  private readonly interactionController: InteractionControlling;

  /** The controller owning local file video media. */
  private readonly videoController: VideoController;

  /** The controller binding app-owned external capture to preview and transport. */
  private readonly externalController: ExternalVideoController;

  // Current local input and lifecycle

  /** The currently owned local media source. */
  private activeSource: ActiveLocalMediaSource | null = null;

  /**
   * Creates a media controller.
   *
   * @param context The context for camera and media permissions.
   * @param rtcManager The RTC services shared by local media sources.
   * @param streamController The controller for encoding and audio/video frame transport.
   * @param errorListener The handler for continuous media output failures.
   * @param mediaService The model sizing service shared by camera, image, and video sources.
   * @param cameraFormatListener The camera output format change handler.
   * @param videoEndedListener The local video playback completion handler.
   */
  constructor(
    context: common.UIAbilityContext,
    rtcManager: RtcManaging,
    streamController: StreamControlling,
    errorListener: (
      error: XmaxError
    ) => void,
    mediaService: MediaServicing = new MediaService(),
    cameraFormatListener: (
      format: RealtimeVideoFormat
    ) => void = (_format: RealtimeVideoFormat): void => { },
    videoEndedListener: () => void = (): void => { }
  ) {
    // Foundation components
    this.rtcManager = rtcManager;

    // Local media components
    this.cameraController = new CameraController(
      context,
      rtcManager,
      streamController,
      mediaService,
      errorListener,
      cameraFormatListener
    );

    this.imageController = new ImageController(
      rtcManager,
      streamController,
      errorListener,
      mediaService
    );

    this.interactionController = new InteractionController((
      taskId: string,
      points: RealtimePoint[]
    ): void => {
      streamController.sendTracks(
        taskId,
        points
      );
    });

    this.externalController = new ExternalVideoController(
      rtcManager,
      streamController,
      mediaService,
      errorListener
    );

    this.videoController = new VideoController(
      context,
      rtcManager,
      streamController,
      errorListener,
      mediaService,
      videoEndedListener
    );
  }

  /** The current local input track, or null without local media. */
  get currentTrack(): RealtimeVideoTrack | null {
    return this.activeSource?.controller.currentTrack ?? null;
  }

  /** The configured camera output format, or null before configuration. */
  get currentVideoFormat(): RealtimeVideoFormat | undefined {
    return this.currentTrack?.videoFormat;
  }

  /** Whether input needs aspect-preserving padding; true for images, videos, and external sources. */
  get usesContainPadding(): boolean {
    const controller = this.activeSource?.controller;
    return controller === this.imageController || controller === this.videoController ||
      controller === this.externalController;
  }

  /** Whether the source uses a camera microphone or an available file audio track. */
  get hasAudio(): boolean {
    if (this.activeSource?.controller === this.cameraController) {
      return this.cameraController.useMicrophone;
    }
    if (this.activeSource?.controller === this.externalController) {
      return this.externalController.hasAudio;
    }
    return this.activeSource?.controller === this.videoController &&
      this.videoController.hasAudio;
  }

  /** The local video file playback state, or undefined before creation or for another media source. */
  get localVideoPlaybackState(): LocalVideoPlaybackState | undefined {
    return this.activeSource?.controller === this.videoController ?
      this.videoController.playbackState : undefined;
  }

  /**
   * Blocks local frame output and detaches preview immediately. Only synchronous silencing occurs
   * here; stopLocalStream completes resource release.
   */
  prepareForClose(): void {
    const source: ActiveLocalMediaSource | null = this.activeSource;
    if (source === null) {
      return;
    }

    source.closing = true;
    try {
      this.prepareControllerForStop(source.controller);
    } catch (error) {
      const reason: string = error instanceof Error ? error.message : String(error);
      XmaxLogger.error(
        `${XmaxLogger.localized("静默本地媒体失败 (Failed to Mute Local Media)\n└─ 原因：", "静默本地媒体失败 (Failed to Mute Local Media)\n└─ Reason: ")}${reason}`,
        'Realtime'
      );
    }
  }

  /** Stops local input and waits for capture, decoding, and publication resources to release. */
  stopLocalStream(): Promise<void> {
    const source: ActiveLocalMediaSource | null = this.activeSource;
    if (source === null) {
      return Promise.resolve();
    }

    return this.stopSource(source.controller);
  }

  /**
   * Sets the camera preview readiness listener.
   *
   * @param listener The preview readiness handler, or null to remove it.
   */
  setCameraPreviewReadyHandler(
    listener: CameraPreviewReadyHandler | null
  ): void {
    this.cameraController.setPreviewReadyListener(listener);
  }

  /** Starts interaction processing for the generation task. */
  start(
    taskId: string,
    videoFormat: RealtimeVideoFormat
  ): void {
    this.interactionController.start(
      taskId,
      videoFormat
    );
  }

  /** Stops generation interaction processing. */
  stop(): void {
    this.interactionController.stop();
  }

  /** Submits viewport touches through the interaction controller. */
  submit(
    frame: InteractionFrame
  ): void {
    this.interactionController.submit(frame);
  }

  /**
   * Creates and owns a local camera source.
   *
   * @param videoFormat The camera stream output format.
   * @param position The initial camera position.
   * @param useMicrophone Whether to use the microphone; creation checks permission and connection
   * starts capture.
   * @param observeDisplayChange Whether to observe display changes; false preserves capture aspect
   * ratio and orientation.
   *
   * @returns The created camera stream.
   */
  createLocalCameraStream(
    videoFormat: RealtimeVideoFormat,
    position: CameraPosition,
    useMicrophone: boolean = false,
    observeDisplayChange: boolean = true
  ): Promise<RealtimeMediaStream> {
    return this.createSource(
      this.cameraController,
      (): Promise<RealtimeMediaStream> =>
        this.cameraController.createLocalCameraStream(
          videoFormat,
          position,
          useMicrophone,
          observeDisplayChange
        )
    );
  }

  /** Updates camera capture and track format for display orientation; other sources are unchanged. */
  updateCameraOrientation(): void {
    if (this.activeSource?.controller === this.cameraController) {
      this.cameraController.updateOrientation();
    }
  }

  /** Reads zoom from the active camera source rather than a cached lens configuration. */
  get currentCameraZoom(): RealtimeCameraZoom | undefined {
    const source: ActiveLocalMediaSource | null = this.activeSource;
    return source !== null && source.controller === this.cameraController && !source.closing ?
      this.cameraController.currentZoom : undefined;
  }

  /** Changes zoom on the owned camera source. */
  setCameraZoomRatio(
    ratio: number
  ): void {
    const source: ActiveLocalMediaSource | null = this.activeSource;
    if (source === null || source.controller !== this.cameraController || source.closing ||
      source.operationPromise !== null || source.stopPromise !== null) {
      throw new XmaxError(
        XmaxErrorCode.INVALID_CONFIGURATION,
        'Camera zoom requires an active camera without a conflicting media operation'
      );
    }

    this.cameraController.setZoomRatio(ratio);
  }

  /**
   * Updates the active camera output while retaining its track and view bindings.
   *
   * @param videoFormat The new output dimensions, frame rate, and encoding settings.
   */
  async updateCameraFormat(
    videoFormat: RealtimeVideoFormat
  ): Promise<void> {
    await this.updateCameraSource(
      (): Promise<RealtimeMediaStream> => this.cameraController.updateVideoFormat(videoFormat)
    );
  }

  /** Starts the current camera microphone on connection, if enabled. */
  startMicrophoneCapture(): void {
    if (this.activeSource?.controller === this.cameraController) {
      this.cameraController.startMicrophoneCapture();
    }
  }

  /** Stops camera microphone capture while retaining reconnection settings. */
  stopMicrophoneCapture(): void {
    if (this.activeSource?.controller === this.cameraController) {
      this.cameraController.stopMicrophoneCapture();
    }
  }

  /**
   * Stops the local camera stream and releases preview resources.
   *
   * The Promise fulfills after the camera source stops.
   */
  stopLocalCameraStream(): Promise<void> {
    return this.stopSource(this.cameraController);
  }

  /**
   * Switches cameras, retaining the connection and restoring cached conditions during generation.
   *
   * @returns The local stream after camera switching.
   */
  switchCamera(): Promise<RealtimeMediaStream> {
    return this.updateCameraSource(
      (): Promise<RealtimeMediaStream> => this.cameraController.switchCamera()
    );
  }

  /**
   * Creates and owns a local video file source.
   *
   * @param filePath The local video file path.
   * @param videoFormat The optional video output format.
   * @param loop Whether to loop after file completion.
   *
   * @returns The created local video stream.
   */
  createLocalVideoStream(
    filePath: string,
    videoFormat?: RealtimeVideoFormat,
    loop: boolean = true
  ): Promise<RealtimeMediaStream> {
    return this.createSource(
      this.videoController,
      (): Promise<RealtimeMediaStream> =>
        this.videoController.createLocalVideoStream(
          filePath,
          videoFormat,
          loop
        )
    );
  }

  /**
   * Stops the local video stream and releases preview resources.
   *
   * The Promise fulfills after the video source stops.
   */
  stopLocalVideoStream(): Promise<void> {
    return this.stopSource(this.videoController);
  }

  /** Binds app-owned capture while retaining normal local stream ownership and rollback. */
  createExternalVideoStream(
    source: RealtimeExternalVideoSource
  ): Promise<RealtimeMediaStream> {
    return this.createSource(
      this.externalController,
      (): Promise<RealtimeMediaStream> => this.externalController.createExternalVideoStream(source)
    );
  }

  /** Unbinds the external source without taking ownership of the app's devices or player. */
  stopExternalVideoStream(): Promise<void> {
    return this.stopSource(this.externalController);
  }

  /** Pauses the current video source and starts frozen-frame publication. */
  pauseLocalVideoStream(): Promise<void> {
    if (this.activeSource?.controller !== this.videoController) {
      return Promise.reject(new XmaxError(
        XmaxErrorCode.INVALID_CONFIGURATION,
        'Create a local video stream before pausing it'
      ));
    }
    return this.videoController.pauseLocalVideoStream();
  }

  /** Resumes the video source at its paused media position. */
  resumeLocalVideoStream(): void {
    if (this.activeSource?.controller !== this.videoController) {
      throw new XmaxError(
        XmaxErrorCode.INVALID_CONFIGURATION,
        'Create a local video stream before resuming it'
      );
    }
    this.videoController.resumeLocalVideoStream();
  }

  /**
   * Creates and owns a local image source.
   *
   * @param source A local file path, encoded image bytes, or platform PixelMap.
   * @param videoFormat The optional video output format.
   *
   * @returns The created local image stream.
   */
  createLocalImageStream(
    source: string | ArrayBuffer | Uint8Array | image.PixelMap,
    videoFormat?: RealtimeVideoFormat
  ): Promise<RealtimeMediaStream> {
    return this.createSource(
      this.imageController,
      (): Promise<RealtimeMediaStream> =>
        this.imageController.createLocalImageStream(
          source,
          videoFormat
        )
    );
  }

  /**
   * Stops the local image stream and releases preview resources.
   *
   * The Promise fulfills after the image source stops.
   */
  stopLocalImageStream(): Promise<void> {
    return this.stopSource(this.imageController);
  }

  /**
   * Checks whether the active source created and owns a stream.
   *
   * @param stream The local stream to check.
   *
   * @returns True if the stream belongs to the active source.
   */
  owns(
    stream: RealtimeMediaStream
  ): boolean {
    const track: RealtimeVideoTrack | undefined = stream.videoTrack;
    return track !== undefined && this.currentTrack === RealtimeVideoTrack.resolve(track);
  }

  /**
   * Enables local file audio preview independently of RTC audio output.
   *
   * @param enabled Whether to play local preview audio.
   */
  setLocalAudioPreviewEnabled(
    enabled: boolean
  ): void {
    if (this.activeSource?.controller === this.videoController) {
      this.videoController.setLocalAudioPreviewEnabled(enabled);
    }
  }

  /** The configured local file preview volume in 0 to 1; zero mutes and one uses original volume. */
  get localAudioVolume(): number {
    return this.videoController.localAudioVolume;
  }

  /**
   * Sets and retains local file preview volume in 0 to 1.
   *
   * @param volume The volume in 0 to 1, from muted to original volume.
   */
  async setLocalAudioVolume(
    volume: number
  ): Promise<void> {
    await this.videoController.setLocalAudioVolume(volume);
  }

  /**
   * Creates a media source only when no source is active.
   *
   * @param controller The controller for the requested media type.
   * @param create The operation creating the local stream.
   *
   * @returns The created local stream.
   */
  private async createSource(
    controller: LocalMediaController,
    create: LocalMediaCreation
  ): Promise<RealtimeMediaStream> {
    if (this.activeSource !== null) {
      throw new XmaxError(
        XmaxErrorCode.INVALID_CONFIGURATION,
        'Stop the current local media stream before creating another one'
      );
    }

    const source = new ActiveLocalMediaSource(controller);
    this.activeSource = source;

    const creationPromise: Promise<RealtimeMediaStream> = this.performCreate(
      source,
      create
    );
    source.operationPromise = creationPromise;

    try {
      return await creationPromise;
    } finally {
      if (source.operationPromise === creationPromise) {
        source.operationPromise = null;
      }
    }
  }

  /**
   * Updates capture while the camera source has no conflicting media operation.
   *
   * @param update The camera source update operation.
   *
   * @returns The updated local stream.
   */
  private async updateCameraSource(
    update: LocalMediaCreation
  ): Promise<RealtimeMediaStream> {
    const source: ActiveLocalMediaSource | null = this.activeSource;
    if (source === null || source.controller !== this.cameraController) {
      throw new XmaxError(
        XmaxErrorCode.INVALID_CONFIGURATION,
        'Create a local camera stream before updating it'
      );
    }
    if (source.closing || source.operationPromise !== null || source.stopPromise !== null) {
      throw new XmaxError(
        XmaxErrorCode.INVALID_CONFIGURATION,
        'Another local media operation is already in progress'
      );
    }

    const updatePromise: Promise<RealtimeMediaStream> = update();
    source.operationPromise = updatePromise;

    try {
      return await updatePromise;
    } finally {
      if (source.operationPromise === updatePromise) {
        source.operationPromise = null;
      }
    }
  }

  /**
   * Initializes RTC before creating the first local source.
   *
   * @param source The active source record.
   * @param create The operation creating the local stream.
   *
   * @returns The created local stream.
   */
  private async performCreate(
    source: ActiveLocalMediaSource,
    create: LocalMediaCreation
  ): Promise<RealtimeMediaStream> {
    try {
      await this.rtcManager.initialize();
      this.ensureCreationActive(source);

      const stream: RealtimeMediaStream = await create();
      this.ensureCreationActive(source);

      return stream;
    } catch (error) {
      if (source.stopPromise === null) {
        // The lifecycle manager waits for creation before cleanup. If closure wins the race,
        // release newly created media before clearing ownership and destroying RTC.
        try {
          await this.stopController(source.controller);
        } catch (cleanupError) {
          XmaxLogger.error(
            `${XmaxLogger.localized("回滚本地媒体失败 (Local Media Rollback Failed)\n└─ 原因：", "回滚本地媒体失败 (Local Media Rollback Failed)\n└─ Reason: ")}${XmaxError.from(cleanupError).message}`,
            'Realtime'
          );
        }

        await this.destroyRtcSafely("本地媒体创建回滚失败 (Local Media Creation Rollback Failed)");

        if (this.activeSource === source) {
          this.activeSource = null;
        }
      }

      throw XmaxError.from(error);
    }
  }

  /**
   * Returns or creates the source's stop task.
   *
   * The Promise fulfills after source stopping.
   *
   * @param controller The media controller to stop.
   */
  private stopSource(
    controller: LocalMediaController
  ): Promise<void> {
    const source: ActiveLocalMediaSource | null = this.activeSource;
    if (source === null || source.controller !== controller) {
      return Promise.resolve();
    }
    if (source.stopPromise !== null) {
      return source.stopPromise;
    }

    source.closing = true;
    const stopPromise: Promise<void> = this.performStop(source);
    source.stopPromise = stopPromise;

    return stopPromise;
  }

  /**
   * Waits for media work, then releases source and RTC resources.
   *
   * The Promise fulfills after all resources are released.
   *
   * @param source The active source to stop.
   */
  private async performStop(
    source: ActiveLocalMediaSource
  ): Promise<void> {
    const operationPromise: Promise<RealtimeMediaStream> | null =
      source.operationPromise;
    if (operationPromise !== null) {
      try {
        await operationPromise;
      } catch (error) {
        if (!this.isCancelled(error)) {
          const reason: string = error instanceof Error ?
            error.message : String(error);
          XmaxLogger.error(
            `${XmaxLogger.localized("等待本地媒体创建结束失败 (Failed to Wait for Local Media Creation)\n└─ 原因：", "等待本地媒体创建结束失败 (Failed to Wait for Local Media Creation)\n└─ Reason: ")}${reason}`,
            'Realtime'
          );
        }
      }
    }

    try {
      await this.stopController(source.controller);
    } finally {
      await this.destroyRtcSafely("释放本地媒体 RTC 资源失败 (Failed to Release Local Media RTC Resources)");

      if (this.activeSource === source) {
        this.activeSource = null;
      }
    }
  }

  /**
   * Dispatches stop requests to the active source controller.
   *
   * The Promise fulfills after the source controller stops.
   *
   * @param controller The media controller to stop.
   */
  private stopController(
    controller: LocalMediaController
  ): Promise<void> {
    if (controller === this.cameraController) {
      return this.cameraController.stopLocalCameraStream();
    }
    if (controller === this.videoController) {
      return this.videoController.stopLocalVideoStream();
    }
    if (controller === this.externalController) {
      return this.externalController.stopExternalVideoStream();
    }

    return this.imageController.stopLocalImageStream();
  }

  /**
   * Dispatches synchronous silencing to the active media controller.
   *
   * @param controller The media controller whose output stops immediately.
   */
  private prepareControllerForStop(
    controller: LocalMediaController
  ): void {
    if (controller === this.cameraController) {
      this.cameraController.prepareForStop();
      return;
    }
    if (controller === this.videoController) {
      this.videoController.prepareForStop();
      return;
    }
    if (controller === this.externalController) {
      this.externalController.prepareForStop();
      return;
    }

    this.imageController.prepareForStop();
  }

  /**
   * Verifies creation or replacement still owns local media.
   *
   * @param source The active source recorded when the operation began.
   */
  private ensureCreationActive(
    source: ActiveLocalMediaSource
  ): void {
    if (this.activeSource === source && !source.closing &&
      source.stopPromise === null) {
      return;
    }

    throw new XmaxError(
      XmaxErrorCode.CANCELLED,
      'Local media stream creation was cancelled'
    );
  }

  /**
   * Releases RTC and logs failures without replacing the original operation error.
   *
   * The Promise fulfills after the release attempt.
   *
   * @param message The release failure log description.
   */
  private async destroyRtcSafely(
    message: string
  ): Promise<void> {
    try {
      await this.rtcManager.destroy();
    } catch (error) {
      const reason: string = error instanceof Error ?
        error.message : String(error);
      XmaxLogger.error(
        `${message}${XmaxLogger.localized("\n└─ 原因：", "\n└─ Reason: ")}${reason}`,
        'Realtime'
      );
    }
  }

  /**
   * Checks whether an error represents lifecycle cancellation.
   *
   * @param error The error to check.
   *
   * @returns True if the error code is CANCELLED.
   */
  private isCancelled(
    error: Object
  ): boolean {
    return error instanceof XmaxError &&
      error.code === XmaxErrorCode.CANCELLED;
  }

}
