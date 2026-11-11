//
//  RealtimeCameraZoom.ets
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-HarmonyOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/** The active camera's zoom multiplier and supported range. */
export class RealtimeCameraZoom {

  /** The lowest supported multiplier, which provides the widest available view. */
  readonly minRatio: number;

  /** The highest supported multiplier. */
  readonly maxRatio: number;

  /** The current zoom multiplier. */
  readonly ratio: number;

  /** Creates camera zoom information. */
  constructor(
    minRatio: number,
    maxRatio: number,
    ratio: number
  ) {
    this.minRatio = minRatio;
    this.maxRatio = maxRatio;
    this.ratio = ratio;
  }
}
