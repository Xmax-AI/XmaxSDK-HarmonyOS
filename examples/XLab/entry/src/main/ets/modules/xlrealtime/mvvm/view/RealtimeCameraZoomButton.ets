import { XLabLocalization } from '../../../../localization/XLabLocalization';
import { RealtimeViewState } from '../model/RealtimeViewState';

@Component
export struct RealtimeCameraZoomButton {
  @StorageLink(XLabLocalization.REVISION_KEY) private languageRevision: number = 0;
  @ObjectLink state: RealtimeViewState;
  @Prop isCameraSwitching: boolean = false;
  onSelect: (ratio: number) => void = (_ratio: number): void => {};
  @State private isMenuVisible: boolean = false;
  @State private draftRatio: number = 1;

  private text(key: string): string {
    return XLabLocalization.text(key, this.languageRevision);
  }

  private ratioLabel(ratio: number): string {
    return `${Number(ratio.toFixed(2))}×`;
  }

  private applyZoom(ratio: number): void {
    if (this.state.canAdjustCameraZoom && !this.isCameraSwitching) {
      this.onSelect(ratio);
    }
    this.draftRatio = this.state.cameraZoom?.ratio ?? 1;
  }

  @Builder
  private zoomMenu() {
    Column({ space: 6 }) {
      if (this.state.cameraZoom !== undefined) {
        Row() {
          Text(this.text('camera_zoom'))
            .fontSize(13)
            .fontColor($r('app.color.realtime_volume_label'))
          Blank()
          Text(this.ratioLabel(this.draftRatio))
            .fontSize(12)
            .fontColor($r('app.color.realtime_volume_secondary_label'))
        }
        .width('100%')

        Slider({
          value: this.draftRatio,
          min: this.state.cameraZoom.minRatio,
          max: this.state.cameraZoom.maxRatio,
          step: 0.01
        })
          .width('100%')
          .height(32)
          .blockColor('#FFFFFF')
          .selectedColor($r('app.color.realtime_volume_tint'))
          .trackColor($r('app.color.realtime_volume_track'))
          .accessibilityText(this.text('camera_zoom'))
          .onChange((value: number, mode: SliderChangeMode): void => {
            this.draftRatio = value;
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              const min: number = this.state.cameraZoom?.minRatio ?? value;
              const max: number = this.state.cameraZoom?.maxRatio ?? value;
              this.applyZoom(Math.max(min, Math.min(max, Math.round(value * 100) / 100)));
            }
          })

        Row() {
          Button(`${this.text('camera_zoom_widest')} · ${this.ratioLabel(this.state.cameraZoom.minRatio)}`)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .height(30)
            .padding({ left: 12, right: 12 })
            .backgroundColor('#30323D')
            .onClick((): void => {
              if (this.state.cameraZoom !== undefined) {
                this.applyZoom(this.state.cameraZoom.minRatio);
              }
            })
          Blank()
          Text(this.ratioLabel(this.state.cameraZoom.maxRatio))
            .fontSize(11)
            .fontColor($r('app.color.realtime_volume_secondary_label'))
        }
        .width('100%')
      }
    }
    .width(228)
    .padding(14)
    .backgroundColor($r('app.color.realtime_volume_background'))
    .borderRadius(14)
    .enabled(this.state.canAdjustCameraZoom && !this.isCameraSwitching)
  }

  build() {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 4 }) {
        Text(this.ratioLabel(this.state.cameraZoom?.ratio ?? 1))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
        Text(this.text('camera_zoom'))
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
      }
      .height(36)
      .justifyContent(FlexAlign.Center)
    }
    .width(58)
    .height(58)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .enabled(this.state.canAdjustCameraZoom && !this.isCameraSwitching)
    .opacity(this.state.canAdjustCameraZoom && !this.isCameraSwitching ? 1 : 0.4)
    .accessibilityText(this.text('camera_zoom'))
    .onClick((): void => {
      this.draftRatio = this.state.cameraZoom?.ratio ?? 1;
      this.isMenuVisible = !this.isMenuVisible;
    })
    .bindPopup(this.isMenuVisible, {
      builder: this.zoomMenu,
      placement: Placement.Left,
      popupColor: $r('app.color.realtime_volume_background'),
      backgroundBlurStyle: BlurStyle.NONE,
      radius: 14,
      onStateChange: (event): void => {
        this.isMenuVisible = event.isVisible;
      }
    })
  }
}
