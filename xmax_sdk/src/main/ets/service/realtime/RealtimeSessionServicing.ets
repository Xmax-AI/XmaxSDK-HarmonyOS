//
//  RealtimeSessionServicing.ets
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-HarmonyOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import { XmaxError } from '../../foundation/errors/XmaxError';
import { RealtimeSession } from './RealtimeSession';

/**
 * Receives a session identifier and heartbeat error.
 *
 * @param sessionId The server realtime session identifier.
 * @param error The server session heartbeat failure.
 */
export type RealtimeSessionHeartbeatFailureHandler =
  (
    sessionId: string,
    error: XmaxError
  ) => Promise<void>;

/** An interface for realtime session creation, heartbeats, and closure. */
export interface RealtimeSessionServicing {

  /**
   * Creates a session for a realtime generation model.
   *
   * @param model The generation model name sent when creating the server session.
   *
   * @returns The created realtime session.
   */
  createSession(
    model: string
  ): Promise<RealtimeSession>;

  /**
   * Sends an immediate first heartbeat, then repeats every ten seconds after each response.
   *
   * @param sessionId The realtime session identifier.
   * @param onFailure The heartbeat failure callback.
   * @param firstHeartbeatGraceSeconds The nonnegative startup allowance in whole seconds, sent
   * only in the first request; omitted when undefined.
   */
  startHeartbeat(
    sessionId: string,
    onFailure: RealtimeSessionHeartbeatFailureHandler,
    firstHeartbeatGraceSeconds?: number
  ): void;

  /** Stops heartbeats for the current realtime session. */
  stopHeartbeat(): void;

  /**
   * Closes a realtime session.
   *
   * The Promise fulfills after session closure.
   *
   * @param sessionId The realtime session identifier.
   */
  closeSession(
    sessionId: string
  ): Promise<void>;
}
