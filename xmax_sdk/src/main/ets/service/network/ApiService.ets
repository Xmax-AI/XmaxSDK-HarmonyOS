//
//  ApiService.ets
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-HarmonyOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import { http } from '@kit.NetworkKit';
import { ErrorMessageFormatter } from '../../foundation/errors/ErrorMessageFormatter';
import { RuntimeInfo } from '../../foundation/runtime/RuntimeInfo';
import {
  XmaxError,
  XmaxErrorCode
} from '../../foundation/errors/XmaxError';
import { ApiLogger } from './ApiLogger';
import { ApiServicing } from './ApiServicing';

const API_TIMEOUT_MS: number = 15000;

/** The standard Xmax API response structure. */
interface ApiEnvelope {

  // Server response status and data

  /** Whether the server reports a successful response. */
  success?: boolean;

  /** The server business response code. */
  code?: number;

  /** The readable error or response message. */
  message?: string;

  /** The response business data. */
  data?: Object;
}

/** Sends Xmax API requests and normalizes responses, logs, and errors. */
export class ApiService implements ApiServicing {

  // Service credentials and base URL

  /** The API key used to access Xmax services. */
  private readonly apiKey: string;

  /** The API base URL for this service. */
  private readonly baseURL: string;

  /** Creates an API service. */
  constructor(
    apiKey: string,
    baseURL: string
  ) {
    this.apiKey = apiKey;
    this.baseURL = baseURL;
  }

  /**
   * Sends a GET request.
   *
   * @param path The request path relative to the API base URL.
   *
   * @returns The parsed response data.
   */
  get<T>(
    path: string
  ): Promise<T> {
    return this.request<T>(
      http.RequestMethod.GET,
      path
    );
  }

  /**
   * Sends a POST request.
   *
   * @param path The request path relative to the API base URL.
   * @param body The optional request body.
   *
   * @returns The parsed response data.
   */
  post<T>(
    path: string,
    body?: Object
  ): Promise<T> {
    return this.request<T>(
      http.RequestMethod.POST,
      path,
      body
    );
  }

  /**
   * Sends a PUT request.
   *
   * @param path The request path relative to the API base URL.
   * @param body The optional request body.
   *
   * @returns The parsed response data.
   */
  put<T>(
    path: string,
    body?: Object
  ): Promise<T> {
    return this.request<T>(
      http.RequestMethod.PUT,
      path,
      body
    );
  }

  /**
   * Sends a DELETE request.
   *
   * @param path The request path relative to the API base URL.
   *
   * @returns The parsed response data.
   */
  delete<T>(
    path: string
  ): Promise<T> {
    return this.request<T>(
      http.RequestMethod.DELETE,
      path
    );
  }

  /**
   * Executes an HTTP request with normalized network errors, response parsing, and logging.
   *
   * @param method The HTTP method.
   * @param path The request path relative to the API base URL.
   * @param body The optional request body.
   *
   * @returns The parsed response data.
   */
  private async request<T>(
    method: http.RequestMethod,
    path: string,
    body?: Object
  ): Promise<T> {
    this.validateApiKey();

    const request: http.HttpRequest = http.createHttp();
    const url: string = `${this.baseURL}${path}`;
    const startedAt: number = Date.now();

    try {
      let result: http.HttpResponse;

      try {
        const extraData: string | undefined = body === undefined ?
          undefined : JSON.stringify(body);

        result = await request.request(
          url,
          {
            method,
            header: this.headers(),
            extraData,
            expectDataType: http.HttpDataType.STRING,
            usingCache: false,
            connectTimeout: API_TIMEOUT_MS,
            readTimeout: API_TIMEOUT_MS
          }
        );
      } catch (error) {
        ApiLogger.logFailure(
          method,
          path,
          error,
          Date.now() - startedAt
        );

        if (error instanceof XmaxError) {
          throw error;
        }

        throw new XmaxError(
          XmaxErrorCode.NETWORK_ERROR,
          `HTTP request failed: ${this.errorMessage(error)}`
        );
      }

      const responseBody: string = result.result as string;
      const durationMs: number = Date.now() - startedAt;

      try {
        const value: T = this.parseResponse<T>(
          result.responseCode,
          responseBody
        );
        ApiLogger.logResponse(
          method,
          path,
          result.responseCode,
          responseBody,
          durationMs,
          true
        );

        return value;
      } catch (error) {
        ApiLogger.logResponse(
          method,
          path,
          result.responseCode,
          responseBody,
          durationMs,
          false
        );

        if (error instanceof XmaxError) {
          throw error;
        }

        throw new XmaxError(
          XmaxErrorCode.API_ERROR,
          this.errorMessage(error),
          undefined,
          result.responseCode
        );
      }
    } finally {
      request.destroy();
    }
  }

  /** Validates the API key before a request. */
  private validateApiKey(): void {
    if (this.apiKey.trim().length === 0) {
      throw new XmaxError(
        XmaxErrorCode.INVALID_API_KEY,
        'API key cannot be empty'
      );
    }
  }

  /**
   * Creates common API request headers.
   *
   * @returns The API request headers.
   */
  private headers(): Record<string, string> {
    const runtime: RuntimeInfo = RuntimeInfo.current;
    return {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'X-Api-Key': this.apiKey,
      'X-Platform': runtime.platform,
      'X-OS-Version': runtime.osVersion,
      'X-SDK-Version': runtime.sdkVersion,
      'X-Device-Model': runtime.deviceModel
    };
  }

  /**
   * Parses and validates the standard API response.
   *
   * @param statusCode The HTTP status code.
   * @param text The raw response text.
   *
   * @returns The response business data.
   */
  private parseResponse<T>(
    statusCode: number,
    text: string
  ): T {
    let envelope: ApiEnvelope;

    try {
      envelope = JSON.parse(text) as ApiEnvelope;
    } catch (_error) {
      throw new XmaxError(
        XmaxErrorCode.API_ERROR,
        'Server returned invalid JSON',
        undefined,
        statusCode
      );
    }

    if (statusCode >= 200 && statusCode < 300 && envelope.success === true &&
      envelope.data !== undefined) {
      return envelope.data as T;
    }

    throw new XmaxError(
      XmaxErrorCode.API_ERROR,
      envelope.message?.trim() || 'Xmax API request failed',
      envelope.code,
      statusCode
    );
  }

  /**
   * Formats an unknown exception as a readable error.
   *
   * @param error The error to format.
   *
   * @returns The readable error message.
   */
  private errorMessage(
    error: Object
  ): string {
    return ErrorMessageFormatter.format(error);
  }
}
