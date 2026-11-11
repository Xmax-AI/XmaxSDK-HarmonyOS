//
//  CameraController.ets
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-HarmonyOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import { RealtimeMediaSource } from '../../service/media/RealtimeMediaSource';
import { common } from '@kit.AbilityKit';
import { camera } from '@kit.CameraKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  XmaxError,
  XmaxErrorCode,
  XmaxErrorListener
} from '../../foundation/errors/XmaxError';
import { XmaxLogger } from '../../foundation/logging/XmaxLogger';
import { CameraPosition } from '../../foundation/media/camera/CameraPosition';
import { PermissionManager } from '../../foundation/permissions/PermissionManager';
import { PermissionManaging } from '../../foundation/permissions/PermissionManaging';
import { RtcManaging } from '../../foundation/rtc/RtcManaging';
import { VideoContentMode } from '../../foundation/media/video/VideoContentMode';
import { VideoFrame } from '../../foundation/media/video/VideoFrame';
import { CameraPreviewRatio } from '../../rendering/video/CameraPreviewRatio';
import {
  VideoRenderBinding,
  VideoRenderRegistry
} from '../../rendering/video/VideoRenderRegistry';
import { ImageSize } from '../../service/media/ImageSize';
import { MediaService } from '../../service/media/MediaService';
import { MediaServicing } from '../../service/media/MediaServicing';
import { CameraPreviewReadyHandler } from './CameraPreviewReadyHandler';
import { RealtimeMediaStream } from '../../service/realtime/RealtimeMediaStream';
import { RealtimeCameraZoom } from '../../service/realtime/RealtimeCameraZoom';
import { RealtimeVideoFormat } from '../../service/realtime/RealtimeVideoFormat';
import {
  RealtimeVideoTrack,
  updateRealtimeVideoTrackFormat,
  updateRealtimeVideoTrackPosition
} from '../../service/realtime/RealtimeVideoTrack';
import { StreamControlling } from '../../stream/StreamControlling';
import { StreamId } from '../../stream/StreamId';
import { CameraFrameOutput } from './CameraFrameOutput';

const MAXIMUM_CAPTURE_WIDTH: number = 1920;
const MAXIMUM_CAPTURE_HEIGHT: number = 1440;
const CAMERA_CAPTURE_FRAME_RATE: number = 30;

/** Captures raw CameraKit frames for external RTC video input. */
export class CameraController {

  // Capture platform and business dependencies

  /** The adapter for RTC engine, room, and media services. */
  private readonly rtcManager: RtcManaging;

  /** The manager checking and requesting platform permissions. */
  private readonly permissionManager: PermissionManaging;

  /** The CameraKit manager creating capture resources. */
  private readonly platformManager: camera.CameraManager;

  /** The service resolving model-specific media dimensions. */
  private readonly mediaService: MediaServicing;

  /** The controller coordinating RTC rooms, streams, and signaling. */
  private readonly streamController: StreamControlling;

  // Error and output format notifications

  /** The handler for asynchronous component failures. */
  private readonly errorListener: XmaxErrorListener;

  /**
   * Reports camera output format changes.
   *
   * @param format The video format to use.
   */
  private readonly formatListener: (
    format: RealtimeVideoFormat
  ) => void;

  // Camera session resources

  /** The CameraKit input for the selected device. */
  private cameraInput: camera.CameraInput | null = null;

  /** The camera output and native frame receiver. */
  private frameOutput: CameraFrameOutput | null = null;

  /** The configured CameraKit capture session. */
  private captureSession: camera.VideoSession | null = null;

  // Output track and capture enablement

  /** The local track owned by the current media source. */
  private activeTrack: RealtimeVideoTrack | null = null;

  /** Whether the current source may deliver media frames. */
  private acceptsFrames: boolean = false;

  // Audio and orientation configuration

  /** Whether the camera source enables microphone capture on connection. */
  private storedUseMicrophone: boolean = false;

  /** Whether capture output follows display orientation. */
  private observeDisplayChange: boolean = true;

  /** Whether RTC microphone capture needs to be stopped during cleanup. */
  private isMicrophoneCapturing: boolean = false;

  // Capture callback revision

  /** The revision rejecting obsolete camera capture callbacks. */
  private captureGeneration: number = 0;

  // Preview readiness conditions and notification

  /** The camera capture and preview readiness handler. */
  private previewReadyListener: CameraPreviewReadyHandler | null = null;

  /** Whether a valid camera frame has arrived for this source. */
  private hasCapturedFrame: boolean = false;

  /** Whether a preview view is bound to the camera track. */
  private hasBoundPreview: boolean = false;

  /** Whether camera readiness has already been notified. */
  private hasReportedPreviewReady: boolean = false;

  /**
   * Creates a camera media controller.
   *
   * @param context The application context for permissions, media, and storage services.
   * @param rtcManager The RTC adapter for capture, publishing, and subscriptions.
   * @param streamController The stream controller for transport, room signaling, and generation
   * tasks.
   * @param mediaService The service resolving media, canvas, and target dimensions.
   * @param errorListener The component error handler.
   * @param formatListener The video format change handler.
   */
  constructor(
    context: common.UIAbilityContext,
    rtcManager: RtcManaging,
    streamController: StreamControlling,
    mediaService: MediaServicing = new MediaService(),
    errorListener: XmaxErrorListener = (_error: XmaxError): void => { },
    formatListener: (
      format: RealtimeVideoFormat
    ) => void = (_format: RealtimeVideoFormat): void => { }
  ) {
    this.rtcManager = rtcManager;
    this.permissionManager = new PermissionManager(context);
    this.platformManager = camera.getCameraManager(context);
    this.mediaService = mediaService;
    this.streamController = streamController;
    this.errorListener = errorListener;
    this.formatListener = formatListener;
  }

  /** The current local input track, or null without local media. */
  get currentTrack(): RealtimeVideoTrack | null {
    return this.activeTrack;
  }

  /** Whether the camera is configured to capture microphone audio while connected. */
  get useMicrophone(): boolean {
    return this.activeTrack !== null && this.storedUseMicrophone;
  }

  /**
   * Sets the camera preview readiness listener.
   *
   * @param listener The event handler, or null to remove it.
   */
  setPreviewReadyListener(
    listener: CameraPreviewReadyHandler | null
  ): void {
    this.previewReadyListener = listener;
    this.notifyPreviewReadyIfNeeded();
  }

  /**
   * Creates and starts a local CameraKit stream.
   *
   * @param videoFormat The media output or transport format.
   * @param position The active camera position.
   * @param useMicrophone Whether to capture and publish microphone audio.
   * @param observeDisplayChange Whether output format follows display orientation.
   *
   * @returns The local stream for connection, generation, or display.
   */
  async createLocalCameraStream(
    videoFormat: RealtimeVideoFormat,
    position: CameraPosition,
    useMicrophone: boolean = false,
    observeDisplayChange: boolean = true
  ): Promise<RealtimeMediaStream> {
    if (this.activeTrack !== null || this.captureSession !== null) {
      throw new XmaxError(
        XmaxErrorCode.INVALID_CONFIGURATION,
        'Stop the current local camera stream before creating another one'
      );
    }

    return this.createStream(
      videoFormat,
      position,
      useMicrophone,
      observeDisplayChange
    );
  }

  /**
   * Updates native orientation on window rotation and before connection, without waiting for the
   * next frame.
   */
  updateOrientation(): void {
    const track = this.activeTrack;
    const format = track?.videoFormat;
    const output = this.frameOutput;
    if (track !== null && format !== undefined && output !== null) {
      output.updateOrientation();
      this.synchronizeVideoFormat(
        track,
        output.currentVideoFormat ?? format
      );
    }
  }

  /** Reads the zoom capability and applied multiplier of the current capture session. */
  get currentZoom(): RealtimeCameraZoom | undefined {
    const session: camera.VideoSession | null = this.captureSession;
    if (session === null || this.activeTrack === null || !this.acceptsFrames) {
      return undefined;
    }

    try {
      const range: number[] = session.getZoomRatioRange();
      const min: number = range[0];
      const max: number = range[1];
      if (!Number.isFinite(min) || !Number.isFinite(max) || min <= 0 || max <= min) {
        return undefined;
      }

      const ratio: number = session.getZoomRatio();
      return Number.isFinite(ratio) && ratio >= min && ratio <= max ?
        new RealtimeCameraZoom(min, max, ratio) : undefined;
    } catch (_error) {
      // A zoom capability query must not interrupt camera preview on unsupported devices.
      return undefined;
    }
  }

  /** Submits a zoom multiplier to CameraKit without reconfiguring capture. */
  setZoomRatio(
    ratio: number
  ): void {
    const session: camera.VideoSession | null = this.captureSession;
    const zoom: RealtimeCameraZoom | undefined = this.currentZoom;
    if (session === null || zoom === undefined || !Number.isFinite(ratio) ||
      ratio < zoom.minRatio || ratio > zoom.maxRatio) {
      throw new XmaxError(
        XmaxErrorCode.INVALID_CONFIGURATION,
        'Camera zoom ratio is unavailable or outside the supported range'
      );
    }

    try {
      session.setZoomRatio(ratio);
    } catch (error) {
      throw this.cameraError(`Failed to set camera zoom: ${XmaxError.from(error).message}`);
    }
  }

  /**
   * Updates camera output without replacing capture resources, the track, or its view bindings.
   *
   * @param videoFormat The new output dimensions, frame rate, and encoding settings.
   *
   * @returns The local stream retaining its camera track.
   */
  async updateVideoFormat(
    videoFormat: RealtimeVideoFormat
  ): Promise<RealtimeMediaStream> {
    const track: RealtimeVideoTrack | null = this.activeTrack;
    const previous: RealtimeVideoFormat | undefined = track?.videoFormat;
    const output: CameraFrameOutput | null = this.frameOutput;
    if (track === null || previous === undefined || output === null || this.captureSession === null) {
      throw new XmaxError(
        XmaxErrorCode.INVALID_CONFIGURATION,
        'Local camera preview is not started'
      );
    }

    const resolved: RealtimeVideoFormat = this.resolveVideoFormat(videoFormat);
    if (resolved.fps > CAMERA_CAPTURE_FRAME_RATE) {
      throw new XmaxError(
        XmaxErrorCode.INVALID_CONFIGURATION,
        'Camera output frame rate must not exceed 30 fps'
      );
    }

    this.acceptsFrames = false;
    try {
      output.configure(
        resolved,
        CAMERA_CAPTURE_FRAME_RATE,
        this.observeDisplayChange,
        true
      );
      this.synchronizeVideoFormat(
        track,
        resolved
      );
    } catch (error) {
      try {
        output.configure(
          previous,
          CAMERA_CAPTURE_FRAME_RATE,
          this.observeDisplayChange,
          true
        );
        this.synchronizeVideoFormat(
          track,
          previous
        );
      } catch (rollbackError) {
        this.errorListener(XmaxError.from(rollbackError));
        throw XmaxError.from(error);
      }

      this.acceptsFrames = true;
      throw XmaxError.from(error);
    }

    this.acceptsFrames = true;
    return new RealtimeMediaStream(
      StreamId.LOCAL,
      track
    );
  }

  /** Starts internal RTC microphone capture on connection without local playback. */
  startMicrophoneCapture(): void {
    if (!this.useMicrophone || this.isMicrophoneCapturing) {
      return;
    }
    // Connection cleanup must stop any opened device even if startup fails.
    this.isMicrophoneCapturing = true;
    this.rtcManager.startMicrophoneCapture();
  }

  /**
   * Stops capture while retaining reconnection settings; keep the marker on failure so cleanup can
   * retry.
   */
  stopMicrophoneCapture(): void {
    if (!this.isMicrophoneCapturing) {
      return;
    }

    this.rtcManager.stopMicrophoneCapture();
    this.isMicrophoneCapturing = false;
  }

  /** Stops CameraKit capture and releases preview bindings. */
  async stopLocalCameraStream(): Promise<void> {
    const track: RealtimeVideoTrack | null = this.activeTrack;
    this.prepareForStop();
    this.activeTrack = null;
    this.storedUseMicrophone = false;

    if (track !== null) {
      VideoRenderRegistry.unregister(track);
    }

    await this.releaseCamera();
    this.isMicrophoneCapturing = false;
  }

  /** Stops the microphone, blocks camera output, and detaches preview immediately. */
  prepareForStop(): void {
    try {
      this.stopMicrophoneCapture();
    } catch (error) {
      this.logResourceError(
        '停止麦克风采集 (Stop Microphone Capture)',
        error
      );
    }

    this.acceptsFrames = false;
    this.captureGeneration += 1;
    this.resetPreviewReadiness();

    try {
      this.rtcManager.unbindLocalVideo();
    } catch (error) {
      this.logResourceError(
        XmaxLogger.localized(
          "解除相机预览绑定",
          "Unbind Camera Preview"
        ),
        error
      );
    }
  }

  /**
   * Switches between front and rear CameraKit cameras.
   *
   * @returns The local stream for connection, generation, or display.
   */
  async switchCamera(): Promise<RealtimeMediaStream> {
    const currentTrack: RealtimeVideoTrack | null = this.activeTrack;
    const videoFormat: RealtimeVideoFormat | undefined = currentTrack?.videoFormat;
    const position: CameraPosition | undefined = currentTrack?.position;
    if (currentTrack === null || videoFormat === undefined || position === undefined ||
      this.captureSession === null) {
      throw new XmaxError(
        XmaxErrorCode.INVALID_CONFIGURATION,
        'Local camera preview is not started'
      );
    }

    const nextPosition: CameraPosition = position === CameraPosition.FRONT ?
      CameraPosition.BACK : CameraPosition.FRONT;

    this.acceptsFrames = false;
    this.resetPreviewReadiness();
    await this.releaseCamera();

    try {
      this.rtcManager.configureLocalVideoMirror(nextPosition);
      this.acceptsFrames = true;
      await this.startCamera(
        videoFormat,
        nextPosition
      );

      this.synchronizeVideoFormat(
        currentTrack,
        this.frameOutput?.currentVideoFormat ?? videoFormat
      );
      updateRealtimeVideoTrackPosition(
        currentTrack,
        nextPosition
      );

      return new RealtimeMediaStream(
        StreamId.LOCAL,
        currentTrack
      );
    } catch (error) {
      this.acceptsFrames = false;
      await this.releaseCamera();
      await this.restoreCameraAfterFailedSwitch(
        videoFormat,
        position
      );

      throw XmaxError.from(error);
    }
  }

  /**
   * Checks permissions, configures external input, starts CameraKit, and registers preview.
   *
   * @param videoFormat The media output or transport format.
   * @param position The active camera position.
   * @param useMicrophone Whether to capture and publish microphone audio.
   * @param observeDisplayChange Whether output format follows display orientation.
   *
   * @returns The local stream for connection, generation, or display.
   */
  private async createStream(
    videoFormat: RealtimeVideoFormat,
    position: CameraPosition,
    useMicrophone: boolean = false,
    observeDisplayChange: boolean = true
  ): Promise<RealtimeMediaStream> {
    const resolvedFormat: RealtimeVideoFormat = this.resolveVideoFormat(videoFormat);
    const track = new RealtimeVideoTrack(
      'video0',
      resolvedFormat,
      position
    );
    this.observeDisplayChange = observeDisplayChange;

    try {
      await this.permissionManager.ensureCameraPermission();
      if (useMicrophone) {
        await this.permissionManager.ensureMicrophonePermission();
      }

      this.streamController.setVideoEncoderConfig(resolvedFormat);
      this.rtcManager.useExternalVideoSource();
      this.rtcManager.configureLocalVideoMirror(position);

      this.acceptsFrames = true;
      await this.startCamera(
        resolvedFormat,
        position
      );
      this.synchronizeVideoFormat(
        track,
        this.frameOutput?.currentVideoFormat ?? resolvedFormat
      );

      VideoRenderRegistry.register(
        track,
        new VideoRenderBinding(
          this.rtcManager.renderLibraryName(),
          (viewId: string, contentMode: VideoContentMode): void => {
            this.rtcManager.bindLocalVideo(
              viewId,
              contentMode
            );
            this.hasBoundPreview = true;
            this.notifyPreviewReadyIfNeeded();
          },
          (_viewId: string): void => {
            this.hasBoundPreview = false;
            this.rtcManager.unbindLocalVideo();
          },
          CameraPreviewRatio.FILL
        )
      );

      this.activeTrack = track;
      this.storedUseMicrophone = useMicrophone;

      return new RealtimeMediaStream(
        StreamId.LOCAL,
        track
      );
    } catch (error) {
      this.acceptsFrames = false;
      VideoRenderRegistry.unregister(track);
      await this.releaseCamera();

      throw XmaxError.from(error);
    }
  }

  /**
   * Creates a CameraKit session bound to a native ImageReceiver Surface.
   *
   * @param videoFormat The media output or transport format.
   * @param position The active camera position.
   */
  private async startCamera(
    videoFormat: RealtimeVideoFormat,
    position: CameraPosition
  ): Promise<void> {
    if (videoFormat.fps > CAMERA_CAPTURE_FRAME_RATE ||
      Math.floor(videoFormat.fps) !== videoFormat.fps) {
      throw new XmaxError(
        XmaxErrorCode.INVALID_CONFIGURATION,
        'Camera frame output configuration is invalid'
      );
    }

    let operation: string = 'Select camera capture profiles';
    try {
      const device: camera.CameraDevice = this.selectCamera(position);
      const profiles: Array<camera.Profile> = this.captureProfiles(device);
      this.resetPreviewReadiness();

      for (const profile of profiles) {
        const dimensions: string = `${profile.size.width} × ${profile.size.height}`;
        operation = `Configure CameraKit session (${dimensions})`;
        const generation: number = ++this.captureGeneration;
        const output: CameraFrameOutput = await this.prepareFrameOutput(
          device,
          profile,
          generation
        );

        // Frame-rate capabilities depend on the bound camera and session; query after configuration is committed.
        operation = `Query CameraKit frame rates (${dimensions})`;
        const ranges: Array<camera.FrameRateRange> = output.output.getSupportedFrameRates();
        if (ranges.length === 0) {
          throw this.cameraError(`${operation}: no frame rate capabilities returned`);
        }
        if (!ranges.some((range: camera.FrameRateRange): boolean =>
          range.min <= CAMERA_CAPTURE_FRAME_RATE && range.max >= CAMERA_CAPTURE_FRAME_RATE)) {
          XmaxLogger.debug(
            `${XmaxLogger.localized("CameraKit 采集规格 ", "CameraKit Capture Profile ")}${dimensions}${XmaxLogger.localized(" 不支持 30 fps，尝试下一档规格", " does not support 30 fps; trying the next profile")}`,
            'Camera'
          );
          await this.releaseCamera();
          continue;
        }

        operation = `Set CameraKit frame rate to 30 fps (${dimensions})`;
        output.output.setFrameRate(
          CAMERA_CAPTURE_FRAME_RATE,
          CAMERA_CAPTURE_FRAME_RATE
        );

        operation = `Start CameraKit capture (${dimensions})`;
        await this.captureSession!.start();
        output.configure(
          videoFormat,
          CAMERA_CAPTURE_FRAME_RATE,
          this.observeDisplayChange,
          this.activeTrack !== null
        );
        const outputFormat: RealtimeVideoFormat = output.currentVideoFormat ?? videoFormat;

        XmaxLogger.debug(
          "CameraKit 相机采集已启动 (CameraKit Capture Started)\n" +
          `${XmaxLogger.localized("├─ 采集：", "├─ Capture: ")}${dimensions} @ ${CAMERA_CAPTURE_FRAME_RATE} fps\n` +
          `${XmaxLogger.localized("└─ 输出：", "└─ Output: ")}${outputFormat.width} × ${outputFormat.height} @ ${outputFormat.fps} fps`,
          'Camera'
        );
        return;
      }

      throw this.cameraError('Camera does not support a compatible 16:9 or 4:3 YUV output at 30 fps');
    } catch (error) {
      await this.releaseCamera();
      if (error instanceof XmaxError) {
        throw error;
      }

      const platformError: BusinessError = error as BusinessError;
      const code: string = typeof platformError.code === 'number' ?
        ` (CameraKit code ${platformError.code})` : '';
      const reason: string = platformError.message || String(error);
      throw this.cameraError(`${operation}${code}: ${reason}`);
    }
  }

  /**
   * Attaches candidate output to the session before querying device-specific frame rates.
   *
   * @param device The selected camera device.
   * @param profile The camera capture profile.
   * @param generation The capture revision rejecting callbacks after capture stops.
   *
   * @returns The created raw camera frame output.
   */
  private async prepareFrameOutput(
    device: camera.CameraDevice,
    profile: camera.Profile,
    generation: number
  ): Promise<CameraFrameOutput> {
    const input: camera.CameraInput = this.platformManager.createCameraInput(device);
    this.cameraInput = input;
    await input.open();

    const output: CameraFrameOutput = CameraFrameOutput.create(
      this.platformManager,
      profile,
      device.cameraPosition,
      (frame: VideoFrame): void => this.handleFrame(
        frame,
        generation
      ),
      (error: XmaxError): void => this.errorListener(error)
    );
    this.frameOutput = output;

    const session: camera.VideoSession = this.platformManager.createSession<camera.VideoSession>(
      camera.SceneMode.NORMAL_VIDEO
    );
    this.captureSession = session;
    session.beginConfig();
    if (!session.canAddInput(input)) {
      throw this.cameraError('Camera input is not supported by the capture session');
    }
    session.addInput(input);

    if (!session.canAddOutput(output.output)) {
      throw this.cameraError('Camera frame output is not supported by the capture session');
    }
    session.addOutput(output.output);
    await session.commitConfig();

    return output;
  }

  /**
   * Wraps camera failures as media capture errors.
   *
   * @param message The camera capture failure description.
   *
   * @returns The camera capture SDK error.
   */
  private cameraError(
    message: string
  ): XmaxError {
    return new XmaxError(
      XmaxErrorCode.MEDIA_ERROR,
      message
    );
  }

  /**
   * Submits camera frames through the shared external video path.
   *
   * @param frame The oriented camera video frame for local preview and RTC submission.
   * @param generation The capture revision rejecting callbacks after capture stops.
   */
  private handleFrame(
    frame: VideoFrame,
    generation: number
  ): void {
    if (!this.acceptsFrames || generation !== this.captureGeneration) {
      return;
    }

    try {
      const format: RealtimeVideoFormat | null | undefined = this.frameOutput?.currentVideoFormat;
      if (format !== undefined && format !== null) {
        // Queued frames from before rotation must not overwrite the new format or use its encoder dimensions.
        if (frame.format.width !== format.width || frame.format.height !== format.height) {
          return;
        }
        if (this.activeTrack !== null) {
          this.synchronizeVideoFormat(
            this.activeTrack,
            format
          );
        }
      }

      this.streamController.pushLocalVideoFrame(frame);
      this.hasCapturedFrame = true;
      this.notifyPreviewReadyIfNeeded();
    } catch (error) {
      this.errorListener(XmaxError.from(error));
    }
  }

  /**
   * Synchronizes camera track format and notifies rendering and generation.
   *
   * @param track The SDK video track handle.
   * @param format The video format to use.
   */
  private synchronizeVideoFormat(
    track: RealtimeVideoTrack,
    format: RealtimeVideoFormat
  ): void {
    const previous: RealtimeVideoFormat | undefined = track.videoFormat;
    if (previous?.width === format.width && previous.height === format.height && previous.fps === format.fps &&
      previous.minimumBitrate === format.minimumBitrate && previous.maximumBitrate === format.maximumBitrate &&
      previous.encoderPreference === format.encoderPreference) {
      return;
    }

    this.streamController.setVideoEncoderConfig(format);
    this.formatListener(format);
    updateRealtimeVideoTrackFormat(
      track,
      format
    );
    VideoRenderRegistry.notifyVideoFormatChanged(track);
  }

  /**
   * Attempts to restore the previous camera after a failed switch.
   *
   * @param videoFormat The media output or transport format.
   * @param position The active camera position.
   */
  private async restoreCameraAfterFailedSwitch(
    videoFormat: RealtimeVideoFormat,
    position: CameraPosition
  ): Promise<void> {
    try {
      this.rtcManager.configureLocalVideoMirror(position);
      this.acceptsFrames = true;
      await this.startCamera(
        videoFormat,
        position
      );
    } catch (rollbackError) {
      this.prepareForStop();
      const track: RealtimeVideoTrack | null = this.activeTrack;
      this.activeTrack = null;
      if (track !== null) {
        VideoRenderRegistry.unregister(track);
      }

      await this.releaseCamera();
      XmaxLogger.error(
        `${XmaxLogger.localized("恢复 CameraKit 相机失败 (Failed to Restore CameraKit Capture)\n└─ 原因：", "恢复 CameraKit 相机失败 (Failed to Restore CameraKit Capture)\n└─ Reason: ")}${XmaxError.from(rollbackError).message}`,
        'Camera'
      );
    }
  }

  /** Releases CameraKit by stopping the session, releasing output, then closing input. */
  private async releaseCamera(): Promise<void> {
    this.captureGeneration += 1;

    const session: camera.Session | null = this.captureSession;
    const output: CameraFrameOutput | null = this.frameOutput;
    const input: camera.CameraInput | null = this.cameraInput;

    this.captureSession = null;
    this.frameOutput = null;
    this.cameraInput = null;

    if (session !== null) {
      try {
        await session.stop();
      } catch (error) {
        this.logResourceError(
          XmaxLogger.localized(
            "停止 CameraKit 会话",
            "Stop CameraKit Session"
          ),
          error
        );
      }

      try {
        await session.release();
      } catch (error) {
        this.logResourceError(
          XmaxLogger.localized(
            "释放 CameraKit 会话",
            "Release CameraKit Session"
          ),
          error
        );
      }
    }

    if (output !== null) {
      await output.release();
    }

    if (input !== null) {
      try {
        await input.close();
      } catch (error) {
        this.logResourceError(
          XmaxLogger.localized(
            "关闭 CameraKit 输入",
            "Close CameraKit Input"
          ),
          error
        );
      }
    }
  }

  /**
   * Selects a camera with the requested position.
   *
   * @param position The active camera position.
   *
   * @returns The matching camera, throwing a capture error if unavailable.
   */
  private selectCamera(
    position: CameraPosition
  ): camera.CameraDevice {
    const platformPosition: camera.CameraPosition = position === CameraPosition.FRONT ?
      camera.CameraPosition.CAMERA_POSITION_FRONT :
      camera.CameraPosition.CAMERA_POSITION_BACK;
    const device: camera.CameraDevice | undefined = this.platformManager
      .getSupportedCameras()
      .find((candidate: camera.CameraDevice): boolean =>
        candidate.cameraPosition === platformPosition);
    if (device === undefined) {
      throw this.cameraError('Requested camera is unavailable');
    }

    return device;
  }

  /**
   * Try 16:9 from 1920 by 1080 downward; fall back to 4:3 when 30 fps is unsupported.
   *
   * @param device The selected camera device.
   *
   * @returns The camera's candidate raw capture profiles.
   */
  private captureProfiles(
    device: camera.CameraDevice
  ): Array<camera.Profile> {
    const capability: camera.CameraOutputCapability = this.platformManager
      .getSupportedOutputCapability(
        device,
        camera.SceneMode.NORMAL_VIDEO
      );

    const profiles: Array<camera.Profile> = capability.previewProfiles.filter(
      (profile: camera.Profile): boolean => {
        const width: number = Math.max(profile.size.width, profile.size.height);
        const height: number = Math.min(profile.size.width, profile.size.height);
        return profile.format === camera.CameraFormat.CAMERA_FORMAT_YUV_420_SP &&
          (this.isWideCaptureProfile(profile) || width * 3 === height * 4) &&
          width <= MAXIMUM_CAPTURE_WIDTH && height <= MAXIMUM_CAPTURE_HEIGHT;
      });

    profiles.sort((left: camera.Profile, right: camera.Profile): number => {
      const leftWide: boolean = this.isWideCaptureProfile(left);
      const rightWide: boolean = this.isWideCaptureProfile(right);
      if (leftWide !== rightWide) {
        return leftWide ? -1 : 1;
      }
      return right.size.width * right.size.height - left.size.width * left.size.height;
    });

    if (profiles.length === 0) {
      throw this.cameraError('Camera does not support a compatible 16:9 or 4:3 YUV preview output');
    }

    return profiles;
  }

  /**
   * Checks whether a capture profile is landscape.
   *
   * @param profile The camera capture profile.
   *
   * @returns True if capture width exceeds height.
   */
  private isWideCaptureProfile(
    profile: camera.Profile
  ): boolean {
    const width: number = Math.max(profile.size.width, profile.size.height);
    const height: number = Math.min(profile.size.width, profile.size.height);
    return width * 9 === height * 16;
  }

  /**
   * Validates a format and resolves model-supported input dimensions.
   *
   * @param videoFormat The media output or transport format.
   *
   * @returns The resolved or updated video format.
   */
  private resolveVideoFormat(
    videoFormat: RealtimeVideoFormat
  ): RealtimeVideoFormat {
    videoFormat.validate();

    const targetSize: ImageSize = this.mediaService.resolveMediaSize(
      new ImageSize(
        videoFormat.width,
        videoFormat.height
      ),
      RealtimeMediaSource.CAMERA
    );
    return videoFormat.resized(
      targetSize.width,
      targetSize.height
    );
  }

  /** Clears camera capture, binding, and readiness markers. */
  private resetPreviewReadiness(): void {
    this.hasCapturedFrame = false;
    this.hasReportedPreviewReady = false;
  }

  /** Notifies preview readiness once capture and binding are both ready. */
  private notifyPreviewReadyIfNeeded(): void {
    const listener: CameraPreviewReadyHandler | null = this.previewReadyListener;
    if (listener === null || !this.hasCapturedFrame || !this.hasBoundPreview ||
      this.hasReportedPreviewReady) {
      return;
    }

    this.hasReportedPreviewReady = true;
    try {
      listener();
    } catch (error) {
      this.logResourceError(
        XmaxLogger.localized(
          "执行摄像头预览就绪监听器",
          "Invoke Camera Preview Ready Listener"
        ),
        error
      );
    }
  }

  /**
   * Logs a camera resource operation failure and its reason.
   *
   * @param action The resource operation name or function.
   * @param error The exception raised by the camera resource operation.
   */
  private logResourceError(
    action: string,
    error: Object
  ): void {
    const reason: string = error instanceof Error ? error.message : String(error);
    XmaxLogger.error(
      `${action}${XmaxLogger.localized("失败\n└─ 原因：", " Failed\n└─ Reason: ")}${reason}`,
      'Camera'
    );
  }
}
