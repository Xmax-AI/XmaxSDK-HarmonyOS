const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadEts } = require('./ets-loader.cjs');

const app = path.resolve(__dirname, '../examples/XLab/entry/src/main/ets');
const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function fixture() {
  const timers = new Map(), clients = [], requests = [], states = [];
  let now = 0, nextTimer = 0, fetch = async () => 12.5;
  const load = loadEts({
    '@kit.LocalizationKit': { intl: { NumberFormat: Intl.NumberFormat } },
    '@xmax/sdk': {
      XmaxEnvironment: { CHINA: 'china', GLOBAL: 'global' },
      XmaxConfiguration: class {
        constructor(apiKey, environment) { this.apiKey = apiKey; this.environment = environment; }
      },
      XmaxClient: class {
        constructor(configuration) { this.configuration = configuration; clients.push({ ...configuration }); }
        async getCreditBalance() {
          requests.push({ ...this.configuration, time: now });
          return { currentBalance: await fetch(this.configuration) };
        }
      }
    }
  }, {
    setTimeout(callback, ms) {
      timers.set(++nextTimer, { callback, ms, at: now + ms });
      return nextTimer;
    },
    clearTimeout(id) { timers.delete(id); }
  });
  const { FeedCreditBalancePoller, formatFeedCreditBalance } = load(`${app}/modules/xlfeed/FeedCreditBalance.ets`);
  const poller = new FeedCreditBalancePoller();
  poller.onChange = state => states.push({ ...state });
  return {
    poller, timers, clients, requests, states, format: formatFeedCreditBalance,
    fetch(handler) { fetch = handler; },
    async advance(milliseconds) {
      const target = now + milliseconds;
      while (true) {
        const next = [...timers].sort((a, b) => a[1].at - b[1].at)[0];
        if (!next || next[1].at > target) break;
        now = next[1].at;
        timers.delete(next[0]);
        next[1].callback();
        await settle();
      }
      now = target;
      await settle();
    }
  };
}

test('empty keys and inactive homepages do not create a client or query credits', async () => {
  const f = fixture();
  f.poller.update(' \n ', 'china', true);
  f.poller.update('key', 'china', false);
  await f.advance(10000);
  assert.equal(f.clients.length, 0);
  assert.equal(f.requests.length, 0);
  assert.equal(f.timers.size, 0);
  assert.equal(f.poller.state.balance, undefined);
});

test('API-key editing is debounced and queries use the trimmed key and selected environment', async () => {
  const f = fixture();
  f.poller.update('first', 'china', true);
  await f.advance(150);
  f.poller.update('  final-key\n ', 'global', true);
  await f.advance(249);
  assert.equal(f.requests.length, 0);
  await f.advance(1);
  assert.deepEqual(f.clients, [{ apiKey: 'final-key', environment: 'global' }]);
  assert.deepEqual(f.requests, [{ apiKey: 'final-key', environment: 'global', time: 400 }]);
  assert.equal(f.poller.state.balance, 12.5);
  f.poller.pause();
});

test('active polling refreshes every five seconds without replacing the client or overlapping slow requests', async () => {
  const f = fixture(), gate = deferred();
  f.fetch(() => gate.promise);
  f.poller.update('key', 'china', true);
  await f.advance(250);
  assert.equal(f.poller.state.isLoading, true);
  await f.advance(15000);
  assert.equal(f.requests.length, 1);
  assert.equal(f.timers.size, 0);
  // Repeated visibility/language notifications for the same account must not start another loop.
  f.poller.update(' key ', 'china', true);
  assert.equal(f.requests.length, 1);
  gate.resolve(0.25);
  await settle();
  await f.advance(4999);
  assert.equal(f.requests.length, 1);
  await f.advance(1);
  assert.equal(f.requests.length, 2);
  assert.equal(f.clients.length, 1);
  assert.equal(f.poller.state.balance, 0.25);
  f.poller.pause();
});

test('refresh failure retains the previous balance, retries, and preserves zero as a real balance', async () => {
  const f = fixture();
  let calls = 0;
  f.fetch(async () => {
    calls++;
    if (calls === 2) throw new Error('offline');
    return calls === 1 ? 1250.75 : 0;
  });
  f.poller.update('key', 'china', true);
  await f.advance(250);
  assert.equal(f.poller.state.balance, 1250.75);
  await f.advance(5000);
  assert.equal(f.poller.state.balance, 1250.75);
  assert.equal(f.poller.state.refreshFailed, true);
  await f.advance(5000);
  assert.equal(f.poller.state.balance, 0);
  assert.equal(f.poller.state.refreshFailed, false);
  f.poller.pause();
});

test('initial failure has no numeric balance and does not masquerade as zero', async () => {
  const f = fixture();
  f.fetch(async () => { throw new Error('invalid API key'); });
  f.poller.update('key', 'china', true);
  await f.advance(250);
  assert.equal(f.poller.state.balance, undefined);
  assert.equal(f.poller.state.isLoading, false);
  assert.equal(f.poller.state.refreshFailed, true);
  f.poller.pause();
});

test('account changes clear the old balance and reject late successes and failures', async () => {
  for (const failure of [false, true]) {
    const f = fixture(), old = deferred();
    f.fetch(({ apiKey }) => apiKey === 'old' ? old.promise : Promise.resolve(42.5));
    f.poller.update('old', 'china', true);
    await f.advance(250);
    f.poller.update('new', 'global', true);
    assert.equal(f.poller.state.balance, undefined);
    await f.advance(250);
    if (failure) old.reject(new Error('old failure')); else old.resolve(999);
    await settle();
    assert.equal(f.poller.state.balance, 42.5);
    assert.equal(f.poller.state.refreshFailed, false);
    assert.equal(f.timers.size, 1);
    f.poller.pause();
  }
});

test('changing only the environment invalidates the previous account cache', async () => {
  const f = fixture();
  f.poller.update('key', 'china', true);
  await f.advance(250);
  f.poller.update('key', 'global', false);
  assert.equal(f.poller.state.balance, undefined);
  assert.equal(f.timers.size, 0);
  assert.equal(f.requests.length, 1);
});

test('hiding or backgrounding pauses refreshes, retains the balance and refreshes on return', async () => {
  const f = fixture();
  f.poller.update('key', 'china', true);
  await f.advance(250);
  const staleTimer = [...f.timers.values()][0].callback;
  f.poller.update('key', 'china', false);
  staleTimer();
  await f.advance(20000);
  assert.equal(f.requests.length, 1);
  assert.equal(f.poller.state.balance, 12.5);
  assert.equal(f.poller.state.isLoading, false);
  assert.equal(f.timers.size, 0);
  f.poller.update('key', 'china', true);
  await f.advance(250);
  assert.equal(f.requests.length, 2);
  f.poller.pause();
});

test('pausing an in-flight request ignores its late result and removes loading', async () => {
  const f = fixture(), gate = deferred();
  f.fetch(() => gate.promise);
  f.poller.update('key', 'china', true);
  await f.advance(250);
  f.poller.pause();
  assert.equal(f.poller.state.isLoading, false);
  gate.resolve(999);
  await settle();
  assert.equal(f.poller.state.balance, undefined);
  assert.equal(f.timers.size, 0);
});

test('formatting matches iOS and Android with grouping, six decimal places and distinct missing/zero values', () => {
  const f = fixture();
  for (const [value, expected] of [[undefined, '—'], [0, '0'], [0.25, '0.25'],
    [1250.75, '1,250.75'], [0.1234567, '0.123457'], [12, '12']]) {
    assert.equal(f.format(value), expected);
  }
});

test('the homepage binds visible/foreground state, credentials and environment to the localized credits pill', () => {
  const source = fs.readFileSync(path.join(app, 'pages/Index.ets'), 'utf8');
  assert.match(source, /onPageShow\(\): void \{\s*this\.isPageVisible = true;/);
  assert.match(source, /onPageHide\(\): void \{\s*this\.isPageVisible = false;/);
  assert.match(source, /@StorageLink\(XLabApplicationLifecycle\.FOREGROUND_STORAGE_KEY\)/);
  assert.match(source, /isActive: this\.isPageVisible && this\.isApplicationForeground/);
  assert.match(source, /@Prop @Watch\('refreshCreditBalance'\) apiKey/);
  assert.match(source, /@Prop @Watch\('refreshCreditBalance'\) isActive/);
  assert.match(source, /@StorageLink\(XLabLocalization\.REVISION_KEY\) @Watch\('refreshCreditBalance'\)/);
  assert.match(source, /this\.creditPoller\.update\(this\.apiKey, XLabLocalization\.environment, this\.isActive\)/);
  assert.match(source, /this\.creditPoller\.onChange = null;\s*this\.creditPoller\.pause\(\)/);
  assert.match(source, /CreditBalancePill\(\{ state: this\.creditBalance \}\)/);
  assert.match(source, /this\.state\.isLoading && this\.state\.balance === undefined/);
  assert.match(source, /this\.text\('credits_refresh_failed'\)/);
  assert.match(source, /\.fontColor\(this\.state\.refreshFailed \? '#F2A04F' : '#8EF0C8'\)/);
});
