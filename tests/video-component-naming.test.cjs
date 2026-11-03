const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const video = path.join(root, 'xmax_sdk/src/main/ets/rendering/video');

test('public ArkUI video components use the SwiftUI-aligned names without legacy aliases', () => {
  const entry = fs.readFileSync(path.join(root, 'xmax_sdk/Index.ets'), 'utf8');
  for (const name of ['XmaxRealtimeVideo', 'XmaxRealtimeDualVideo']) {
    assert.match(entry, new RegExp(`export \\{ ${name} \\} from '\\./src/main/ets/rendering/video/${name}';`));
    const source = fs.readFileSync(path.join(video, `${name}.ets`), 'utf8');
    assert.ok(source.includes(`//  ${name}.ets`));
    assert.ok(source.includes(`export struct ${name} {`));
  }
  for (const name of ['XmaxVideoView', 'XmaxRealtimeVideoView']) {
    assert.doesNotMatch(entry, new RegExp(`\\b${name}\\b`));
    assert.equal(fs.existsSync(path.join(video, `${name}.ets`)), false);
  }
});

test('the dual-video component composes two single-track components and XLab uses the dual component', () => {
  const dual = fs.readFileSync(path.join(video, 'XmaxRealtimeDualVideo.ets'), 'utf8');
  assert.match(dual, /import \{ XmaxRealtimeVideo \} from '\.\/XmaxRealtimeVideo';/);
  assert.equal([...dual.matchAll(/\bXmaxRealtimeVideo\(\{/g)].length, 2);
  assert.match(dual, /track: this\.localTrack/);
  assert.match(dual, /track: this\.remoteTrack/);
  const example = fs.readFileSync(path.join(root,
    'examples/XLab/entry/src/main/ets/modules/xlrealtime/RealtimePage.ets'), 'utf8');
  assert.match(example, /XmaxRealtimeDualVideo\(\{/);
  const readme = fs.readFileSync(path.join(root, 'README.md'), 'utf8');
  assert.match(readme, /\bXmaxRealtimeDualVideo\b/);
  assert.doesNotMatch(readme, /\bXmaxRealtimeVideoView\b|\bXmaxVideoView\b/);
});
