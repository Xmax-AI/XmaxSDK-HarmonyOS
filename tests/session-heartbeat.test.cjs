const test = require('node:test');
const assert = require('node:assert/strict');
const { loadEts } = require('./ets-loader.cjs');

const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function serviceFixture() {
  const requests = [], failures = [], timers = new Map();
  let nextTimer = 0, reply = { sessionUid: 'session', status: 'ACTIVE' };
  const load = loadEts({ XmaxLogger: { XmaxLogger: { error() {} } } }, {
    setTimeout(callback, ms) { timers.set(++nextTimer, { callback, ms }); return nextTimer; },
    clearTimeout(id) { timers.delete(id); }
  });
  const { RealtimeSessionService } = load('service/realtime/RealtimeSessionService.ets');
  const service = new RealtimeSessionService({
    async put(path, body) {
      requests.push({ path, body });
      if (reply instanceof Error) throw reply;
      return reply;
    }
  });
  return {
    service, requests, failures, timers,
    start(session = 'session', grace = 2) {
      service.startHeartbeat(session, async (id, error) => { failures.push({ id, error }); }, grace);
    },
    reply(value) { reply = value; },
    async tick() {
      assert.equal(timers.size, 1);
      const [id, timer] = [...timers][0];
      assert.equal(timer.ms, 10000);
      timers.delete(id);
      timer.callback();
      await settle();
    }
  };
}

test('the first HTTP heartbeat is immediate and only its body contains startup grace, including zero', async () => {
  for (const seconds of [0, 2]) {
    const f = serviceFixture();
    f.start('session', seconds);
    assert.deepEqual(f.requests, [{ path: '/session/session/heartbeat',
      body: { firstHeartbeatGraceSeconds: seconds } }]);
    await settle();
    await f.tick();
    await f.tick();
    assert.deepEqual(f.requests.slice(1), [
      { path: '/session/session/heartbeat', body: undefined },
      { path: '/session/session/heartbeat', body: undefined }
    ]);
    assert.equal(f.timers.size, 1);
    assert.deepEqual(f.failures, []);
    f.service.stopHeartbeat();
    assert.equal(f.timers.size, 0);
  }
});

test('heartbeats never overlap a pending request and stopped responses cannot schedule another', async () => {
  const f = serviceFixture(), gate = deferred();
  f.reply(gate.promise);
  f.start();
  await settle();
  assert.equal(f.requests.length, 1);
  assert.equal(f.timers.size, 0);
  f.service.stopHeartbeat();
  gate.resolve({ sessionUid: 'session', status: 'ACTIVE' });
  await settle();
  assert.equal(f.timers.size, 0);
  assert.deepEqual(f.failures, []);
});

test('stopped or replaced cycles ignore late failures and stale timer callbacks', async () => {
  const f = serviceFixture();
  f.start('old');
  await settle();
  const staleTimer = [...f.timers.values()][0].callback;
  const gate = deferred();
  f.reply(gate.promise);
  await f.tick();
  f.start('new', 5);
  const pendingCount = f.requests.length;
  staleTimer();
  assert.equal(f.requests.length, pendingCount);
  gate.reject(new Error('late transport failure'));
  await settle();
  // Both current and old pending requests used this gate; only the current cycle may report it.
  assert.equal(f.failures.length, 1);
  assert.equal(f.failures[0].id, 'new');
  assert.equal(f.timers.size, 0);
});

test('an old pending failure cannot cancel a successfully restarted heartbeat cycle', async () => {
  const f = serviceFixture(), old = deferred();
  f.reply(old.promise);
  f.start('old');
  f.reply({ sessionUid: 'new', status: 'ACTIVE' });
  f.start('new', 3);
  await settle();
  old.reject(new Error('old failure'));
  await settle();
  assert.deepEqual(f.failures, []);
  assert.equal(f.timers.size, 1);
  await f.tick();
  assert.equal(f.requests.at(-1).path, '/session/new/heartbeat');
  f.service.stopHeartbeat();
});

test('HTTP failures and inactive sessions report once and stop scheduling', async () => {
  for (const reply of [new Error('offline'), { sessionUid: 'session', status: 'CLOSED', closeReason: 'ended' }]) {
    const f = serviceFixture();
    f.reply(reply);
    f.start();
    await settle();
    assert.equal(f.failures.length, 1);
    assert.equal(f.failures[0].id, 'session');
    assert.equal(f.failures[0].error.message, reply instanceof Error ? 'offline' : 'ended');
    assert.equal(f.timers.size, 0);
  }
});

function connectionFixture() {
  const calls = [], failures = [];
  let now = 0, count = 0, failedConnection = false;
  const load = loadEts({
    '@ohos.systemDateTime': { default: { TimeType: { ACTIVE: 0 }, getUptime: () => now } },
    XmaxLogger: { XmaxLogger: { error() {} } },
    RealtimeTiming: { RealtimeTiming: class {
      beginConnection() {} beginSessionCreation() {} finishSessionCreation() {} finishConnection() {}
    } },
    RealtimeSessionService: { RealtimeSessionService: class {
      async createSession() { return { id: `session-${++count}`, connection: { botName: 'bot' } }; }
      startHeartbeat(id, onFailure, graceSeconds) { calls.push({ id, onFailure, graceSeconds }); }
      stopHeartbeat() {} async closeSession() {}
    } },
    RealtimeVideoTrack: { RealtimeVideoTrack: class {} },
    VideoRenderRegistry: {}, TrajectoryRegistry: {}
  });
  const { XmaxRealtimeConnectionManager } = load('core/realtime/XmaxRealtimeConnectionManager.ets');
  const manager = new XmaxRealtimeConnectionManager({}, {}, {
    registerRemoteTrack() {}, resetRemoteTrack() {}
  }, {
    async connect() { if (failedConnection) throw new Error('join failed'); },
    async disconnect() {}
  });
  return {
    calls, failures, manager,
    now(value) { now = value; },
    failConnection() { failedConnection = true; },
    connect() { return manager.connect('x2.0-sla', { width: 1080, height: 1920 }, false,
      () => true, async (id, error) => { failures.push({ id, error }); }); }
  };
}

test('connection startup is measured monotonically and rounded up to nonnegative whole seconds', async () => {
  for (const [elapsed, expected] of [[0, 0], [1, 1], [1e9, 1], [1e9 + 1, 2], [-1, 0]]) {
    const f = connectionFixture();
    f.now(100e9);
    await f.connect();
    assert.equal(f.calls.length, 0);
    f.manager.startHeartbeat('wrong');
    assert.equal(f.calls.length, 0);
    f.now(100e9 + elapsed);
    f.manager.startHeartbeat('session-1');
    f.manager.startHeartbeat('session-1');
    assert.equal(f.calls.length, 1);
    assert.equal(f.calls[0].graceSeconds, expected);
    await f.manager.disconnect();
    f.manager.startHeartbeat('session-1');
    assert.equal(f.calls.length, 1);
  }
});

test('reconnection measures a new startup allowance and ignores the old session failure handler', async () => {
  const f = connectionFixture();
  await f.connect();
  f.now(1.2e9);
  f.manager.startHeartbeat('session-1');
  const oldFailure = f.calls[0].onFailure;
  f.manager.prepareForClose();
  await oldFailure('session-1', new Error('closing'));
  assert.deepEqual(f.failures, []);
  await f.manager.disconnect();

  f.now(10e9);
  await f.connect();
  f.now(10.1e9);
  f.manager.startHeartbeat('session-2');
  assert.deepEqual(f.calls.map(call => [call.id, call.graceSeconds]), [['session-1', 2], ['session-2', 1]]);
  await oldFailure('session-1', new Error('old'));
  assert.deepEqual(f.failures, []);
  const failure = new Error('current');
  await f.calls[1].onFailure('session-2', failure);
  assert.deepEqual(f.failures, [{ id: 'session-2', error: failure }]);
  await f.manager.disconnect();
});

test('connection failure cannot start HTTP heartbeats', async () => {
  const f = connectionFixture();
  f.failConnection();
  await assert.rejects(f.connect());
  f.manager.startHeartbeat('session-1');
  assert.equal(f.calls.length, 0);
});
