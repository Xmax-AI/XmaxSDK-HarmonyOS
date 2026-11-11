//
//  XmaxRealtimeManager.ets
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-HarmonyOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import { RealtimeGenerationOptions, RealtimeGenerationParameters } from '../../service/realtime/RealtimeGenerationOptions';
import { UplinkVideoStatisticsListener, DownlinkVideoStatisticsListener } from '../../foundation/rtc/VideoStatistics';
import { ImageSize } from '../../service/media/ImageSize';
import { QualityConfiguration, QualityChange } from '../../stream/quality/QualityConfiguration';
import { QualityVideoFormat } from '../../stream/quality/QualityVideoFormat';
import { QualityPreferences } from '../../stream/quality/QualityPreferences';
import { RealtimeNetworkQuality } from '../../service/realtime/RealtimeNetworkQuality';
import { RealtimeVideoTrack, setRealtimeVideoTrackOrientationHandler, updateRealtimeVideoTrackOrientation } from '../../service/realtime/RealtimeVideoTrack';
import {
  LocalVideoPlaybackState,
  LocalVideoPlaybackStateListener
} from '../../service/realtime/LocalVideoPlaybackState';
import { RealtimeMediaFrameListener } from '../../service/realtime/RealtimeMediaFrame';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import {
  XmaxError,
  XmaxErrorCode
} from '../../foundation/errors/XmaxError';
import { XmaxLogger } from '../../foundation/logging/XmaxLogger';
import { CameraPosition } from '../../foundation/media/camera/CameraPosition';
import { RtcManager } from '../../foundation/rtc/RtcManager';
import { RtcManaging } from '../../foundation/rtc/RtcManaging';
import { MediaController } from '../../media/MediaController';
import { RealtimeExternalVideoSource } from '../../media/external/RealtimeExternalVideoSource';
import { MediaControlling } from '../../media/MediaControlling';
import { RenderController } from '../../rendering/RenderController';
import { RenderControlling } from '../../rendering/RenderControlling';
import { ApiServicing } from '../../service/network/ApiServicing';
import { RealtimeContext } from '../../service/realtime/RealtimeContext';
import { RealtimeMediaStream } from '../../service/realtime/RealtimeMediaStream';
import { RealtimeNetworkQualityListener } from '../../service/realtime/RealtimeNetworkQuality';
import { RealtimePerformanceAlarmListener } from '../../service/realtime/RealtimePerformanceAlarm';
import {
  RealtimeConnectionState,
  RealtimeReason,
  RealtimeState,
  RealtimeStateListener
} from '../../service/realtime/RealtimeState';
import { RealtimeVideoFormat } from '../../service/realtime/RealtimeVideoFormat';
import { RealtimeCameraZoom } from '../../service/realtime/RealtimeCameraZoom';
import { RealtimeQualityLevel } from '../../stream/quality/RealtimeQualityLevel';
import { StreamController } from '../../stream/StreamController';
import { StreamControlling } from '../../stream/StreamControlling';
import { MediaService } from '../../service/media/MediaService';
import { RealtimeTiming, RealtimeTimingRun } from '../../service/realtime/RealtimeTiming';
import { RealtimeConfiguration } from './RealtimeConfiguration';
import {
  XmaxRealtimeLifecycleManager,
  RealtimeOperationKind,
  RealtimeOperationToken,
  RealtimeTerminationScope
} from './XmaxRealtimeLifecycleManager';
import { XmaxRealtimeConnectionManager } from './XmaxRealtimeConnectionManager';
import { XmaxRealtimeErrorManager } from './XmaxRealtimeErrorManager';
import { XmaxRealtimeGenerationManager } from './XmaxRealtimeGenerationManager';
import { XmaxRealtimeManaging } from './XmaxRealtimeManaging';

/** Coordinates local media, realtime connections, generation, and state notifications. */
export class XmaxRealtimeManager implements XmaxRealtimeManaging {

  // Public realtime configuration

  /** The realtime model and business configuration. */
  readonly options: RealtimeConfiguration;

  // Platform and business components

  /** The adapter for RTC engine, room, and media services. */
  private readonly rtcManager: RtcManaging;

  // Error manager

  /** The manager normalizing and deduplicating realtime errors. */
  private readonly errorManager: XmaxRealtimeErrorManager;

  // Rendering components

  /** The controller owning video and trajectory rendering bindings. */
  private readonly renderController: RenderControlling;

  // Business components

  /** The controller coordinating RTC rooms, streams, and signaling. */
  private readonly streamController: StreamControlling;

  /** The controller owning local media and its RTC engine lifecycle. */
  private readonly mediaController: MediaControlling;

  // Realtime managers

  /** The manager owning server session and RTC connection resources. */
  private readonly connectionManager: XmaxRealtimeConnectionManager;

  /** The manager coordinating task signaling, confirmation, and conditions. */
  private readonly generationManager: XmaxRealtimeGenerationManager;

  // Startup timing and internal configuration operations

  /** The shared connection and generation startup timing recorder. */
  private readonly timing: RealtimeTiming = new RealtimeTiming();

  /** Whether a camera stabilization timer is pending, preventing duplicate restart scheduling. */
  private orientationRestartPending: boolean = false;

  /** Whether an adaptive quality update is already scheduled. */
  private qualityPending: boolean = false;

  /** The active orientation restart request into which new user conditions are merged. */
  private orientationRestartCompletion: Promise<void> | null = null;

  /** The submitted generation format used to detect orientation drift during confirmation. */
  private lastSubmittedFormat: RealtimeVideoFormat | undefined = undefined;

  // Lifecycle coordination

  /** The manager owning operation admission, lifecycle state, and scoped cleanup. */
  private readonly lifecycleManager: XmaxRealtimeLifecycleManager;

  // Local playback notifications

  /** The local video file playback state handler. */
  private localVideoPlaybackStateListener: LocalVideoPlaybackStateListener | null = null;

  /**
   * Creates a realtime manager and assembles its dependencies.
   *
   * @param context The context for RTC, permissions, and rendering services.
   * @param options The model and realtime configuration.
   * @param apiService The network service for creating and closing sessions.
   */
  constructor(
    context: common.UIAbilityContext,
    options: RealtimeConfiguration,
    apiService: ApiServicing
  ) {
    // Public configuration
    this.options = options;

    // Foundation components
    this.rtcManager = new RtcManager(context);

    // Error manager
    this.errorManager = new XmaxRealtimeErrorManager();

    // Rendering components
    this.renderController = new RenderController(
      this.rtcManager,
      (error: XmaxError): void => {
        this.handleRuntimeError(
          error,
          RealtimeTerminationScope.CONNECTION
        );
      }
    );

    // Business components
    this.streamController = new StreamController(
      this.rtcManager,
      (stream): void => {
        this.renderController.setRemoteStream(stream);
      },
      (error: XmaxError): void => {
        this.handleRuntimeError(
          error,
          RealtimeTerminationScope.CONNECTION
        );
      },
      this.timing,
      new QualityPreferences(context)
    );

    this.mediaController = new MediaController(
      context,
      this.rtcManager,
      this.streamController,
      (error: XmaxError): void => {
        this.handleRuntimeError(
          error,
          RealtimeTerminationScope.ALL
        );
      },
      new MediaService(options.model),
      (format: RealtimeVideoFormat): void => {
        this.handleCameraVideoFormatChange(format);
      },
      (): void => {
        if (this.lifecycleManager.isClosing || this.localVideoPlaybackState !== LocalVideoPlaybackState.ENDED) {
          return;
        }
        // Local playback completion preserves the generation session so in-flight results remain visible.
        this.notifyLocalVideoPlaybackState(LocalVideoPlaybackState.ENDED);
      }
    );

    // Realtime managers
    this.connectionManager = new XmaxRealtimeConnectionManager(
      apiService,
      this.mediaController,
      this.renderController,
      this.streamController,
      this.timing
    );
    this.generationManager = new XmaxRealtimeGenerationManager(
      this.mediaController,
      this.streamController,
      new MediaService(options.model)
    );

    this.lifecycleManager = new XmaxRealtimeLifecycleManager(
      this.errorManager,
      (scope: RealtimeTerminationScope, taskId: string): Promise<string | undefined> =>
        this.cleanup(
          scope,
          taskId
        ),
      (): boolean => this.mediaController.currentTrack !== null,
      (state: RealtimeState): void => {
        if (state.connectionState === RealtimeConnectionState.GENERATING && state.sessionId !== undefined) {
          this.connectionManager.startHeartbeat(state.sessionId);
        }
      }
    );
  }

  /** The most recently committed realtime state. */
  get currentState(): RealtimeState {
    return this.lifecycleManager.currentState;
  }

  /** The applied uplink level, or undefined outside an established connection. */
  get uplinkQualityLevel(): RealtimeQualityLevel | undefined {
    const state: RealtimeConnectionState = this.currentState.connectionState;
    if (state !== RealtimeConnectionState.CONNECTED && state !== RealtimeConnectionState.GENERATING) {
      return undefined;
    }

    return this.streamController.qualityConfiguration?.uplinkLevel as RealtimeQualityLevel | undefined;
  }

  /** The submitted downlink level, or undefined outside an established connection. */
  get downlinkQualityLevel(): RealtimeQualityLevel | undefined {
    const state: RealtimeConnectionState = this.currentState.connectionState;
    if (state !== RealtimeConnectionState.CONNECTED && state !== RealtimeConnectionState.GENERATING) {
      return undefined;
    }

    return this.streamController.qualityConfiguration?.downlinkLevel as RealtimeQualityLevel | undefined;
  }

  /** Changes uplink encoding while allowing later automatic adjustments. */
  setUplinkQualityLevel(
    level: RealtimeQualityLevel
  ): Promise<void> {
    return this.setQualityLevel(
      level,
      false
    );
  }

  /** Changes returned dimensions while allowing later automatic adjustments. */
  setDownlinkQualityLevel(
    level: RealtimeQualityLevel
  ): Promise<void> {
    return this.setQualityLevel(
      level,
      true
    );
  }

  /** Applies one manual quality change under lifecycle operation ownership. */
  private setQualityLevel(
    level: RealtimeQualityLevel,
    downlink: boolean
  ): Promise<void> {
    return this.lifecycleManager.run(
      RealtimeOperationKind.CONFIGURATION,
      null,
      async (token: RealtimeOperationToken): Promise<void> => {
        const state: RealtimeState = this.currentState;
        if (!Number.isInteger(level) || level < RealtimeQualityLevel.L1 || level > RealtimeQualityLevel.L5) {
          throw new XmaxError(
            XmaxErrorCode.INVALID_CONFIGURATION,
            'Quality level must be one of L1 through L5'
          );
        }
        if (state.connectionState !== RealtimeConnectionState.GENERATING ||
          state.taskId === undefined || this.streamController.qualityConfiguration === undefined) {
          throw new XmaxError(
            XmaxErrorCode.INVALID_CONFIGURATION,
            'Quality levels can only be changed while generating'
          );
        }

        this.applyQualityLevel(
          level,
          downlink,
          state.taskId,
          token
        );
      }
    );
  }

  /** Sets the realtime lifecycle state listener. */
  setStateListener(
    listener: RealtimeStateListener | null
  ): void {
    this.lifecycleManager.setStateListener(listener);
  }

  /** The local video file playback state, or undefined before creation or for another media source. */
  get localVideoPlaybackState(): LocalVideoPlaybackState | undefined {
    return this.mediaController.localVideoPlaybackState;
  }

  /**
   * Sets the local file playback listener and immediately delivers the current valid state.
   *
   * @param listener The event handler, or null to remove it.
   */
  setLocalVideoPlaybackStateListener(
    listener: LocalVideoPlaybackStateListener | null
  ): void {
    this.localVideoPlaybackStateListener = listener;

    const state: LocalVideoPlaybackState | undefined = this.localVideoPlaybackState;
    if (state !== undefined) {
      this.notifyLocalVideoPlaybackState(state);
    }
  }

  /** Sets unified remote PCM and video delivery. */
  setRemoteMediaFrameListener(
    listener: RealtimeMediaFrameListener | null
  ): void {
    try {
      this.renderController.setRemoteMediaFrameListener(listener);
    } catch (error) {
      throw this.reportError(XmaxError.from(error));
    }
  }

  /** Sets the uplink video statistics listener; null removes it. */
  setUplinkVideoStatisticsListener(
    listener: UplinkVideoStatisticsListener | null
  ): void {
    this.streamController.setUplinkVideoStatisticsListener(listener);
  }

  /** Sets the result stream video statistics listener; null removes it. */
  setDownlinkVideoStatisticsListener(
    listener: DownlinkVideoStatisticsListener | null
  ): void {
    this.streamController.setDownlinkVideoStatisticsListener(listener);
  }

  /** Sets the realtime network quality listener. */
  setNetworkQualityListener(
    listener: RealtimeNetworkQualityListener | null
  ): void {
    this.streamController.setNetworkQualityListener(listener);
  }

  /** Sets the device performance alarm listener. */
  setPerformanceAlarmListener(
    listener: RealtimePerformanceAlarmListener | null
  ): void {
    this.streamController.setPerformanceAlarmListener(listener);
  }

  /** The configured local file preview volume in 0 to 1; zero mutes and one uses original volume. */
  get localAudioVolume(): number {
    return this.mediaController.localAudioVolume;
  }

  /**
   * Sets local file preview volume without affecting uploaded audio or automatic generation muting.
   * Can be set before local stream creation and is retained after stopping or replacing video.
   *
   * @param volume A finite volume in 0 to 1; zero mutes, one uses original volume, and the default
   * is 0.45.
   */
  async setLocalAudioVolume(
    volume: number
  ): Promise<void> {
    try {
      this.validateAudioVolume(volume);
      await this.mediaController.setLocalAudioVolume(volume);
    } catch (error) {
      throw this.reportError(XmaxError.from(error));
    }
  }

  /** The generation result playback volume in 0 to 1; zero mutes and one uses original volume. */
  get remoteAudioVolume(): number {
    return this.streamController.remoteAudioVolume;
  }

  /**
   * Sets remote playback volume, retained for later subscriptions and reconnections. Successful
   * camera/image creation resets it to zero; video creation resets it to one. Override volume after
   * stream creation.
   *
   * @param volume A finite volume in 0 to 1; zero mutes, one uses original volume, and the value
   * before local stream creation is one.
   */
  async setRemoteAudioVolume(
    volume: number
  ): Promise<void> {
    try {
      this.validateAudioVolume(volume);
      this.streamController.setRemoteAudioVolume(volume);
    } catch (error) {
      throw this.reportError(XmaxError.from(error));
    }
  }

  /**
   * Validates a finite volume in 0 to 1, throwing a configuration error otherwise.
   *
   * @param volume The volume in 0 to 1, from muted to original volume.
   */
  private validateAudioVolume(
    volume: number
  ): void {
    if (!Number.isFinite(volume) || volume < 0 || volume > 1) {
      throw new XmaxError(
        XmaxErrorCode.INVALID_CONFIGURATION,
        'Audio volume must be between 0 and 1'
      );
    }
  }

  /**
   * Creates and starts a local camera stream.
   *
   * @param videoFormat The local video format; defaults to the model's camera format.
   * @param position The initial camera position; defaults to front.
   * @param useMicrophone Whether to use the microphone, default false. Creation requests
   * permission; connection starts capture and disconnection stops it.
   * @param observeDisplayChange Whether to observe display changes, default true. False preserves
   * capture orientation and ratio without rotation-triggered generation restarts.
   *
   * @returns The local stream for connection, generation, or display.
   */
  async createLocalCameraStream(
    videoFormat: RealtimeVideoFormat = this.options.model.defaultCameraVideoFormat,
    position: CameraPosition = CameraPosition.FRONT,
    useMicrophone: boolean = false,
    observeDisplayChange: boolean = true
  ): Promise<RealtimeMediaStream> {
    return this.lifecycleManager.run(
      RealtimeOperationKind.MEDIA,
      null,
      async (token: RealtimeOperationToken): Promise<RealtimeMediaStream> => {
        this.ensureLocalMediaCanChange();
        if (this.mediaController.currentTrack !== null) {
          throw new XmaxError(
            XmaxErrorCode.INVALID_CONFIGURATION,
            'Stop the current local stream before creating another one'
          );
        }

        this.mediaController.setCameraPreviewReadyHandler(null);
        this.lifecycleManager.commit(
          new RealtimeState(RealtimeConnectionState.PREPARING),
          token
        );

        const stream = await this.mediaController.createLocalCameraStream(
          videoFormat,
          position,
          useMicrophone,
          observeDisplayChange
        );
        token.ensureCurrent();
        token.setFailureScope(RealtimeTerminationScope.ALL);
        if (observeDisplayChange) {
          this.observeLocalOrientation(stream);
        }

        this.streamController.setRemoteAudioVolume(0);
        this.mediaController.setCameraPreviewReadyHandler((): void => {
          this.lifecycleManager.localPreviewDidBecomeReady((): boolean =>
            stream.videoTrack !== undefined && this.mediaController.currentTrack === stream.videoTrack);
        });

        return stream;
      }
    );
  }

  /** The camera's local output format, or undefined for other input sources. */
  get currentCameraVideoFormat(): RealtimeVideoFormat | undefined {
    const track: RealtimeVideoTrack | null = this.mediaController.currentTrack;
    return track?.position !== undefined ? track.videoFormat : undefined;
  }

  /** Returns zoom information for the current camera source. */
  get currentCameraZoom(): RealtimeCameraZoom | undefined {
    return this.mediaController.currentCameraZoom;
  }

  /** Changes camera zoom in place without interrupting capture or generation. */
  setCameraZoomRatio(
    ratio: number
  ): void {
    const state: RealtimeConnectionState = this.currentState.connectionState;
    if (this.lifecycleManager.isClosing || this.lifecycleManager.hasActiveOperation() ||
      (state !== RealtimeConnectionState.READY && state !== RealtimeConnectionState.CONNECTED &&
        state !== RealtimeConnectionState.GENERATING)) {
      throw this.reportError(new XmaxError(
        XmaxErrorCode.INVALID_CONFIGURATION,
        'Camera zoom is unavailable while realtime is transitioning'
      ));
    }

    try {
      this.mediaController.setCameraZoomRatio(ratio);
    } catch (error) {
      throw this.reportError(XmaxError.from(error));
    }
  }

  /** Updates a ready, disconnected camera stream while retaining its track and view bindings. */
  updateCameraFormat(
    videoFormat: RealtimeVideoFormat
  ): Promise<void> {
    if (this.currentState.connectionState !== RealtimeConnectionState.READY ||
      this.currentCameraVideoFormat === undefined) {
      return Promise.reject(this.reportError(new XmaxError(
        XmaxErrorCode.INVALID_CONFIGURATION,
        'Camera preview must be ready before updating its format'
      )));
    }

    return this.lifecycleManager.run(
      RealtimeOperationKind.MEDIA,
      null,
      async (token: RealtimeOperationToken): Promise<void> => {
        this.ensureLocalMediaCanChange();
        if (this.currentState.connectionState !== RealtimeConnectionState.READY ||
          this.currentCameraVideoFormat === undefined) {
          throw new XmaxError(
            XmaxErrorCode.INVALID_CONFIGURATION,
            'Camera preview must be ready before updating its format'
          );
        }

        token.ensureCurrent();
        await this.mediaController.updateCameraFormat(videoFormat);
        token.ensureCurrent();
      }
    );
  }

  /** Stops the local camera stream and releases preview resources. */
  stopLocalCameraStream(): Promise<void> {
    return this.lifecycleManager.run(
      RealtimeOperationKind.MEDIA,
      null,
      async (token: RealtimeOperationToken): Promise<void> => {
        this.ensureLocalMediaCanChange();
        token.setFailureScope(RealtimeTerminationScope.ALL);

        const track = this.mediaController.currentTrack;
        await this.mediaController.stopLocalCameraStream();
        if (track !== null && this.mediaController.currentTrack !== track) {
          setRealtimeVideoTrackOrientationHandler(track);
        }

        this.lifecycleManager.commit(
          new RealtimeState(this.mediaController.currentTrack !== null ?
            RealtimeConnectionState.READY : RealtimeConnectionState.IDLE),
          token
        );
      }
    );
  }

  /**
   * Switches cameras, retaining the connection and restoring cached conditions during generation.
   *
   * @returns The local stream for connection, generation, or display.
   */
  switchCamera(): Promise<RealtimeMediaStream> {
    const operation: Promise<RealtimeMediaStream> = this.lifecycleManager.run(
      RealtimeOperationKind.CAMERA_SWITCH,
      null,
      async (token: RealtimeOperationToken): Promise<RealtimeMediaStream> => {
        const current: RealtimeState = this.currentState;
        const wasGenerating: boolean = current.connectionState === RealtimeConnectionState.GENERATING;
        if (current.connectionState === RealtimeConnectionState.CONNECTING ||
          current.connectionState === RealtimeConnectionState.DISCONNECTING ||
          (!wasGenerating && this.streamController.currentGenerationTaskId.length > 0)) {
          throw new XmaxError(
            XmaxErrorCode.INVALID_CONFIGURATION,
            'Camera switching is unavailable while realtime is transitioning'
          );
        }

        if (wasGenerating) {
          token.setFailureScope(RealtimeTerminationScope.CONNECTION);
          this.renderController.stopRemoteFrameDelivery();
          this.generationManager.stop(current.taskId ?? '');
          this.restoreLocalAudioPreview();
          this.lifecycleManager.commit(
            new RealtimeState(
              RealtimeConnectionState.CONNECTED,
              current.sessionId
            ),
            token
          );
        }

        const stream: RealtimeMediaStream = await this.mediaController.switchCamera();
        token.ensureCurrent();

        if (wasGenerating) {
          await token.delay(500);
          await this.performStartGeneration(
            undefined,
            token
          );
        }

        return stream;
      }
    );

    return operation.finally((): void => {
      // Recheck orientation after switch confirmation and restart if orientation drifted during the wait.
      this.restartGenerationIfOrientationDrifted();
    });
  }

  /**
   * Creates a local video stream using the model's input rules.
   *
   * @param filePath The local video file path.
   * @param videoFormat The output format; defaults to dimensions resolved from video display size
   * and the model frame rate. An explicit frame rate is preserved.
   * @param loop Whether to loop, default true. False stops audio/video delivery and reports ENDED
   * at completion, preserving generation and connection.
   *
   * @returns The local stream for connection, generation, or display.
   */
  async createLocalVideoStream(
    filePath: string,
    videoFormat?: RealtimeVideoFormat,
    loop: boolean = true
  ): Promise<RealtimeMediaStream> {
    return this.lifecycleManager.run(
      RealtimeOperationKind.MEDIA,
      null,
      async (token: RealtimeOperationToken): Promise<RealtimeMediaStream> => {
        this.ensureLocalMediaCanChange();
        if (this.mediaController.currentTrack !== null) {
          throw new XmaxError(
            XmaxErrorCode.INVALID_CONFIGURATION,
            'Stop the current local stream before creating another one'
          );
        }

        this.mediaController.setCameraPreviewReadyHandler(null);
        this.lifecycleManager.commit(
          new RealtimeState(RealtimeConnectionState.PREPARING),
          token
        );

        const stream = await this.mediaController.createLocalVideoStream(
          filePath,
          videoFormat,
          loop
        );
        token.ensureCurrent();
        token.setFailureScope(RealtimeTerminationScope.ALL);

        this.notifyLocalVideoPlaybackState(this.localVideoPlaybackState ?? LocalVideoPlaybackState.PLAYING);
        this.observeLocalOrientation(stream);
        this.streamController.setRemoteAudioVolume(1);

        this.lifecycleManager.commit(
          new RealtimeState(RealtimeConnectionState.READY),
          token
        );

        return stream;
      }
    );
  }

  /** Binds an app-owned external video source, with optional audio, for preview and generation. */
  createExternalVideoStream(
    source: RealtimeExternalVideoSource
  ): Promise<RealtimeMediaStream> {
    return this.lifecycleManager.run(
      RealtimeOperationKind.MEDIA,
      null,
      async (token: RealtimeOperationToken): Promise<RealtimeMediaStream> => {
        this.ensureLocalMediaCanChange();
        if (this.mediaController.currentTrack !== null) {
          throw new XmaxError(
            XmaxErrorCode.INVALID_CONFIGURATION,
            'Stop the current local stream before creating another one'
          );
        }

        this.mediaController.setCameraPreviewReadyHandler(null);
        this.lifecycleManager.commit(
          new RealtimeState(RealtimeConnectionState.PREPARING),
          token
        );

        const stream: RealtimeMediaStream = await this.mediaController.createExternalVideoStream(source);
        token.ensureCurrent();
        token.setFailureScope(RealtimeTerminationScope.ALL);

        this.streamController.setRemoteAudioVolume(0);
        this.lifecycleManager.commit(
          new RealtimeState(RealtimeConnectionState.READY),
          token
        );
        return stream;
      }
    );
  }

  /** Unbinds external frames and preview after the realtime connection has been disconnected. */
  stopExternalVideoStream(): Promise<void> {
    return this.lifecycleManager.run(
      RealtimeOperationKind.MEDIA,
      null,
      async (token: RealtimeOperationToken): Promise<void> => {
        this.ensureLocalMediaCanChange();
        token.setFailureScope(RealtimeTerminationScope.ALL);

        await this.mediaController.stopExternalVideoStream();

        this.lifecycleManager.commit(
          new RealtimeState(this.mediaController.currentTrack !== null ?
            RealtimeConnectionState.READY : RealtimeConnectionState.IDLE),
          token
        );
      }
    );
  }

  /** Stops the local video stream and releases preview resources. */
  stopLocalVideoStream(): Promise<void> {
    return this.lifecycleManager.run(
      RealtimeOperationKind.MEDIA,
      null,
      async (token: RealtimeOperationToken): Promise<void> => {
        this.ensureLocalMediaCanChange();
        token.setFailureScope(RealtimeTerminationScope.ALL);

        const track = this.mediaController.currentTrack;
        await this.mediaController.stopLocalVideoStream();
        if (track !== null && this.mediaController.currentTrack !== track) {
          setRealtimeVideoTrackOrientationHandler(track);
        }

        this.lifecycleManager.commit(
          new RealtimeState(this.mediaController.currentTrack !== null ?
            RealtimeConnectionState.READY : RealtimeConnectionState.IDLE),
          token
        );
      }
    );
  }

  /** Pauses local video while RTC continues sending a frozen frame and silent audio. */
  pauseLocalVideoStream(): Promise<void> {
    return this.lifecycleManager.run(
      RealtimeOperationKind.PLAYBACK,
      null,
      async (token: RealtimeOperationToken): Promise<void> => {
        this.ensureLocalVideoPlaybackCanChange();
        await this.mediaController.pauseLocalVideoStream();
        token.ensureCurrent();
        this.notifyLocalVideoPlaybackState(LocalVideoPlaybackState.PAUSE);
        token.ensureCurrent();
        await this.renderController.freezeRemoteVideo();
        token.ensureCurrent();
      }
    );
  }

  /** Resumes local video from its paused position. */
  resumeLocalVideoStream(): Promise<void> {
    return this.lifecycleManager.run(
      RealtimeOperationKind.PLAYBACK,
      null,
      async (token: RealtimeOperationToken): Promise<void> => {
        this.ensureLocalVideoPlaybackCanChange();

        this.mediaController.resumeLocalVideoStream();
        token.ensureCurrent();
        await this.renderController.resumeRemoteVideo();
        token.ensureCurrent();

        if (this.localVideoPlaybackState === LocalVideoPlaybackState.PLAYING) {
          this.notifyLocalVideoPlaybackState(LocalVideoPlaybackState.PLAYING);
        }
      }
    );
  }

  /** Toggles local video between playing and paused. */
  toggleLocalVideoStreamPlayback(): Promise<void> {
    return this.localVideoPlaybackState === LocalVideoPlaybackState.PAUSE ?
      this.resumeLocalVideoStream() : this.pauseLocalVideoStream();
  }

  /**
   * Creates a continuous frame stream from image input.
   *
   * @param source A local file path, encoded image bytes, or platform PixelMap.
   * @param videoFormat The output format; defaults to dimensions resolved from the image and the
   * model frame rate. An explicit frame rate is preserved.
   *
   * @returns The local stream for connection, generation, or display.
   */
  async createLocalImageStream(
    source: string | ArrayBuffer | Uint8Array | image.PixelMap,
    videoFormat?: RealtimeVideoFormat
  ): Promise<RealtimeMediaStream> {
    return this.lifecycleManager.run(
      RealtimeOperationKind.MEDIA,
      null,
      async (token: RealtimeOperationToken): Promise<RealtimeMediaStream> => {
        this.ensureLocalMediaCanChange();
        if (this.mediaController.currentTrack !== null) {
          throw new XmaxError(
            XmaxErrorCode.INVALID_CONFIGURATION,
            'Stop the current local stream before creating another one'
          );
        }

        this.mediaController.setCameraPreviewReadyHandler(null);
        this.lifecycleManager.commit(
          new RealtimeState(RealtimeConnectionState.PREPARING),
          token
        );

        const stream = await this.mediaController.createLocalImageStream(
          source,
          videoFormat
        );
        token.ensureCurrent();
        token.setFailureScope(RealtimeTerminationScope.ALL);

        this.observeLocalOrientation(stream);
        this.streamController.setRemoteAudioVolume(0);

        this.lifecycleManager.commit(
          new RealtimeState(RealtimeConnectionState.READY),
          token
        );

        return stream;
      }
    );
  }

  /** Stops the local image stream and releases preview resources. */
  stopLocalImageStream(): Promise<void> {
    return this.lifecycleManager.run(
      RealtimeOperationKind.MEDIA,
      null,
      async (token: RealtimeOperationToken): Promise<void> => {
        this.ensureLocalMediaCanChange();
        token.setFailureScope(RealtimeTerminationScope.ALL);

        const track = this.mediaController.currentTrack;
        await this.mediaController.stopLocalImageStream();
        if (track !== null && this.mediaController.currentTrack !== track) {
          setRealtimeVideoTrackOrientationHandler(track);
        }

        this.lifecycleManager.commit(
          new RealtimeState(this.mediaController.currentTrack !== null ?
            RealtimeConnectionState.READY : RealtimeConnectionState.IDLE),
          token
        );
      }
    );
  }

  /**
   * Connects a local stream created by this manager.
   *
   * @param localStream The local media stream created by this manager.
   *
   * @returns The remote stream after connection completes.
   */
  connect(
    localStream: RealtimeMediaStream
  ): Promise<RealtimeMediaStream> {
    return this.lifecycleManager.run(
      RealtimeOperationKind.CONNECTION,
      null,
      (token: RealtimeOperationToken): Promise<RealtimeMediaStream> => this.performConnect(
        localStream,
        token
      )
    );
  }

  /**
   * Configures media transport and commits connected state for the valid operation.
   *
   * @param localStream The existing local media stream.
   * @param token The token verifying operation ownership and cancellation.
   *
   * @returns The connected remote stream for generation and display.
   */
  private async performConnect(
    localStream: RealtimeMediaStream,
    token: RealtimeOperationToken
  ): Promise<RealtimeMediaStream> {
    token.ensureCurrent();
    const current: RealtimeState = this.currentState;
    if (this.connectionManager.currentSessionId.length > 0 ||
      current.connectionState === RealtimeConnectionState.CONNECTING ||
      current.connectionState === RealtimeConnectionState.DISCONNECTING) {
      throw new XmaxError(
        XmaxErrorCode.INVALID_CONFIGURATION,
        'Realtime connection is already open'
      );
    }
    if (!this.mediaController.owns(localStream)) {
      throw new XmaxError(
        XmaxErrorCode.INVALID_CONFIGURATION,
        'The local stream must be created and started by this realtime manager'
      );
    }

    this.mediaController.updateCameraOrientation();
    token.ensureCurrent();
    const videoFormat: RealtimeVideoFormat | undefined = localStream.videoTrack?.videoFormat;
    if (videoFormat === undefined) {
      throw new XmaxError(
        XmaxErrorCode.INVALID_CONFIGURATION,
        'The local stream must be created and started by this realtime manager'
      );
    }

    token.setFailureScope(RealtimeTerminationScope.CONNECTION);
    this.generationManager.reset();
    this.lifecycleManager.commit(
      new RealtimeState(RealtimeConnectionState.CONNECTING),
      token
    );

    const quality: QualityConfiguration = this.streamController.prepareQuality(
      videoFormat,
      this.options.model.name,
      this.options.model.minimumInputPixels,
      this.options.isAdaptiveQualityEnabled
    );
    this.streamController.setVideoEncoderConfig(quality.uplink);
    token.ensureCurrent();

    this.mediaController.startMicrophoneCapture();
    token.ensureCurrent();

    const remoteStream: RealtimeMediaStream = await this.connectionManager.connect(
      this.options.model.name,
      videoFormat,
      this.mediaController.hasAudio,
      (): boolean => token.isCurrent,
      (sessionId: string, error: XmaxError): Promise<void> => this.handleHeartbeatFailure(
        sessionId,
        error
      ),
      this.resolveQualityTarget(quality)
    );
    token.ensureCurrent();

    const sessionId: string = this.connectionManager.currentSessionId;
    if (sessionId.length === 0) {
      throw RealtimeOperationToken.cancelledError();
    }

    this.lifecycleManager.commit(
      new RealtimeState(
        RealtimeConnectionState.CONNECTED,
        sessionId
      ),
      token
    );

    return remoteStream;
  }

  /**
   * Observes current local track orientation changes for generation restarts.
   *
   * @param stream The local camera stream whose orientation changes require task reconfiguration.
   */
  private observeLocalOrientation(
    stream: RealtimeMediaStream
  ): void {
    if (stream.videoTrack === undefined) {
      return;
    }

    const track = RealtimeVideoTrack.resolve(stream.videoTrack);
    setRealtimeVideoTrackOrientationHandler(
      track,
      (): void => {
        if (this.mediaController.currentTrack === track && !this.lifecycleManager.isClosing) {
          this.handleLocalOrientationChange();
        }
      }
    );
  }

  /**
   * Updates native orientation first. Camera dimension changes trigger restart through format
   * notifications; other sources are unaffected.
   */
  private handleLocalOrientationChange(): void {
    try {
      this.mediaController.updateCameraOrientation();
    } catch (error) {
      this.handleRuntimeError(
        XmaxError.from(error),
        RealtimeTerminationScope.ALL
      );
    }
  }

  /**
   * Stops generation on orientation drift while retaining the connection and committing CONNECTED.
   * Releases operation ownership before timer-based stabilization. Dimension changes require a new task
   * because change_condition cannot resize it.
   *
   * @param format The video format to use.
   */
  private restartGenerationIfOrientationDrifted(
    format?: RealtimeVideoFormat
  ): void {
    // If a user operation is active, its completion drift check will reschedule the restart.
    if (this.orientationRestartPending || this.lifecycleManager.hasActiveOperation() ||
      !this.hasOrientationDrift(format)) {
      return;
    }

    const sessionId: string = this.currentState.sessionId ?? '';
    let stopped: boolean = false;
    const operation: Promise<void | RealtimeMediaStream> = this.lifecycleManager.run(
      RealtimeOperationKind.GENERATION,
      null,
      async (token: RealtimeOperationToken): Promise<void> => {
        token.setFailureScope(RealtimeTerminationScope.CONNECTION);
        this.renderController.stopRemoteFrameDelivery();
        this.generationManager.stop(this.currentState.taskId ?? '');
        this.restoreLocalAudioPreview();
        this.lifecycleManager.commit(
          new RealtimeState(
            RealtimeConnectionState.CONNECTED,
            sessionId,
            undefined,
            RealtimeReason.ORIENTATION_CHANGED
          ),
          token
        );
        stopped = true;
      }
    );

    void operation.catch((error: Object): void => {
      const resolved: XmaxError = XmaxError.from(error);
      if (resolved.code !== XmaxErrorCode.CANCELLED) {
        this.logCleanupFailure(
          "转屏后停止生成失败 (Failed to Stop Generation after Orientation Change)",
          resolved
        );
      }
    }).finally((): void => {
      // Wait for restart only after stopping succeeds; termination or later drift checks own cancellation recovery.
      if (stopped) {
        this.scheduleOrientationRestart();
      }
    });
  }

  /**
   * Waits for camera stabilization without holding operation ownership so user requests can proceed. A
   * user request updates the submitted format, invalidating a pending restart if drift disappears.
   */
  private scheduleOrientationRestart(): void {
    if (this.orientationRestartPending || this.lifecycleManager.isClosing) {
      return;
    }

    this.orientationRestartPending = true;
    setTimeout(
      (): void => {
        this.orientationRestartPending = false;
        this.resumeOrientationRestart();
      },
      500
    );
  }

  /**
   * Restarts after stabilization only while CONNECTED and lifecycle admission is available. Uses the
   * current capture format and cached conditions, then rechecks for rotation during confirmation.
   */
  private resumeOrientationRestart(): void {
    if (this.lifecycleManager.isClosing) {
      return;
    }
    if (this.currentState.connectionState !== RealtimeConnectionState.CONNECTED ||
      this.connectionManager.currentSessionId.length === 0 ||
      this.lifecycleManager.hasActiveOperation()) {
      // A user request or disconnect may take over. Recheck active generation drift; other cases finish through the user operation.
      this.restartGenerationIfOrientationDrifted();
      return;
    }

    const operation: Promise<void> = this.lifecycleManager.run(
      RealtimeOperationKind.GENERATION,
      null,
      async (token: RealtimeOperationToken): Promise<void> => {
        token.setFailureScope(RealtimeTerminationScope.CONNECTION);
        await this.performStartGeneration(
          undefined,
          token
        );
      }
    );

    this.orientationRestartCompletion = operation;
    void operation.catch((error: Object): void => {
      const resolved: XmaxError = XmaxError.from(error);
      if (resolved.code !== XmaxErrorCode.CANCELLED) {
        this.logCleanupFailure(
          "转屏后重启生成失败 (Failed to Restart Generation after Orientation Change)",
          resolved
        );
      }
    }).finally((): void => {
      this.orientationRestartCompletion = null;
      this.restartGenerationIfOrientationDrifted();
    });
  }

  /**
   * Merges user conditions through change_condition while an orientation restart is submitting,
   * sharing its completion. The restart already supplies current dimensions; return null outside
   * its submission window.
   *
   * @param input The local stream or generation context.
   * @param context The prompt, reference image, and face detection configuration.
   * @param faceRestoration Whether to enable face restoration.
   *
   * @returns The active restart Promise if mergeable, or null; stream-based calls resolve to the
   * remote stream.
   */
  private tryJoinOrientationRestart(
    input: RealtimeContext | RealtimeMediaStream | undefined,
    context: RealtimeContext | undefined,
    faceRestoration: boolean
  ): Promise<void | RealtimeMediaStream> | null {
    const completion: Promise<void> | null = this.orientationRestartCompletion;
    if (completion === null ||
      (input instanceof RealtimeMediaStream && !this.mediaController.owns(input))) {
      return null;
    }

    const taskId: string = this.streamController.currentGenerationTaskId;
    const videoFormat: RealtimeVideoFormat | undefined =
      this.lastSubmittedFormat ?? this.mediaController.currentVideoFormat;
    if (taskId.length === 0 || videoFormat === undefined ||
      this.connectionManager.currentSessionId.length === 0) {
      return null;
    }

    const newContext: RealtimeContext | undefined =
      input instanceof RealtimeMediaStream ? context : input;
    this.generationManager.update(
      taskId,
      videoFormat,
      newContext,
      faceRestoration
    );

    if (input instanceof RealtimeMediaStream) {
      return completion.then((): RealtimeMediaStream => {
        const remoteStream: RealtimeMediaStream | null = this.connectionManager.currentRemoteStream;
        if (remoteStream === null) {
          throw new XmaxError(
            XmaxErrorCode.RTC_ERROR,
            'Realtime connection has no remote stream'
          );
        }
        return remoteStream;
      });
    }
    return completion;
  }

  /**
   * Detects capture orientation differing from the submitted generation format. Pass the new format
   * explicitly when its callback precedes track metadata updates.
   *
   * @param format The video format to use.
   *
   * @returns True if capture and submitted generation orientations differ.
   */
  private hasOrientationDrift(
    format?: RealtimeVideoFormat
  ): boolean {
    if (this.currentState.connectionState !== RealtimeConnectionState.GENERATING) {
      return false;
    }

    const submitted: RealtimeVideoFormat | undefined = this.lastSubmittedFormat;
    const current: RealtimeVideoFormat | undefined = format ?? this.mediaController.currentVideoFormat;
    if (submitted === undefined || current === undefined) {
      return false;
    }
    return (submitted.width > submitted.height) !== (current.width > current.height);
  }

  /**
   * Propagates camera format changes to connection and generation settings.
   *
   * @param format The video format to use.
   */
  private handleCameraVideoFormatChange(
    format: RealtimeVideoFormat
  ): void {
    const current: RealtimeConnectionState = this.currentState.connectionState;
    if (current === RealtimeConnectionState.DISCONNECTING) {
      return;
    }

    const previous: RealtimeVideoFormat | undefined = this.mediaController.currentVideoFormat;
    const orientationChanged: boolean = previous !== undefined &&
      (previous.width > previous.height) !== (format.width > format.height);
    const quality: QualityConfiguration | undefined = this.streamController.qualityConfiguration;

    if (quality !== undefined && !QualityVideoFormat.same(
      quality.baseline,
      format
    )) {
      const rebased: QualityConfiguration | undefined = this.streamController.rebaseQuality(format);
      if (rebased !== undefined) {
        this.streamController.setVideoEncoderConfig(rebased.uplink);
        const taskId: string | undefined = this.currentState.taskId;
        if (!orientationChanged && current === RealtimeConnectionState.GENERATING && taskId !== undefined) {
          try {
            const target: ImageSize = this.resolveQualityTarget(rebased);
            this.streamController.changeTargetSize(
              taskId,
              target
            );
            this.connectionManager.updateTargetSize(
              target,
              format
            );
          } catch (error) {
            XmaxLogger.warn(
              'Failed to update return size after media change: ' + String(error),
              'Quality'
            );
          }
        }
      }
    }

    const track = this.mediaController.currentTrack;
    if (orientationChanged && track !== null) {
      updateRealtimeVideoTrackOrientation(
        track,
        format.width > format.height,
        false
      );
      // Without a bound view, frame dimensions detect rotation. Orientation changes require task replacement because change_condition cannot resize it.
      this.restartGenerationIfOrientationDrifted(format);
    } else {
      // Resolution changes preserving orientation still use change_condition.
      this.generationManager.updateVideoFormat(format);
    }

    this.connectionManager.updateVideoFormat(format);
  }

  /**
   * Cancels connection/generation and waits for rollback and cleanup while preserving local media
   * and preview.
   *
   * @param reason The disconnection reason; defaults to RealtimeReason.NORMAL.
   */
  disconnect(
    reason: RealtimeReason = RealtimeReason.NORMAL
  ): Promise<void> {
    const current: RealtimeState = this.currentState;
    if ((current.connectionState === RealtimeConnectionState.IDLE ||
      current.connectionState === RealtimeConnectionState.READY ||
      current.connectionState === RealtimeConnectionState.PREPARING) &&
      !this.lifecycleManager.hasOperation(RealtimeOperationKind.CONNECTION) &&
      !this.lifecycleManager.hasOperation(RealtimeOperationKind.GENERATION) &&
      !this.lifecycleManager.hasOperation(RealtimeOperationKind.CAMERA_SWITCH)) {
      return Promise.resolve();
    }

    this.renderController.stopRemoteFrameDelivery();
    return this.lifecycleManager.terminate(
      RealtimeTerminationScope.CONNECTION,
      reason
    );
  }

  /**
   * Silences media immediately, then waits for active operations before releasing all realtime
   * resources.
   */
  close(): Promise<void> {
    this.renderController.stopRemoteFrameDelivery();
    const wasClosing: boolean = this.lifecycleManager.isClosing;
    const closing: Promise<void> = this.lifecycleManager.terminate(
      RealtimeTerminationScope.ALL);

    if (!wasClosing) {
      try {
        this.mediaController.setLocalAudioPreviewEnabled(false);
        this.mediaController.prepareForClose();
      } catch (error) {
        this.logCleanupFailure(
          "静默本地媒体失败 (Failed to Mute Local Media)",
          error
        );
      }
      this.connectionManager.prepareForClose();
    }

    return closing;
  }

  /**
   * Starts generation or updates conditions on an existing connection.
   *
   * New tasks await result confirmation and, unless static, first-frame readiness. Condition
   * updates complete after their signal is submitted, not after the result is displayed.
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

  /**
   * Dispatches generation overloads through one lifecycle operation, connecting for stream inputs.
   *
   * @param input The local stream, generation context, or generation options.
   * @param contextOrFaceRestoration The generation context or a Boolean face restoration setting.
   * @param faceRestoration Whether to enable face restoration.
   *
   * @returns The startup/update Promise; stream-based calls return the remote stream, otherwise no
   * value.
   */
  startGeneration(
    input?: RealtimeContext | RealtimeMediaStream | RealtimeGenerationOptions,
    contextOrFaceRestoration?: RealtimeContext | boolean,
    faceRestoration: boolean = false
  ): Promise<void | RealtimeMediaStream> {
    const options: RealtimeGenerationOptions | undefined = input !== undefined &&
      !(input instanceof RealtimeContext) && !(input instanceof RealtimeMediaStream) ? input : undefined;
    const resolvedInput: RealtimeContext | RealtimeMediaStream | undefined = options === undefined ?
      input as RealtimeContext | RealtimeMediaStream | undefined : options.localStream ?? options.context;
    const context: RealtimeContext | undefined = options === undefined ?
      (typeof contextOrFaceRestoration === 'boolean' ? undefined : contextOrFaceRestoration) : options.context;

    let extraParams: RealtimeGenerationParameters | undefined = undefined;
    if (options?.extraParams !== undefined) {
      if (options.context === undefined) {
        return Promise.reject(new XmaxError(
          XmaxErrorCode.INVALID_CONFIGURATION,
          'A context is required when specifying extraParams'
        ));
      }
      // Snapshot parameters before admission so external mutation cannot alter pending or cached settings.
      const path: string | undefined = options.extraParams.static_image_path?.trim();
      extraParams = {
        static_generate: options.extraParams.static_generate,
        static_image_path: path === '' ? undefined : path
      };
    }

    const restart: boolean = options?.restart ?? false;
    const resolvedFaceRestoration: boolean = options !== undefined ? options.faceRestoration ?? false : resolvedInput instanceof RealtimeMediaStream ? faceRestoration :
      (typeof contextOrFaceRestoration === 'boolean' ? contextOrFaceRestoration : false);

    // Merge new conditions into an orientation restart submission without competing for operation ownership.
    const joined: Promise<void | RealtimeMediaStream> | null =
      restart || options !== undefined ? null : this.tryJoinOrientationRestart(
        resolvedInput,
        context,
        resolvedFaceRestoration
      );
    if (joined !== null) {
      return joined;
    }

    let measurement: RealtimeTimingRun | null = null;
    const operation = this.lifecycleManager.run<void | RealtimeMediaStream>(
      RealtimeOperationKind.GENERATION,
      null,
      async (token: RealtimeOperationToken): Promise<void | RealtimeMediaStream> => {
        // Begin timing only after acquiring ownership; condition updates and rejected requests retain existing measurements.
        if (restart || this.currentState.connectionState !== RealtimeConnectionState.GENERATING) {
          measurement = this.timing.begin();
        }
        try {
          if (resolvedInput instanceof RealtimeMediaStream) {
            return await this.startGenerationWithStream(
              resolvedInput,
              context,
              token,
              resolvedFaceRestoration,
              restart,
              extraParams
            );
          }

          await this.performStartGeneration(
            resolvedInput,
            token,
            resolvedFaceRestoration,
            restart,
            extraParams
          );

          if (options !== undefined) {
            const remote: RealtimeMediaStream | null = this.connectionManager.currentRemoteStream;
            if (remote === null) {
              throw new XmaxError(
                XmaxErrorCode.RTC_ERROR,
                'Realtime connection has no remote stream'
              );
            }
            return remote;
          }
        } finally {
          this.timing.endOperation(measurement);
        }
      }
    );

    return operation.catch((error: Object): void | RealtimeMediaStream => {
      // Use this operation's timing record after lifecycle cleanup to avoid disturbing a newer retry.
      this.timing.finishFailure(
        error,
        measurement
      );
      throw XmaxError.from(error);
    }).finally((): void => {
      // Recheck orientation after initial confirmation, when operation ownership prevented immediate restart.
      this.restartGenerationIfOrientationDrifted();
    });
  }

  /**
   * Connects a local stream and starts or updates its generation task.
   *
   * Static tasks await result confirmation without waiting for a video frame.
   *
   * @param localStream The existing local media stream.
   * @param context The prompt, reference image, and face detection configuration.
   * @param token The token verifying operation ownership and cancellation.
   * @param faceRestoration Whether to enable face restoration.
   * @param restart Whether to replace the task; defaults to false.
   *
   * @returns The generated remote stream for SDK video views.
   */
  private async startGenerationWithStream(
    localStream: RealtimeMediaStream,
    context: RealtimeContext | undefined,
    token: RealtimeOperationToken,
    faceRestoration: boolean,
    restart: boolean = false,
    extraParams?: RealtimeGenerationParameters
  ): Promise<RealtimeMediaStream> {
    if (!this.mediaController.owns(localStream)) {
      throw new XmaxError(
        XmaxErrorCode.INVALID_CONFIGURATION,
        'The local stream must be created and started by this realtime manager'
      );
    }

    let remoteStream: RealtimeMediaStream;
    if (this.connectionManager.currentSessionId.length > 0) {
      const activeRemoteStream: RealtimeMediaStream | null = this.connectionManager.currentRemoteStream;
      if (activeRemoteStream === null) {
        throw new XmaxError(
          XmaxErrorCode.RTC_ERROR,
          'Realtime connection has no remote stream'
        );
      }
      remoteStream = activeRemoteStream;
    } else {
      if (context === undefined) {
        throw new XmaxError(
          XmaxErrorCode.INVALID_CONFIGURATION,
          'A realtime context is required for the first generation'
        );
      }

      this.mediaController.setLocalAudioPreviewEnabled(false);
      remoteStream = await this.performConnect(
        localStream,
        token
      );
      token.setFailureScope(null);
    }

    token.ensureCurrent();
    await this.performStartGeneration(
      context,
      token,
      faceRestoration,
      restart,
      extraParams
    );

    return remoteStream;
  }

  /**
   * Submits generation conditions or starts a task with result confirmation.
   *
   * New non-static tasks also await first-frame readiness; static tasks may not output until an
   * interaction arrives. Updating an active task only submits the condition signal.
   *
   * @param context The prompt, reference image, and face detection configuration.
   * @param token The token verifying operation ownership and cancellation.
   * @param faceRestoration Whether to enable face restoration.
   * @param restart Whether to replace the task; defaults to false.
   */
  private async performStartGeneration(
    context: RealtimeContext | undefined,
    token: RealtimeOperationToken,
    faceRestoration?: boolean,
    restart: boolean = false,
    extraParams?: RealtimeGenerationParameters
  ): Promise<void> {
    token.ensureCurrent();
    const sessionId: string = this.connectionManager.currentSessionId;
    const videoFormat: RealtimeVideoFormat | undefined = this.mediaController.currentVideoFormat;
    let current: RealtimeState = this.currentState;
    if (sessionId.length === 0 || videoFormat === undefined ||
      (current.connectionState !== RealtimeConnectionState.CONNECTED &&
        current.connectionState !== RealtimeConnectionState.GENERATING)) {
      throw new XmaxError(
        XmaxErrorCode.RTC_ERROR,
        'Realtime connection is not open'
      );
    }

    this.generationManager.validateContext(
      context,
      extraParams
    );

    if (restart && current.connectionState === RealtimeConnectionState.GENERATING) {
      token.setFailureScope(RealtimeTerminationScope.CONNECTION);
      this.renderController.stopRemoteFrameDelivery();
      this.generationManager.stop(current.taskId ?? '');
      this.lifecycleManager.commit(
        new RealtimeState(
          RealtimeConnectionState.CONNECTED,
          sessionId
        ),
        token
      );
      token.ensureCurrent();
      current = this.currentState;
    }

    if (current.connectionState === RealtimeConnectionState.GENERATING && current.taskId !== undefined) {
      this.generationManager.update(
        current.taskId,
        videoFormat,
        context,
        faceRestoration,
        extraParams
      );
      token.ensureCurrent();
      return;
    }

    this.generationManager.validateContext(
      context,
      extraParams
    );
    token.setFailureScope(RealtimeTerminationScope.CONNECTION);

    const previousQuality: QualityConfiguration | undefined = this.streamController.qualityConfiguration;
    const quality: QualityConfiguration | undefined = previousQuality === undefined ? undefined :
      QualityVideoFormat.same(
        previousQuality.baseline,
        videoFormat
      ) ? previousQuality : this.streamController.rebaseQuality(videoFormat);
    if (quality !== undefined) {
      this.streamController.setVideoEncoderConfig(quality.uplink);
      this.connectionManager.updateTargetSize(
        this.resolveQualityTarget(quality),
        videoFormat
      );
    }

    token.ensureCurrent();
    this.mediaController.setLocalAudioPreviewEnabled(false);

    // Record submitted orientation for drift detection during confirmation; condition updates do not change dimensions.
    this.lastSubmittedFormat = videoFormat;
    try {
      const taskId: string = await this.generationManager.start(
        videoFormat,
        context,
        (): void => token.ensureCurrent(),
        (confirmation: Promise<void>): Promise<void> => token.wait(confirmation),
        faceRestoration,
        this.connectionManager.currentTargetSize,
        extraParams
      );
      token.ensureCurrent();

      const waitsForFrame: boolean = !this.generationManager.usesStaticInput;
      if (waitsForFrame) {
        await token.wait(this.renderController.waitUntilRemoteFrameReady());
        token.ensureCurrent();
      }

      if (this.localVideoPlaybackState === LocalVideoPlaybackState.PAUSE) {
        await token.wait(this.renderController.freezeRemoteVideo());
        token.ensureCurrent();
      }

      this.streamController.activateRemoteAudio();
      if (this.connectionManager.currentSessionId !== sessionId) {
        throw RealtimeOperationToken.cancelledError();
      }

      this.lifecycleManager.commit(
        new RealtimeState(
          RealtimeConnectionState.GENERATING,
          sessionId,
          taskId
        ),
        token
      );

      if (quality !== undefined) {
        this.streamController.completeQuality(
          false,
          quality.uplinkLevel,
          true
        );
        this.streamController.completeQuality(
          true,
          quality.downlinkLevel,
          true
        );
      }

      this.streamController.setAdaptiveQualityListener(
        this.options.isAdaptiveQualityEnabled === false ? null : (
          sample: RealtimeNetworkQuality,
          sampledAt: number
        ): void => {
          this.scheduleAdaptiveQuality(
            sample,
            sampledAt,
            taskId
          );
        }
      );
      this.timing.finish(
        taskId,
        !waitsForFrame
      );
    } catch (error) {
      this.restoreLocalAudioPreview();
      throw XmaxError.from(error);
    }
  }

  /**
   * Resolves result dimensions from media aspect ratio and downlink quality limits.
   *
   * @param configuration The uplink/downlink levels and fixed media baseline.
   *
   * @returns The resolved media dimensions.
   */
  private resolveQualityTarget(
    configuration: QualityConfiguration
  ): ImageSize {
    const baseline: RealtimeVideoFormat = configuration.baseline;
    return new MediaService(this.options.model).resolveTargetSize(
      new ImageSize(
        baseline.width,
        baseline.height
      ),
      QualityVideoFormat.resolveDownlinkMaximumSize(
        baseline,
        configuration.downlinkLevel
      )
    );
  }

  /**
   * Schedules automatic quality changes only for the active task without a user operation.
   *
   * @param sample The uplink and downlink network quality sample.
   * @param sampledAt The monotonic network sample time, in seconds.
   * @param taskId The current generation task identifier.
   */
  private scheduleAdaptiveQuality(
    sample: RealtimeNetworkQuality,
    sampledAt: number,
    taskId: string
  ): void {
    if (this.options.isAdaptiveQualityEnabled === false || this.qualityPending) { return; }

    this.qualityPending = true;
    // Notify the synchronous user listener first; a user operation may cause this background sample to be skipped.
    void Promise.resolve().then((): void => {
      if (this.currentState.taskId !== taskId) { return; }

      const accepted: boolean = this.lifecycleManager.runAdaptiveConfiguration((token: RealtimeOperationToken): void => {
        if (this.currentState.taskId !== taskId) { return; }

        const change: QualityChange = this.streamController.proposeQuality(
          sample,
          sampledAt
        );

        for (const downlink of [false, true]) {
          const level: number | undefined = downlink ? change.downlink : change.uplink;
          if (level === undefined) { continue; }

          token.ensureCurrent();
          try {
            this.applyQualityLevel(
              level,
              downlink,
              taskId,
              token
            );
          } catch (error) {
            // A failed direction keeps its old level; still try the other direction unless cancelled.
            if (!token.isCurrent) { throw XmaxError.from(error); }
          }
        }
      });

      if (!accepted) { this.streamController.resetQualitySamples(); }
    }).catch((error: Object): void => {
      if (this.currentState.taskId !== taskId) { return; }

      this.streamController.resetQualitySamples();
      if (XmaxError.from(error).code !== XmaxErrorCode.CANCELLED) {
        XmaxLogger.warn(
          'Adaptive quality skipped: ' + String(error),
          'Quality'
        );
      }
    }).finally((): void => { this.qualityPending = false; });
  }

  /**
   * Submits a quality level for one direction and records whether submission succeeded.
   *
   * @param level The quality level, from 1 to 5; lower values mean higher quality.
   * @param downlink Whether this is downlink; false selects uplink.
   * @param taskId The current generation task identifier.
   * @param token The token verifying operation ownership and cancellation.
   */
  private applyQualityLevel(
    level: number,
    downlink: boolean,
    taskId: string,
    token: RealtimeOperationToken
  ): void {
    const configuration: QualityConfiguration | undefined = this.streamController.qualityConfiguration;
    if (configuration === undefined) { return; }

    try {
      token.ensureCurrent();
      if (this.currentState.taskId !== taskId) { return; }

      if (downlink) {
        const candidate: QualityConfiguration = new QualityConfiguration(
          configuration.baseline,
          configuration.uplinkLevel,
          level,
          configuration.minimumInputPixels
        );
        const target: ImageSize = this.resolveQualityTarget(candidate);
        const previous: ImageSize | undefined = this.connectionManager.currentTargetSize;
        if (previous === undefined || previous.width !== target.width || previous.height !== target.height) {
          this.streamController.changeTargetSize(
            taskId,
            target
          );
          token.ensureCurrent();
          this.connectionManager.updateTargetSize(
            target,
            configuration.baseline
          );
        }
      } else {
        this.streamController.setVideoEncoderConfig(QualityVideoFormat.resolve(
          configuration.baseline,
          level,
          false,
          configuration.minimumInputPixels
        ));
      }

      token.ensureCurrent();
      this.streamController.completeQuality(
        downlink,
        level,
        true
      );

      XmaxLogger.debug(
        `Quality adjustment: ${downlink ? 'downlink' : 'uplink'} L${level}`,
        'Quality'
      );
    } catch (error) {
      if (!token.isCurrent) { throw XmaxError.from(error); }

      this.streamController.completeQuality(
        downlink,
        level,
        false
      );

      XmaxLogger.warn(
        'Quality adjustment failed: ' + String(error),
        'Quality'
      );

      throw XmaxError.from(error);
    }
  }

  /** Verifies local media can be replaced, rejecting busy or connected state. */
  private ensureLocalMediaCanChange(): void {
    const current: RealtimeState = this.currentState;
    if (this.connectionManager.currentSessionId.length > 0 ||
      current.connectionState === RealtimeConnectionState.CONNECTING ||
      current.connectionState === RealtimeConnectionState.DISCONNECTING) {
      throw new XmaxError(
        XmaxErrorCode.INVALID_CONFIGURATION,
        'Disconnect realtime before changing the local media stream'
      );
    }
  }

  /** Verifies local video playback can change, throwing a configuration error if unavailable. */
  private ensureLocalVideoPlaybackCanChange(): void {
    const current: RealtimeConnectionState = this.currentState.connectionState;
    if (this.localVideoPlaybackState === LocalVideoPlaybackState.ENDED) {
      throw new XmaxError(
        XmaxErrorCode.INVALID_CONFIGURATION,
        'Local video playback has ended; stop and recreate the stream to replay'
      );
    }
    if (this.localVideoPlaybackState === undefined ||
      current === RealtimeConnectionState.PREPARING ||
      current === RealtimeConnectionState.CONNECTING ||
      current === RealtimeConnectionState.DISCONNECTING) {
      throw new XmaxError(
        XmaxErrorCode.INVALID_CONFIGURATION,
        'Local video playback cannot change while realtime is transitioning'
      );
    }
  }

  /**
   * Notifies local playback state while isolating listener exceptions.
   *
   * @param state The lifecycle or playback state to deliver.
   */
  private notifyLocalVideoPlaybackState(
    state: LocalVideoPlaybackState
  ): void {
    try {
      this.localVideoPlaybackStateListener?.(state);
    } catch (error) {
      XmaxLogger.error(
        `${XmaxLogger.localized("本地视频播放状态监听器执行失败 (Local Video Playback State Listener Failed)\n└─ 原因：", "本地视频播放状态监听器执行失败 (Local Video Playback State Listener Failed)\n└─ Reason: ")}${XmaxError.from(error).message}`,
        'Realtime'
      );
    }
  }

  /**
   * Log cleanup failures and continue releasing resources, preserving the original termination
   * error.
   *
   * @param scope The resources to release.
   * @param taskId The current generation task identifier.
   *
   * @returns The Promise for cleanup, containing the closed session identifier or undefined if
   * absent.
   */
  private async cleanup(
    scope: RealtimeTerminationScope,
    taskId: string
  ): Promise<string | undefined> {
    this.renderController.stopRemoteFrameDelivery();

    try {
      this.mediaController.stopMicrophoneCapture();
    } catch (error) {
      this.logCleanupFailure(
        '停止麦克风采集失败 (Failed to Stop Microphone Capture)',
        error
      );
    }

    try {
      this.generationManager.reset(taskId);
    } catch (error) {
      this.logCleanupFailure(
        "停止实时生成失败 (Failed to Stop Realtime Generation)",
        error
      );
    }

    let sessionId: string | undefined = this.connectionManager.currentSessionId || undefined;
    try {
      sessionId = (await this.connectionManager.disconnect()) ?? sessionId;
    } catch (error) {
      this.logCleanupFailure(
        "断开实时连接失败 (Failed to Disconnect Realtime Session)",
        error
      );
    }

    if (scope === RealtimeTerminationScope.ALL) {
      this.mediaController.setCameraPreviewReadyHandler(null);
      const track = this.mediaController.currentTrack;
      if (track !== null) {
        setRealtimeVideoTrackOrientationHandler(track);
      }

      try {
        await this.mediaController.stopLocalStream();
      } catch (error) {
        this.logCleanupFailure(
          "关闭本地媒体失败 (Failed to Close Local Media)",
          error
        );
      }
    } else {
      this.restoreLocalAudioPreview();
    }

    return sessionId;
  }

  /** Restores local audio preview according to video playback state. */
  private restoreLocalAudioPreview(): void {
    if (!this.lifecycleManager.isClosing) {
      this.mediaController.setLocalAudioPreviewEnabled(true);
    }
  }

  /**
   * Handles only the current session's heartbeat failure, disconnecting while preserving preview.
   *
   * @param sessionId The server realtime session identifier.
   * @param error The current session heartbeat failure requiring disconnection.
   */
  private handleHeartbeatFailure(
    sessionId: string,
    error: XmaxError
  ): Promise<void> {
    if (this.connectionManager.currentSessionId !== sessionId) {
      return Promise.resolve();
    }

    this.renderController.stopRemoteFrameDelivery();
    return this.lifecycleManager.terminateWithError(
      error,
      RealtimeTerminationScope.CONNECTION
    );
  }

  /**
   * Logs a failed cleanup operation and its reason.
   *
   * @param title The phase or operation name.
   * @param error The exception raised while releasing realtime resources.
   */
  private logCleanupFailure(
    title: string,
    error: Object
  ): void {
    XmaxLogger.error(
      `${title}${XmaxLogger.localized("\n└─ 原因：", "\n└─ Reason: ")}${XmaxError.from(error).message}`,
      'Realtime'
    );
  }

  /**
   * Terminates failed resources within a scope through normalized error handling.
   *
   * @param error The asynchronous media or RTC failure requiring scoped cleanup.
   * @param scope The resources to release.
   */
  private handleRuntimeError(
    error: XmaxError,
    scope: RealtimeTerminationScope
  ): void {
    this.renderController.stopRemoteFrameDelivery();
    this.renderController.failRemoteFrameWait(error);

    void this.lifecycleManager.terminateWithError(
      error,
      scope
    )
      .catch((failure: Object): void => this.logCleanupFailure(
        "实时错误清理失败 (Realtime Error Cleanup Failed)",
        failure
      ));
  }

  /**
   * Normalizes an exception through the shared error manager.
   *
   * @param error The exception to normalize and log as an SDK error.
   *
   * @returns The normalized, deduplicated SDK error.
   */
  private reportError(
    error: Object
  ): XmaxError {
    return this.errorManager.handle(XmaxError.from(error));
  }
}
