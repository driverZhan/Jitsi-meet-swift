/*
 * 50-sdk-facade.js — the boundary lib-jitsi-meet sits behind.
 *
 * Swift never touches lib-jitsi-meet's object graph. It calls one function,
 * `__sdkInvoke({ method, args })`, and this file flattens the JitsiMeetJS API into
 * promise-returning RPC plus one event channel. A lib-jitsi-meet upgrade therefore
 * only has to keep this table honest, not 8k lines of Swift bindings.
 *
 * Every call below is against the API surface in this repo's source
 * (JitsiMeetJS.ts, JitsiConference.ts, JitsiConnection.ts, the *Events.ts enums).
 * Anything not verified is left as an explicit `unimplemented` throw.
 */
(function (global) {
  'use strict';

  const Native = global.__JitsiNative;

  // Set by `lib.init` / `lib.setDebug` from `SDKConfig.debugSignaling`. The network shim
  // reads it too, so raw transport frames and parsed stanzas share one switch.
  global.__jitsiDebug = !!global.__jitsiDebug;

  function debugLog(message) {
    if (global.__jitsiDebug) {
      console.log('[debug][xmpp] ' + message);
    }
  }

  function traceStanzas(connection) {
    const wrapper = connection && connection.xmpp && connection.xmpp.connection;
    // lib-jitsi-meet wraps Strophe in its own connection class; the raw connection (the
    // object Strophe actually invokes xmlInput/xmlOutput on) is `_stropheConn`.
    const strophe = wrapper && wrapper._stropheConn ? wrapper._stropheConn : wrapper;
    if (!global.__jitsiDebug || !strophe || strophe.__jitsiSwiftTraced) {
      return;
    }
    strophe.__jitsiSwiftTraced = true;
    const serializer = new XMLSerializer();
    const render = stanza => {
      try {
        return typeof stanza === 'string' ? stanza : serializer.serializeToString(stanza);
      } catch (error) {
        return String(stanza);
      }
    };
    // Stream management wraps these two hooks; chain instead of replacing so its
    // stanza counters and resume token keep working with tracing on.
    const input = strophe.xmlInput;
    const output = strophe.xmlOutput;
    strophe.xmlInput = function (stanza) {
      debugLog('recv ' + render(stanza));
      if (typeof input === 'function') {
        return input.call(this, stanza);
      }
    };
    strophe.xmlOutput = function (stanza) {
      debugLog('send ' + render(stanza));
      if (typeof output === 'function') {
        return output.call(this, stanza);
      }
    };
  }

  const state = {
    lib: null,
    connection: null,
    conference: null,
    // Name of the conference created by `conference.prepare` that `conference.join` reuses.
    preparedName: null,
    // The lib has no lock-state getter, so mirror the LOCK_STATE_CHANGED event for `state()`.
    locked: false,
    // lib-jitsi-meet keeps participant properties in the presence map and only exposes a
    // per-key getter, which loses `string[]` values. Keep the last value written here so
    // `conference.localParticipantProperty` returns exactly what Swift sent.
    localParticipantProperties: {},
    // jicofo publishes room properties as a full object on every change.
    conferenceProperties: {},
    // Lobby users are pseudo-participants: the event carries a delta (`{email}`), so merge
    // them into a map and emit the full snapshot.
    lobbyUsers: new Map(),
    // Lobby MUC JID from the 407 and its <waiting-for-host/> marker. The JID is kept for
    // logging; the marker tells a wait-for-host lobby (auto-admission on host arrival)
    // apart from one a moderator approves from the lobby list.
    lobbyRoomJid: null,
    lobbyWaitingForHost: false,
    // mediaType -> enabled, mirrored from AV_MODERATION_CHANGED for `conference.state`.
    avModeration: {},
    // Last `BREAKOUT_ROOMS_UPDATED` payload, flattened to an array so room order survives the
    // JSON boundary; the component names rooms and the moderator UI lists them in order.
    breakoutRooms: [],
    breakoutRoomCounter: 0,
    // A deliberate room switch leaves the old MUC before joining the new one; the transient
    // CONFERENCE_LEFT must not reach Swift as "the meeting ended".
    switchingRoom: false,
    logLevel: 'info',
    // JID assigned by the server on CONNECTION_ESTABLISHED; survives until disconnect so
    // `connection.jid` still answers while the socket is flapping.
    connectionJID: null,
    localTracks: new Map(),
    attached: new Map(),
    // mode -> JibriSession, so stopRecording() can name the session the lib insists on.
    recordings: new Map(),
    // Presence commands the app subscribed to, keyed by command name. Listeners are bound to
    // the room, so they must be re-attached after a rejoin or breakout switch rebuilds it.
    commandListeners: new Map()
  };

  // Every field above belongs to the conference that is about to be created; a rejoin or a
  // new room must not inherit lobby users or properties from the previous one.
  function resetConferenceState() {
    state.locked = false;
    state.localParticipantProperties = {};
    state.conferenceProperties = {};
    state.lobbyUsers.clear();
    state.lobbyRoomJid = null;
    state.lobbyWaitingForHost = false;
    state.avModeration = {};
    state.breakoutRooms = [];
    state.breakoutRoomCounter = 0;
  }

  function plainObject(value) {
    const copy = plain(value);
    return copy && typeof copy === 'object' && !Array.isArray(copy) ? copy : {};
  }

  function lib() {
    if (state.lib) {
      return state.lib;
    }
    // A webpack UMD bundle attaches to `self` (== window == globalThis here).
    const candidate = global.JitsiMeetJS || global.libJitsiMeet;
    if (!candidate) {
      throw new Error('lib-jitsi-meet bundle not loaded; run Scripts/build-js-bundle.sh');
    }
    patchBrowserCapabilities(candidate);
    state.lib = candidate;
    return candidate;
  }

  /**
   * The shim identifies as Chromium/WebKit, so lib-jitsi-meet mutes video by tearing the
   * stream out of the peer connection (`doesVideoMuteByStreamRemove`). On unmute it calls
   * getUserMedia again, which hands back a *new* native track id while the local track map,
   * the capture bookkeeping and every frame sink still point at the old one — the camera
   * appears dead locally and remotely. Capture here is native and survives mute, so flip
   * the capability to the `track.enabled` path: one stable id for the whole call, and
   * presence (`SourceInfo`) still tells the other side about the mute.
   */
  function patchBrowserCapabilities(instance) {
    const browser = instance.util && instance.util.browser;
    if (browser && typeof browser.doesVideoMuteByStreamRemove === 'function') {
      browser.doesVideoMuteByStreamRemove = () => false;
    }
  }

  function conferenceEvents() {
    return lib().events.conference;
  }

  // lib-jitsi-meet's resume task waits for NETWORK_INFO_EVENT before retrying and, while
  // the app reports offline, holds the reservation instead of burning its three attempts.
  // The host pushes reachability changes from NWPathMonitor on the `network` channel.
  Native.on('network', 'status', payload => {
    const online = !payload || payload.online !== false;
    try {
      const instance = lib();
      if (typeof instance.setNetworkInfo === 'function') {
        instance.setNetworkInfo({ isOnline: online });
      }
    } catch (error) {
      console.warn('[sdk] setNetworkInfo failed: ' + error.message);
    }
  });

  function connectionEvents() {
    return lib().events.connection;
  }

  function plain(value) {
    if (value === undefined) {
      return null;
    }
    try {
      return JSON.parse(JSON.stringify(value));
    } catch (error) {
      return String(value);
    }
  }

  // RTC stats reach the conference as Map<ssrc, stats>; JSON.stringify turns a Map into `{}`,
  // so the entries have to be flattened before crossing the bridge.
  function mapToPlain(value) {
    if (value && typeof value.entries === 'function') {
      const entries = {};
      for (const [key, entry] of value.entries()) {
        entries[String(key)] = plain(entry);
      }
      return entries;
    }
    return plain(value);
  }

  // Presence values arrive as strings ("true"/"false"), so `!!value` would read a lowered
  // hand as raised.
  function asBool(value) {
    return value === true || value === 'true';
  }

  function moderationMediaType(value) {
    const type = String(value || '');
    if (type !== 'audio' && type !== 'video' && type !== 'desktop') {
      throw new Error('mediaType must be audio, video or desktop');
    }
    return type;
  }

  // Presence commands reach a listener as the lib's presence node: `{ tagName, attributes,
  // value?, children? }` for parsed packets, or a DOM element when the lib hands the element
  // through. Swift only needs the values, so flatten attributes and keep text/children.
  function presenceNodeValues(node) {
    if (!node) {
      return {};
    }
    const values = {};
    const attrs = node.attributes;
    if (Array.isArray(attrs)) {
      attrs.forEach(attr => {
        values[attr.name] = attr.value;
      });
    } else if (attrs && typeof attrs === 'object') {
      Object.keys(attrs).forEach(key => {
        values[key] = attrs[key];
      });
    } else {
      Object.keys(node).forEach(key => {
        if (key !== 'tagName' && key !== 'children' && key !== 'attributes') {
          values[key] = node[key];
        }
      });
    }
    if (node.value !== undefined && !Object.prototype.hasOwnProperty.call(values, 'value')) {
      values.value = node.value;
    }
    if (Array.isArray(node.children) && node.children.length) {
      // Child names matter (they are the payload keys); the top-level name is the command
      // itself and is already on the event.
      values.children = node.children.map(child => Object.assign(
        { tagName: child && child.tagName },
        presenceNodeValues(child)
      ));
    }
    return values;
  }

  function emit(name, payload) {
    Native.sync('sdk.event', { name, payload: plain(payload === undefined ? {} : payload) });
  }

  function unimplemented(feature) {
    throw new Error('unimplemented in this phase: ' + feature);
  }

  // ---------------------------------------------------------------------------
  // Snapshots. Track/Participant objects are rich browser-side classes; only the
  // serializable identity the Swift state machine needs crosses the boundary.
  // ---------------------------------------------------------------------------

  /**
   * The shim MediaStreamTrack behind a lib-jitsi-meet track. Frames reach the native
   * renderer under this id, so it is the only key that can match a frame sink.
   * `getId()`/`getTrackId()` are lib-jitsi-meet identifiers invented on the JS side
   * (a stream id, or a generated uuid) and never match.
   */
  function nativeTrack(track) {
    const stream = track && track.stream;
    if (!stream) {
      return null;
    }
    const kind = typeof track.getType === 'function' ? track.getType() : null;
    const list = kind === 'audio'
      ? (stream.getAudioTracks && stream.getAudioTracks())
      : (stream.getVideoTracks && stream.getVideoTracks());
    return (list && list[0]) || null;
  }

  function trackKey(track) {
    const native = nativeTrack(track);
    return (native && native.id)
      || (track && track.getTrackId && track.getTrackId())
      || (track && track.getId && track.getId())
      || null;
  }

  function trackSnapshot(track) {
    if (!track) {
      return null;
    }
    const nativeUnderlying = nativeTrack(track);
    return {
      id: trackKey(track),
      mediaType: track.getType(),
      isLocal: track.isLocal(),
      muted: track.isMuted(),
      videoType: track.getVideoType ? track.getVideoType() : undefined,
      deviceID: track.deviceId || (nativeUnderlying && nativeUnderlying.deviceId),
      label: (nativeUnderlying && nativeUnderlying.label) || ''
    };
  }

  function participantSnapshot(participant) {
    if (!participant) {
      return null;
    }
    // This lib-jitsi-meet build no longer exposes `isLocal`/`hasRaisedHand` on participants;
    // local participants are not even in the conference map. Only call what exists so an
    // event handler can never take the whole Strophe handler chain down.
    const call = (name, fallback) => (typeof participant[name] === 'function' ? participant[name]() : fallback);
    const getProperty = name => (typeof participant.getProperty === 'function' ? participant.getProperty(name) : undefined);
    const raisedHand = typeof participant.hasRaisedHand === 'function'
      ? participant.hasRaisedHand()
      : asBool(getProperty('raiseHand'));
    return {
      id: call('getId', null),
      displayName: call('getDisplayName', ''),
      role: call('getRole', 'none'),
      isLocal: call('isLocal', false),
      raisedHand,
      tracks: (call('getTracks', []) || []).map(trackSnapshot),
      // Detail fields used by participant sheets and moderator tooling. Every getter is
      // guarded through `call` so an older or partial participant object cannot throw
      // inside a Strophe handler.
      jid: call('getJid', ''),
      connectionJID: call('getConnectionJid', undefined),
      status: call('getStatus', ''),
      botType: call('getBotType', undefined),
      statsID: call('getStatsID', ''),
      isSilent: !!call('isSilent', false),
      isReplacing: !!call('isReplacing', false),
      isReplaced: !!call('isReplaced', false),
      isHidden: !!call('isHidden', false),
      isAudioMuted: !!call('isAudioMuted', false),
      isVideoMuted: !!call('isVideoMuted', false)
    };
  }

  function requireConference() {
    if (!state.conference) {
      throw new Error('no active conference');
    }
    return state.conference;
  }

  function commandName(args) {
    const name = String((args && args.name) || '');
    if (!name) {
      throw new Error('command name is required');
    }
    return name;
  }

  // `sendCommand(name, values)` writes a presence extension whose attributes are `values`;
  // `sendCommandOnce` additionally removes it right after sending. The facade keeps the value
  // check here so a non-object payload fails before it reaches the lib's XML builder.
  function sendPresenceCommand(args, once) {
    const conference = requireConference();
    const name = commandName(args);
    const method = once ? 'sendCommandOnce' : 'sendCommand';
    if (typeof conference[method] !== 'function') {
      throw new Error(method + ' is not supported by this lib build');
    }
    const values = args.values === undefined ? {} : args.values;
    if (!values || typeof values !== 'object' || Array.isArray(values)) {
      throw new Error('command values must be a JSON object');
    }
    conference[method](name, values);
    return true;
  }

  // Dropping the XMPP stream also drops the media session; captures would otherwise keep
  // running (camera/mic light on) while nobody can hear or see them.
  function disposeLocalTracks() {
    for (const track of state.localTracks.values()) {
      try {
        if (track && typeof track.dispose === 'function') {
          track.dispose();
        }
      } catch (error) {
        console.warn('[sdk] track.dispose failed: ' + error.message);
      }
    }
    state.localTracks.clear();
    state.attached.clear();
  }

  // A dropped stream makes the JitsiConference unreachable, so nothing calls
  // `JingleSessionPC.close()` and the native peer (and its encoders) would stay allocated
  // for the lifetime of the app. The shim keeps a registry for exactly this case.
  function closePeerConnections() {
    if (typeof global.__closeAllPeerConnections === 'function') {
      global.__closeAllPeerConnections();
    }
  }

  function createConference(args) {    const options = Object.assign({}, args.options || {}, args.configOverwrite || {});
    resetConferenceState();
    const conference = state.connection.initJitsiConference(args.name, options);
    wireConference(conference);
    // Presence listeners live on the room, so a rebuilt conference starts deaf; re-attach
    // every command the app subscribed to before the switch/rejoin.
    if (typeof conference.addCommandListener === 'function') {
      state.commandListeners.forEach((handler, name) => conference.addCommandListener(name, handler));
    }
    // Identity has to be in the presence map before join(): the room's own sendPresence()
    // is suppressed until then, so this only stages the stanza the join will send.
    applyUserInfo(conference, args.userInfo);
    state.conference = conference;
    state.preparedName = args.name;
    return conference;
  }

  function findParticipant(conference, id) {
    if (typeof conference.getParticipantById === 'function') {
      const found = conference.getParticipantById(id);
      if (found) {
        return found;
      }
    }
    return (conference.getParticipants() || []).find(participant => participant.getId() === id) || null;
  }

  // ---------------------------------------------------------------------------
  // Breakout rooms. The lib's methods live on `conference.getBreakoutRooms()` and silently
  // no-op for non-moderators or a deployment without the component, so the checks below turn
  // those no-ops into errors the app can show.
  // ---------------------------------------------------------------------------
  function requireBreakoutRooms(conference) {
    const manager = typeof conference.getBreakoutRooms === 'function'
      ? conference.getBreakoutRooms()
      : null;
    if (!manager || typeof manager.createBreakoutRoom !== 'function') {
      throw new Error('breakout rooms are not supported by this lib build');
    }
    if (typeof manager.isSupported === 'function' && !manager.isSupported()) {
      throw new Error('breakout rooms are not supported by this deployment');
    }
    if (typeof conference.isModerator === 'function' && !conference.isModerator()) {
      throw new Error('only a moderator can manage breakout rooms');
    }
    return manager;
  }

  function requireRoomJID(value, label) {
    const jid = String(value || '');
    const at = jid.indexOf('@');
    if (at <= 0 || at === jid.length - 1) {
      throw new Error(label + ' must be a full room JID');
    }
    return jid;
  }

  // `sendParticipantToRoom` wants the participant's connection JID, while Swift only knows
  // endpoint ids. Prefer the live participant, then the last rooms snapshot (someone already
  // moved out of the main room is no longer in the conference map).
  function breakoutParticipantJID(conference, value) {
    const id = String(value || '');
    if (!id) {
      throw new Error('participantId is required');
    }
    if (id.indexOf('@') !== -1) {
      return id;
    }
    const participant = findParticipant(conference, id);
    const jid = participant && typeof participant.getJid === 'function' ? participant.getJid() : null;
    if (jid) {
      return jid;
    }
    for (const room of state.breakoutRooms) {
      const match = (room.participants || []).find(
        entry => entry.jid === id || entry.jid.slice(-(id.length + 1)) === '/' + id);
      if (match) {
        return match.jid;
      }
    }
    throw new Error('unknown participant: ' + id);
  }

  function breakoutRoomSnapshot(jid, room) {
    const source = room || {};
    const participants = source.participants && typeof source.participants === 'object'
      ? source.participants
      : {};
    return {
      id: source.id !== undefined && source.id !== null ? String(source.id) : '',
      jid: source.jid ? String(source.jid) : String(jid),
      name: source.name || source.subject ? String(source.name || source.subject) : '',
      isMainRoom: !!source.isMainRoom,
      participants: Object.keys(participants).map(key => {
        const participant = participants[key] || {};
        return {
          jid: participant.jid ? String(participant.jid) : String(key),
          displayName: participant.displayName ? String(participant.displayName) : '',
          role: participant.role ? String(participant.role) : 'none'
        };
      })
    };
  }

  // Capability and room list in one payload. `isSupported` is false when the deployment
  // published no `breakout_rooms` component, which is also what `requireBreakoutRooms`
  // turns into an error for the management calls.
  function breakoutRoomsStateSnapshot() {
    const conference = state.conference;
    const manager = conference && typeof conference.getBreakoutRooms === 'function'
      ? conference.getBreakoutRooms()
      : null;
    if (!manager) {
      return {
        isSupported: false,
        canRename: false,
        isBreakoutRoom: false,
        mainRoomJID: null,
        rooms: [],
        roomCounter: state.breakoutRoomCounter
      };
    }
    const mainRoomJID = typeof manager.getMainRoomJid === 'function'
      ? manager.getMainRoomJid()
      : null;
    return {
      isSupported: typeof manager.isSupported === 'function' ? !!manager.isSupported() : false,
      canRename: typeof manager.isFeatureSupported === 'function'
        ? !!manager.isFeatureSupported('rename')
        : false,
      isBreakoutRoom: typeof manager.isBreakoutRoom === 'function'
        ? !!manager.isBreakoutRoom()
        : false,
      mainRoomJID: mainRoomJID ? String(mainRoomJID) : null,
      rooms: state.breakoutRooms,
      roomCounter: state.breakoutRoomCounter
    };
  }

  /**
   * Stages the identity jitsi-meet clients understand on the room's presence map before the
   * join. The initial presence then carries all of it in one stanza: `nick` for the display
   * name, the `avatar-url` / `email` commands the web app listens for, and
   * `jitsi_participant_<key>` for everything else. sendCommand() itself calls
   * sendPresence(), which is a no-op until the room is joined, so nothing is sent twice.
   */
  function applyUserInfo(conference, userInfo) {
    if (!userInfo) {
      return;
    }
    if (userInfo.displayName && typeof conference.setDisplayName === 'function') {
      conference.setDisplayName(userInfo.displayName);
    }
    if (typeof conference.sendCommand !== 'function') {
      return;
    }
    if (userInfo.avatarURL) {
      conference.sendCommand('avatar-url', { value: userInfo.avatarURL });
    }
    if (userInfo.email) {
      conference.sendCommand('email', { value: userInfo.email });
    }
    const extras = userInfo.extras || {};
    if (typeof conference.setLocalParticipantProperty === 'function') {
      Object.keys(extras).forEach(key => {
        const value = String(extras[key]);
        conference.setLocalParticipantProperty(key, value);
        state.localParticipantProperties[key] = value;
      });
    }
  }

  function escapeXML(value) {
    return String(value === undefined || value === null ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&apos;');
  }

  function stanzaError(error) {
    if (!error) {
      return 'unknown error';
    }
    try {
      return new XMLSerializer().serializeToString(error).slice(0, 500);
    } catch (failure) {
      return String(error);
    }
  }

  /**
   * Sends an IQ and waits for the focus/MUC to answer. The lib's own `muteParticipant`
   * and `kickParticipant` are fire-and-forget: a non-moderator caller never learns that
   * the server rejected the request. Building the same stanzas here is what lets Swift
   * surface the rejection instead of reporting success.
   */
  function sendIQ(conference, xml, operation) {
    const room = conference && conference.room;
    const connection = room && room.connection;
    if (!connection || typeof connection.sendIQ !== 'function') {
      throw new Error(operation + ': XMPP connection is gone');
    }
    return new Promise((resolve, reject) => {
      connection.sendIQ(
        new DOMParser().parseFromString(xml, 'text/xml').documentElement,
        result => resolve(result || true),
        error => reject(new Error(operation + ' rejected: ' + stanzaError(error))),
        15000);
    });
  }

  // ---------------------------------------------------------------------------
  // Event wiring
  // ---------------------------------------------------------------------------
  // JitsiConnection only exposes `addEventListener`; `on` is the JitsiConference API.
  // A replaced connection still delivers events: Strophe flushes its pending callbacks after
  // `disconnect()`, so a late CONNECTION_FAILED from the old socket would schedule a second
  // rejoin on top of a healthy one. Only the object in `state.connection` may reach Swift.
  function wireConnection(connection) {
    const Events = connectionEvents();
    const on = (name, handler) => {
      const event = Events[name];
      if (event === undefined) {
        console.warn('connection event missing from this lib build: ' + name);
        return;
      }
      connection.addEventListener(event, (...args) => {
        if (state.connection !== connection) {
          return;
        }
        handler(...args);
      });
    };

    on('CONNECTION_ESTABLISHED', jid => {
      state.connectionJID = jid || (connection.getJid ? connection.getJid() : null) || null;
      emit('connectionStatus', { status: 'connected' });
    });
    on('CONNECTION_DISCONNECTED', () => {
      state.connectionJID = null;
      emit('connectionStatus', { status: 'disconnected' });
    });
    on('CONNECTION_FAILED', (error, ...args) => {
      const name = (error && (error.name || String(error))) || 'unknown';
      emit('connectionStatus', { status: 'error', error: name, details: plain(args) });
      // The lib has exhausted its BOSH retries (deployment is BOSH-only, so stream resume
      // never applies). The room is gone and only a fresh connect/join recovers it.
      if (name === 'connection.droppedError') {
        // The JitsiConference instance is unusable once the stream is gone: release its
        // tracks and forget it so the next prepare() builds a fresh one for the rejoin.
        disposeLocalTracks();
        closePeerConnections();
        state.conference = null;
        state.preparedName = null;
        state.switchingRoom = false;
        resetConferenceState();
        emit('connectionLost', { reason: name, details: plain(args) });
      }
    });
    on('CONNECTION_REDIRECTED', () => emit('connectionRedirected', {}));
    on('CONNECTION_TOKEN_EXPIRED', handler => emit('tokenExpired', { resumable: !!handler }));
    on('PROPERTIES_UPDATED', properties =>
      emit('connectionPropertiesUpdated', plainObject(properties)));
    on('DISPLAY_NAME_REQUIRED', () => emit('displayNameRequired', {}));
  }

  // lib-jitsi-meet handles AUDIO/VIDEO/DESKTOP_MUTED_BY_FOCUS internally: it flips
  // `isMutedByFocus` (and the per-media variants) when the focus-requested mute completes,
  // but exposes no public event for it. The track mute event usually lands just before that
  // promise resolves, so re-check the flag once the mute has settled.
  function reportLocalMuteByFocus(track) {
    const conference = state.conference || track.conference;
    if (!conference) {
      return;
    }
    const mediaType = track.getType();
    const desktop = mediaType === 'video'
      && typeof track.getVideoType === 'function'
      && track.getVideoType() === 'desktop';
    const actor = desktop
      ? conference.mutedDesktopByFocusActor
      : mediaType === 'audio'
        ? conference.mutedByFocusActor
        : conference.mutedVideoByFocusActor;
    setTimeout(() => {
      const byFocus = desktop
        ? conference.isDesktopMutedByFocus
        : mediaType === 'audio'
          ? conference.isMutedByFocus
          : conference.isVideoMutedByFocus;
      if (!byFocus || !track.isMuted()) {
        return;
      }
      emit('localMutedByFocus', {
        mediaType,
        desktop,
        actor: actor || null
      });
    }, 100);
  }

  function wireConference(conference) {
    const Events = conferenceEvents();
    const on = (name, handler) => {
      const event = Events[name];
      if (event === undefined) {
        console.warn('conference event missing from this lib build: ' + name);
        return;
      }
      conference.on(event, handler);
    };

    on('CONFERENCE_JOINED', id => {
      state.conference = conference;
      state.lobbyWaitingForHost = false;
      emit('conferenceJoined', { id });
    });
    on('CONFERENCE_LEFT', id => {
      state.conference = null;
      state.preparedName = null;
      state.lobbyWaitingForHost = false;
      if (state.switchingRoom) {
        // Deliberate room switch: the new conference is created right after, and Swift must
        // not see a transient "left" (it would stop metrics and flash "meeting ended").
        return;
      }
      emit('conferenceLeft', { id });
    });
    on('CONFERENCE_FAILED', (error, ...args) => {
      const name = (error && (error.name || String(error))) || 'unknown';
      if (name === 'conference.connectionError.membersOnly') {
        // The 407 carries the lobby MUC JID and, on wait-for-host deployments, the
        // <waiting-for-host/> marker. Both describe how admission happens, so report the
        // flag before the failure: Swift uses it to tell the two lobby flows apart.
        state.lobbyRoomJid = args[0] || null;
        state.lobbyWaitingForHost = !!args[1];
        console.info('[sdk][lobby] members-only: lobbyRoomJid='
          + (state.lobbyRoomJid || '(none)')
          + ' waitingForHost=' + state.lobbyWaitingForHost);
        emit('lobbyWaitingForHost', { waiting: state.lobbyWaitingForHost });
      }
      emit('conferenceFailed', {
        error: name,
        details: plain(args)
      });
    });
    on('CONFERENCE_ERROR', error => emit('conferenceError', {
      error: (error && (error.name || String(error))) || 'unknown',
      message: (error && error.message) || ''
    }));
    on('AUTH_STATUS_CHANGED', status => emit('authStatusChanged', { status: String(status) }));

    on('USER_JOINED', (id, participant) => emit('participantJoined', participantSnapshot(participant)));
    on('USER_LEFT', (id, participant) => emit('participantLeft', participantSnapshot(participant) || { id }));
    on('USER_ROLE_CHANGED', (id, role) => emit('participantRoleChanged', { id, role }));
    on('DISPLAY_NAME_CHANGED', (id, name) => emit('participantDisplayNameChanged', { id, name }));

    // Avatar and email never appear on JitsiParticipant; they travel as presence commands
    // (`avatar-url`, `email`) that the MUC delivers per participant. The handler receives
    // (node, participantId, from), so the id here is the MUC resource the participant map
    // is keyed by. A removed command arrives with no value and clears the field.
    const onCommand = (command, report) => {
      if (typeof conference.addCommandListener !== 'function') {
        console.warn('conference.addCommandListener missing from this lib build: ' + command);
        return;
      }
      conference.addCommandListener(command, (node, participantId) => {
        const value = node && node.value !== undefined
          ? node.value
          : (node && node.attributes && node.attributes.value);
        report(participantId, value === undefined ? null : String(value));
      });
    };
    onCommand('avatar-url', (id, value) => emit('participantAvatarChanged', { id, value }));
    onCommand('email', (id, value) => emit('participantEmailChanged', { id, value }));
    on('USER_STATUS_CHANGED', (id, status) => emit('participantStatusChanged', { id, status: plain(status) }));
    on('PARTICIPANT_PROPERTY_CHANGED', (participant, key, oldValue, newValue) => {
      if (key === 'raiseHand') {
        emit('raisedHandChanged', { id: participant.getId(), raised: asBool(newValue) });
      } else {
        emit('participantPropertyChanged', {
          id: participant.getId(),
          key,
          value: plain(newValue),
          previous: plain(oldValue)
        });
      }
    });
    on('PARTICIPANT_SOURCE_UPDATED', id => emit('participantSourcesUpdated', { id }));
    on('PARTCIPANT_FEATURES_CHANGED', id => emit('participantFeaturesChanged', { id }));
    on('DOMINANT_SPEAKER_CHANGED', (id, previous, confidence) =>
      emit('dominantSpeakerChanged', { id, previous, confidence }));

    on('TRACK_ADDED', track => {
      const snapshot = trackSnapshot(track);
      if (track.isLocal()) {
        state.localTracks.set(trackKey(track), track);
        emit('localTrackAdded', snapshot);
      } else {
        emit('remoteTrackAdded', { track: snapshot, owner: track.getParticipantId() });
      }
    });
    on('TRACK_REMOVED', track => {
      if (track.isLocal()) {
        state.localTracks.delete(trackKey(track));
        state.attached.delete(trackKey(track));
        emit('localTrackRemoved', trackSnapshot(track));
      } else {
        emit('remoteTrackRemoved', { track: trackSnapshot(track), owner: track.getParticipantId() });
      }
    });
    on('TRACK_MUTE_CHANGED', track => {
      emit('trackMuteChanged', trackSnapshot(track));
      // The lib only reports mute state per track; the API models it per participant too,
      // which is what a participant tile reads.
      emit('participantMuted', {
        id: track.getParticipantId(),
        mediaType: track.getType(),
        muted: !!track.isMuted()
      });
      if (track.isLocal() && track.isMuted()) {
        reportLocalMuteByFocus(track);
      }
    });
    on('TRACK_AUDIO_LEVEL_CHANGED', (id, level) => emit('audioLevel', { id, level }));
    on('TRACK_UNMUTE_REJECTED', track => emit('trackUnmuteRejected', trackSnapshot(track)));
    on('NO_AUDIO_INPUT', hasInput => emit('noAudioInput', { hasInput }));
    on('AUDIO_INPUT_STATE_CHANGE', state => emit('audioInputState', { state: String(state) }));
    on('TALK_WHILE_MUTED', () => emit('talkWhileMuted', {}));
    on('NOISY_MIC', () => emit('noisyMic', {}));

    // Current lib signatures: group chat emits (participantId, text, ts, displayName, …),
    // private chat (participantId, text, ts, messageId, displayName, …). Only the fields the
    // Swift event models are read here; the old `isPrivate` positional argument no longer exists.
    on('MESSAGE_RECEIVED', (from, text) =>
      emit('chatMessage', { from, text, isPrivate: false }));
    on('PRIVATE_MESSAGE_RECEIVED', (from, text) =>
      emit('chatMessage', { from, text, isPrivate: true }));
    on('ENDPOINT_MESSAGE_RECEIVED', (participant, content) => {
      const from = participant && participant.getId();
      // Endpoint messages are the structured-JSON channel (lib-jitsi-meet's
      // `sendMessage(object)` arrives here as a parsed object). Log both shapes so a
      // two-device run can confirm the payload without turning on signaling tracing.
      console.log('[sdk][json-message] recv from ' + from + ': ' + JSON.stringify(plain(content)));
      emit('endpointMessage', { from, content: plain(content) });
    });
    on('NON_PARTICIPANT_MESSAGE_RECEIVED', (id, text) =>
      emit('nonParticipantMessage', { from: id, text }));
    // XEP-0459: (participantId, reactions[], messageId). A reaction may carry more than one
    // codepoint, and an empty messageId means it is not attached to a chat message.
    on('REACTION_RECEIVED', (id, reactions, messageId) => emit('reactionReceived', {
      id,
      reactions: (Array.isArray(reactions) ? reactions : [reactions]).map(String),
      messageId: messageId || ''
    }));

    on('LAST_N_ENDPOINTS_CHANGED', (added, removed) => emit('lastNEndpointsChanged', { added, removed }));
    on('FORWARDED_SOURCES_CHANGED', (id, sources) => emit('forwardedSourcesChanged', { id, sources: plain(sources) }));
    // One event carries file recording, livestream and HD-migration: the payload is a
    // JibriSession, and its mode says which.
    on('RECORDER_STATE_CHANGED', session => {
      const mode = session && session.getMode ? session.getMode() : undefined;
      const status = session && session.getStatus ? session.getStatus() : String(session);
      if (session && session.getID && status === 'off') {
        state.recordings.delete(String(mode));
      }
      emit('recordingStateChanged', {
        status,
        mode,
        sessionID: session && session.getID ? session.getID() : undefined,
        error: session && session.getError ? session.getError() : undefined
      });
    });
    on('TRANSCRIPTION_STATUS_CHANGED', status => emit('transcriptionStatus', { status: String(status) }));
    on('E2EE_VERIFICATION_AVAILABLE', id => emit('e2eeVerificationAvailable', { id }));
    on('E2EE_VERIFICATION_READY', (id, message) => emit('e2eeVerificationReady', { id, message: plain(message) }));
    on('E2EE_VERIFICATION_COMPLETED', (id, result) => emit('e2eeVerificationCompleted', { id, result: !!result }));
    on('KICKED', (actor, reason, isReplaceParticipant) => {
      // The lib emits the actor participant, a reason string and a "replace" flag; the
      // self-kick path leaves the room right after this event, so the payload has to be
      // complete here or the app cannot tell a host kick from a duplicate-JWT replacement.
      emit('kicked', {
        actor: actor && typeof actor.getId === 'function' ? actor.getId() : null,
        reason: reason || '',
        replaced: !!isReplaceParticipant
      });
    });
    on('PARTICIPANT_KICKED', (id, actor, reason) => emit('participantKicked', { id, actor, reason }));
    on('LOCK_STATE_CHANGED', locked => {
      state.locked = !!locked;
      emit('lockStateChanged', { locked: !!locked });
    });
    // jicofo's room properties (`audio-limit-reached`, `bridge-count`, visitor counters…).
    // These are not participant properties; those arrive on PARTICIPANT_PROPERTY_CHANGED.
    on('PROPERTIES_CHANGED', properties => {
      state.conferenceProperties = plainObject(properties);
      emit('conferencePropertiesChanged', state.conferenceProperties);
    });
    // Lobby users are not in the participant map and each event carries a delta, so keep a
    // merged snapshot per id and emit the whole row.
    on('LOBBY_USER_JOINED', (id, nick, avatarURL) => {
      const user = { id, displayName: nick || '', avatarURL: avatarURL || null };
      state.lobbyUsers.set(id, user);
      emit('lobbyUserJoined', user);
    });
    on('LOBBY_USER_UPDATED', (id, change) => {
      const existing = state.lobbyUsers.get(id) || { id, displayName: '' };
      const user = Object.assign({}, existing, plainObject(change));
      state.lobbyUsers.set(id, user);
      emit('lobbyUserUpdated', user);
    });
    on('LOBBY_USER_LEFT', id => {
      state.lobbyUsers.delete(id);
      emit('lobbyUserLeft', { id });
    });
    if (typeof conference.addLobbyMessageListener === 'function') {
      conference.addLobbyMessageListener((message, participantId) =>
        emit('lobbyMessageReceived', { from: participantId || null, message: plain(message) }));
    }
    on('AV_MODERATION_CHANGED', (enabled, mediaType, actor) => {
      if (mediaType) {
        state.avModeration[mediaType] = !!enabled;
      }
      emit('avModerationChanged', {
        enabled: !!enabled,
        mediaType: mediaType || null,
        actor: actor && typeof actor.getId === 'function' ? actor.getId() : null
      });
    });
    on('AV_MODERATION_APPROVED', mediaType => emit('avModerationApproved', { mediaType }));
    on('AV_MODERATION_REJECTED', mediaType => emit('avModerationRejected', { mediaType }));
    const moderationParticipant = payload => ({
      id: payload && payload.participant && typeof payload.participant.getId === 'function'
        ? payload.participant.getId()
        : null,
      mediaType: payload && payload.mediaType
    });
    on('AV_MODERATION_PARTICIPANT_APPROVED', payload =>
      emit('avModerationParticipantApproved', moderationParticipant(payload)));
    on('AV_MODERATION_PARTICIPANT_REJECTED', payload =>
      emit('avModerationParticipantRejected', moderationParticipant(payload)));
    on('BREAKOUT_ROOMS_UPDATED', payload => {
      const data = plainObject(payload);
      const rooms = plainObject(data.rooms);
      state.breakoutRooms = Object.keys(rooms).map(jid => breakoutRoomSnapshot(jid, rooms[jid]));
      state.breakoutRoomCounter = typeof data.roomCounter === 'number' ? data.roomCounter : 0;
      emit('breakoutRoomsUpdated', {
        rooms: state.breakoutRooms,
        roomCounter: state.breakoutRoomCounter
      });
    });
    // The lib argument is the target room's JID (not an id); name it accordingly.
    on('BREAKOUT_ROOMS_MOVE_TO_ROOM', roomJid =>
      emit('breakoutRoomsMoveToRoom', { roomJid: String(roomJid || '') }));
    on('SUBJECT_CHANGED', (subject, old) => emit('subjectChanged', { subject, previous: old }));
    on('METADATA_UPDATED', (metadata, old) => emit('metadataUpdated', { metadata: plain(metadata), previous: plain(old) }));
    on('SERVER_REGION_CHANGED', region => emit('serverRegionChanged', { region }));
    on('P2P_STATUS', (p2p, old) => emit('p2pStatus', { p2p: !!p2p, previous: !!old }));
    on('CONNECTION_INTERRUPTED', () => emit('connectionInterrupted', {}));
    on('CONNECTION_RESTORED', () => emit('connectionRestored', {}));
    on('SUSPEND_DETECTED', () => emit('suspendDetected', {}));
    on('DATA_CHANNEL_OPENED', () => emit('bridgeChannelOpened', {}));
    on('DATA_CHANNEL_CLOSED', () => emit('bridgeChannelClosed', {}));
    on('VIDEO_CODEC_CHANGED', () => emit('videoCodecChanged', {}));
    on('START_MUTED_POLICY_CHANGED', policy => emit('startMutedPolicy', plain(policy)));
    on('DTMF_SUPPORT_CHANGED', supported => emit('dtmfSupportChanged', { supported: !!supported }));
    on('VIDEO_SIP_GW_AVAILABILITY_CHANGED', status => emit('videoSipGwAvailability', { status: String(status) }));
    on('VIDEO_SIP_GW_SESSION_STATE_CHANGED', payload => emit('videoSipGwSessionState', plain(payload)));
    on('POLL_RECEIVED', poll => emit('pollReceived', plain(poll)));
    on('POLL_ANSWER_RECEIVED', answer => emit('pollAnswerReceived', plain(answer)));
    on('FILE_SHARING_FILES_RECEIVED', files => emit('fileSharingFiles', plain(files)));

    // Conference metadata and room visibility. The lib emits PHONE_NUMBER_CHANGED without an
    // argument, so the value is read from the getter at event time.
    on('CONFERENCE_JOIN_IN_PROGRESS', () => emit('conferenceJoinInProgress', {}));
    on('CONFERENCE_UNIQUE_ID_SET', id => emit('conferenceUniqueIDSet', { id }));
    on('CONFERENCE_CREATED_TIMESTAMP', timestamp =>
      emit('conferenceCreatedTimestamp', { timestamp: String(timestamp) }));
    // Conference-level ICE (the first media connection). Later recoveries are
    // CONNECTION_RESTORED; the XMPP status is reported by the connection.
    on('CONNECTION_ESTABLISHED', () => emit('conferenceConnectionEstablished', {}));
    on('AUDIO_UNMUTE_PERMISSIONS_CHANGED', audioLimitReached =>
      emit('audioUnmutePermissionsChanged', { audioLimitReached: !!audioLimitReached }));
    on('VIDEO_UNMUTE_PERMISSIONS_CHANGED', videoLimitReached =>
      emit('videoUnmutePermissionsChanged', { videoLimitReached: !!videoLimitReached }));
    on('CONFERENCE_VISITOR_CODECS_CHANGED', codecs =>
      emit('visitorCodecsChanged', { codecs: Array.isArray(codecs) ? codecs.map(String) : [] }));
    on('BOT_TYPE_CHANGED', (id, botType) =>
      emit('botTypeChanged', { id, botType: botType === undefined ? null : String(botType) }));
    on('PERMISSIONS_RECEIVED', permissions =>
      emit('permissionsReceived', { permissions: plainObject(permissions) }));
    on('SILENT_STATUS_CHANGED', (id, isSilent) =>
      emit('silentStatusChanged', { id, isSilent: !!isSilent }));
    on('MEMBERS_ONLY_CHANGED', membersOnly => emit('membersOnlyChanged', { membersOnly: !!membersOnly }));
    on('VISITORS_SUPPORTED_CHANGED', supported =>
      emit('visitorsSupportedChanged', { supported: !!supported }));
    on('PHONE_NUMBER_CHANGED', () => emit('phoneNumberChanged', {
      phoneNumber: typeof conference.getPhoneNumber === 'function' ? conference.getPhoneNumber() : null
    }));
    on('FILE_SHARING_FILE_ADDED', file => emit('fileSharingFileAdded', { file: plain(file) }));
    on('FILE_SHARING_FILE_REMOVED', id => emit('fileSharingFileRemoved', { id }));
    on('VISITORS_MESSAGE', message => emit('visitorsMessage', { message: plain(message) }));
    on('VISITORS_REJECTION', () => emit('visitorsRejection', {}));

    // Statistics. Endpoint stats carry a participant object; the RTP maps are keyed by SSRC
    // and the peer connection is identified by its numeric id.
    on('BRIDGE_BWE_STATS_RECEIVED', bwe => emit('bridgeBweStatsReceived', { bandwidth: Number(bwe) || 0 }));
    on('ENDPOINT_STATS_RECEIVED', (participant, stats) => emit('endpointStatsReceived', {
      id: participant && typeof participant.getId === 'function' ? participant.getId() : null,
      stats: mapToPlain(stats)
    }));
    on('ENCODE_TIME_STATS_RECEIVED', (tpc, stats) => emit('encodeTimeStatsReceived', {
      peerConnection: tpc && tpc.id !== undefined ? tpc.id : null,
      stats: mapToPlain(stats)
    }));
    on('INBOUND_VIDEO_STATS_RECEIVED', (tpc, stats) => emit('inboundVideoStatsReceived', {
      peerConnection: tpc && tpc.id !== undefined ? tpc.id : null,
      stats: mapToPlain(stats)
    }));
    on('BEFORE_STATISTICS_DISPOSED', () => emit('beforeStatisticsDisposed', {}));

    // Connection quality and e2e ping are separate listenables on the lib.
    try {
      const qualityEvents = lib().events.connectionQuality;
      conference.on(qualityEvents.LOCAL_STATS_UPDATED, stats => emit('localStats', plain(stats)));
      conference.on(qualityEvents.REMOTE_STATS_UPDATED, (id, stats) => emit('remoteStats', { id, stats: plain(stats) }));
    } catch (error) {
      console.warn('connectionQuality events not attached', error);
    }
  }

  // `conference.join()` only starts the MUC join. A reconnect or a room switch that returned
  // here would be marked successful even when the join later failed, and no further attempt
  // would run, so the caller can opt into waiting for the terminal event.
  function waitForConferenceJoin(conference, name, args) {
    const Events = conferenceEvents();
    const timeout = typeof args.waitTimeout === 'number' ? args.waitTimeout : 15000;
    return new Promise((resolve, reject) => {
      let settled = false;
      let timer = null;
      const detach = () => {
        if (timer !== null) {
          clearTimeout(timer);
          timer = null;
        }
        if (typeof conference.off === 'function') {
          conference.off(Events.CONFERENCE_JOINED, onJoined);
          conference.off(Events.CONFERENCE_FAILED, onFailed);
          conference.off(Events.CONFERENCE_LEFT, onLeft);
        }
      };
      const finish = (fn, value) => {
        if (settled) {
          return;
        }
        settled = true;
        detach();
        fn(value);
      };
      const onJoined = id => finish(resolve, { name, joined: true, id });
      const onFailed = error => finish(reject, new Error(
        'conference join failed: '
          + ((error && (error.name || error.message)) || 'unknown')));
      const onLeft = () => finish(reject, new Error('conference left before joining'));
      conference.on(Events.CONFERENCE_JOINED, onJoined);
      conference.on(Events.CONFERENCE_FAILED, onFailed);
      conference.on(Events.CONFERENCE_LEFT, onLeft);
      timer = setTimeout(() => finish(reject,
        new Error('timed out waiting for CONFERENCE_JOINED')), timeout);
    });
  }

  // ---------------------------------------------------------------------------
  // Method table: `swift.methodName` -> handler
  // ---------------------------------------------------------------------------
  const methods = {
    'lib.init'(args) {
      const instance = lib();
      const levels = instance.logLevels || {};
      const requested = String(args.logLevel || 'info').toUpperCase();
      state.logLevel = requested;
      global.__jitsiDebug = !!args.debug;
      instance.setLogLevel(global.__jitsiDebug ? levels.DEBUG : levels[requested] ?? levels.INFO);
      instance.init(Object.assign({}, args.options, args.flags ? { flags: args.flags } : {}));
      if (global.__jitsiDebug) {
        console.log('[debug][sdk] signaling tracing enabled (log level DEBUG)');
      }
      try {
        instance.mediaDevices.addEventListener(
          instance.events.mediaDevices.DEVICE_LIST_CHANGED,
          devices => emit('deviceListChanged', plain(devices))
        );
      } catch (error) {
        console.warn('deviceListChanged listener unavailable', error);
      }
      return { version: instance.version || 'unknown', ready: true };
    },

    // TURN/data-channel probe. The lib resolves an object with only the metrics it managed
    // to collect; a React Native throughput run is skipped by the lib itself.
    async 'lib.preCallTest'(args) {
      const instance = lib();
      if (typeof instance.runPreCallTest !== 'function') {
        throw new Error('runPreCallTest missing from this lib build');
      }
      return instance.runPreCallTest(args.iceServers || []);
    },

    'lib.setDebug'(args) {
      global.__jitsiDebug = !!args.enabled;
      if (state.lib && typeof state.lib.setLogLevel === 'function') {
        const levels = state.lib.logLevels || {};
        state.lib.setLogLevel(global.__jitsiDebug
          ? levels.DEBUG
          : levels[state.logLevel] ?? levels.INFO);
      }
      if (global.__jitsiDebug) {
        traceStanzas(state.connection);
      }
      console.log('[debug][sdk] signaling tracing ' + (global.__jitsiDebug ? 'enabled' : 'disabled'));
      return { enabled: global.__jitsiDebug };
    },

    'lib.dispose'() {
      const instance = state.lib;
      state.conference = null;
      state.connection = null;
      resetConferenceState();
      state.localTracks.clear();
      state.attached.clear();
      state.recordings.clear();
      closePeerConnections();
      if (instance && typeof instance.unload === 'function') {
        instance.unload();
      }
      state.lib = null;
      return true;
    },

    'connection.connect'(args) {
      const instance = lib();
      const options = Object.assign({ serviceUrl: args.serviceUrl, hosts: args.hosts }, args.options || {});
      if (args.token) {
        options.token = args.token;
      }
      if (args.credentials) {
        options.credentials = args.credentials;
      }
      if (args.p2p) {
        // Always sent: lib-jitsi-meet otherwise falls back to its public jitsi.net STUN
        // server, which is unreachable from mainland China and leaks the device address.
        options.p2p = args.p2p;
      }
      const connection = new instance.JitsiConnection(args.appName, args.appKey, options);
      state.connection = connection;
      traceStanzas(connection);
      wireConnection(connection);
      emit('connectionStatus', { status: 'connecting' });

      // `connect()` returns void while Strophe is still authenticating. Resolving the bridge
      // call right away let callers create the conference over a socket that was not up yet,
      // which surfaces as `Strophe error: {"reason":"Not connected"}` on the focus request.
      const Events = connectionEvents();
      return new Promise((resolve, reject) => {
        let settled = false;
        const finish = (fn, value) => {
          if (settled) {
            return;
          }
          settled = true;
          clearTimeout(timer);
          fn(value);
        };
        const onEstablished = () => finish(resolve, { jid: connection.jid || null });
        const onFailed = error => finish(reject,
          error instanceof Error ? error : new Error(String((error && error.name) || error || 'connection failed')));
        const timer = setTimeout(
          () => finish(reject, new Error('timed out waiting for CONNECTION_ESTABLISHED')),
          20000);
        connection.addEventListener(Events.CONNECTION_ESTABLISHED, onEstablished);
        connection.addEventListener(Events.CONNECTION_FAILED, onFailed);
        connection.connect();
      });
    },

    'connection.disconnect'() {
      const connection = state.connection;
      // Clear before disconnecting: Strophe emits its final events synchronously, and the
      // identity guard in wireConnection has to drop them. Tracks go too, so a plain leave
      // stops the camera and microphone instead of leaving capture running off-call.
      state.connection = null;
      state.conference = null;
      state.preparedName = null;
      state.switchingRoom = false;
      state.connectionJID = null;
      resetConferenceState();
      disposeLocalTracks();
      closePeerConnections();
      if (connection) {
        connection.disconnect();
      }
      return true;
    },

    'connection.refreshToken'(args) {
      if (!state.connection) {
        throw new Error('not connected');
      }
      // Emitted as CONNECTION_TOKEN_EXPIRED while a dropped stream is being resumed.
      // Without this the resume task is cancelled and the room is lost.
      return Promise.resolve(state.connection.refreshToken(args.token)).then(() => true);
    },

    // Full JID of this endpoint's XMPP session. Null before the session is established.
    'connection.jid'() {
      const connection = state.connection;
      if (!connection || typeof connection.getJid !== 'function') {
        return null;
      }
      const jid = connection.getJid();
      if (jid) {
        return jid;
      }
      // Anonymous sessions get their JID assigned by the server; the event is authoritative
      // until `getJid()` catches up.
      return state.connectionJID || null;
    },

    // Timing marks collected while connecting (DNS, TCP, BOSH, SASL, MUC...). Keys vary by
    // transport version, so this stays an opaque object for the Swift side.
    'connection.times'() {
      const connection = state.connection;
      if (!connection || typeof connection.getConnectionTimes !== 'function') {
        return {};
      }
      return plain(connection.getConnectionTimes()) || {};
    },

    // XEP-0115 caps feature of this client. `submit` re-publishes presence right away.
    'connection.addFeature'(args) {
      const connection = state.connection;
      if (!connection || typeof connection.addFeature !== 'function') {
        throw new Error('not connected');
      }
      connection.addFeature(String(args.feature), !!args.submit);
      return true;
    },

    'connection.removeFeature'(args) {
      const connection = state.connection;
      if (!connection || typeof connection.removeFeature !== 'function') {
        throw new Error('not connected');
      }
      connection.removeFeature(String(args.feature), !!args.submit);
      return true;
    },

    // Resumes an existing XMPP session created elsewhere. The server has to still hold the
    // session (rid + sid); the resulting events flow through the same connection listeners.
    'connection.attach'(args) {
      const connection = state.connection;
      if (!connection || typeof connection.attach !== 'function') {
        throw new Error('not connected');
      }
      connection.attach({ rid: String(args.rid), sid: String(args.sid), jid: String(args.jid) });
      return true;
    },

    // Jingle + XMPP transcripts. They carry JWTs, SASL payloads and TURN credentials, so the
    // same switch that turns on the debug-level transport log gates this call.
    'connection.logs'() {
      if (!global.__jitsiDebug) {
        throw new Error('connection logs require debugSignaling');
      }
      const connection = state.connection;
      if (!connection || typeof connection.getLogs !== 'function') {
        return {};
      }
      return plain(connection.getLogs()) || {};
    },

    // Splits conference creation from joining so local tracks can be registered first.
    // jitsi-meet does the same (`_addLocalTracksToConference` before `conference.join()`):
    // tracks present when the JVB session-initiate arrives are part of the m-lines the
    // client answers with, and the bridge starts forwarding them immediately.
    'conference.prepare'(args) {
      if (!state.connection) {
        throw new Error('not connected');
      }
      if (!state.conference || state.preparedName !== args.name) {
        state.conference = createConference(args);
        state.preparedName = args.name;
      }
      return { name: args.name };
    },

    'conference.join'(args) {
      if (!state.connection) {
        throw new Error('not connected');
      }
      const conference = state.conference && state.preparedName === args.name
        ? state.conference
        : createConference(args);
      // A room password makes the join land in the lobby when the backend has one, and
      // fails with PASSWORD_REQUIRED otherwise. The lib takes it as the first argument.
      conference.join(args.password || '');
      // CONFERENCE_JOINED swaps state.conference; keep it here so requireConference()
      // works for calls issued immediately after join resolves.
      state.conference = conference;
      if (!args.waitForJoin) {
        return { name: args.name, password: !!args.password };
      }
      return waitForConferenceJoin(conference, args.name, args);
    },

    // Moves this endpoint to another MUC on the same connection: into a breakout room, back
    // to the main room, or between breakouts. `leave('switch_room')` tells the lib this is a
    // redirect (it sets `_breakoutMovingToMain` when leaving a breakout), and the local
    // tracks survive the leave, so they are re-added to the new conference before joining —
    // the same ordering `conference.prepare` + `conference.addTrack` uses for a first join.
    async 'conference.switch'(args) {
      if (!state.connection) {
        throw new Error('not connected');
      }
      if (!args.name) {
        throw new Error('conference name is required');
      }
      const previous = state.conference;
      if (!previous) {
        const created = createConference(args);
        created.join(args.password || '');
        state.conference = created;
        return waitForConferenceJoin(created, args.name, args);
      }
      const tracks = Array.from(state.attached.values());
      // The new conference starts from a clean presence map, so anything written to the old
      // room has to be staged again before the first presence goes out.
      const properties = Object.assign({}, state.localParticipantProperties);
      state.switchingRoom = true;
      try {
        await previous.leave('switch_room');
        state.attached.clear();
        const conference = createConference(args);
        if (typeof conference.setLocalParticipantProperty === 'function') {
          Object.keys(properties).forEach(name => {
            conference.setLocalParticipantProperty(name, properties[name]);
          });
        }
        await Promise.all(tracks.map(track => conference.addTrack(track)));
        tracks.forEach(track => state.attached.set(trackKey(track), track));
        conference.join(args.password || '');
        return await waitForConferenceJoin(conference, args.name, args);
      } finally {
        state.switchingRoom = false;
      }
    },

    'conference.leave'() {
      if (state.conference) {
        state.conference.leave();
      }
      state.preparedName = null;
      state.switchingRoom = false;
      resetConferenceState();
      return true;
    },

    'conference.createLocalTracks'(args) {
      return lib().createLocalTracks(args.options || {}).then(tracks => {
        const list = Array.isArray(tracks) ? tracks : [tracks];
        return list.map(track => {
          const snapshot = trackSnapshot(track);
          if (track) {
            state.localTracks.set(trackKey(track), track);
          }
          return snapshot;
        });
      });
    },

    'conference.addTrack'(args) {
      const track = state.localTracks.get(args.trackId);
      if (!track) {
        console.error('[sdk] unknown local track ' + args.trackId
          + '; known: ' + Array.from(state.localTracks.keys()).join(','));
        throw new Error('unknown local track: ' + args.trackId);
      }
      return requireConference().addTrack(track).then(() => {
        state.attached.set(args.trackId, track);
        return trackSnapshot(track);
      });
    },

    'conference.removeTrack'(args) {
      const track = state.attached.get(args.trackId) || state.localTracks.get(args.trackId);
      if (!track) {
        return true;
      }
      return requireConference().removeTrack(track).then(() => {
        state.attached.delete(args.trackId);
        state.localTracks.delete(args.trackId);
        // Removing a track is terminal in this API: dispose the wrapper so lib-jitsi-meet
        // stops the underlying native track (camera or screen capture) instead of leaking it.
        try {
          if (typeof track.dispose === 'function') {
            track.dispose();
          }
        } catch (error) {
          console.warn('[sdk] track.dispose failed: ' + error.message);
        }
        return true;
      });
    },

    'conference.setMuted'(args) {
      const track = state.localTracks.get(args.trackId);
      if (!track) {
        throw new Error('unknown local track: ' + args.trackId);
      }
      // `JitsiLocalTrack.mute()` takes no argument and always mutes; an unmute is
      // `unmute()`. Passing the flag to `mute()` silently re-muted and then short-circuited
      // on `isMuted() === true`, so neither side ever saw the camera or mic come back.
      const operation = Boolean(args.muted) ? track.mute() : track.unmute();
      return operation.then(() => trackSnapshot(track));
    },

    'conference.sendMessage'(args) {
      requireConference().sendMessage(args.text, args.to || '');
      return true;
    },

    // lib-jitsi-meet wraps an object payload in a `json-message` extension (adding an empty
    // `type` property when the payload has none) and delivers it to peers as an endpoint
    // message. Both directions log the payload so verification does not need stanza tracing.
    'conference.sendJSONMessage'(args) {
      const payload = args.payload;
      if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
        throw new Error('sendJSONMessage expects a JSON object');
      }
      console.log('[sdk][json-message] send to ' + (args.to || 'all') + ': ' + JSON.stringify(payload));
      requireConference().sendMessage(payload, args.to || '');
      return true;
    },

    // Generic presence commands. `values` become attributes of the `<name>` extension the
    // lib writes into the local presence, which is how raise-hand and the identity commands
    // already travel; this exposes the general form.
    'conference.sendCommand'(args) {
      return sendPresenceCommand(args, false);
    },

    'conference.sendCommandOnce'(args) {
      return sendPresenceCommand(args, true);
    },

    'conference.removeCommand'(args) {
      const conference = requireConference();
      const name = commandName(args);
      if (typeof conference.removeCommand !== 'function') {
        throw new Error('removeCommand is not supported by this lib build');
      }
      conference.removeCommand(name);
      return true;
    },

    // A command listener is registered once per name; deliveries arrive as `commandReceived`
    // with the presence node's attribute values.
    'conference.addCommandListener'(args) {
      const conference = requireConference();
      const name = commandName(args);
      if (typeof conference.addCommandListener !== 'function') {
        throw new Error('addCommandListener is not supported by this lib build');
      }
      if (!state.commandListeners.has(name)) {
        const handler = (node, participantId) => emit('commandReceived', {
          name,
          from: participantId,
          values: presenceNodeValues(node)
        });
        state.commandListeners.set(name, handler);
        conference.addCommandListener(name, handler);
      }
      return true;
    },

    'conference.removeCommandListener'(args) {
      const name = commandName(args);
      const handler = state.commandListeners.get(name);
      if (!handler) {
        return false;
      }
      state.commandListeners.delete(name);
      const conference = state.conference;
      if (conference && typeof conference.removeCommandListener === 'function') {
        conference.removeCommandListener(name, handler);
      }
      return true;
    },

    // Data-channel signalling: delivered to peers as ENDPOINT_MESSAGE_RECEIVED (Swift:
    // `endpointMessage`) without involving the MUC message archive.
    'conference.sendEndpointMessage'(args) {
      const conference = requireConference();
      if (typeof conference.sendEndpointMessage !== 'function') {
        throw new Error('sendEndpointMessage is not supported by this lib build');
      }
      const payload = args.payload;
      if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
        throw new Error('sendEndpointMessage expects a JSON object');
      }
      conference.sendEndpointMessage(args.to || '', payload);
      return true;
    },

    // XEP-0459. The lib rejects a non-emoji reaction from ChatRoom.sendReaction, so an empty
    // string is the only check worth doing here.
    'conference.sendReaction'(args) {
      const conference = requireConference();
      const reaction = String(args.reaction || '');
      if (!reaction) {
        throw new Error('reaction is required');
      }
      if (typeof conference.sendReaction !== 'function') {
        throw new Error('sendReaction is not supported by this lib build');
      }
      conference.sendReaction(reaction, String(args.messageId || ''), args.to || '');
      return true;
    },

    'conference.setDisplayName'(args) {
      requireConference().setDisplayName(args.name);
      return true;
    },

    // Raising a hand is a presence extension (`jitsi_participant_raiseHand`), which every
    // jitsi-meet client already reads. The lib exposes no raiseHand(), so write presence
    // through setLocalParticipantProperty and clear it symmetrically.
    'conference.raiseHand'(args) {
      const conference = requireConference();
      if (typeof conference.setLocalParticipantProperty !== 'function') {
        throw new Error('raiseHand: this lib build cannot edit presence');
      }
      if (args.raised) {
        conference.setLocalParticipantProperty('raiseHand', true);
        state.localParticipantProperties.raiseHand = true;
      } else if (typeof conference.removeLocalParticipantProperty === 'function') {
        conference.removeLocalParticipantProperty('raiseHand');
        delete state.localParticipantProperties.raiseHand;
      } else {
        conference.setLocalParticipantProperty('raiseHand', false);
        state.localParticipantProperties.raiseHand = false;
      }
      return true;
    },

    // DTMF goes to the active audio sender. The lib has no delivery acknowledgement, so a
    // resolved call only means the tones were handed to the peer connection.
    'conference.sendTones'(args) {
      const conference = requireConference();
      const tones = String(args.tones || '');
      if (!tones) {
        throw new Error('tones are required');
      }
      if (typeof conference.sendTones !== 'function') {
        throw new Error('sendTones is not supported by this lib build');
      }
      const duration = Number(args.duration);
      const pause = Number(args.pause);
      if (!isFinite(duration) || duration <= 0) {
        throw new Error('duration must be a positive number of milliseconds');
      }
      if (!isFinite(pause) || pause < 0) {
        throw new Error('pause must be a non-negative number of milliseconds');
      }
      conference.sendTones(tones, duration, pause);
      return true;
    },

    // Dial-in is a deployment component (`sip_gateway` in Jicofo); the lib answers from the
    // moderator IQ it already holds, so this is a local read.
    'conference.isSIPCallingSupported'() {
      const conference = requireConference();
      return typeof conference.isSIPCallingSupported === 'function'
        ? !!conference.isSIPCallingSupported()
        : false;
    },

    'conference.dial'(args) {
      const conference = requireConference();
      const number = String(args.number || '');
      if (!number) {
        throw new Error('number is required');
      }
      if (typeof conference.dial !== 'function') {
        throw new Error('SIP dialing is not supported by this lib build');
      }
      return Promise.resolve(conference.dial(number)).then(() => true);
    },

    // Anonymous-domain deployments only let logged-in users create rooms. This logs in on a
    // side connection and asks Jicofo to upgrade this conference's role; the main XMPP
    // session is untouched.
    'conference.authenticateAndUpgradeRole'(args) {
      const conference = requireConference();
      const id = String(args.id || '');
      const password = String(args.password || '');
      if (!id || !password) {
        throw new Error('id and password are required');
      }
      if (typeof conference.authenticateAndUpgradeRole !== 'function') {
        throw new Error('authenticateAndUpgradeRole is not supported by this lib build');
      }
      return Promise.resolve(conference.authenticateAndUpgradeRole({ id, password }))
        .then(() => true);
    },

    // -------------------------------------------------------------------------
    // Local participant properties. The lib stores them in the MUC presence map and
    // only offers a per-key getter, so the last written value is mirrored here: that
    // keeps `string[]` values intact and answers without a signalling round-trip.
    // -------------------------------------------------------------------------
    'conference.setLocalParticipantProperty'(args) {
      const conference = requireConference();
      const name = String(args.name || '');
      if (!name) {
        throw new Error('participant property name is required');
      }
      if (typeof conference.setLocalParticipantProperty !== 'function') {
        throw new Error('setLocalParticipantProperty: this lib build cannot edit presence');
      }
      const value = args.value;
      const valid = typeof value === 'string'
        || typeof value === 'boolean'
        || typeof value === 'number'
        || (Array.isArray(value) && value.every(entry => typeof entry === 'string'));
      if (!valid) {
        throw new Error('participant property value must be a string, number, boolean or string array');
      }
      conference.setLocalParticipantProperty(name, value);
      state.localParticipantProperties[name] = plain(value);
      return state.localParticipantProperties[name];
    },

    'conference.removeLocalParticipantProperty'(args) {
      const conference = requireConference();
      const name = String(args.name || '');
      if (!name) {
        throw new Error('participant property name is required');
      }
      if (typeof conference.removeLocalParticipantProperty !== 'function') {
        throw new Error('removeLocalParticipantProperty: this lib build cannot edit presence');
      }
      conference.removeLocalParticipantProperty(name);
      delete state.localParticipantProperties[name];
      return true;
    },

    'conference.localParticipantProperty'(args) {
      const conference = requireConference();
      const name = String(args.name || '');
      if (!name) {
        throw new Error('participant property name is required');
      }
      if (Object.prototype.hasOwnProperty.call(state.localParticipantProperties, name)) {
        return state.localParticipantProperties[name];
      }
      if (typeof conference.getLocalParticipantProperty !== 'function') {
        return null;
      }
      const value = conference.getLocalParticipantProperty(name);
      return value === undefined ? null : value;
    },

    // -------------------------------------------------------------------------
    // Lobby moderation. The lib names the access calls lobbyApproveAccess /
    // lobbyDenyAccess and accepts a string or an array of ids.
    // -------------------------------------------------------------------------
    'conference.myLobbyUserID'() {
      const conference = requireConference();
      if (typeof conference.myLobbyUserId !== 'function') {
        return null;
      }
      const id = conference.myLobbyUserId();
      return id === undefined ? null : id;
    },

    'conference.approveLobbyUser'(args) {
      const conference = requireConference();
      if (!args.participantId) {
        throw new Error('participantId is required');
      }
      if (typeof conference.lobbyApproveAccess !== 'function') {
        throw new Error('approveLobbyUser: this lib build has no lobby moderation');
      }
      conference.lobbyApproveAccess(args.participantId);
      return true;
    },

    'conference.denyLobbyUser'(args) {
      const conference = requireConference();
      if (!args.participantId) {
        throw new Error('participantId is required');
      }
      if (typeof conference.lobbyDenyAccess !== 'function') {
        throw new Error('denyLobbyUser: this lib build has no lobby moderation');
      }
      conference.lobbyDenyAccess(args.participantId);
      return true;
    },

    // `participantId` absent broadcasts to every moderator in the lobby.
    'conference.sendLobbyMessage'(args) {
      const conference = requireConference();
      const message = args.message;
      if (!message || typeof message !== 'object' || Array.isArray(message)) {
        throw new Error('sendLobbyMessage expects a JSON object');
      }
      if (typeof conference.sendLobbyMessage !== 'function') {
        throw new Error('sendLobbyMessage: this lib build has no lobby messaging');
      }
      conference.sendLobbyMessage(message, args.participantId || '');
      return true;
    },

    // -------------------------------------------------------------------------
    // AV moderation. The lib warns and no-ops for non-moderators or unknown ids,
    // so arguments are validated here and the server stays the authority.
    // -------------------------------------------------------------------------
    'conference.isAVModerationSupported'() {
      const conference = requireConference();
      return typeof conference.isAVModerationSupported === 'function'
        && !!conference.isAVModerationSupported();
    },

    'conference.enableAVModeration'(args) {
      const conference = requireConference();
      const mediaType = moderationMediaType(args.mediaType);
      if (typeof conference.enableAVModeration !== 'function') {
        throw new Error('enableAVModeration: this lib build has no AV moderation');
      }
      conference.enableAVModeration(mediaType);
      return true;
    },

    'conference.disableAVModeration'(args) {
      const conference = requireConference();
      const mediaType = moderationMediaType(args.mediaType);
      if (typeof conference.disableAVModeration !== 'function') {
        throw new Error('disableAVModeration: this lib build has no AV moderation');
      }
      conference.disableAVModeration(mediaType);
      return true;
    },

    'conference.approveAVModeration'(args) {
      const conference = requireConference();
      const mediaType = moderationMediaType(args.mediaType);
      if (!findParticipant(conference, args.participantId)) {
        throw new Error('unknown participant: ' + args.participantId);
      }
      if (typeof conference.avModerationApprove !== 'function') {
        throw new Error('approveAVModeration: this lib build has no AV moderation');
      }
      conference.avModerationApprove(mediaType, args.participantId);
      return true;
    },

    'conference.rejectAVModeration'(args) {
      const conference = requireConference();
      const mediaType = moderationMediaType(args.mediaType);
      if (!findParticipant(conference, args.participantId)) {
        throw new Error('unknown participant: ' + args.participantId);
      }
      if (typeof conference.avModerationReject !== 'function') {
        throw new Error('rejectAVModeration: this lib build has no AV moderation');
      }
      conference.avModerationReject(mediaType, args.participantId);
      return true;
    },

    // -------------------------------------------------------------------------
    // Breakout rooms (moderator). `BreakoutRooms` logs and no-ops for a non-moderator or a
    // deployment without the component, so `requireBreakoutRooms` turns that into an error
    // the app can show; the resulting room list arrives via BREAKOUT_ROOMS_UPDATED.
    // -------------------------------------------------------------------------
    'conference.breakoutRoomsState'() {
      return breakoutRoomsStateSnapshot();
    },

    'conference.createBreakoutRoom'(args) {
      const manager = requireBreakoutRooms(requireConference());
      const subject = String(args.subject || '').trim();
      if (!subject) {
        throw new Error('subject is required');
      }
      manager.createBreakoutRoom(subject);
      return true;
    },

    'conference.renameBreakoutRoom'(args) {
      const manager = requireBreakoutRooms(requireConference());
      if (typeof manager.isFeatureSupported === 'function'
          && !manager.isFeatureSupported('rename')) {
        throw new Error('renameBreakoutRoom: this deployment does not support renaming');
      }
      const roomJid = requireRoomJID(args.roomJid, 'roomJid');
      const subject = String(args.subject || '').trim();
      if (!subject) {
        throw new Error('subject is required');
      }
      manager.renameBreakoutRoom(roomJid, subject);
      return true;
    },

    'conference.removeBreakoutRoom'(args) {
      const manager = requireBreakoutRooms(requireConference());
      manager.removeBreakoutRoom(requireRoomJID(args.roomJid, 'roomJid'));
      return true;
    },

    'conference.sendParticipantToBreakoutRoom'(args) {
      const conference = requireConference();
      const manager = requireBreakoutRooms(conference);
      const roomJid = requireRoomJID(args.roomJid, 'roomJid');
      // The component rejects unknown rooms asynchronously (the call itself is void), so a
      // stale list must not block a move the moderator just made; only a room that is in the
      // published list under a different JID is a caller mistake.
      if (state.breakoutRooms.length > 0
          && !state.breakoutRooms.some(room => room.jid === roomJid)) {
        throw new Error('unknown breakout room: ' + roomJid);
      }
      manager.sendParticipantToRoom(
        breakoutParticipantJID(conference, args.participantId), roomJid);
      return true;
    },

    // -------------------------------------------------------------------------
    // Conference control (moderator). These are thin wrappers over JitsiConference's
    // own methods: the lib already warns and no-ops for non-moderators, and the backend
    // rejection is what an app should surface, so nothing is pre-empted here.
    // -------------------------------------------------------------------------
    'conference.end'() {
      const conference = requireConference();
      if (typeof conference.isEndConferenceSupported === 'function'
          && !conference.isEndConferenceSupported()) {
        throw new Error('ending the conference is not supported by this deployment');
      }
      conference.end();
      return true;
    },

    'conference.lock'(args) {
      return requireConference().lock(args.password || '').then(() => true);
    },

    'conference.unlock'() {
      return requireConference().unlock().then(() => true);
    },

    'conference.grantOwner'(args) {
      const conference = requireConference();
      if (!findParticipant(conference, args.participantId)) {
        throw new Error('unknown participant: ' + args.participantId);
      }
      conference.grantOwner(args.participantId);
      return true;
    },

    // `revokeOwner` also accepts the local id, which is how a moderator resigns.
    'conference.revokeOwner'(args) {
      const conference = requireConference();
      const isSelf = typeof conference.myUserId === 'function'
        && conference.myUserId() === args.participantId;
      if (!isSelf && !findParticipant(conference, args.participantId)) {
        throw new Error('unknown participant: ' + args.participantId);
      }
      conference.revokeOwner(args.participantId);
      return true;
    },

    // The lib names this `setIsSilent`: a silent participant joined without audio and
    // peers skip the join chime for them.
    'conference.setSilent'(args) {
      const conference = requireConference();
      if (typeof conference.setIsSilent !== 'function') {
        throw new Error('setSilent: this lib build has no setIsSilent');
      }
      conference.setIsSilent(!!args.silent);
      return true;
    },

    'conference.setSubject'(args) {
      requireConference().setSubject(String(args.subject || ''));
      return true;
    },

    'conference.setStartMutedPolicy'(args) {
      const conference = requireConference();
      if (typeof conference.setStartMutedPolicy !== 'function') {
        throw new Error('setStartMutedPolicy: this lib build cannot edit the policy');
      }
      conference.setStartMutedPolicy({ audio: !!args.audio, video: !!args.video });
      return true;
    },

    // The lib has no `setLocalVideoQuality`: outgoing resolution is the sender constraint.
    async 'conference.setLocalVideoQuality'(args) {
      await requireConference().setSenderVideoConstraint(args.height);
      return true;
    },

    // Capture formats live in the native backend; these two keep Swift inside the facade
    // instead of reaching into the modules MediaModule owns.
    'conference.videoCapabilities'(args) {
      return Native.call('media.trackCapabilities', { trackId: args.trackId });
    },

    'conference.applyVideoConstraints'(args) {
      return Native.call('media.applyConstraints', {
        trackId: args.trackId,
        constraints: args.constraints || {}
      });
    },

    'conference.setReceiverVideoConstraint'(args) {
      requireConference().setReceiverVideoConstraint(args.maxHeight);
      return true;
    },

    'conference.setLastN'(args) {
      requireConference().setLastN(args.lastN);
      return true;
    },

    // Per-source receiver hints. The lib merges these into the constraints it sends on the
    // bridge channel, so omitted fields keep their previous values.
    'conference.setReceiverConstraints'(args) {
      const constraints = {};
      if (args.lastN !== undefined && args.lastN !== null) {
        constraints.lastN = args.lastN;
      }
      if (args.defaultMaxHeight !== undefined && args.defaultMaxHeight !== null) {
        constraints.defaultConstraints = { maxHeight: args.defaultMaxHeight };
      }
      if (args.assumedBandwidthBps !== undefined && args.assumedBandwidthBps !== null) {
        constraints.assumedBandwidthBps = args.assumedBandwidthBps;
      }
      if (args.sourceMaxHeights && typeof args.sourceMaxHeights === 'object') {
        const perSource = {};
        Object.keys(args.sourceMaxHeights).forEach(source => {
          perSource[source] = { maxHeight: args.sourceMaxHeights[source] };
        });
        if (Object.keys(perSource).length > 0) {
          constraints.constraints = perSource;
        }
      }
      requireConference().setReceiverConstraints(constraints);
      return true;
    },

    'conference.setAssumedBandwidthBps'(args) {
      requireConference().setAssumedBandwidthBps(Number(args.bps));
      return true;
    },

    'conference.setDesktopSharingFrameRate'(args) {
      return !!requireConference().setDesktopSharingFrameRate(Number(args.maxFps));
    },

    // Replaces one local track with another in a single offer/answer. Both ids name tracks
    // created through this facade; a nil id on either side means "add" or "remove".
    // The lib does not dispose the old track, so the facade does it once the swap lands.
    'conference.replaceTrack'(args) {
      const conference = requireConference();
      const oldTrackId = args.oldTrackId || null;
      const newTrackId = args.newTrackId || null;
      if (!oldTrackId && !newTrackId) {
        throw new Error('replaceTrack needs an old or a new track');
      }
      const oldTrack = oldTrackId ? state.localTracks.get(oldTrackId) : null;
      if (oldTrackId && !oldTrack) {
        throw new Error('unknown local track: ' + oldTrackId);
      }
      const newTrack = newTrackId ? state.localTracks.get(newTrackId) : null;
      if (newTrackId && !newTrack) {
        throw new Error('unknown local track: ' + newTrackId);
      }
      const wasAttached = oldTrackId ? state.attached.has(oldTrackId) : false;
      const attachesNew = !!newTrack && (!oldTrackId || !wasAttached);
      return conference.replaceTrack(oldTrack || undefined, newTrack || undefined).then(() => {
        if (oldTrackId) {
          state.localTracks.delete(oldTrackId);
          state.attached.delete(oldTrackId);
          try {
            if (typeof oldTrack.dispose === 'function') {
              oldTrack.dispose();
            }
          } catch (error) {
            console.warn('[sdk] track.dispose failed: ' + error.message);
          }
        }
        if (newTrack) {
          state.localTracks.set(newTrackId, newTrack);
          if (attachesNew) {
            state.attached.set(newTrackId, newTrack);
          }
        }
        return newTrack ? trackSnapshot(newTrack) : null;
      });
    },

    'conference.kick'(args) {
      const conference = requireConference();
      const participant = findParticipant(conference, args.participantId);
      if (!participant) {
        throw new Error('unknown participant: ' + args.participantId);
      }
      const room = conference.room;
      if (!room || !room.roomjid) {
        throw new Error('kick: the MUC is not joined yet');
      }
      const nick = String(participant.getId() || '').split('/').pop();
      const reason = args.reason || 'You have been kicked.';
      const xml = '<iq to="' + escapeXML(room.roomjid) + '" type="set">'
        + '<query xmlns="http://jabber.org/protocol/muc#admin">'
        + '<item nick="' + escapeXML(nick) + '" role="none">'
        + '<reason>' + escapeXML(reason) + '</reason>'
        + '</item></query></iq>';
      return sendIQ(conference, xml, 'kick participant').then(() => true);
    },

    'conference.muteRemote'(args) {
      const conference = requireConference();
      if (!args.mute) {
        // Jitsi has no remote unmute: the participant has to unmute themselves, or a
        // moderator approves an AV-moderation request. `muteRemoteAudio` is something
        // else entirely (this endpoint's audio subscription), so it must not be used
        // here — doing so unmuted every remote participant locally and looked like the
        // requested participant had been unmuted.
        throw new Error('remote unmute is not supported; the participant must unmute, '
          + 'or a moderator can approve an AV-moderation request');
      }
      const participant = findParticipant(conference, args.participantId);
      if (!participant) {
        throw new Error('unknown participant: ' + args.participantId);
      }
      const room = conference.room;
      if (!room || !room.focusMucJid) {
        throw new Error('mute: focus is not known yet');
      }
      const mediaType = args.mediaType === 'video' ? 'video' : 'audio';
      const xml = '<iq to="' + escapeXML(room.focusMucJid) + '" type="set">'
        + '<mute xmlns="http://jitsi.org/jitmeet/' + mediaType + '" '
        + 'jid="' + escapeXML(participant.getJid()) + '">true</mute></iq>';
      return sendIQ(conference, xml, 'mute participant').then(() => true);
    },

    // This is the local receive switch, not a moderator action: it asks the bridge to
    // stop forwarding any remote audio to this endpoint. Named explicitly so nobody
    // mistakes it for "unmute participant X".
    'conference.setRemoteAudioSubscription'(args) {
      requireConference().muteRemoteAudio(Boolean(args.muted));
      return true;
    },

    // Polls live in the Prosody polls component; isSupported() is false when the
    // deployment has no such component.
    'conference.pollsSupported'() {
      const polls = requireConference().getPolls && requireConference().getPolls();
      return !!(polls && typeof polls.isSupported === 'function' && polls.isSupported());
    },

    'conference.createPoll'(args) {
      const polls = requireConference().getPolls && requireConference().getPolls();
      if (!polls) {
        throw new Error('polls are not supported by this deployment');
      }
      polls.createPoll(
        args.pollId,
        args.question,
        (args.answers || []).map(name => ({ name })));
      return true;
    },

    'conference.answerPoll'(args) {
      const polls = requireConference().getPolls && requireConference().getPolls();
      if (!polls) {
        throw new Error('polls are not supported by this deployment');
      }
      polls.answerPoll(args.pollId, (args.answers || []).map(Boolean));
      return true;
    },

    'conference.enableLobby'() {
      return requireConference().enableLobby().then(() => true);
    },

    'conference.disableLobby'() {
      requireConference().disableLobby();
      return true;
    },

    'conference.joinLobby'(args) {
      // Name the lobby room when the knock fails: a JID that no longer exists (the host
      // arrived and the wait-for-host lobby was destroyed) is otherwise indistinguishable
      // from a knock no moderator reacted to.
      console.info('[sdk][lobby] knocking in '
        + (state.lobbyRoomJid || '(unknown lobby room)')
        + (state.lobbyWaitingForHost ? ' (waiting for host)' : ''));
      return requireConference()
        .joinLobby(args.displayName || '', args.email || '')
        .then(() => {
          console.info('[sdk][lobby] joined the lobby room, waiting for admission');
          return true;
        })
        .catch(error => {
          console.warn('[sdk][lobby] knock failed: '
            + ((error && (error.message || error)) || 'unknown'));
          throw error;
        });
    },

    'conference.startRecording'(args) {
      const mode = String(args.mode || 'file');
      return requireConference()
        .startRecording(Object.assign({ mode }, args.options || {}))
        .then(session => {
          if (session && session.getID) {
            state.recordings.set(mode, session);
          }
          return {
            mode,
            sessionID: session && session.getID ? session.getID() : null,
            status: session && session.getStatus ? session.getStatus() : null
          };
        });
    },

    // The lib stops by session id; without one it resolves the mode to undefined, so the id
    // captured at start is what makes a bare stopRecording() stop the right session.
    'conference.stopRecording'(args) {
      const mode = String(args.mode || 'file');
      const session = state.recordings.get(mode);
      const sessionID = args.sessionId || (session && session.getID && session.getID()) || undefined;
      return requireConference().stopRecording(sessionID).then(() => {
        state.recordings.delete(mode);
        return true;
      });
    },

    'conference.e2ee'() {
      unimplemented('E2EE (phase 4: needs crypto.subtle over CryptoKit + encoded-frame transformers)');
    },

    'conference.state'() {
      const conference = state.conference;
      if (!conference) {
        return { joined: false, participants: [] };
      }
      return {
        joined: conference.isJoined(),
        authRequired: conference.isAuthRequired ? !!conference.isAuthRequired() : false,
        passwordRequired: conference.isPasswordRequired ? !!conference.isPasswordRequired() : false,
        e2eeEnabled: !!conference.isE2EEEnabled(),
        isModerator: typeof conference.isModerator === 'function' ? !!conference.isModerator() : false,
        lobbySupported: typeof conference.isLobbySupported === 'function' ? !!conference.isLobbySupported() : false,
        lobbyEnabled: typeof conference.isMembersOnly === 'function' ? !!conference.isMembersOnly() : false,
        isLocked: !!state.locked,
        endConferenceSupported: typeof conference.isEndConferenceSupported === 'function'
          ? !!conference.isEndConferenceSupported() : false,
        startMutedPolicy: typeof conference.getStartMutedPolicy === 'function'
          ? plain(conference.getStartMutedPolicy()) : null,
        visitorsSupported: typeof conference.isVisitorsSupported === 'function'
          ? !!conference.isVisitorsSupported() : false,
        myUserId: typeof conference.myUserId === 'function' ? conference.myUserId() : null,
        localParticipantProperties: state.localParticipantProperties,
        conferenceProperties: state.conferenceProperties,
        lobbyUsers: Array.from(state.lobbyUsers.values()),
        avModeration: state.avModeration,
        breakoutRooms: breakoutRoomsStateSnapshot(),
        participants: conference.getParticipants().map(participantSnapshot)
      };
    },

    'conference.participants'() {
      return state.conference ? state.conference.getParticipants().map(participantSnapshot) : [];
    },

    // The lib returns a map keyed by participant id; the SDK models it as a list so the
    // order survives JSON and a report can be sorted without rebuilding keys.
    'conference.speakerStats'() {
      const conference = requireConference();
      if (typeof conference.getSpeakerStats !== 'function') {
        return [];
      }
      const stats = conference.getSpeakerStats() || {};
      return Object.keys(stats).map(userId => {
        const entry = stats[userId];
        if (!entry) {
          return null;
        }
        const call = (name, fallback) => (typeof entry[name] === 'function' ? entry[name]() : fallback);
        const landmarks = call('getFaceLandmarks', []) || [];
        return {
          participantId: call('getUserId', userId),
          displayName: call('getDisplayName', ''),
          isLocal: !!call('isLocalStats', false),
          isDominantSpeaker: !!call('isDominantSpeaker', false),
          // Milliseconds in the lib; the Swift model converts to seconds.
          totalDominantSpeakerTime: Number(call('getTotalDominantSpeakerTime', 0)) || 0,
          hasLeft: !!call('hasLeft', false),
          faceLandmarks: landmarks.map(landmark => ({
            duration: Number(landmark && landmark.duration) || 0,
            faceExpression: (landmark && landmark.faceExpression) || ''
          }))
        };
      }).filter(Boolean);
    },

    /**
     * Raw RTCStatistics records from the active peer connection. TraceablePeerConnection
     * forwards getStats() to the shim, so the records are the ones the native backend
     * produced; the Swift layer keeps them as JSON instead of re-modelling each counter.
     */
    async 'conference.stats'() {
      const conference = state.conference;
      if (!conference) {
        return { records: [], connectionState: null };
      }
      const peerConnection = conference.getActivePeerConnection();
      if (!peerConnection || typeof peerConnection.getStats !== 'function') {
        return { records: [], connectionState: conference.getConnectionState() || null };
      }
      const records = [];
      (await peerConnection.getStats()).forEach(record => records.push(plain(record)));
      return { records, connectionState: conference.getConnectionState() || null };
    },

    // The lib's enumerateDevices is callback-style, not promise-style.
    'media.enumerateDevices'() {
      return new Promise((resolve, reject) => {
        try {
          lib().mediaDevices.enumerateDevices(devices => resolve(plain(devices)));
        } catch (error) {
          reject(error);
        }
      });
    },

    // `isDeviceListAvailable` was dropped from the lib; the capability it described is whether
    // the device list can be enumerated at all.
    'media.isDeviceListAvailable'() {
      return typeof lib().mediaDevices.enumerateDevices === 'function';
    },

    'xmpp.sendCommand'(args) {
      const room = state.conference && state.conference.room;
      const connection = room && room.connection;
      if (!connection || typeof connection.send !== 'function' || !args.raw) {
        unimplemented('raw XMPP command');
      }
      // Strophe sends DOM nodes, so the stanza arrives as XML text and is parsed through the
      // DOM shim; case is preserved because it goes down the createElementNS path.
      connection.send(new DOMParser().parseFromString(args.raw, 'text/xml').documentElement);
      return true;
    }
  };

  global.__sdkInvoke = function (envelope) {
    const request = typeof envelope === 'string' ? JSON.parse(envelope) : envelope;
    const handler = methods[request.method];
    if (!handler) {
      return Promise.reject(new Error('unimplemented SDK method: ' + request.method));
    }
    return Promise.resolve().then(() => handler(request.args || {}));
  };

  global.__sdkMethods = () => Object.keys(methods);
})(globalThis);
