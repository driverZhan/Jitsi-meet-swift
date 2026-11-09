/*
 * 00-native.js — the Swift <-> JavaScript boundary.
 *
 * One bridged entry point, `__nativeReceive(jsonString)`, installed by JSCEngineHost.
 * Two modes:
 *   call  -> returns a Promise, resolved later by __nativeResolve/__nativeReject
 *   sync  -> fire-and-forget (timers, log, storage) so hot paths never await
 *
 * Native -> JS traffic:
 *   __nativeResolve(callId, payload)
 *   __nativeReject(callId, message)
 *   __nativeEmit(channel, name, payload)
 */
(function (global) {
  'use strict';

  const pending = new Map();
  const listeners = new Map();
  let nextCallId = 1;

  function channelKey(channel, name) {
    return channel + '::' + name;
  }

  function emit(channel, name, payload) {
    const handlers = listeners.get(channelKey(channel, name));
    if (!handlers || !handlers.length) {
      return;
    }
    for (const handler of handlers.slice()) {
      try {
        handler(payload);
      } catch (error) {
        // A throwing listener must not break the delivery loop for the others.
        console.error('[shim] listener failed for ' + channel + '.' + name, error);
      }
    }
  }

  global.__nativeResolve = function (callId, payload) {
    const entry = pending.get(callId);
    if (!entry) {
      return;
    }
    pending.delete(callId);
    entry.resolve(payload);
  };

  global.__nativeReject = function (callId, message) {
    const entry = pending.get(callId);
    if (!entry) {
      return;
    }
    pending.delete(callId);
    entry.reject(new Error(typeof message === 'string' ? message : 'native call failed'));
  };

  global.__nativeEmit = emit;

  // ---------------------------------------------------------------------------
  // Swift -> JS. JavaScriptCore drains its microtask queue when the outermost JS
  // execution returns, so the promise `__sdkInvoke` hands back and the callbacks for
  // it have to be wired inside one execution. Calling `.then` on it from Swift in a
  // second `call(withArguments:)` queues a reaction that nothing ever drains.
  // ---------------------------------------------------------------------------
  global.__sdkSettle = function (method, argsJSON, resolve, reject) {
    try {
      Promise.resolve(__sdkInvoke({ method: method, args: JSON.parse(argsJSON) })).then(
        function (value) { resolve(value); },
        function (error) { reject(String((error && error.message) || error)); }
      );
    } catch (error) {
      reject(String((error && error.message) || error));
    }
  };

  const Native = {
    /** Awaitable native module call, e.g. Native.call('pc.createOffer', { pcId }). */
    call(moduleMethod, args) {
      if (typeof global.__nativeReceive !== 'function') {
        return Promise.reject(new Error('native bridge not installed'));
      }
      const callId = nextCallId++;
      return new Promise((resolve, reject) => {
        pending.set(callId, { resolve, reject });
        global.__nativeReceive(JSON.stringify({
          mode: 'call',
          id: callId,
          method: moduleMethod,
          args: args === undefined ? {} : args
        }));
      });
    },

    /** Fire-and-forget; returns immediately, no microtask hop. */
    sync(moduleMethod, args) {
      if (typeof global.__nativeReceive !== 'function') {
        return;
      }
      global.__nativeReceive(JSON.stringify({
        mode: 'sync',
        method: moduleMethod,
        args: args === undefined ? {} : args
      }));
    },

    on(channel, name, handler) {
      const key = channelKey(channel, name);
      if (!listeners.has(key)) {
        listeners.set(key, []);
      }
      listeners.get(key).push(handler);
      return () => {
        const handlers = listeners.get(key);
        if (!handlers) {
          return;
        }
        const index = handlers.indexOf(handler);
        if (index >= 0) {
          handlers.splice(index, 1);
        }
      };
    }
  };

  global.__JitsiNative = Native;

  // ---------------------------------------------------------------------------
  // Timers. JavaScriptCore has none, and lib-jitsi-meet leans on them everywhere
  // (reconnect backoff, ICE retry, stats polling, debounce).
  // ---------------------------------------------------------------------------
  const timers = new Map();
  let nextTimerId = 1;

  function schedule(id, delay, repeat, callback) {
    timers.set(id, { repeat, callback });
    Native.sync('timer.set', { id, delay, repeat });
  }

  global.setTimeout = function (callback, delay) {
    const id = nextTimerId++;
    const extra = delay > 0 ? Array.prototype.slice.call(arguments, 2) : [];
    schedule(id, Math.max(0, delay | 0), false, () => callback.apply(global, extra));
    return id;
  };

  global.setInterval = function (callback, delay) {
    const id = nextTimerId++;
    const extra = delay > 0 ? Array.prototype.slice.call(arguments, 2) : [];
    schedule(id, Math.max(1, delay | 0), true, () => callback.apply(global, extra));
    return id;
  };

  function clear(id) {
    if (timers.has(id)) {
      timers.delete(id);
      Native.sync('timer.clear', { id });
    }
  }

  global.clearTimeout = clear;
  global.clearInterval = clear;

  // JavaScriptCore exposes neither `queueMicrotask` nor `setImmediate` through JSContext.
  // async-es (lib-jitsi-meet's Jingle modification queue) defers resumed work with the
  // first of those it finds and never executes it through the setTimeout fallback, which
  // left trickled ICE candidates queued forever and P2P ICE stuck in `checking`.
  if (typeof global.queueMicrotask !== 'function') {
    global.queueMicrotask = function (callback) {
      Promise.resolve().then(callback);
    };
  }
  if (typeof global.setImmediate !== 'function') {
    global.setImmediate = function (callback) {
      return global.setTimeout(callback, 0);
    };
  }

  Native.on('timer', 'fire', payload => {
    const timer = timers.get(payload.id);
    if (!timer) {
      return;
    }
    if (!timer.repeat) {
      timers.delete(payload.id);
    }
    timer.callback();
  });

  // ---------------------------------------------------------------------------
  // console -> native logging
  // ---------------------------------------------------------------------------
  const originalConsole = global.console || {};

  function forward(level) {
    return function () {
      const parts = Array.prototype.slice.call(arguments).map(value => {
        if (typeof value === 'string') {
          return value;
        }
        // An Error JSON-stringifies to '{}', which throws away the only thing worth logging.
        if (value instanceof Error) {
          return String(value.stack || value.message || value);
        }
        try {
          return JSON.stringify(value);
        } catch (error) {
          return String(value);
        }
      });
      // os_log drops everything past ~1 KB. Signaling tracing routinely logs whole
      // stanzas (SDP included), so split long messages into separate, marked records.
      const message = parts.join(' ');
      if (message.length > 800) {
        for (let offset = 0; offset < message.length; offset += 800) {
          Native.sync('log.write', {
            level,
            message: (offset === 0 ? '' : '… ') + message.slice(offset, offset + 800)
          });
        }
      } else {
        Native.sync('log.write', { level, message });
      }
      if (typeof originalConsole[level] === 'function') {
        try {
          originalConsole[level].apply(originalConsole, arguments);
        } catch (error) {
          // Debugger-less JSC has no working console; ignore.
        }
      }
    };
  }

  global.console = {
    log: forward('log'),
    info: forward('info'),
    warn: forward('warn'),
    error: forward('error'),
    debug: forward('debug')
  };

  // ---------------------------------------------------------------------------
  // Storage. Reads go through __nativeSyncReceive, a bridged function that returns
  // synchronously: lib-jitsi-meet's Settings/flags layer reads localStorage on the
  // hot path and cannot await.
  // ---------------------------------------------------------------------------
  function callSync(moduleMethod, args) {
    if (typeof global.__nativeSyncReceive !== 'function') {
      return null;
    }
    const raw = global.__nativeSyncReceive(JSON.stringify({
      method: moduleMethod,
      args: args === undefined ? {} : args
    }));
    if (typeof raw !== 'string' || !raw) {
      return null;
    }
    try {
      return JSON.parse(raw);
    } catch (error) {
      return null;
    }
  }

  Native.callSync = callSync;

  function makeStorage(prefix) {
    return {
      getItem(key) {
        const result = callSync('storage.get', { prefix, key });
        return result && Object.prototype.hasOwnProperty.call(result, 'value') ? result.value : null;
      },
      setItem(key, value) {
        Native.sync('storage.set', { prefix, key, value: String(value) });
      },
      removeItem(key) {
        Native.sync('storage.remove', { prefix, key });
      },
      clear() {
        Native.sync('storage.clear', { prefix });
      }
    };
  }

  global.localStorage = makeStorage('local');
  global.sessionStorage = makeStorage('session');

  global.performance = {
    now() {
      return Date.now();
    },
    timing: {},
    mark() {},
    measure() {}
  };
})(globalThis);
