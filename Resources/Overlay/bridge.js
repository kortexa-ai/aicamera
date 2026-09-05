// AICamera overlay bridge.
//
// Sets up a transparent three.js canvas and exposes `window.AICamera`, the
// only API an overlay script may use. The native side injects scripts via
// evaluateJavaScript and receives rendered frames as base64 strings through
// the "frame" message handler (WKScriptMessage cannot carry binary).
(function () {
  var lastLog = -Infinity;
  function log(msg) {
    var now = performance.now();
    if (now - lastLog < 250) return;
    lastLog = now;
    try { window.webkit.messageHandlers.log.postMessage(String(msg).slice(0, 512)); } catch (e) {}
  }
  var W = window.innerWidth;
  var H = window.innerHeight;
  var canvas = document.createElement('canvas');
  canvas.width = W;
  canvas.height = H;
  document.body.appendChild(canvas);

  var renderer;
  try {
    renderer = new THREE.WebGLRenderer({
      canvas: canvas,
      alpha: true,
      antialias: true,
      preserveDrawingBuffer: true
    });
  } catch (e) {
    log('WEBGL FAILED: ' + e);
    return;
  }
  renderer.setPixelRatio(1);
  renderer.setSize(W, H, false);
  var gl = renderer.getContext();

  var scene = new THREE.Scene();
  var camera = new THREE.PerspectiveCamera(50, W / H, 0.1, 100);
  camera.position.set(0, 0, 6);
  function addDefaultLights() {
    scene.add(new THREE.AmbientLight(0xffffff, 0.55));
    var dir = new THREE.DirectionalLight(0xffffff, 0.9);
    dir.position.set(2, 3, 4);
    scene.add(dir);
  }
  addDefaultLights();

  var TARGET_FPS = 30;
  var onFrameCb = null;
  var active = false;
  var last = performance.now();
  var lastPost = 0;
  var seq = 0;
  var generation = '';
  var pendingFrame = null;
  // WebKit's WebGL2 readPixels only accepts an ArrayBufferView destination.
  var pixelView = new Uint8Array(W * H * 4);

  function bufToBase64(buf) {
    var bytes = new Uint8Array(buf);
    var binary = '';
    var chunk = 0x8000;
    for (var i = 0; i < bytes.length; i += chunk) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
    }
    return btoa(binary);
  }

  function postFrame(renderMs, readMs) {
    var t0 = performance.now();
    var b64 = bufToBase64(pixelView.buffer);
    var encMs = performance.now() - t0;
    window.webkit.messageHandlers.frame.postMessage({
      seq: seq,
      generation: generation,
      w: W,
      h: H,
      b64: b64,
      renderMs: renderMs,
      readMs: readMs,
      encMs: encMs,
      wallMs: Date.now()
    });
    pendingFrame = seq;
    seq += 1;
  }

  function pump() {
    requestAnimationFrame(pump);
    if (!active) return;
    var now = performance.now();
    var dt = Math.min(0.1, (now - last) / 1000);
    last = now;
    try {
      if (onFrameCb) onFrameCb(dt);
    } catch (e) {
      log('onFrame error: ' + e);
    }
    var t1 = performance.now();
    renderer.render(scene, camera);
    var t2 = performance.now();
    if (pendingFrame === null && now - lastPost >= 1000 / TARGET_FPS - 1) {
      gl.readPixels(0, 0, W, H, gl.RGBA, gl.UNSIGNED_BYTE, pixelView);
      var t3 = performance.now();
      lastPost = now;
      postFrame(t2 - t1, t3 - t2);
    }
  }
  requestAnimationFrame(pump);

  var api = {
    width: W,
    height: H,
    scene: scene,
    camera: camera,
    renderer: renderer,
    onFrame: function (fn) {
      onFrameCb = typeof fn === 'function' ? fn : null;
    },
    requestRender: function () {
      lastPost = 0;
    },
    sceneData: null,
    log: log
  };
  api._reset = function () {
    active = false;
    onFrameCb = null;
    while (scene.children.length) {
      var child = scene.children[0];
      scene.remove(child);
      if (child.geometry) child.geometry.dispose();
      if (child.material) {
        (Array.isArray(child.material) ? child.material : [child.material]).forEach(function (m) {
          m.dispose();
        });
      }
    }
    addDefaultLights();
  };
  api._activate = function (fps, currentGeneration) {
    generation = currentGeneration;
    pendingFrame = null;
    if (fps) TARGET_FPS = Math.min(60, Math.max(1, fps));
    active = true;
    last = performance.now();
    lastPost = 0;
  };
  api._ackFrame = function (currentGeneration, sequence) {
    if (generation === currentGeneration && pendingFrame === sequence) pendingFrame = null;
  };
  api._deactivate = function () {
    active = false;
  };
  api._setSceneData = function (json) {
    api.sceneData = json;
  };
  window.AICamera = api;
  window.addEventListener('error', function (e) { log('PAGE ERROR: ' + e.message); });
  log('bridge ready ' + W + 'x' + H);
})();
