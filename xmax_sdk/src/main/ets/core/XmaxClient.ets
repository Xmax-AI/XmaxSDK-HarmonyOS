//
//  XmaxClient.ets
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-HarmonyOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import { XmaxLogger, XmaxLogLanguage } from '../foundation/logging/XmaxLogger';
import { common } from '@kit.AbilityKit';
import {
  XmaxError,
  XmaxErrorCode
} from '../foundation/errors/XmaxError';
import { MediaService } from '../service/media/MediaService';
import { MediaServicing } from '../service/media/MediaServicing';
import { ApiService } from '../service/network/ApiService';
import { ApiServicing } from '../service/network/ApiServicing';
import { XmaxConfiguration } from './XmaxConfiguration';
import { apiBaseURL, XmaxEnvironment } from './XmaxEnvironment';
import { XmaxCreditBalance } from './account/XmaxCreditBalance';
import { RealtimeConfiguration } from './realtime/RealtimeConfiguration';
import { RealtimeModel, RealtimeModels } from '../service/realtime/RealtimeModel';
import { XmaxRealtimeManaging } from './realtime/XmaxRealtimeManaging';
import { XmaxRealtimeManager } from './realtime/XmaxRealtimeManager';
import { XmaxStorageManaging } from './storage/XmaxStorageManaging';
import { XmaxStorageManager } from './storage/XmaxStorageManager';

/** The server payload decoded separately from the validated public account model. */
interface CreditBalanceResponse {

  /** Remaining credits, validated before returning them to your app. */
  currentBalance?: number;
}

/** A client for account queries, realtime generation, storage, and media services. */
export class XmaxClient {

  /** The client configuration. */
  readonly configuration: XmaxConfiguration;

  /** The platform context for SDK resources. */
  private readonly context?: common.UIAbilityContext;

  /** The service sending authenticated Xmax API requests. */
  private readonly apiService: ApiServicing;

  /**
   * Creates a client.
   *
   * @param configuration The client configuration.
   * @param context The optional platform context, required when creating managers that use platform
   * services.
   */
  constructor(
    configuration: XmaxConfiguration,
    context?: common.UIAbilityContext
  ) {
    this.configuration = configuration;
    XmaxLogger.configure(
      configuration.loggerOptions,
      configuration.environment === XmaxEnvironment.CHINA ? XmaxLogLanguage.CHINESE : XmaxLogLanguage.ENGLISH
    );

    this.context = context;
    this.apiService = new ApiService(
      configuration.apiKey,
      apiBaseURL(configuration.environment)
    );
  }

  /**
   * Fetches remaining credits for the account owning this client's API key.
   *
   * Each call reads the current server balance using the configured general API environment.
   * Fractional credits are preserved. This query does not require a platform context or create a
   * realtime session. The promise rejects with an XmaxError if credentials, transport, or the
   * response are invalid.
   *
   * @returns The account's remaining credits.
   */
  async getCreditBalance(): Promise<XmaxCreditBalance> {
    this.configuration.validate();

    const response: CreditBalanceResponse | null =
      await this.apiService.get<CreditBalanceResponse | null>('/balance');
    const value: number | undefined = response?.currentBalance;
    if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) {
      throw new XmaxError(
        XmaxErrorCode.API_ERROR,
        'Credit balance must be a finite, nonnegative number'
      );
    }

    return new XmaxCreditBalance(value);
  }

  /**
   * Creates a realtime generation manager.
   *
   * @param options The model and realtime configuration.
   *
   * @returns The manager for local streams, connections, and generation.
   */
  createRealtimeManager(
    options: RealtimeConfiguration
  ): XmaxRealtimeManaging {
    if (this.context === undefined) {
      throw new XmaxError(
        XmaxErrorCode.INVALID_CONFIGURATION,
        'UIAbilityContext is required to create a realtime manager on HarmonyOS'
      );
    }

    const baseURL: string | undefined = options.model.baseURL;
    const apiService: ApiServicing = baseURL === undefined
      ? this.apiService
      : new ApiService(
        this.configuration.apiKey,
        baseURL
      );

    return new XmaxRealtimeManager(
      this.context,
      options,
      apiService
    );
  }

  /**
   * Creates a storage manager.
   *
   * @returns The manager for media uploads and downloads.
   */
  createStorageManager(): XmaxStorageManaging {
    this.configuration.validate();

    if (this.context === undefined) {
      throw new XmaxError(
        XmaxErrorCode.INVALID_CONFIGURATION,
        'UIAbilityContext is required to create a storage manager on HarmonyOS'
      );
    }

    return new XmaxStorageManager(
      this.context.getApplicationContext(),
      this.apiService
    );
  }

  /**
   * Creates a media sizing service.
   *
   * @param model The model defining media constraints; defaults to x2.0.
   *
   * @returns The service for resolving model input dimensions.
   */
  createMediaService(
    model: RealtimeModel = RealtimeModel.X2_0
  ): MediaServicing {
    return new MediaService(RealtimeModels.realtime(model));
  }
}
