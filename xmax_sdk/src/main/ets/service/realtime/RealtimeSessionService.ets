//
//  RealtimeSessionService.ets
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-HarmonyOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import {
  XmaxError,
  XmaxErrorCode
} from '../../foundation/errors/XmaxError';
import { ApiServicing } from '../network/ApiServicing';
import { RealtimeSession } from './RealtimeSession';
import { RealtimeSessionConnection } from './RealtimeSessionConnection';
import {
  RealtimeSessionHeartbeatFailureHandler,
  RealtimeSessionServicing
} from './RealtimeSessionServicing';

const SESSION_HEARTBEAT_INTERVAL_MS: number = 10000;

/** Manages realtime session creation, heartbeats, and closure. */
export class RealtimeSessionService implements RealtimeSessionServicing {

  // Server session access

  /** The service sending authenticated Xmax API requests. */
  private readonly apiService: ApiServicing;

  // Session heartbeat and revision isolation

  /** The timer scheduling server session heartbeats. */
  private heartbeatTimer: number = -1;

  /** The revision rejecting heartbeat results from earlier cycles. */
  private heartbeatVersion: number = 0;

  /** Creates a realtime session service. */
  constructor(
    apiService: ApiServicing
  ) {
    this.apiService = apiService;
  }

  /**
   * Creates a session for a realtime generation model.
   *
   * @param model The generation model name sent when creating the server session.
   *
   * @returns The created realtime session.
   */
  async createSession(
    model: string
  ): Promise<RealtimeSession> {
    const body: Record<string, string> = { 'model': model };
    const value = await this.apiService.post<Object>(
      '/session',
      body
    );

    return this.toSession(
      value,
      true
    );
  }

  /**
   * Sends an immediate first heartbeat and schedules subsequent requests after each response.
   *
   * @param sessionId The realtime generation session identifier.
   * @param onFailure The heartbeat failure handler.
   * @param firstHeartbeatGraceSeconds The startup allowance sent only in the first request.
   */
  startHeartbeat(
    sessionId: string,
    onFailure: RealtimeSessionHeartbeatFailureHandler,
    firstHeartbeatGraceSeconds?: number
  ): void {
    this.stopHeartbeat();

    const heartbeatVersion: number = this.heartbeatVersion;
    void this.sendHeartbeat(
      sessionId,
      onFailure,
      heartbeatVersion,
      firstHeartbeatGraceSeconds
    );
  }

  /** Stops heartbeats and invalidates pending heartbeat responses. */
  stopHeartbeat(): void {
    this.heartbeatVersion++;

    if (this.heartbeatTimer >= 0) {
      clearTimeout(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
  }

  /**
   * Requests closure of a realtime session.
   *
   * The Promise fulfills after session closure.
   *
   * @param sessionId The realtime generation session identifier.
   */
  async closeSession(
    sessionId: string
  ): Promise<void> {
    try {
      await this.apiService.delete<Object>(`/session/${sessionId}`);
    } catch (error) {
      throw XmaxError.from(error);
    }
  }

  /**
   * Schedules the next heartbeat, ending the cycle on failure.
   *
   * @param sessionId The realtime generation session identifier.
   * @param onFailure The heartbeat failure handler.
   * @param heartbeatVersion The heartbeat cycle revision.
   */
  private scheduleHeartbeat(
    sessionId: string,
    onFailure: RealtimeSessionHeartbeatFailureHandler,
    heartbeatVersion: number
  ): void {
    this.heartbeatTimer = setTimeout(
      (): void => {
        if (heartbeatVersion !== this.heartbeatVersion) {
          return;
        }

        this.heartbeatTimer = -1;
        void this.sendHeartbeat(
          sessionId,
          onFailure,
          heartbeatVersion
        );
      },
      SESSION_HEARTBEAT_INTERVAL_MS
    );
  }

  /**
   * Sends one current heartbeat, scheduling the next request only while its cycle remains active.
   *
   * @param sessionId The realtime generation session identifier.
   * @param onFailure The heartbeat failure handler.
   * @param heartbeatVersion The heartbeat cycle revision.
   * @param firstHeartbeatGraceSeconds The startup allowance sent only in the first request.
   */
  private async sendHeartbeat(
    sessionId: string,
    onFailure: RealtimeSessionHeartbeatFailureHandler,
    heartbeatVersion: number,
    firstHeartbeatGraceSeconds?: number
  ): Promise<void> {
    if (heartbeatVersion !== this.heartbeatVersion) {
      return;
    }

    try {
      const session: RealtimeSession = await this.heartbeatSession(
        sessionId,
        firstHeartbeatGraceSeconds
      );
      if (heartbeatVersion !== this.heartbeatVersion) {
        return;
      }

      this.ensureSessionActive(session);
    } catch (error) {
      if (heartbeatVersion !== this.heartbeatVersion) {
        return;
      }

      this.stopHeartbeat();
      await onFailure(
        sessionId,
        XmaxError.from(error)
      );
      return;
    }

    this.scheduleHeartbeat(
      sessionId,
      onFailure,
      heartbeatVersion
    );
  }

  /**
   * Sends a heartbeat and parses current session information.
   *
   * @param sessionId The realtime generation session identifier.
   * @param firstHeartbeatGraceSeconds The startup allowance, omitted after the first request.
   *
   * @returns The session returned by the heartbeat.
   */
  private async heartbeatSession(
    sessionId: string,
    firstHeartbeatGraceSeconds?: number
  ): Promise<RealtimeSession> {
    const body: Record<string, number> | undefined = firstHeartbeatGraceSeconds === undefined ?
      undefined : { 'firstHeartbeatGraceSeconds': firstHeartbeatGraceSeconds };
    const value = await this.apiService.put<Object>(
      `/session/${sessionId}/heartbeat`,
      body
    );

    return this.toSession(
      value,
      false
    );
  }

  /**
   * Verifies that the heartbeat session remains active.
   *
   * @param session The session returned by the heartbeat.
   */
  private ensureSessionActive(
    session: RealtimeSession
  ): void {
    if (session.status !== undefined && session.status !== 'ACTIVE') {
      throw new XmaxError(
        XmaxErrorCode.SESSION_ERROR,
        session.closeReason ?? `Session is no longer active: ${session.status}`
      );
    }
  }

  /**
   * Converts an API response into a realtime session.
   *
   * @param value The API response data.
   * @param requiresConnection Whether complete RTC connection parameters are required.
   *
   * @returns The parsed realtime session.
   */
  private toSession(
    value: Object,
    requiresConnection: boolean
  ): RealtimeSession {
    const record = JSON.parse(JSON.stringify(value)) as Record<string, Object>;
    const sessionId: string | undefined = this.readString(
      record,
      'sessionUid'
    );

    if (sessionId === undefined) {
      throw new XmaxError(
        XmaxErrorCode.SESSION_ERROR,
        'Invalid session response'
      );
    }

    const userId: string | undefined = this.readString(
      record,
      'userUid'
    );
    const connection: RealtimeSessionConnection | undefined = this.readConnection(
      record['modelExtra'],
      userId
    );

    if (requiresConnection && connection === undefined) {
      throw new XmaxError(
        XmaxErrorCode.SESSION_ERROR,
        'Session does not contain complete RTC join information'
      );
    }

    const status: string | undefined = this.readString(
      record,
      'status'
    );
    const closeReason: string | undefined = this.readString(
      record,
      'closeReason'
    );

    return new RealtimeSession(
      sessionId,
      userId,
      status,
      connection,
      closeReason
    );
  }

  /**
   * Parses RTC connection information from session extras.
   *
   * @param raw The raw session extras.
   * @param fallbackUserId The fallback user identifier if absent.
   *
   * @returns The complete connection, or undefined if incomplete.
   */
  private readConnection(
    raw: Object | undefined,
    fallbackUserId?: string
  ): RealtimeSessionConnection | undefined {
    if (raw === undefined || raw === null) {
      return undefined;
    }

    let record: Record<string, Object>;
    try {
      if (typeof raw === 'string') {
        record = JSON.parse(raw) as Record<string, Object>;
      } else {
        record = JSON.parse(JSON.stringify(raw)) as Record<string, Object>;
      }
    } catch (_error) {
      return undefined;
    }

    const roomId: string = this.readString(
      record,
      'room_id'
    ) ?? '';
    const token: string = this.readString(
      record,
      'room_token'
    ) ?? '';
    const userId: string = this.readString(
      record,
      'user_id'
    ) ?? fallbackUserId ?? '';
    if (roomId.length === 0 || token.length === 0 || userId.length === 0) {
      return undefined;
    }

    return new RealtimeSessionConnection(
      roomId,
      userId,
      token,
      this.readString(
        record,
        'bot_name'
      )
    );
  }

  /**
   * Reads a nonempty string field from a record.
   *
   * @param record The data record.
   * @param key The field name.
   *
   * @returns The normalized string, or undefined for an invalid field.
   */
  private readString(
    record: Record<string, Object>,
    key: string
  ): string | undefined {
    const raw: Object | undefined = record[key];
    return typeof raw === 'string' ? this.nonEmpty(raw) : undefined;
  }

  /**
   * Trims a string and filters blank values.
   *
   * @param value The string to process.
   *
   * @returns The nonempty string, or undefined for invalid input.
   */
  private nonEmpty(
    value: string | undefined
  ): string | undefined {
    const normalized: string | undefined = value?.trim();
    return normalized !== undefined && normalized.length > 0 ? normalized : undefined;
  }
}
