const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadEts } = require('./ets-loader.cjs');

function fixture() {
  const requests = [];
  let destroyed = 0;
  let response = { responseCode: 200, result: '' };
  let failure;
  const unexpectedManager = class {
    constructor() { throw new Error('Balance queries must not create media or storage managers'); }
  };
  const load = loadEts({
    XmaxLogger: { XmaxLogger: { configure() {}, error() {} } },
    XmaxRealtimeManager: { XmaxRealtimeManager: unexpectedManager },
    XmaxStorageManager: { XmaxStorageManager: unexpectedManager },
    MediaService: { MediaService: unexpectedManager },
    RuntimeInfo: { RuntimeInfo: { current: {
      platform: 'harmonyos', osVersion: 'test-os', sdkVersion: 'test-sdk', deviceModel: 'test-device'
    } } },
    ApiLogger: { ApiLogger: { logResponse() {}, logFailure() {} } },
    '@kit.NetworkKit': { http: {
      RequestMethod: { GET: 'GET', POST: 'POST', PUT: 'PUT', DELETE: 'DELETE' },
      HttpDataType: { STRING: 'STRING' },
      createHttp: () => ({
        async request(url, options) {
          requests.push({ url, options });
          if (failure !== undefined) throw failure;
          return response;
        },
        destroy() { destroyed++; }
      })
    } }
  });
  const { XmaxClient } = load('core/XmaxClient.ets');
  const { XmaxConfiguration } = load('core/XmaxConfiguration.ets');
  const { XmaxEnvironment } = load('core/XmaxEnvironment.ets');
  return {
    requests, load, XmaxEnvironment,
    get destroyed() { return destroyed; },
    client(key = 'balance-key', environment = XmaxEnvironment.CHINA) {
      return new XmaxClient(new XmaxConfiguration(key, environment));
    },
    respond(data, status = 200) {
      response = { responseCode: status, result: JSON.stringify({ success: true, data }) };
    },
    raw(body, status = 200) { response = { responseCode: status, result: body }; },
    fail(error) { failure = error; }
  };
}

test('balance uses the general API environment, trimmed API key and GET without platform context', async () => {
  const f = fixture();
  const { XmaxCreditBalance } = f.load('core/account/XmaxCreditBalance.ets');
  f.respond({ currentBalance: 1250.75 });
  for (const environment of Object.values(f.XmaxEnvironment)) {
    const balance = await f.client('  balance-key\n', environment).getCreditBalance();
    assert.ok(balance instanceof XmaxCreditBalance);
    assert.equal(balance.currentBalance, 1250.75);
  }
  assert.deepEqual(f.requests.map(request => request.url), [
    'https://cloud.xmax.22duck.cn/open/api/v1/balance',
    'https://api.xmax.cloud/open/api/v1/balance'
  ]);
  for (const { options } of f.requests) {
    assert.equal(options.method, 'GET');
    assert.equal(options.header['X-Api-Key'], 'balance-key');
    assert.equal(options.extraData, undefined);
    assert.equal(options.usingCache, false);
  }
  assert.equal(f.destroyed, 2);
});

test('each balance query fetches fresh credits and preserves zero and fractions', async () => {
  const f = fixture(), client = f.client();
  for (const value of [1250.75, 0, 0.25]) {
    f.respond({ currentBalance: value });
    assert.equal((await client.getCreditBalance()).currentBalance, value);
  }
  assert.equal(f.requests.length, 3);
  assert.equal(f.destroyed, 3);
});

test('an empty API key rejects before sending a request', async () => {
  const f = fixture();
  await assert.rejects(f.client(' \n ').getCreditBalance(), { code: 'INVALID_API_KEY' });
  assert.equal(f.requests.length, 0);
  assert.equal(f.destroyed, 0);
});

test('malformed, missing, negative and nonfinite balances reject instead of becoming zero', async () => {
  const f = fixture(), client = f.client();
  const payloads = [
    'null', '[]', '{}', 'true', '5', '"balance"',
    '{"currentBalance":null}', '{"currentBalance":true}', '{"currentBalance":"1250.75"}',
    '{"currentBalance":-1}', '{"currentBalance":1e400}',
    '{"currentBalance":NaN}', '{"currentBalance":Infinity}',
    '{"currentBalance":[]}', '{"currentBalance":{}}'
  ];
  for (const payload of payloads) {
    f.raw(`{"success":true,"data":${payload}}`);
    await assert.rejects(client.getCreditBalance(), { code: 'API_ERROR' }, payload);
  }
  assert.equal(f.destroyed, payloads.length);
});

test('invalid JSON and missing response data remain API errors with HTTP status', async () => {
  const f = fixture();
  for (const body of ['invalid-json', '{"success":true}']) {
    f.raw(body);
    await assert.rejects(f.client().getCreditBalance(), { code: 'API_ERROR', httpStatus: 200 });
  }
  assert.equal(f.destroyed, 2);
});

test('HTTP and business errors preserve the server code, message and status', async () => {
  const f = fixture();
  for (const status of [200, 401, 403, 500]) {
    f.raw('{"success":false,"code":46002,"message":"Access denied","data":null}', status);
    await assert.rejects(f.client().getCreditBalance(), {
      code: 'API_ERROR', apiCode: 46002, httpStatus: status, message: 'Access denied'
    });
  }
  f.respond({ currentBalance: 50 }, 403);
  await assert.rejects(f.client().getCreditBalance(), { code: 'API_ERROR', httpStatus: 403 });
  assert.equal(f.destroyed, 5);
});

test('transport failure remains a network error and releases the HTTP request', async () => {
  const f = fixture();
  f.fail(new Error('offline'));
  await assert.rejects(f.client().getCreditBalance(), { code: 'NETWORK_ERROR' });
  assert.equal(f.destroyed, 1);
});

test('existing SDK errors propagate without replacing their code', async () => {
  const f = fixture();
  const { XmaxError, XmaxErrorCode } = f.load('foundation/errors/XmaxError.ets');
  const failure = new XmaxError(XmaxErrorCode.CANCELLED, 'cancelled');
  f.fail(failure);
  await assert.rejects(f.client().getCreditBalance(), error => error === failure);
  assert.equal(f.destroyed, 1);
});

test('credit balance is publicly exported with a readonly numeric value', () => {
  const sdk = path.join(__dirname, '../xmax_sdk');
  assert.match(fs.readFileSync(path.join(sdk, 'Index.ets'), 'utf8'),
    /export\s*\{\s*XmaxCreditBalance\s*\}\s*from\s*'.\/src\/main\/ets\/core\/account\/XmaxCreditBalance'/);
  assert.match(fs.readFileSync(path.join(sdk, 'src/main/ets/core/account/XmaxCreditBalance.ets'), 'utf8'),
    /readonly currentBalance: number;/);
});
