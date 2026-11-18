/*
 * 20-network.js — WebSocket, XMLHttpRequest and fetch over URLSession.
 *
 * Needed by: XMPP stream management / BOSH fallback, the colibri-ws BridgeChannel
 * (WebSocket), config fetches and the statistics/RTCStats uploaders (XHR + fetch).
 */
(function (global) {
  'use strict';

  const Native = global.__JitsiNative;

  // Off unless the host enables it through `SDKConfig.debugSignaling`. Raw frames are what
  // actually crossed the wire, so they stay useful even when lib-jitsi-meet's own parsing
  // rejects a stanza.
  function trace(channel, message) {
    if (global.__jitsiDebug) {
      console.log('[debug][' + channel + '] ' + message);
    }
  }

  // ---------------------------------------------------------------------------
  // WebSocket
  // ---------------------------------------------------------------------------
  class WebSocket extends global.EventTarget {
    static CONNECTING = 0;
    static OPEN = 1;
    static CLOSING = 2;
    static CLOSED = 3;

    constructor(url, protocols) {
      super();
      this.url = String(url);
      this.protocol = Array.isArray(protocols) ? protocols[0] || '' : '';
      this.readyState = WebSocket.CONNECTING;
      this.binaryType = 'arraybuffer';
      trace('ws', 'connect ' + this.url);
      const opened = Native.callSync('ws.open', { url: this.url, protocols: [].concat(protocols || []) });
      this.id = opened && opened.id;
      if (!this.id) {
        trace('ws', 'connect failed ' + this.url);
        this.readyState = WebSocket.CLOSED;
        return;
      }

      const off = [];
      off.push(Native.on('ws:' + this.id, 'open', () => {
        this.readyState = WebSocket.OPEN;
        trace('ws', 'open ' + this.url);
        this.dispatchEvent(new global.Event('open'));
      }));
      off.push(Native.on('ws:' + this.id, 'message', payload => {
        trace('ws', 'recv ' + (payload.text !== undefined
          ? payload.text
          : '<binary ' + String(payload.bytes || '').length + ' base64 chars>'));
        const event = new global.Event('message');
        event.data = payload.text !== undefined ? payload.text : payload.bytes;
        this.dispatchEvent(event);
      }));
      off.push(Native.on('ws:' + this.id, 'close', payload => {
        this.readyState = WebSocket.CLOSED;
        trace('ws', 'close ' + (payload.code || 1006) + ' ' + (payload.reason || '') + ' ' + this.url);
        const event = new global.Event('close');
        event.code = payload.code || 1006;
        event.reason = payload.reason || '';
        off.forEach(unsubscribe => unsubscribe());
        this.dispatchEvent(event);
      }));
      off.push(Native.on('ws:' + this.id, 'error', () => {
        trace('ws', 'error ' + this.url);
        this.dispatchEvent(new global.Event('error'));
      }));
    }

    send(data) {
      if (this.readyState !== WebSocket.OPEN) {
        throw new Error('WebSocket is not open');
      }
      trace('ws', 'send ' + (typeof data === 'string'
        ? data
        : '<binary ' + data.byteLength + ' bytes>'));
      Native.sync('ws.send', {
        id: this.id,
        text: typeof data === 'string' ? data : undefined,
        bytesBase64: typeof data === 'string' ? undefined : toBase64(data)
      });
    }

    close(code, reason) {
      trace('ws', 'closing ' + (code || 1000) + ' ' + (reason || '') + ' ' + this.url);
      Native.sync('ws.close', { id: this.id, code: code || 1000, reason: reason || '' });
      this.readyState = WebSocket.CLOSING;
    }
  }

  global.WebSocket = WebSocket;

  // ---------------------------------------------------------------------------
  // XMLHttpRequest
  // ---------------------------------------------------------------------------
  class XMLHttpRequest extends global.EventTarget {
    constructor() {
      super();
      this.readyState = 0;
      this.status = 0;
      this.statusText = '';
      this.responseText = '';
      this.responseType = '';
      this.timeout = 0;
      this.upload = new global.EventTarget();
      this.__headers = {};
      this.__method = 'GET';
      this.__url = '';
    }

    open(method, url, _async, user, password) {
      this.__method = method;
      this.__url = url;
      if (user) {
        this.__headers.Authorization = 'Basic ' + btoa(user + ':' + (password || ''));
      }
      this.readyState = 1;
      this.dispatchEvent(new global.Event('readystatechange'));
    }

    setRequestHeader(name, value) {
      this.__headers[name] = value;
    }

    getResponseHeader(name) {
      return (this.__responseHeaders || {})[String(name).toLowerCase()] || null;
    }

    getAllResponseHeaders() {
      const headers = this.__responseHeaders || {};
      return Object.keys(headers).map(name => name + ': ' + headers[name]).join('\r\n');
    }

    abort() {
      Native.sync('http.abort', { id: this.__requestId });
    }

    send(body) {
      trace('http', 'send ' + this.__method + ' ' + this.__url + (typeof body === 'string' && body ? '\n' + body : ''));
      const requestId = Native.callSync('http.send', {
        method: this.__method,
        url: this.__url,
        headers: this.__headers,
        body: typeof body === 'string' ? body : undefined,
        timeout: this.timeout
      });
      this.__requestId = requestId;
      this.readyState = 2;

      Native.on('http:' + requestId, 'response', result => {
        this.status = result.status;
        this.statusText = result.statusText || '';
        this.__responseHeaders = result.headers || {};
        this.responseText = result.body || '';
        trace('http', 'recv ' + result.status + ' ' + this.__url
          + (this.responseText ? '\n' + this.responseText : ''));
        this.response = this.responseType === 'json' ? safeJSON(this.responseText) : this.responseText;
        this.readyState = 4;
        this.dispatchEvent(new global.Event('readystatechange'));
        this.dispatchEvent(new global.Event('load'));
        if (this.status >= 400) {
          this.dispatchEvent(new global.Event('error'));
        }
      });

      Native.on('http:' + requestId, 'failure', () => {
        trace('http', 'failed ' + this.__method + ' ' + this.__url);
        this.readyState = 4;
        this.status = 0;
        this.dispatchEvent(new global.Event('readystatechange'));
        this.dispatchEvent(new global.Event('error'));
      });
    }
  }

  global.XMLHttpRequest = XMLHttpRequest;

  global.fetch = function (url, options) {
    return new Promise((resolve, reject) => {
      const request = new XMLHttpRequest();
      request.open((options && options.method) || 'GET', String(url));
      const headers = (options && options.headers) || {};
      Object.keys(headers).forEach(name => request.setRequestHeader(name, headers[name]));
      request.onload = () => resolve({
        ok: request.status >= 200 && request.status < 300,
        status: request.status,
        statusText: request.statusText,
        headers: { get: name => request.getResponseHeader(name) },
        text: () => Promise.resolve(request.responseText),
        json: () => Promise.resolve(safeJSON(request.responseText))
      });
      request.onerror = () => reject(new TypeError('Fetch failed for ' + url));
      request.send(options && options.body);
    });
  };

  function safeJSON(text) {
    try {
      return JSON.parse(text);
    } catch (error) {
      return null;
    }
  }

  // `btoa`/`atob` are absent in JavaScriptCore.
  const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  global.btoa = function (binary) {
    const bytes = [];
    for (let i = 0; i < binary.length; i++) {
      bytes.push(binary.charCodeAt(i) & 0xff);
    }
    return encode(bytes);
  };

  global.atob = function (base64) {
    const bytes = decode(base64);
    let binary = '';
    for (const byte of bytes) {
      binary += String.fromCharCode(byte);
    }
    return binary;
  };

  function encode(bytes) {
    let output = '';
    for (let i = 0; i < bytes.length; i += 3) {
      const chunk = bytes.slice(i, i + 3);
      const value = (chunk[0] << 16) | ((chunk[1] || 0) << 8) | (chunk[2] || 0);
      output += B64[(value >> 18) & 63] + B64[(value >> 12) & 63];
      output += chunk.length > 1 ? B64[(value >> 6) & 63] : '=';
      output += chunk.length > 2 ? B64[value & 63] : '=';
    }
    return output;
  }

  function decode(base64) {
    const clean = String(base64).replace(/[^A-Za-z0-9+/]/g, '');
    const bytes = [];
    for (let i = 0; i < clean.length; i += 4) {
      const group = clean.slice(i, i + 4);
      const value = [0, 1, 2, 3].reduce((acc, index) => (acc << 6) | B64.indexOf(group[index] || 'A'), 0);
      bytes.push((value >> 16) & 255, (value >> 8) & 255, value & 255);
    }
    return bytes.slice(0, Math.floor(clean.length * 3 / 4));
  }

  function toBase64(data) {
    if (data instanceof ArrayBuffer) {
      return encode(Array.from(new Uint8Array(data)));
    }
    if (ArrayBuffer.isView(data)) {
      return encode(Array.from(new Uint8Array(data.buffer, data.byteOffset, data.byteLength)));
    }
    return undefined;
  }
})(globalThis);
