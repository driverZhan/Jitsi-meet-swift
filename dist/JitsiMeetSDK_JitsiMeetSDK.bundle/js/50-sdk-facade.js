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
    // mediaType -> enabled, mirrored from AV_MODERATION_CHANGED for `conference.state`.
    avModeration: {},
    logLevel: 'info',
    localTracks: new Map(),
    attached: new Map(),
    // mode -> JibriSession, so stopRecording() can name the session the lib insists on.
    recordings: new Map()
  };

  // Every field above belongs to the conference that is about to be created; a rejoin or a
  // new room must not inherit lobby users or properties from the previous one.
  function resetConferenceState() {
    state.locked = false;
    state.localParticipantProperties = {};
    state.conferenceProperties = {};
    state.lobbyUsers.clear();
    state.avModeration = {};
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
      tracks: (call('getTracks', []) || []).map(trackSnapshot)
    };
  }

  function requireConference() {
    if (!state.conference) {
      throw new Error('no active conference');
    }
    return state.conference;
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

    on('CONNECTION_ESTABLISHED', () => emit('connectionStatus', { status: 'connected' }));
    on('CONNECTION_DISCONNECTED', () => emit('connectionStatus', { status: 'disconnected' }));
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
      emit('conferenceJoined', { id });
    });
    on('CONFERENCE_LEFT', id => {
      state.conference = null;
      state.preparedName = null;
      emit('conferenceLeft', { id });
    });
    on('CONFERENCE_FAILED', (error, ...args) => emit('conferenceFailed', {
      error: (error && (error.name || String(error))) || 'unknown',
      details: plain(args)
    }));
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
    });
    on('TRACK_AUDIO_LEVEL_CHANGED', (id, level) => emit('audioLevel', { id, level }));
    on('TRACK_UNMUTE_REJECTED', track => emit('trackUnmuteRejected', trackSnapshot(track)));
    on('NO_AUDIO_INPUT', hasInput => emit('noAudioInput', { hasInput }));
    on('AUDIO_INPUT_STATE_CHANGE', state => emit('audioInputState', { state: String(state) }));
    on('TALK_WHILE_MUTED', () => emit('talkWhileMuted', {}));
    on('NOISY_MIC', () => emit('noisyMic', {}));

    on('MESSAGE_RECEIVED', (from, text, isPrivate, stamps) =>
      emit('chatMessage', { from, text, isPrivate: !!isPrivate, stamps: plain(stamps) }));
    on('PRIVATE_MESSAGE_RECEIVED', (from, to, text, stamps) =>
      emit('chatMessage', { from, text, isPrivate: true, stamps: plain(stamps) }));
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
    on('REACTION_RECEIVED', () => emit('reaction', {}));

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
    on('KICKED', () => emit('kicked', {}));
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
    on('BREAKOUT_ROOMS_UPDATED', rooms => emit('breakoutRoomsUpdated', plain(rooms)));
    on('BREAKOUT_ROOMS_MOVE_TO_ROOM', room => emit('breakoutRoomsMoveToRoom', { room }));
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

    // Connection quality and e2e ping are separate listenables on the lib.
    try {
      const qualityEvents = lib().events.connectionQuality;
      conference.on(qualityEvents.LOCAL_STATS_UPDATED, stats => emit('localStats', plain(stats)));
      conference.on(qualityEvents.REMOTE_STATS_UPDATED, (id, stats) => emit('remoteStats', { id, stats: plain(stats) }));
    } catch (error) {
      console.warn('connectionQuality events not attached', error);
    }
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
      // `join()` only starts the MUC join. A reconnect that returned here would be marked
      // successful even when the join later failed, and no further attempt would run.
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
        const onJoined = id => finish(resolve, { name: args.name, joined: true, id });
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
    },

    'conference.leave'() {
      if (state.conference) {
        state.conference.leave();
      }
      state.preparedName = null;
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
      return requireConference()
        .joinLobby(args.displayName || '', args.email || '')
        .then(() => true);
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
        participants: conference.getParticipants().map(participantSnapshot)
      };
    },

    'conference.participants'() {
      return state.conference ? state.conference.getParticipants().map(participantSnapshot) : [];
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
