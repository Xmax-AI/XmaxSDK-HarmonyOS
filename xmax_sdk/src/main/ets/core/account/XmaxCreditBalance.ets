//
//  XmaxCreditBalance.ets
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-HarmonyOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/** The server-reported credit balance for the account owning the client's API key. */
export class XmaxCreditBalance {

  /** Remaining credits as a finite, nonnegative value, including fractional credits. */
  readonly currentBalance: number;

  /** Creates a balance from the remaining credits. */
  constructor(
    currentBalance: number
  ) {
    this.currentBalance = currentBalance;
  }
}
