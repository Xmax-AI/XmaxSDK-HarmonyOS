function createCameraKitFixture(calls = [], options = {}) {
  const listeners = [], outputs = [];
  const front = { id: 'front', cameraPosition: 'front' };
  const back = { id: 'back', cameraPosition: 'back' };
  const profiles = options.profiles ?? [
    { format: 'yuv420sp', size: { width: 1920, height: 1440 } },
    { format: 'yuv420sp', size: { width: 1440, height: 1080 } }
  ];

  const cameraManager = {
    getSupportedCameras() { return options.devices ?? [front, back]; },
    getSupportedOutputCapability(device, mode) {
      calls.push(['camera-capability', device.id, mode]);
      return { previewProfiles: profiles };
    },
    createCameraInput(device) {
      calls.push(['camera-input', device.id]);
      return {
        deviceId: device.id,
        async open() { calls.push(['camera-open', device.id]); },
        async close() { calls.push(['camera-close', device.id]); }
      };
    },
    createSession(mode) {
      calls.push(['camera-session', mode]);
      let attachedOutput, deviceId, zoomRatio = 1;
      return {
        beginConfig() { calls.push(['camera-begin-config']); },
        canAddInput() { return true; },
        addInput(input) { deviceId = input.deviceId; calls.push(['camera-add-input']); },
        canAddOutput() { return true; },
        addOutput(output) { attachedOutput = output; calls.push(['camera-add-output']); },
        async commitConfig() {
          calls.push(['camera-commit']);
          if (options.commitError) throw options.commitError;
          attachedOutput.committed = true;
        },
        async start() { calls.push(['camera-start']); },
        getZoomRatioRange() {
          if (options.zoomQueryError) throw options.zoomQueryError;
          return options.zoomRanges?.[deviceId] ?? [];
        },
        getZoomRatio() { return zoomRatio; },
        setZoomRatio(ratio) {
          if (options.zoomError) throw options.zoomError;
          zoomRatio = ratio;
          calls.push(['camera-zoom', deviceId, ratio]);
        },
        async stop() { calls.push(['camera-stop']); },
        async release() {
          if (attachedOutput) attachedOutput.committed = false;
          calls.push(['camera-session-release']);
        }
      };
    }
  };

  class CameraFrameOutput {
    static create(_manager, selectedProfile, _position, listener) {
      calls.push(['camera-frame-output', selectedProfile.size.width, selectedProfile.size.height]);
      listeners.push(listener);
      const frameOutput = {
        currentVideoFormat: null,
        output: {
          committed: false,
          getSupportedFrameRates() {
            calls.push(['camera-query-frame-rates', this.committed]);
            if (!this.committed) return [];
            if (options.queryError) throw options.queryError;
            return selectedProfile.frameRates ?? [{ min: 1, max: 30 }];
          },
          setFrameRate(min, max) {
            if (!this.committed) throw new Error('Session not committed');
            if (options.frameRateError) throw options.frameRateError;
            calls.push(['camera-frame-rate', min, max]);
          }
        },
        configure(format, fps, _observeDisplayChange, preserveDimensions = false) {
          this.currentVideoFormat = options.landscape && !preserveDimensions ?
            { width: Math.max(format.width, format.height), height: Math.min(format.width, format.height), fps: format.fps } : format;
          calls.push(['camera', this.currentVideoFormat.width, this.currentVideoFormat.height, fps]);
        },
        updateOrientation() {
          if (options.landscape && this.currentVideoFormat) {
            this.currentVideoFormat = { ...this.currentVideoFormat,
              width: Math.max(this.currentVideoFormat.width, this.currentVideoFormat.height),
              height: Math.min(this.currentVideoFormat.width, this.currentVideoFormat.height) };
          }
        },
        async release() { calls.push(['camera-output-release']); }
      };
      outputs.push(frameOutput);
      return frameOutput;
    }
  }

  return {
    kit: { camera: {
      CameraPosition: { CAMERA_POSITION_FRONT: 'front', CAMERA_POSITION_BACK: 'back' },
      CameraFormat: { CAMERA_FORMAT_YUV_420_SP: 'yuv420sp' },
      SceneMode: { NORMAL_VIDEO: 'normal-video' },
      getCameraManager() { return cameraManager; }
    } },
    frameOutput: { CameraFrameOutput },
    emit(frame, outputIndex = listeners.length - 1) {
      if (!frame.format) frame.format = outputs[outputIndex].currentVideoFormat;
      listeners[outputIndex](frame);
    },
    outputs,
    listeners
  };
}

module.exports = { createCameraKitFixture };
