import { DownlinkVideoStatistics, UplinkVideoStatistics, RealtimeNetworkQuality, RealtimeQualityLevel, LocalVideoPlaybackState, RealtimeCameraZoom, RealtimeConnectionState, RealtimeVideoFormat, RealtimeVideoTrack, VideoContentMode } from '@xmax/sdk';
import { Reference } from '../../reference/Reference';
import { ReferenceCategory } from '../../reference/ReferenceCategory';
import { RealtimeRecordingState } from '../../recording/RealtimeRecordingState';

@Observed
export class RealtimeReferenceItemState {
  readonly reference: Reference;
  isSelected: boolean = false;

  constructor(reference: Reference) {
    this.reference = reference;
  }
}

@Observed
export class RealtimeReferenceListState {
  items: RealtimeReferenceItemState[];

  constructor(references: Reference[]) {
    this.items = references.map(
      (reference: Reference): RealtimeReferenceItemState =>
        new RealtimeReferenceItemState(reference)
    );
  }

  insertAfterAddAction(item: RealtimeReferenceItemState): void {
    const nextItems: RealtimeReferenceItemState[] = this.items.slice();
    const addIndex: number = nextItems.findIndex(
      (candidate: RealtimeReferenceItemState): boolean => candidate.reference.isAddAction
    );
    nextItems.splice(addIndex < 0 ? 0 : addIndex + 1, 0, item);
    this.items = nextItems;
  }
}

@Observed
export class RealtimeCategoryState {
  readonly category: ReferenceCategory;
  readonly referenceList: RealtimeReferenceListState;

  constructor(category: ReferenceCategory) {
    this.category = category;
    this.referenceList = new RealtimeReferenceListState(category.references);
  }
}

@Observed
export class RealtimeViewState {
  selectedCategoryId: string;
  selectedReferenceId: string = '';
  promptText: string = '';
  promptReferenceImageUrl: string = '';
  isPromptReferenceUploading: boolean = false;
  connectionState: RealtimeConnectionState = RealtimeConnectionState.IDLE;
  localVideoTrack: RealtimeVideoTrack | null = null;
  cameraVideoFormat: RealtimeVideoFormat | undefined = undefined;
  cameraZoom: RealtimeCameraZoom | undefined = undefined;
  remoteVideoTrack: RealtimeVideoTrack | null = null;
  localVideoPlaybackState: LocalVideoPlaybackState | undefined = undefined;
  uplinkStatistics: UplinkVideoStatistics | undefined = undefined;
  downlinkStatistics: DownlinkVideoStatistics | undefined = undefined;
  networkQuality: RealtimeNetworkQuality | undefined = undefined;
  uplinkQualityLevel: RealtimeQualityLevel | undefined = undefined;
  downlinkQualityLevel: RealtimeQualityLevel | undefined = undefined;
  isQualityChanging: boolean = false;
  supportedCameraFormats: RealtimeVideoFormat[] = [];
  isCameraFormatUpdating: boolean = false;
  recordingState: RealtimeRecordingState = RealtimeRecordingState.IDLE;
  isLocalPreviewLoading: boolean = true;
  isGenerationStarting: boolean = false;
  isMoxGenerationActive: boolean = false;
  errorMessage: string = '';
  localAudioVolume: number = 0.45;
  remoteAudioVolume: number = 1;
  isAudioMuted: boolean = false;
  readonly categories: ReferenceCategory[];
  readonly categoryStates: RealtimeCategoryState[];
  private readonly emptyReferenceList: RealtimeReferenceListState = new RealtimeReferenceListState([]);

  constructor(categories: ReferenceCategory[]) {
    this.categories = categories;
    this.categoryStates = categories.map(
      (category: ReferenceCategory): RealtimeCategoryState => new RealtimeCategoryState(category)
    );
    this.selectedCategoryId = categories.length > 0 ? categories[0].id : '';
  }

  get hasSelectedReference(): boolean {
    return this.selectedReferenceId.length > 0;
  }

  get canCancelGeneration(): boolean {
    return this.isGenerationStarting ||
      this.connectionState === RealtimeConnectionState.GENERATING;
  }

  get canAdjustQuality(): boolean {
    return this.connectionState === RealtimeConnectionState.GENERATING &&
      !this.isGenerationStarting && !this.isQualityChanging;
  }

  get canUpdateCameraFormat(): boolean {
    return this.connectionState === RealtimeConnectionState.READY &&
      this.localVideoTrack?.position !== undefined && !this.isLocalPreviewLoading &&
      !this.isGenerationStarting && !this.isCameraFormatUpdating;
  }

  get canAdjustCameraZoom(): boolean {
    return this.cameraZoom !== undefined && !this.isLocalPreviewLoading &&
      !this.isGenerationStarting && !this.isCameraFormatUpdating &&
      (this.connectionState === RealtimeConnectionState.READY ||
        this.connectionState === RealtimeConnectionState.CONNECTED ||
        this.connectionState === RealtimeConnectionState.GENERATING);
  }

  get cameraPreviewContentMode(): VideoContentMode {
    const format: RealtimeVideoFormat | undefined = this.cameraVideoFormat;
    const fillsPreview: boolean = format !== undefined &&
      format.width * 16 === format.height * 9;
    return fillsPreview ? VideoContentMode.FILL : VideoContentMode.FIT;
  }

  referenceList(categoryId: string): RealtimeReferenceListState {
    const categoryState: RealtimeCategoryState | undefined = this.categoryStates.find(
      (candidate: RealtimeCategoryState): boolean => candidate.category.id === categoryId
    );
    return categoryState?.referenceList ?? this.emptyReferenceList;
  }
}
