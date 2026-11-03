//
//  XmaxRealtimeLifecycleManager.ets
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-HarmonyOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import { XmaxError, XmaxErrorCode } from '../../foundation/errors/XmaxError';
import { XmaxLogger } from '../../foundation/logging/XmaxLogger';
import { RealtimeConnectionState, RealtimeReason, RealtimeState, RealtimeStateListener } from '../../service/realtime/RealtimeState';
import { XmaxRealtimeErrorManager } from './XmaxRealtimeErrorManager';

/** An operation kind used for mutual exclusion and cancellation scope. */
export enum RealtimeOperationKind {

  /** Local media creation or replacement. */
  MEDIA,

  /** Local video playback control. */
  PLAYBACK,

  /** Realtime connection setup. */
  CONNECTION,

  /** Generation startup or condition updates. */
  GENERATION,

  /** Camera switching. */
  CAMERA_SWITCH,

  /** Internal transmission configuration. */
  CONFIGURATION
}

/** Resource cleanup scopes ordered from smallest to largest; larger scopes include smaller ones. */
export enum RealtimeTerminationScope {

  /** Connection resources, preserving local media and the RTC engine. */
  CONNECTION,

  /** All realtime resources, including local media and the RTC engine. */
  ALL
}

/**
 * Receives the terminal error when an operation is cancelled.
 *
 * @param error The cancellation error ending the operation.
 */
type CancellationListener = (
  error: XmaxError
) => void;

/**
 * Releases a resource scope and returns the closed session identifier.
 *
 * @param scope The resources to release.
 * @param taskId The current generation task identifier.
 *
 * @returns The Promise for cleanup, containing the closed session identifier or undefined if
 * absent.
 */
type CleanupHandler = (
  scope: RealtimeTerminationScope,
  taskId: string
) => Promise<string | undefined>;

/** Verifies operation ownership across asynchronous boundaries and cancels obsolete result waits. */
export class RealtimeOperationToken {

  // Operation validity and cancellation notifications

  /** Whether this operation still owns execution. */
  private valid: boolean = true;

  /** The error invalidating the operation, if any. */
  private failure: XmaxError | null = null;

  /** The handlers waiting for operation cancellation. */
  private readonly cancellationListeners: Set<CancellationListener> = new Set();

  // Failure cleanup scope

  /** The resource scope released after operation failure. */
  private storedFailureScope: RealtimeTerminationScope | null;

  /** Creates a realtime operation token. */
  constructor(
    failureScope: RealtimeTerminationScope | null
  ) {
    this.storedFailureScope = failureScope;
  }

  /** Whether the operation still owns execution; false after cancellation or completion. */
  get isCurrent(): boolean {
    return this.valid;
  }

  /** The resource scope to clean up after failure, or null for caller-owned rollback. */
  get failureScope(): RealtimeTerminationScope | null {
    return this.storedFailureScope;
  }

  /** The error that terminated the operation, or null if absent. */
  get terminalError(): XmaxError | null {
    return this.failure;
  }

  /**
   * Sets the resource scope to release after operation failure.
   *
   * @param scope The resources to release.
   */
  setFailureScope(
    scope: RealtimeTerminationScope | null
  ): void {
    this.storedFailureScope = scope;
  }

  /** Verifies operation validity, throwing its terminal or cancellation error if invalid. */
  ensureCurrent(): void {
    if (!this.valid) {
      throw this.failure ?? RealtimeOperationToken.cancelledError();
    }
  }

  /**
   * Invalidates the operation and notifies cancellation waiters.
   *
   * @param error The error retained as the cancellation cause, if supplied.
   */
  invalidate(
    error?: XmaxError
  ): void {
    if (error !== undefined && this.failure === null) {
      this.failure = error;
    }

    this.valid = false;
    const reason: XmaxError = this.failure ?? RealtimeOperationToken.cancelledError();
    this.cancellationListeners.forEach((listener: CancellationListener): void => listener(reason));
    this.cancellationListeners.clear();
  }

  /**
   * Waits for confirmation or first-frame readiness with cancellation. Resource mutations must
   * finish before cleanup.
   *
   * @param promise The result Promise whose wait can be cancelled by this operation.
   *
   * @returns The result Promise, rejected if the operation is cancelled.
   */
  wait<T>(
    promise: Promise<T>
  ): Promise<T> {
    return new Promise<T>((resolve: (
      value: T
    ) => void, reject: (
      error: XmaxError
    ) => void): void => {
      const cancel: CancellationListener = (error: XmaxError): void => reject(error);
      if (this.valid) {
        this.cancellationListeners.add(cancel);
      } else {
        reject(this.failure ?? RealtimeOperationToken.cancelledError());
      }

      // Observe the original Promise after cancellation to consume late rejections.
      promise.then(
        (value: T): void => {
          this.cancellationListeners.delete(cancel);
          try {
            this.ensureCurrent();
            resolve(value);
          } catch (error) {
            reject(XmaxError.from(error));
          }
        },
        (error: Object): void => {
          this.cancellationListeners.delete(cancel);
          reject(XmaxError.from(error));
        }
      );
    });
  }

  /**
   * Waits for a duration, rejecting early if the operation is invalidated.
   *
   * @param milliseconds The delay, in milliseconds.
   */
  async delay(
    milliseconds: number
  ): Promise<void> {
    let timer: number = -1;
    const delay = new Promise<void>((resolve: () => void): void => {
      timer = setTimeout(
        resolve,
        milliseconds
      );
    });

    try {
      await this.wait(delay);
    } finally {
      clearTimeout(timer);
    }
  }

  /**
   * Creates an operation cancellation error recognized by your app.
   *
   * @returns An SDK error with code CANCELLED.
   */
  static cancelledError(): XmaxError {
    return new XmaxError(
      XmaxErrorCode.CANCELLED,
      'Realtime operation was cancelled'
    );
  }
}

/** An operation's ownership, completion notification, and associated cleanup. */
class RealtimeOperation {

  // Operation identity and execution ownership

  /** The operation kind used for mutual exclusion. */
  readonly kind: RealtimeOperationKind;

  /** The token guarding operation validity. */
  readonly token: RealtimeOperationToken;

  // Completion and termination association

  /** The Promise tracking completion of the operation body. */
  completion: Promise<void> = Promise.resolve();

  /** The shared resource termination task, if active. */
  termination: RealtimeTermination | null = null;

  /**
   * Creates a realtime operation record.
   *
   * @param kind The realtime operation kind.
   * @param failureScope The failure cleanup scope; null leaves rollback to the caller.
   */
  constructor(
    kind: RealtimeOperationKind,
    failureScope: RealtimeTerminationScope | null
  ) {
    this.kind = kind;
    this.token = new RealtimeOperationToken(failureScope);
  }
}

/** Merges concurrent termination requests and tracks cleanup scope, reason, and progress. */
class RealtimeTermination {

  // Termination reason and resource scope

  /** The reason for terminating this lifecycle. */
  reason: RealtimeReason | undefined;

  /** The requested resource cleanup scope. */
  target: RealtimeTerminationScope;

  /** The failure associated with this operation or result. */
  error: XmaxError | undefined;

  /** The server session identifier. */
  sessionId: string | undefined;

  // Cleanup revision and pending operation

  /** The revision rejecting obsolete asynchronous results. */
  revision: number = 0;

  /** The operations affected by the shared termination task. */
  readonly operations: Set<RealtimeOperation> = new Set();

  /** The shared Promise for this asynchronous operation. */
  promise: Promise<void> = Promise.resolve();

  /** Creates a resource termination task. */
  constructor(
    target: RealtimeTerminationScope,
    error?: XmaxError
  ) {
    this.target = target;
    this.error = error;
  }
}

/** Owns operation admission, lifecycle state, and scoped cleanup on the ArkTS event loop. */
export class XmaxRealtimeLifecycleManager {

  // Error handling and cleanup dependencies

  /** The manager normalizing and deduplicating realtime errors. */
  private readonly errorManager: XmaxRealtimeErrorManager;

  /** The function releasing resources within a termination scope. */
  private readonly cleanup: CleanupHandler;

  /**
   * Queries local media availability for the final state after cleanup.
   *
   * @returns True if local media remains available.
   */
  private readonly hasLocalMedia: () => boolean;

  // Lifecycle state and notifications

  /** The most recently committed lifecycle state. */
  private state: RealtimeState = new RealtimeState(RealtimeConnectionState.IDLE);

  /** The current lifecycle state handler. */
  private stateListener: RealtimeStateListener | null = null;

  /** The internal handler run after state commitment and before the public listener. */
  private readonly onStateChanged: RealtimeStateListener | null;

  // Exclusive operation and termination task

  /** The operation currently holding exclusive execution ownership. */
  private activeOperation: RealtimeOperation | null = null;

  /** The shared resource termination task, if active. */
  private termination: RealtimeTermination | null = null;

  /**
   * Creates a realtime lifecycle manager.
   *
   * @param errorManager The shared error normalizer.
   * @param cleanup The function releasing resources within a termination scope.
   * @param hasLocalMedia The local media availability check used after cleanup.
   * @param onStateChanged The internal state commitment handler, called before the public listener.
   */
  constructor(
    errorManager: XmaxRealtimeErrorManager,
    cleanup: CleanupHandler,
    hasLocalMedia: () => boolean = (): boolean => false,
    onStateChanged: RealtimeStateListener | null = null
  ) {
    this.errorManager = errorManager;
    this.cleanup = cleanup;
    this.hasLocalMedia = hasLocalMedia;
    this.onStateChanged = onStateChanged;
  }

  /** The most recently committed realtime state. */
  get currentState(): RealtimeState {
    return this.state;
  }

  /** Whether all realtime resources are being released. */
  get isClosing(): boolean {
    return this.termination?.target === RealtimeTerminationScope.ALL;
  }

  /**
   * Returns whether an operation of the specified kind is active.
   *
   * @param kind The realtime operation kind.
   *
   * @returns True if that operation kind is active.
   */
  hasOperation(
    kind: RealtimeOperationKind
  ): boolean {
    return this.activeOperation?.kind === kind;
  }

  /**
   * Returns whether any realtime operation is active.
   *
   * @returns True if an operation is active.
   */
  hasActiveOperation(): boolean {
    return this.activeOperation !== null;
  }

  /**
   * Sets the state listener and immediately delivers current state; null removes it.
   *
   * @param listener The state handler, or null to remove it.
   */
  setStateListener(
    listener: RealtimeStateListener | null
  ): void {
    this.stateListener = listener;
    this.notifyStateListener(this.state);
  }

  /**
   * Runs an exclusive realtime operation with cleanup after failure or cancellation.
   *
   * @param kind The realtime operation kind.
   * @param failureScope The failure cleanup scope; null leaves rollback to the caller.
   * @param body The operation body executed while its token remains valid.
   *
   * @returns The operation result Promise; rejects if busy, failed, or cancelled.
   */
  run<T>(
    kind: RealtimeOperationKind,
    failureScope: RealtimeTerminationScope | null,
    body: (
      token: RealtimeOperationToken
    ) => Promise<T>
  ): Promise<T> {
    if (this.termination !== null || this.activeOperation !== null) {
      return Promise.reject(this.errorManager.handle(new XmaxError(
        XmaxErrorCode.INVALID_CONFIGURATION,
        'Another realtime operation is in progress; wait for it to finish'
      )));
    }

    const operation = new RealtimeOperation(
      kind,
      failureScope
    );
    this.activeOperation = operation;
    if (this.state.reason !== undefined) {
      this.setState(new RealtimeState(
        this.state.connectionState,
        this.state.sessionId,
        this.state.taskId
      ));
    }

    const execution: Promise<T> = this.execute(
      body,
      operation.token
    );
    // Wait for the operation body, not run's cleanup-inclusive result, to avoid a cancellation/cleanup dependency cycle.
    operation.completion = execution.then(
      (): void => { },
      (_error: Object): void => { }
    );

    return this.finishRun(
      execution,
      operation
    );
  }

  /**
   * Automatic quality changes neither queue nor report busy errors, and preserve the user's state
   * reason.
   *
   * @param body The operation body executed while its token remains valid.
   *
   * @returns True if configuration ran; false outside generation, while busy, or during cleanup.
   */
  runAdaptiveConfiguration(
    body: (
      token: RealtimeOperationToken
    ) => void
  ): boolean {
    if (this.termination !== null || this.activeOperation !== null ||
      this.state.connectionState !== RealtimeConnectionState.GENERATING) { return false; }

    const operation: RealtimeOperation = new RealtimeOperation(
      RealtimeOperationKind.CONFIGURATION,
      null
    );
    this.activeOperation = operation;

    try {
      operation.token.ensureCurrent();
      body(operation.token);
      operation.token.ensureCurrent();
      return true;
    } finally {
      this.finish(operation);
    }
  }

  /**
   * Runs an asynchronous operation body after checking validity.
   *
   * @param body The operation body executed while its token remains valid.
   * @param token The token verifying operation ownership and cancellation.
   *
   * @returns The operation body's result Promise.
   */
  private async execute<T>(
    body: (
      token: RealtimeOperationToken
    ) => Promise<T>,
    token: RealtimeOperationToken
  ): Promise<T> {
    token.ensureCurrent();
    return await body(token);
  }

  /**
   * Commits state only for the valid operation and rechecks validity after notifying listeners.
   *
   * @param next The lifecycle state to commit.
   * @param token The token verifying operation ownership and cancellation.
   */
  commit(
    next: RealtimeState,
    token: RealtimeOperationToken
  ): void {
    token.ensureCurrent();
    if (this.activeOperation?.token !== token) {
      throw RealtimeOperationToken.cancelledError();
    }

    this.setState(next);
    // Listeners may synchronously stop or close; revalidate ownership before continuing.
    token.ensureCurrent();
  }

  /**
   * Accepts readiness only for the current media without overwriting connecting or closing state.
   *
   * @param isCurrent The function checking whether the notification belongs to the current media.
   */
  localPreviewDidBecomeReady(
    isCurrent: () => boolean
  ): void {
    if (this.termination === null && this.state.connectionState === RealtimeConnectionState.PREPARING && isCurrent()) {
      this.setState(new RealtimeState(RealtimeConnectionState.READY));
    }
  }

  /**
   * Terminates operations within a scope and waits for cleanup.
   *
   * @param target The requested termination scope.
   * @param reason The termination reason or platform alarm reason.
   */
  terminate(
    target: RealtimeTerminationScope,
    reason: RealtimeReason = RealtimeReason.NORMAL
  ): Promise<void> {
    return this.requestTermination(
      target,
      undefined,
      reason
    ).promise;
  }

  /**
   * Terminates a failed resource scope and records the error in final state.
   *
   * @param error The lifecycle failure to retain in the final state reason.
   * @param target The requested termination scope.
   */
  terminateWithError(
    error: XmaxError,
    target: RealtimeTerminationScope
  ): Promise<void> {
    // Late connection errors preserve explicit disconnect reasons; local media failures can expand cleanup scope.
    if (this.termination !== null && target !== RealtimeTerminationScope.ALL) {
      return Promise.resolve();
    }
    return this.requestTermination(
      target,
      error
    ).promise;
  }

  /**
   * Completes operation results and failure cleanup without committing cancelled results.
   *
   * @param execution The operation body's result Promise.
   * @param operation The operation to complete or clean up.
   *
   * @returns The result Promise, rejected after cleanup on failure or cancellation.
   */
  private async finishRun<T>(
    execution: Promise<T>,
    operation: RealtimeOperation
  ): Promise<T> {
    try {
      const value: T = await execution;
      operation.token.ensureCurrent();
      this.finish(operation);

      return value;
    } catch (error) {
      const resolved: XmaxError = XmaxError.from(error);
      let pending: RealtimeTermination | null = operation.termination;
      const cancelled: boolean = !operation.token.isCurrent ||
        resolved.code === XmaxErrorCode.CANCELLED || pending !== null;
      if (cancelled) {
        if (pending === null && operation.token.failureScope !== null) {
          pending = this.requestTermination(operation.token.failureScope);
        }
      } else if (operation.token.failureScope !== null) {
        pending = this.requestTermination(
          operation.token.failureScope,
          resolved
        );
      }

      if (pending !== null) {
        await pending.promise;
      }

      this.finish(operation);
      if (pending === null) {
        // Local creation owns rollback. Release operation ownership before notifying IDLE without a reason so listeners can retry.
        if (operation.kind === RealtimeOperationKind.MEDIA &&
          this.state.connectionState === RealtimeConnectionState.PREPARING) {
          this.setState(new RealtimeState(RealtimeConnectionState.IDLE));
        }
        if (!cancelled) {
          this.errorManager.handle(resolved);
        }
      }

      if (operation.token.terminalError !== null) {
        throw operation.token.terminalError;
      }
      if (pending !== null || cancelled) {
        throw RealtimeOperationToken.cancelledError();
      }
      throw resolved;
    }
  }

  /**
   * Merges termination requests, cancels affected work, and shares one cleanup task.
   *
   * @param target The requested termination scope.
   * @param error The failure associated with cleanup, if termination follows an error.
   * @param reason The termination reason or platform alarm reason.
   *
   * @returns The termination task with the merged cleanup scope.
   */
  private requestTermination(
    target: RealtimeTerminationScope,
    error?: XmaxError,
    reason?: RealtimeReason
  ): RealtimeTermination {
    const beginsDisconnection: boolean = this.termination === null;
    let pending: RealtimeTermination;
    if (this.termination !== null) {
      pending = this.termination;
      if (target > pending.target) {
        pending.target = target;
        pending.revision++;
      }
      if (pending.error === undefined && error !== undefined) {
        pending.error = error;
        pending.revision++;
      }
    } else {
      pending = new RealtimeTermination(
        target,
        error
      );
      this.termination = pending;
      // Register the shared task before cleanup and synchronous state notifications run.
      pending.promise = Promise.resolve().then((): Promise<void> => this.performTermination(pending));
    }

    pending.reason = pending.error !== undefined ? RealtimeReason.failure(pending.error) :
      pending.reason ?? reason ?? RealtimeReason.NORMAL;

    const active: RealtimeOperation | null = this.activeOperation;
    if (active !== null && this.affects(
      pending.target,
      active.kind
    )) {
      if (active.termination !== pending) {
        active.termination = pending;
        pending.operations.add(active);
      }
      active.token.invalidate(pending.error);
    }

    if (beginsDisconnection) {
      this.setState(new RealtimeState(
        RealtimeConnectionState.DISCONNECTING,
        this.state.sessionId
      ));
    }

    return pending;
  }

  /**
   * Waits for affected operations, cleans resources, and commits final state.
   *
   * @param pending The merged termination request and cleanup state.
   */
  private async performTermination(
    pending: RealtimeTermination
  ): Promise<void> {
    while (true) {
      const operations: RealtimeOperation[] = Array.from(pending.operations);
      pending.operations.clear();
      for (const operation of operations) {
        await operation.completion;
      }

      const revision: number = pending.revision;
      const scope: RealtimeTerminationScope = pending.target;
      try {
        const sessionId: string | undefined = await this.cleanup(
          scope,
          this.state.taskId ?? ''
        );
        pending.sessionId = sessionId ?? pending.sessionId;
      } catch (error) {
        XmaxLogger.error(
          `${XmaxLogger.localized("实时资源清理失败 (Realtime Cleanup Failed)\n└─ 原因：", "实时资源清理失败 (Realtime Cleanup Failed)\n└─ Reason: ")}${XmaxError.from(error).message}`,
          'Realtime'
        );
      }

      if (pending.revision !== revision || pending.operations.size > 0) {
        continue;
      }

      const next: RealtimeState = this.resolveFinalState(pending);
      if (pending.error !== undefined) {
        this.errorManager.handle(pending.error);
      }

      if (this.activeOperation?.termination === pending) {
        this.finish(this.activeOperation);
      }

      this.termination = null;
      this.setState(next);
      return;
    }
  }

  /**
   * Resolves final state from cleanup scope and local media availability.
   *
   * @param pending The merged termination request and cleanup state.
   *
   * @returns The realtime state to notify after cleanup.
   */
  private resolveFinalState(
    pending: RealtimeTermination
  ): RealtimeState {
    const connectionState: RealtimeConnectionState = pending.target === RealtimeTerminationScope.ALL ?
      RealtimeConnectionState.IDLE : this.hasLocalMedia() ?
        RealtimeConnectionState.READY : RealtimeConnectionState.IDLE;
    return new RealtimeState(
      connectionState,
      pending.sessionId ?? this.state.sessionId,
      undefined,
      pending.reason
    );
  }

  /**
   * Checks whether a cleanup scope terminates an operation kind.
   *
   * @param scope The resources to release.
   * @param kind The realtime operation kind.
   *
   * @returns True if the operation kind is affected.
   */
  private affects(
    scope: RealtimeTerminationScope,
    kind: RealtimeOperationKind
  ): boolean {
    if (scope === RealtimeTerminationScope.ALL) {
      return true;
    }
    return kind !== RealtimeOperationKind.MEDIA &&
      kind !== RealtimeOperationKind.PLAYBACK;
  }

  /**
   * Releases operation ownership and invalidates its token.
   *
   * @param operation The operation to complete or clean up.
   */
  private finish(
    operation: RealtimeOperation
  ): void {
    if (this.activeOperation === operation) {
      this.activeOperation = null;
    }
    operation.token.invalidate();
  }

  /**
   * Commits changed state and notifies its listener.
   *
   * @param next The lifecycle state to commit.
   */
  private setState(
    next: RealtimeState
  ): void {
    if (this.state.connectionState === next.connectionState && this.state.sessionId === next.sessionId &&
      this.state.taskId === next.taskId && this.state.reason?.kind === next.reason?.kind && this.state.reason?.error === next.reason?.error) {
      return;
    }

    this.state = next;
    this.onStateChanged?.(next);
    this.notifyStateListener(next);
  }

  /**
   * Notifies the state listener while isolating listener exceptions.
   *
   * @param state The lifecycle or playback state to deliver.
   */
  private notifyStateListener(
    state: RealtimeState
  ): void {
    try {
      this.stateListener?.(state);
    } catch (error) {
      XmaxLogger.error(
        `${XmaxLogger.localized("实时状态监听器执行失败 (Realtime State Listener Failed)\n└─ 原因：", "实时状态监听器执行失败 (Realtime State Listener Failed)\n└─ Reason: ")}${XmaxError.from(error).message}`,
        'Realtime'
      );
    }
  }
}
