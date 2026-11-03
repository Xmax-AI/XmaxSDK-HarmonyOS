//
//  XmaxRealtimeConnectionManager.ets
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-HarmonyOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import systemDateTime from '@ohos.systemDateTime';
import { ImageSize } from '../../service/media/ImageSize';
import { TrajectoryRegistry } from '../../rendering/trajectory/TrajectoryRegistry';
import { RealtimeTiming } from '../../service/realtime/RealtimeTiming';
import {
  XmaxError,
  XmaxErrorCode
} from '../../foundation/errors/XmaxError';
import { XmaxLogger } from '../../foundation/logging/XmaxLogger';
import { MediaControlling } from '../../media/MediaControlling';
import { RenderControlling } from '../../rendering/RenderControlling';
import { ApiServicing } from '../../service/network/ApiServicing';
import { RealtimeMediaStream } from '../../service/realtime/RealtimeMediaStream';
import { RealtimeSession } from '../../service/realtime/RealtimeSession';
import { RealtimeSessionConnection } from '../../service/realtime/RealtimeSessionConnection';
import { RealtimeSessionService } from '../../service/realtime/RealtimeSessionService';
import { RealtimeSessionServicing } from '../../service/realtime/RealtimeSessionServicing';
import { RealtimeVideoFormat } from '../../service/realtime/RealtimeVideoFormat';
import { RealtimeVideoTrack, updateRealtimeVideoTrackFormat } from '../../service/realtime/RealtimeVideoTrack';
import { VideoRenderRegistry } from '../../rendering/video/VideoRenderRegistry';
import { StreamControlling } from '../../stream/StreamControlling';
import { StreamId } from '../../stream/StreamId';

/**
 * Checks connection operation validity to reject obsolete asynchronous results.
 *
 * @returns True while the connection operation remains valid.
 */
type ConnectionValidity = () => boolean;

/**
 * Receives a session identifier and heartbeat failure.
 *
 * @param sessionId The server realtime session identifier.
 * @param error The failure reported by the server session heartbeat.
 */
type ConnectionHeartbeatFailureHandler = (
  sessionId: string,
  error: XmaxError
) => Promise<void>;

/** Coordinates server sessions, RTC rooms, local publishing, and remote media resources. */
export class XmaxRealtimeConnectionManager {

  // Connection service and media dependencies

  /** The shared connection and generation startup timing recorder. */
  private readonly timing: RealtimeTiming;

  // Service components

  /** The service creating, maintaining, and closing server sessions. */
  private readonly sessionService: RealtimeSessionServicing;

  // Business components

  /** The controller owning local media and its RTC engine lifecycle. */
  private readonly mediaController: MediaControlling;

  /** The controller coordinating RTC rooms, streams, and signaling. */
  private readonly streamController: StreamControlling;

  // Rendering components

  /** The controller owning video and trajectory rendering bindings. */
  private readonly renderController: RenderControlling;

  // Established connection resources

  /** The remote track registered for the current connection. */
  private activeRemoteTrack: RealtimeVideoTrack | null = null;

  /** The established server session, if connected. */
  private activeSession: RealtimeSession | null = null;

  /** The monotonic connection start time in nanoseconds, absent outside an active connection. */
  private connectionStartedAt?: number;

  /** Whether HTTP heartbeats have started for the current server session. */
  private heartbeatStarted: boolean = false;

  /** The failure handler retained until the session first enters generating. */
  private heartbeatFailureHandler: ConnectionHeartbeatFailureHandler | null = null;

  // Result stream target dimensions

  /** The requested result stream dimensions. */
  private activeTargetSize: ImageSize | undefined;

  /** The requested result stream dimensions for the current session, or undefined if not configured. */
  get currentTargetSize(): ImageSize | undefined {
    return this.activeTargetSize;
  }

  /**
   * Updates expected return dimensions without changing the trajectory's local media baseline.
   *
   * @param size The expected result stream dimensions, in pixels.
   * @param baseline The baseline preserving media aspect ratio and explicit encoding settings.
   */
  updateTargetSize(
    size: ImageSize,
    baseline: RealtimeVideoFormat
  ): void {
    this.activeTargetSize = size;
    if (this.activeRemoteTrack !== null) {
      updateRealtimeVideoTrackFormat(
        this.activeRemoteTrack,
        baseline.resized(
          size.width,
          size.height
        )
      );
      VideoRenderRegistry.notifyVideoFormatChanged(this.activeRemoteTrack);
    }
  }

  /**
   * Creates a realtime connection manager.
   *
   * @param apiService The network service for session creation, heartbeats, and closure.
   * @param mediaController The media controller providing remote trajectory interactions.
   * @param renderController The controller for tracks, remote video, and trajectory bindings.
   * @param streamController The controller for RTC rooms, media streams, and signaling.
   * @param timing The startup timing recorder shared with the realtime manager.
   */
  constructor(
    apiService: ApiServicing,
    mediaController: MediaControlling,
    renderController: RenderControlling,
    streamController: StreamControlling,
    timing: RealtimeTiming = new RealtimeTiming()
  ) {
    this.timing = timing;
    // Service components
    this.sessionService = new RealtimeSessionService(apiService);

    // Business components
    this.mediaController = mediaController;
    this.streamController = streamController;

    // Rendering components
    this.renderController = renderController;
  }

  /** The established server session identifier, or an empty string before connection. */
  get currentSessionId(): string {
    return this.activeSession?.id ?? '';
  }

  /** The remote stream for the current connection, or null before connection. */
  get currentRemoteStream(): RealtimeMediaStream | null {
    return this.activeRemoteTrack === null ? null :
      new RealtimeMediaStream(
        StreamId.REMOTE,
        this.activeRemoteTrack
      );
  }

  /**
   * Updates expected remote format and the interaction baseline after local camera orientation
   * changes.
   *
   * @param format The video format to use.
   */
  updateVideoFormat(
    format: RealtimeVideoFormat
  ): void {
    if (this.activeRemoteTrack !== null) {
      updateRealtimeVideoTrackFormat(
        this.activeRemoteTrack,
        this.activeTargetSize === undefined ? format :
          format.resized(
            this.activeTargetSize.width,
            this.activeTargetSize.height
          )
      );

      VideoRenderRegistry.notifyVideoFormatChanged(this.activeRemoteTrack);

      // Only local camera format changes update this baseline; returned frame dimensions must not.
      TrajectoryRegistry.binding(this.activeRemoteTrack)?.updateResolvedMediaSize(new ImageSize(
        format.width,
        format.height
      ));
    }
  }

  /**
   * Stops heartbeats and detaches remote rendering immediately. Does not leave the RTC room or
   * close the server session.
   */
  prepareForClose(): void {
    this.stopHeartbeat();
    try {
      this.renderController.resetRemoteTrack(this.activeRemoteTrack);
    } catch (error) {
      const reason: string = error instanceof Error ? error.message : String(error);
      XmaxLogger.error(
        `${XmaxLogger.localized("静默远端视频渲染失败 (Failed to Mute Remote Video Rendering)\n└─ 原因：", "静默远端视频渲染失败 (Failed to Mute Remote Video Rendering)\n└─ Reason: ")}${reason}`,
        'Realtime'
      );
    }
  }

  /**
   * Creates a server session, joins the RTC room, and publishes local media.
   *
   * @param model The generation model name sent when creating the server session.
   * @param videoFormat The video format for local input and remote results.
   * @param includeLocalAudio Whether to publish local audio.
   * @param isCurrent The callback checking connection operation validity.
   * @param onHeartbeatFailure The session heartbeat failure handler.
   * @param targetSize The optional result stream target dimensions.
   *
   * @returns The remote stream after connection and rendering registration.
   */
  async connect(
    model: string,
    videoFormat: RealtimeVideoFormat,
    includeLocalAudio: boolean,
    isCurrent: ConnectionValidity,
    onHeartbeatFailure: ConnectionHeartbeatFailureHandler,
    targetSize?: ImageSize
  ): Promise<RealtimeMediaStream> {
    this.timing.beginConnection();
    let session: RealtimeSession | null = null;
    let sessionActivated: boolean = false;

    try {
      this.stopHeartbeat();
      this.connectionStartedAt = systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE, true);
      this.heartbeatFailureHandler = onHeartbeatFailure;

      this.timing.beginSessionCreation();
      session = await this.sessionService.createSession(model);
      this.timing.finishSessionCreation();
      this.ensureCurrent(isCurrent);

      const connection: RealtimeSessionConnection | undefined = session.connection;
      if (connection === undefined) {
        throw new XmaxError(
          XmaxErrorCode.SESSION_ERROR,
          'Session does not contain complete RTC join information'
        );
      }

      await this.streamController.connect(
        connection,
        includeLocalAudio,
        (): void => {
          this.ensureCurrent(isCurrent);
        }
      );
      this.ensureCurrent(isCurrent);

      const resolvedMediaFormat: RealtimeVideoFormat = this.mediaController.currentVideoFormat ?? videoFormat;
      const remoteTrack = new RealtimeVideoTrack(
        connection.botName ?? 'video-remote',
        targetSize === undefined ? resolvedMediaFormat : resolvedMediaFormat.resized(
          targetSize.width,
          targetSize.height
        )
      );
      this.renderController.registerRemoteTrack(
        remoteTrack,
        this.mediaController,
        new ImageSize(
          resolvedMediaFormat.width,
          resolvedMediaFormat.height
        )
      );

      this.activeTargetSize = targetSize;
      this.activeSession = session;
      this.activeRemoteTrack = remoteTrack;
      sessionActivated = true;
      this.ensureCurrent(isCurrent);

      this.timing.finishConnection();
      return new RealtimeMediaStream(
        StreamId.REMOTE,
        remoteTrack
      );
    } catch (error) {
      if (isCurrent()) {
        await this.rollbackConnection();
      }

      if (session !== null && !sessionActivated) {
        try {
          await this.sessionService.closeSession(session.id);
        } catch (closeError) {
          const reason: string = closeError instanceof Error ?
            closeError.message : String(closeError);
          XmaxLogger.error(
            `${XmaxLogger.localized("连接回滚关闭会话失败 (Failed to Close Session during Connection Rollback)\n└─ 原因：", "连接回滚关闭会话失败 (Failed to Close Session during Connection Rollback)\n└─ Reason: ")}${reason}`,
            'Realtime'
          );
        }
      }

      if (!isCurrent()) {
        throw new XmaxError(
          XmaxErrorCode.CANCELLED,
          'Realtime connection was cancelled'
        );
      }

      throw XmaxError.from(error);
    }
  }

  /**
   * Starts HTTP heartbeats once after generating is committed for the current session.
   *
   * @param sessionId The server session entering generation.
   */
  startHeartbeat(
    sessionId: string
  ): void {
    const onFailure: ConnectionHeartbeatFailureHandler | null = this.heartbeatFailureHandler;
    if (this.activeSession?.id !== sessionId || this.heartbeatStarted ||
      this.connectionStartedAt === undefined || onFailure === null) {
      return;
    }

    const elapsed: number = systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE, true) -
      this.connectionStartedAt;
    const graceSeconds: number = Math.max(0, Math.ceil(elapsed / 1000000000));
    this.heartbeatStarted = true;

    this.sessionService.startHeartbeat(
      sessionId,
      async (id: string, error: XmaxError): Promise<void> => {
        if (this.heartbeatStarted && this.activeSession?.id === id) {
          await onFailure(id, error);
        }
      },
      graceSeconds
    );
  }

  /**
   * Stops heartbeats, releases remote resources, leaves the room, and closes the session.
   *
   * @param fallbackSessionId The session identifier used if current session resources are missing.
   *
   * @returns The closed session identifier, or undefined without a session.
   */
  async disconnect(
    fallbackSessionId?: string
  ): Promise<string | undefined> {
    const session: RealtimeSession | null = this.activeSession;
    const remoteTrack: RealtimeVideoTrack | null = this.activeRemoteTrack;

    this.activeTargetSize = undefined;
    this.activeSession = null;
    this.activeRemoteTrack = null;

    this.stopHeartbeat();
    try {
      this.renderController.resetRemoteTrack(remoteTrack);
    } catch (error) {
      const reason: string = error instanceof Error ? error.message : String(error);
      XmaxLogger.error(
        `${XmaxLogger.localized("重置远端视频渲染失败 (Failed to Reset Remote Video Rendering)\n└─ 原因：", "重置远端视频渲染失败 (Failed to Reset Remote Video Rendering)\n└─ Reason: ")}${reason}`,
        'Realtime'
      );
    }

    try {
      await this.streamController.disconnect();
    } catch (error) {
      const reason: string = error instanceof Error ? error.message : String(error);
      XmaxLogger.error(
        `${XmaxLogger.localized("释放 RTC 传输资源失败 (Failed to Release RTC Resources)\n└─ 原因：", "释放 RTC 传输资源失败 (Failed to Release RTC Resources)\n└─ Reason: ")}${reason}`,
        'Realtime'
      );
    }

    const sessionId: string | undefined = session?.id ?? fallbackSessionId;
    if (sessionId !== undefined) {
      try {
        await this.sessionService.closeSession(sessionId);
      } catch (error) {
        const reason: string = error instanceof Error ? error.message : String(error);
        XmaxLogger.error(
          `${XmaxLogger.localized("关闭实时会话失败 (Failed to Close Realtime Session)\n└─ 原因：", "关闭实时会话失败 (Failed to Close Realtime Session)\n└─ Reason: ")}${reason}`,
          'Realtime'
        );
      }
    }

    return sessionId;
  }

  /**
   * Rolls back an incomplete connection and releases created room and remote resources.
   *
   * The Promise fulfills after rollback.
   */
  private async rollbackConnection(): Promise<void> {
    const remoteTrack: RealtimeVideoTrack | null = this.activeRemoteTrack;
    this.activeRemoteTrack = null;

    this.stopHeartbeat();
    this.renderController.resetRemoteTrack(remoteTrack);

    try {
      await this.streamController.disconnect();
    } catch (error) {
      const reason: string = error instanceof Error ? error.message : String(error);
      XmaxLogger.error(
        `${XmaxLogger.localized("连接回滚释放 RTC 传输资源失败 (Failed to Release RTC Resources during Connection Rollback)\n└─ 原因：", "连接回滚释放 RTC 传输资源失败 (Failed to Release RTC Resources during Connection Rollback)\n└─ Reason: ")}${reason}`,
        'Realtime'
      );
    }
  }

  /**
   * Verifies that connection work still belongs to the current lifecycle.
   *
   * @param isCurrent The callback checking connection validity.
   */
  private ensureCurrent(
    isCurrent: ConnectionValidity
  ): void {
    if (!isCurrent()) {
      throw new XmaxError(
        XmaxErrorCode.CANCELLED,
        'Realtime connection was cancelled'
      );
    }
  }

  /** Stops HTTP heartbeats and clears the session's startup timing and failure handler. */
  private stopHeartbeat(): void {
    this.heartbeatStarted = false;
    this.connectionStartedAt = undefined;
    this.heartbeatFailureHandler = null;
    this.sessionService.stopHeartbeat();
  }

}
