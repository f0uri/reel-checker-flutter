// Run with: node --test test/preview_ui.test.js
const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');

const html = fs.readFileSync('assets/index.html', 'utf8');
const source = html.slice(html.indexOf('function onReelResult('), html.indexOf('/* ---- بحث عن حساب:'));

function setup() {
  const elements = {};
  const element = (id) => elements[id] ||= {
    style: {}, textContent: '', disabled: false,
    classList: {add() {}},
    removeAttribute(name) { delete this[name]; },
    querySelector() { return this.label ||= {}; },
    offsetWidth: 100,
  };
  const calls = [];
  const document = {getElementById: element, querySelector: () => element('eyebrow')};
  const AndroidBridge = {openPreview: (code) => calls.push(code)};
  const context = {document, AndroidBridge, window: {AndroidBridge}, current: null, showErr: () => {}};
  vm.createContext(context);
  vm.runInContext(source, context);
  return {context, element, calls};
}

test('video preview invokes native player with shortcode, not the signed URL', () => {
  const {context, element, calls} = setup();
  context.onReelResult(JSON.stringify({ok: true, shortcode: 'abc123', mediaType: 'video',
    videoUrl: 'https://cdn.example/video?token=secret', thumbUrl: 'data:image/jpeg;base64,AA', previewAvailable: true}));
  assert.equal(element('previewBtn').style.display, 'block');
  assert.equal(element('previewPoster').src, 'data:image/jpeg;base64,AA');
  assert.equal(element('photoPreview').style.display, 'none');
  context.openNativePreview();
  assert.deepEqual(calls, ['abc123']);
  assert.equal(context.current.videoUrl, 'https://cdn.example/video?token=secret');
});

test('image and carousel results do not display the native video button', () => {
  for (const mediaType of ['image', 'carousel']) {
    const {context, element} = setup();
    context.onReelResult(JSON.stringify({ok: true, mediaType, imageUrls: ['https://example.test/1.jpg']}));
    assert.equal(element('previewBtn').style.display, 'none');
    assert.equal(element('photoPreview').style.display, 'block');
  }
});

test('missing poster and unavailable native URL produce a disabled button', () => {
  const {context, element} = setup();
  context.onReelResult(JSON.stringify({ok: true, mediaType: 'video', previewAvailable: false}));
  assert.equal(element('previewBtn').disabled, true);
  assert.equal(element('previewPoster').style.display, 'none');
  assert.equal(element('previewBtn').label.textContent, 'المعاينة غير متاحة');
});

test('poster failure hides the broken image without removing the play button', () => {
  const {context, element} = setup();
  context.onReelResult(JSON.stringify({ok: true, shortcode: 'abc123', mediaType: 'video', thumbUrl: 'https://example.test/poster.jpg'}));
  element('previewPoster').style.display = 'block';
  element('previewPoster').onerror();
  assert.equal(element('previewPoster').style.display, 'none');
  assert.equal(element('previewBtn').style.display, 'block');
});
