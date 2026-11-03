import { intl } from '@kit.LocalizationKit';
import { XmaxClient, XmaxConfiguration, XmaxEnvironment } from '@xmax/sdk';

export class FeedCreditBalanceState {
  readonly balance?: number;
  readonly isLoading: boolean;
  readonly refreshFailed: boolean;

  constructor(
    balance?: number,
    isLoading: boolean = false,
    refreshFailed: boolean = false
  ) {
    this.balance = balance;
    this.isLoading = isLoading;
    this.refreshFailed = refreshFailed;
  }
}

type CreditBalanceQuery = () => Promise<number>;
type CreditBalanceQueryFactory = (apiKey: string, environment: XmaxEnvironment) => CreditBalanceQuery;

/** Polls only for the visible, active homepage and rejects results from replaced credentials. */
export class FeedCreditBalancePoller {
  private readonly makeQuery: CreditBalanceQueryFactory;
  private apiKey: string = '';
  private environment?: XmaxEnvironment;
  private timer: number = -1;
  private revision: number = 0;
  private isRunning: boolean = false;
  private currentState: FeedCreditBalanceState = new FeedCreditBalanceState();
  onChange: ((state: FeedCreditBalanceState) => void) | null = null;

  constructor(
    makeQuery: CreditBalanceQueryFactory = (apiKey: string, environment: XmaxEnvironment): CreditBalanceQuery => {
      const client = new XmaxClient(new XmaxConfiguration(apiKey, environment));
      return async (): Promise<number> => (await client.getCreditBalance()).currentBalance;
    }
  ) {
    this.makeQuery = makeQuery;
  }

  get state(): FeedCreditBalanceState {
    return this.currentState;
  }

  update(
    apiKey: string,
    environment: XmaxEnvironment,
    isActive: boolean
  ): void {
    const key: string = apiKey.trim();
    if (key !== this.apiKey || environment !== this.environment) {
      this.pause();
      this.apiKey = key;
      this.environment = environment;
      this.publish(new FeedCreditBalanceState());
    }

    if (!isActive || key.length === 0) {
      this.pause();
      return;
    }
    if (this.isRunning) {
      return;
    }

    this.isRunning = true;
    const revision: number = ++this.revision;
    // Coalesce API-key edits before creating the authenticated query.
    this.timer = setTimeout((): void => {
      if (revision !== this.revision) {
        return;
      }

      this.timer = -1;
      void this.refresh(this.makeQuery(key, environment), revision);
    }, 250);
  }

  pause(): void {
    this.revision++;
    this.isRunning = false;
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }

    if (this.state.isLoading) {
      this.publish(new FeedCreditBalanceState(this.state.balance, false, this.state.refreshFailed));
    }
  }

  private async refresh(
    query: CreditBalanceQuery,
    revision: number
  ): Promise<void> {
    if (revision !== this.revision) {
      return;
    }

    this.publish(new FeedCreditBalanceState(this.state.balance, true));
    if (revision !== this.revision) {
      return;
    }

    try {
      const balance: number = await query();
      if (revision !== this.revision) {
        return;
      }
      this.publish(new FeedCreditBalanceState(balance));
    } catch (_error) {
      if (revision !== this.revision) {
        return;
      }
      this.publish(new FeedCreditBalanceState(this.state.balance, false, true));
    }

    if (revision !== this.revision) {
      return;
    }
    this.timer = setTimeout((): void => {
      if (revision !== this.revision) {
        return;
      }

      this.timer = -1;
      void this.refresh(query, revision);
    }, 5000);
  }

  private publish(
    state: FeedCreditBalanceState
  ): void {
    this.currentState = state;
    this.onChange?.(state);
  }
}

const CREDIT_BALANCE_FORMAT: intl.NumberFormat = new intl.NumberFormat('en-US', {
  maximumFractionDigits: 6
});

export function formatFeedCreditBalance(
  balance: number | undefined
): string {
  return balance === undefined ? '—' : CREDIT_BALANCE_FORMAT.format(balance);
}
