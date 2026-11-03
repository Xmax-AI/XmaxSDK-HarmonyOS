const test = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const { loadEts } = require('./ets-loader.cjs');
const { createCameraKitFixture } = require('./camera-kit-fixture.cjs');

const platform = {
  XLabLocalization: { XLabLocalization: {
    environment: 'china',
    text: key => require('../examples/XLab/entry/src/main/resources/zh_Hans/element/string.json')
      .string.find(value => value.name === key)?.value ?? key,
    format(key, values) { return this.text(key).replace(/\{(\d+)\}/g, (_match, index) => values[Number(index)] ?? ''); }
  } },
    '@ohos.systemDateTime': { default: { TimeType: { ACTIVE: 0 }, getUptime: () => 0 } },
  '@kit.ArkUI': { UIUtils: { getTarget: value => value } },
  '@kit.ArkTS': { util: {
    generateRandomUUID: () => randomUUID(),
    Base64Helper: class { encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); } }
  } },
  '@kit.BasicServicesKit': { deviceInfo: { distributionOSVersion: '5.1.0', productModel: 'Test model' } },
  XmaxLogger: { XmaxLogger: { error() {}, debug() {}, info() {}, warn() {} } }
};
const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
const outcome = promise => promise.then(value => ({ value }), error => ({ error }));
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function managerFixture(modelName = 'x2.0-sla') {
  const calls = { sessions: [], closed: [], starts: [], updates: [], stops: [], audio: [], switches: 0,
    heartbeats: [] };
  const timers = [];
  let sessionGate = null, autoConfirm = true, holdPreview = false, media, stream, api;
  let Track, Format, MediaStream, XmaxError, Code, CameraPosition, updatePosition;
  class FakeMedia {
    constructor(_context, _rtc, _stream, _error, _service, formatListener, endedListener) {
      media = this; this.currentTrack = null; this.hasAudio = true; this.formatListener = formatListener; this.onError = _error;
      this.endedListener = endedListener;
    }
    get currentVideoFormat() { return this.currentTrack?.videoFormat; }
    async updateCameraFormat(format) {
      (calls.cameraFormats ??= []).push(format);
      if (this.formatGate) await this.formatGate.promise;
      if (this.formatError) throw this.formatError;
      format.validate();
      const { MediaService } = load('service/media/MediaService.ets');
      const { ImageSize } = load('service/media/ImageSize.ets');
      new MediaService(manager.options.model).resolveMediaSize(new ImageSize(format.width, format.height), 'camera');
      this.formatListener(format);
      load('service/realtime/RealtimeVideoTrack.ets').updateRealtimeVideoTrackFormat(this.currentTrack, format);
    }
    async createLocalCameraStream(format, position) {
      if (this.currentTrack) throw new XmaxError(Code.INVALID_CONFIGURATION, 'Already started');
      this.currentTrack = new Track('video0', format, position);
      return new MediaStream('local', this.currentTrack);
    }
    async stopLocalCameraStream() { this.currentTrack = null; }
    async stopLocalStream() { this.currentTrack = null; if (this.externalSource) await this.stopExternalVideoStream(); }
    async createExternalVideoStream(source) {
      this.externalSource = source; this.hasAudio = source.hasAudio;
      this.currentTrack = new Track('external0', source.videoFormat);
      await source.start({ isRequestingFrames: true, videoFormat: source.videoFormat });
      return new MediaStream('local', this.currentTrack);
    }
    async stopExternalVideoStream() {
      const source = this.externalSource;
      this.externalSource = null; this.currentTrack = null;
      await source?.stop();
    }
    owns(local) { return local.videoTrack !== undefined && Track.resolve(local.videoTrack) === this.currentTrack; }
    setLocalAudioPreviewEnabled(value) { calls.audio.push(value); }
    get localAudioVolume() { return this.volume ?? 0.45; }
    async setLocalAudioVolume(value) { this.volume = value; }
    start(task, format) { this.interactionTask = task; this.interactionFormat = format; }
    stop() { this.interactionTask = null; }
    updateCameraOrientation() {}
    startMicrophoneCapture() {}
    stopMicrophoneCapture() {}
    prepareForClose() {}
    setCameraPreviewReadyHandler(listener) { this.readyHandler = listener; if (!holdPreview) listener?.(); }
    async switchCamera() {
      calls.switches++;
      updatePosition(this.currentTrack, CameraPosition.BACK);
      return new MediaStream('local', this.currentTrack);
    }
  }
  class FakeStream {
    constructor(_rtc, _remote, _error, _timing, historyStore) {
      stream = this; this.currentGenerationTaskId = '';
      const { QualityController } = load('stream/quality/QualityController.ets');
      this.quality = new QualityController({ setQualityListener() {} }, historyStore);
    }
    get qualityConfiguration() { return this.quality.qualityConfiguration; }
    prepareQuality(...args) { return this.quality.prepareQuality(...args); }
    rebaseQuality(...args) { return this.quality.rebaseQuality(...args); }
    setUplinkVideoStatisticsListener(...args) { this.quality.setUplinkVideoStatisticsListener(...args); }
    setDownlinkVideoStatisticsListener(...args) { this.quality.setDownlinkVideoStatisticsListener(...args); }
    setNetworkQualityListener(...args) { this.quality.setNetworkQualityListener(...args); }
    setAdaptiveQualityListener(...args) { this.quality.setAdaptiveQualityListener(...args); }
    proposeQuality(...args) { return this.quality.proposeQuality(...args); }
    completeQuality(...args) { this.quality.completeQuality(...args); }
    resetQualitySamples() { this.quality.resetQualitySamples(); }
    setVideoEncoderConfig(format) { (calls.encodings ??= []).push(format); }
    changeTargetSize(task, size) { (calls.targets ??= []).push({ task, size }); }

    get remoteAudioVolume() { return this.volume ?? 1; }
    setRemoteAudioVolume(value) { this.volume = value; }
    async connect(_connection, _audio, ensure) { ensure(); }
    async disconnect() { this.stopGeneration(''); this.quality.resetQuality(); }
    activateRemoteAudio() {}
    beginGeneration(task, format, context, faceRestoration, _targetSize, _padding, extraParams) {
      this.currentGenerationTaskId = task;
      const gate = deferred();
      this.confirmation = gate;
      calls.starts.push({ task, format, context, faceRestoration, extraParams, gate });
      if (autoConfirm) gate.resolve();
      return gate.promise;
    }
    updateGeneration(task, format, context, faceRestoration, _targetSize, _padding, extraParams) {
      calls.updates.push({ task, format, context, faceRestoration, extraParams });
    }
    stopGeneration(task) {
      this.quality.setAdaptiveQualityListener(null);
      this.quality.resetQualitySamples();
      calls.stops.push(task);
      this.currentGenerationTaskId = '';
      this.confirmation?.reject(new XmaxError(Code.CANCELLED, 'Stopped'));
      this.confirmation = null;
    }
  }
  class FakeSessionService {
    constructor() { api = this; }
    async createSession(model) {
      calls.sessions.push(model);
      if (sessionGate) await sessionGate.promise;
      return { id: `session-${calls.sessions.length}`, connection: { roomId: 'room', botName: 'bot' } };
    }
    async closeSession(id) { calls.closed.push(id); }
    startHeartbeat(id, onFailure, graceSeconds) {
      calls.heartbeats.push({ id, graceSeconds });
      this.heartbeat = error => onFailure(id, error);
    }
    stopHeartbeat() {}
  }
  const load = loadEts({ ...platform,
    RtcManager: { RtcManager: class {} },
    MediaController: { MediaController: FakeMedia },
    StreamController: { StreamController: FakeStream },
    RealtimeSessionService: { RealtimeSessionService: FakeSessionService },
    RenderController: { RenderController: class {
      registerRemoteTrack() {} resetRemoteTrack() {} failRemoteFrameWait() {}
      stopRemoteFrameDelivery() {}
      setRemoteMediaFrameListener(listener) { calls.mediaListener = listener; }
      async waitUntilRemoteFrameReady() {}
      async freezeRemoteVideo() { calls.freezes = (calls.freezes ?? 0) + 1; }
    } }
  }, { setTimeout: callback => { timers.push(callback); return timers.length; } });
  ({ RealtimeVideoTrack: Track, updateRealtimeVideoTrackPosition: updatePosition } = load('service/realtime/RealtimeVideoTrack.ets'));
  ({ RealtimeVideoFormat: Format } = load('service/realtime/RealtimeVideoFormat.ets'));
  ({ RealtimeMediaStream: MediaStream } = load('service/realtime/RealtimeMediaStream.ets'));
  ({ XmaxError, XmaxErrorCode: Code } = load('foundation/errors/XmaxError.ets'));
  ({ CameraPosition } = load('foundation/media/camera/CameraPosition.ets'));
  const { RealtimeContext: Context } = load('service/realtime/RealtimeContext.ets');
  const { RealtimeConnectionState: State, RealtimeReason: Reason, RealtimeReasonKind: ReasonKind } = load('service/realtime/RealtimeState.ets');
  const { XmaxRealtimeManager } = load('core/realtime/XmaxRealtimeManager.ets');
  const { RealtimeModels } = load('service/realtime/RealtimeModel.ets');
  const manager = new XmaxRealtimeManager({}, { model: RealtimeModels.realtime(modelName) }, {});
  return { load, manager, media, stream, api, calls, timers, State, Reason, ReasonKind, Context, Format, Track, MediaStream, XmaxError, Code,
    rotateCamera(format) {
      const track = media.currentTrack;
      const previous = track.videoFormat;
      const next = format ?? new Format(previous.height, previous.width, previous.fps);
      media.formatListener(next);
      load('service/realtime/RealtimeVideoTrack.ets').updateRealtimeVideoTrackFormat(track, next);
      return next;
    },
    create: () => manager.createLocalCameraStream(new Format(1080, 1920, 30), CameraPosition.FRONT),
    holdSession() { sessionGate = deferred(); return sessionGate; },
    holdGeneration() { autoConfirm = false; },
    holdPreview() { holdPreview = true; },
    runSwitchDelay() { assert.equal(timers.length, 1); timers.shift()(); }
  };
}

test('camera formats change only from a ready, disconnected camera and preserve its track', async () => {
  const f = managerFixture(), format = new f.Format(1408, 1408, 24, 100, 6000, 'MaintainQuality');
  assert.equal(f.manager.currentCameraVideoFormat, undefined);
  await assert.rejects(f.manager.updateCameraFormat(format), { code: 'INVALID_CONFIGURATION' });
  f.holdPreview();
  const local = await f.create();
  await assert.rejects(f.manager.updateCameraFormat(format), { code: 'INVALID_CONFIGURATION' });
  assert.equal(f.manager.currentState.connectionState, f.State.PREPARING);
  f.media.readyHandler();
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  const states = [];
  f.manager.setStateListener(state => states.push(state.connectionState));
  for (const size of f.manager.options.model.resolutionBuckets) {
    const selected = format.resized(size.width, size.height);
    await f.manager.updateCameraFormat(selected);
    assert.equal(f.media.currentTrack, local.videoTrack);
    assert.deepEqual(f.manager.currentCameraVideoFormat, selected);
    assert.equal(f.manager.currentState.connectionState, f.State.READY);
  }
  assert.deepEqual(f.calls.sessions, []);
  assert.deepEqual(f.calls.starts, []);
  assert.ok(states.every(state => state === f.State.READY));
  await f.manager.close();
  assert.equal(f.manager.currentCameraVideoFormat, undefined);

  const external = { videoFormat: format, hasAudio: false, async start() {}, async stop() {} };
  await f.manager.createExternalVideoStream(external);
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  assert.equal(f.manager.currentCameraVideoFormat, undefined);
  await assert.rejects(f.manager.updateCameraFormat(format), { code: 'INVALID_CONFIGURATION' });
  await f.manager.close();
});

for (const phase of ['connecting', 'connected', 'generating', 'disconnecting']) {
  test(`camera format changes are rejected while realtime is ${phase}`, async () => {
    const f = managerFixture(), local = await f.create(), format = new f.Format(1408, 1408, 30);
    let gate, pending, cleanup;
    if (phase === 'connecting' || phase === 'disconnecting') {
      gate = f.holdSession();
      pending = outcome(f.manager.connect(local));
      await settle();
      if (phase === 'disconnecting') cleanup = f.manager.disconnect();
    } else if (phase === 'connected') {
      await f.manager.connect(local);
    } else {
      await f.manager.startGeneration(local, new f.Context('test'));
    }
    const previous = local.videoTrack.videoFormat;
    await assert.rejects(f.manager.updateCameraFormat(format), { code: 'INVALID_CONFIGURATION' });
    assert.equal(f.calls.cameraFormats, undefined);
    assert.equal(local.videoTrack.videoFormat, previous);
    if (gate) { gate.resolve(); await pending; await cleanup; }
    await f.manager.close();
  });
}

test('camera format operations exclude connect, generation, lens switches and duplicate updates', async () => {
  const f = managerFixture(), local = await f.create(), gate = deferred();
  f.media.formatGate = gate;
  const pending = f.manager.updateCameraFormat(new f.Format(1408, 1408, 30));
  for (const request of [() => f.manager.connect(local),
    () => f.manager.startGeneration(local, new f.Context('test')), () => f.manager.switchCamera(),
    () => f.manager.updateCameraFormat(new f.Format(1920, 1080, 30))]) {
    await assert.rejects(request(), { code: 'INVALID_CONFIGURATION' });
  }
  assert.equal(f.calls.cameraFormats.length, 1);
  assert.equal(f.calls.sessions.length, 0);
  assert.equal(f.calls.switches, 0);
  gate.resolve(); await pending;
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  await f.manager.close();
});

test('camera format failures preserve READY and closing cancels pending format updates before releasing media', async () => {
  const f = managerFixture(), local = await f.create(), original = local.videoTrack.videoFormat;
  f.media.formatError = new f.XmaxError(f.Code.MEDIA_ERROR, 'format unavailable');
  await assert.rejects(f.manager.updateCameraFormat(new f.Format(1408, 1408, 30)), /format unavailable/);
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  assert.equal(local.videoTrack.videoFormat, original);
  f.media.formatError = null;
  const gate = deferred();
  f.media.formatGate = gate;
  const pending = outcome(f.manager.updateCameraFormat(new f.Format(1408, 1408, 30)));
  let closed = false;
  const close = f.manager.close().then(() => { closed = true; });
  await settle();
  assert.equal(closed, false);
  gate.resolve(); await close;
  assert.equal((await pending).error.code, 'CANCELLED');
  assert.equal(f.manager.currentCameraVideoFormat, undefined);
  assert.equal(f.manager.currentState.connectionState, f.State.IDLE);
  f.media.formatGate = null;
  const next = await f.create();
  assert.notEqual(next.videoTrack, local.videoTrack);
  assert.equal(next.videoTrack.videoFormat.width, 1080);
  await f.manager.close();
});

test('manager delegates unified media registration and removal without starting a session', async () => {
  const f = managerFixture(), listener = () => {};
  f.manager.setRemoteMediaFrameListener(listener);
  assert.equal(f.calls.mediaListener, listener);
  assert.deepEqual(f.calls.sessions, []);
  f.manager.setRemoteMediaFrameListener(null);
  assert.equal(f.calls.mediaListener, null);
  await f.manager.close();
});

for (const withStream of [false, true]) {
  test(`face restoration supports start, flag-only updates and default false (stream overload: ${withStream})`, async () => {
    const f = managerFixture();
    const local = await f.create();
    if (!withStream) await f.manager.connect(local);
    const start = (context, flag) => withStream ?
      f.manager.startGeneration(local, context, flag) : f.manager.startGeneration(context, flag);
    const context = new f.Context('original', 'reference.png', true);
    await start(context, true);
    const task = f.calls.starts[0].task;
    assert.equal(f.calls.starts[0].faceRestoration, true);
    await start(undefined, false);
    assert.equal(f.calls.updates.at(-1).faceRestoration, false);
    assert.equal(f.calls.updates.at(-1).context, context);
    const changed = new f.Context('changed');
    await start(changed, true);
    assert.equal(f.calls.updates.at(-1).faceRestoration, true);
    await start(undefined);
    assert.equal(f.calls.updates.at(-1).faceRestoration, false);
    assert.equal(f.calls.updates.at(-1).context, changed);
    assert.ok(f.calls.updates.every(update => update.task === task));
    assert.equal(f.calls.starts.length, 1);
    await start(undefined, true);
    await f.manager.disconnect();
    if (!withStream) await f.manager.connect(local);
    await start(changed);
    assert.equal(f.calls.starts.at(-1).faceRestoration, false);
    assert.equal(f.calls.starts.at(-1).context, changed);
    await f.manager.close();
  });
}

test('face restoration defaults to false on the first generation', async () => {
  const f = managerFixture();
  await f.manager.startGeneration(await f.create(), new f.Context('prompt'));
  assert.equal(f.calls.starts[0].faceRestoration, false);
  await f.manager.close();
});

test('orientation restarts preserve face restoration and commit updates made during confirmation', async () => {
  const f = managerFixture();
  await f.manager.startGeneration(await f.create(), new f.Context('prompt'), true);
  f.rotateCamera();
  await settle();
  f.holdGeneration();
  f.runSwitchDelay();
  await settle();
  assert.equal(f.calls.starts.at(-1).faceRestoration, true);
  const joined = f.manager.startGeneration(undefined, false);
  assert.equal(f.calls.updates.at(-1).faceRestoration, false);
  assert.equal(f.calls.updates.at(-1).context.prompt, 'prompt');
  f.stream.confirmation.resolve();
  await joined;
  f.rotateCamera();
  await settle();
  f.runSwitchDelay();
  await settle();
  assert.equal(f.calls.starts.at(-1).faceRestoration, false);
  f.stream.confirmation.resolve();
  await settle();
  await f.manager.close();
});

for (const endDuringStart of [false, true]) {
  test(`video completion keeps generation active without freezing remote output (during start: ${endDuringStart})`, async () => {
    const f = managerFixture();
    const { LocalVideoPlaybackState: Playback } = f.load('service/realtime/LocalVideoPlaybackState.ets');
    f.media.createLocalVideoStream = async () => {
      f.media.currentTrack = new f.Track('video0', new f.Format(832, 1472, 30));
      f.media.localVideoPlaybackState = Playback.PLAYING;
      return new f.MediaStream('local', f.media.currentTrack);
    };
    const playbackStates = [];
    f.manager.setLocalVideoPlaybackStateListener(state => playbackStates.push(state));
    const local = await f.manager.createLocalVideoStream('once.mp4', undefined, false);
    const complete = () => {
      f.media.localVideoPlaybackState = Playback.ENDED;
      f.media.endedListener();
    };
    if (endDuringStart) {
      f.holdGeneration();
      const starting = f.manager.startGeneration(local, new f.Context('test'));
      await settle();
      complete();
      assert.equal(f.calls.starts.length, 1);
      f.calls.starts[0].gate.resolve();
      await starting;
    } else {
      await f.manager.startGeneration(local, new f.Context('test'));
      const previousState = f.manager.currentState;
      complete();
      assert.equal(f.manager.currentState, previousState);
    }
    assert.deepEqual(playbackStates, [Playback.PLAYING, Playback.ENDED]);
    assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
    assert.equal(f.manager.currentState.taskId, f.calls.starts[0].task);
    assert.equal(f.stream.currentGenerationTaskId, f.calls.starts[0].task);
    assert.equal(f.calls.freezes ?? 0, 0);
    // Starting a session clears the previous (empty) task; EOF must not stop the active one.
    assert.deepEqual(f.calls.stops.filter(task => task.length > 0), []);
    assert.deepEqual(f.calls.closed, []);
    await f.manager.close();
  });
}

test('default camera formats follow the manager model and reach generation signaling unchanged', async () => {
  for (const [name, width, height, fps] of [['x2.0', 832, 1472, 30], ['x2.0-sla', 1080, 1920, 30]]) {
    const f = managerFixture(name);
    const local = await f.manager.createLocalCameraStream(undefined, 'back');
    assert.deepEqual(local.videoTrack.videoFormat, new f.Format(width, height, fps));
    assert.equal(local.videoTrack.position, 'back');
    await f.manager.startGeneration(local, new f.Context('test'));
    assert.deepEqual(f.calls.sessions, [name]);
    assert.deepEqual(f.calls.starts[0].format, new f.Format(width, height, fps));
    await f.manager.close();
  }
});

for (const name of ['x2.0', 'x2.0-sla']) {
  test(`${name} admits image and video input and forwards optional formats to media preparation`, async () => {
    const f = managerFixture(name), calls = [];
    for (const method of ['createLocalImageStream', 'createLocalVideoStream']) {
      f.media[method] = async (source, format) => {
        calls.push({ method, source, format });
        return new f.MediaStream('local');
      };
      for (const format of [undefined, new f.Format(832, 1472, 20)]) {
        const source = method === 'createLocalImageStream' ? new Uint8Array([1, 2]) : 'source.mp4';
        await f.manager[method](source, format);
        assert.deepEqual(calls.at(-1), { method, source, format });
      }
    }
    assert.equal(calls.length, 4);
    assert.deepEqual(f.calls.sessions, []);
  });

}

test('public volume APIs validate finite normalized values before touching playback', async () => {
  const f = managerFixture(), errors = [];
  f.manager.setStateListener(state => { if (state.reason?.error) errors.push(state.reason.error); });
  for (const volume of [-0.01, 1.01, NaN, Infinity, -Infinity]) {
    for (const method of ['setLocalAudioVolume', 'setRemoteAudioVolume']) {
      await assert.rejects(f.manager[method](volume), {
        code: 'INVALID_CONFIGURATION'
      });
    }
  }
  assert.equal(f.media.volume, undefined);
  assert.equal(f.stream.volume, undefined);
  for (const volume of [0, 0.45, 1]) {
    await f.manager.setLocalAudioVolume(volume);
    await f.manager.setRemoteAudioVolume(volume);
    assert.equal(f.media.volume, volume);
    assert.equal(f.stream.volume, volume);
  }
  assert.deepEqual(errors, []);
  assert.equal(f.calls.sessions.length, 0);
});

test('volume failures retain their error code and leave generation running', async () => {
  const f = managerFixture(), errors = [];
  const local = await f.create();
  await f.manager.startGeneration(local, new f.Context('generate'));
  f.manager.setStateListener(state => { if (state.reason?.error) errors.push(state.reason.error); });
  f.media.setLocalAudioVolume = async () => { throw new f.XmaxError(f.Code.MEDIA_ERROR, 'local failed'); };
  f.stream.setRemoteAudioVolume = () => { throw new f.XmaxError(f.Code.RTC_ERROR, 'remote failed'); };
  await assert.rejects(f.manager.setLocalAudioVolume(0.6), {
    code: 'MEDIA_ERROR', message: 'local failed'
  });
  await assert.rejects(f.manager.setRemoteAudioVolume(0.6), {
    code: 'RTC_ERROR', message: 'remote failed'
  });
  assert.deepEqual(errors, []);
  assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
});

test('one-call generation connects on demand, reuses its remote track and supports the original API', async () => {
  const f = managerFixture(), local = await f.create();
  assert.equal(f.calls.sessions.length, 0);
  const context = new f.Context('first');
  const first = await f.manager.startGeneration(local, context);
  const second = await f.manager.startGeneration(local, new f.Context('updated'));
  assert.equal(second.videoTrack, first.videoTrack);
  assert.deepEqual(f.calls.sessions, ['x2.0-sla']);
  assert.equal(f.calls.starts.length, 1);
  assert.equal(f.calls.updates[0].context.prompt, 'updated');
  assert.equal(f.calls.starts[0].format, local.videoTrack.videoFormat);
  assert.equal(f.calls.starts[0].format.width, 1080);
  assert.equal(typeof f.manager.stopGeneration, 'undefined');
  await f.manager.disconnect();
  await assert.rejects(f.manager.startGeneration(local), { code: 'INVALID_CONFIGURATION' });
  const reconnected = await f.manager.connect(local);
  assert.notEqual(reconnected.videoTrack, first.videoTrack);
  assert.equal(await f.manager.startGeneration(new f.Context('explicit connection')), undefined);
  assert.deepEqual(f.calls.sessions, ['x2.0-sla', 'x2.0-sla']);
  await f.manager.close();
});

test('missing context and foreign stream are rejected before creating a session', async () => {
  const f = managerFixture(), local = await f.create();
  await assert.rejects(f.manager.startGeneration(local), { code: 'INVALID_CONFIGURATION' });
  const foreign = new f.MediaStream('local', new f.Track('video0', local.videoTrack.videoFormat));
  await assert.rejects(f.manager.startGeneration(foreign, new f.Context('test')), { code: 'INVALID_CONFIGURATION' });
  assert.equal(f.calls.sessions.length, 0);
});

test('disconnect while connecting waits for rollback and prevents automatic generation', async () => {
  const f = managerFixture(), local = await f.create(), gate = f.holdSession();
  const pending = outcome(f.manager.startGeneration(local, new f.Context('test')));
  const disconnecting = f.manager.disconnect();
  let disconnected = false;
  disconnecting.then(() => { disconnected = true; });
  await settle();
  assert.equal(disconnected, false);
  assert.equal(f.manager.currentState.connectionState, f.State.DISCONNECTING);
  gate.resolve();
  await disconnecting;
  assert.equal((await pending).error.code, f.Code.CANCELLED);
  assert.equal(f.calls.starts.length, 0);
  assert.deepEqual(f.calls.closed, ['session-1']);
  assert.equal(f.calls.audio.at(-1), true);
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  assert.equal(f.media.currentTrack, local.videoTrack);
});

for (const trigger of ['CONNECTING', 'CONNECTED']) {
  test(`disconnect from the synchronous ${trigger} listener cancels automatic generation`, async () => {
    const f = managerFixture(), local = await f.create();
    f.manager.setStateListener(state => {
      if (state.connectionState === f.State[trigger]) void f.manager.disconnect();
    });
    await assert.rejects(f.manager.startGeneration(local, new f.Context('test')), { code: 'CANCELLED' });
    assert.equal(f.calls.starts.length, 0);
    assert.deepEqual(f.calls.closed, trigger === 'CONNECTED' ? ['session-1'] : []);
    assert.equal(f.calls.audio.at(-1), true);
    assert.equal(f.manager.currentState.connectionState, f.State.READY);
    assert.equal(f.media.currentTrack, local.videoTrack);
  });
}

test('close during connection rolls back the late session without reopening audio or generation', async () => {
  const f = managerFixture(), local = await f.create(), gate = f.holdSession();
  const pending = outcome(f.manager.startGeneration(local, new f.Context('test')));
  const closing = f.manager.close();
  let closed = false;
  closing.then(() => { closed = true; });
  await settle();
  assert.equal(closed, false);
  const audioCount = f.calls.audio.length;
  gate.resolve();
  await closing;
  assert.equal((await pending).error.code, 'CANCELLED');
  assert.equal(f.calls.audio.length, audioCount);
  assert.equal(f.calls.audio.at(-1), false);
  assert.equal(f.calls.starts.length, 0);
  assert.deepEqual(f.calls.closed, ['session-1']);
  assert.equal(f.manager.currentState.connectionState, f.State.IDLE);
});

test('a cancelled start cannot stop a newer generation or restore its muted preview', async () => {
  const f = managerFixture(), local = await f.create();
  await f.manager.connect(local);
  f.holdGeneration();
  const old = outcome(f.manager.startGeneration(new f.Context('old')));
  const stopping = f.manager.disconnect();
  await assert.rejects(f.manager.startGeneration(local, new f.Context('too soon')),
    { code: 'INVALID_CONFIGURATION' });
  await stopping;
  const newer = f.manager.startGeneration(local, new f.Context('new'));
  await settle();
  const newTask = f.stream.currentGenerationTaskId;
  assert.equal((await old).error.code, 'CANCELLED');
  assert.equal(f.stream.currentGenerationTaskId, newTask);
  assert.equal(f.calls.audio.at(-1), false);
  f.calls.starts.at(-1).gate.resolve();
  await newer;
  assert.equal(f.media.interactionTask, newTask);
  assert.equal(f.manager.currentState.taskId, newTask);
});

test('close upgrades a pending stop on an established connection and releases local media', async () => {
  const f = managerFixture(), local = await f.create();
  await f.manager.connect(local);
  f.holdGeneration();
  const running = outcome(f.manager.startGeneration(new f.Context('test')));
  const stopping = f.manager.disconnect();
  const closing = f.manager.close();
  assert.equal(stopping, closing);
  assert.equal(f.calls.audio.at(-1), false);
  await closing;
  assert.equal((await running).error.code, f.Code.CANCELLED);
  assert.deepEqual(f.calls.closed, ['session-1']);
  assert.equal(f.stream.currentGenerationTaskId, '');
  assert.equal(f.media.currentTrack, null);
  assert.equal(f.manager.currentState.connectionState, f.State.IDLE);
});

test('repeated disconnect during connection shares rollback without restoring audio early', async () => {
  const f = managerFixture(), local = await f.create(), gate = f.holdSession();
  const running = outcome(f.manager.startGeneration(local, new f.Context('test')));
  const disconnecting = f.manager.disconnect();
  let disconnected = false;
  disconnecting.then(() => { disconnected = true; });
  const audio = [...f.calls.audio];
  assert.equal(f.manager.disconnect(), disconnecting);
  await settle();
  assert.equal(disconnected, false);
  assert.deepEqual(f.calls.audio, audio);
  assert.equal(f.manager.currentState.connectionState, f.State.DISCONNECTING);
  gate.resolve();
  await disconnecting;
  assert.equal((await running).error.code, f.Code.CANCELLED);
  assert.deepEqual(f.calls.closed, ['session-1']);
  assert.equal(f.calls.starts.length, 0);
  assert.ok(f.media.currentTrack);
  assert.equal(f.calls.audio.at(-1), true);
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
});

test('connection failure reports the original error', async () => {
  const f = managerFixture(), local = await f.create(), gate = f.holdSession();
  const error = new f.XmaxError(f.Code.NETWORK_ERROR, 'session request failed');
  const running = outcome(f.manager.startGeneration(local, new f.Context('test')));
  gate.reject(error);
  assert.equal((await running).error, error);
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  assert.equal(f.calls.starts.length, 0);
  assert.equal(f.calls.audio.at(-1), true);
});

test('disconnect is a no-op after generation failure has closed the session and returned to READY', async () => {
  const f = managerFixture(), local = await f.create();
  await f.manager.disconnect();
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  assert.deepEqual(f.calls.audio, []);
  assert.deepEqual(f.calls.stops, []);
  await f.manager.connect(local);
  f.holdGeneration();
  const running = outcome(f.manager.startGeneration(new f.Context('test')));
  const failure = new f.XmaxError(f.Code.TIMEOUT, 'generation confirmation timed out');
  f.calls.starts.at(-1).gate.reject(failure);
  assert.equal((await running).error, failure);
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  assert.deepEqual(f.calls.closed, ['session-1']);
  assert.equal(f.manager.currentState.reason.error, failure);
  const stops = [...f.calls.stops], audio = [...f.calls.audio];
  await f.manager.disconnect();
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  assert.deepEqual(f.calls.stops, stops);
  assert.deepEqual(f.calls.audio, audio);
  await f.manager.disconnect();
  const disconnectedStops = [...f.calls.stops], disconnectedAudio = [...f.calls.audio];
  await f.manager.disconnect();
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  assert.deepEqual(f.calls.stops, disconnectedStops);
  assert.deepEqual(f.calls.audio, disconnectedAudio);
});

test('heartbeat failure cancels a later task restart and publishes the original error only after cleanup', async () => {
  const f = managerFixture(), local = await f.create(), received = [];
  await f.manager.startGeneration(local, new f.Context('first'));
  f.holdGeneration();
  const running = outcome(f.manager.startGeneration({ context: new f.Context('test'), restart: true }));
  f.manager.setStateListener(state => { if (state.reason?.error) received.push({ error: state.reason.error,
    state: f.manager.currentState.connectionState,
    closed: [...f.calls.closed], task: f.stream.currentGenerationTaskId
  }); });
  const failure = new f.XmaxError(f.Code.SESSION_ERROR, 'heartbeat failed', 1004, 503);
  await f.api.heartbeat(failure);
  assert.equal((await running).error, failure);
  assert.deepEqual(received, [{ error: failure, state: f.State.READY, closed: ['session-1'], task: '' }]);
  assert.notEqual(f.media.currentTrack, null);
});

test('HTTP heartbeats start after the first committed GENERATING, not connect or pending confirmation', async () => {
  const f = managerFixture(), local = await f.create(), observedHeartbeatCounts = [];
  await f.manager.connect(local);
  assert.deepEqual(f.calls.heartbeats, []);
  f.holdGeneration();
  const starting = f.manager.startGeneration(new f.Context('first'));
  await settle();
  assert.deepEqual(f.calls.heartbeats, []);
  assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);

  f.manager.setStateListener(state => {
    if (state.connectionState === f.State.GENERATING) {
      observedHeartbeatCounts.push(f.calls.heartbeats.length);
    }
  });
  f.calls.starts.at(-1).gate.resolve();
  await starting;
  assert.deepEqual(f.calls.heartbeats, [{ id: 'session-1', graceSeconds: 0 }]);

  await f.manager.startGeneration(new f.Context('updated'));
  const restarting = f.manager.startGeneration({ restart: true });
  await settle();
  f.calls.starts.at(-1).gate.resolve();
  await restarting;
  assert.equal(f.calls.heartbeats.length, 1);
  assert.deepEqual(observedHeartbeatCounts, [1, 1]);
  await f.manager.close();
});

test('cancelling generation before GENERATING never starts HTTP heartbeats', async () => {
  for (const operation of ['disconnect', 'close']) {
    const f = managerFixture(), local = await f.create();
    f.holdGeneration();
    const starting = outcome(f.manager.startGeneration(local, new f.Context('test')));
    await settle();
    await f.manager[operation]();
    assert.equal((await starting).error.code, f.Code.CANCELLED);
    assert.deepEqual(f.calls.heartbeats, []);
  }
});

test('stop-signal failure is logged without a failure callback and still disconnects and preserves local preview', async () => {
  const f = managerFixture(), local = await f.create(), errors = [];
  await f.manager.startGeneration(local, new f.Context('test'));
  f.manager.setStateListener(state => { if (state.reason?.error) errors.push(state.reason.error); });
  const stop = f.stream.stopGeneration.bind(f.stream);
  f.stream.stopGeneration = task => {
    stop(task);
    throw new f.XmaxError(f.Code.RTC_ERROR, 'stop signal failed');
  };
  await f.manager.disconnect();
  assert.deepEqual(errors, []);
  assert.equal(f.stream.currentGenerationTaskId, '');
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  assert.equal(f.calls.audio.at(-1), true);
});

test('switchCamera preserves track/session/format and restores the last generation context', async () => {
  const f = managerFixture(), local = await f.create();
  await f.manager.startGeneration(local, new f.Context('first'));
  await f.manager.startGeneration(new f.Context('latest'), true);
  const oldTask = f.manager.currentState.taskId;
  const switching = f.manager.switchCamera();
  await settle();
  assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);
  assert.equal(f.calls.switches, 1);
  f.runSwitchDelay();
  const switched = await switching;
  assert.equal(switched.videoTrack, local.videoTrack);
  assert.equal(f.calls.sessions.length, 1);
  assert.equal(f.calls.starts.at(-1).context.prompt, 'latest');
  assert.equal(f.calls.starts.at(-1).faceRestoration, true);
  assert.notEqual(f.manager.currentState.taskId, oldTask);
  assert.equal(f.calls.starts.at(-1).format, local.videoTrack.videoFormat);
});

test('stopping during the camera settling delay prevents generation from restarting', async () => {
  const f = managerFixture(), local = await f.create();
  await f.manager.startGeneration(local, new f.Context('test'));
  const switching = outcome(f.manager.switchCamera());
  await settle();
  await f.manager.disconnect();
  f.runSwitchDelay();
  assert.equal((await switching).error.code, 'CANCELLED');
  assert.equal(f.calls.starts.length, 1);
  assert.equal(f.calls.audio.at(-1), true);
});

test('camera switching is rejected while generation startup is still pending', async () => {
  const f = managerFixture(), local = await f.create();
  await f.manager.connect(local);
  f.holdGeneration();
  const starting = outcome(f.manager.startGeneration(new f.Context('test')));
  await assert.rejects(f.manager.switchCamera(), { code: 'INVALID_CONFIGURATION' });
  assert.equal(f.calls.switches, 0);
  await f.manager.disconnect();
  assert.equal((await starting).error.code, 'CANCELLED');
});

test('replacing a camera stream still requires disconnect, stop and create; old streams become invalid', async () => {
  const f = managerFixture(), local = await f.create();
  const firstRemote = await f.manager.startGeneration(local, new f.Context('test'));
  assert.equal(f.manager.replaceLocalCameraStream, undefined);
  await assert.rejects(f.manager.stopLocalCameraStream(), { code: 'INVALID_CONFIGURATION' });
  await f.manager.disconnect();
  await f.manager.stopLocalCameraStream();
  const format = new f.Format(832, 1472, 24);
  const newLocal = await f.manager.createLocalCameraStream(format);
  await assert.rejects(f.manager.startGeneration(local, new f.Context('test')), { code: 'INVALID_CONFIGURATION' });
  const remote = await f.manager.startGeneration(newLocal, new f.Context('new specs'));
  assert.notEqual(remote.videoTrack, firstRemote.videoTrack);
  assert.equal(newLocal.videoTrack.videoFormat, format);
  assert.deepEqual(remote.videoTrack.videoFormat, new f.Format(728, 1288, 24));
  assert.equal(f.calls.sessions.length, 2);
});

function renderFixture() {
  const load = loadEts({ ...platform,
    DefaultTrajectoryEffectRenderer: { DefaultTrajectoryEffectRenderer: class {} },
    TrajectoryOverlayView: { TrajectoryOverlayView: class {} }
  });
  const { RealtimeVideoTrack: Track, updateRealtimeVideoTrackPosition: updatePosition } = load('service/realtime/RealtimeVideoTrack.ets');
  const { VideoRenderBinding: Binding, VideoRenderRegistry: Registry } = load('rendering/video/VideoRenderRegistry.ets');
  return { load, Track, updatePosition, Binding, Registry };
}

test('ArkUI property copies retain opaque track identity, metadata and render/interaction bindings', () => {
  const f = renderFixture();
  const original = new f.Track('same-id', { width: 1024, height: 1920, fps: 30 }, 0);
  const copy = Object.assign(Object.create(Object.getPrototypeOf(original)), original);
  const another = new f.Track('same-id');
  const { TrajectoryRegistry } = f.load('rendering/trajectory/TrajectoryRegistry.ets');
  const binding = new f.Binding('rtc', () => {}, () => {});
  f.Registry.register(original, binding);
  TrajectoryRegistry.register(original, { submit() {} });
  assert.equal(f.Track.resolve(copy), original);
  assert.equal(copy.videoFormat, original.videoFormat);
  f.updatePosition(original, 1);
  assert.equal(copy.position, 1);
  assert.equal(f.Registry.libraryName(copy), 'rtc');
  assert.equal(f.Registry.libraryName(another), '');
  assert.equal(TrajectoryRegistry.binding(copy), TrajectoryRegistry.binding(original));
  f.Registry.unregister(original);
  TrajectoryRegistry.unregister(original);
});

test('video view rebinds a changed track, clears frames, and ignores late surface callbacks', () => {
  const f = renderFixture(), events = [];
  const { XmaxRealtimeVideo } = f.load('rendering/video/XmaxRealtimeVideo.ets');
  const a = new f.Track('same-id'), b = new f.Track('same-id');
  const bindingA = new f.Binding('rtc', id => events.push(['attachA', id]), id => events.push(['detachA', id]));
  const bindingB = new f.Binding('rtc', id => events.push(['attachB', id]), id => events.push(['detachB', id]));
  f.Registry.register(a, bindingA); f.Registry.register(b, bindingB);
  const view = new XmaxRealtimeVideo(), ready = [];
  view.onVideoReadyChanged = value => ready.push(value);
  view.getUIContext = () => ({ getMediaQuery: () => ({ matchMediaSync: () => ({ matches: false, on() {}, off() {} }) }) });
  view.track = a; view.aboutToAppear();
  const oldView = view.viewId;
  view.attachVideo(oldView);
  bindingA.setPreviewFrame('old frame'); bindingA.setVideoReady(true);
  assert.equal(view.previewFrame, 'old frame');
  view.track = b; view.onTrackChanged();
  assert.equal(view.previewFrame, undefined);
  assert.equal(ready.at(-1), false);
  view.attachVideo(view.viewId);
  view.attachVideo(oldView);
  bindingA.setPreviewFrame('late frame'); bindingA.setVideoReady(true);
  assert.equal(view.previewFrame, undefined);
  assert.deepEqual(events.map(event => event[0]), ['attachA', 'detachA', 'attachB']);
  bindingB.setVideoReady(true);
  bindingB.setPreviewFrame('active frame');
  assert.equal(ready.at(-1), true);
  f.Registry.unregister(b);
  assert.equal(ready.at(-1), false);
  assert.equal(view.previewFrame, undefined);
  view.aboutToDisappear();
  assert.equal(events.filter(event => event[0] === 'detachB').length, 1);
  f.Registry.unregister(a);
});

test('a new generation on a reused RTC stream waits for a fresh render, while remounting the same generation replays readiness', () => {
  const f = renderFixture(), readiness = [], rendered = new Set(), bound = [], subscriptions = [];
  const { RemoteVideoController } = f.load('rendering/video/RemoteVideoController.ets');
  const { RemoteStream } = f.load('foundation/rtc/RemoteStream.ets');
  let listener;
  const rtc = {
    setRemoteVideoRenderedListener(value) { listener = value; },
    hasRenderedRemoteVideo(stream) { return rendered.has(stream.key()); },
    bindRemoteVideo(stream, view) { bound.push([stream.key(), view]); },
    unbindRemoteVideo() {},
    subscribeRemoteVideo(userId, enabled) {
      subscriptions.push([userId, enabled]);
      if (!enabled) rendered.clear();
    }
  };
  const controller = new RemoteVideoController(rtc, ready => readiness.push(ready));
  const stream = new RemoteStream('room', 'bot');
  controller.attach('view', 0); controller.setRemoteStream(stream);
  assert.equal(readiness.at(-1), false);
  listener(new RemoteStream('old-room', 'bot'));
  assert.equal(readiness.at(-1), false);
  rendered.add(stream.key()); listener(stream);
  assert.equal(readiness.at(-1), true);
  controller.setRemoteStream(null);
  assert.equal(readiness.at(-1), false);
  listener(stream);
  assert.equal(readiness.at(-1), false);
  controller.setRemoteStream(new RemoteStream('room', 'bot'));
  assert.deepEqual(subscriptions, [['bot', false], ['bot', true]]);
  assert.equal(readiness.at(-1), false, 'old publication readiness must not reveal its cached frame');
  controller.attach('replacement-view', 0);
  assert.equal(readiness.at(-1), false, 'mounting a view cannot bypass the fresh render wait');
  rendered.add(stream.key()); listener(stream);
  assert.equal(readiness.at(-1), true);
  controller.detach('old-view');
  assert.equal(readiness.at(-1), true);
  controller.detach('replacement-view');
  assert.equal(readiness.at(-1), false);
  controller.attach('view', 0);
  assert.equal(readiness.at(-1), true);
  assert.equal(subscriptions.length, 2, 'same-generation remount must not restart the subscription');
  controller.reset();
  listener(stream);
  assert.equal(readiness.at(-1), false);
});

test('a disconnect from the GENERATING listener prevents returning a stale successful start', async () => {
  const f = managerFixture(), local = await f.create();
  f.manager.setStateListener(state => {
    if (state.connectionState === f.State.GENERATING) void f.manager.disconnect();
  });
  await assert.rejects(f.manager.startGeneration(local, new f.Context('test')), { code: 'CANCELLED' });
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  assert.equal(f.media.interactionTask, null);
});

test('composite view resets on replacement/nil and ignores a removed remote view callback', () => {
  const f = renderFixture();
  const { XmaxRealtimeDualVideo } = f.load('rendering/video/XmaxRealtimeDualVideo.ets');
  const view = new XmaxRealtimeDualVideo();
  view.remoteTrack = new f.Track('remote'); view.aboutToAppear();
  const oldKey = view.remoteViewKey;
  view.onRemoteVideoReady(oldKey, true);
  assert.equal(view.remoteReady, true);
  view.remoteTrack = new f.Track('remote'); view.onRemoteTrackChanged();
  assert.equal(view.remoteReady, false);
  view.onRemoteVideoReady(oldKey, true);
  assert.equal(view.remoteReady, false);
  view.onRemoteVideoReady(view.remoteViewKey, true);
  assert.equal(view.remoteReady, true);
  view.remoteTrack = undefined; view.onRemoteTrackChanged();
  view.onRemoteVideoReady(view.remoteViewKey, true);
  assert.equal(view.remoteReady, false);
});

test('camera controller uses CameraKit external frames and preserves its track when switching', async () => {
  const calls = [];
  const cameraKit = createCameraKitFixture(calls);
  const load = loadEts({ ...platform,
    '@kit.CameraKit': cameraKit.kit,
    CameraFrameOutput: cameraKit.frameOutput,
    PermissionManager: { PermissionManager: class { async ensureCameraPermission() {} } }
  });
  const { CameraController } = load('media/camera/CameraController.ets');
  const { RealtimeVideoFormat } = load('service/realtime/RealtimeVideoFormat.ets');
  const { CameraPosition } = load('foundation/media/camera/CameraPosition.ets');
  const { VideoRenderRegistry } = load('rendering/video/VideoRenderRegistry.ets');
  const pushedFrames = [];
  const camera = new CameraController({}, {
    useExternalVideoSource() { calls.push(['external-video']); },
    configureLocalVideoMirror(position) { calls.push(['mirror', position]); },
    renderLibraryName() { return 'rtc'; },
    bindLocalVideo(viewId) { calls.push(['bind', viewId]); },
    unbindLocalVideo() {}
  }, {
    setVideoEncoderConfig() {}, pushLocalVideoFrame(frame) { pushedFrames.push(frame); }
  }, new (load('service/media/MediaService.ets').MediaService)(
    load('service/realtime/RealtimeModel.ets').RealtimeModels.realtime('x2.0-sla')));
  let readyCount = 0;
  camera.setPreviewReadyListener(() => readyCount++);
  const local = await camera.createLocalCameraStream(new RealtimeVideoFormat(1080, 1920, 30), CameraPosition.FRONT);
  assert.ok(calls.some(call => call[0] === 'external-video'));
  assert.deepEqual(calls.find(call => call[0] === 'camera-frame-output'),
    ['camera-frame-output', 1920, 1440]);
  assert.deepEqual(calls.find(call => call[0] === 'camera-frame-rate'),
    ['camera-frame-rate', 30, 30]);
  assert.ok(calls.filter(call => call[0] === 'camera-query-frame-rates').every(call => call[1]));
  assert.deepEqual(calls.find(call => call[0] === 'camera'), ['camera', 1080, 1920, 30]);
  const frame = { timestampUs: 123 };
  cameraKit.emit(frame);
  assert.deepEqual(pushedFrames, [frame]);
  assert.equal(readyCount, 0);
  VideoRenderRegistry.attach(local.videoTrack, 'local-view', 'fill', () => {}, () => {});
  assert.equal(readyCount, 1);
  const switched = await camera.switchCamera();
  assert.equal(switched.videoTrack, local.videoTrack);
  assert.equal(switched.videoTrack.position, CameraPosition.BACK);
  assert.equal(calls.filter(call => call[0] === 'camera').length, 2);
  assert.ok(calls.some(call => call[0] === 'camera-close' && call[1] === 'front'));
  cameraKit.emit({ timestampUs: 456 }, 0);
  assert.deepEqual(pushedFrames, [frame]);
  const switchedFrame = { timestampUs: 789 };
  cameraKit.emit(switchedFrame, 1);
  assert.deepEqual(pushedFrames, [frame, switchedFrame]);
  assert.equal(readyCount, 2);
  await camera.stopLocalCameraStream();
  assert.ok(calls.some(call => call[0] === 'camera-close' && call[1] === 'back'));
  cameraKit.emit({ timestampUs: 999 }, 1);
  assert.deepEqual(pushedFrames, [frame, switchedFrame]);
});

test('camera capture falls back to the largest compatible 4:3 profile when 16:9 cannot run at 30 fps', async () => {
  const calls = [];
  const cameraKit = createCameraKitFixture(calls, { profiles: [
    { format: 'yuv420sp', size: { width: 2560, height: 1920 }, frameRates: [{ min: 30, max: 30 }] },
    { format: 'yuv420sp', size: { width: 1920, height: 1080 }, frameRates: [{ min: 24, max: 24 }] },
    { format: 'yuv420sp', size: { width: 1440, height: 1920 }, frameRates: [{ min: 24, max: 24 }] },
    { format: 'yuv420sp', size: { width: 1200, height: 1600 }, frameRates: [{ min: 15, max: 30 }] },
    { format: 'yuv420sp', size: { width: 1440, height: 1080 }, frameRates: [{ min: 30, max: 30 }] }
  ] });
  const load = loadEts({ ...platform,
    '@kit.CameraKit': cameraKit.kit,
    CameraFrameOutput: cameraKit.frameOutput,
    PermissionManager: { PermissionManager: class { async ensureCameraPermission() {} } }
  });
  const { CameraController } = load('media/camera/CameraController.ets');
  const { RealtimeVideoFormat } = load('service/realtime/RealtimeVideoFormat.ets');
  const { CameraPosition } = load('foundation/media/camera/CameraPosition.ets');
  const camera = new CameraController({}, {
    useExternalVideoSource() {}, configureLocalVideoMirror() {},
    renderLibraryName() { return 'rtc'; }, bindLocalVideo() {}, unbindLocalVideo() {}
  }, {
    setVideoEncoderConfig() {}, pushLocalVideoFrame() {}
  }, new (load('service/media/MediaService.ets').MediaService)(
    load('service/realtime/RealtimeModel.ets').RealtimeModels.realtime('x2.0-sla')));

  await camera.createLocalCameraStream(
    new RealtimeVideoFormat(1080, 1920, 30),
    CameraPosition.FRONT
  );

  assert.deepEqual(calls.filter(call => call[0] === 'camera-frame-output'), [
    ['camera-frame-output', 1920, 1080],
    ['camera-frame-output', 1440, 1920],
    ['camera-frame-output', 1200, 1600]
  ]);
  assert.equal(calls.filter(call => call[0] === 'camera-output-release').length, 2);
  assert.deepEqual(calls.find(call => call[0] === 'camera-frame-rate'),
    ['camera-frame-rate', 30, 30]);
  assert.ok(calls.filter(call => call[0] === 'camera-query-frame-rates').every(call => call[1]));
  await camera.stopLocalCameraStream();
});

test('camera capture prefers 1080p YUV at 30 fps over larger 4:3 and rejects oversized or other-format profiles', async () => {
  const f = cameraFailureFixture({ profiles: [
    { format: 'yuv420sp', size: { width: 1920, height: 1440 } },
    { format: 'yuv420sp', size: { width: 3840, height: 2160 } },
    { format: 'jpeg', size: { width: 1920, height: 1080 } },
    { format: 'yuv420sp', size: { width: 1600, height: 1600 } },
    { format: 'yuv420sp', size: { width: 1280, height: 720 } },
    { format: 'yuv420sp', size: { width: 1920, height: 1080 } }
  ] });
  await f.start();
  assert.deepEqual(f.calls.filter(call => call[0] === 'camera-frame-output'), [
    ['camera-frame-output', 1920, 1080]
  ]);
  assert.deepEqual(f.calls.find(call => call[0] === 'camera-frame-rate'), ['camera-frame-rate', 30, 30]);
  await f.camera.stopLocalCameraStream();
});

test('camera capture tries smaller portrait 9:16 profiles before falling back to 4:3', async () => {
  const f = cameraFailureFixture({ profiles: [
    { format: 'yuv420sp', size: { width: 1920, height: 1440 } },
    { format: 'yuv420sp', size: { width: 720, height: 1280 } },
    { format: 'yuv420sp', size: { width: 1080, height: 1920 }, frameRates: [{ min: 24, max: 24 }] }
  ] });
  await f.start();
  assert.deepEqual(f.calls.filter(call => call[0] === 'camera-frame-output'), [
    ['camera-frame-output', 1080, 1920],
    ['camera-frame-output', 720, 1280]
  ]);
  assert.equal(f.calls.filter(call => call[0] === 'camera-output-release').length, 1);
  await f.camera.stopLocalCameraStream();
});

function cameraFailureFixture(options = {}, rtcError) {
  const calls = [];
  const cameraKit = createCameraKitFixture(calls, options);
  const load = loadEts({ ...platform,
    '@kit.CameraKit': cameraKit.kit,
    CameraFrameOutput: cameraKit.frameOutput,
    PermissionManager: { PermissionManager: class { async ensureCameraPermission() {} } }
  });
  const { CameraController } = load('media/camera/CameraController.ets');
  const { RealtimeVideoFormat } = load('service/realtime/RealtimeVideoFormat.ets');
  const { CameraPosition } = load('foundation/media/camera/CameraPosition.ets');
  const errors = load('foundation/errors/XmaxError.ets');
  const camera = new CameraController({}, {
    useExternalVideoSource() { if (rtcError) throw rtcError(errors); },
    configureLocalVideoMirror() {}, renderLibraryName() { return 'rtc'; },
    bindLocalVideo() {}, unbindLocalVideo() {}
  }, { setVideoEncoderConfig() {}, pushLocalVideoFrame() {} },
  new (load('service/media/MediaService.ets').MediaService)(
    load('service/realtime/RealtimeModel.ets').RealtimeModels.realtime('x2.0-sla')));
  return { camera, calls, start: () => camera.createLocalCameraStream(
    new RealtimeVideoFormat(1080, 1920, 30), CameraPosition.FRONT) };
}

test('camera rejects genuinely unsupported frame rates as media errors and releases each session', async () => {
  const f = cameraFailureFixture({ profiles: [
    { format: 'yuv420sp', size: { width: 1920, height: 1440 }, frameRates: [{ min: 24, max: 24 }] },
    { format: 'yuv420sp', size: { width: 1440, height: 1080 }, frameRates: [{ min: 60, max: 60 }] }
  ] });
  await assert.rejects(f.start(), error => {
    assert.equal(error.code, 'MEDIA_ERROR');

    assert.match(error.message, /at 30 fps/);
    return true;
  });
  assert.equal(f.camera.currentTrack, null);
  for (const event of ['camera-session-release', 'camera-output-release', 'camera-close']) {
    assert.equal(f.calls.filter(call => call[0] === event).length, 2);
  }
  assert.equal(f.calls.some(call => call[0] === 'camera-start'), false);
});

test('camera platform failures retain the failing stage and native code instead of claiming no compatible profile', async () => {
  for (const [option, stage] of [
    ['commitError', /Configure CameraKit session/],
    ['queryError', /Query CameraKit frame rates/],
    ['frameRateError', /Set CameraKit frame rate/]
  ]) {
    const options = { [option]: Object.assign(new Error('native failure'), { code: 7400110 }) };
    const f = cameraFailureFixture(options);
    await assert.rejects(f.start(), error => {
      assert.equal(error.code, 'MEDIA_ERROR');

      assert.match(error.message, stage);
      assert.match(error.message, /7400110.*native failure/);
      assert.doesNotMatch(error.message, /does not support/);
      return true;
    });
    for (const event of ['camera-session-release', 'camera-output-release', 'camera-close']) {
      assert.equal(f.calls.filter(call => call[0] === event).length, 1);
    }
    delete options[option];
    await f.start();
    assert.ok(f.camera.currentTrack);
    await f.camera.stopLocalCameraStream();
  }
});

test('camera missing capabilities and invalid lifecycle have the appropriate error categories', async () => {
  for (const options of [{ devices: [] }, { profiles: [] }, { profiles: [
    { format: 'yuv420sp', size: { width: 1920, height: 1440 }, frameRates: [] }
  ] }]) {
    const f = cameraFailureFixture(options);
    await assert.rejects(f.start(), { code: 'MEDIA_ERROR' });
    assert.equal(f.camera.currentTrack, null);
  }
  const f = cameraFailureFixture();
  await assert.rejects(f.camera.switchCamera(), { code: 'INVALID_CONFIGURATION' });
});

test('camera setup preserves errors originating in RTC', async () => {
  let original;
  const f = cameraFailureFixture({}, ({ XmaxError, XmaxErrorCode }) => {
    original = new XmaxError(XmaxErrorCode.RTC_ERROR, 'external source failed');
    return original;
  });
  await assert.rejects(f.start(), error => error === original);
  assert.equal(f.calls.some(call => call[0] === 'camera-open'), false);
});

test('RTC first-frame cache ignores other rooms/engines and resets on unsubscribe, unpublish and leaving', async () => {
  const handlers = new Map(), roomHandlers = new Map();
  const engine = { on(name, fn) { handlers.set(name, fn); }, off(name) { handlers.delete(name); } };
  const load = loadEts({ ...platform,
    '@bytertc/volcenginertc': { MirrorType: { kMirrorTypeNone: 0 }, StreamIndex: { kStreamIndexMain: 0 } },
    RtcEngineManager: { RtcEngineManager: { async acquire() { return { engine }; }, async release() {} } },
    RtcQualityConverter: {}, RtcStatsLogger: {}, RtcVideoConverter: {}
  });
  const { RtcManager } = load('foundation/rtc/RtcManager.ets');
  const { RemoteStream } = load('foundation/rtc/RemoteStream.ets');
  const rtc = new RtcManager({}), stream = new RemoteStream('room', 'bot'), events = [];
  rtc.setRemoteVideoRenderedListener(value => events.push(value.key()));
  await rtc.initialize();
  rtc.activeRoomId = 'room';
  const firstFrame = handlers.get('onFirstRemoteVideoFrameRendered');
  firstFrame({ room_id: 'stale-room', user_id: 'bot', stream_index: 0 }, {});
  firstFrame({ room_id: 'room', user_id: 'bot', stream_index: 1 }, {});
  assert.equal(events.length, 0);
  const key = { room_id: 'room', user_id: 'bot', stream_index: 0 };
  firstFrame(key, {});
  assert.equal(rtc.hasRenderedRemoteVideo(stream), true);
  const room = { on(name, fn) { roomHandlers.set(name, fn); }, subscribeStreamVideo() { return 0; } };
  rtc.room = room; rtc.bindRoomEvents(room);
  rtc.subscribeRemoteVideo('bot', false);
  assert.equal(rtc.hasRenderedRemoteVideo(stream), false);
  rtc.subscribeRemoteVideo('bot', true);
  assert.equal(rtc.hasRenderedRemoteVideo(stream), false);
  firstFrame(key, {});
  assert.equal(rtc.hasRenderedRemoteVideo(stream), true);
  roomHandlers.get('onUserPublishStreamVideo')('room', 'bot', false);
  assert.equal(rtc.hasRenderedRemoteVideo(stream), false);
  firstFrame(key, {});
  rtc.room = null;
  await rtc.leaveRoom();
  assert.equal(rtc.hasRenderedRemoteVideo(stream), false);
  await rtc.destroy();
  const count = events.length;
  firstFrame(key, {});
  assert.equal(events.length, count);
  assert.equal(handlers.has('onFirstRemoteVideoFrameRendered'), false);
});

test('external input uses the normal Core lifecycle, is READY without a frame, and remains bound after disconnect', async () => {
  const f = managerFixture();
  const source = { videoFormat: new f.Format(1280, 720, 24), hasAudio: false,
    starts: 0, stops: 0,
    async start() { this.starts++; }, async stop() { this.stops++; } };
  const local = await f.manager.createExternalVideoStream(source);
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  assert.equal(source.starts, 1);
  assert.equal(f.manager.remoteAudioVolume, 0);
  assert.equal(local.videoTrack.videoFormat.fps, 24);
  assert.equal(f.calls.sessions.length, 0);
  await f.manager.disconnect();
  assert.equal(source.stops, 0);
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  await f.manager.stopExternalVideoStream();
  assert.equal(source.stops, 1);
  assert.equal(f.manager.currentState.connectionState, f.State.IDLE);
});

test('close releases an external source through the normal media cleanup path', async () => {
  const f = managerFixture();
  const source = { videoFormat: new f.Format(1280, 720, 24), hasAudio: true,
    stops: 0, async start() {}, async stop() { this.stops++; } };
  await f.manager.createExternalVideoStream(source);
  await f.manager.close();
  assert.equal(source.stops, 1);
  assert.equal(f.manager.currentState.connectionState, f.State.IDLE);
});

function exampleFixture(modelName = 'x2.0-sla') {
  const f = managerFixture(modelName);
  const recorders = [];
  let nextManager = f.manager;
  const load = loadEts({ ...platform,
    '@kit.PerformanceAnalysisKit': { hilog: { error() {} } },
    '@xmax/sdk': {
      CameraPosition: { FRONT: 'front' }, RealtimeConnectionState: f.State,
      LocalVideoPlaybackState: f.load('service/realtime/LocalVideoPlaybackState.ets').LocalVideoPlaybackState,
      RealtimeReasonKind: f.ReasonKind,
      RealtimeContext: f.Context, RealtimeMediaStream: f.MediaStream, RealtimeVideoFormat: f.Format,
      XmaxLoggerOption: { ALL: 3 },
      XmaxEnvironment: { CHINA: 'china', GLOBAL: 'global' },
      VideoContentMode: { FIT: 'fit', FILL: 'fill' },
      RealtimeConfiguration: class {}, RealtimeModels: { realtime() {} }, XmaxConfiguration: class {},
      XmaxClient: class { createRealtimeManager() { return nextManager; } }
    },
    XLabConfiguration: { XLabConfiguration: { currentApiKey: () => 'test-only' } },
    XLabModelSelection: { XLabModelSelection: { current: () => 'x2.0-sla' } },
    ReferenceDataSource: { ReferenceDataSource: { categories: () => [] } },
    RealtimeFileVideoSource: { RealtimeFileVideoSource: class {
      static async create() { throw new Error('Stub external file decoding for this test'); }
    } },
    RealtimeVideoRecorder: { RealtimeVideoRecorder: class {
      constructor() { recorders.push(this); this.frames = []; }
      start(onError) { this.onError = onError; }
      append(frame) { if (this.appendError) throw this.appendError; this.frames.push(frame); }
      async stop() { this.stopped = true; if (this.stopGate) await this.stopGate.promise; return 'recording.mp4'; }
      async saveToAlbum() { this.saved = true; return true; }
      async cancel() { this.cancelled = true; if (this.cancelGate) await this.cancelGate.promise; }
      async removeOutput() { this.removed = true; }
    } }
  }, { Observed: value => value });
  const path = require('node:path');
  const { RealtimeViewModel } = load(path.resolve(__dirname,
    '../examples/XLab/entry/src/main/ets/modules/xlrealtime/mvvm/viewmodel/RealtimeViewModel.ets'));
  return { ...f, recorders, viewModel: new RealtimeViewModel([]),
    useManager(manager) { nextManager = manager; }
  };
}

test('XLab exposes five camera formats and preserves fps and encoding settings when selecting a ratio', async () => {
  const f = exampleFixture(), vm = f.viewModel;
  await vm.connect({}); await settle();
  assert.deepEqual(vm.state.supportedCameraFormats.map(format => [format.width, format.height]),
    [[1920, 1080], [1080, 1920], [1408, 1408], [1152, 1536], [1536, 1152]]);
  assert.equal(vm.state.canUpdateCameraFormat, true);
  const track = vm.localStream.videoTrack;
  const original = new f.Format(1080, 1920, 24, 1500, 7000, 'MaintainQuality');
  f.load('service/realtime/RealtimeVideoTrack.ets').updateRealtimeVideoTrackFormat(track, original);
  await vm.updateCameraFormat(new f.Format(1408, 1408, 30));
  assert.deepEqual(track.videoFormat, original.resized(1408, 1408));
  assert.equal(vm.localStream.videoTrack, track);
  assert.equal(vm.state.localVideoTrack, track);
  assert.equal(vm.state.cameraVideoFormat, track.videoFormat);
  assert.equal(vm.state.cameraPreviewContentMode, 'fit');
  assert.equal(vm.state.isCameraFormatUpdating, false);
  assert.deepEqual(f.calls.sessions, []);
  const updates = f.calls.cameraFormats.length;
  await vm.updateCameraFormat(new f.Format(1408, 1408, 30));
  assert.equal(f.calls.cameraFormats.length, updates);
  await vm.disconnect();
  assert.deepEqual(vm.state.supportedCameraFormats, []);
  assert.equal(vm.state.cameraVideoFormat, undefined);
});

test('XLab camera preview fills only exact 9:16 formats while keeping the same track', async () => {
  const f = exampleFixture(), vm = f.viewModel;
  await vm.connect({}); await settle();
  const track = vm.state.localVideoTrack;
  assert.equal(vm.state.cameraVideoFormat, track.videoFormat);
  assert.equal(vm.state.cameraPreviewContentMode, 'fill');
  for (const [width, height, mode] of [[1408, 1408, 'fit'], [1920, 1080, 'fit'],
    [1152, 1536, 'fit'], [1536, 1152, 'fit'], [1080, 1920, 'fill']]) {
    await vm.updateCameraFormat(new f.Format(width, height, 30));
    assert.equal(vm.state.localVideoTrack, track);
    assert.equal(vm.state.cameraVideoFormat, track.videoFormat);
    assert.equal(vm.state.cameraPreviewContentMode, mode);
  }
  await vm.disconnect();
});

test('XLab ignores generation and lens clicks while a camera format update is pending', async () => {
  const f = exampleFixture(), vm = f.viewModel;
  await vm.connect({}); await settle();
  f.media.formatGate = deferred();
  const pending = vm.updateCameraFormat(new f.Format(1408, 1408, 30));
  assert.equal(vm.state.isCameraFormatUpdating, true);
  assert.equal(vm.state.canUpdateCameraFormat, false);
  await vm.updateCameraFormat(new f.Format(1920, 1080, 30));
  await vm.switchCamera();
  vm.state.selectedCategoryId = 'free';
  vm.submitPrompt('ignored while changing ratio');
  vm.state.selectedCategoryId = 'mox';
  vm.startMoxGeneration();
  vm.selectReference({ reference: { id: 'reference', categoryId: 'charx', remoteUrl: 'reference.png' } });
  assert.equal(vm.state.selectedReferenceId, '');
  assert.equal(f.calls.switches, 0);
  assert.equal(f.calls.cameraFormats.length, 1);
  assert.equal(f.calls.sessions.length, 0);
  f.media.formatGate.resolve(); await pending;
  assert.equal(vm.state.canUpdateCameraFormat, true);
  await f.manager.startGeneration(vm.localStream, new f.Context('test'));
  await vm.updateCameraFormat(new f.Format(1920, 1080, 30));
  assert.equal(f.calls.cameraFormats.length, 1);
  assert.equal(vm.state.canUpdateCameraFormat, false);
  await vm.disconnect();
});

test('XLab ignores an obsolete camera format completion after page closure', async () => {
  const f = exampleFixture(), vm = f.viewModel, messages = [];
  vm.onMessage = message => messages.push(message);
  await vm.connect({}); await settle();
  const gate = deferred();
  f.media.formatGate = gate;
  const pending = vm.updateCameraFormat(new f.Format(1408, 1408, 30));
  const close = vm.disconnect();
  assert.equal(vm.state.isCameraFormatUpdating, false);
  gate.resolve(); await pending; await close;
  assert.equal(vm.state.localVideoTrack, null);
  assert.equal(vm.state.connectionState, f.State.IDLE);
  assert.deepEqual(messages, []);
  assert.deepEqual(f.calls.sessions, []);
});

test('XLab records only while generating, attaches the unified receiver on demand and saves once', async () => {
  const f = exampleFixture(), vm = f.viewModel;
  vm.toggleRecording({}); assert.equal(f.recorders.length, 0);
  await vm.connect({});
  assert.equal(f.calls.mediaListener, undefined);
  vm.toggleRecording({}); assert.equal(f.recorders.length, 0);
  await f.manager.startGeneration(vm.localStream, new f.Context('prompt'));
  vm.toggleRecording({});
  const recorder = f.recorders[0];
  assert.equal(vm.state.recordingState, 'recording');
  const listener = f.calls.mediaListener;
  listener({ streamId: 'result', timestampUs: 10 });
  assert.equal(recorder.frames.length, 1);
  recorder.stopGate = deferred();
  vm.toggleRecording({}); vm.toggleRecording({});
  assert.equal(vm.state.recordingState, 'saving');
  assert.equal(f.calls.mediaListener, null);
  listener({ streamId: 'result', timestampUs: 20 });
  assert.equal(recorder.frames.length, 1);
  assert.equal(f.recorders.length, 1);
  recorder.stopGate.resolve(); await vm.recordingCompletion;
  assert.equal(recorder.saved, true);
  assert.equal(recorder.removed, true);
  assert.equal(vm.state.recordingState, 'idle');
  await vm.disconnect();
});

test('XLab automatically finishes recording when generation stops without closing preview', async () => {
  const f = exampleFixture(), vm = f.viewModel;
  await vm.connect({});
  await f.manager.startGeneration(vm.localStream, new f.Context('prompt'));
  vm.toggleRecording({});
  await f.manager.disconnect(); await vm.recordingCompletion;
  assert.equal(f.recorders[0].stopped, true);
  assert.equal(f.recorders[0].saved, true);
  assert.equal(vm.state.recordingState, 'idle');
  await vm.disconnect();
});

test('XLab isolates recording failures from generation and ignores obsolete media and error callbacks', async () => {
  const f = exampleFixture(), vm = f.viewModel, messages = [];
  vm.onMessage = message => messages.push(message);
  await vm.connect({});
  await f.manager.startGeneration(vm.localStream, new f.Context('prompt'));
  vm.toggleRecording({});
  const recorder = f.recorders[0], listener = f.calls.mediaListener;
  recorder.cancelGate = deferred();
  recorder.appendError = new Error('queue full');
  listener({});
  assert.equal(vm.state.recordingState, 'saving');
  assert.equal(f.calls.mediaListener, null);
  assert.equal(vm.state.connectionState, f.State.GENERATING);
  recorder.onError('late native failure');
  assert.equal(messages.length, 1);
  recorder.cancelGate.resolve(); await vm.recordingCompletion;
  vm.toggleRecording({});
  listener({}); recorder.onError('obsolete');
  assert.equal(vm.state.recordingState, 'recording');
  assert.equal(f.recorders[1].frames.length, 0);
  await vm.disconnect();
  assert.equal(f.recorders[1].cancelled, true);
  assert.equal(f.recorders[1].saved, undefined);
  assert.equal(f.calls.mediaListener, null);
});

test('XLab exit during finalization suppresses the save dialog and waits asynchronously for cleanup', async () => {
  const f = exampleFixture(), vm = f.viewModel;
  await vm.connect({});
  await f.manager.startGeneration(vm.localStream, new f.Context('prompt'));
  vm.toggleRecording({});
  const recorder = f.recorders[0]; recorder.stopGate = deferred();
  vm.toggleRecording({});
  const closing = vm.disconnect();
  await settle();
  assert.equal(f.calls.mediaListener, null);
  recorder.stopGate.resolve(); await closing;
  assert.equal(recorder.saved, undefined);
  assert.equal(recorder.removed, true);
  assert.equal(vm.state.recordingState, 'idle');
});

function exampleVideoPlaybackFixture() {
  const f = exampleFixture();
  const { LocalVideoPlaybackState: Playback } = f.load('service/realtime/LocalVideoPlaybackState.ets');
  f.media.createLocalVideoStream = async (_path, _format, loop) => {
    f.media.loop = loop;
    f.media.currentTrack = new f.Track('file-video', new f.Format(832, 1472, 24));
    f.media.localVideoPlaybackState = Playback.PLAYING;
    return new f.MediaStream('local', f.media.currentTrack);
  };
  f.media.pauseLocalVideoStream = async () => { f.media.localVideoPlaybackState = Playback.PAUSE; };
  f.media.resumeLocalVideoStream = () => { f.media.localVideoPlaybackState = Playback.PLAYING; };
  f.media.stopLocalVideoStream = async () => {
    f.media.currentTrack = null;
    f.media.localVideoPlaybackState = undefined;
  };
  f.manager.renderController.freezeRemoteVideo = async () => {};
  f.manager.renderController.resumeRemoteVideo = async () => {};
  return { ...f, Playback };
}

test('XLab quality selectors require generation and track successful independent changes', async () => {
  const f = exampleFixture(), vm = f.viewModel;
  const { RealtimeQualityLevel: Level } = f.load('stream/quality/RealtimeQualityLevel.ets');
  assert.equal(vm.state.canAdjustQuality, false);
  await vm.setUplinkQualityLevel(Level.L3);
  await vm.connect({});
  await vm.setDownlinkQualityLevel(Level.L4);
  assert.equal(vm.state.uplinkQualityLevel, undefined);
  assert.equal(vm.state.downlinkQualityLevel, undefined);
  assert.deepEqual(f.calls.sessions, []);
  await f.manager.startGeneration(vm.localStream, new f.Context('prompt'));
  assert.equal(vm.state.canAdjustQuality, true);
  assert.equal(vm.state.uplinkQualityLevel, Level.L2);
  assert.equal(vm.state.downlinkQualityLevel, Level.L2);
  await vm.setUplinkQualityLevel(Level.L3);
  assert.equal(vm.state.uplinkQualityLevel, Level.L3);
  assert.equal(vm.state.downlinkQualityLevel, Level.L2);
  await vm.setDownlinkQualityLevel(Level.L4);
  assert.equal(vm.state.downlinkQualityLevel, Level.L4);
  assert.equal(f.calls.starts.length, 1);
  assert.equal(vm.state.isQualityChanging, false);
  await f.manager.disconnect();
  assert.equal(vm.state.canAdjustQuality, false);
  assert.equal(vm.state.uplinkQualityLevel, undefined);
  assert.equal(vm.state.downlinkQualityLevel, undefined);
  await vm.disconnect();
});

test('XLab statistics refresh quality levels after automatic changes and ignore stale callbacks', async () => {
  const f = exampleFixture(), vm = f.viewModel;
  await vm.connect({});
  await f.manager.startGeneration(vm.localStream, new f.Context('prompt'));
  const uplinkListener = f.stream.quality.uplinkStatisticsListener;
  const downlinkListener = f.stream.quality.downlinkStatisticsListener;
  f.stream.completeQuality(false, 4, true);
  f.stream.completeQuality(true, 5, true);
  uplinkListener({ width: 608, height: 1140 });
  assert.equal(vm.state.uplinkQualityLevel, 4);
  assert.equal(vm.state.downlinkQualityLevel, 5);
  f.stream.completeQuality(true, 3, true);
  downlinkListener({ width: 768, height: 1440 });
  assert.equal(vm.state.downlinkQualityLevel, 3);
  await vm.disconnect();
  uplinkListener({ width: 1, height: 1 });
  downlinkListener({ width: 1, height: 1 });
  assert.equal(vm.state.uplinkStatistics, undefined);
  assert.equal(vm.state.downlinkStatistics, undefined);
  assert.equal(vm.state.uplinkQualityLevel, undefined);
  assert.equal(vm.state.downlinkQualityLevel, undefined);
});

test('XLab serializes quality taps and reports failures without selecting an unapplied level', async () => {
  const f = exampleFixture(), vm = f.viewModel, gate = deferred(), messages = [];
  await vm.connect({});
  await f.manager.startGeneration(vm.localStream, new f.Context('prompt'));
  vm.onMessage = message => messages.push(message);
  let requests = 0;
  f.manager.setUplinkQualityLevel = async () => { requests++; await gate.promise; };
  await vm.setUplinkQualityLevel(2);
  assert.equal(requests, 0);
  const pending = vm.setUplinkQualityLevel(3);
  assert.equal(vm.state.canAdjustQuality, false);
  await vm.setUplinkQualityLevel(4);
  await vm.setDownlinkQualityLevel(5);
  assert.equal(requests, 1);
  assert.equal(vm.state.uplinkQualityLevel, 2);
  assert.equal(vm.state.downlinkQualityLevel, 2);
  gate.reject(new Error('quality change failed'));
  await pending;
  assert.deepEqual(messages, ['quality change failed']);
  assert.equal(vm.state.errorMessage, '');
  assert.equal(vm.state.canAdjustQuality, true);
  assert.equal(vm.state.uplinkQualityLevel, 2);
  await vm.disconnect();
});

test('XLab ignores quality changes during generation startup and other local operations', async () => {
  const f = exampleFixture(), vm = f.viewModel;
  await vm.connect({});
  await f.manager.startGeneration(vm.localStream, new f.Context('prompt'));
  let requests = 0;
  f.manager.setUplinkQualityLevel = async () => { requests++; };
  vm.state.isGenerationStarting = true;
  assert.equal(vm.state.canAdjustQuality, false);
  await vm.setUplinkQualityLevel(3);
  vm.state.isGenerationStarting = false;
  for (const operation of ['connecting', 'switchingCamera', 'changingLocalMedia',
    'changingVideoPlayback', 'generationUpdating']) {
    vm[operation] = true;
    await vm.setUplinkQualityLevel(3);
    vm[operation] = false;
  }
  assert.equal(requests, 0);
  await vm.disconnect();
});

test('XLab ignores obsolete quality completion after closing and reopening its manager', async () => {
  const f = exampleFixture(), next = managerFixture(), vm = f.viewModel;
  const oldGate = deferred(), nextGate = deferred(), messages = [];
  vm.onMessage = message => messages.push(message);
  await vm.connect({});
  await f.manager.startGeneration(vm.localStream, new f.Context('prompt'));
  f.manager.setUplinkQualityLevel = () => oldGate.promise;
  const oldPending = vm.setUplinkQualityLevel(3);
  await vm.disconnect();
  assert.equal(vm.state.isQualityChanging, false);
  f.useManager(next.manager);
  await vm.connect({});
  await next.manager.startGeneration(vm.localStream, new next.Context('prompt'));
  next.manager.setDownlinkQualityLevel = () => nextGate.promise;
  const nextPending = vm.setDownlinkQualityLevel(4);
  oldGate.reject(new Error('obsolete request'));
  await oldPending;
  assert.equal(vm.state.isQualityChanging, true);
  assert.deepEqual(messages, []);
  nextGate.resolve();
  await nextPending;
  assert.equal(vm.state.isQualityChanging, false);
  assert.equal(vm.state.downlinkQualityLevel, 2);
  await vm.disconnect();
});

test('XLab loops selected videos by default and retains completion callback handling', async () => {
  const f = exampleVideoPlaybackFixture(), vm = f.viewModel, messages = [];
  vm.onMessage = message => messages.push(message);
  await vm.connect({}, 'video.mp4');
  assert.equal(f.media.loop, true);
  assert.deepEqual(messages, []);
  f.manager.localVideoPlaybackStateListener(f.Playback.ENDED);
  assert.equal(vm.state.localVideoPlaybackState, f.Playback.ENDED);
  assert.deepEqual(messages, ['视频播放结束']);
  await vm.changeLocalVideo('next.mp4');
  assert.equal(f.media.loop, true);
  assert.equal(vm.state.localVideoPlaybackState, f.Playback.PLAYING);
  const oldListener = f.manager.localVideoPlaybackStateListener;
  await vm.disconnect();
  oldListener(f.Playback.ENDED);
  assert.deepEqual(messages, ['视频播放结束']);
});

test('XLab ignores video taps after completion without calling SDK playback controls or showing errors', async () => {
  const f = exampleVideoPlaybackFixture(), vm = f.viewModel, messages = [];
  vm.onMessage = message => messages.push(message);
  await vm.connect({}, 'video.mp4');
  f.media.localVideoPlaybackState = f.Playback.ENDED;
  f.manager.localVideoPlaybackStateListener(f.Playback.ENDED);
  let toggleCalls = 0;
  f.manager.toggleLocalVideoStreamPlayback = async () => {
    toggleCalls++;
    throw new Error('Playback already ended');
  };
  await vm.toggleLocalVideoPlayback();
  await vm.toggleLocalVideoPlayback();
  assert.equal(toggleCalls, 0);
  assert.equal(vm.state.localVideoPlaybackState, f.Playback.ENDED);
  assert.deepEqual(messages, ['视频播放结束']);
  await vm.disconnect();
});

test('XLab video taps pause and resume through the SDK callback without starting generation', async () => {
  const f = exampleVideoPlaybackFixture(), vm = f.viewModel;
  await vm.connect({}, 'video.mp4');
  assert.equal(vm.state.localVideoPlaybackState, f.Playback.PLAYING);
  await vm.toggleLocalVideoPlayback();
  assert.equal(vm.state.localVideoPlaybackState, f.Playback.PAUSE);
  await vm.toggleLocalVideoPlayback();
  assert.equal(vm.state.localVideoPlaybackState, f.Playback.PLAYING);
  assert.deepEqual(f.calls.sessions, []);
  assert.ok(vm.state.localVideoTrack);
});

test('XLab video tap waits for playback completion and reports failures without changing UI state', async () => {
  const f = exampleVideoPlaybackFixture(), vm = f.viewModel, gate = deferred(), messages = [];
  await vm.connect({}, 'video.mp4');
  vm.onMessage = value => messages.push(value);
  let toggles = 0;
  f.manager.toggleLocalVideoStreamPlayback = async () => { toggles++; await gate.promise; };
  const pending = vm.toggleLocalVideoPlayback();
  await vm.toggleLocalVideoPlayback();
  assert.equal(toggles, 1);
  assert.equal(vm.state.localVideoPlaybackState, f.Playback.PLAYING);
  gate.reject(new Error('pause failed'));
  await pending;
  assert.deepEqual(messages, ['pause failed']);
  assert.equal(vm.state.errorMessage, '');
  assert.equal(vm.changingVideoPlayback, false);
});

test('XLab ignores playback taps for camera, image, loading and media replacement', async () => {
  const f = exampleVideoPlaybackFixture(), vm = f.viewModel;
  const camera = exampleFixture();
  let toggles = 0;
  f.manager.toggleLocalVideoStreamPlayback = async () => { toggles++; };
  camera.manager.toggleLocalVideoStreamPlayback = async () => { toggles++; };
  await vm.toggleLocalVideoPlayback();
  await camera.viewModel.connect({});
  await camera.viewModel.toggleLocalVideoPlayback();
  await camera.viewModel.disconnect();
  await vm.connect({}, 'video.mp4');
  assert.equal(vm.state.localVideoPlaybackState, f.Playback.PLAYING);
  vm.localImagePath = 'image.jpg';
  await vm.toggleLocalVideoPlayback();
  vm.localImagePath = '';
  vm.state.isGenerationStarting = true;
  await vm.toggleLocalVideoPlayback();
  vm.state.isGenerationStarting = false;
  vm.changingLocalMedia = true;
  await vm.toggleLocalVideoPlayback();
  assert.equal(toggles, 0);
});

test('XLab resets paused video when replacing the file and detaches callback on exit', async () => {
  const f = exampleVideoPlaybackFixture(), vm = f.viewModel;
  await vm.connect({}, 'video.mp4');
  await vm.toggleLocalVideoPlayback();
  await vm.changeLocalVideo('next.mp4');
  assert.equal(vm.state.localVideoPlaybackState, f.Playback.PLAYING);
  const oldListener = f.manager.localVideoPlaybackStateListener;
  assert.equal(typeof oldListener, 'function');
  await vm.disconnect();
  assert.equal(f.manager.localVideoPlaybackStateListener, null);
  oldListener(f.Playback.PAUSE);
  assert.equal(vm.state.localVideoPlaybackState, undefined);
});

test('XLab uses model camera defaults for both models without an interpolation size override', async () => {
  for (const [name, width, height, fps] of [['x2.0', 832, 1472, 30], ['x2.0-sla', 1080, 1920, 30]]) {
    const f = exampleFixture(name);
    await f.viewModel.connect({});
    await settle();
    assert.deepEqual(f.viewModel.state.localVideoTrack.videoFormat, new f.Format(width, height, fps));
    assert.deepEqual(f.calls.sessions, []);
    await f.viewModel.suspend();
  }
});

test('XLab applies remembered volumes before local playback and restores both after mute', async () => {
  const f = exampleFixture(), vm = f.viewModel;
  assert.equal(vm.state.localAudioVolume, 0.45);
  assert.equal(vm.state.remoteAudioVolume, 1);
  await vm.setLocalAudioVolume(0.3);
  await vm.setRemoteAudioVolume(0.8);
  const create = f.media.createLocalCameraStream.bind(f.media);
  f.media.createLocalCameraStream = async (...args) => {
    assert.equal(f.media.volume, 0.3);
    assert.equal(f.stream.volume, 0.8);
    return create(...args);
  };
  await vm.connect({});
  await vm.setAudioMuted(true);
  assert.equal(f.media.volume, 0);
  assert.equal(f.stream.volume, 0);
  assert.equal(vm.state.localAudioVolume, 0.3);
  assert.equal(vm.state.remoteAudioVolume, 0.8);
  await vm.setAudioMuted(false);
  assert.equal(f.media.volume, 0.3);
  assert.equal(f.stream.volume, 0.8);
});

test('either XLab video slider unmutes both channels and restores the other remembered volume', async () => {
  const f = exampleFixture(), vm = f.viewModel;
  f.media.createLocalVideoStream = async () => new f.MediaStream('local');
  await vm.connect({}, 'video.mp4');
  await vm.setAudioMuted(true);
  await vm.setLocalAudioVolume(0.2);
  assert.equal(vm.state.isAudioMuted, false);
  assert.equal(f.media.volume, 0.2);
  assert.equal(f.stream.volume, 1);
  await vm.setAudioMuted(true);
  await vm.setRemoteAudioVolume(0.7);
  assert.equal(vm.state.isAudioMuted, false);
  assert.equal(f.media.volume, 0.2);
  assert.equal(f.stream.volume, 0.7);
});

test('XLab volume errors show a toast without covering or stopping generation', async () => {
  const f = exampleFixture(), messages = [], vm = f.viewModel;
  await vm.connect({});
  vm.onMessage = message => messages.push(message);
  f.stream.setRemoteAudioVolume = () => { throw new Error('volume failed'); };
  await vm.setRemoteAudioVolume(0.6);
  assert.deepEqual(messages, ['volume failed']);
  assert.equal(vm.state.errorMessage, '');
  assert.ok(vm.state.localVideoTrack);
});

test('XLab restores mute and slider values when recreating its manager after suspension', async () => {
  const f = exampleFixture(), next = managerFixture(), vm = f.viewModel;
  await vm.connect({});
  await vm.setLocalAudioVolume(0.2);
  await vm.setRemoteAudioVolume(0.7);
  await vm.setAudioMuted(true);
  await vm.suspend();
  f.useManager(next.manager);
  const create = next.media.createLocalCameraStream.bind(next.media);
  next.media.createLocalCameraStream = async (...args) => {
    assert.equal(next.media.volume, 0);
    assert.equal(next.stream.volume, 0);
    return create(...args);
  };
  await vm.resume({});
  assert.ok(vm.state.localVideoTrack);
  assert.equal(vm.state.isAudioMuted, true);
  assert.equal(vm.state.localAudioVolume, 0.2);
  assert.equal(vm.state.remoteAudioVolume, 0.7);
  await vm.setAudioMuted(false);
  assert.equal(next.media.volume, 0.2);
  assert.equal(next.stream.volume, 0.7);
});

test('XLab starts with local preview only, then starts MOX directly from idle', async () => {
  const f = exampleFixture();
  await f.viewModel.connect({});
  await settle();
  assert.ok(f.viewModel.state.localVideoTrack);
  assert.equal(f.calls.sessions.length, 0);
  f.viewModel.state.selectedCategoryId = 'mox';
  f.viewModel.startMoxGeneration();
  await settle();
  assert.equal(f.calls.sessions.length, 1);
  assert.equal(f.calls.starts.length, 1);
  assert.ok(f.viewModel.state.remoteVideoTrack);
  assert.equal(f.viewModel.state.connectionState, f.State.GENERATING);
});

test('XLab cancellation during one-call connection leaves local preview without starting generation', async () => {
  const f = exampleFixture(), gate = f.holdSession();
  await f.viewModel.connect({});
  await settle();
  f.viewModel.state.selectedCategoryId = 'mox';
  f.viewModel.startMoxGeneration();
  await settle();
  assert.equal(f.manager.currentState.connectionState, f.State.CONNECTING);
  f.viewModel.cancelGeneration();
  assert.equal(f.manager.currentState.connectionState, f.State.DISCONNECTING);
  gate.resolve();
  await settle();
  assert.equal(f.calls.starts.length, 0);
  assert.equal(f.viewModel.state.remoteVideoTrack, null);
  assert.equal(f.viewModel.state.isGenerationStarting, false);
  assert.equal(f.viewModel.state.errorMessage, '');
  assert.ok(f.viewModel.state.localVideoTrack);
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  assert.deepEqual(f.calls.closed, ['session-1']);
});

test('XLab replaces input during connection by closing the old session and generating only the latest prompt', async () => {
  const f = exampleFixture(), gate = f.holdSession();
  await f.viewModel.connect({});
  await settle();
  f.viewModel.state.selectedCategoryId = 'free';
  f.viewModel.submitPrompt('old prompt');
  await settle();
  assert.equal(f.manager.currentState.connectionState, f.State.CONNECTING);
  f.viewModel.submitPrompt('new prompt');
  assert.equal(f.manager.currentState.connectionState, f.State.DISCONNECTING);
  f.viewModel.submitPrompt('latest prompt');
  gate.resolve();
  await settle();
  await settle();
  assert.deepEqual(f.calls.closed, ['session-1']);
  assert.equal(f.calls.sessions.length, 2);
  assert.equal(f.calls.starts.length, 1);
  assert.equal(f.calls.starts[0].context.prompt, 'latest prompt');
  assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
  assert.ok(f.viewModel.state.remoteVideoTrack);
  assert.ok(f.viewModel.state.localVideoTrack);
  assert.equal(f.viewModel.state.errorMessage, '');
});

function referenceItem(id) {
  return { isSelected: false, reference: {
    id, categoryId: 'charx', remoteUrl: `https://example.invalid/${id}.jpg`,
    uploadState: 'ready', isAddAction: false
  } };
}

test('XLab enables face restoration only for clothing references and disables it for other generation modes', async () => {
  const f = exampleFixture(), vm = f.viewModel;
  await vm.connect({});
  const clothing = referenceItem('clothing');
  clothing.reference.categoryId = 'clothx';
  vm.selectReference(clothing);
  await settle();
  assert.equal(f.calls.starts.at(-1).faceRestoration, true);
  for (const category of ['charx', 'dimx', 'vibex']) {
    const item = referenceItem(category);
    item.reference.categoryId = category;
    vm.selectReference(item);
    await settle();
    assert.equal(f.calls.updates.at(-1).faceRestoration, false);
  }
  vm.selectReference(clothing);
  await settle();
  assert.equal(f.calls.updates.at(-1).faceRestoration, true);
  vm.state.selectedCategoryId = 'free';
  vm.submitPrompt('custom prompt');
  await settle();
  assert.equal(f.calls.updates.at(-1).faceRestoration, false);
  assert.equal(f.calls.updates.at(-1).context.prompt, 'custom prompt');
  vm.state.selectedCategoryId = 'mox';
  vm.startMoxGeneration();
  await settle();
  assert.equal(f.calls.updates.at(-1).faceRestoration, false);
  await vm.disconnect();
});

for (const phase of ['connecting', 'waiting for generation']) {
  test(`XLab keeps loading continuously when replacing references while ${phase}`, async () => {
    const f = exampleFixture(), vm = f.viewModel;
    const gate = phase === 'connecting' ? f.holdSession() : null;
    f.holdGeneration();
    await vm.connect({});
    vm.selectReference(referenceItem('first'));
    await settle();
    assert.equal(vm.state.isGenerationStarting, true);
    const loadingChanges = [];
    let loading = true;
    Object.defineProperty(vm.state, 'isGenerationStarting', {
      get: () => loading,
      set(value) { loading = value; loadingChanges.push(value); }
    });
    vm.selectReference(referenceItem('second'));
    vm.selectReference(referenceItem('latest'));
    assert.equal(f.manager.currentState.connectionState, f.State.DISCONNECTING);
    assert.equal(loading, true);
    gate?.resolve();
    await settle(); await settle();
    assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);
    assert.equal(f.calls.starts.at(-1).context.referencePath, 'https://example.invalid/latest.jpg');
    assert.equal(f.calls.starts.some(call => call.context.referencePath?.includes('second.jpg')), false);
    assert.equal(loadingChanges.includes(false), false);
    assert.equal(vm.state.errorMessage, '');
    f.stream.confirmation.resolve();
    await settle();
    assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
    assert.equal(loading, false);
    await vm.suspend();
  });
}

for (const action of ['cancel', 'deselect', 'suspend']) {
  test(`XLab ${action} ends loading while a reference replacement is disconnecting`, async () => {
    const f = exampleFixture(), vm = f.viewModel, gate = f.holdSession();
    await vm.connect({});
    vm.selectReference(referenceItem('first'));
    await settle();
    const replacement = referenceItem('second');
    vm.selectReference(replacement);
    let closing;
    if (action === 'cancel') vm.cancelGeneration();
    else if (action === 'deselect') vm.selectReference(replacement);
    else closing = vm.suspend();
    assert.equal(vm.state.isGenerationStarting, false);
    gate.resolve();
    await closing;
    await settle(); await settle();
    assert.equal(vm.state.isGenerationStarting, false);
    assert.equal(f.calls.sessions.length, 1);
    assert.equal(f.calls.starts.length, 0);
    assert.equal(vm.state.selectedReferenceId, '');
    assert.equal(vm.state.errorMessage, '');
    await vm.suspend();
  });
}

for (const action of ['failure', 'orientation change']) {
  test(`XLab ${action} ends loading after a replacement request starts`, async () => {
    const f = exampleFixture(), vm = f.viewModel;
    f.holdGeneration();
    await vm.connect({});
    vm.selectReference(referenceItem('first'));
    await settle();
    vm.selectReference(referenceItem('second'));
    await settle(); await settle();
    assert.equal(f.calls.starts.length, 2);
    assert.equal(vm.state.isGenerationStarting, true);
    if (action === 'failure') {
      f.stream.confirmation.reject(new f.XmaxError(f.Code.RTC_ERROR, 'replacement failed'));
    } else {
      f.rotateCamera();
    }
    await settle(); await settle();
    if (action !== 'failure') {
      // 转屏不走 change_condition：确认放行后自检漂移，终止错误方向任务并按最新方向重建。
      assert.equal(vm.state.isGenerationStarting, true);
      assert.equal(f.calls.updates.length, 0);
      f.stream.confirmation?.resolve();
      await settle();
      f.runSwitchDelay();
      await settle();
      assert.equal(f.calls.starts.length, 3);
      f.stream.confirmation?.resolve();
      await settle();
    }
    assert.equal(vm.state.isGenerationStarting, false);
    assert.equal(vm.state.selectedReferenceId, action === 'failure' ? '' : 'second');
    assert.equal(f.calls.sessions.length, 2);
    assert.equal(f.calls.starts.length, action === 'failure' ? 2 : 3);
    assert.equal(vm.state.errorMessage, action === 'failure' ? 'replacement failed' : '');
    await vm.suspend();
  });
}

test('XLab orientation changes leave idle local preview and disconnected media alone', async () => {
  const f = exampleFixture(), messages = [];
  f.viewModel.onMessage = message => messages.push(message);
  await f.viewModel.connect({});
  await settle();
  const local = f.viewModel.state.localVideoTrack;
  f.rotateCamera();
  assert.equal(f.calls.sessions.length, 0);
  f.viewModel.state.selectedCategoryId = 'free';
  f.viewModel.submitPrompt('test');
  await settle();
  f.viewModel.cancelGeneration();
  await settle();
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  f.rotateCamera();
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  assert.equal(f.viewModel.state.localVideoTrack, local);
  assert.deepEqual(f.calls.closed, ['session-1']);
  assert.deepEqual(messages, []);
  await f.viewModel.disconnect();
});

for (const phase of ['connecting', 'starting', 'generating']) {
  test(`XLab orientation change while ${phase} keeps the session and restores generation automatically`, async () => {
    const f = exampleFixture(), messages = [];
    f.viewModel.onMessage = message => messages.push(message);
    await f.viewModel.connect({});
    await settle();
    const local = f.viewModel.state.localVideoTrack;
    const gate = phase === 'connecting' ? f.holdSession() : null;
    if (phase === 'starting') f.holdGeneration();
    f.viewModel.state.selectedCategoryId = 'free';
    f.viewModel.submitPrompt('before rotation');
    await settle();
    assert.equal(f.manager.currentState.connectionState,
      phase === 'connecting' ? f.State.CONNECTING : phase === 'starting' ? f.State.CONNECTED : f.State.GENERATING);
    f.rotateCamera();
    f.rotateCamera(); // Rapid rotations must not duplicate the restart.
    gate?.resolve();
    await settle();
    if (phase === 'generating') {
      // 停止旧任务但保留会话，延时后以缓存条件自动重启；重建期间保持 loading。
      assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);
      assert.equal(f.viewModel.state.isGenerationStarting, true);
      assert.equal(f.calls.starts.length, 1);
      f.runSwitchDelay();
      await settle();
      assert.equal(f.calls.starts.length, 2);
      assert.equal(f.calls.starts.at(-1).context.prompt, 'before rotation');
    } else {
      f.stream.confirmation?.resolve();
      await settle();
      assert.equal(f.calls.starts.length, 1);
    }
    assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
    assert.equal(f.calls.sessions.length, 1);
    assert.deepEqual(f.calls.closed, []);
    assert.deepEqual(messages, []);
    assert.equal(f.viewModel.state.localVideoTrack, local);
    assert.equal(f.media.currentTrack, local);
    assert.ok(f.viewModel.state.remoteVideoTrack);
    assert.equal(f.viewModel.state.isGenerationStarting, false);
    assert.equal(f.viewModel.state.isMoxGenerationActive, false);
    assert.equal(f.viewModel.state.errorMessage, '');
    assert.equal(f.viewModel.state.selectedReferenceId, '');

    f.rotateCamera(); // 回到竖屏同样自动重启，不打断预览。
    await settle(); // 停止操作落地后才会调度重启定时器。
    if (f.manager.currentState.connectionState === f.State.CONNECTED) {
      assert.equal(f.viewModel.state.isGenerationStarting, true); // 重建期间保持 loading。
      f.runSwitchDelay();
      await settle();
      if (phase === 'starting') {
        // 确认等待期 loading 不中断，直到放行后进入 GENERATING。
        assert.equal(f.viewModel.state.isGenerationStarting, true);
      }
      f.stream.confirmation?.resolve(); // starting 阶段持有确认，需要手动放行重启后的任务。
      await settle();
    }
    assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
    assert.equal(f.viewModel.state.isGenerationStarting, false);
    assert.deepEqual(messages, []);
    await f.viewModel.disconnect();
  });
}

test('XLab cancellation after connecting closes the session and retains local preview', async () => {
  const f = exampleFixture();
  await f.viewModel.connect({});
  await settle();
  f.holdGeneration();
  f.viewModel.state.selectedCategoryId = 'mox';
  f.viewModel.startMoxGeneration();
  await settle();
  assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);
  assert.equal(f.calls.starts.length, 1);
  f.viewModel.cancelGeneration();
  await settle();
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  assert.deepEqual(f.calls.closed, ['session-1']);
  assert.equal(f.stream.currentGenerationTaskId, '');
  assert.equal(f.viewModel.state.remoteVideoTrack, null);
  assert.ok(f.viewModel.state.localVideoTrack);
  assert.equal(f.viewModel.state.errorMessage, '');
});


for (const phase of ['connecting', 'starting', 'generating']) {
  test(`SDK camera rotation while ${phase} keeps the connection without an app orientation listener`, async () => {
    const f = managerFixture(), states = [], errors = [];
    f.manager.setStateListener(state => { states.push(state); if (state.reason?.error) errors.push(state.reason.error); });
    const local = await f.create();
    const gate = phase === 'connecting' ? f.holdSession() : null;
    if (phase === 'starting') f.holdGeneration();
    const operation = phase === 'connecting' ? f.manager.connect(local) :
      f.manager.startGeneration(local, new f.Context('before rotation'));
    const result = outcome(operation);
    await settle();
    if (phase === 'generating') assert.ok((await result).value);
    const landscape = f.rotateCamera();
    if (phase === 'generating') {
      // 生成中：停止任务、保留连接并排队重启，状态短暂回到 CONNECTED。
      assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);
      assert.equal(f.manager.currentState.reason, f.Reason.ORIENTATION_CHANGED);
      assert.equal(f.calls.stops.filter(task => task.length > 0).length, 1);
      assert.deepEqual(f.calls.closed, []);
      f.rotateCamera(landscape); // 重启期间重复或同方向的转屏事件不叠加。
      assert.equal(f.calls.stops.filter(task => task.length > 0).length, 1);
      await settle(); // 停止操作落地后才会调度重启定时器。
      f.runSwitchDelay();
    }
    gate?.resolve();
    if (phase === 'starting') {
      // 确认等待期转屏不走 change_condition；确认放行后自检漂移，终止并按最新方向重建。
      assert.deepEqual(f.calls.updates, []);
      f.stream.confirmation?.resolve();
      assert.ok(!(await result).error, 'rotation must not cancel the in-flight operation');
      await settle();
      assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);
      f.runSwitchDelay();
      await settle();
      f.stream.confirmation?.resolve();
      await settle();
    } else {
      assert.ok(!(await result).error, 'rotation must not cancel the in-flight operation');
      await settle();
    }
    assert.equal(f.manager.currentState.connectionState,
      phase === 'connecting' ? f.State.CONNECTED : f.State.GENERATING);
    assert.deepEqual(f.calls.closed, []);
    assert.equal(f.calls.sessions.length, 1);
    assert.equal(f.calls.starts.length, phase === 'connecting' ? 0 : 2);
    assert.deepEqual(errors, []);
    assert.equal(states.filter(state => state.connectionState === f.State.DISCONNECTING).length, 0);
    assert.equal(f.media.currentTrack, local.videoTrack);
    if (phase !== 'connecting') {
      assert.equal(f.calls.starts.at(-1).context.prompt, 'before rotation');
      assert.deepEqual(f.calls.starts.at(-1).format, landscape);
      assert.equal(f.manager.currentState.reason, undefined);
      assert.equal(f.media.interactionTask, f.stream.currentGenerationTaskId);
    }

    if (phase === 'connecting') {
      await f.manager.startGeneration(local, new f.Context('after rotation'));
      assert.deepEqual(f.calls.starts.at(-1).format, landscape);
    }
    await f.manager.disconnect();
    assert.equal(f.manager.currentState.connectionState, f.State.READY);
    assert.equal(f.manager.currentState.reason, f.Reason.NORMAL);
    assert.deepEqual(f.calls.closed, ['session-1']);
    await f.manager.close();
  });
}

test('SDK rapid double rotation restarts generation once with the latest capture format', async () => {
  const f = managerFixture(), errors = [];
  f.manager.setStateListener(state => { if (state.reason?.error) errors.push(state.reason.error); });
  const local = await f.create();
  await f.manager.startGeneration(local, new f.Context('double rotation'));
  const landscape = f.rotateCamera();
  assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);
  assert.equal(f.manager.currentState.reason, f.Reason.ORIENTATION_CHANGED);
  const portrait = f.rotateCamera(); // 延时窗口内转回竖屏：不叠加第二次重启。
  assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);
  assert.equal(f.calls.stops.filter(task => task.length > 0).length, 1);
  assert.equal(f.calls.starts.length, 1);
  await settle(); // 停止操作落地后才会调度重启定时器。
  f.runSwitchDelay();
  await settle();
  // 唯一一次重启用最新的竖屏规格和缓存条件。
  assert.equal(f.calls.starts.length, 2);
  assert.deepEqual(f.calls.starts.at(-1).format, portrait);
  assert.equal(f.calls.starts.at(-1).context.prompt, 'double rotation');
  assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
  assert.equal(f.manager.currentState.reason, undefined);
  assert.deepEqual(f.calls.closed, []);
  assert.equal(f.calls.sessions.length, 1);
  assert.deepEqual(errors, []);

  // 重启完成后再次转屏仍可正常工作。
  const again = f.rotateCamera();
  assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);
  await settle(); // 停止操作落地后才会调度重启定时器。
  f.runSwitchDelay();
  await settle();
  assert.equal(f.calls.starts.length, 3);
  assert.deepEqual(f.calls.starts.at(-1).format, again);
  assert.deepEqual(f.calls.starts.at(-1).format, landscape);
  assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
  assert.deepEqual(f.calls.closed, []);
  await f.manager.close();
});

test('SDK rotation during the restart confirmation terminates and resubmits with the latest orientation', async () => {
  const f = managerFixture();
  const local = await f.create();
  await f.manager.startGeneration(local, new f.Context('test'));
  f.rotateCamera();
  await settle(); // 停止操作落地后才会调度重启定时器。
  f.holdGeneration();
  f.runSwitchDelay();
  await settle();
  // 重启的新任务已发出但未确认，此时仍在 CONNECTED。
  assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);
  assert.equal(f.calls.starts.length, 2);
  const portrait = f.rotateCamera(); // 确认等待期转回竖屏：change_condition 不能改尺寸，确认后再次终止重建。
  assert.equal(f.calls.stops.filter(task => task.length > 0).length, 1);
  assert.equal(f.calls.starts.length, 2);
  assert.deepEqual(f.calls.updates, []);
  f.stream.confirmation?.resolve();
  await settle();
  // 方向漂移仍存在：终止刚确认的横屏任务，再次回到 CONNECTED 排队重启。
  assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);
  assert.equal(f.calls.stops.filter(task => task.length > 0).length, 2);
  f.runSwitchDelay();
  await settle();
  assert.equal(f.calls.starts.length, 3);
  f.stream.confirmation?.resolve();
  await settle();
  // 最终任务使用最新的竖屏规格，会话与连接始终保留。
  assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
  assert.deepEqual(f.calls.starts.at(-1).format, portrait);
  assert.deepEqual(f.calls.closed, []);
  assert.equal(f.calls.sessions.length, 1);
  await f.manager.close();
});

test('SDK startGeneration during the orientation restart window applies immediately and supersedes the pending restart', async () => {
  const f = managerFixture(), errors = [];
  f.manager.setStateListener(state => { if (state.reason?.error) errors.push(state.reason.error); });
  const local = await f.create();
  await f.manager.startGeneration(local, new f.Context('original'));
  const landscape = f.rotateCamera();
  assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);
  assert.equal(f.manager.currentState.reason, f.Reason.ORIENTATION_CHANGED);
  await settle(); // 停止操作在微任务内落地；真实点击是宏任务，必然在此之后。
  // 重启等待窗口不占用协调器：用户提交新条件立即按最新方向生效，不被拒绝。
  await f.manager.startGeneration(new f.Context('new reference'));
  assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
  assert.equal(f.calls.starts.length, 2);
  assert.deepEqual(f.calls.starts.at(-1).format, landscape);
  assert.equal(f.calls.starts.at(-1).context.prompt, 'new reference');
  // 挂起的重启接力时漂移已消失，自动作废，不会用旧条件覆盖用户的提交。
  f.runSwitchDelay();
  await settle();
  assert.equal(f.calls.starts.length, 2);
  assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
  assert.deepEqual(f.calls.closed, []);
  assert.equal(f.calls.sessions.length, 1);
  assert.deepEqual(errors, []);
  await f.manager.close();
});

test('XLab reference selection during the orientation restart window applies without a conflict error', async () => {
  const f = exampleFixture(), vm = f.viewModel;
  await vm.connect({});
  await settle();
  vm.state.selectedCategoryId = 'free';
  vm.submitPrompt('before rotation');
  await settle();
  assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
  f.rotateCamera();
  assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);
  await settle(); // 停止操作在微任务内落地；真实点击是宏任务，必然在此之后。
  // 重启等待窗口内选择参考图：走正常生成流程立即生效，不再报并发冲突。
  vm.selectReference(referenceItem('chosen'));
  await settle(); await settle();
  assert.equal(vm.state.errorMessage, '');
  assert.equal(vm.state.selectedReferenceId, 'chosen');
  assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
  assert.equal(f.calls.starts.length, 2);
  assert.equal(f.calls.starts.at(-1).context.referencePath, 'https://example.invalid/chosen.jpg');
  // 挂起的转屏重启已作废：定时器触发后不再用缓存条件重复 start。
  f.runSwitchDelay();
  await settle();
  assert.equal(f.calls.starts.length, 2);
  assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
  assert.equal(vm.state.isGenerationStarting, false);
  await vm.disconnect();
});

test('SDK startGeneration during the orientation restart confirmation joins the pending task via change_condition', async () => {
  const f = managerFixture(), errors = [];
  f.manager.setStateListener(state => { if (state.reason?.error) errors.push(state.reason.error); });
  const local = await f.create();
  await f.manager.startGeneration(local, new f.Context('original'));
  const landscape = f.rotateCamera();
  await settle();
  f.holdGeneration();
  f.runSwitchDelay();
  await settle();
  // 重启的 start 已发出、等待确认，仍在 CONNECTED。
  assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);
  assert.equal(f.calls.starts.length, 2);
  // 确认等待期用户提交新条件：不重发 start，经 change_condition 并入当前重启任务。
  const joined = f.manager.startGeneration(new f.Context('new reference'));
  await settle();
  assert.equal(f.calls.starts.length, 2);
  assert.equal(f.calls.updates.length, 1);
  assert.equal(f.calls.updates[0].context.prompt, 'new reference');
  assert.deepEqual(f.calls.updates[0].format, landscape);
  assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);
  // 确认放行后，调用随重启一起完成，后续重建也使用并入后的缓存条件。
  f.stream.confirmation?.resolve();
  await joined;
  await settle();
  assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
  assert.deepEqual(errors, []);
  f.rotateCamera();
  await settle();
  f.runSwitchDelay();
  await settle();
  assert.equal(f.calls.starts.length, 3);
  assert.equal(f.calls.starts.at(-1).context.prompt, 'new reference');
  f.stream.confirmation?.resolve();
  await settle();
  assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
  assert.deepEqual(f.calls.closed, []);
  assert.equal(f.calls.sessions.length, 1);
  await f.manager.close();
});

test('XLab reference selection during the orientation restart confirmation joins without a conflict error', async () => {
  const f = exampleFixture(), vm = f.viewModel;
  await vm.connect({});
  await settle();
  vm.state.selectedCategoryId = 'free';
  vm.submitPrompt('before rotation');
  await settle();
  assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
  f.rotateCamera();
  await settle();
  f.holdGeneration();
  f.runSwitchDelay();
  await settle();
  assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);
  // 重启确认等待期选择参考图：经 change_condition 并入重启任务，不报并发冲突。
  vm.selectReference(referenceItem('chosen'));
  await settle(); await settle();
  assert.equal(vm.state.errorMessage, '');
  assert.equal(f.calls.starts.length, 2);
  assert.equal(f.calls.updates.length, 1);
  assert.equal(f.calls.updates[0].context.referencePath, 'https://example.invalid/chosen.jpg');
  // 确认放行后进入 GENERATING，参考图选择生效。
  f.stream.confirmation?.resolve();
  await settle(); await settle();
  assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
  assert.equal(vm.state.selectedReferenceId, 'chosen');
  assert.equal(vm.state.isGenerationStarting, false);
  assert.ok(vm.state.remoteVideoTrack);
  await vm.disconnect();
});

test('SDK camera rotation keeps CONNECTED sessions and leaves local preview available', async () => {
  const f = managerFixture();
  const local = await f.create();
  f.rotateCamera();
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  await f.manager.connect(local);
  const portrait = f.rotateCamera();
  assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);
  await settle();
  assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);
  assert.deepEqual(f.calls.closed, []);
  await f.manager.startGeneration(local, new f.Context('test'));
  assert.deepEqual(f.calls.starts.at(-1).format, portrait);
  f.rotateCamera(portrait); // 同方向重复帧不触发重启。
  assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
  assert.equal(f.calls.starts.length, 1);
  f.rotateCamera(); // 生成中翻转：保留连接自动重启。
  assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);
  await settle(); // 停止操作落地后才会调度重启定时器。
  f.runSwitchDelay();
  await settle();
  assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
  assert.equal(f.calls.starts.length, 2);
  assert.deepEqual(f.calls.closed, []);
  await f.manager.disconnect();
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  assert.deepEqual(f.calls.closed, ['session-1']);
  await f.manager.close();
});

test('generation synchronizes camera dimensions before connecting without cancelling its own operation', async () => {
  const f = managerFixture(), local = await f.create();
  const landscape = new f.Format(1920, 1080, 30);
  f.media.updateCameraOrientation = () => f.rotateCamera(landscape);
  await f.manager.startGeneration(local, new f.Context('current orientation'));
  assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
  assert.deepEqual(f.calls.starts[0].format, landscape);
  assert.deepEqual(f.calls.closed, []);
  await f.manager.close();
});

test('camera applies oriented output before connect and rejects queued frames from the old dimensions', async () => {
  const calls = [], events = [], errors = [];
  const kit = createCameraKitFixture(calls, { landscape: true });
  const load = loadEts({ ...platform, '@kit.CameraKit': kit.kit, CameraFrameOutput: kit.frameOutput,
    PermissionManager: { PermissionManager: class { async ensureCameraPermission() {} } } });
  const { CameraController } = load('media/camera/CameraController.ets');
  const { RealtimeVideoFormat: Format } = load('service/realtime/RealtimeVideoFormat.ets');
  const { MediaService } = load('service/media/MediaService.ets');
  const { RealtimeModels } = load('service/realtime/RealtimeModel.ets');
  const { VideoRenderRegistry: Registry } = load('rendering/video/VideoRenderRegistry.ets');
  const camera = new CameraController({}, {
    useExternalVideoSource() {}, configureLocalVideoMirror() {}, renderLibraryName: () => 'rtc',
    bindLocalVideo() {}, unbindLocalVideo() {}
  }, {
    setVideoEncoderConfig: format => events.push(['encode', format.width, format.height]),
    pushLocalVideoFrame: frame => events.push(['push', frame.format.width, frame.format.height])
  }, new MediaService(RealtimeModels.realtime('x2.0-sla')), error => errors.push(error),
  format => events.push(['signal', format.width, format.height]));
  const local = await camera.createLocalCameraStream(new Format(1080, 1920, 30), 'front');
  try {
    assert.deepEqual(local.videoTrack.videoFormat, { width: 1920, height: 1080, fps: 30 });
    const observed = [];
    Registry.attach(local.videoTrack, 'view', 'fit', () => {}, () => {}, undefined,
      () => observed.push(local.videoTrack.videoFormat));
    events.length = 0;
    kit.outputs[0].currentVideoFormat = new Format(1080, 1920, 30);
    kit.emit({ format: { width: 1920, height: 1080 } });
    assert.deepEqual(events, []);
    kit.emit({ format: { width: 1080, height: 1920 } });
    assert.deepEqual(events, [['encode', 1080, 1920], ['signal', 1080, 1920], ['push', 1080, 1920]]);
    assert.equal(observed.length, 2);
    assert.equal(observed[1].width, 1080);
    kit.emit({ format: { width: 1080, height: 1920 } });
    assert.equal(events.length, 4); // No duplicate encoding/signaling for subsequent frames.
    events.length = 0;
    camera.updateOrientation(); // Read the current display before another frame is delivered.
    assert.deepEqual(events, [['encode', 1920, 1080], ['signal', 1920, 1080]]);
    assert.equal(local.videoTrack.videoFormat.width, 1920);
    assert.equal(observed.at(-1).width, 1920);
    camera.updateOrientation();
    assert.equal(events.length, 2);
    assert.deepEqual(errors, []);
  } finally {
    await camera.stopLocalCameraStream();
  }
});

test('camera exposes PREPARING until preview readiness and ignores old ready notifications after close/replacement/connect', async () => {
  const f = managerFixture(), states = [];
  f.holdPreview();
  f.manager.setStateListener(state => states.push(state));
  assert.equal(typeof f.manager.setErrorListener, 'undefined');
  assert.equal(typeof f.manager.setCameraPreviewReadyListener, 'undefined');
  const first = await f.create();
  assert.equal(f.manager.currentState.connectionState, f.State.PREPARING);
  const oldReady = f.media.readyHandler;
  await f.manager.close();
  oldReady();
  assert.equal(f.manager.currentState.connectionState, f.State.IDLE);
  const second = await f.create();
  assert.notEqual(first.videoTrack, second.videoTrack);
  oldReady();
  assert.equal(f.manager.currentState.connectionState, f.State.PREPARING);
  const ready = f.media.readyHandler;
  ready(); ready();
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  assert.equal(states.filter(state => state.connectionState === f.State.READY).length, 1);
  const gate = f.holdSession(), connecting = f.manager.connect(second);
  ready();
  assert.equal(f.manager.currentState.connectionState, f.State.CONNECTING);
  gate.resolve(); await connecting;
  ready();
  assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);
  await f.manager.close();
});

test('image and video preparation enter READY without a camera callback, stopping local media returns IDLE', async () => {
  for (const source of ['Image', 'Video']) {
    const f = managerFixture(), states = [];
    f.media[`createLocal${source}Stream`] = async () => {
      f.media.currentTrack = new f.Track('file', new f.Format(1024, 1920, 30));
      return new f.MediaStream('local', f.media.currentTrack);
    };
    f.media[`stopLocal${source}Stream`] = async () => { f.media.currentTrack = null; };
    f.manager.setStateListener(state => states.push(state.connectionState));
    await f.manager[`createLocal${source}Stream`]('input');
    await f.manager[`stopLocal${source}Stream`]();
    assert.deepEqual(states, [f.State.IDLE, f.State.PREPARING, f.State.READY, f.State.IDLE]);
    await f.manager.close();
  }
});

for (const source of ['Camera', 'Image', 'Video']) {
  test(`${source} preparation failure returns directly to IDLE without reason and permits immediate retry`, async () => {
    const f = managerFixture(), states = [];
    const original = new f.XmaxError(f.Code.MEDIA_ERROR, 'preparation failed', 123, 403);
    const method = `createLocal${source}Stream`;
    f.media[method] = async () => { throw original; };
    let retry, preparing = false;
    f.manager.setStateListener(state => {
      states.push(state);
      if (state.connectionState === f.State.PREPARING) preparing = true;
      if (preparing && state.connectionState === f.State.IDLE && !retry) {
        f.media[method] = async () => {
          f.media.currentTrack = new f.Track('local', new f.Format(1024, 1920, 30), 'front');
          return new f.MediaStream('local', f.media.currentTrack);
        };
        retry = f.manager[method]('input');
      }
    });
    await assert.rejects(f.manager[method]('input'), error => error === original);
    await retry;
    assert.deepEqual(states.map(state => state.connectionState), [
      f.State.IDLE, f.State.PREPARING, f.State.IDLE, f.State.PREPARING, f.State.READY
    ]);
    assert.ok(states.every(state => state.reason === undefined));
    assert.deepEqual(f.calls.closed, []);
    await f.manager.close();
  });

  test(`${source} post-preparation failure still cleans up the created media and reports failure`, async () => {
    const f = managerFixture(), states = [];
    f.media[`createLocal${source}Stream`] = async () => {
      f.media.currentTrack = new f.Track('local', new f.Format(1024, 1920, 30), 'front');
      return new f.MediaStream('local', f.media.currentTrack);
    };
    const original = new f.XmaxError(f.Code.RTC_ERROR, 'volume configuration failed');
    f.stream.setRemoteAudioVolume = () => { throw original; };
    f.manager.setStateListener(state => states.push(state));
    await assert.rejects(f.manager[`createLocal${source}Stream`]('input'), error => error === original);
    assert.deepEqual(states.map(state => state.connectionState), [
      f.State.IDLE, f.State.PREPARING, f.State.DISCONNECTING, f.State.IDLE
    ]);
    assert.equal(f.manager.currentState.reason.error, original);
    assert.equal(f.media.currentTrack, null);
  });
}

test('local runtime errors clean up media and connection and publish one original error through state only', async () => {
  const f = managerFixture(), states = [];
  const local = await f.create();
  await f.manager.startGeneration(local, new f.Context('test'));
  f.manager.setStateListener(state => states.push(state));
  const original = new f.XmaxError(f.Code.MEDIA_ERROR, 'capture failed', 456, 500);
  f.media.onError(original);
  await settle();
  assert.equal(f.media.currentTrack, null);
  assert.equal(f.manager.currentState.connectionState, f.State.IDLE);
  assert.equal(f.manager.currentState.reason.error, original);
  assert.deepEqual(f.calls.closed, ['session-1']);
  assert.equal(states.filter(state => state.reason?.error === original).length, 1);
  assert.equal(f.stream.currentGenerationTaskId, '');
});

test('a READY failure listener can immediately start a fresh connection without stale cleanup cancelling it', async () => {
  const f = managerFixture(), local = await f.create();
  await f.manager.startGeneration(local, new f.Context('first'));
  let restart;
  const original = new f.XmaxError(f.Code.SESSION_ERROR, 'heartbeat lost');
  f.manager.setStateListener(state => {
    if (state.reason?.error === original) {
      restart = f.manager.startGeneration(local, new f.Context('retry'));
    }
  });
  await f.api.heartbeat(original);
  await restart;
  assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
  assert.equal(f.manager.currentState.reason, undefined);
  assert.equal(f.calls.starts.at(-1).context.prompt, 'retry');
  assert.deepEqual(f.calls.closed, ['session-1']);
  await f.manager.close();
});

test('XLab loading and failures are driven exclusively by SDK states', async () => {
  const f = exampleFixture();
  f.holdPreview();
  await f.viewModel.connect({});
  assert.equal(f.viewModel.state.connectionState, f.State.PREPARING);
  assert.equal(f.viewModel.state.isLocalPreviewLoading, true);
  assert.ok(f.viewModel.state.localVideoTrack);
  f.media.readyHandler();
  assert.equal(f.viewModel.state.connectionState, f.State.READY);
  assert.equal(f.viewModel.state.isLocalPreviewLoading, false);
  const original = new f.XmaxError(f.Code.MEDIA_ERROR, 'camera stopped');
  f.media.onError(original);
  await settle();
  assert.equal(f.viewModel.state.connectionState, f.State.IDLE);
  assert.equal(f.viewModel.state.localVideoTrack, null);
  assert.equal(f.viewModel.state.errorMessage, original.message);
  await f.viewModel.disconnect();
});

test('invalid preflight calls and condition update failures preserve an active generation and original errors', async () => {
  const f = managerFixture(), local = await f.create();
  await f.manager.startGeneration(local, new f.Context('first'));
  const task = f.manager.currentState.taskId;
  await assert.rejects(f.manager.createLocalCameraStream(), { code: 'INVALID_CONFIGURATION' });
  await assert.rejects(f.manager.connect(local), { code: 'INVALID_CONFIGURATION' });
  await assert.rejects(f.manager.stopLocalCameraStream(), { code: 'INVALID_CONFIGURATION' });
  const original = new f.XmaxError(f.Code.RTC_ERROR, 'update failed', 1003, 503);
  f.stream.updateGeneration = () => { throw original; };
  await assert.rejects(f.manager.startGeneration(new f.Context('next')), error => error === original);
  assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
  assert.equal(f.manager.currentState.taskId, task);
  assert.equal(f.manager.currentState.reason, undefined);
  assert.deepEqual(f.calls.closed, []);
  assert.equal(f.media.currentTrack, local.videoTrack);
  await f.manager.close();
});

test('missing generation context preserves connection, but failure after startup begins closes it regardless of error code', async () => {
  const f = managerFixture(), local = await f.create();
  await f.manager.connect(local);
  await assert.rejects(f.manager.startGeneration(), { code: 'INVALID_CONFIGURATION' });
  assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);
  assert.deepEqual(f.calls.closed, []);
  const original = new f.XmaxError(f.Code.INVALID_CONFIGURATION, 'RTC rejected start', 123, 500);
  f.stream.beginGeneration = () => { throw original; };
  await assert.rejects(f.manager.startGeneration(new f.Context('start')), error => error === original);
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  assert.equal(f.manager.currentState.reason.error, original);
  assert.equal(f.media.currentTrack, local.videoTrack);
  assert.deepEqual(f.calls.closed, ['session-1']);
  await f.manager.close();
});

test('local runtime failures use media cleanup scope even for former validation-category errors', async () => {
  const f = managerFixture();
  await f.create();
  const original = new f.XmaxError(f.Code.INVALID_CONFIGURATION, 'invalid captured frame');
  f.media.onError(original);
  await settle();
  assert.equal(f.media.currentTrack, null);
  assert.equal(f.manager.currentState.connectionState, f.State.IDLE);
  assert.equal(f.manager.currentState.reason.error, original);
});


test('volume getters expose saved values and source creation selects the remote default before ready', async () => {
  const f = managerFixture();
  assert.equal(f.manager.localAudioVolume, 0.45);
  assert.equal(f.manager.remoteAudioVolume, 1);
  await f.manager.setLocalAudioVolume(0.23);
  for (const [method, args, expected] of [
    ['createLocalCameraStream', [], 0],
    ['createLocalImageStream', ['image.png'], 0],
    ['createLocalVideoStream', ['video.mp4'], 1]
  ]) {
    if (method !== 'createLocalCameraStream') {
      f.media[method] = async () => new f.MediaStream('local');
    }
    await f.manager.setRemoteAudioVolume(0.67);
    const readyVolumes = [];
    f.manager.setStateListener(state => {
      if (state.connectionState === f.State.READY) readyVolumes.push(f.manager.remoteAudioVolume);
    });
    await f.manager[method](...args);
    assert.equal(f.manager.remoteAudioVolume, expected);
    assert.deepEqual(readyVolumes, [expected]);
    assert.equal(f.manager.localAudioVolume, 0.23);
    if (method === 'createLocalCameraStream') {
      await f.manager.setRemoteAudioVolume(0.4);
      await f.manager.switchCamera();
      assert.equal(f.manager.remoteAudioVolume, 0.4);
    }
    await f.manager.close();
  }
});

for (const method of ['createLocalCameraStream', 'createLocalImageStream', 'createLocalVideoStream']) {
  test(`${method} does not reset remote volume when preparation fails or is cancelled`, async () => {
    for (const cancelled of [false, true]) {
      const f = managerFixture(), gate = deferred();
      await f.manager.setRemoteAudioVolume(0.6);
      f.media[method] = async () => { await gate.promise; return new f.MediaStream('local'); };
      const preparing = outcome(f.manager[method]());
      await settle();
      if (cancelled) {
        const closing = f.manager.close();
        gate.resolve();
        await closing;
      } else {
        gate.reject(new f.XmaxError(f.Code.MEDIA_ERROR, 'prepare failed'));
      }
      assert.ok((await preparing).error);
      assert.equal(f.manager.remoteAudioVolume, 0.6);
    }
  });
}

test('XLab restores video volume after SDK creation defaults, including mute and file replacement', async () => {
  const f = exampleFixture(), vm = f.viewModel;
  f.media.createLocalVideoStream = async () => new f.MediaStream('local');
  f.media.stopLocalVideoStream = async () => {};
  await vm.setRemoteAudioVolume(0.7);
  await vm.connect({}, 'video.mp4');
  assert.equal(f.manager.remoteAudioVolume, 0.7);
  await vm.setAudioMuted(true);
  await vm.changeLocalVideo('next.mp4');
  assert.equal(f.manager.remoteAudioVolume, 0);
  await vm.setAudioMuted(false);
  assert.equal(f.manager.remoteAudioVolume, 0.7);
  await vm.suspend();
  await vm.resume({});
  assert.equal(f.manager.remoteAudioVolume, 0.7);
});

for (const state of ['CONNECTING', 'CONNECTED', 'GENERATING']) {
  test(`disconnect from ${state} preserves local preview and exposes the supplied reason after cleanup`, async () => {
    for (const kind of ['default', 'orientation', 'failure']) {
      const f = managerFixture(), local = await f.create(), states = [];
      const original = new f.XmaxError(f.Code.MEDIA_ERROR, 'host requested disconnect', 123, 503);
      const reason = kind === 'default' ? undefined : kind === 'orientation' ?
        f.Reason.ORIENTATION_CHANGED : f.Reason.failure(original);
      let running, gate;
      if (state === 'CONNECTING') {
        gate = f.holdSession();
        running = outcome(f.manager.startGeneration(local, new f.Context('test')));
        await settle();
      } else if (state === 'CONNECTED') {
        await f.manager.connect(local);
      } else {
        await f.manager.startGeneration(local, new f.Context('test'));
      }
      assert.equal(f.manager.currentState.connectionState, f.State[state]);
      f.manager.setStateListener(value => states.push(value));
      const disconnecting = f.manager.disconnect(reason);
      assert.equal(f.manager.currentState.connectionState, f.State.DISCONNECTING);
      assert.equal(f.manager.currentState.reason, undefined);
      gate?.resolve();
      await disconnecting;
      if (running) assert.equal((await running).error.code, f.Code.CANCELLED);
      assert.equal(f.manager.currentState.connectionState, f.State.READY);
      assert.equal(f.manager.currentState.reason, reason ?? f.Reason.NORMAL);
      if (kind === 'failure') assert.equal(f.manager.currentState.reason.error, original);
      assert.equal(f.media.currentTrack, local.videoTrack);
      assert.equal(f.calls.audio.at(-1), true);
      assert.deepEqual(f.calls.closed, ['session-1']);
      assert.equal(f.stream.currentGenerationTaskId, '');
      const count = states.length;
      await f.manager.disconnect(f.Reason.NORMAL);
      assert.equal(states.length, count);
      await f.manager.startGeneration(local, new f.Context('next'));
      assert.equal(f.manager.currentState.reason, undefined);
      await f.manager.close();
    }
  });
}

test('disconnect with a reason does not interrupt unconnected local creation or change its state', async () => {
  const f = managerFixture();
  const idle = f.manager.currentState;
  await f.manager.disconnect(f.Reason.ORIENTATION_CHANGED);
  assert.equal(f.manager.currentState, idle);
  const gate = deferred(), create = f.media.createLocalCameraStream.bind(f.media);
  f.media.createLocalCameraStream = async (...args) => { await gate.promise; return create(...args); };
  const creating = f.create();
  await settle();
  assert.equal(f.manager.currentState.connectionState, f.State.PREPARING);
  const preparing = f.manager.currentState;
  await f.manager.disconnect(f.Reason.ORIENTATION_CHANGED);
  assert.equal(f.manager.currentState, preparing);
  gate.resolve();
  await creating;
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  const ready = f.manager.currentState;
  await f.manager.disconnect(f.Reason.ORIENTATION_CHANGED);
  assert.equal(f.manager.currentState, ready);
  assert.deepEqual(f.calls.closed, []);
  await f.manager.close();
});

test('disconnect cancels an active camera switch even while the public state is READY', async () => {
  const f = managerFixture(), local = await f.create(), gate = deferred();
  f.media.switchCamera = async () => { await gate.promise; return local; };
  const switching = outcome(f.manager.switchCamera());
  const disconnecting = f.manager.disconnect(f.Reason.ORIENTATION_CHANGED);
  assert.equal(f.manager.currentState.connectionState, f.State.DISCONNECTING);
  gate.resolve();
  await disconnecting;
  assert.equal((await switching).error.code, f.Code.CANCELLED);
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  assert.equal(f.manager.currentState.reason, f.Reason.ORIENTATION_CHANGED);
  assert.equal(f.media.currentTrack, local.videoTrack);
  await f.manager.close();
});

test('concurrent disconnect and close keep the first reason despite a late heartbeat error', async () => {
  const f = managerFixture(), local = await f.create(), gate = deferred();
  await f.manager.startGeneration(local, new f.Context('test'));
  const disconnect = f.stream.disconnect.bind(f.stream);
  f.stream.disconnect = async () => { await gate.promise; return disconnect(); };
  const disconnecting = f.manager.disconnect(f.Reason.ORIENTATION_CHANGED);
  assert.equal(f.manager.disconnect(), disconnecting);
  assert.equal(f.manager.close(), disconnecting);
  await f.api.heartbeat(new f.XmaxError(f.Code.SESSION_ERROR, 'late heartbeat failure'));
  gate.resolve();
  await disconnecting;
  assert.equal(f.manager.currentState.connectionState, f.State.IDLE);
  assert.equal(f.manager.currentState.reason, f.Reason.ORIENTATION_CHANGED);
  assert.equal(f.media.currentTrack, null);
});

test('a local media failure during explicit disconnect still releases media and reports the original error', async () => {
  const f = managerFixture(), local = await f.create(), gate = deferred();
  await f.manager.startGeneration(local, new f.Context('test'));
  const disconnect = f.stream.disconnect.bind(f.stream);
  f.stream.disconnect = async () => { await gate.promise; return disconnect(); };
  const disconnecting = f.manager.disconnect(f.Reason.ORIENTATION_CHANGED);
  const original = new f.XmaxError(f.Code.MEDIA_ERROR, 'camera failed during disconnect');
  f.media.onError(original);
  gate.resolve();
  await disconnecting;
  assert.equal(f.manager.currentState.connectionState, f.State.IDLE);
  assert.equal(f.manager.currentState.reason.error, original);
  assert.equal(f.media.currentTrack, null);
});

function enableMicrophoneFixture(f) {
  const events = [];
  const create = f.media.createLocalCameraStream.bind(f.media);
  f.media.createLocalCameraStream = async (format, position, useMicrophone) => {
    f.media.hasAudio = useMicrophone;
    events.push(['prepare', useMicrophone]);
    return create(format, position);
  };
  f.media.startMicrophoneCapture = () => { events.push(['start']); f.media.capturing = true; };
  f.media.stopMicrophoneCapture = () => { events.push(['stop']); f.media.capturing = false; };
  const connect = f.stream.connect.bind(f.stream);
  f.stream.connect = async (connection, audio, ensure) => {
    assert.equal(f.media.capturing, true);
    events.push(['connect', audio]);
    return connect(connection, audio, ensure);
  };
  return events;
}

test('camera useMicrophone reaches connection audio publication and stops on disconnect/restarts on reconnect', async () => {
  const f = managerFixture(), events = enableMicrophoneFixture(f);
  const local = await f.manager.createLocalCameraStream(undefined, undefined, true);
  assert.deepEqual(events, [['prepare', true]]);
  await f.manager.startGeneration(local, new f.Context('first'));
  assert.deepEqual(events, [['prepare', true], ['start'], ['connect', true]]);
  await f.manager.disconnect();
  assert.equal(f.media.capturing, false);
  assert.ok(f.media.currentTrack);
  await f.manager.startGeneration(local, new f.Context('second'));
  assert.deepEqual(events.slice(-3), [['stop'], ['start'], ['connect', true]]);
  await f.manager.close();
  assert.equal(f.media.capturing, false);
});

test('microphone start failure rejects connection with the original error and stops partial capture', async () => {
  const f = managerFixture();
  enableMicrophoneFixture(f);
  const local = await f.manager.createLocalCameraStream(undefined, undefined, true);
  const original = new f.XmaxError(f.Code.RTC_ERROR, 'microphone startup failed');
  f.media.startMicrophoneCapture = () => { f.media.capturing = true; throw original; };
  await assert.rejects(f.manager.startGeneration(local, new f.Context('test')), error => error === original);
  assert.equal(f.media.capturing, false);
  assert.deepEqual(f.calls.sessions, []);
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  assert.equal(f.manager.currentState.reason.error, original);
  await f.manager.close();
});

for (const action of ['disconnect', 'close', 'failure']) {
  test(`microphone stops when a pending connection ends with ${action}`, async () => {
    const f = managerFixture();
    enableMicrophoneFixture(f);
    const local = await f.manager.createLocalCameraStream(undefined, undefined, true);
    const gate = f.holdSession();
    const running = outcome(f.manager.startGeneration(local, new f.Context('test')));
    await settle();
    assert.equal(f.media.capturing, true);
    let stopping;
    if (action === 'failure') {
      gate.reject(new f.XmaxError(f.Code.NETWORK_ERROR, 'session failed'));
    } else {
      stopping = f.manager[action]();
      gate.resolve();
    }
    assert.ok((await running).error);
    await stopping;
    assert.equal(f.media.capturing, false);
    assert.equal(f.calls.starts.length, 0);
    await f.manager.close();
  });
}


test('XLab camera volume menu reads SDK defaults and preserves the selected volume after suspension', async () => {
  const f = exampleFixture(), vm = f.viewModel;
  await vm.connect({});
  vm.refreshAudioVolumes();
  assert.equal(vm.state.remoteAudioVolume, 0);
  await vm.setRemoteAudioVolume(0.65);
  assert.equal(f.manager.remoteAudioVolume, 0.65);
  await vm.suspend();
  await vm.resume({});
  vm.refreshAudioVolumes();
  assert.equal(vm.state.remoteAudioVolume, 0.65);
  assert.equal(f.manager.remoteAudioVolume, 0.65);
  await f.manager.setRemoteAudioVolume(0.3);
  vm.refreshAudioVolumes();
  assert.equal(vm.state.remoteAudioVolume, 0.3);
  await vm.setAudioMuted(true);
  vm.refreshAudioVolumes();
  assert.equal(vm.state.remoteAudioVolume, 0.3);
  await vm.setAudioMuted(false);
  assert.equal(f.manager.remoteAudioVolume, 0.3);
  await vm.suspend();
});

test('XLab follows camera/video defaults when no remote volume has been selected', async () => {
  const f = exampleFixture(), vm = f.viewModel;
  await vm.connect({});
  assert.equal(vm.state.remoteAudioVolume, 0);
  await vm.suspend();
  f.media.createLocalVideoStream = async () => new f.MediaStream('local');
  await vm.connect({}, 'video.mp4');
  assert.equal(vm.state.remoteAudioVolume, 1);
  assert.equal(f.manager.remoteAudioVolume, 1);
  await vm.suspend();
});

for (const phase of ['CONNECTING', 'CONNECTED', 'GENERATING']) {
  test(`XLab cancellation in ${phase} disconnects microphone and permits a fresh generation`, async () => {
    const f = exampleFixture(), vm = f.viewModel;
    enableMicrophoneFixture(f);
    await vm.connect({});
    const localTrack = vm.state.localVideoTrack;
    const sessionGate = phase === 'CONNECTING' ? f.holdSession() : null;
    if (phase === 'CONNECTED') f.holdGeneration();
    vm.state.selectedCategoryId = 'free';
    vm.submitPrompt('first');
    await settle();
    assert.equal(f.manager.currentState.connectionState, f.State[phase]);
    assert.equal(f.media.capturing, true);
    const previousConfirmation = f.stream.confirmation;
    vm.cancelGeneration();
    await settle();
    if (sessionGate) {
      assert.equal(f.manager.currentState.connectionState, f.State.DISCONNECTING);
      sessionGate.resolve();
    }
    await settle();
    previousConfirmation?.resolve();
    await settle();
    assert.equal(f.manager.currentState.connectionState, f.State.READY);
    assert.equal(f.media.capturing, false);
    assert.equal(vm.state.localVideoTrack, localTrack);
    assert.equal(vm.state.remoteVideoTrack, null);
    assert.equal(vm.state.isGenerationStarting, false);
    assert.equal(vm.state.isMoxGenerationActive, false);
    assert.equal(vm.state.errorMessage, '');
    assert.deepEqual(f.calls.closed, ['session-1']);
    const startCount = f.calls.starts.length;
    vm.submitPrompt('second');
    await settle();
    f.stream.confirmation?.resolve();
    await settle();
    assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
    assert.equal(f.media.capturing, true);
    assert.equal(f.calls.sessions.length, 2);
    assert.equal(f.calls.starts.length, startCount + 1);
    assert.equal(f.calls.starts.at(-1).context.prompt, 'second');
    await vm.suspend();
  });
}

for (const source of ['Camera', 'Image', 'Video']) {
  for (const phase of ['READY', 'CONNECTING', 'CONNECTED', 'GENERATING']) {
    test(`${source} window rotation in ${phase} follows the connection-preserving restart policy`, async () => {
      const f = managerFixture(), states = [];
      const { updateRealtimeVideoTrackOrientation: rotate } = f.load('service/realtime/RealtimeVideoTrack.ets');
      if (source !== 'Camera') {
        f.media[`createLocal${source}Stream`] = async () => {
          f.media.currentTrack = new f.Track('local', new f.Format(1024, 1920, 30));
          return new f.MediaStream('local', f.media.currentTrack);
        };
      } else {
        // 窗口转屏时相机采集输出随显示方向翻转。
        f.media.updateCameraOrientation = () => f.rotateCamera();
      }
      const local = source === 'Camera' ? await f.create() : await f.manager[`createLocal${source}Stream`]('input');
      let gate, pending;
      if (phase === 'CONNECTING') {
        gate = f.holdSession();
        pending = outcome(f.manager.startGeneration(local, new f.Context('test')));
      } else if (phase === 'CONNECTED') {
        await f.manager.connect(local);
      } else if (phase === 'GENERATING') {
        await f.manager.startGeneration(local, new f.Context('test'));
      }
      f.manager.setStateListener(state => states.push(state));
      rotate(local.videoTrack, false, false);
      assert.equal(f.manager.currentState.connectionState, f.State[phase]);
      rotate(local.videoTrack, true, true);
      rotate(local.videoTrack, true, true); // Repeated events must not stack restarts.
      gate?.resolve();
      await settle();
      const restarts = source === 'Camera' && phase === 'GENERATING';
      if (restarts) {
        // 相机生成中：停止任务、保留连接，延时后以缓存条件重启。
        assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);
        assert.equal(f.manager.currentState.reason, f.Reason.ORIENTATION_CHANGED);
        assert.equal(f.calls.starts.length, 1);
        f.runSwitchDelay();
        await settle();
        assert.equal(f.calls.starts.length, 2);
        assert.equal(f.calls.starts.at(-1).context.prompt, 'test');
      }
      if (pending) {
        // 连接中的生成请求继续完成，不再因转屏取消。
        assert.ok((await pending).value);
      }
      await settle();
      assert.equal(states.filter(state => state.connectionState === f.State.DISCONNECTING).length, 0);
      assert.deepEqual(f.calls.closed, []);
      assert.equal(f.media.currentTrack, local.videoTrack);
      assert.equal(f.manager.currentState.connectionState,
        phase === 'READY' ? f.State.READY :
        phase === 'CONNECTED' ? f.State.CONNECTED : f.State.GENERATING);

      if (phase !== 'READY' && phase !== 'GENERATING') {
        await f.manager.startGeneration(local, new f.Context('next'));
        assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
      }
      rotate(local.videoTrack, true, true); // A repeated same-orientation event stays quiet.
      if (source === 'Camera' && phase !== 'READY') {
        assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
      } else {
        assert.equal(f.manager.currentState.connectionState,
          phase === 'READY' ? f.State.READY : f.State.GENERATING);
      }
      await f.manager.close();
      const replacement = await f.create();
      await f.manager.startGeneration(replacement, new f.Context('replacement'));
      rotate(local.videoTrack, false, true); // Events from a replaced track stay quiet.
      assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
      await f.manager.close();
    });
  }
}

test('XLab observes SDK statistics, clears on disconnect and detaches stale manager callbacks', async () => {
  const f = exampleFixture(), vm = f.viewModel;
  await vm.connect({});
  const quality = f.stream.quality;
  const oldUp = quality.uplinkStatisticsListener, oldDown = quality.downlinkStatisticsListener;
  const oldNetwork = quality.networkQualityListener;
  const up = { width: 640, bitrateKbps: 800 }, down = { userId: 'bot', width: 640 };
  const network = { uplink: 'Good', downlink: 'Excellent' };
  oldUp(up); oldDown(down); oldNetwork(network);
  assert.equal(vm.state.uplinkStatistics, up);
  assert.equal(vm.state.downlinkStatistics, down);
  assert.equal(vm.state.networkQuality, network);
  oldDown(undefined); assert.equal(vm.state.downlinkStatistics, undefined);
  oldDown(down);
  await vm.disconnect();
  assert.equal(quality.uplinkStatisticsListener, null);
  assert.equal(quality.downlinkStatisticsListener, null);
  assert.equal(quality.networkQualityListener, null);
  oldUp(up); oldDown(down); oldNetwork(network);
  assert.equal(vm.state.uplinkStatistics, undefined);
  assert.equal(vm.state.downlinkStatistics, undefined);
  assert.equal(vm.state.networkQuality, undefined);
});

test('restart options create a new task while keeping the RTC session and local stream', async () => {
  const f = managerFixture();
  const local = await f.create();
  const context = new f.Context('', 'ref.jpg');
  const extraParams = { static_generate: true, static_image_path: '  https://example.test/cat.jpg  ' };
  const starting = f.manager.startGeneration({ localStream: local, context, extraParams });
  extraParams.static_image_path = 'changed-after-call';
  const remote = await starting;
  assert.equal(Object.hasOwn(context, 'extraParams'), false);
  assert.equal(context.referencePath, 'ref.jpg');
  assert.equal(f.calls.starts[0].extraParams.static_image_path, 'https://example.test/cat.jpg');
  const first = f.calls.starts[0].task;
  const result = await f.manager.startGeneration({ restart: true });
  assert.equal(f.Track.resolve(result.videoTrack), f.Track.resolve(remote.videoTrack));
  assert.equal(f.calls.sessions.length, 1);
  assert.equal(f.calls.closed.length, 0);
  assert.equal(f.media.currentTrack, local.videoTrack);
  assert.equal(f.calls.starts.length, 2);
  assert.notEqual(f.calls.starts[1].task, first);
  assert.equal(f.calls.stops.at(-1), first);
  assert.equal(f.calls.starts[1].extraParams.static_image_path, 'https://example.test/cat.jpg');
  assert.equal(f.calls.starts[1].context.referencePath, 'ref.jpg');
  await f.manager.startGeneration({ context: new f.Context('continuous', 'ref.jpg'), restart: true });
  assert.equal(f.calls.starts[2].extraParams, undefined);
  assert.equal(f.calls.sessions.length, 1);
  await f.manager.close();
});

test('updated static options are cached independently of context and cleared by an explicit normal context', async () => {
  const f = managerFixture(), local = await f.create();
  await f.manager.startGeneration({ localStream: local, context: new f.Context('first', 'ref.jpg'),
    extraParams: { static_generate: true, static_image_path: 'first.jpg' } });
  await f.manager.startGeneration({ context: new f.Context('updated', 'next-ref.jpg'),
    extraParams: { static_generate: true, static_image_path: 'next.jpg' } });
  assert.equal(f.calls.updates.at(-1).extraParams.static_image_path, 'next.jpg');
  await f.manager.startGeneration({ restart: true });
  assert.equal(f.calls.starts.at(-1).extraParams.static_image_path, 'next.jpg');
  assert.equal(f.calls.starts.at(-1).context.referencePath, 'next-ref.jpg');
  assert.equal(Object.hasOwn(f.calls.starts.at(-1).context, 'extraParams'), false);
  await f.manager.startGeneration({ context: new f.Context('normal', 'ref.jpg') });
  assert.equal(f.calls.updates.at(-1).extraParams, undefined);
  await f.manager.startGeneration({ restart: true });
  assert.equal(f.calls.starts.at(-1).extraParams, undefined);
  await f.manager.close();
});

test('invalid static input cannot stop a valid generation or replace its task', async () => {
  const f = managerFixture();
  await f.manager.startGeneration(await f.create(), new f.Context('original'));
  const task = f.manager.currentState.taskId;
  const stops = f.calls.stops.length;
  await assert.rejects(f.manager.startGeneration({ context: new f.Context(''), restart: true,
    extraParams: { static_generate: true, static_image_path: '   ' } }), { code: f.Code.INVALID_CONFIGURATION });
  assert.equal(f.manager.currentState.taskId, task);
  assert.equal(f.calls.stops.length, stops);
  assert.equal(f.calls.starts.length, 1);
  await f.manager.close();
});
