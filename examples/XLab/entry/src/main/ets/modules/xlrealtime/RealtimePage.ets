import { XLabLocalization } from '../../localization/XLabLocalization';
import { common } from '@kit.AbilityKit';
import { mediaquery, promptAction } from '@kit.ArkUI';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  DefaultTrajectoryEffectRenderer,
  LocalVideoPlaybackState,
  RealtimeQualityLevel,
  RealtimeVideoFormat,
  TrajectoryEffectRendering,
  VideoContentMode,
  XmaxRealtimeDualVideo
} from '@xmax/sdk';
import { XLabApplicationLifecycle } from '../../application/XLabApplicationLifecycle';
import { XLabConfiguration } from './config/XLabConfiguration';
import {
  RealtimeCategoryState,
  RealtimeReferenceItemState,
  RealtimeViewState
} from './mvvm/model/RealtimeViewState';
import { RealtimeLoadingView } from './mvvm/view/RealtimeLoadingView';
import { RealtimeStatisticsPanel, RealtimeStatisticsButton } from './mvvm/view/RealtimeStatisticsPanel';
import { RealtimeAudioControlsView } from './mvvm/view/RealtimeAudioControlsView';
import { RealtimeRecordingButton } from './mvvm/view/RealtimeRecordingButton';
import { RealtimeCameraFormatButton } from './mvvm/view/RealtimeCameraFormatButton';
import { RealtimeCameraZoomButton } from './mvvm/view/RealtimeCameraZoomButton';
import { RealtimePromptInputView } from './mvvm/view/RealtimePromptInputView';
import { RealtimeReferenceListView } from './mvvm/view/RealtimeReferenceListView';
import { RealtimeViewModel } from './mvvm/viewmodel/RealtimeViewModel';
import { CustomTrajectoryRenderer } from './rendering/CustomTrajectoryRenderer';
import { ReferenceCategory, ReferenceCategoryInput } from './reference/ReferenceCategory';
import { ReferencePhotoPicker } from './reference/ReferencePhotoPicker';
import { ReferenceUploader } from './reference/ReferenceUploader';

const CAMERA_SWITCH_BLUR_RADIUS: number = 48;
const LOCAL_FILE_VIEW_TOP_INSET: number = 84;
const STATISTICS_PANEL_TOP_INSET: number = 80;
const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'RealtimePage';

@Component
struct CancelGenerationButton {
  @StorageLink(XLabLocalization.REVISION_KEY) private languageRevision: number = 0;

  private text(key: string): string {
    return XLabLocalization.text(key, this.languageRevision);
  }

  @Prop isEnabled: boolean = false;
  onCancel: () => void = (): void => {};

  build() {
    Button({ type: ButtonType.Normal }) {
      SymbolGlyph($r('sys.symbol.nosign'))
        .fontSize(13)
        .fontColor(['#FFFFFF'])
    }
    .width(36)
    .height(36)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .borderRadius(18)
    .enabled(this.isEnabled)
    .opacity(this.isEnabled ? 1 : 0.32)
    .animation({ duration: 300, curve: Curve.EaseInOut })
    .accessibilityText(this.text('stop_generation'))
    .onClick(this.onCancel)
  }
}

@Component
export struct RealtimePage {
  @StorageLink(XLabLocalization.REVISION_KEY) private languageRevision: number = 0;

  private text(key: string): string {
    return XLabLocalization.text(key, this.languageRevision);
  }

  @Prop localVideoPath: string = '';
  @Prop localImagePath: string = '';
  @Prop usesCustomTrajectoryRenderer: boolean = false;
  @Prop usesExternalSource: boolean = false;

  // 页面组件
  private readonly viewModel: RealtimeViewModel = new RealtimeViewModel();
  private readonly promptInputController: TextInputController = new TextInputController();

  // 渲染组件
  private readonly defaultTrajectoryRenderer: TrajectoryEffectRendering =
    new DefaultTrajectoryEffectRenderer();
  private readonly customTrajectoryRenderer: TrajectoryEffectRendering =
    new CustomTrajectoryRenderer();

  // 页面状态
  @State private state: RealtimeViewState = this.viewModel.state;
  @State private isCameraSwitchTransitionActive: boolean = false;
  @State private cameraSwitchBlurRadius: number = 0;
  @State private cameraSwitchRotation: number = 0;
  @State private isPickingLocalMedia: boolean = false;
  @State private isLandscape: boolean = false;
  @State private isStatisticsVisible: boolean = false;
  private orientationQuery: mediaquery.MediaQueryListener | null = null;
  private readonly orientationListener = (result: mediaquery.MediaQueryResult): void => {
    this.isLandscape = result.matches;
  };
  @StorageLink(XLabApplicationLifecycle.FOREGROUND_STORAGE_KEY)
  @Watch('onApplicationForegroundChanged')
  private isApplicationForeground: boolean = true;
  private isPickingReference: boolean = false;

  // 生命周期协调
  private lifecycleOperationVersion: number = 0;
  private realtimeCleanup: Promise<void> | null = null;

  private localContentMode(): VideoContentMode {
    return this.hasLocalFile() ? VideoContentMode.FIT : this.state.cameraPreviewContentMode;
  }

  private trajectoryRenderer(): TrajectoryEffectRendering {
    return this.usesCustomTrajectoryRenderer ?
      this.customTrajectoryRenderer : this.defaultTrajectoryRenderer;
  }

  private dismissKeyboard(): void {
    this.promptInputController.stopEditing();
  }

  private toggleStatistics(): void {
    this.isStatisticsVisible = !this.isStatisticsVisible;
    if (this.isStatisticsVisible) {
      this.viewModel.refreshQualityLevels();
    }
  }

  private async switchCamera(): Promise<void> {
    if (this.isCameraSwitchTransitionActive || this.state.isCameraFormatUpdating) {
      return;
    }

    const lifecycleVersion: number = this.lifecycleOperationVersion;
    this.isCameraSwitchTransitionActive = true;
    this.cameraSwitchBlurRadius = 0;
    this.cameraSwitchRotation = 0;

    await this.coverCameraPreview();
    if (lifecycleVersion !== this.lifecycleOperationVersion) {
      this.resetCameraSwitchTransition();
      return;
    }

    const switchPromise: Promise<void> = this.viewModel.switchCamera();
    await this.animateCameraSwitch();
    if (lifecycleVersion !== this.lifecycleOperationVersion) {
      this.resetCameraSwitchTransition();
      return;
    }

    await switchPromise;
    if (lifecycleVersion !== this.lifecycleOperationVersion) {
      this.resetCameraSwitchTransition();
      return;
    }

    await this.finishCameraSwitchTransition();
  }

  private resetCameraSwitchTransition(): void {
    this.isCameraSwitchTransitionActive = false;
    this.cameraSwitchBlurRadius = 0;
    this.cameraSwitchRotation = 0;
  }

  private coverCameraPreview(): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      this.getUIContext().animateTo({
        duration: 140,
        curve: Curve.EaseIn,
        onFinish: (): void => {
          resolve();
        }
      }, (): void => {
        this.cameraSwitchBlurRadius = CAMERA_SWITCH_BLUR_RADIUS;
      });
    });
  }

  private animateCameraSwitch(): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      this.getUIContext().animateTo({
        duration: 500,
        curve: Curve.EaseInOut,
        onFinish: (): void => {
          this.cameraSwitchRotation = 0;
          resolve();
        }
      }, (): void => {
        this.cameraSwitchRotation = 180;
      });
    });
  }

  private finishCameraSwitchTransition(): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      this.getUIContext().animateTo({
        duration: 180,
        curve: Curve.EaseOut,
        onFinish: (): void => {
          this.isCameraSwitchTransitionActive = false;
          resolve();
        }
      }, (): void => {
        this.cameraSwitchBlurRadius = 0;
      });
    });
  }

  aboutToAppear(): void {
    this.orientationQuery = this.getUIContext().getMediaQuery().matchMediaSync('(orientation: landscape)');
    this.orientationQuery.on('change', this.orientationListener);
    this.isLandscape = this.orientationQuery.matches;
    if (this.hasLocalImage()) {
      this.viewModel.selectCategory('mox');
    }

    this.viewModel.onMessage = (message: string): void => {
      promptAction.showToast({ message: message });
    };
    if (this.isApplicationForeground) {
      this.resumeRealtime();
    }
  }

  aboutToDisappear(): void {
    this.orientationQuery?.off('change', this.orientationListener);
    this.orientationQuery = null;
    this.viewModel.onMessage = null;
    this.suspendRealtime(false);
  }

  private onApplicationForegroundChanged(): void {
    if (this.isApplicationForeground) {
      this.resumeRealtime();
      return;
    }

    this.dismissKeyboard();
    this.suspendRealtime(true);
  }

  private resumeRealtime(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const operationVersion: number = ++this.lifecycleOperationVersion;
    const pendingCleanup: Promise<void> | null = this.realtimeCleanup;

    void this.restoreRealtimeAfterCleanup(
      context,
      operationVersion,
      pendingCleanup
    );
  }

  private async restoreRealtimeAfterCleanup(
    context: common.UIAbilityContext,
    operationVersion: number,
    pendingCleanup: Promise<void> | null
  ): Promise<void> {
    if (pendingCleanup !== null) {
      await pendingCleanup;
    }
    if (operationVersion !== this.lifecycleOperationVersion ||
      !this.isApplicationForeground) {
      return;
    }

    this.viewModel.setReferenceUploader(
      new ReferenceUploader(context, XLabConfiguration.currentApiKey())
    );
    await this.viewModel.resume(
      context,
      this.localVideoPath,
      this.localImagePath,
      this.usesExternalSource
    );
  }

  private suspendRealtime(preservesLocalInput: boolean): void {
    this.lifecycleOperationVersion++;
    this.resetCameraSwitchTransition();

    if (this.realtimeCleanup !== null) {
      return;
    }

    const cleanup: Promise<void> = this.cleanupRealtime(preservesLocalInput);
    this.realtimeCleanup = cleanup;
  }

  private async cleanupRealtime(preservesLocalInput: boolean): Promise<void> {
    try {
      if (preservesLocalInput) {
        await this.viewModel.suspend();
      } else {
        await this.viewModel.disconnect();
      }
    } catch (error) {
      const message: string = error instanceof Error ? error.message : String(error);
      hilog.error(
        LOG_DOMAIN,
        LOG_TAG,
        'Failed to clean up realtime resources: %{public}s',
        message
      );
    } finally {
      this.realtimeCleanup = null;
    }
  }

  private async presentReferencePhotoPicker(categoryId: string): Promise<void> {
    if (this.isPickingReference) {
      return;
    }
    this.isPickingReference = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const filePath: string | undefined = await ReferencePhotoPicker.pickImage(context);
      if (filePath !== undefined) {
        this.viewModel.addLocalReference(categoryId, filePath);
      }
    } catch (_error) {
      promptAction.showToast({ message: this.text('read_photo_failed') });
    } finally {
      this.isPickingReference = false;
    }
  }

  private async presentPromptReferencePhotoPicker(): Promise<void> {
    if (this.isPickingReference) {
      return;
    }
    this.isPickingReference = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const filePath: string | undefined = await ReferencePhotoPicker.pickImage(context);
      if (filePath !== undefined) {
        this.viewModel.addPromptReference(filePath);
      }
    } catch (_error) {
      promptAction.showToast({ message: this.text('read_photo_failed') });
    } finally {
      this.isPickingReference = false;
    }
  }

  private async presentLocalMediaPicker(): Promise<void> {
    if (this.isPickingLocalMedia) {
      return;
    }

    this.isPickingLocalMedia = true;
    try {
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = this.hasLocalImage() ?
        photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE :
        photoAccessHelper.PhotoViewMIMETypes.VIDEO_TYPE;
      options.maxSelectNumber = 1;

      const picker = new photoAccessHelper.PhotoViewPicker();
      const result = await picker.select(options);
      const filePath: string | undefined = result.photoUris[0];
      if (filePath === undefined || filePath.trim().length === 0) {
        return;
      }

      if (this.hasLocalImage()) {
        await this.viewModel.changeLocalImage(filePath);
      } else {
        await this.viewModel.changeLocalVideo(filePath);
      }
    } catch (_error) {
      const mediaName: string = this.hasLocalImage() ? this.text('image') : this.text('video');
      promptAction.showToast({ message: XLabLocalization.format('read_media_failed', [mediaName]) });
    } finally {
      this.isPickingLocalMedia = false;
    }
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.TopStart }) {
        Stack({ alignContent: Alignment.TopStart }) {
          if (this.state.localVideoTrack !== null) {
            Stack() {
              XmaxRealtimeDualVideo({
                localTrack: this.state.localVideoTrack,
                remoteTrack: this.state.remoteVideoTrack ?? undefined,
                contentMode: this.localContentMode(),
                isInteractionEnabled: !this.hasLocalVideo(),
                trajectoryRenderer: this.trajectoryRenderer()
              })
                .width('100%')
                .height('100%')
                .onClick((): void => {
                  if (this.hasLocalVideo()) {
                    void this.viewModel.toggleLocalVideoPlayback();
                  }
                })

              if (this.hasLocalVideo() && this.state.localVideoPlaybackState === LocalVideoPlaybackState.PAUSE) {
                SymbolGlyph($r('sys.symbol.play_fill'))
                  .fontSize(24)
                  .fontColor(['#FFFFFF'])
                  .padding(12)
                  .backgroundColor('#66000000')
                  .borderRadius(24)
                  .hitTestBehavior(HitTestMode.None)
              }

              if (this.isCameraSwitchTransitionActive) {
                Row()
                  .width('100%')
                  .height('100%')
                  .backgroundColor('#66000000')
                  .opacity(this.cameraSwitchBlurRadius / CAMERA_SWITCH_BLUR_RADIUS)
                  .hitTestBehavior(HitTestMode.None)
              }
            }
            .width('100%')
            .height('100%')
            .blur(this.cameraSwitchBlurRadius)
            .rotate({
              y: 1,
              angle: this.cameraSwitchRotation,
              perspective: 600
            })
          }

          if (this.state.isLocalPreviewLoading ||
            this.state.isGenerationStarting) {
            RealtimeLoadingView()
              .transition(TransitionEffect.OPACITY.animation({
                duration: 300,
                curve: Curve.EaseInOut
              }))
          }

          if (this.state.errorMessage.length > 0) {
            Row() {
              Text(this.state.errorMessage)
                .fontSize(12)
                .fontColor('#FFFFFFFF')
                .textAlign(TextAlign.Center)
                .backgroundColor('#B3000000')
                .borderRadius(8)
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            }
            .width('100%')
            .height('100%')
            .padding({ left: 68, right: 68 })
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .hitTestBehavior(HitTestMode.None)
          }
        }
        .width('100%')
        .height(this.hasLocalFile() ?
          `calc(100% - ${LOCAL_FILE_VIEW_TOP_INSET}vp)` : '100%')
        .margin({ top: this.hasLocalFile() ? LOCAL_FILE_VIEW_TOP_INSET : 0 })

        if (!this.hasLocalFile()) {
          Button({ type: ButtonType.Normal }) {
            Column({ space: 4 }) {
              Image($r('app.media.realtime_camera_rotate'))
                .width(20)
                .height(20)

              Text(this.text('flip'))
                .fontSize(10)
                .lineHeight(12)
                .fontWeight(FontWeight.Medium)
                .fontColor('#FFFFFF')
                .textShadow({ radius: 2, color: '#80000000', offsetX: 0, offsetY: 1 })
            }
            .height(36)
            .justifyContent(FlexAlign.Center)
          }
          .width(58)
          .height(58)
          .padding(0)
          .position({ right: 8, top: 18 })
          .fontColor('#FFFFFF')
          .backgroundColor(Color.Transparent)
          .enabled(!this.isCameraSwitchTransitionActive && !this.state.isCameraFormatUpdating)
          .accessibilityText(this.text('flip_camera'))
          .onClick((): void => {
            void this.switchCamera();
          })
          if (this.state.cameraZoom !== undefined) {
            RealtimeCameraZoomButton({
              state: this.state,
              isCameraSwitching: this.isCameraSwitchTransitionActive,
              onSelect: (ratio: number): void => this.viewModel.setCameraZoomRatio(ratio)
            })
              .position({ right: 66, top: 18 })
          }
          RealtimeAudioControlsView({
            state: this.state,
            isCamera: true,
            onOpenVolumeMenu: (): void => this.viewModel.refreshAudioVolumes(),
            onRemoteVolumeChanged: (volume: number): void => {
              void this.viewModel.setRemoteAudioVolume(volume);
            }
          })
            .position({ right: 8, top: 76 })
          RealtimeRecordingButton({
            state: this.state,
            onToggle: (): void => {
              this.viewModel.toggleRecording(this.getUIContext().getHostContext() as common.UIAbilityContext);
            }
          })
            .position({ right: 15, top: 134 })
        } else {
          Row() {
            RealtimeRecordingButton({
              state: this.state,
              onToggle: (): void => {
                this.viewModel.toggleRecording(this.getUIContext().getHostContext() as common.UIAbilityContext);
              }
            })
            RealtimeStatisticsButton({
              isActive: this.isStatisticsVisible,
              buttonWidth: 44,
              onToggle: (): void => { this.toggleStatistics(); }
            })
            if (!this.hasLocalImage()) {
              RealtimeAudioControlsView({
                state: this.state,
                onOpenVolumeMenu: (): void => this.viewModel.refreshAudioVolumes(),
                onLocalVolumeChanged: (volume: number): void => {
                  void this.viewModel.setLocalAudioVolume(volume);
                },
                onRemoteVolumeChanged: (volume: number): void => {
                  void this.viewModel.setRemoteAudioVolume(volume);
                },
                onMuteChanged: (muted: boolean): void => {
                  void this.viewModel.setAudioMuted(muted);
                }
              })
            }
            Button({ type: ButtonType.Normal }) {
              Column({ space: 4 }) {
                SymbolGlyph($r('sys.symbol.picture'))
                  .fontSize(20)
                  .fontColor(['#FFFFFF'])

                Text(this.text('album'))
                  .fontSize(10)
                  .lineHeight(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#FFFFFF')
                  .textShadow({ radius: 2, color: '#80000000', offsetX: 0, offsetY: 1 })
              }
              .height(36)
              .justifyContent(FlexAlign.Center)
            }
            .width(44)
            .height(58)
            .padding(0)
            .fontColor('#FFFFFF')
            .backgroundColor(Color.Transparent)
            .enabled(!this.isPickingLocalMedia)
            .opacity(this.isPickingLocalMedia ? 0.5 : 1)
            .accessibilityText(this.text('replace_media'))
            .onClick((): void => {
              void this.presentLocalMediaPicker();
            })
          }
          .width(this.hasLocalImage() ? 132 : 220)
          .height(58)
          .position({ right: 8, top: 18 })
        }
        if (this.isStatisticsVisible) {
          RealtimeStatisticsPanel({
            state: this.state,
            maximumHeight: `calc(100% - ${STATISTICS_PANEL_TOP_INSET + 12}vp)`,
            onUplinkQualitySelect: (level: RealtimeQualityLevel): void => {
              void this.viewModel.setUplinkQualityLevel(level);
            },
            onDownlinkQualitySelect: (level: RealtimeQualityLevel): void => {
              void this.viewModel.setDownlinkQualityLevel(level);
            }
          })
            .width(this.isLandscape ? 216 : 228)
            .position({ left: 12, top: STATISTICS_PANEL_TOP_INSET })
        }
        if (!this.hasLocalFile()) {
          RealtimeStatisticsButton({
            isActive: this.isStatisticsVisible,
            onToggle: (): void => { this.toggleStatistics(); }
          })
            .position({ right: 8, top: 192 })
          if (this.state.supportedCameraFormats.length > 1) {
            RealtimeCameraFormatButton({
              state: this.state,
              isCameraSwitching: this.isCameraSwitchTransitionActive,
              onSelect: (format: RealtimeVideoFormat): void => {
                void this.viewModel.updateCameraFormat(format);
              }
            })
              .position({ right: 8, top: 250 })
          }
        }
      }
      .width('100%')
      .layoutWeight(1)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
      .onClick((): void => {
        this.dismissKeyboard();
      })

      Column() {
        Row() {
          CancelGenerationButton({
            isEnabled: this.state.canCancelGeneration,
            onCancel: (): void => {
              this.dismissKeyboard();
              this.viewModel.cancelGeneration();
            }
          })
            .margin({ left: 6, right: 6 })

          List({ space: 22 }) {
            ForEach(this.state.categories, (category: ReferenceCategory) => {
              ListItem() {
                Text(this.text(category.name))
                  .height(36)
                  .fontSize(12)
                  .fontWeight(this.state.selectedCategoryId === category.id ?
                    FontWeight.Bold : FontWeight.Regular)
                  .fontColor(this.state.selectedCategoryId === category.id ?
                    '#FFFFFF' : '#7AFFFFFF')
                  .textAlign(TextAlign.Center)
                  .onClick((): void => {
                    this.dismissKeyboard();
                    this.viewModel.selectCategory(category.id);
                  })
              }
            }, (category: ReferenceCategory): string => category.id)
          }
          .listDirection(Axis.Horizontal)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .contentEndOffset(16)
          .layoutWeight(1)
          .height(36)
        }
        .width('100%')
        .height(40)
        .alignItems(VerticalAlign.Bottom)
        .onClick((): void => {
          this.dismissKeyboard();
        })

        Stack({ alignContent: Alignment.TopStart }) {
          ForEach(this.state.categoryStates, (categoryState: RealtimeCategoryState) => {
            if (categoryState.category.input === ReferenceCategoryInput.PROMPT) {
              RealtimePromptInputView({
                prompt: this.state.promptText,
                referenceImageUrl: this.state.promptReferenceImageUrl,
                isReferenceUploading: this.state.isPromptReferenceUploading,
                controller: this.promptInputController,
                onPromptChange: (prompt: string): void => {
                  this.viewModel.updatePromptText(prompt);
                },
                onSubmit: (prompt: string): void => {
                  this.dismissKeyboard();
                  this.viewModel.submitPrompt(prompt);
                },
                onAddReference: (): void => {
                  this.dismissKeyboard();
                  void this.presentPromptReferencePhotoPicker();
                },
                onRemoveReference: (): void => {
                  this.viewModel.removePromptReference();
                }
              })
                .width('calc(100% - 28vp)')
                .margin({ left: 14, right: 14, top: 2 })
                .visibility(this.state.selectedCategoryId === categoryState.category.id ?
                  Visibility.Visible : Visibility.Hidden)
                .hitTestBehavior(this.state.selectedCategoryId === categoryState.category.id ?
                  HitTestMode.Default : HitTestMode.None)
            } else if (categoryState.category.input === ReferenceCategoryInput.INSTRUCTION) {
              Button(this.state.isMoxGenerationActive ?
                this.text(categoryState.category.instruction) : this.text('start_generation'), { type: ButtonType.Normal })
                .width('calc(100% - 28vp)')
                .height(40)
                .margin({ left: 14, right: 14, top: 10 })
                .padding({ left: 14, right: 14 })
                .fontSize(this.state.isMoxGenerationActive ? 11 : 12)
                .fontColor(this.state.isMoxGenerationActive ? '#66FFFFFF' : '#D9FFFFFF')
                .backgroundColor(this.state.isMoxGenerationActive ? '#18FFFFFF' : '#24FFFFFF')
                .border({ width: 1, color: '#30FFFFFF' })
                .borderRadius(20)
                .onClick((): void => {
                  this.dismissKeyboard();
                  if (!this.state.isMoxGenerationActive) {
                    this.viewModel.startMoxGeneration();
                  }
                })
                .visibility(this.state.selectedCategoryId === categoryState.category.id ?
                  Visibility.Visible : Visibility.Hidden)
                .hitTestBehavior(this.state.selectedCategoryId === categoryState.category.id ?
                  HitTestMode.Default : HitTestMode.None)
            } else {
              RealtimeReferenceListView({
                listState: categoryState.referenceList,
                onSelectReference: (item: RealtimeReferenceItemState): void => {
                  this.dismissKeyboard();
                  this.viewModel.selectReference(item);
                },
                onAddReference: (categoryId: string): void => {
                  this.dismissKeyboard();
                  void this.presentReferencePhotoPicker(categoryId);
                }
              })
                .visibility(this.state.selectedCategoryId === categoryState.category.id ?
                  Visibility.Visible : Visibility.Hidden)
                .hitTestBehavior(this.state.selectedCategoryId === categoryState.category.id ?
                  HitTestMode.Default : HitTestMode.None)
            }
          }, (categoryState: RealtimeCategoryState): string => categoryState.category.id)
        }
        .width('100%')
        .height(60)
      }
      .width('100%')
      .padding({ bottom: 12 })
      .enabled(!this.state.isCameraFormatUpdating)
      .backgroundColor('#0D0D0E')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    .expandSafeArea(
      [SafeAreaType.SYSTEM],
      [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]
    )
  }

  private hasLocalFile(): boolean {
    return this.localVideoPath.length > 0 || this.localImagePath.length > 0;
  }

  private hasLocalVideo(): boolean {
    return this.localVideoPath.length > 0 && !this.hasLocalImage();
  }

  private hasLocalImage(): boolean {
    return this.localImagePath.length > 0;
  }
}
