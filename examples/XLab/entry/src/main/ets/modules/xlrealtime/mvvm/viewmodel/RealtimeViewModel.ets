import { XLabLocalization } from '../../../../localization/XLabLocalization';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  CameraPosition,
  UplinkVideoStatistics,
  DownlinkVideoStatistics,
  RealtimeNetworkQuality,
  RealtimeQualityLevel,
  LocalVideoPlaybackState,
  RealtimeCameraZoom,
  RealtimeConfiguration,
  RealtimeConnectionState,
  RealtimeReasonKind,
  RealtimeContext,
  RealtimeMediaStream,
  RealtimeMediaFrame,
  RealtimeModels,
  RealtimeState,
  RealtimeVideoFormat,
  XmaxClient,
  XmaxConfiguration,
  XmaxLoggerOption,
  XmaxError,
  XmaxRealtimeManaging
} from '@xmax/sdk';
import { XLabConfiguration } from '../../config/XLabConfiguration';
import { XLabModelSelection } from '../../config/XLabModelSelection';
import { Reference, ReferenceUploadState } from '../../reference/Reference';
import { ReferenceCategory } from '../../reference/ReferenceCategory';
import { ReferenceDataSource } from '../../reference/ReferenceDataSource';
import { ReferenceUploading } from '../../reference/ReferenceUploader';
import { RealtimeReferenceItemState, RealtimeViewState } from '../model/RealtimeViewState';
import { RealtimeVideoRecorder } from '../../recording/RealtimeVideoRecorder';
import { RealtimeRecordingState } from '../../recording/RealtimeRecordingState';
import { RealtimeFileVideoSource } from '../../external/RealtimeFileVideoSource';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'RealtimeViewModel';

enum GenerationInputMode {
  REFERENCE = 'reference',
  PROMPT = 'prompt',
  MOX = 'mox'
}

type LocalMediaCreation = (
  manager: XmaxRealtimeManaging,
  filePath: string
) => Promise<RealtimeMediaStream>;

export class RealtimeViewModel {
  onMessage: ((message: string) => void) | null = null;
  readonly state: RealtimeViewState;

  private static nextCustomReferenceId: number = 1;
  private selectedReferenceItem: RealtimeReferenceItemState | null = null;
  private referenceUploader: ReferenceUploading | null = null;
  private readonly uploadVersions: Map<string, number> = new Map();
  private nextUploadVersion: number = 1;
  private promptReference: Reference | null = null;
  private promptReferenceUploadVersion: number = 0;
  private realtimeManager: XmaxRealtimeManaging | null = null;
  private localStream: RealtimeMediaStream | null = null;
  private remoteStream: RealtimeMediaStream | null = null;
  private connecting: boolean = false;
  private hasRemoteAudioVolumeSelection: boolean = false;
  private switchingCamera: boolean = false;
  private changingLocalMedia: boolean = false;
  private changingVideoPlayback: boolean = false;
  private generationUpdating: boolean = false;
  private pendingGenerationRestart: boolean = false;
  private generationRevision: number = 0;
  private generationInputMode: GenerationInputMode = GenerationInputMode.REFERENCE;
  private submittedPrompt: string = '';
  private localVideoPath: string = '';
  private localImagePath: string = '';
  private usesExternalSource: boolean = false;
  private moxReferenceSourcePath: string = '';
  private moxReferenceRemoteUrl: string = '';
  private recorder: RealtimeVideoRecorder | null = null;
  private recordingRevision: number = 0;
  private recordingCompletion: Promise<void> | null = null;

  constructor(categories: ReferenceCategory[] = ReferenceDataSource.categories()) {
    this.state = new RealtimeViewState(categories);
  }

  setReferenceUploader(uploader: ReferenceUploading): void {
    this.referenceUploader = uploader;
  }

  toggleRecording(context: common.Context): void {
    if (this.state.recordingState === RealtimeRecordingState.RECORDING) {
      void this.stopRecording(context);
      return;
    }
    const manager: XmaxRealtimeManaging | null = this.realtimeManager;
    if (manager === null || this.state.recordingState !== RealtimeRecordingState.IDLE ||
      this.state.connectionState !== RealtimeConnectionState.GENERATING) {
      return;
    }

    const recorder: RealtimeVideoRecorder = new RealtimeVideoRecorder(context);
    this.recorder = recorder;
    this.recordingRevision++;
    try {
      recorder.start((message: string): void => this.failRecording(recorder, message));
      manager.setRemoteMediaFrameListener((frame: RealtimeMediaFrame): void => {
        if (this.realtimeManager !== manager || this.recorder !== recorder) {
          return;
        }
        try {
          recorder.append(frame);
        } catch (error) {
          this.failRecording(recorder, this.errorMessage(error));
        }
      });
      this.state.recordingState = RealtimeRecordingState.RECORDING;
    } catch (error) {
      this.failRecording(recorder, this.errorMessage(error));
    }
  }

  private failRecording(recorder: RealtimeVideoRecorder, message: string): void {
    if (this.recorder !== recorder) {
      return;
    }
    hilog.error(LOG_DOMAIN, LOG_TAG, 'Realtime recording failed: %{public}s', message);
    this.recorder = null;
    this.realtimeManager?.setRemoteMediaFrameListener(null);
    this.recordingRevision++;
    this.state.recordingState = RealtimeRecordingState.SAVING;
    this.onMessage?.(XLabLocalization.format('record_failed', [message]));
    this.recordingCompletion = recorder.cancel().finally((): void => {
      this.state.recordingState = RealtimeRecordingState.IDLE;
      this.recordingCompletion = null;
    });
  }

  private stopRecording(context: common.Context): Promise<void> {
    const recorder: RealtimeVideoRecorder | null = this.recorder;
    if (recorder === null) {
      return this.recordingCompletion ?? Promise.resolve();
    }

    const revision: number = this.recordingRevision;
    this.recorder = null;
    this.realtimeManager?.setRemoteMediaFrameListener(null);
    this.state.recordingState = RealtimeRecordingState.SAVING;
    const completion: Promise<void> = (async (): Promise<void> => {
      try {
        await recorder.stop();
        if (revision !== this.recordingRevision) {
          return;
        }
        const saved: boolean = await recorder.saveToAlbum(context);
        if (revision === this.recordingRevision) {
          this.onMessage?.(XLabLocalization.text(saved ? 'record_saved' : 'record_save_cancelled'));
        }
      } catch (error) {
        await recorder.cancel();
        if (revision === this.recordingRevision) {
          this.onMessage?.(XLabLocalization.format('record_failed', [this.errorMessage(error)]));
        }
      } finally {
        await recorder.removeOutput();
        this.state.recordingState = RealtimeRecordingState.IDLE;
        this.recordingCompletion = null;
      }
    })();
    this.recordingCompletion = completion;
    return completion;
  }

  refreshQualityLevels(): void {
    this.state.uplinkQualityLevel = this.realtimeManager?.uplinkQualityLevel;
    this.state.downlinkQualityLevel = this.realtimeManager?.downlinkQualityLevel;
  }

  async setUplinkQualityLevel(level: RealtimeQualityLevel): Promise<void> {
    await this.setQualityLevel(level, true);
  }

  async setDownlinkQualityLevel(level: RealtimeQualityLevel): Promise<void> {
    await this.setQualityLevel(level, false);
  }

  private async setQualityLevel(level: RealtimeQualityLevel, uplink: boolean): Promise<void> {
    const manager: XmaxRealtimeManaging | null = this.realtimeManager;
    if (manager === null || !this.state.canAdjustQuality || this.connecting ||
      this.switchingCamera || this.changingLocalMedia || this.changingVideoPlayback ||
      this.generationUpdating) {
      return;
    }
    const currentLevel: RealtimeQualityLevel | undefined = uplink ?
      manager.uplinkQualityLevel : manager.downlinkQualityLevel;
    if (currentLevel === level) {
      return;
    }

    const revision: number = this.generationRevision;
    this.state.isQualityChanging = true;
    try {
      if (uplink) {
        await manager.setUplinkQualityLevel(level);
      } else {
        await manager.setDownlinkQualityLevel(level);
      }
    } catch (error) {
      if (this.realtimeManager === manager && this.generationRevision === revision &&
        manager.currentState.connectionState === RealtimeConnectionState.GENERATING) {
        this.onMessage?.(this.errorMessage(error));
      }
    } finally {
      if (this.realtimeManager === manager) {
        this.state.isQualityChanging = false;
        this.refreshQualityLevels();
      }
    }
  }

  /** 打开弹窗时读取实际音量；静音期间保留取消静音所需的音量。 */
  refreshAudioVolumes(): void {
    const manager: XmaxRealtimeManaging | null = this.realtimeManager;
    if (manager !== null && !this.state.isAudioMuted) {
      this.state.localAudioVolume = manager.localAudioVolume;
      this.state.remoteAudioVolume = manager.remoteAudioVolume;
    }
  }

  /** 新建输入后读取 SDK 默认值，用户已经调整过时恢复其设置。 */
  private async restoreRemoteAudioVolume(manager: XmaxRealtimeManaging): Promise<void> {
    if (!this.hasRemoteAudioVolumeSelection) {
      this.state.remoteAudioVolume = manager.remoteAudioVolume;
    }
    await this.applyRemoteAudioVolume();
  }

  async setAudioMuted(muted: boolean): Promise<void> {
    this.state.isAudioMuted = muted;
    await Promise.all([this.applyLocalAudioVolume(), this.applyRemoteAudioVolume()]);
  }

  async setLocalAudioVolume(volume: number): Promise<void> {
    this.state.localAudioVolume = volume;
    const wasMuted: boolean = this.state.isAudioMuted;
    this.state.isAudioMuted = false;
    await Promise.all([
      this.applyLocalAudioVolume(),
      wasMuted ? this.applyRemoteAudioVolume() : Promise.resolve()
    ]);
  }

  async setRemoteAudioVolume(volume: number): Promise<void> {
    this.hasRemoteAudioVolumeSelection = true;
    this.state.remoteAudioVolume = volume;
    const wasMuted: boolean = this.state.isAudioMuted;
    this.state.isAudioMuted = false;
    await Promise.all([
      this.applyRemoteAudioVolume(),
      wasMuted ? this.applyLocalAudioVolume() : Promise.resolve()
    ]);
  }

  private async applyLocalAudioVolume(): Promise<void> {
    const manager: XmaxRealtimeManaging | null = this.realtimeManager;
    const volume: number = this.state.isAudioMuted ? 0 : this.state.localAudioVolume;
    try {
      await manager?.setLocalAudioVolume(volume);
    } catch (error) {
      if (this.realtimeManager === manager &&
        volume === (this.state.isAudioMuted ? 0 : this.state.localAudioVolume)) {
        this.onMessage?.(this.errorMessage(error));
      }
    }
  }

  private async applyRemoteAudioVolume(): Promise<void> {
    const manager: XmaxRealtimeManaging | null = this.realtimeManager;
    const volume: number = this.state.isAudioMuted ? 0 : this.state.remoteAudioVolume;
    try {
      await manager?.setRemoteAudioVolume(volume);
    } catch (error) {
      if (this.realtimeManager === manager &&
        volume === (this.state.isAudioMuted ? 0 : this.state.remoteAudioVolume)) {
        this.onMessage?.(this.errorMessage(error));
      }
    }
  }

  // 点击只切换本地视频播放；生成会话的生命周期仍由 SDK 管理。
  async toggleLocalVideoPlayback(): Promise<void> {
    const manager: XmaxRealtimeManaging | null = this.realtimeManager;
    if (manager === null || this.localVideoPath.length === 0 || this.localImagePath.length > 0 ||
      this.localStream === null || this.connecting || this.changingLocalMedia ||
      this.changingVideoPlayback || this.state.isGenerationStarting ||
      manager.localVideoPlaybackState === undefined ||
      manager.localVideoPlaybackState === LocalVideoPlaybackState.ENDED) {
      return;
    }
    this.changingVideoPlayback = true;
    try {
      await manager.toggleLocalVideoStreamPlayback();
    } catch (error) {
      if (this.realtimeManager === manager) {
        this.onMessage?.(this.errorMessage(error));
      }
    } finally {
      if (this.realtimeManager === manager) {
        this.changingVideoPlayback = false;
      }
    }
  }

  async connect(
    context: common.UIAbilityContext,
    localVideoPath: string = '',
    localImagePath: string = '',
    usesExternalSource: boolean = false
  ): Promise<void> {
    if (this.realtimeManager !== null || this.connecting) {
      return;
    }
    this.connecting = true;
    this.localVideoPath = localVideoPath;
    this.localImagePath = localImagePath;
    this.usesExternalSource = usesExternalSource;
    this.state.isLocalPreviewLoading = true;
    this.state.errorMessage = '';

    let connectingManager: XmaxRealtimeManaging | null = null;
    try {
      const client = new XmaxClient(
        new XmaxConfiguration(
          XLabConfiguration.currentApiKey(),
          XLabLocalization.environment,
          XmaxLoggerOption.ALL
        ),
        context
      );
      const manager: XmaxRealtimeManaging = client.createRealtimeManager(
        new RealtimeConfiguration(
          RealtimeModels.realtime(XLabModelSelection.current())
        )
      );
      connectingManager = manager;
      this.realtimeManager = manager;
      this.state.supportedCameraFormats = manager.options.model.resolutionBuckets.map(
        size => manager.options.model.defaultCameraVideoFormat.resized(size.width, size.height)
      );
      manager.setUplinkVideoStatisticsListener((statistics: UplinkVideoStatistics | undefined): void => {
        if (this.realtimeManager === manager) {
          this.state.uplinkStatistics = statistics;
          this.refreshQualityLevels();
        }
      });
      manager.setDownlinkVideoStatisticsListener((statistics: DownlinkVideoStatistics | undefined): void => {
        if (this.realtimeManager === manager) {
          this.state.downlinkStatistics = statistics;
          this.refreshQualityLevels();
        }
      });
      manager.setNetworkQualityListener((quality: RealtimeNetworkQuality): void => {
        if (this.realtimeManager === manager) { this.state.networkQuality = quality; }
      });
      manager.setLocalVideoPlaybackStateListener((state: LocalVideoPlaybackState): void => {
        if (this.realtimeManager === manager) {
          this.state.localVideoPlaybackState = state;
          if (state === LocalVideoPlaybackState.ENDED) {
            this.onMessage?.(XLabLocalization.text('video_playback_ended'));
          }
        }
      });
      manager.setStateListener((state: RealtimeState): void => {
        if (this.realtimeManager !== manager) {
          return;
        }
        if (state.connectionState !== RealtimeConnectionState.GENERATING && this.recorder !== null) {
          void this.stopRecording(context);
        }
        const terminal: boolean = state.connectionState === RealtimeConnectionState.READY ||
          state.connectionState === RealtimeConnectionState.IDLE;
        if (terminal || state.connectionState === RealtimeConnectionState.DISCONNECTING) {
          this.clearStatistics();
        }
        if (terminal && state.reason !== undefined) {
          if (state.reason.kind === RealtimeReasonKind.ORIENTATION_CHANGED || state.reason.error !== undefined) {
            this.generationRevision++;
            this.clearGenerationSelection();
            this.remoteStream = null;
          }
          if (state.reason.error !== undefined) {
            this.state.errorMessage = state.reason.error.message;
          } else if (state.reason.kind === RealtimeReasonKind.ORIENTATION_CHANGED) {
            this.state.errorMessage = '';
            this.onMessage?.(XLabLocalization.text('orientation_changed'));
          }
        }
        this.state.isLocalPreviewLoading = state.connectionState === RealtimeConnectionState.PREPARING;
        if (state.connectionState === RealtimeConnectionState.IDLE) {
          this.state.localVideoPlaybackState = undefined;
          this.state.localVideoTrack = null;
          this.state.cameraZoom = undefined;
          this.localStream = null;
        }
        if (state.connectionState === RealtimeConnectionState.READY && this.state.cameraZoom === undefined) {
          this.state.cameraZoom = manager.currentCameraZoom;
        }
        if (state.connectionState !== RealtimeConnectionState.GENERATING) {
          this.state.remoteVideoTrack = null;
        } else if (this.state.remoteVideoTrack === null) {
          // SDK 内部重启生成（如转屏）后恢复远端画面；连接保留时远端轨道仍然有效。
          this.state.remoteVideoTrack = this.remoteStream?.videoTrack ?? null;
        }
        this.state.connectionState = state.connectionState;
        this.state.cameraVideoFormat = manager.currentCameraVideoFormat;
        this.refreshQualityLevels();
        if (state.connectionState === RealtimeConnectionState.CONNECTING) {
          this.pendingGenerationRestart = false;
          this.state.isGenerationStarting = true;
        }
        if (state.connectionState === RealtimeConnectionState.CONNECTED &&
          state.reason?.kind === RealtimeReasonKind.ORIENTATION_CHANGED) {
          // 转屏触发的重建期间保持 loading，直到重新生成确认进入 GENERATING。
          this.state.isGenerationStarting = true;
        }
        if (state.connectionState === RealtimeConnectionState.GENERATING ||
          state.connectionState === RealtimeConnectionState.IDLE) {
          this.pendingGenerationRestart = false;
          this.state.isGenerationStarting = false;
        } else if (terminal || state.connectionState === RealtimeConnectionState.DISCONNECTING) {
          // 替换请求时的断开和 READY 是中间状态，等待新请求期间保持 loading。
          this.state.isGenerationStarting = this.pendingGenerationRestart;
        }
        if (terminal || state.connectionState === RealtimeConnectionState.DISCONNECTING) {
          this.state.isMoxGenerationActive = false;
        }
      });

      await Promise.all([this.applyLocalAudioVolume(), this.applyRemoteAudioVolume()]);
      if (this.realtimeManager !== manager) {
        return;
      }
      const localStream: RealtimeMediaStream = await this.createLocalStream(
        manager,
        localVideoPath,
        localImagePath
      );
      if (this.realtimeManager !== manager) {
        return;
      }
      await this.restoreRemoteAudioVolume(manager);
      if (this.realtimeManager !== manager) {
        return;
      }
      this.localStream = localStream;
      this.state.localVideoTrack = localStream.videoTrack ?? null;
      this.state.cameraVideoFormat = manager.currentCameraVideoFormat;
      this.state.cameraZoom = manager.currentCameraZoom;
      if (localVideoPath.length > 0 || localImagePath.length > 0) {
        this.state.isLocalPreviewLoading = false;
      }
      // 本地预览不占用服务端会话；首次提交生成条件时再连接。
      this.scheduleGenerationUpdate();
    } catch (error) {
      if (connectingManager === null ||
        this.realtimeManager === connectingManager) {
        const message: string = this.errorMessage(error);
        this.state.errorMessage = message;
        this.state.remoteVideoTrack = null;
        this.state.isLocalPreviewLoading = false;
        this.logPreviewError(message);
      }
    } finally {
      if (this.realtimeManager === connectingManager) {
        this.connecting = false;
      }
    }
  }

  async resume(
    context: common.UIAbilityContext,
    fallbackVideoPath: string = '',
    fallbackImagePath: string = '',
    usesExternalSource: boolean = false
  ): Promise<void> {
    const hasPreservedInput: boolean = this.localVideoPath.length > 0 ||
      this.localImagePath.length > 0;
    await this.connect(
      context,
      hasPreservedInput ? this.localVideoPath : fallbackVideoPath,
      hasPreservedInput ? this.localImagePath : fallbackImagePath,
      usesExternalSource
    );
  }

  async updateCameraFormat(format: RealtimeVideoFormat): Promise<void> {
    const manager: XmaxRealtimeManaging | null = this.realtimeManager;
    const current: RealtimeVideoFormat | undefined = manager?.currentCameraVideoFormat;
    if (manager === null || current === undefined || !this.state.canUpdateCameraFormat ||
      this.connecting || this.switchingCamera || this.changingLocalMedia || this.generationUpdating) {
      return;
    }
    if (current.width === format.width && current.height === format.height) {
      return;
    }

    const revision: number = this.generationRevision;
    this.state.isCameraFormatUpdating = true;
    try {
      await manager.updateCameraFormat(current.resized(format.width, format.height));
      if (this.realtimeManager === manager) {
        this.state.cameraVideoFormat = manager.currentCameraVideoFormat;
      }
    } catch (error) {
      if (this.realtimeManager === manager) {
        this.onMessage?.(this.errorMessage(error));
      }
    } finally {
      if (this.realtimeManager === manager) {
        this.state.isCameraFormatUpdating = false;
        if (this.generationRevision !== revision) {
          this.scheduleGenerationUpdate();
        }
      }
    }
  }

  setCameraZoomRatio(ratio: number): void {
    const manager: XmaxRealtimeManaging | null = this.realtimeManager;
    const zoom: RealtimeCameraZoom | undefined = this.state.cameraZoom;
    if (manager === null || zoom === undefined || !this.state.canAdjustCameraZoom ||
      this.connecting || this.switchingCamera || this.changingLocalMedia || this.generationUpdating) {
      return;
    }

    try {
      manager.setCameraZoomRatio(ratio);
      // CameraKit may not report the new ratio until a subsequent frame.
      this.state.cameraZoom = new RealtimeCameraZoom(zoom.minRatio, zoom.maxRatio, ratio);
    } catch (error) {
      this.onMessage?.(this.errorMessage(error));
    }
  }

  async switchCamera(): Promise<void> {
    const manager: XmaxRealtimeManaging | null = this.realtimeManager;
    if (manager === null || this.connecting || this.switchingCamera ||
      this.changingLocalMedia || this.state.isCameraFormatUpdating || this.state.isGenerationStarting ||
      this.state.localVideoTrack?.position === undefined) {
      return;
    }

    this.switchingCamera = true;
    const switchRevision: number = ++this.generationRevision;
    this.state.errorMessage = '';
    try {
      this.state.isGenerationStarting =
        manager.currentState.connectionState === RealtimeConnectionState.GENERATING;
      const stream: RealtimeMediaStream = await manager.switchCamera();
      if (this.realtimeManager === manager) {
        this.localStream = stream;
        this.state.localVideoTrack = stream.videoTrack ?? null;
        this.state.cameraVideoFormat = manager.currentCameraVideoFormat;
        if (manager.currentState.connectionState === RealtimeConnectionState.GENERATING) {
          this.state.remoteVideoTrack = this.remoteStream?.videoTrack ?? null;
        }
      }
    } catch (error) {
      if (this.realtimeManager === manager && this.generationRevision === switchRevision) {
        this.presentError(error);
      }
    } finally {
      if (this.realtimeManager === manager) {
        this.state.cameraZoom = manager.currentCameraZoom;
        this.switchingCamera = false;
        this.state.isGenerationStarting = this.pendingGenerationRestart;
      }
    }

    if (this.realtimeManager === manager &&
      this.generationRevision !== switchRevision) {
      this.scheduleGenerationUpdate();
    }
  }

  async changeLocalVideo(filePath: string): Promise<void> {
    await this.changeLocalMedia(
      filePath,
      false,
      (
        manager: XmaxRealtimeManaging,
        resolvedPath: string
      ): Promise<RealtimeMediaStream> =>
        this.createLocalStream(manager, resolvedPath, '')
    );
  }

  async changeLocalImage(filePath: string): Promise<void> {
    await this.changeLocalMedia(
      filePath,
      true,
      (
        manager: XmaxRealtimeManaging,
        resolvedPath: string
      ): Promise<RealtimeMediaStream> =>
        manager.createLocalImageStream(resolvedPath)
    );
  }

  async suspend(): Promise<void> {
    await this.closeRealtime(true);
  }

  async disconnect(): Promise<void> {
    await this.closeRealtime(false);
  }

  private async closeRealtime(preservesLocalInput: boolean): Promise<void> {
    this.generationRevision++;
    this.recordingRevision++;
    const recorder: RealtimeVideoRecorder | null = this.recorder;
    this.recorder = null;
    const recordingCleanup: Promise<void> = recorder?.cancel() ?? this.recordingCompletion ?? Promise.resolve();
    const manager: XmaxRealtimeManaging | null = this.realtimeManager;
    let closePromise: Promise<void> | null = null;
    if (manager !== null) {
      manager.setStateListener(null);
      manager.setRemoteMediaFrameListener(null);
      manager.setLocalVideoPlaybackStateListener(null);
      manager.setUplinkVideoStatisticsListener(null);
      manager.setDownlinkVideoStatisticsListener(null);
      manager.setNetworkQualityListener(null);
      closePromise = manager.close();
    }
    this.realtimeManager = null;
    this.state.isQualityChanging = false;
    this.state.isCameraFormatUpdating = false;
    this.state.supportedCameraFormats = [];
    this.clearStatistics();
    this.localStream = null;
    this.remoteStream = null;
    if (!preservesLocalInput) {
      this.localVideoPath = '';
      this.localImagePath = '';
    }
    this.moxReferenceSourcePath = '';
    this.moxReferenceRemoteUrl = '';
    if (this.selectedReferenceItem !== null) {
      this.selectedReferenceItem.isSelected = false;
      this.selectedReferenceItem = null;
    }
    this.submittedPrompt = '';
    this.generationInputMode = GenerationInputMode.REFERENCE;
    this.state.selectedReferenceId = '';
    this.state.localVideoTrack = null;
    this.state.cameraVideoFormat = undefined;
    this.state.cameraZoom = undefined;
    this.state.remoteVideoTrack = null;
    this.state.isLocalPreviewLoading = true;
    this.connecting = false;
    this.switchingCamera = false;
    this.changingLocalMedia = false;
    this.changingVideoPlayback = false;
    this.state.localVideoPlaybackState = undefined;
    this.pendingGenerationRestart = false;
    this.state.isGenerationStarting = false;
    this.state.isMoxGenerationActive = false;
    this.state.errorMessage = '';
    if (closePromise !== null) {
      await closePromise;
    }
    await recordingCleanup;
    this.state.recordingState = RealtimeRecordingState.IDLE;
    if (this.realtimeManager === null) {
      this.state.connectionState = RealtimeConnectionState.IDLE;
    }
  }

  private clearStatistics(): void {
    this.state.uplinkStatistics = undefined;
    this.state.downlinkStatistics = undefined;
    this.state.networkQuality = undefined;
    this.state.uplinkQualityLevel = undefined;
    this.state.downlinkQualityLevel = undefined;
  }

  selectCategory(categoryId: string): void {
    const categoryExists: boolean = this.state.categories.some(
      (category: ReferenceCategory): boolean => category.id === categoryId
    );
    if (categoryExists) {
      this.state.selectedCategoryId = categoryId;
    }
  }

  updatePromptText(prompt: string): void {
    this.state.promptText = prompt;
  }

  submitPrompt(value: string): void {
    if (this.state.isCameraFormatUpdating) {
      return;
    }
    const prompt: string = value.trim();
    this.state.promptText = prompt;
    if (prompt.length === 0 || this.state.selectedCategoryId !== 'free' ||
      this.state.isPromptReferenceUploading) {
      return;
    }
    this.submittedPrompt = prompt;
    this.generationInputMode = GenerationInputMode.PROMPT;
    this.state.isMoxGenerationActive = false;
    this.scheduleGenerationUpdate();
  }

  startMoxGeneration(): void {
    if (this.state.selectedCategoryId !== 'mox' || this.state.isCameraFormatUpdating) {
      return;
    }

    const manager: XmaxRealtimeManaging | null = this.realtimeManager;
    const connectionAvailable: boolean = manager !== null && this.localStream !== null;
    if (!connectionAvailable) {
      const message: string = this.state.errorMessage.trim().length > 0 ?
        this.state.errorMessage : XLabLocalization.text('media_not_ready');
      this.onMessage?.(message);
      return;
    }

    if (this.selectedReferenceItem !== null) {
      this.selectedReferenceItem.isSelected = false;
      this.selectedReferenceItem = null;
      this.state.selectedReferenceId = '';
    }
    this.submittedPrompt = '';
    this.generationInputMode = GenerationInputMode.MOX;
    this.scheduleGenerationUpdate();
  }

  addPromptReference(filePath: string): void {
    const uploader: ReferenceUploading | null = this.referenceUploader;
    if (uploader === null) {
      this.onMessage?.(XLabLocalization.text('reference_not_ready'));
      return;
    }

    const reference = new Reference(
      `prompt-${Date.now()}-${RealtimeViewModel.nextCustomReferenceId++}`,
      'free',
      XLabLocalization.text('prompt_reference'),
      filePath,
      undefined,
      false,
      ReferenceUploadState.UPLOADING
    );
    const version: number = ++this.promptReferenceUploadVersion;
    this.promptReference = reference;
    this.state.promptReferenceImageUrl = '';
    this.state.isPromptReferenceUploading = true;

    uploader.uploadReference(filePath)
      .then((remoteUrl: string): void => {
        if (this.promptReferenceUploadVersion !== version ||
          this.promptReference !== reference) {
          return;
        }
        reference.remoteUrl = remoteUrl;
        reference.uploadState = ReferenceUploadState.READY;
        this.state.promptReferenceImageUrl = filePath;
        this.state.isPromptReferenceUploading = false;
      })
      .catch((_error: Object): void => {
        if (this.promptReferenceUploadVersion !== version ||
          this.promptReference !== reference) {
          return;
        }
        this.promptReference = null;
        this.state.promptReferenceImageUrl = '';
        this.state.isPromptReferenceUploading = false;
        this.onMessage?.(XLabLocalization.text('reference_upload_failed'));
      });
  }

  removePromptReference(): void {
    this.promptReferenceUploadVersion++;
    this.promptReference = null;
    this.state.promptReferenceImageUrl = '';
    this.state.isPromptReferenceUploading = false;
  }

  selectReference(item: RealtimeReferenceItemState): void {
    if (item.reference.isAddAction || this.state.isCameraFormatUpdating) {
      return;
    }
    if (item.reference.uploadState === ReferenceUploadState.FAILED &&
      item.reference.imageUrl !== undefined) {
      this.startReferenceUpload(item);
      return;
    }
    if (this.selectedReferenceItem === item) {
      this.clearReference();
      return;
    }
    if (this.selectedReferenceItem !== null) {
      this.selectedReferenceItem.isSelected = false;
    }
    item.isSelected = true;
    this.selectedReferenceItem = item;
    this.state.selectedReferenceId = item.reference.id;
    this.generationInputMode = GenerationInputMode.REFERENCE;
    this.state.isMoxGenerationActive = false;
    this.scheduleGenerationUpdate();
  }

  addLocalReference(categoryId: string, filePath: string): void {
    const reference = new Reference(
      `custom-${Date.now()}-${RealtimeViewModel.nextCustomReferenceId++}`,
      categoryId,
      XLabLocalization.text('custom_reference'),
      filePath,
      undefined,
      false,
      ReferenceUploadState.UPLOADING
    );
    const item = new RealtimeReferenceItemState(reference);
    this.state.referenceList(categoryId).insertAfterAddAction(item);
    this.selectReference(item);
    this.startReferenceUpload(item);
  }

  clearReference(): void {
    if (this.selectedReferenceItem === null) {
      return;
    }
    this.selectedReferenceItem.isSelected = false;
    this.selectedReferenceItem = null;
    this.state.selectedReferenceId = '';
    this.scheduleGenerationUpdate();
  }

  cancelGeneration(): void {
    this.clearGenerationSelection();
    this.scheduleGenerationUpdate();
  }

  private clearGenerationSelection(): void {
    this.pendingGenerationRestart = false;
    if (this.selectedReferenceItem !== null) {
      this.selectedReferenceItem.isSelected = false;
      this.selectedReferenceItem = null;
      this.state.selectedReferenceId = '';
    }
    this.submittedPrompt = '';
    this.generationInputMode = GenerationInputMode.REFERENCE;
    this.state.isGenerationStarting = false;
    this.state.isMoxGenerationActive = false;
  }

  private startReferenceUpload(item: RealtimeReferenceItemState): void {
    const uploader: ReferenceUploading | null = this.referenceUploader;
    const filePath: string | undefined = item.reference.imageUrl;
    if (uploader === null || filePath === undefined) {
      item.reference.uploadState = ReferenceUploadState.FAILED;
      this.onMessage?.(XLabLocalization.text('reference_not_ready'));
      return;
    }

    item.reference.uploadState = ReferenceUploadState.UPLOADING;
    const version: number = this.nextUploadVersion++;
    this.uploadVersions.set(item.reference.id, version);
    uploader.uploadReference(filePath)
      .then((remoteUrl: string): void => {
        if (this.uploadVersions.get(item.reference.id) !== version) {
          return;
        }
        item.reference.remoteUrl = remoteUrl;
        item.reference.uploadState = ReferenceUploadState.READY;
        this.uploadVersions.delete(item.reference.id);
        if (this.selectedReferenceItem === item) {
          this.scheduleGenerationUpdate();
        }
      })
      .catch((_error: Object): void => {
        if (this.uploadVersions.get(item.reference.id) !== version) {
          return;
        }
        item.reference.uploadState = ReferenceUploadState.FAILED;
        this.uploadVersions.delete(item.reference.id);
        this.onMessage?.(XLabLocalization.text('reference_upload_retry'));
      });
  }

  private scheduleGenerationUpdate(): void {
    this.generationRevision++;
    const manager: XmaxRealtimeManaging | null = this.realtimeManager;
    if (this.switchingCamera || this.generationUpdating) {
      // 取消旧操作时统一断开连接，停止麦克风并保留本地预览。
      if (manager !== null) {
        this.pendingGenerationRestart = this.hasGenerationInput();
        this.state.isGenerationStarting = this.pendingGenerationRestart;
        const stopping: Promise<void> = manager.disconnect();
        void stopping.catch((error: Object): void => {
          if (this.realtimeManager === manager) {
            this.presentError(error);
          }
        });
      }
      return;
    }
    if (this.changingLocalMedia || this.state.isCameraFormatUpdating) {
      return;
    }
    void this.applyGenerationUpdates();
  }

  private hasGenerationInput(): boolean {
    if (this.generationInputMode === GenerationInputMode.MOX) {
      return true;
    }
    if (this.generationInputMode === GenerationInputMode.REFERENCE) {
      return this.selectedReferenceItem?.reference.remoteUrl !== undefined;
    }
    return this.submittedPrompt.length > 0;
  }

  private async applyGenerationUpdates(): Promise<void> {
    this.generationUpdating = true;
    try {
      while (true) {
        const revision: number = this.generationRevision;
        const manager: XmaxRealtimeManaging | null = this.realtimeManager;
        const localStream: RealtimeMediaStream | null = this.localStream;
        if (manager === null || localStream === null || this.switchingCamera || this.changingLocalMedia ||
          this.state.isCameraFormatUpdating ||
          manager.currentState.connectionState === RealtimeConnectionState.CONNECTING ||
          manager.currentState.connectionState === RealtimeConnectionState.DISCONNECTING) {
          return;
        }
        const selectedReference: Reference | undefined = this.selectedReferenceItem?.reference;
        const usesPrompt: boolean = this.generationInputMode === GenerationInputMode.PROMPT;
        const usesMox: boolean = this.generationInputMode === GenerationInputMode.MOX;
        const prompt: string = usesPrompt || usesMox ? this.submittedPrompt :
          this.generationPrompt(selectedReference?.categoryId ?? '');
        try {
          const referencePath: string | undefined = usesPrompt ?
            this.promptReference?.remoteUrl : usesMox ?
              await this.resolveMoxReferencePath() : selectedReference?.remoteUrl;
          if (revision !== this.generationRevision || this.realtimeManager !== manager) {
            continue;
          }
          const shouldGenerate: boolean = usesMox || (usesPrompt ?
            prompt.length > 0 : referencePath !== undefined);
          if (shouldGenerate) {
            this.state.isMoxGenerationActive = usesMox;
            if (manager.currentState.connectionState !== RealtimeConnectionState.GENERATING) {
              this.state.isGenerationStarting = true;
            }
            // 摄像头输入开启人脸检测；图片和视频输入保持关闭。
            const isCameraInput: boolean =
              this.localImagePath.length === 0 && this.localVideoPath.length === 0;
            const faceRestoration: boolean = this.generationInputMode === GenerationInputMode.REFERENCE &&
              selectedReference?.categoryId === 'clothx';
            const remoteStream: RealtimeMediaStream = await manager.startGeneration(
              localStream, new RealtimeContext(prompt, referencePath, isCameraInput), faceRestoration
            );
            if (this.realtimeManager === manager && revision === this.generationRevision) {
              this.remoteStream = remoteStream;
              this.state.remoteVideoTrack = remoteStream.videoTrack ?? null;
            }
          } else {
            this.pendingGenerationRestart = false;
            this.state.isGenerationStarting = false;
            this.state.isMoxGenerationActive = false;
            await manager.disconnect();
          }
          if (shouldGenerate && this.realtimeManager === manager && revision === this.generationRevision) {
            this.state.errorMessage = '';
          }
        } catch (error) {
          if (revision === this.generationRevision && this.realtimeManager === manager) {
            this.pendingGenerationRestart = false;
            this.state.isGenerationStarting = false;
            this.state.isMoxGenerationActive = false;
            this.presentError(error);
            return;
          }
        }
        if (revision === this.generationRevision) {
          return;
        }
      }
    } finally {
      this.generationUpdating = false;
    }
  }

  private async changeLocalMedia(
    filePath: string,
    isImage: boolean,
    creation: LocalMediaCreation
  ): Promise<void> {
    const resolvedPath: string = filePath.trim();
    const manager: XmaxRealtimeManaging | null = this.realtimeManager;
    if (resolvedPath.length === 0 || manager === null || this.connecting ||
      this.switchingCamera || this.changingLocalMedia) {
      return;
    }

    const connectionState: RealtimeConnectionState =
      manager.currentState.connectionState;
    const shouldRestartGeneration: boolean = this.state.isGenerationStarting ||
      connectionState === RealtimeConnectionState.GENERATING;
    const previousVideoPath: string = this.localVideoPath;
    const previousImagePath: string = this.localImagePath;
    this.changingLocalMedia = true;
    this.state.localVideoPlaybackState = undefined;
    const changeRevision: number = ++this.generationRevision;
    this.state.isLocalPreviewLoading = true;
    this.state.errorMessage = '';

    let changed: boolean = false;
    let stream: RealtimeMediaStream | null = null;
    try {
      if (shouldRestartGeneration) {
        this.state.isGenerationStarting = true;
      }

      this.state.localVideoTrack = null;
      this.state.remoteVideoTrack = null;

      this.localStream = null;
      this.remoteStream = null;
      await manager.disconnect();
      if (this.realtimeManager !== manager) {
        return;
      }
      await this.stopLocalInput(
        manager,
        previousVideoPath,
        previousImagePath
      );
      if (this.realtimeManager !== manager) {
        return;
      }
      stream = await creation(manager, resolvedPath);
      if (this.realtimeManager !== manager) {
        return;
      }
      await this.restoreRemoteAudioVolume(manager);
      if (this.realtimeManager !== manager) {
        return;
      }

      this.localStream = stream;
      this.state.localVideoTrack = stream.videoTrack ?? null;
      this.state.isLocalPreviewLoading = false;
      if (isImage) {
        this.localImagePath = resolvedPath;
        this.localVideoPath = '';
        this.moxReferenceSourcePath = '';
        this.moxReferenceRemoteUrl = '';
      } else {
        this.localVideoPath = resolvedPath;
        this.localImagePath = '';
      }
      changed = true;
    } catch (error) {
      if (this.realtimeManager === manager) {
        this.state.localVideoTrack = stream?.videoTrack ?? null;
        this.state.remoteVideoTrack = null;
        this.state.isLocalPreviewLoading = false;
        this.state.isGenerationStarting = false;
        this.logPreviewError(this.errorMessage(error));
        this.presentError(error);
      }
    } finally {
      if (this.realtimeManager === manager) {
        this.changingLocalMedia = false;
      }
    }

    const generationChanged: boolean =
      this.generationRevision !== changeRevision;
    if (this.realtimeManager === manager && changed &&
      (shouldRestartGeneration || generationChanged)) {
      this.scheduleGenerationUpdate();
    }
  }

  private generationPrompt(categoryId: string): string {
    switch (categoryId) {
      case 'charx':
        return '视频中角色替换成参考图中角色';
      case 'clothx':
        return '视频中人物衣服替换成参考图中衣服';
      case 'vibex':
        return '视频风格变为参考图指定的风格';
      case 'dimx':
        return '指定角色在场景中互动';
      default:
        return '';
    }
  }

  private async resolveMoxReferencePath(): Promise<string | undefined> {
    const sourcePath: string = this.localImagePath.trim();
    if (sourcePath.length === 0) {
      return undefined;
    }
    if (this.moxReferenceSourcePath === sourcePath &&
      this.moxReferenceRemoteUrl.length > 0) {
      return this.moxReferenceRemoteUrl;
    }

    const uploader: ReferenceUploading | null = this.referenceUploader;
    if (uploader === null) {
      throw new Error(XLabLocalization.text('reference_not_ready'));
    }

    this.state.isGenerationStarting = true;
    const remoteUrl: string = await uploader.uploadReference(sourcePath);
    if (this.localImagePath.trim() !== sourcePath) {
      return undefined;
    }
    this.moxReferenceSourcePath = sourcePath;
    this.moxReferenceRemoteUrl = remoteUrl;
    return remoteUrl;
  }

  private async stopLocalInput(
    manager: XmaxRealtimeManaging,
    localVideoPath: string,
    localImagePath: string
  ): Promise<void> {
    if (localImagePath.length > 0) {
      await manager.stopLocalImageStream();
      return;
    }
    if (localVideoPath.length > 0) {
      if (this.usesExternalSource) {
        await manager.stopExternalVideoStream();
        return;
      }
      await manager.stopLocalVideoStream();
      return;
    }

    await manager.stopLocalCameraStream();
  }

  private async createLocalStream(
    manager: XmaxRealtimeManaging,
    localVideoPath: string,
    localImagePath: string
  ): Promise<RealtimeMediaStream> {
    if (localImagePath.length > 0) {
      return manager.createLocalImageStream(localImagePath);
    }

    if (localVideoPath.length > 0) {
      if (this.usesExternalSource) {
        const source: RealtimeFileVideoSource = await RealtimeFileVideoSource.create(
          localVideoPath,
          manager.options.model.defaultFrameRate,
          manager.options.model.maximumInputPixels
        );
        try {
          return await manager.createExternalVideoStream(source);
        } catch (error) {
          await source.stop();
          throw error as Error;
        }
      }
      return manager.createLocalVideoStream(localVideoPath);
    }

    return manager.createLocalCameraStream(
      manager.options.model.defaultCameraVideoFormat,
      CameraPosition.FRONT,
      true
    );
  }

  private errorMessage(error: Object): string {
    if (error instanceof Error) {
      return error.message;
    }
    return String(error);
  }

  private presentError(error: Object): void {
    const message: string = this.errorMessage(error);
    this.state.errorMessage = message;
    this.onMessage?.(message);
  }

  private logPreviewError(message: string): void {
    hilog.error(
      LOG_DOMAIN,
      LOG_TAG,
      'Failed to load local preview: %{public}s',
      message
    );
  }
}
