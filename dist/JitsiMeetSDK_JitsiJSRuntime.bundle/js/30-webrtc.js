/*
 * 30-webrtc.js — the WebRTC facade lib-jitsi-meet expects, backed by MediaBackend.
 *
 * Design constraint that makes this portable: SDP crosses the boundary as a raw
 * string. lib-jitsi-meet munges SDP text directly (LocalSdpMunger, RtxModifier,
 * SdpSimulcast), and libwebrtc's native API exposes local/remote descriptions as
 * strings, so no browser-only object graph has to be reproduced.
 *
 * Not implemented yet (see README, phase 4): RTCRtpScriptTransform /
 * createEncodedStreams, which E2EE requires; the encoded-frame hooks are stubbed to
 * fail loudly rather than silently disabling encryption.
 */
(function (global) {
  'use strict';

  const Native = global.__JitsiNative;
  let nextId = 1;
  const id = prefix => prefix + (nextId++);

  /**
   * Minimal SDP media-section reader: lib-jitsi-meet only needs each m-line's kind,
   * mid and direction; SDP itself still crosses to the native stack verbatim.
   */
  function mediaSections(sdp) {
    const sections = [];
    let current = null;
    for (const line of String(sdp || '').split(/\r?\n/)) {
      if (line.indexOf('m=') === 0) {
        current = { kind: line.slice(2).split(' ')[0], mid: null, direction: null };
        sections.push(current);
      } else if (!current) {
        continue;
      } else if (line.indexOf('a=mid:') === 0) {
        current.mid = line.slice(6).trim();
      } else if (line === 'a=sendrecv' || line === 'a=sendonly'
          || line === 'a=recvonly' || line === 'a=inactive') {
        current.direction = line.slice(2);
      }
    }
    return sections.filter(section => section.kind === 'audio' || section.kind === 'video');
  }

  class MediaStreamTrack extends global.EventTarget {
    constructor(snapshot) {
      super();
      this.id = snapshot.id || id('track');
      this.kind = snapshot.kind;
      this.label = snapshot.label || '';
      this.deviceId = snapshot.deviceId || null;
      this.muted = !!snapshot.muted;
      this.__enabled = snapshot.enabled !== false;
      this.readyState = 'live';
      this.__settings = snapshot.settings || {};
      this.__stopListenersAttached = false;

      // lib-jitsi-meet mutes a local track by flipping `track.enabled`, but the capture
      // lives natively. Without the bridge hop the microphone keeps sending while the
      // conference believes it is muted, so the setter is what actually stops media.
      Object.defineProperty(this, 'enabled', {
        enumerable: true,
        configurable: true,
        get: () => this.__enabled,
        set: value => {
          const enabled = !!value;
          if (enabled === this.__enabled) {
            return;
          }
          this.__enabled = enabled;
          Native.sync('media.trackEnabled', { trackId: this.id, enabled });
        }
      });
    }

    stop() {
      this.readyState = 'ended';
      Native.sync('media.trackStop', { trackId: this.id });
      this.dispatchEvent(new global.Event('ended'));
    }

    /**
     * The capture resolution the caller asked for, not what libwebrtc settled on: the
     * native track snapshot carries no dimensions, and lib-jitsi-meet uses these numbers
     * for its video layout and presence instead of asking the peer connection.
     */
    getSettings() {
      return Object.assign({ deviceId: this.deviceId }, this.__settings);
    }

    getConstraints() {
      return Object.assign({}, this.__settings);
    }

    async applyConstraints(constraints) {
      await Native.call('media.applyConstraints', { trackId: this.id, constraints });
    }

    async getCapabilities() {
      return Native.call('media.trackCapabilities', { trackId: this.id });
    }

    clone() {
      return new MediaStreamTrack({
        id: id('track'),
        kind: this.kind,
        label: this.label,
        deviceId: this.deviceId,
        enabled: this.enabled,
        muted: this.muted,
        settings: this.__settings
      });
    }
  }

  class MediaStream extends global.EventTarget {
    /**
     * Accepts the native snapshot form `{ id, tracks, settings }` and the standard
     * `new MediaStream(trackArray)` that lib-jitsi-meet uses to split one stream into an
     * audio stream and a video stream; dropping the array silently produced an empty
     * stream, and the library then called `getSettings()` on an undefined track.
     */
    constructor(source) {
      super();
      const items = Array.isArray(source) ? source : ((source && source.tracks) || []);
      const settings = (source && source.settings) || {};
      this.id = typeof source === 'string' ? source : (source && source.id) || id('stream');
      this.__tracks = items.map(item => item instanceof MediaStreamTrack
        ? item
        : new MediaStreamTrack(Object.assign({}, item, { settings: settings[item.kind] })));
      this.active = true;
    }

    getTracks() {
      return this.__tracks.slice();
    }

    getAudioTracks() {
      return this.__tracks.filter(track => track.kind === 'audio');
    }

    getVideoTracks() {
      return this.__tracks.filter(track => track.kind === 'video');
    }

    addTrack(track) {
      if (this.__tracks.indexOf(track) < 0) {
        this.__tracks.push(track);
        const event = new global.Event('addtrack');
        event.track = track;
        this.dispatchEvent(event);
      }
    }

    removeTrack(track) {
      const index = this.__tracks.indexOf(track);
      if (index >= 0) {
        this.__tracks.splice(index, 1);
        const event = new global.Event('removetrack');
        event.track = track;
        this.dispatchEvent(event);
      }
    }

    getTracksByIds(ids) {
      return this.__tracks.filter(track => ids.indexOf(track.id) >= 0);
    }
  }

  class RTCDataChannel extends global.EventTarget {
    constructor(pcId, label, options) {
      super();
      this.__pcId = pcId;
      this.label = label;
      this.id = options && options.id;
      this.protocol = (options && options.protocol) || '';
      this.negotiated = !!(options && options.negotiated);
      this.ordered = options && options.ordered === false ? false : true;
      this.maxRetransmits = options && options.maxRetransmits;
      this.readyState = 'connecting';
    }

    send(data) {
      Native.sync('pc.sendData', {
        pcId: this.__pcId,
        label: this.label,
        text: typeof data === 'string' ? data : undefined,
        base64: typeof data === 'string' ? undefined : global.btoa(String(data))
      });
    }

    close() {
      this.readyState = 'closed';
      Native.sync('pc.closeDataChannel', { pcId: this.__pcId, label: this.label });
    }

    __setState(state) {
      this.readyState = state;
      this.dispatchEvent(new global.Event(state === 'open' ? 'open' : 'close'));
    }
  }

  class RTCRtpSender {
    constructor(pcId, track, streamIds) {
      this.__pcId = pcId;
      this.track = track;
      this.dtmf = null;
      this.streamIds = streamIds || [];
      this.transform = null;
      this.__parameters = { encodings: [{ rid: undefined, maxBitrate: undefined, scalabilityMode: undefined }] };
    }

    getParameters() {
      return JSON.parse(JSON.stringify(this.__parameters));
    }

    async setParameters(parameters) {
      this.__parameters = parameters;
      await Native.call('pc.setEncodingParameters', {
        pcId: this.__pcId,
        trackId: this.track && this.track.id,
        encodings: (parameters.encodings || []).map(encoding => ({
          rid: encoding.rid,
          maxBitrate: encoding.maxBitrate,
          scalabilityMode: encoding.scalabilityMode,
          active: encoding.active !== false
        }))
      });
    }

    async replaceTrack(track) {
      await Native.call('pc.replaceTrack', { pcId: this.__pcId, oldTrackId: this.track && this.track.id, trackId: track && track.id });
      this.track = track;
    }

    createEncodedStreams() {
      throw new Error('createEncodedStreams is not wired yet (phase 4: E2EE)');
    }
  }

  class RTCRtpReceiver {
    constructor(pcId, track) {
      this.__pcId = pcId;
      this.track = track;
      this.transform = null;
    }

    createEncodedStreams() {
      throw new Error('createEncodedStreams is not wired yet (phase 4: E2EE)');
    }
  }

  // lib-jitsi-meet probes `RTCRtpTransceiver.prototype.setCodecPreferences`; leaving the
  // global undefined makes that probe throw and aborts the Jingle session. Codec preference
  // ordering itself has no native counterpart here, so the call only records the list.
  class RTCRtpTransceiver {
    constructor(init) {
      init = init || {};
      this.sender = init.sender || null;
      this.receiver = init.receiver || null;
      this.direction = init.direction || 'sendrecv';
      this.currentDirection = init.currentDirection || null;
      this.mid = init.mid || null;
      this.stopped = false;
    }

    setCodecPreferences(codecs) {
      this.__codecs = (codecs || []).slice();
    }

    stop() {
      this.stopped = true;
      this.direction = 'stopped';
    }
  }

  class RTCPeerConnection extends global.EventTarget {
    constructor(configuration) {
      super();
      this.__listeners = new Map();
      this.localDescription = null;
      this.remoteDescription = null;
      this.signalingState = 'stable';
      this.iceConnectionState = 'checking';
      this.iceGatheringState = 'new';
      this.connectionState = 'new';
      this.currentLocalDescription = null;
      this.currentRemoteDescription = null;
      this.__senders = [];
      this.__receivers = [];
      this.__transceivers = [];
      this.__streams = [];
      this.__dataChannels = new Map();

      const created = Native.callSync('pc.create', { configuration: configuration || {} });
      this.id = created && created.pcId;
      if (!this.id) {
        throw new Error('RTCPeerConnection: native backend is unavailable');
      }

      Native.on('pc:' + this.id, 'event', payload => this.__handle(payload));
    }

    __handle(payload) {
      switch (payload.type) {
      case 'icecandidate': {
        const event = new global.Event('icecandidate');
        event.candidate = payload.candidate || null;
        this.dispatchEvent(event);
        break;
      }
      case 'negotiationneeded':
        this.dispatchEvent(new global.Event('negotiationneeded'));
        break;
      case 'signalingState':
        this.signalingState = payload.state;
        this.dispatchEvent(stateEvent('signalingstatechange', this));
        break;
      case 'iceConnectionState':
        this.iceConnectionState = payload.state;
        this.dispatchEvent(stateEvent('iceconnectionstatechange', this));
        break;
      case 'iceGatheringState':
        this.iceGatheringState = payload.state;
        this.dispatchEvent(stateEvent('icegatheringstatechange', this));
        break;
      case 'connectionState':
        this.connectionState = payload.state;
        this.dispatchEvent(stateEvent('connectionstatechange', this));
        break;
      case 'track': {
        const track = new MediaStreamTrack(payload.track);
        const receiver = new RTCRtpReceiver(this.id, track);
        this.__receivers.push(receiver);
        const stream = new MediaStream({ id: payload.streamId, tracks: [payload.track] });
        this.__streams.push(stream);
        // lib-jitsi-meet resolves the remote SDP m-line through `transceiver.mid`, so the
        // native side reports the negotiated mid alongside the track. Several remote
        // sources can share one m-line, so merge by mid instead of appending a duplicate.
        let transceiver = payload.mid != null
          ? this.__transceivers.find(t => t.mid === payload.mid)
          : null;
        if (transceiver) {
          transceiver.receiver = receiver;
        } else {
          transceiver = new RTCRtpTransceiver({
            receiver,
            direction: 'recvonly',
            currentDirection: 'recvonly',
            mid: payload.mid || null
          });
          this.__transceivers.push(transceiver);
        }
        const event = new global.Event('track');
        event.track = track;
        event.streams = [stream];
        event.receiver = receiver;
        event.transceiver = transceiver;
        this.dispatchEvent(event);
        break;
      }
      case 'datachannel': {
        const channel = new RTCDataChannel(this.id, payload.label, {});
        this.__dataChannels.set(payload.label, channel);
        channel.__setState('open');
        const event = new global.Event('datachannel');
        event.channel = channel;
        this.dispatchEvent(event);
        break;
      }
      case 'channelState': {
        const channel = this.__dataChannels.get(payload.label);
        if (channel) {
          channel.__setState(payload.state);
        }
        break;
      }
      case 'channelMessage': {
        const channel = this.__dataChannels.get(payload.label);
        if (channel) {
          const event = new global.Event('message');
          event.data = payload.text !== undefined ? payload.text : payload.bytes;
          channel.dispatchEvent(event);
        }
        break;
      }
      default:
        console.warn('RTCPeerConnection: unhandled native event', payload.type);
      }
    }

    async createOffer(options) {
      const result = await Native.call('pc.createOffer', { pcId: this.id, options: options || {} });
      return new global.RTCSessionDescription(result);
    }

    async createAnswer(options) {
      const result = await Native.call('pc.createAnswer', { pcId: this.id, options: options || {} });
      return new global.RTCSessionDescription(result);
    }

    async setLocalDescription(description) {
      if (global.__jitsiDebug) {
        console.log('[debug][sdp] local ' + description.type + '\n' + (description.sdp || ''));
      }
      // Publish the description before the native call: libwebrtc fires state and track
      // events from inside it, and lib-jitsi-meet's listeners read these properties.
      const previous = this.__local;
      this.__local = new global.RTCSessionDescription(description);
      this.localDescription = this.__local;
      this.currentLocalDescription = this.__local;
      try {
        await Native.call('pc.setLocalDescription', {
          pcId: this.id,
          type: description.type,
          sdp: typeof description === 'string' ? description : description.sdp
        });
        this.__assignLocalMids(this.__local.sdp);
      } catch (error) {
        this.__local = previous;
        this.localDescription = previous;
        this.currentLocalDescription = previous;
        throw error;
      }
    }

    async setRemoteDescription(description) {
      if (global.__jitsiDebug) {
        console.log('[debug][sdp] remote ' + description.type + '\n' + (description.sdp || ''));
      }
      const previous = this.__remote;
      this.__remote = new global.RTCSessionDescription(description);
      this.remoteDescription = this.__remote;
      this.currentRemoteDescription = this.__remote;
      try {
        await Native.call('pc.setRemoteDescription', {
          pcId: this.id,
          type: description.type,
          sdp: typeof description === 'string' ? description : description.sdp
        });
        this.__syncTransceiversFromSdp(this.__remote.sdp);
      } catch (error) {
        this.__remote = previous;
        this.remoteDescription = previous;
        this.currentRemoteDescription = previous;
        throw error;
      }
    }

    async addIceCandidate(candidate) {
      if (!candidate) {
        await Native.call('pc.addIceCandidate', { pcId: this.id, candidate: null });
        return;
      }
      const init = typeof candidate === 'object' && candidate.toJSON ? candidate.toJSON() : candidate;
      await Native.call('pc.addIceCandidate', { pcId: this.id, candidate: init });
    }

    /**
     * Browsers materialize one transceiver per m-line as soon as a remote description is
     * applied, and lib-jitsi-meet's responder path depends on that: it calls `addTrack()`
     * and then expects the returned sender to belong to the recvonly transceiver that the
     * offer created.
     */
    __syncTransceiversFromSdp(sdp) {
      for (const section of mediaSections(sdp)) {
        let transceiver = section.mid !== null
          ? this.__transceivers.find(t => t.mid === section.mid)
          : null;
        if (!transceiver) {
          transceiver = new RTCRtpTransceiver({
            receiver: new RTCRtpReceiver(this.id, new MediaStreamTrack({
              id: 'remote-' + (section.mid !== null ? section.mid : id('track')),
              kind: section.kind,
              muted: true
            })),
            direction: section.direction || 'recvonly',
            currentDirection: section.direction || 'recvonly',
            mid: section.mid
          });
          this.__transceivers.push(transceiver);
          continue;
        }
        if (!transceiver.receiver || !transceiver.receiver.track) {
          transceiver.receiver = new RTCRtpReceiver(this.id, new MediaStreamTrack({
            id: 'remote-' + (section.mid !== null ? section.mid : id('track')),
            kind: section.kind,
            muted: true
          }));
        }
        if (section.mid !== null) {
          transceiver.mid = section.mid;
        }
        if (section.direction) {
          transceiver.currentDirection = section.direction;
        }
      }
    }

    /**
     * Locally created transceivers only learn their mid from the description libwebrtc
     * produced, so adopt it (and the negotiated direction) from the local SDP.
     */
    __assignLocalMids(sdp) {
      for (const section of mediaSections(sdp)) {
        let transceiver = section.mid !== null
          ? this.__transceivers.find(t => t.mid === section.mid)
          : null;
        if (!transceiver) {
          transceiver = this.__transceivers.find(t => t.mid === null
            && t.receiver && t.receiver.track && t.receiver.track.kind === section.kind);
        }
        if (!transceiver) {
          continue;
        }
        transceiver.mid = section.mid;
        if (section.direction) {
          transceiver.direction = section.direction;
          transceiver.currentDirection = section.direction;
        }
      }
    }

    addTrack(track, ...streams) {
      const streamIds = streams
        .filter(Boolean)
        .map(stream => (stream && stream.id) || String(stream));
      // Reuse the recvonly transceiver the remote offer created for this kind, which is
      // what a browser's `pc.addTrack` does; lib-jitsi-meet finds it via `t.sender === sender`.
      let transceiver = this.__transceivers.find(t => !t.stopped
        && !t.sender
        && t.receiver && t.receiver.track && t.receiver.track.kind === track.kind
        && (t.direction === 'recvonly' || t.direction === 'inactive'));
      const sender = new RTCRtpSender(this.id, track, streamIds);
      this.__senders.push(sender);
      if (transceiver) {
        transceiver.sender = sender;
        transceiver.direction = 'sendrecv';
      } else {
        transceiver = new RTCRtpTransceiver({
          sender,
          receiver: new RTCRtpReceiver(this.id, new MediaStreamTrack({
            id: id('track'),
            kind: track.kind,
            muted: true
          })),
          direction: 'sendrecv'
        });
        this.__transceivers.push(transceiver);
      }
      Native.sync('pc.addTrack', { pcId: this.id, trackId: track.id, streamIds });
      return sender;
    }

    addTransceiver(trackOrKind, init) {
      const track = typeof trackOrKind === 'string' ? new MediaStreamTrack({ id: id('track'), kind: trackOrKind }) : trackOrKind;
      const sender = new RTCRtpSender(this.id, track, []);
      const receiver = new RTCRtpReceiver(this.id, track);
      if (init && init.direction === 'recvonly') {
        this.__receivers.push(receiver);
        const transceiver = new RTCRtpTransceiver({ receiver, direction: init.direction });
        this.__transceivers.push(transceiver);
        return transceiver;
      }
      const streamIds = ((init && init.streams) || [])
        .filter(Boolean)
        .map(stream => (stream && stream.id) || String(stream));
      this.__senders.push(sender);
      this.__receivers.push(receiver);
      Native.sync('pc.addTrack', { pcId: this.id, trackId: track.id, streamIds });
      const transceiver = new RTCRtpTransceiver({
        sender,
        receiver,
        direction: (init && init.direction) || 'sendrecv'
      });
      this.__transceivers.push(transceiver);
      return transceiver;
    }

    removeTrack(sender) {
      const index = this.__senders.indexOf(sender);
      if (index >= 0) {
        this.__senders.splice(index, 1);
      }
      const transceiver = this.__transceivers.find(t => t.sender === sender);
      if (transceiver) {
        transceiver.sender = null;
        if (transceiver.direction === 'sendrecv') {
          transceiver.direction = 'recvonly';
        }
      }
      Native.sync('pc.removeTrack', { pcId: this.id, trackId: sender.track && sender.track.id });
    }

    getSenders() {
      return this.__senders.slice();
    }

    getReceivers() {
      return this.__receivers.slice();
    }

    getTransceivers() {
      return this.__transceivers.slice();
    }

    getLocalStreams() {
      return this.__streams.filter(stream => stream.getVideoTracks().length || stream.getAudioTracks().length);
    }

    getRemoteStreams() {
      return this.__streams.slice();
    }

    createDataChannel(label, options) {
      const channel = new RTCDataChannel(this.id, label, options || {});
      this.__dataChannels.set(label, channel);
      Native.sync('pc.createDataChannel', {
        pcId: this.id,
        label,
        options: {
          ordered: channel.ordered,
          maxRetransmits: channel.maxRetransmits,
          negotiated: channel.negotiated,
          id: channel.id
        }
      });
      return channel;
    }

    async getStats(selector) {
      const report = await Native.call('pc.getStats', { pcId: this.id, trackId: selector && selector.id });
      return new global.RTCStatsReport(report);
    }

    setConfiguration(configuration) {
      Native.sync('pc.setConfiguration', { pcId: this.id, configuration: configuration || {} });
    }

    close() {
      Native.sync('pc.close', { pcId: this.id });
      this.signalingState = 'closed';
      this.connectionState = 'closed';
      this.iceConnectionState = 'closed';
    }
  }

  global.RTCPeerConnection = RTCPeerConnection;

  global.RTCSessionDescription = class RTCSessionDescription {
    constructor(init) {
      init = init || {};
      this.type = init.type || 'offer';
      this.sdp = typeof init === 'string' ? init : init.sdp || '';
    }

    toJSON() {
      return { type: this.type, sdp: this.sdp };
    }
  };

  global.RTCIceCandidate = class RTCIceCandidate {
    constructor(init) {
      Object.assign(this, init || {});
    }

    toJSON() {
      return {
        candidate: this.candidate,
        sdpMid: this.sdpMid,
        sdpMLineIndex: this.sdpMLineIndex,
        usernameFragment: this.usernameFragment
      };
    }
  };

  /**
   * getStats returns an array of report records. lib-jitsi-meet's RTPStatsCollector
   * walks it with forEach and reads `report.type`, so the shape matters more than the
   * class identity.
   */
  global.RTCStatsReport = class RTCStatsReport {
    constructor(records) {
      this.__records = records || [];
    }

    forEach(callback) {
      this.__records.forEach(record => callback(record, record.id, this));
    }

    get(id) {
      return this.__records.find(record => record.id === id);
    }

    values() {
      return this.__records.slice();
    }
  };

  global.RTCError = class RTCError extends Error {
    constructor(init) {
      super((init && init.message) || 'RTCError');
      this.errorDetail = init && init.errorDetail;
      this.httpStatusCode = init && init.httpStatusCode;
    }
  };

  global.RTCOfferOptions = undefined;

  // lib-jitsi-meet's codec selection reads these; the values come from the linked
  // libwebrtc build, so they are requested from the native side rather than hardcoded.
  global.RTCRtpSender = RTCRtpSender;
  global.RTCRtpReceiver = RTCRtpReceiver;
  global.RTCRtpTransceiver = RTCRtpTransceiver;
  global.RTCRtpCapabilities = undefined;
  global.RTCRtpParameters = undefined;
  global.RTCRtpSendParameters = undefined;
  global.RTCCertificate = class RTCCertificate {
    constructor(init) {
      Object.assign(this, init || {});
    }
  };

  RTCRtpSender.getCapabilities = kind => Native.callSync('media.capabilities', { kind }) || {
    codecs: [],
    headerExtensions: [],
    fecMechanisms: [],
    rtcp: {}
  };
  RTCRtpReceiver.getCapabilities = RTCRtpSender.getCapabilities;

  global.MediaStream = MediaStream;
  global.MediaStreamTrack = MediaStreamTrack;
  global.RTCDataChannel = RTCDataChannel;
  global.__jitsiWebRTC = { MediaStream, MediaStreamTrack, RTCDataChannel, RTCPeerConnection };

  global.navigator = global.navigator || {};

  /** `{ width: { ideal: 1280 } }` and `{ width: 1280 }` both appear in lib-jitsi-meet constraints. */
  function ideal(value) {
    return value && typeof value === 'object' ? value.ideal : value;
  }

  function requestedSettings(kind, constraints) {
    const requested = (constraints && constraints[kind]) || {};
    if (typeof requested !== 'object') {
      return {};
    }
    const settings = {
      width: ideal(requested.width) || 0,
      height: ideal(requested.height) || 0,
      frameRate: ideal(requested.frameRate) || 0
    };
    if (kind === 'video') {
      settings.facingMode = requested.facingMode || 'user';
    } else {
      settings.channelCount = ideal(requested.channelCount) || 1;
      settings.autoGainControl = !!requested.autoGainControl;
      settings.echoCancellation = !!requested.echoCancellation;
      settings.noiseSuppression = !!requested.noiseSuppression;
    }
    return settings;
  }

  function streamFromNative(result, constraints) {
    const settings = {
      audio: requestedSettings('audio', constraints),
      video: requestedSettings('video', constraints)
    };
    return new MediaStream({ id: result.streamId, tracks: result.tracks, settings });
  }

  global.navigator.mediaDevices = {
    async getUserMedia(constraints) {
      const result = await Native.call('media.getUserMedia', { constraints });
      return streamFromNative(result, constraints);
    },

    async getDisplayMedia(constraints) {
      const result = await Native.call('media.getDisplayMedia', { constraints });
      return streamFromNative(result, constraints);
    },

    async enumerateDevices() {
      return Native.call('media.enumerateDevices');
    },

    async getSupportedConstraints() {
      return {
        deviceId: true,
        echoingCancellation: true,
        facingMode: true,
        frameRate: true,
        groupId: true,
        height: true,
        width: true,
        autoGainControl: true,
        noiseSuppression: true,
        channelCount: true,
        sampleRate: true,
        sampleSize: true
      };
    },

    addEventListener(type, handler) {
      Native.on('media', type, handler);
    },

    removeEventListener() {}
  };

  global.MediaStreamTrackEvent = class MediaStreamTrackEvent extends global.Event {
    constructor(type, init) {
      super(type);
      this.track = init && init.track;
    }
  };

  function stateEvent(name, target) {
    const event = new global.Event(name);
    event.target = target;
    return event;
  }
})(globalThis);
