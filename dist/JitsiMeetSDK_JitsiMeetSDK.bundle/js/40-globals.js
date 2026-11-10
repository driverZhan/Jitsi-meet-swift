/*
 * 40-globals.js — the browser surface lib-jitsi-meet probes at load time.
 *
 * `navigator.product = 'ReactNative'` is deliberate: it makes BrowserCapabilities
 * report isReactNative() true, which is the code path lib-jitsi-meet already runs
 * outside a browser (Jitsi's React Native SDK). The UA also carries an iOS token so
 * getOS() resolves to iOS for the few places that branch on the platform itself.
 */
(function (global) {
  'use strict';

  const Native = global.__JitsiNative;
  const environment = Native.callSync('env.describe', {}) || {};

  // A minimal html/head/body tree, so ScriptUtil/append-style code has a target.
  const html = global.document.createElement('html');
  const head = global.document.createElement('head');
  const body = global.document.createElement('body');
  html.appendChild(head);
  html.appendChild(body);
  global.document.appendChild(html);

  global.document.title = 'JitsiMeet';
  global.document.cookie = '';
  global.document.readyState = 'complete';
  global.document.activeElement = body;
  global.document.defaultView = global;

  Object.defineProperty(global.document, 'visibilityState', {
    get: () => environment.visible ? 'visible' : 'hidden'
  });

  // ---------------------------------------------------------------------------
  // window / self
  // ---------------------------------------------------------------------------
  const windowListeners = new Map();

  global.self = global;
  global.window = global;
  global.top = global;
  global.parent = global;
  global.frames = global;

  global.addEventListener = function (type, handler) {
    if (!windowListeners.has(type)) {
      windowListeners.set(type, []);
    }
    windowListeners.get(type).push(handler);
  };

  global.removeEventListener = function (type, handler) {
    const handlers = windowListeners.get(type);
    if (handlers) {
      const index = handlers.indexOf(handler);
      if (index >= 0) {
        handlers.splice(index, 1);
      }
    }
  };

  global.dispatchEvent = function (event) {
    for (const handler of (windowListeners.get(event.type) || []).slice()) {
      handler(event);
    }
    return true;
  };

  Native.on('env', 'visibility', payload => {
    const event = new global.Event('visibilitychange');
    event.hidden = !payload.visible;
    global.dispatchEvent(event);
  });

  global.screen = {
    width: environment.screenWidth || 0,
    height: environment.screenHeight || 0,
    availWidth: environment.screenWidth || 0,
    availHeight: environment.screenHeight || 0,
    orientation: { angle: 0, type: 'landscape-primary', lock: () => Promise.resolve() }
  };

  global.innerWidth = global.screen.width;
  global.innerHeight = global.screen.height;
  global.devicePixelRatio = environment.scale || 2;
  global.isSecureContext = true;

  const origin = environment.origin || 'https://' + (environment.hostname || 'meet.jitsi');
  global.location = {
    href: origin + '/',
    protocol: 'https:',
    host: environment.hostname || 'meet.jitsi',
    hostname: environment.hostname || 'meet.jitsi',
    origin,
    pathname: '/',
    search: '',
    hash: '',
    reload() {}
  };

  global.history = {
    length: 1,
    state: null,
    pushState() {},
    replaceState() {},
    back() {},
    forward() {},
    go() {}
  };

  // ---------------------------------------------------------------------------
  // navigator
  // ---------------------------------------------------------------------------
  const mediaSources = new Map();
  let blobCounter = 1;

  // 30-webrtc.js already attached `navigator.mediaDevices`; merge into that object
  // instead of replacing it.
  const navigator = global.navigator = global.navigator || {};

  Object.assign(navigator, {
    product: 'ReactNative',
    appName: 'JitsiMeetSDK',
    appCodeName: 'Mozilla',
    platform: environment.platform || 'iOS',
    // Keep this free of a "ReactNative/x.y.z" token: lib-jitsi-meet's BrowserDetection prefers
    // the UA token and compares it with 'react-native', so the token would defeat isReactNative().
    userAgent: environment.userAgent || 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 JitsiNative/1.0',
    language: environment.language || 'en-US',
    languages: [environment.language || 'en-US'],
    onLine: environment.online !== false,
    hardwareConcurrency: environment.cpuCount || 4,
    maxTouchPoints: 5,
    doNotTrack: null,
    geolocation: null,
    serviceWorker: undefined,
    vibrate: () => false,
    reactNativeVersion: environment.reactNativeVersion || null
  });

  navigator.mediaDevices = navigator.mediaDevices || {};

  global.navigator.getUserMedia = function (constraints, success, error) {
    global.navigator.mediaDevices.getUserMedia(constraints).then(success, error);
  };

  global.crypto = global.crypto || {
    getRandomValues(typedArray) {
      const bytes = Native.callSync('crypto.randomBytes', { length: typedArray.length });
      if (bytes && bytes.bytes) {
        for (let i = 0; i < typedArray.length; i++) {
          typedArray[i] = bytes.bytes[i];
        }
      }
      return typedArray;
    },
    randomUUID() {
      const result = Native.callSync('crypto.randomUUID', {});
      return (result && result.uuid) || fallbackUUID();
    },
    subtle: undefined
  };

  function fallbackUUID() {
    let output = '';
    for (let i = 0; i < 36; i++) {
      if (i === 14) {
        output += '-';
      } else if (i === 19) {
        output += '4';
      } else {
        output += '0123456789abcdef'[Math.floor(Math.random() * 16)];
      }
    }
    return output;
  }

  // ---------------------------------------------------------------------------
  // Blob / URL / Worker.
  // E2EEContext builds a Worker from `URL.createObjectURL(new Blob([source]))`, so a
  // same-thread Worker implementation is enough to load that code path; it runs the
  // worker source in this context instead of a second thread.
  // ---------------------------------------------------------------------------
  global.Blob = class Blob {
    constructor(parts, options) {
      this.type = (options && options.type) || '';
      this.__text = (parts || []).map(part =>
        typeof part === 'string' ? part : String(part)).join('');
      this.size = this.__text.length;
    }

    text() {
      return Promise.resolve(this.__text);
    }

    arrayBuffer() {
      return Promise.resolve(new ArrayBuffer(0));
    }
  };

  global.File = class File extends global.Blob {
    constructor(parts, name, options) {
      super(parts, options);
      this.name = name;
      this.lastModified = Date.now();
    }
  };

  global.FileReader = class FileReader extends global.EventTarget {
    constructor() {
      super();
      this.result = null;
      this.readyState = 0;
    }

    readAsText(blob) {
      this.result = blob.__text;
      this.readyState = 2;
      this.dispatchEvent(new global.Event('load'));
    }

    readAsDataURL() {
      this.readyState = 2;
      this.dispatchEvent(new global.Event('load'));
    }
  };

  global.URL = {
    createObjectURL(blob) {
      const url = 'blob:jitsi/' + blobCounter++;
      mediaSources.set(url, blob.__text);
      return url;
    },
    revokeObjectURL(url) {
      mediaSources.delete(url);
    },
    parseURL(input) {
      const match = /^(?:([a-zA-Z][\w+.-]*):)?(?:\/\/([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?$/
        .exec(String(input));
      return {
        protocol: (match && match[1] ? match[1] : global.location.protocol).replace(/:$/, ''),
        host: (match && match[2]) || global.location.host,
        pathname: (match && match[3]) || '/',
        search: (match && match[4]) || '',
        hash: (match && match[5]) || ''
      };
    }
  };

  global.Worker = class Worker extends global.EventTarget {
    constructor(scriptURL, options) {
      super();
      this.name = (options && options.name) || 'Worker';
      this.onmessage = null;
      this.onerror = null;
      this.__terminated = false;
      this.__source = mediaSources.get(String(scriptURL));
      if (this.__source === undefined) {
        // Remote workers (olm, watchrtc) must be pre-bundled into the JS resources.
        this.__source = null;
        console.warn('Worker: no bundled source for ' + scriptURL);
      }
      this.__scope = this.__source === null ? null : buildWorkerScope(this);
      if (this.__scope) {
        Promise.resolve().then(() => this.dispatchEvent(new global.Event('message')));
      }
    }

    postMessage(data, transfer) {
      if (this.__terminated || !this.__scope) {
        return;
      }
      const event = new global.Event('message');
      event.data = data;
      event.ports = transfer || [];
      this.__scope.deliver(event);
    }

    terminate() {
      this.__terminated = true;
      if (this.__scope) {
        this.__scope.close();
      }
    }
  };

  /**
   * A worker's `self` is a fresh object with its own message handlers; keeping it out
   * of `globalThis` stops a worker from clobbering the main context's globals.
   */
  function buildWorkerScope(worker) {
    const scope = {
      onmessage: null,
      onerror: null,
      console: global.console,
      setTimeout: global.setTimeout,
      setInterval: global.setInterval,
      clearTimeout: global.clearTimeout,
      clearInterval: global.clearInterval,
      Math,
      Date,
      JSON,
      Error,
      Map,
      Set,
      Promise,
      Uint8Array,
      Uint16Array,
      Uint32Array,
      Int16Array,
      Int32Array,
      Float32Array,
      ArrayBuffer,
      DataView,
      TextEncoder: global.TextEncoder,
      TextDecoder: global.TextDecoder,
      performance: global.performance,
      postMessage(data) {
        const event = new global.Event('message');
        event.data = data;
        worker.dispatchEvent(event);
        if (typeof worker.onmessage === 'function') {
          worker.onmessage(event);
        }
      }
    };
    scope.self = scope;
    scope.globalThis = scope;

    let started = false;
    return {
      scope,
      deliver(event) {
        if (!started) {
          started = true;
          try {
            Native.sync('worker.eval', { source: worker.__source, name: worker.name });
            Native.callSync('worker.bootstrap', { name: worker.name });
          } catch (error) {
            console.error('Worker failed to start', error);
            return;
          }
        }
        try {
          Native.sync('worker.message', { name: worker.name, data: event.data });
        } catch (error) {
          console.error('Worker message failed', error);
        }
      },
      close() {
        Native.sync('worker.close', { name: worker.name });
      }
    };
  }

  // ---------------------------------------------------------------------------
  // Capability flags surfaced to the SDK and to lib-jitsi-meet
  // ---------------------------------------------------------------------------
  global.__jitsiHostCapabilities = {
    encodedTransform: false,
    e2ee: false,
    audioWorklet: false,
    webRTC: !!environment.mediaBackendReady,
    dataChannel: true,
    host: 'jitsi-ios-native-shim',
    version: 1
  };

  global.HTMLElement = class HTMLElement extends global.EventTarget {};
  global.HTMLAudioElement = class HTMLAudioElement extends global.HTMLElement {
    constructor() {
      super();
      this.srcObject = null;
      this.src = '';
      this.volume = 1;
      this.muted = false;
      this.paused = true;
    }

    play() {
      this.paused = false;
      return Promise.resolve();
    }

    pause() {
      this.paused = true;
      return Promise.resolve();
    }

    load() {}
  };

  global.HTMLVideoElement = class HTMLVideoElement extends global.HTMLAudioElement {};

  /**
   * BrowserCapabilities probes codec support with
   * `document.createElement('audio').canPlayType(...)`. The answer has to match the
   * linked libwebrtc build, so it is read from the native side rather than hardcoded.
   */
  const documentCreateElement = global.document.createElement.bind(global.document);
  global.document.createElement = function (tag, options) {
    const element = documentCreateElement(tag, options);
    if (/^(audio|video)$/i.test(tag)) {
      element.canPlayType = mimeType => {
        const supported = Native.callSync('media.canPlayType', { mimeType });
        if (!supported) {
          return '';
        }
        return supported.proficient ? 'probably' : 'maybe';
      };
      element.setSrcObject = stream => {
        element.srcObject = stream;
      };
      element.play = () => Promise.resolve();
      element.pause = () => {};
    }
    if (/^script$/i.test(tag)) {
      element.async = true;
      element.onload = null;
      element.onerror = null;
    }
    return element;
  };

  global.requestAnimationFrame = callback => global.setTimeout(() => callback(Date.now()), 16);
  global.cancelAnimationFrame = handle => global.clearTimeout(handle);

  global.HTMLElement.prototype.appendChild = function (child) {
    return child;
  };
})(globalThis);
