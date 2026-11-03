const test = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const { loadEts } = require('./ets-loader.cjs');

const settle = async () => { for (let i = 0; i < 40; i++) await Promise.resolve(); };
const outcome = promise => promise.then(value => ({ value }), error => ({ error }));

function fixture(t, timingOptions = {}) {
  const timers = new Map(), events = [], messages = [], observations = [], errors = [], timingLogs = [];
  let now = 0;
  let timerId = 0, rtc, media;
  let Track, Format, MediaStream;
  class FakeRtc {
    constructor() { rtc = this; }
    setEventListener(listener) { this.listener = listener; }
    setQualityListener(listener) { this.qualityListener = listener; }
    configureVideoEncoding(format) {
      if (this.failEncoding) throw this.failEncoding;
      (this.encodings ??= []).push(format);
    }
    setRemoteVideoFrameListener(listener) { this.frameListener = listener; }
    setRemoteAudioFrameListener(listener) { this.audioFrameListener = listener; }
    observeRemoteAudioFrames(stream, enabled) { (this.audioObservations ??= []).push({ key: stream.key(), enabled }); }
    setRemoteVideoRenderedListener(listener) { this.renderedListener = listener; }
    observeRemoteVideoFrames(stream, enabled) { observations.push({ key: stream.key(), enabled }); }
    hasRenderedRemoteVideo() { return this.rendered ?? false; }
    renderLibraryName() { return 'rtc'; }
    bindRemoteVideo() { events.push('bind-surface'); }
    unbindRemoteVideo() {}
    async joinRoom() {
      now += timingOptions.roomMs ?? 0;
      if (timingOptions.roomError) throw timingOptions.roomError;
    }
    async leaveRoom() {}
    publishLocalVideo() {}
    unpublishLocalVideo() {}
    unpublishLocalAudio() {}
    setRemoteAudioVolume() { events.push('audio-volume'); }
    subscribeRemoteAudio(user, enabled) { events.push(`audio:${user}:${enabled}`); }
    subscribeRemoteVideo(_user, enabled) { if (!enabled) this.rendered = false; }
    sendRoomMessage(text) {
      const event = JSON.parse(text);
      if (this.failTarget && event.event === 'change_target_size') throw this.failTarget;
      messages.push(event);
      if (event.event === 'start') now += timingOptions.signalMs ?? 0;
    }
  }
  class FakeMedia {
    constructor(_context, _rtc, stream) {
      media = this; this.hasAudio = false;
      const { InteractionController } = load('media/interaction/InteractionController.ets');
      this.interaction = new InteractionController((task, points) => stream.sendTracks(task, points));
    }
    get currentTrack() { return this.track ?? null; }
    setCameraPreviewReadyHandler(listener) { listener?.(); }
    get currentVideoFormat() { return this.track?.videoFormat; }
    async createLocalCameraStream(format, position) {
      this.track = new Track('local', format, position);
      return new MediaStream('local', this.track);
    }
    async createLocalImageStream(_path) {
      this.usesContainPadding = true;
      this.track = new Track('local', new Format(1080, 1920, 30));
      return new MediaStream('local', this.track);
    }
    owns(local) { return local.videoTrack === this.track; }
    start(id, format) { this.task = id; this.interaction.start(id, format); }
    stop() { this.task = null; this.interaction.stop(); }
    submit(frame) { this.interaction.submit(frame); }
    setLocalAudioPreviewEnabled(enabled) { this.previewAudio = enabled; }
    updateCameraOrientation() {}
    startMicrophoneCapture() {}
    stopMicrophoneCapture() {}
    prepareForClose() {}
    async stopLocalStream() { this.track = null; }
  }
  const load = loadEts({
    '@ohos.systemDateTime': { default: { TimeType: { ACTIVE: 0 }, getUptime: () => now * 1000000 } },
    '@kit.ArkUI': { UIUtils: { getTarget: value => value } },
    '@kit.BasicServicesKit': { deviceInfo: { distributionOSVersion: '5.1.0', productModel: 'Test' } },
    '@kit.ArkTS': { util: {
      generateRandomUUID: () => randomUUID(),
      Base64Helper: class { encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); } },
      TextEncoder: class { encodeInto(text) { return new Uint8Array(Buffer.from(text)); } }
    } },
    XmaxLogger: { XmaxLogger: { debug() {}, info(message, category, option) {
      if (category === 'Timing') timingLogs.push({ message: typeof message === 'function' ? message() : message, option });
    }, warn() {}, error() {} } },
    RtcManager: { RtcManager: FakeRtc }, MediaController: { MediaController: FakeMedia },
    RoomHeartbeat: { RoomHeartbeat: class { start() {} stop() {} } },
    RealtimeSessionService: { RealtimeSessionService: class {
      async createSession() {
        now += timingOptions.sessionMs ?? 0;
        if (timingOptions.sessionError) throw timingOptions.sessionError;
        return { id: 'session', connection: {
        roomId: 'room', userId: 'user', token: 'test', botName: 'bot'
      } }; }
      startHeartbeat(id, _onFailure, graceSeconds) {
        events.push(`heartbeat:${id}:${graceSeconds}`);
      }
      stopHeartbeat() {} async closeSession() {}
    } }
  }, {
    setTimeout: (callback, ms) => { timers.set(++timerId, { callback, ms }); return timerId; },
    clearTimeout: id => timers.delete(id)
  });
  ({ RealtimeVideoTrack: Track } = load('service/realtime/RealtimeVideoTrack.ets'));
  ({ RealtimeVideoFormat: Format } = load('service/realtime/RealtimeVideoFormat.ets'));
  ({ RealtimeMediaStream: MediaStream } = load('service/realtime/RealtimeMediaStream.ets'));
  const { RealtimeContext: Context } = load('service/realtime/RealtimeContext.ets');
  const { RemoteStream } = load('foundation/rtc/RemoteStream.ets');
  const { XmaxRealtimeManager } = load('core/realtime/XmaxRealtimeManager.ets');
  const { XmaxError, XmaxErrorCode: Code } = load('foundation/errors/XmaxError.ets');
  const { RealtimeConnectionState: State } = load('service/realtime/RealtimeState.ets');
  const { RealtimeModels } = load('service/realtime/RealtimeModel.ets');
  const { RealtimeConfiguration } = load('core/realtime/RealtimeConfiguration.ets');
  const manager = new XmaxRealtimeManager({}, new RealtimeConfiguration(
    RealtimeModels.realtime('x2.0-sla'), timingOptions.isAdaptiveQualityEnabled ?? true), {});
  manager.setStateListener(state => { events.push(`state:${state.connectionState}`); if (state.reason?.error) errors.push(state.reason.error); });
  const remote = new RemoteStream('room', 'bot');
  t.after(async () => { await manager.close(); assert.equal(timers.size, 0); });
  return { load, rtc, media, manager, events, messages, observations, errors, timers, State, XmaxError, Code,
    timingLogs, advance(ms) { now += ms; },
    remote, RemoteStream,
    async begin() {
      const local = new MediaStream('local', media.track);
      const input = media.track ? local : await manager.createLocalCameraStream(new Format(1024, 1920, 30));
      const pending = outcome(manager.startGeneration(input, new Context('prompt')));
      await settle();
      return { pending, task: messages.filter(m => m.event === 'start').at(-1)?.uid };
    },
    sei(task, stream = remote) { rtc.listener.onSeiMessageReceived(stream, task); },
    frame(stream = remote, copyFrame) { rtc.frameListener(stream, copyFrame); },
    runTimer(ms) {
      const entries = [...timers].filter(([, timer]) => timer.ms === ms);
      assert.equal(entries.length, 1);
      const [id, timer] = entries[0]; timers.delete(id); timer.callback();
    }
  };
}

test('startup timing spans session creation, RTC join, signaling, matched SEI and usable first frame', async t => {
  const f = fixture(t, { sessionMs: 10, roomMs: 20, signalMs: 2 });
  const first = await f.begin();
  assert.deepEqual(f.timingLogs, []);
  f.advance(100); f.sei(first.task); await settle();
  assert.deepEqual(f.timingLogs, []);
  f.advance(25); f.frame(); await first.pending;
  assert.equal(f.timingLogs.length, 1);
  assert.equal(f.timingLogs[0].option, 2);
  for (const detail of ['总耗时：157.0 ms',
    '实时连接：30.0 ms', '等待生成结果流确认：102.0 ms',
    '结果流确认到首帧就绪：25.0 ms']) assert.ok(f.timingLogs[0].message.includes(detail), detail);
  await f.manager.disconnect();
  const second = await f.begin();
  f.advance(10); f.sei(second.task); await settle();
  f.advance(3); f.frame(); await second.pending;
  assert.equal(f.timingLogs.length, 2);
  assert.match(f.timingLogs[1].message, /总耗时：45.0 ms/);
  assert.match(f.timingLogs[1].message, /实时连接：30.0 ms/);
});

test('rejected concurrent calls and condition updates do not reset startup timing or produce extra reports', async t => {
  const f = fixture(t), first = await f.begin();
  const { RealtimeContext } = f.load('service/realtime/RealtimeContext.ets');
  f.advance(50);
  await assert.rejects(f.manager.startGeneration(new RealtimeContext('overlap')), { code: f.Code.INVALID_CONFIGURATION });
  f.sei(first.task); await settle();
  f.advance(10); f.frame(); await first.pending;
  assert.equal(f.timingLogs.length, 1);
  assert.match(f.timingLogs[0].message, /总耗时：60.0 ms/);
  await f.manager.startGeneration(new RealtimeContext('update'));
  assert.equal(f.timingLogs.length, 1);
});

test('cancelled startup emits no timing report and a retry ignores the old task SEI', async t => {
  const f = fixture(t), first = await f.begin();
  f.advance(20); f.sei(first.task); await settle();
  await f.manager.disconnect();
  assert.equal((await first.pending).error.code, f.Code.CANCELLED);
  assert.deepEqual(f.timingLogs, []);
  const second = await f.begin();
  f.advance(10); f.sei(first.task); f.frame(); await settle();
  assert.deepEqual(f.timingLogs, []);
  f.advance(20); f.sei(second.task); await settle();
  f.advance(5); f.frame(); await second.pending;
  assert.equal(f.timingLogs.length, 1);
  assert.match(f.timingLogs[0].message, /总耗时：35.0 ms/);
  assert.match(f.timingLogs[0].message, /等待生成结果流确认：30.0 ms/);
});

test('generation confirmation and first-frame timeouts report the correct stage without changing the error', async t => {
  for (const [matched, milliseconds, stage] of [
    [false, 30000, '正在等待生成结果流确认'], [true, 10000, '结果流已确认，正在等待首帧']
  ]) {
    const f = fixture(t), first = await f.begin();
    if (matched) { f.sei(first.task); await settle(); }
    f.advance(milliseconds); f.runTimer(milliseconds);
    const result = await first.pending;
    assert.equal(result.error.code, f.Code.TIMEOUT);
    assert.equal(f.errors[0], result.error);
    assert.equal(f.timingLogs.length, 1);
    assert.ok(f.timingLogs[0].message.includes(`停留阶段：${stage}`));
    assert.ok(f.timingLogs[0].message.includes(`已耗时：${milliseconds.toFixed(1)} ms`));
    assert.equal(f.manager.currentState.connectionState, f.State.READY);
  }
});

test('session and room failures report their connection stage after cleanup', async t => {
  for (const [field, stage] of [['sessionError', '服务端会话创建'], ['roomError', '正在连接 RTC 房间']]) {
    const options = { sessionMs: 10, roomMs: 20 };
    const f = fixture(t, options);
    const error = new f.XmaxError(f.Code.NETWORK_ERROR, 'connection failed');
    options[field] = error;
    const first = await f.begin();
    assert.equal((await first.pending).error, error);
    assert.equal(f.timingLogs.length, 1);
    assert.ok(f.timingLogs[0].message.includes(`停留阶段：${stage}`));
    assert.equal(f.manager.currentState.connectionState, f.State.READY);
    assert.equal(f.messages.some(message => message.event === 'start'), false);
  }
});

test('synchronous stop from the GENERATING listener does not produce a successful timing report', async t => {
  const f = fixture(t);
  f.manager.setStateListener(state => {
    if (state.connectionState === f.State.GENERATING) void f.manager.disconnect();
  });
  const first = await f.begin();
  f.sei(first.task); await settle(); f.frame();
  assert.equal((await first.pending).error.code, f.Code.CANCELLED);
  assert.deepEqual(f.timingLogs, []);
});

test('GENERATING and one-call return wait for a usable frame without requiring a mounted view', async t => {
  const f = fixture(t), { pending, task } = await f.begin();
  f.rtc.listener.onRemoteAudioPublished('bot', true);
  f.frame(); // A frame before matching SEI cannot satisfy this generation.
  f.sei(task);
  await settle();
  let returned = false; pending.then(() => { returned = true; });
  assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);
  assert.equal(f.events.includes('audio:bot:true'), false);
  assert.equal(f.events.some(event => event.startsWith('heartbeat:')), false);
  assert.equal(returned, false);
  assert.deepEqual([...f.timers.values()].map(timer => timer.ms), [10000]);
  f.frame(new f.RemoteStream('room', 'other'));
  f.frame(new f.RemoteStream('other-room', 'bot'));
  await settle();
  assert.equal(returned, false);
  f.frame();
  const result = await pending;
  assert.ok(result.value.videoTrack);
  assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
  assert.equal(f.manager.currentState.taskId, task);
  assert.deepEqual(f.events.filter(event => event.startsWith('heartbeat:')), ['heartbeat:session:0']);
  assert.ok(f.events.indexOf('heartbeat:session:0') < f.events.indexOf(`state:${f.State.GENERATING}`));
  assert.ok(f.events.indexOf('audio:bot:true') < f.events.indexOf(`state:${f.State.GENERATING}`));
  assert.equal(f.events.includes('bind-surface'), false);
  assert.equal(f.observations.at(-1).enabled, false);
  assert.equal(f.timers.size, 0);
});

test('an immediate frame after SEI is remembered until Core starts waiting', async t => {
  const f = fixture(t), { pending, task } = await f.begin();
  f.sei(task); f.frame();
  assert.ok((await pending).value.videoTrack);
  assert.equal(f.timers.size, 0);
});

test('10-second first-frame timeout stops the task, restores preview audio and allows retry', async t => {
  const f = fixture(t), first = await f.begin();
  f.sei(first.task); await settle(); f.runTimer(10000);
  const failure = (await first.pending).error;
  assert.equal(failure.code, f.Code.TIMEOUT);
  assert.equal(failure.message, 'Remote video first frame timed out');
  assert.deepEqual(f.errors, [failure]);
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  assert.equal(f.messages.at(-1).event, 'stop');
  assert.equal(f.messages.at(-1).uid, first.task);
  assert.equal(f.media.previewAudio, true);
  assert.equal(f.media.task, null);
  f.frame(); await settle();
  assert.equal(f.events.includes('audio:bot:true'), false);
  const second = await f.begin();
  f.sei(second.task); f.frame();
  assert.ok((await second.pending).value.videoTrack);
});

test('stop cancels first-frame waiting and an old timeout cannot fail a new task', async t => {
  const f = fixture(t), first = await f.begin();
  f.sei(first.task); await settle();
  const oldTimeout = [...f.timers.values()][0].callback;
  await f.manager.disconnect();
  assert.equal((await first.pending).error.code, f.Code.CANCELLED);
  assert.equal(f.errors.length, 0);
  const second = await f.begin(); f.sei(second.task); await settle();
  oldTimeout(); await settle();
  assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);
  assert.equal(f.messages.at(-1).event, 'start');
  f.frame();
  assert.equal((await second.pending).error, undefined);
});

test('stop after the frame callback but before its continuation cannot activate audio or emit GENERATING', async t => {
  const f = fixture(t), { pending, task } = await f.begin();
  f.sei(task); await settle(); f.frame();
  await f.manager.disconnect();
  assert.equal((await pending).error.code, f.Code.CANCELLED);
  assert.equal(f.events.includes('audio:bot:true'), false);
  assert.equal(f.events.includes(`state:${f.State.GENERATING}`), false);
  assert.equal(f.events.some(event => event.startsWith('heartbeat:')), false);
});

test('disconnect and close cancel pending first-frame waits without a late state transition', async t => {
  for (const operation of ['disconnect', 'close']) {
    const f = fixture(t), { pending, task } = await f.begin();
    f.sei(task); await settle(); await f.manager[operation]();
    assert.equal((await pending).error.code, f.Code.CANCELLED);
    f.frame(); await settle();
    assert.equal(f.events.includes(`state:${f.State.GENERATING}`), false);
    assert.equal(f.timers.size, 0);
  }
});

test('restarting on the same remote stream requires a new frame and stops old audio', async t => {
  const f = fixture(t), first = await f.begin();
  f.sei(first.task); f.frame(); await first.pending;
  await f.manager.disconnect();
  assert.equal(f.events.at(-2), 'audio:bot:false');
  f.rtc.listener.onRemoteAudioPublished('bot', true);
  assert.equal(f.events.filter(e => e === 'audio:bot:true').length, 1);
  const second = await f.begin();
  f.sei(first.task); f.frame(); await settle(); // Old task cannot arm first-frame observation.
  f.sei(second.task); await settle();
  assert.equal(f.manager.currentState.connectionState, f.State.CONNECTED);
  f.frame(); await second.pending;
  assert.equal(f.events.filter(e => e === 'audio:bot:true').length, 2);
  f.rtc.listener.onRemoteAudioPublished('bot', true); // Repeated publication is idempotent.
  assert.equal(f.events.filter(e => e === 'audio:bot:true').length, 2);
});

test('refresh holds the image through task confirmation and decode until the replacement frame renders', async t => {
  const f = fixture(t), readiness = [];
  const { RealtimeContext } = f.load('service/realtime/RealtimeContext.ets');
  const { VideoRenderRegistry } = f.load('rendering/video/VideoRenderRegistry.ets');
  const local = await f.manager.createLocalImageStream('cat');
  const remote = await f.manager.connect(local);
  VideoRenderRegistry.attach(remote.videoTrack, 'surface', 0, () => {}, () => {},
    ready => readiness.push(ready));
  const first = await f.begin();
  f.sei(first.task); f.frame();
  f.rtc.rendered = true; f.rtc.renderedListener(f.remote);
  await first.pending;
  assert.equal(readiness.at(-1), true);

  const restart = outcome(f.manager.startGeneration({
    localStream: local, context: new RealtimeContext(''), restart: true
  }));
  await settle();
  assert.equal(readiness.at(-1), false);
  const task = f.messages.filter(message => message.event === 'start').at(-1).uid;
  assert.notEqual(task, first.task);
  f.sei(first.task); f.rtc.renderedListener(f.remote); f.frame();
  assert.equal(readiness.at(-1), false, 'events from the stopped task must not reveal video');
  f.sei(task); await settle();
  assert.equal(readiness.at(-1), false, 'matching SEI cannot replay historic readiness');
  f.frame();
  assert.ok(!(await restart).error);
  assert.equal(readiness.at(-1), false, 'a decoded frame is not a rendered frame');
  f.rtc.rendered = true; f.rtc.renderedListener(f.remote);
  assert.equal(readiness.at(-1), true);
  assert.equal(f.manager.currentState.sessionId, 'session');
  VideoRenderRegistry.detach(remote.videoTrack, 'surface');
});

test('remote video removal cancels startup and audio cannot resume from later publication', async t => {
  const f = fixture(t), { pending, task } = await f.begin();
  f.sei(task); await settle();
  f.rtc.listener.onRemoteVideoPublished('bot', false);
  assert.equal((await pending).error.code, f.Code.CANCELLED);
  f.rtc.listener.onRemoteAudioPublished('bot', true);
  assert.equal(f.events.includes('audio:bot:true'), false);
});

test('audio activation failure rejects startup, stops the task, and never emits GENERATING', async t => {
  const f = fixture(t), { pending, task } = await f.begin();
  const error = new f.XmaxError(f.Code.RTC_ERROR, 'audio failed');
  f.rtc.subscribeRemoteAudio = (_user, enabled) => { if (enabled) throw error; };
  f.sei(task); f.frame();
  assert.equal((await pending).error, error);
  assert.deepEqual(f.errors, [error]);
  assert.equal(f.messages.at(-1).event, 'stop');
  assert.equal(f.events.includes(`state:${f.State.GENERATING}`), false);
});

test('RTC errors during first-frame waiting reject promptly with the original error once', async t => {
  const f = fixture(t), { pending, task } = await f.begin();
  f.sei(task); await settle();
  const error = new f.XmaxError(f.Code.RTC_ERROR, 'subscription failed');
  f.rtc.subscribeRemoteVideo = () => { throw error; };
  f.rtc.listener.onRemoteVideoPublished('bot', true);
  assert.equal((await pending).error, error);
  assert.deepEqual(f.errors, [error]);
  assert.equal(f.timers.size, 0);
  assert.equal(f.events.includes(`state:${f.State.GENERATING}`), false);
});

test('a sink setup failure stops generation before any audio or GENERATING state', async t => {
  const f = fixture(t), { pending, task } = await f.begin();
  const error = new f.XmaxError(f.Code.RTC_ERROR, 'sink failed');
  f.rtc.observeRemoteVideoFrames = (_stream, enabled) => { if (enabled) throw error; };
  f.sei(task);
  assert.equal((await pending).error, error);
  assert.equal(f.events.includes('audio:bot:true'), false);
  assert.equal(f.messages.at(-1).event, 'stop');
});

test('RTC bridge observes postprocessed main-stream frames only while armed and removes its callback on destroy', async () => {
  const handlers = new Map(), sinks = [], received = [];
  const engine = {
    on: (name, callback) => handlers.set(name, callback),
    off: name => handlers.delete(name),
    setRemoteVideoSinkWithConfig(key, config, enabled) { sinks.push({ key, config, enabled }); return 0; }
  };
  const load = loadEts({
    '@kit.ArkTS': { util: { TextDecoder: { create: () => ({
      decodeToString: bytes => Buffer.from(bytes).toString('utf8')
    }) } } },
    '@bytertc/volcenginertc': {
      MirrorType: { kMirrorTypeNone: 0 }, StreamIndex: { kStreamIndexMain: 0 },
      RemoteVideoSinkPosition: { kRemoteVideoSinkPositionAfterPostProcess: 1 },
      VideoPixelFormat: { kVideoPixelFormatI420: 1 },
      VideoApplyRotation: { kVideoApplyRotationDefault: -1 },
      VideoSinkMirrorType: { kVideoSinkMirrorTypeOFF: 2 }
    },
    RtcEngineManager: { RtcEngineManager: { async acquire() { return { engine }; }, async release() {} } },
    RtcStatsLogger: { RtcStatsLogger: {} }, XmaxLogger: { XmaxLogger: { info() {}, debug() {} } }
  });
  const { RtcManager } = load('foundation/rtc/RtcManager.ets');
  const { RemoteStream } = load('foundation/rtc/RemoteStream.ets');
  const rtc = new RtcManager({});
  await rtc.initialize();
  rtc.activeRoomId = 'room';
  rtc.setEventListener({ onSeiMessageReceived() {} });
  rtc.setRemoteVideoFrameListener(stream => received.push(stream.key()));
  const key = { room_id: 'room', user_id: 'bot', stream_index: 0 };
  const frame = { width: 1024, height: 1920 };
  handlers.get('onSEIMessageReceived')(key, new Uint8Array(Buffer.from('task')).buffer);
  const onFrame = handlers.get('onRemoteVideoFrame');
  const stream = new RemoteStream('room', 'bot');
  onFrame(key, 1, frame);
  assert.deepEqual(received, []);
  rtc.observeRemoteVideoFrames(stream, true);
  assert.deepEqual(sinks[0], { key, config: {
    position: 1, pixel_format: 1, apply_rotation: -1, mirror_type: 2
  }, enabled: true });
  onFrame({ ...key, room_id: 'other' }, 1, frame);
  onFrame({ ...key, user_id: 'other' }, 1, frame);
  onFrame({ ...key, stream_index: 1 }, 1, frame);
  onFrame(key, 0, frame);
  onFrame(key, 1, { width: 0, height: 1920 });
  assert.deepEqual(received, []);
  onFrame(key, 1, frame);
  assert.deepEqual(received, ['room:bot']);
  rtc.observeRemoteVideoFrames(stream, false);
  assert.equal(sinks.at(-1).enabled, false);
  onFrame(key, 1, frame);
  assert.equal(received.length, 1);
  rtc.observeRemoteVideoFrames(stream, true);
  onFrame(key, 1, frame);
  assert.equal(received.length, 2);
  let copied;
  rtc.setRemoteVideoFrameListener((stream, copyFrame) => { received.push(stream.key()); copied = copyFrame(); });
  const pixels = Uint8Array.from([10, 20, 30, 40]);
  onFrame(key, 1, { width: 2, height: 2, rotation: 0, timestamp_us: 999,
    pixel_format: 1, number_of_planes: 3, plane_stride: [2, 1, 1],
    plane_data: [pixels.buffer, Uint8Array.of(50).buffer, Uint8Array.of(60).buffer] });
  pixels.fill(0); // RTC may recycle its buffers after this callback returns.
  assert.deepEqual([...new Uint8Array(copied.planes[0].data)], [10, 20, 30, 40]);
  assert.equal(copied.timestampUs, 999);
  assert.equal(received.length, 3);
  await rtc.destroy();
  assert.equal(handlers.has('onRemoteVideoFrame'), false);
  onFrame(key, 1, frame); // Callback retained by a previous engine cannot leak into another lifetime.
  assert.equal(received.length, 3);
});

for (const action of ['disconnect', 'close']) {
  test(`unified media stops on ${action}, discards queued audio/video and resumes with a fresh stream identity`, async t => {
    const f = fixture(t), delivered = [];
    const { RealtimeVideoFrame } = f.load('foundation/media/video/RealtimeVideoFrame.ets');
    const { RtcRemoteAudioFrame } = f.load('foundation/rtc/RtcRemoteAudioFrame.ets');
    const makeVideo = () => new RealtimeVideoFrame(2, 2, 'i420', [], 990000, 0);
    const makeAudio = () => new RtcRemoteAudioFrame(new Uint8Array(960), 48000, 1, 480, 1000000);
    let copies = 0;
    const audio = () => f.rtc.audioFrameListener(f.remote, () => { copies++; return makeAudio(); });
    f.manager.setRemoteMediaFrameListener(frame => delivered.push(frame));

    const first = await f.begin(); f.sei(first.task); f.frame(f.remote, makeVideo);
    await settle(); assert.ok(!(await first.pending).error);
    audio(); f.runTimer(0);
    assert.deepEqual(delivered.map(frame => frame.timestampUs), [990000, 1000000]);
    const oldId = delivered[0].streamId;
    audio(); f.frame(f.remote, makeVideo);
    const stopping = f.manager[action]();
    assert.equal([...f.timers.values()].filter(timer => timer.ms === 0).length, 0);
    const previousCopies = copies; audio(); assert.equal(copies, previousCopies);
    await stopping;
    assert.equal(delivered.length, 2);
    assert.equal(f.rtc.audioObservations.at(-1).enabled, false);

    const second = await f.begin(); f.sei(second.task); f.frame(f.remote, makeVideo);
    await settle(); assert.ok(!(await second.pending).error);
    audio(); f.runTimer(0);
    assert.equal(delivered.length, 4);
    assert.notEqual(delivered[2].streamId, oldId);
    assert.ok(delivered.slice(2).every(frame => frame.isDiscontinuous));
    f.manager.setRemoteMediaFrameListener(null);
    assert.equal(f.rtc.audioObservations.at(-1).enabled, false);
  });
}

for (const [width, height] of [[1920, 1080], [1080, 1920], [1408, 1408], [1152, 1536], [1536, 1152]]) {
  test(`X2.1 ${width}x${height} camera canvas reaches start and condition-update signals unchanged`, async t => {
    const f = fixture(t);
    const { RealtimeVideoFormat } = f.load('service/realtime/RealtimeVideoFormat.ets');
    const { RealtimeContext } = f.load('service/realtime/RealtimeContext.ets');
    const format = new RealtimeVideoFormat(width, height, 30);
    const local = await f.manager.createLocalCameraStream(format);
    const pending = outcome(f.manager.startGeneration(local, new RealtimeContext('first')));
    await settle();
    const start = f.messages.find(message => message.event === 'start');
    assert.ok(start);
    assert.deepEqual(start.params.size, [width, height]);
    assert.deepEqual(local.videoTrack.videoFormat, format);
    f.sei(start.uid); await settle(); f.frame();
    assert.equal((await pending).error, undefined);
    await f.manager.startGeneration(new RealtimeContext('second'));
    const changed = f.messages.at(-1);
    assert.equal(changed.event, 'change_condition');
    assert.equal(changed.uid, start.uid);
    assert.deepEqual(changed.params.size, [width, height]);
    assert.deepEqual(local.videoTrack.videoFormat, format);
  });
}

test('X2.1 image generation separates media, canvas and return sizes through the real room signaling chain', async t => {
  const f = fixture(t);
  const { RealtimeContext } = f.load('service/realtime/RealtimeContext.ets');
  const local = await f.manager.createLocalImageStream('image');
  const pending = outcome(f.manager.startGeneration(local, new RealtimeContext('first'), true));
  await settle();
  const message = f.messages.find(m => m.event === 'start');
  assert.deepEqual(message.params.size, [1080, 1920]);
  assert.deepEqual(message.params.target_size, [972, 1728]);
  assert.equal(message.params.padding, 'contain');
  assert.equal(message.params.face_replace, true);
  assert.equal(local.videoTrack.videoFormat.width, 1080);
  f.sei(message.uid); await settle();
  f.frame();
  const result = await pending;
  assert.equal(result.error, undefined);
  assert.equal(result.value.videoTrack.videoFormat.width, 972);
  assert.equal(result.value.videoTrack.videoFormat.height, 1728);
  await f.manager.startGeneration(new RealtimeContext('second'), false);
  const changed = f.messages.at(-1);
  assert.equal(changed.event, 'change_condition');
  assert.deepEqual(changed.params.size, [1080, 1920]);
  assert.equal(changed.params.padding, 'contain');
  assert.equal(changed.params.face_replace, false);
  assert.equal(changed.params.target_size, undefined);
  assert.equal(f.media.currentVideoFormat.width, 1080);
  const { TrajectoryRegistry } = f.load('rendering/trajectory/TrajectoryRegistry.ets');
  const { VideoContentMode } = f.load('foundation/media/video/VideoContentMode.ets');
  const { updateRealtimeVideoTrackFormat } = f.load('service/realtime/RealtimeVideoTrack.ets');
  const { RealtimeVideoFormat } = f.load('service/realtime/RealtimeVideoFormat.ets');
  const binding = TrajectoryRegistry.binding(result.value.videoTrack);
  assert.deepEqual({ ...binding.resolvedMediaSize }, { width: 1080, height: 1920 });
  for (const [width, height] of [[684, 1216], [1024, 1920], [800, 600]]) {
    updateRealtimeVideoTrackFormat(result.value.videoTrack, new RealtimeVideoFormat(width, height, 30));
    binding.submit([{ x: 0.431231 * 108, y: 0.56931 * 192 }], 108, 192, VideoContentMode.FIT);
    const tracks = f.messages.at(-1);
    assert.equal(tracks.event, 'tracks');
    assert.equal(tracks.uid, message.uid);
    assert.ok(Math.abs(tracks.tracks[0][0] - 0.431231) < 1e-12);
    assert.ok(Math.abs(tracks.tracks[0][1] - 0.56931) < 1e-12);
  }
});

async function generated(f) {
  const started = await f.begin();
  f.sei(started.task); await settle();
  f.frame();
  const result = await started.pending;
  assert.equal(result.error, undefined);
  return { task: started.task, remote: result.value };
}
async function qualitySamples(f, uplink, downlink, count = 4) {
  const { RtcQualityLevel: Level } = f.load('foundation/rtc/RtcQualityListener.ets');
  for (let index = 0; index < count; index++) {
    f.advance(2000);
    f.rtc.qualityListener.onNetworkQuality(Level[uplink], Level[downlink]);
    await settle();
  }
}

test('quality getters expose only established connections and setters require active generation', async t => {
  const f = fixture(t);
  const { RealtimeQualityLevel: Level } = f.load('stream/quality/RealtimeQualityLevel.ets');
  const { RealtimeVideoFormat: Format } = f.load('service/realtime/RealtimeVideoFormat.ets');
  assert.equal(f.manager.uplinkQualityLevel, undefined);
  assert.equal(f.manager.downlinkQualityLevel, undefined);
  await assert.rejects(f.manager.setUplinkQualityLevel(Level.L1), error => error.code === f.Code.INVALID_CONFIGURATION);
  const local = await f.manager.createLocalCameraStream(new Format(1024, 1920, 30));
  assert.equal(f.manager.uplinkQualityLevel, undefined);
  await f.manager.connect(local);
  assert.equal(f.manager.uplinkQualityLevel, Level.L2);
  assert.equal(f.manager.downlinkQualityLevel, Level.L2);
  await assert.rejects(f.manager.setDownlinkQualityLevel(Level.L1), error => error.code === f.Code.INVALID_CONFIGURATION);
  await generated(f);
  assert.equal(f.manager.uplinkQualityLevel, Level.L2);
  const disconnecting = f.manager.disconnect();
  assert.equal(f.manager.uplinkQualityLevel, undefined);
  assert.equal(f.manager.downlinkQualityLevel, undefined);
  await disconnecting;
  assert.equal(f.manager.downlinkQualityLevel, undefined);
});

test('manual uplink and downlink levels preserve the task, capture baseline and interaction coordinates', async t => {
  const f = fixture(t), { task, remote } = await generated(f);
  const { RealtimeQualityLevel: Level } = f.load('stream/quality/RealtimeQualityLevel.ets');
  const capture = f.media.currentTrack.videoFormat;
  const previousRemote = remote.videoTrack.videoFormat;
  const count = f.rtc.encodings.length;
  await f.manager.setUplinkQualityLevel(Level.L5);
  assert.equal(f.manager.uplinkQualityLevel, Level.L5);
  assert.equal(f.manager.downlinkQualityLevel, Level.L2);
  assert.equal(f.rtc.encodings.length, count + 1);
  const encoding = f.rtc.encodings.at(-1);
  assert.deepEqual([encoding.width, encoding.height, encoding.frameRate], [576, 1080, 16]);
  assert.equal(remote.videoTrack.videoFormat, previousRemote);
  assert.equal(f.messages.filter(m => m.event === 'change_target_size').length, 0);
  await f.manager.setDownlinkQualityLevel(Level.L3);
  assert.equal(f.manager.downlinkQualityLevel, Level.L3);
  assert.equal(f.rtc.encodings.length, count + 1);
  assert.deepEqual(f.messages.at(-1).params.target_size, [768, 1440]);
  assert.equal(f.media.currentTrack.videoFormat, capture);
  assert.equal(f.manager.currentState.taskId, task);
  assert.equal(f.messages.filter(m => m.event === 'start').length, 1);
  const { TrajectoryRegistry } = f.load('rendering/trajectory/TrajectoryRegistry.ets');
  assert.deepEqual({ ...TrajectoryRegistry.binding(remote.videoTrack).resolvedMediaSize }, { width: 1024, height: 1920 });
});

test('disabling adaptation retains network notifications and manual control, and reconnect starts at L1', async t => {
  const f = fixture(t, { isAdaptiveQualityEnabled: false });
  const { RealtimeQualityLevel: Level } = f.load('stream/quality/RealtimeQualityLevel.ets');
  await generated(f);
  assert.equal(f.manager.uplinkQualityLevel, Level.L1);
  assert.equal(f.manager.downlinkQualityLevel, Level.L1);
  const notifications = [];
  f.manager.setNetworkQualityListener(q => notifications.push(q));
  const encoded = f.rtc.encodings.length;
  await qualitySamples(f, 'VERY_BAD', 'VERY_BAD', 10);
  assert.equal(notifications.length, 10);
  assert.equal(f.rtc.encodings.length, encoded);
  assert.equal(f.messages.filter(m => m.event === 'change_target_size').length, 0);
  await f.manager.setUplinkQualityLevel(Level.L4);
  await f.manager.setDownlinkQualityLevel(Level.L5);
  await qualitySamples(f, 'GOOD', 'VERY_BAD', 10);
  assert.equal(f.manager.uplinkQualityLevel, Level.L4);
  assert.equal(f.manager.downlinkQualityLevel, Level.L5);
  await f.manager.disconnect();
  await generated(f);
  assert.equal(f.manager.uplinkQualityLevel, Level.L1);
  assert.equal(f.manager.downlinkQualityLevel, Level.L1);
});

test('automatic adaptation can change a manually selected level and successful selections restore from history', async t => {
  const f = fixture(t);
  const { RealtimeQualityLevel: Level } = f.load('stream/quality/RealtimeQualityLevel.ets');
  await generated(f);
  await f.manager.setUplinkQualityLevel(Level.L4);
  assert.equal(f.manager.uplinkQualityLevel, Level.L4);
  await f.manager.disconnect();
  await generated(f);
  assert.equal(f.manager.uplinkQualityLevel, Level.L4);
  await qualitySamples(f, 'GOOD', 'UNKNOWN', 6);
  assert.equal(f.manager.uplinkQualityLevel, Level.L3);
});

for (const downlink of [false, true]) {
  test(`manual ${downlink ? 'downlink' : 'uplink'} failure rejects without committing history or ending generation`, async t => {
    const f = fixture(t), { task, remote } = await generated(f);
    const { RealtimeQualityLevel: Level } = f.load('stream/quality/RealtimeQualityLevel.ets');
    const operation = level => downlink ? f.manager.setDownlinkQualityLevel(level) : f.manager.setUplinkQualityLevel(level);
    const field = downlink ? 'failTarget' : 'failEncoding';
    const previous = remote.videoTrack.videoFormat;
    const error = new f.XmaxError(f.Code.RTC_ERROR, 'manual configuration failed');
    f.rtc[field] = error;
    await assert.rejects(operation(Level.L3), failure => failure === error);
    assert.equal(f.manager.uplinkQualityLevel, Level.L2);
    assert.equal(f.manager.downlinkQualityLevel, Level.L2);
    assert.equal(remote.videoTrack.videoFormat, previous);
    assert.equal(f.manager.currentState.taskId, task);
    assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
    assert.deepEqual(f.errors, []);
    const history = f.manager.streamController.qualityController.history;
    assert.equal(history.read(downlink), Level.L2);
    f.rtc[field] = undefined;
    await operation(Level.L3);
    assert.equal(history.read(downlink), Level.L3);
  });
}

test('manual levels reject invalid inputs and concurrent startup without changing the pending generation', async t => {
  const f = fixture(t), start = await f.begin();
  await assert.rejects(f.manager.setUplinkQualityLevel(3), error => error.code === f.Code.INVALID_CONFIGURATION);
  f.sei(start.task); await settle(); f.frame();
  assert.equal((await start.pending).error, undefined);
  for (const level of [0, 6, 1.5, NaN, Infinity]) {
    await assert.rejects(f.manager.setUplinkQualityLevel(level), error => error.code === f.Code.INVALID_CONFIGURATION);
    await assert.rejects(f.manager.setDownlinkQualityLevel(level), error => error.code === f.Code.INVALID_CONFIGURATION);
  }
  assert.equal(f.manager.currentState.taskId, start.task);
  assert.equal(f.manager.uplinkQualityLevel, 2);
  assert.equal(f.manager.downlinkQualityLevel, 2);
});

test('disconnect cancels a manual adjustment before committing its level or history', async t => {
  const f = fixture(t); await generated(f);
  const previous = f.manager.streamController.qualityController.history;
  const configure = f.rtc.configureVideoEncoding.bind(f.rtc);
  let closing;
  f.rtc.configureVideoEncoding = format => {
    configure(format);
    closing = f.manager.disconnect();
  };
  await assert.rejects(f.manager.setUplinkQualityLevel(3), error => error.code === f.Code.CANCELLED);
  await closing;
  assert.equal(previous.read(false), 2);
  assert.equal(f.manager.uplinkQualityLevel, undefined);
  assert.equal(f.manager.downlinkQualityLevel, undefined);
});

test('automatic downlink adjustment can succeed when the same sample fails to change uplink encoding', async t => {
  const f = fixture(t); await generated(f);
  f.rtc.failEncoding = new f.XmaxError(f.Code.RTC_ERROR, 'encoder unavailable');
  await qualitySamples(f, 'BAD', 'BAD');
  assert.equal(f.manager.uplinkQualityLevel, 2);
  assert.equal(f.manager.downlinkQualityLevel, 3);
  assert.deepEqual(f.messages.at(-1).params.target_size, [768, 1440]);
  assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
});

test('overlapping manual adjustments reject instead of silently replacing an admitted change', async t => {
  const f = fixture(t); await generated(f);
  const changing = f.manager.setUplinkQualityLevel(3);
  await assert.rejects(f.manager.setDownlinkQualityLevel(4), error => error.code === f.Code.INVALID_CONFIGURATION);
  await changing;
  assert.equal(f.manager.uplinkQualityLevel, 3);
  assert.equal(f.manager.downlinkQualityLevel, 2);
  await f.manager.setDownlinkQualityLevel(4);
  assert.equal(f.manager.downlinkQualityLevel, 4);
});

test('a manual selection from a network listener takes precedence over queued automatic work', async t => {
  const f = fixture(t); await generated(f);
  let adjustment;
  f.manager.setNetworkQualityListener(() => { adjustment ??= f.manager.setUplinkQualityLevel(4); });
  await qualitySamples(f, 'BAD', 'BAD', 1);
  await adjustment;
  assert.equal(f.manager.uplinkQualityLevel, 4);
  assert.equal(f.manager.downlinkQualityLevel, 2);
  assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
});

test('poor uplink independently changes real RTC encoding, persists across reconnect and preserves generation and media', async t => {
  const f = fixture(t), { task } = await generated(f);
  const media = f.media.currentTrack.videoFormat;
  const before = f.rtc.encodings.length;
  await qualitySamples(f, 'BAD', 'UNKNOWN');
  const last = f.rtc.encodings.at(-1);
  assert.equal(f.rtc.encodings.length, before + 1);
  assert.deepEqual([last.width, last.height, last.frameRate, last.minimumBitrate], [768, 1440, 24, 100]);
  assert.equal(f.manager.streamController.qualityConfiguration.uplinkLevel, 3);
  assert.equal(f.manager.streamController.qualityConfiguration.downlinkLevel, 2);
  assert.equal(f.media.currentTrack.videoFormat, media);
  assert.equal(f.manager.currentState.taskId, task);
  assert.equal(f.messages.filter(m => m.event === 'start').length, 1);
  assert.equal(f.messages.filter(m => m.event === 'change_target_size').length, 0);
  await f.manager.disconnect();
  await generated(f);
  assert.equal(f.manager.streamController.qualityConfiguration.uplinkLevel, 3);
  assert.equal(f.rtc.encodings.at(-1).width, 768);
});

test('poor downlink updates return signaling and remote metadata without touching capture or normalized trajectories', async t => {
  const f = fixture(t), { task, remote } = await generated(f);
  const media = f.media.currentTrack.videoFormat;
  const encoded = f.rtc.encodings.length;
  await qualitySamples(f, 'UNKNOWN', 'VERY_BAD');
  const event = f.messages.at(-1);
  assert.equal(event.event, 'change_target_size');
  assert.equal(event.uid, task);
  assert.deepEqual(event.params.target_size, [768, 1440]);
  assert.equal(event.params.min_bitrate, 100);
  assert.ok(event.params.max_bitrate >= 100 && event.params.max_bitrate <= 10000);
  assert.deepEqual(Object.keys(event.params).sort(), ['max_bitrate', 'min_bitrate', 'target_size']);
  assert.equal(f.rtc.encodings.length, encoded);
  assert.equal(f.media.currentTrack.videoFormat, media);
  assert.deepEqual([remote.videoTrack.videoFormat.width, remote.videoTrack.videoFormat.height], [768, 1440]);
  const { TrajectoryRegistry } = f.load('rendering/trajectory/TrajectoryRegistry.ets');
  const { VideoContentMode } = f.load('foundation/media/video/VideoContentMode.ets');
  const binding = TrajectoryRegistry.binding(remote.videoTrack);
  assert.deepEqual({ ...binding.resolvedMediaSize }, { width: 1024, height: 1920 });
  binding.submit([{ x: 0.431231 * 1024, y: 0.56931 * 1920 }], 1024, 1920, VideoContentMode.FIT);
  assert.deepEqual(f.messages.at(-1).tracks, [[0.431231, 0.56931]]);
  assert.equal(f.messages.filter(m => m.event === 'start').length, 1);
  assert.equal(f.manager.currentState.taskId, task);
});

test('encoder failure retains its tier and generation; a later sample window can retry successfully', async t => {
  const f = fixture(t), { task } = await generated(f);
  f.rtc.failEncoding = new f.XmaxError(f.Code.RTC_ERROR, 'encoding failed');
  await qualitySamples(f, 'BAD', 'UNKNOWN');
  assert.equal(f.manager.streamController.qualityConfiguration.uplinkLevel, 2);
  assert.equal(f.manager.currentState.taskId, task);
  assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
  assert.deepEqual(f.errors, []);
  f.rtc.failEncoding = undefined;
  await qualitySamples(f, 'BAD', 'UNKNOWN');
  assert.equal(f.manager.streamController.qualityConfiguration.uplinkLevel, 3);
});

test('return signal failure preserves expected dimensions and retries without disconnecting', async t => {
  const f = fixture(t), { remote, task } = await generated(f);
  const previous = remote.videoTrack.videoFormat;
  f.rtc.failTarget = new f.XmaxError(f.Code.RTC_ERROR, 'send failed');
  await qualitySamples(f, 'UNKNOWN', 'BAD');
  assert.equal(f.manager.streamController.qualityConfiguration.downlinkLevel, 2);
  assert.equal(remote.videoTrack.videoFormat, previous);
  assert.equal(f.manager.currentState.taskId, task);
  assert.deepEqual(f.errors, []);
  f.rtc.failTarget = undefined;
  await qualitySamples(f, 'UNKNOWN', 'BAD');
  assert.equal(f.manager.streamController.qualityConfiguration.downlinkLevel, 3);
  assert.equal(remote.videoTrack.videoFormat.width, 768);
});

test('application network listeners can disconnect before adaptation and old-task samples cannot affect reconnect', async t => {
  const f = fixture(t);
  await generated(f);
  const oldListener = f.manager.streamController.qualityController.adaptiveListener;
  await qualitySamples(f, 'BAD', 'BAD', 3);
  const count = f.rtc.encodings.length;
  let closing;
  f.manager.setNetworkQualityListener(() => { closing ??= f.manager.disconnect(); });
  await qualitySamples(f, 'BAD', 'BAD', 1);
  await closing;
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
  assert.equal(f.rtc.encodings.length, count);
  assert.equal(f.messages.filter(m => m.event === 'change_target_size').length, 0);
  f.manager.setNetworkQualityListener(null);
  const next = await generated(f);
  const { RealtimeNetworkQuality, RealtimeNetworkQualityLevel } = f.load('service/realtime/RealtimeNetworkQuality.ets');
  const baseline = f.manager.streamController.qualityConfiguration;
  oldListener(new RealtimeNetworkQuality(RealtimeNetworkQualityLevel.BAD, RealtimeNetworkQualityLevel.BAD), 0);
  await settle();
  assert.equal(f.manager.currentState.taskId, next.task);
  assert.equal(f.manager.streamController.qualityConfiguration.uplinkLevel, baseline.uplinkLevel);
  assert.equal(f.manager.streamController.qualityConfiguration.downlinkLevel, baseline.downlinkLevel);
});

test('public statistics listeners follow publication, matched SEI, remote removal and reconnection', async t => {
  const f = fixture(t), up = [], down = [];
  const { UplinkVideoStatistics: Up, DownlinkVideoStatistics: Down } = f.load('foundation/rtc/VideoStatistics.ets');
  const uplink = new Up(640, 360), downlink = new Down('bot', 640, 360);
  f.manager.setUplinkVideoStatisticsListener(s => up.push(s));
  f.manager.setDownlinkVideoStatisticsListener(s => down.push(s));
  f.rtc.qualityListener.onUplinkVideoStatistics(uplink);
  const first = await f.begin();
  f.rtc.qualityListener.onUplinkVideoStatistics(uplink);
  f.rtc.qualityListener.onDownlinkVideoStatistics(downlink);
  await settle();
  assert.equal(up.at(-1), uplink);
  assert.equal(down.includes(downlink), false);
  f.sei('wrong-task');
  f.rtc.qualityListener.onDownlinkVideoStatistics(downlink); await settle();
  assert.equal(down.includes(downlink), false);
  f.sei(first.task); f.frame(); await first.pending;
  f.rtc.qualityListener.onDownlinkVideoStatistics(new Down('someone-else'));
  f.rtc.qualityListener.onDownlinkVideoStatistics(downlink); await settle();
  assert.equal(down.at(-1), downlink);
  f.rtc.listener.onRemoteVideoPublished('bot', false); await settle();
  assert.equal(down.at(-1), undefined);
  f.rtc.qualityListener.onDownlinkVideoStatistics(downlink); await settle();
  assert.equal(down.at(-1), undefined);
  await f.manager.disconnect(); await settle();
  assert.equal(up.at(-1), undefined);
  const count = up.length;
  f.rtc.qualityListener.onUplinkVideoStatistics(uplink); await settle();
  assert.equal(up.length, count);
  const second = await f.begin();
  f.sei(second.task); f.frame(); await second.pending;
  f.rtc.qualityListener.onUplinkVideoStatistics(uplink);
  f.rtc.qualityListener.onDownlinkVideoStatistics(downlink); await settle();
  assert.equal(up.at(-1), uplink); assert.equal(down.at(-1), downlink);
});

test('static restart retains the connection and completes at matching SEI without requiring idle video', async t => {
  const f = fixture(t);
  const { RealtimeContext } = f.load('service/realtime/RealtimeContext.ets');
  const local = await f.manager.createLocalImageStream('cat');
  const options = { localStream: local, context: new RealtimeContext('', 'https://example.test/cat.jpg'),
    extraParams: { static_generate: true, static_image_path: 'https://example.test/cat.jpg' } };
  const initial = outcome(f.manager.startGeneration(options));
  await settle();
  const first = f.messages.filter(m => m.event === 'start').at(-1);
  assert.equal(first.params.static_generate, true);
  assert.equal(first.params.ref_image_path, 'https://example.test/cat.jpg');
  assert.equal(first.params.padding, 'contain');
  f.sei(first.uid); await settle(); f.frame();
  const initialResult = await initial;
  assert.ok(!initialResult.error);
  let finished = false;
  const restart = outcome(f.manager.startGeneration({ restart: true })).then(result => {
    finished = true; return result;
  });
  await settle();
  const second = f.messages.filter(m => m.event === 'start').at(-1);
  assert.notEqual(first.uid, second.uid);
  assert.equal(f.manager.currentState.sessionId, 'session');
  f.sei(first.uid); f.frame(); await settle();
  assert.equal(finished, false);
  f.sei(second.uid); await settle();
  assert.equal(finished, true);
  assert.equal([...f.timers.values()].some(timer => timer.ms === 10000), false);
  const result = await restart;
  assert.ok(!result.error);
  assert.equal(result.value.videoTrack.id, initialResult.value.videoTrack.id);
  assert.equal(f.media.task, second.uid);
  assert.equal(second.params.static_image_path, 'https://example.test/cat.jpg');
  assert.equal(second.params.ref_image_path, 'https://example.test/cat.jpg');
});


test('static task confirmation does not replay early drags and enables subsequent live samples', async t => {
  const f = fixture(t);
  const { RealtimeContext } = f.load('service/realtime/RealtimeContext.ets');
  const { VideoContentMode } = f.load('foundation/media/video/VideoContentMode.ets');
  const local = await f.manager.createLocalImageStream('cat');
  await f.manager.connect(local);
  f.media.submit({ points: [{ x: 100, y: 100 }], viewportWidth: 200,
    viewportHeight: 200, contentMode: VideoContentMode.FILL });
  const pending = outcome(f.manager.startGeneration({ localStream: local,
    context: new RealtimeContext(''), extraParams: {
      static_generate: true, static_image_path: 'https://example.test/cat.jpg'
    } }));
  await settle();
  const task = f.messages.filter(message => message.event === 'start').at(-1).uid;
  assert.equal(f.messages.some(message => message.event === 'tracks'), false);
  f.sei(task); await settle();
  const result = await pending;
  assert.ok(!result.error);
  assert.equal(f.messages.some(message => message.event === 'tracks'), false);
  f.media.submit({ points: [{ x: 120, y: 100 }], viewportWidth: 200,
    viewportHeight: 200, contentMode: VideoContentMode.FILL });
  const tracks = f.messages.filter(message => message.event === 'tracks');
  assert.equal(tracks.length, 1);
  assert.equal(tracks[0].uid, task);
  assert.deepEqual(tracks[0].tracks, [[0.6, 0.5]]);
  assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
  const timing = f.timingLogs.at(-1).message;
  assert.match(timing, /静态生成任务确认耗时/);
  assert.doesNotMatch(timing, /首帧就绪/);
});

test('static server acknowledgement enables live tracks without SEI and late SEI binds video once', async t => {
  const f = fixture(t);
  const { RealtimeContext } = f.load('service/realtime/RealtimeContext.ets');
  const { VideoContentMode } = f.load('foundation/media/video/VideoContentMode.ets');
  const { VideoRenderRegistry } = f.load('rendering/video/VideoRenderRegistry.ets');
  const local = await f.manager.createLocalImageStream('cat');
  const remote = await f.manager.connect(local);
  const ready = [];
  VideoRenderRegistry.attach(remote.videoTrack, 'surface', VideoContentMode.FIT, () => {}, () => {},
    value => ready.push(value));
  const pending = outcome(f.manager.startGeneration({ localStream: local,
    context: new RealtimeContext(''), extraParams: {
      static_generate: true, static_image_path: 'https://example.test/cat.jpg'
    } }));
  await settle();
  const task = f.messages.filter(message => message.event === 'start').at(-1).uid;
  const signal = JSON.stringify({ event: 'video_started', uid: task.split('?')[0] });
  const sample = { points: [{ x: 100, y: 100 }], viewportWidth: 200,
    viewportHeight: 200, contentMode: VideoContentMode.FILL };
  f.media.submit(sample);
  f.rtc.listener.onRoomSignalReceived('bot', signal);
  await settle();
  assert.ok(!(await pending).error);
  assert.equal(f.manager.currentState.connectionState, f.State.GENERATING);
  assert.equal(f.messages.some(message => message.event === 'tracks'), false);
  assert.equal(ready.includes(true), false, 'server ack must not reveal an old frame');
  assert.equal(f.events.some(event => event === 'audio:bot:true'), false);
  assert.equal([...f.timers.values()].some(timer => timer.ms === 30000), false);
  f.media.submit(sample);
  assert.equal(f.messages.filter(message => message.event === 'tracks').length, 1);
  assert.equal(f.messages.at(-1).uid, task);
  f.rtc.listener.onRoomSignalReceived('bot', signal);
  f.sei(task); await settle();
  assert.equal(f.events.filter(event => event === 'bind-surface').length, 1);
  assert.equal(f.events.filter(event => event === 'audio:bot:true').length, 1);
  f.sei(task);
  assert.equal(f.events.filter(event => event === 'bind-surface').length, 1);
  f.rtc.renderedListener(f.remote);
  assert.equal(ready.at(-1), true);
  VideoRenderRegistry.detach(remote.videoTrack, 'surface');
  await f.manager.disconnect();
  f.rtc.listener.onRoomSignalReceived('bot', signal);
  assert.equal(f.manager.currentState.connectionState, f.State.READY);
});

test('static start acknowledgement rejects other tasks, senders and malformed payloads', async t => {
  const f = fixture(t);
  const { RealtimeContext } = f.load('service/realtime/RealtimeContext.ets');
  const local = await f.manager.createLocalImageStream('cat');
  await f.manager.connect(local);
  const pending = outcome(f.manager.startGeneration({ localStream: local,
    context: new RealtimeContext(''), extraParams: {
      static_generate: true, static_image_path: 'https://example.test/cat.jpg'
    } }));
  await settle();
  const task = f.messages.filter(message => message.event === 'start').at(-1).uid;
  let completed = false; pending.then(() => { completed = true; });
  for (const message of ['null', '{}', 'not-json', '{"event":"video_started","uid":42}',
    JSON.stringify({ event: 'video_completed', uid: task }),
    JSON.stringify({ event: 'video_started', uid: 'task-old' })]) {
    f.rtc.listener.onRoomSignalReceived('bot', message);
  }
  f.rtc.listener.onRoomSignalReceived('other', JSON.stringify({ event: 'video_started', uid: task }));
  await settle();
  assert.equal(completed, false);
  assert.equal(f.media.task, null);
  f.sei(task);
  assert.ok(!(await pending).error, 'existing SEI confirmation still works');
});

test('continuous generation still waits for matched SEI and a usable frame after server acknowledgement', async t => {
  const f = fixture(t), { pending, task } = await f.begin();
  let completed = false; pending.then(() => { completed = true; });
  f.rtc.listener.onRoomSignalReceived('bot', JSON.stringify({ event: 'video_started', uid: task }));
  await settle();
  assert.equal(completed, false);
  f.sei(task); await settle();
  assert.equal(completed, false);
  f.frame();
  assert.ok(!(await pending).error);
});

test('a static restart rejects the previous task acknowledgement and accepts the replacement without SEI', async t => {
  const f = fixture(t);
  const { RealtimeContext } = f.load('service/realtime/RealtimeContext.ets');
  const local = await f.manager.createLocalImageStream('cat');
  await f.manager.connect(local);
  const first = outcome(f.manager.startGeneration({ localStream: local,
    context: new RealtimeContext(''), extraParams: {
      static_generate: true, static_image_path: 'https://example.test/cat.jpg'
    } }));
  await settle();
  const firstTask = f.messages.filter(message => message.event === 'start').at(-1).uid;
  f.sei(firstTask);
  assert.ok(!(await first).error);
  const second = outcome(f.manager.startGeneration({ restart: true }));
  await settle();
  const task = f.messages.filter(message => message.event === 'start').at(-1).uid;
  let completed = false; second.then(() => { completed = true; });
  f.rtc.listener.onRoomSignalReceived('bot', JSON.stringify({ event: 'video_started', uid: firstTask }));
  f.sei(firstTask); await settle();
  assert.equal(completed, false);
  assert.equal(f.media.task, null);
  f.rtc.listener.onRoomSignalReceived('bot', JSON.stringify({ event: 'video_started', uid: task }));
  assert.ok(!(await second).error);
  assert.equal(f.media.task, task);
  assert.equal(f.manager.currentState.taskId, task);
});
