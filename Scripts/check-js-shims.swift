/*
 * Loads every shim script into a real JavaScriptCore context and asserts the browser
 * surface lib-jitsi-meet depends on exists. Run with:
 *
 *   swift Scripts/check-js-shims.swift
 *
 * This is a JS-layer check only: the Swift build validates the same contract at compile
 * time, and this catches runtime errors (bad regex, missing global, throw at load).
 */
import Foundation
import JavaScriptCore

let jsFolder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/JitsiJSRuntime/Resources/js")

guard let context = JSContext() else {
    print("FAIL could not create a JSContext")
    exit(1)
}

var loadErrors: [String] = []
context.exceptionHandler = { _, exception in
    guard let exception else { return }
    loadErrors.append(exception.toString() ?? "unknown JS exception")
}

// Host stand-ins for the two functions JSCEngineHost bridges. Every answer uses the exact
// JSON shape the Swift modules return, so the shims exercise their real code paths.
context.evaluateScript("""
(function () {
  'use strict';
  const calls = [];
  globalThis.__nativeCalls = calls;
  globalThis.__nativeReceive = function (json) { calls.push(JSON.parse(json)); };
  globalThis.__nativeSyncReceive = function (json) {
    const request = JSON.parse(json);
    calls.push(request);
    switch (request.method) {
      case 'storage.get': return JSON.stringify({ value: null });
      case 'crypto.randomBytes': {
        const bytes = [];
        for (let i = 0; i < (request.args.length || 0); i += 1) bytes.push(i % 256);
        return JSON.stringify({ bytes });
      }
      case 'crypto.randomUUID': return JSON.stringify({ uuid: '00000000-0000-0000-0000-000000000000' });
      case 'env.describe':
        return JSON.stringify({
          userAgent: 'Mozilla/5.0 (iPhone) like Mac OS X AppleWebKit/605.1.15 Mobile/15E148 JitsiNative/1.0',
          platform: 'iOS', hostname: 'meet.jitsi', origin: 'https://meet.jitsi',
          language: 'en', screenWidth: 390, screenHeight: 844, scale: 3, cpuCount: 6,
          online: true, visible: true, mediaBackendReady: false, reactNativeVersion: '0.77.0'
        });
      case 'media.canPlayType': return JSON.stringify({ proficient: true });
      case 'pc.create': return JSON.stringify({ pcId: 'pc-1' });
      case 'pc.addTrack': return JSON.stringify({ senderId: 'sender-1' });
      case 'ws.open': return JSON.stringify({ id: 'ws-1' });
      case 'http.send': return JSON.stringify('http-1');
      default: return JSON.stringify({});
    }
  };
})();
""")

let scripts = ((try? FileManager.default.contentsOfDirectory(atPath: jsFolder.path)) ?? [])
    .filter { $0.hasSuffix(".js") }
    .sorted()
guard !scripts.isEmpty else {
    print("FAIL no shim scripts in \(jsFolder.path)")
    exit(1)
}

for name in scripts {
    let url = jsFolder.appendingPathComponent(name)
    guard let source = try? String(contentsOf: url, encoding: .utf8) else {
        print("FAIL could not read \(name)")
        exit(1)
    }
    let before = loadErrors.count
    context.evaluateScript(source, withSourceURL: url)
    if loadErrors.count > before {
        print("FAIL \(name): \(loadErrors[before])")
    } else {
        print("ok   \(name)")
    }
}

// Each entry is (label, JS expression that must be truthy).
let assertions: [(String, String)] = [
    ("Swift entry point", "typeof __sdkInvoke === 'function'"),
    ("native receive", "typeof __nativeReceive === 'function'"),
    ("window === global", "window.self === window"),
    ("Document nodes keep XML case", "document.createElement('body').tagName === 'body'"),
    ("NamedNodeMap", "new DOMParser().parseFromString('<x a=\\'1\\'/>', 'text/xml').documentElement.attributes.getNamedItem('a').value === '1'"),
    ("Text nodeValue", "new DOMParser().parseFromString('<x>hi</x>', 'text/xml').documentElement.firstChild.nodeValue === 'hi'"),
    ("namespace lookup", "new DOMParser().parseFromString('<x xmlns=\\'urn:x\\'><feature/></x>', 'text/xml').documentElement.getElementsByTagNameNS('urn:x', 'feature').length === 1"),
    ("namespaced attribute selector", "new DOMParser().parseFromString('<presence><x xmlns=\\'urn:muc\\'><status code=\\'201\\'/></x></presence>', 'text/xml').documentElement.querySelector(':scope>x[*|xmlns=\\'urn:muc\\']>status[code=\\'201\\']') !== null"),
    ("DOMParser XML", "new DOMParser().parseFromString('<x a=\\'1\\'><y/></x>', 'text/xml').documentElement.getAttribute('a') === '1'"),
    ("XMLSerializer round-trip", "new XMLSerializer().serializeToString(new DOMParser().parseFromString('<a b=\\'1\\'></a>', 'text/xml').documentElement).indexOf('<a') === 0"),
    ("Strophe :scope query", "document.querySelectorAll(':scope>query>feature').length >= 0"),
    ("XML keeps tag case", "new DOMParser().parseFromString('<query><feature xmlns=\\'urn:xmpp:disc\\'/></query>', 'text/xml').documentElement.firstChild.namespaceURI === 'urn:xmpp:disc'"),
    ("WebSocket", "typeof WebSocket === 'function'"),
    ("XMLHttpRequest", "typeof XMLHttpRequest === 'function'"),
    ("fetch", "typeof fetch === 'function'"),
    ("RTCPeerConnection", "typeof RTCPeerConnection === 'function'"),
    ("RTCRtpTransceiver codec preferences", "typeof RTCRtpTransceiver === 'function' && 'setCodecPreferences' in RTCRtpTransceiver.prototype"),
    ("getUserMedia", "typeof navigator.mediaDevices.getUserMedia === 'function'"),
    ("MediaStream(trackArray)", "(function () { const t = new MediaStreamTrack({ id: 't1', kind: 'video', settings: { facingMode: 'user', width: 1280 } }); const s = new MediaStream([t]); return s.getVideoTracks()[0] === t && t.getSettings().facingMode === 'user' && t.getSettings().width === 1280; })()"),
    ("navigator identity", "navigator.product === 'ReactNative' && /like Mac OS X/.test(navigator.userAgent)"),
    ("lib-jitsi-meet detects React Native", "JitsiMeetJS.util.browser.isReactNative() === true && JitsiMeetJS.util.browser.usesSdpMungingForSimulcast() === true"),
    ("localStorage", "localStorage.setItem('k', 'v') || localStorage.getItem('k') === null"),
    ("crypto.getRandomValues", "(function () { const a = new Uint8Array(4); crypto.getRandomValues(a); return a.length === 4; })()"),
    ("setTimeout wired to native", "(function () { setTimeout(function () {}, 10); return __nativeCalls.some(function (c) { return c.method === 'timer.set'; }); })()"),
    ("signaling tracing off by default", "__jitsiDebug === false"),
    ("debug mode logs BOSH frames", "(function () { globalThis.__jitsiDebug = true; const before = __nativeCalls.length; const request = new XMLHttpRequest(); request.open('POST', 'https://example.test/http-bind'); request.send('<body>ping</body>'); const logged = __nativeCalls.slice(before).some(function (c) { return c.method === 'log.write' && String(c.args.message).indexOf('[debug][http] send POST') === 0; }); globalThis.__jitsiDebug = false; return logged; })()"),
    ("EventSource-free globals", "typeof Blob === 'function' && typeof URL.createObjectURL === 'function'"),
    ("remote mute semantics", "__sdkMethods().indexOf('conference.setRemoteAudioSubscription') >= 0 && __sdkMethods().indexOf('conference.muteRemote') >= 0"),
    ("lobby methods", "__sdkMethods().indexOf('conference.enableLobby') >= 0 && __sdkMethods().indexOf('conference.joinLobby') >= 0"),
    ("token refresh facade", "__sdkMethods().indexOf('connection.refreshToken') >= 0"),
    ("polls facade", "__sdkMethods().indexOf('conference.createPoll') >= 0 && __sdkMethods().indexOf('conference.answerPoll') >= 0"),
    ("structured message facade", "__sdkMethods().indexOf('conference.sendJSONMessage') >= 0"),
    ("generic signaling facade", "(function () { const names = ['sendCommand', 'sendCommandOnce', 'removeCommand', 'addCommandListener', 'removeCommandListener', 'sendEndpointMessage', 'sendReaction']; return names.every(function (name) { return __sdkMethods().indexOf('conference.' + name) >= 0; }); })()"),
    ("conference control facade", "(function () { const names = ['end', 'lock', 'unlock', 'grantOwner', 'revokeOwner', 'setSilent', 'setSubject', 'setStartMutedPolicy']; return names.every(function (name) { return __sdkMethods().indexOf('conference.' + name) >= 0; }); })()"),
    ("local participant property facade", "(function () { const names = ['setLocalParticipantProperty', 'removeLocalParticipantProperty', 'localParticipantProperty']; return names.every(function (name) { return __sdkMethods().indexOf('conference.' + name) >= 0; }); })()"),
    ("lobby moderation facade", "(function () { const names = ['approveLobbyUser', 'denyLobbyUser', 'sendLobbyMessage', 'myLobbyUserID']; return names.every(function (name) { return __sdkMethods().indexOf('conference.' + name) >= 0; }); })()"),
    ("AV moderation facade", "(function () { const names = ['isAVModerationSupported', 'enableAVModeration', 'disableAVModeration', 'approveAVModeration', 'rejectAVModeration']; return names.every(function (name) { return __sdkMethods().indexOf('conference.' + name) >= 0; }); })()"),
    ("runtime media constraints", "(function () { const t = new MediaStreamTrack({ id: 't2', kind: 'video' }); const before = __nativeCalls.length; t.applyConstraints({ width: { ideal: 640 } }); t.getCapabilities(); const calls = __nativeCalls.slice(before); return calls.some(function (c) { return c.method === 'media.applyConstraints' && c.args.trackId === 't2' && c.args.constraints.width.ideal === 640; }) && calls.some(function (c) { return c.method === 'media.trackCapabilities' && c.args.trackId === 't2'; }); })()"),
    ("local raise hand facade", "__sdkMethods().indexOf('conference.raiseHand') >= 0"),
    ("prepare-before-join facade", "__sdkMethods().indexOf('conference.prepare') >= 0 && __sdkMethods().indexOf('conference.join') >= 0"),
    ("remote m-lines expose a sender", "(function () { const pc = new RTCPeerConnection({ iceServers: [] }); pc.__syncTransceiversFromSdp('v=0\\r\\nm=audio 9 UDP/TLS/RTP/SAVPF 111\\r\\na=mid:0\\r\\na=recvonly\\r\\n'); const transceiver = pc.getTransceivers()[0]; return !!transceiver && !!transceiver.sender && transceiver.sender.track === null; })()"),
    ("replaceTrack reaches native with the sender id", "(function () { const pc = new RTCPeerConnection({ iceServers: [] }); const first = new MediaStreamTrack({ id: 'a1', kind: 'audio' }); const sender = pc.addTrack(first, new MediaStream({ id: 's1' })); const second = new MediaStreamTrack({ id: 'a2', kind: 'audio' }); sender.replaceTrack(second); const call = __nativeCalls.filter(function (c) { return c.method === 'pc.replaceTrack'; }).pop(); return !!call && call.args.senderId === 'sender-1' && call.args.oldTrackId === 'a1' && call.args.trackId === 'a2' && call.args.kind === 'audio'; })()"),
    ("dropping a stream frees the native peers", "(function () { globalThis.__closeAllPeerConnections(); const a = new RTCPeerConnection({ iceServers: [] }); const b = new RTCPeerConnection({ iceServers: [] }); const before = __nativeCalls.filter(function (c) { return c.method === 'pc.close'; }).length; globalThis.__closeAllPeerConnections(); const closed = __nativeCalls.filter(function (c) { return c.method === 'pc.close'; }).length - before; return closed === 2 && a.signalingState === 'closed' && b.signalingState === 'closed'; })()"),
    ("identity presence is staged before join", "(function () { const connection = new JitsiMeetJS.JitsiConnection('app', 'key', { serviceUrl: 'wss://meet.jitsi/xmpp-websocket', hosts: { domain: 'meet.jitsi', muc: 'muc.meet.jitsi' } }); const conference = connection.initJitsiConference('uinfo', {}); conference.setDisplayName('Ada'); conference.sendCommand('avatar-url', { value: 'https://example.test/a.png' }); conference.sendCommand('email', { value: 'ada@example.test' }); conference.setLocalParticipantProperty('phone', '123'); const nodes = conference.room.presMap.nodes; const has = function (name, value) { return nodes.some(function (node) { return node.tagName === name && node.value === value; }); }; return has('nick', 'Ada') && has('avatar-url', 'https://example.test/a.png') && has('email', 'ada@example.test') && has('jitsi_participant_phone', '123'); })()"),
    ("breakout room facade", "(function () { const names = ['breakoutRoomsState', 'createBreakoutRoom', 'renameBreakoutRoom', 'removeBreakoutRoom', 'sendParticipantToBreakoutRoom', 'switch']; return names.every(function (name) { return __sdkMethods().indexOf('conference.' + name) >= 0; }); })()")
]

var failures: [String] = []
for (label, expression) in assertions {
    let value = context.evaluateScript("(function () { 'use strict'; return (\(expression)); })()")
    if value?.toBool() == true {
        print("ok   \(label)")
    } else {
        failures.append(label)
        print("FAIL \(label) -> \(value?.toString() ?? "nil")")
    }
}

// Contract check: every method JSMeetingEngine invokes must exist in the facade table,
// because a name missing on the JS side is a runtime rejection rather than a compile error.
let engineSource = jsFolder
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("JSMeetingEngine.swift")
let facadeMethods = Set((context.evaluateScript("__sdkMethods()")?.toArray() ?? []) as? [String] ?? [])
if let source = try? String(contentsOf: engineSource, encoding: .utf8) {
    let pattern = try! NSRegularExpression(pattern: "invoke\\(\"([a-z]+\\.[a-zA-Z0-9]+)\"")
    let called = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
        .compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[range])
        }
    let missing = Set(called).subtracting(facadeMethods).sorted()
    if missing.isEmpty {
        print("ok   facade covers \(Set(called).count) Swift methods (\(facadeMethods.count) available)")
    } else {
        failures.append("facade methods missing: \(missing)")
        print("FAIL Swift calls methods the facade does not implement: \(missing)")
    }
} else {
    print("FAIL could not read \(engineSource.path)")
}

// With the real bundle in place, the facade's calls into lib-jitsi-meet become checkable too:
// every member it dereferences has to exist on the objects the lib actually returns. This is
// how a renamed or callback-shaped API (setSenderVideoConstraint, mediaDevices.enumerateDevices)
// gets caught here instead of at join time on a device.
let libSurface = context.evaluateScript("""
(function () {
  'use strict';
  const L = globalThis.JitsiMeetJS;
  if (!L) {
    return ['JitsiMeetJS global missing: run Scripts/build-js-bundle.sh'];
  }
  const missing = [];
  const need = function (label, holder, name) {
    if (!holder || holder[name] === undefined) { missing.push(label); }
  };
  ['JitsiConnection', 'createLocalTracks', 'init', 'setLogLevel', 'logLevels', 'mediaDevices', 'events']
    .forEach(k => need('JitsiMeetJS.' + k, L, k));
  need('JitsiMeetJS.logLevels.INFO', L.logLevels, 'INFO');
  ['conference', 'connection', 'mediaDevices', 'connectionQuality']
    .forEach(k => need('events.' + k, L.events, k));
  const connection = new L.JitsiConnection('app', 'key', {
    serviceUrl: 'wss://meet.jitsi/xmpp-websocket', hosts: { domain: 'meet.jitsi', muc: 'muc.meet.jitsi' }
  });
  ['connect', 'disconnect', 'initJitsiConference', 'addEventListener', 'refreshToken']
    .forEach(k => need('connection.' + k, connection, k));
  const conference = connection.initJitsiConference('shim-check', {});
  ['join', 'leave', 'addTrack', 'removeTrack', 'sendMessage', 'setDisplayName', 'sendCommand',
   'sendCommandOnce', 'removeCommand', 'addCommandListener', 'removeCommandListener',
   'sendEndpointMessage', 'sendReaction',
   'setLocalParticipantProperty', 'removeLocalParticipantProperty', 'setSenderVideoConstraint',
   'setReceiverVideoConstraint', 'setLastN', 'kickParticipant', 'muteParticipant', 'muteRemoteAudio',
   'startRecording', 'stopRecording', 'isJoined', 'isE2EEEnabled', 'getParticipants',
   'getActivePeerConnection', 'getConnectionState', 'on', 'getParticipantById', 'isModerator',
   'isLobbySupported', 'isMembersOnly', 'isVisitorsSupported', 'enableLobby', 'disableLobby', 'joinLobby',
   'isEndConferenceSupported', 'end', 'lock', 'unlock', 'grantOwner', 'revokeOwner', 'setIsSilent',
   'setSubject', 'setStartMutedPolicy', 'getStartMutedPolicy', 'myUserId',
   'getLocalParticipantProperty', 'getProperty', 'myLobbyUserId', 'lobbyApproveAccess',
   'lobbyDenyAccess', 'sendLobbyMessage', 'addLobbyMessageListener',
   'isAVModerationSupported', 'enableAVModeration', 'disableAVModeration',
   'avModerationApprove', 'avModerationReject', 'getBreakoutRooms']
    .forEach(k => need('conference.' + k, conference, k));
  const breakout = typeof conference.getBreakoutRooms === 'function'
    ? conference.getBreakoutRooms()
    : null;
  ['createBreakoutRoom', 'renameBreakoutRoom', 'removeBreakoutRoom', 'sendParticipantToRoom',
   'isSupported', 'isFeatureSupported', 'isBreakoutRoom', 'getMainRoomJid']
    .forEach(k => need('breakoutRooms.' + k, breakout, k));
  need('events.connection.PROPERTIES_UPDATED', L.events.connection, 'PROPERTIES_UPDATED');
  ['enumerateDevices', 'addEventListener']
    .forEach(k => need('mediaDevices.' + k, L.mediaDevices, k));
  return missing;
})()
""")
let surfaceGaps = (libSurface?.toArray() ?? []) as? [String] ?? []
if surfaceGaps.isEmpty {
    print("ok   lib API surface matches the facade")
} else {
    failures.append("lib API surface: \(surfaceGaps)")
    print("FAIL the facade calls lib members that do not exist: \(surfaceGaps)")
}

// And the event enum names: `on('NAME')` in the facade must exist in the lib's enums, or the
// listener is silently skipped by the facade's own guard.
let enumList = (context.evaluateScript("""
(function () {
  const L = globalThis.JitsiMeetJS;
  if (!L) { return []; }
  const groups = ['conference', 'connection', 'mediaDevices', 'connectionQuality'];
  const names = [];
  groups.forEach(function (group) {
    Object.keys((L.events && L.events[group]) || {}).forEach(function (name) { names.push(name); });
  });
  return names;
})()
""")?.toArray() ?? []) as? [String] ?? []
let enumNames = Set(enumList)
let facadeSource = jsFolder.appendingPathComponent("50-sdk-facade.js")
if let facadeText = try? String(contentsOf: facadeSource, encoding: .utf8), !enumNames.isEmpty {
    let listenerPattern = try! NSRegularExpression(pattern: "on\\('([A-Z_0-9]+)'")
    let referenced = Set(listenerPattern.matches(in: facadeText, range: NSRange(facadeText.startIndex..., in: facadeText))
        .compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: facadeText) else { return nil }
            return String(facadeText[range])
        })
    let unknown = referenced.subtracting(enumNames).sorted()
    if unknown.isEmpty {
        print("ok   all \(referenced.count) lib event names the facade listens for exist")
    } else {
        failures.append("unknown lib events: \(unknown)")
        print("FAIL the facade listens for events this lib build does not define: \(unknown)")
    }
} else if enumNames.isEmpty {
    failures.append("lib event enums unreadable")
    print("FAIL lib event enums unreadable (bundle is the placeholder?)")
}

// Same idea for the event channel: a reducer case whose name the facade never emits is dead
// code, and an emit whose name no case handles silently degrades to MeetingEvent.raw.
if let swiftSource = try? String(contentsOf: engineSource, encoding: .utf8),
   let facadeText = try? String(contentsOf: facadeSource, encoding: .utf8) {
    let casePattern = try! NSRegularExpression(pattern: "case (\"[a-zA-Z]+\"(?:, *\"[a-zA-Z]+\")*)\\s*:")
    let namePattern = try! NSRegularExpression(pattern: "\"([a-zA-Z]+)\"")
    let handled = casePattern.matches(in: swiftSource, range: NSRange(swiftSource.startIndex..., in: swiftSource))
        .flatMap { match -> [String] in
            guard let clause = Range(match.range(at: 1), in: swiftSource) else { return [] }
            let text = String(swiftSource[clause])
            return namePattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
        }
    let emittedPattern = try! NSRegularExpression(pattern: "emit\\('([a-zA-Z]+)'")
    let emitted = Set(emittedPattern.matches(in: facadeText, range: NSRange(facadeText.startIndex..., in: facadeText))
        .compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: facadeText) else { return nil }
            return String(facadeText[range])
        })
    let dead = Set(handled).subtracting(emitted).sorted()
    let unmodelled = emitted.subtracting(Set(handled)).sorted()
    if dead.isEmpty {
        print("ok   every reducer case is emitted (\(Set(handled).count) modelled, \(emitted.count) emitted)")
    } else {
        failures.append("dead reducer cases: \(dead)")
        print("FAIL reducer cases the facade never emits: \(dead)")
    }
    // Not a failure: MeetingEvent.raw is the escape hatch, but the number is worth seeing.
    print("     \(unmodelled.count) emits fall through to MeetingEvent.raw: \(unmodelled.prefix(8).joined(separator: ", "))")
}

// Async contract: Swift drives JS through `__sdkSettle`, which must attach its callbacks in
// the same execution that creates the promise. The synchronous assertions above cannot see a
// bridge that settles never, so pump the run loop and require a real answer.
context.evaluateScript("""
globalThis.__settled = 'pending';
__sdkSettle('lib.init', '{"logLevel":"info","options":{}}',
  function (value) { globalThis.__settled = 'ok:' + JSON.stringify(value); },
  function (message) { globalThis.__settled = 'err:' + message; });
__sdkSettle('connection.nope', '{}',
  function () { globalThis.__rejected = 'resolved'; },
  function (message) { globalThis.__rejected = 'rejected:' + message; });
""")
RunLoop.current.run(until: Date().addingTimeInterval(2))
let settled = context.evaluateScript("__settled")?.toString() ?? "nil"
let rejected = context.evaluateScript("__rejected")?.toString() ?? "nil"
if settled.hasPrefix("ok:") {
    print("ok   lib.init settles through __sdkSettle (\(settled))")
} else {
    failures.append("lib.init settles through __sdkSettle")
    print("FAIL lib.init settles through __sdkSettle -> \(settled)")
}
if rejected.hasPrefix("rejected:") {
    print("ok   an unknown method rejects (\(rejected))")
} else {
    failures.append("unknown method rejects")
    print("FAIL unknown method rejects -> \(rejected)")
}

// End-to-end through the facade: drive connection.connect with a fake JitsiConnection, then
// conference.join with a userInfo payload and inspect what the facade staged on the room.
// This catches a wrong command name or an identity field the join path forgets to apply,
// which the table-driven checks above cannot see.
context.evaluateScript("""
globalThis.__userInfoCalls = 'pending';
(function () {
  const L = globalThis.JitsiMeetJS;
  const original = L.JitsiConnection;
  const calls = [];
  const fakeConference = {
    on: function (event, handler) { fakeConference.handlers[event] = handler; },
    handlers: {},
    messages: [],
    join: function () {},
    commandListeners: {},
    addCommandListener: function (command, handler) {
      fakeConference.commandListeners[command] = handler;
    },
    setDisplayName: function (name) { calls.push(['nick', name]); },
    sendCommand: function (name, values) { calls.push([name, values.value]); },
    setLocalParticipantProperty: function (name, value) {
      calls.push(['jitsi_participant_' + name, value]);
    },
    sendMessage: function (message, to) { fakeConference.messages.push([message, to]); }
  };
  function FakeConnection() {
    this.jid = 'fake@example.test';
    this.listeners = {};
    this.initJitsiConference = function () { return fakeConference; };
    this.addEventListener = function (event, handler) {
      (this.listeners[event] || (this.listeners[event] = [])).push(handler);
    };
    this.connect = function () {
      const Events = L.events.connection;
      (this.listeners[Events.CONNECTION_ESTABLISHED] || []).forEach(fn => fn());
    };
  }
  L.JitsiConnection = FakeConnection;
  const restore = () => { L.JitsiConnection = original; };
  try {
    __sdkSettle('connection.connect', JSON.stringify({
      serviceUrl: 'https://example.test/http-bind',
      hosts: { domain: 'd', muc: 'm' }
    }), function () {
      __sdkSettle('conference.join', JSON.stringify({
        name: 'uinfo', options: {}, configOverwrite: {},
        userInfo: {
          displayName: 'Ada',
          email: 'ada@example.test',
          avatarURL: 'https://example.test/a.png',
          extras: { phone: '123' }
        }
      }), function () {
        globalThis.__userInfoCalls = JSON.stringify(calls);
        // Inbound identity: the facade must subscribe to the two presence commands and
        // normalize (node, participantId) into the event channel with the raw value.
        const commands = Object.keys(fakeConference.commandListeners).sort().join(',');
        if (fakeConference.commandListeners['avatar-url']) {
          fakeConference.commandListeners['avatar-url'](
            { tagName: 'avatar-url', value: 'https://example.test/b.png' }, 'remote-1');
        }
        if (fakeConference.commandListeners['email']) {
          fakeConference.commandListeners['email']({ tagName: 'email', value: 'b@example.test' }, 'remote-1');
        }
        const inbound = globalThis.__nativeCalls
          .filter(function (call) {
            return call.method === 'sdk.event' && call.args && String(call.args.name).indexOf('participant') === 0;
          })
          .map(function (call) {
            return [call.args.name, call.args.payload.id, call.args.payload.value];
          });
        globalThis.__identitySurface = JSON.stringify({ commands: commands, events: inbound });
        // Structured messages must reach the wire as an object and log both directions, so a
        // two-device run can verify payloads without turning on signaling tracing.
        globalThis.__jsonMessageLog = 'pending';
        try {
          const sentBefore = globalThis.__nativeCalls.length;
          __sdkSettle('conference.sendJSONMessage', JSON.stringify({
            payload: { kind: 'probe', n: 1 },
            to: 'remote-1'
          }), function () {
            const sent = globalThis.__nativeCalls.slice(sentBefore).some(function (call) {
              return call.method === 'log.write'
                && String(call.args.message).indexOf('[sdk][json-message] send to remote-1: {"kind":"probe","n":1}') === 0;
            });
            const delivered = fakeConference.messages.length === 1
              && fakeConference.messages[0][0].kind === 'probe'
              && fakeConference.messages[0][1] === 'remote-1';
            const receivedBefore = globalThis.__nativeCalls.length;
            const handler = fakeConference.handlers[globalThis.JitsiMeetJS.events.conference.ENDPOINT_MESSAGE_RECEIVED];
            if (handler) {
              handler({ getId: function () { return 'remote-1'; } }, { kind: 'reply' });
            }
            const received = globalThis.__nativeCalls.slice(receivedBefore).some(function (call) {
              return call.method === 'log.write'
                && String(call.args.message).indexOf('[sdk][json-message] recv from remote-1: {"kind":"reply"}') === 0;
            });
            globalThis.__jsonMessageLog = JSON.stringify({ sent: sent, delivered: delivered, received: received });
            restore();
          }, function (message) {
            globalThis.__jsonMessageLog = 'rejected: ' + message;
            restore();
          });
        } catch (error) {
          globalThis.__jsonMessageLog = 'threw: ' + error.message;
          restore();
        }
      }, function (message) {
        globalThis.__userInfoCalls = 'join rejected: ' + message;
        restore();
      });
    }, function (message) {
      globalThis.__userInfoCalls = 'connect rejected: ' + message;
      restore();
    });
  } catch (error) {
    globalThis.__userInfoCalls = 'threw: ' + error.message;
    restore();
  }
})();
""")
RunLoop.current.run(until: Date().addingTimeInterval(2))
let userInfoCalls = context.evaluateScript("__userInfoCalls")?.toString() ?? "nil"
let expectedUserInfo = """
[["nick","Ada"],["avatar-url","https://example.test/a.png"],["email","ada@example.test"],["jitsi_participant_phone","123"]]
"""
.trimmingCharacters(in: .whitespacesAndNewlines)
if userInfoCalls == expectedUserInfo {
    print("ok   join stages display name, avatar, email and extras")
} else {
    failures.append("user info staging")
    print("FAIL user info staging -> \(userInfoCalls)")
}

let jsonMessageLog = context.evaluateScript("__jsonMessageLog")?.toString() ?? "nil"
if jsonMessageLog == "{\"sent\":true,\"delivered\":true,\"received\":true}" {
    print("ok   structured messages log both directions")
} else {
    failures.append("structured message logging")
    print("FAIL structured message logging -> \(jsonMessageLog)")
}

// Generic presence commands, bridge data-channel messages and reactions are three distinct
// lib paths; wiring one to another would still "work" in the facade but deliver nothing.
// Drive each through the facade and inspect the lib-side calls and the events it emits.
context.evaluateScript("""
globalThis.__signalingSurface = 'pending';
(function () {
  const L = globalThis.JitsiMeetJS;
  const original = L.JitsiConnection;
  const calls = [];
  const listeners = {};
  const fakeConference = {
    on: function (event, handler) { listeners[event] = handler; },
    join: function () {},
    sendCommand: function (name, values) { calls.push(['sendCommand', name, values]); },
    sendCommandOnce: function (name, values) { calls.push(['sendCommandOnce', name, values]); },
    removeCommand: function (name) { calls.push(['removeCommand', name]); },
    addCommandListener: function (name, handler) {
      calls.push(['addCommandListener', name]);
      listeners['command:' + name] = handler;
    },
    removeCommandListener: function (name) { calls.push(['removeCommandListener', name]); },
    sendEndpointMessage: function (to, payload) { calls.push(['sendEndpointMessage', to, payload]); },
    sendReaction: function (reaction, messageId, receiverId) {
      calls.push(['sendReaction', reaction, messageId, receiverId]);
    }
  };
  function FakeConnection() {
    this.jid = 'fake@example.test';
    this.listeners = {};
    this.initJitsiConference = function () { return fakeConference; };
    this.addEventListener = function (event, handler) {
      (this.listeners[event] || (this.listeners[event] = [])).push(handler);
    };
    this.connect = function () {
      (this.listeners[L.events.connection.CONNECTION_ESTABLISHED] || []).forEach(fn => fn());
    };
  }
  L.JitsiConnection = FakeConnection;
  const restore = () => { L.JitsiConnection = original; };
  const call = function (method, args) {
    return new Promise(function (resolve, reject) {
      __sdkSettle(method, JSON.stringify(args), resolve, reject);
    });
  };
  const events = function (name) {
    return globalThis.__nativeCalls
      .filter(function (entry) { return entry.method === 'sdk.event' && entry.args.name === name; })
      .map(function (entry) { return entry.args.payload; });
  };
  (async function () {
    await call('connection.connect', {
      serviceUrl: 'https://example.test/http-bind',
      hosts: { domain: 'd', muc: 'm' }
    });
    await call('conference.join', { name: 'signaling', options: {} });
    await call('conference.sendCommand', { name: 'probe', values: { value: '42' } });
    await call('conference.sendCommandOnce', { name: 'once', values: { value: true } });
    await call('conference.removeCommand', { name: 'once' });
    await call('conference.addCommandListener', { name: 'probe' });
    const inbound = listeners['command:probe'];
    if (inbound) {
      inbound({ tagName: 'probe', attributes: { value: '7', xmlns: 'urn:test' } }, 'remote-2');
    }
    await call('conference.removeCommandListener', { name: 'probe' });
    await call('conference.sendEndpointMessage', { payload: { kind: 'ping' }, to: 'remote-2' });
    await call('conference.sendReaction', { reaction: '👍', messageId: 'm1', to: 'remote-2' });
    const reaction = listeners[L.events.conference.REACTION_RECEIVED];
    if (reaction) {
      reaction('remote-3', ['👍'], 'm1');
    }
    const has = function (entry) {
      return calls.some(function (callArgs) { return JSON.stringify(callArgs) === JSON.stringify(entry); });
    };
    if (!has(['sendCommand', 'probe', { value: '42' }])
        || !has(['sendCommandOnce', 'once', { value: true }])
        || !has(['removeCommand', 'once'])
        || !has(['addCommandListener', 'probe'])
        || !has(['removeCommandListener', 'probe'])
        || !has(['sendEndpointMessage', 'remote-2', { kind: 'ping' }])
        || !has(['sendReaction', '👍', 'm1', 'remote-2'])) {
      globalThis.__signalingSurface = 'lib calls: ' + JSON.stringify(calls);
      restore();
      return;
    }
    const command = events('commandReceived');
    if (command.length !== 1
        || command[0].name !== 'probe'
        || command[0].from !== 'remote-2'
        || JSON.stringify(command[0].values) !== JSON.stringify({ value: '7', xmlns: 'urn:test' })) {
      globalThis.__signalingSurface = 'command event: ' + JSON.stringify(command);
      restore();
      return;
    }
    const reactions = events('reactionReceived');
    if (reactions.length !== 1
        || reactions[0].id !== 'remote-3'
        || JSON.stringify(reactions[0].reactions) !== JSON.stringify(['👍'])
        || reactions[0].messageId !== 'm1') {
      globalThis.__signalingSurface = 'reaction event: ' + JSON.stringify(reactions);
      restore();
      return;
    }
    globalThis.__signalingSurface = 'ok';
    restore();
  })().catch(function (error) {
    globalThis.__signalingSurface = 'threw: ' + (error && error.message);
    restore();
  });
})();
""")
RunLoop.current.run(until: Date().addingTimeInterval(2))
let signalingSurface = context.evaluateScript("__signalingSurface")?.toString() ?? "nil"
if signalingSurface == "ok" {
    print("ok   presence commands, endpoint messages and reactions reach the lib")
} else {
    failures.append("signaling facade")
    print("FAIL signaling facade -> \(signalingSurface)")
}

// A replaced connection keeps delivering Strophe callbacks. Only the current one may reach
// Swift, or a late droppedError from the old socket triggers a second full rejoin; and a
// disconnect has to clear the connection so nothing can be prepared on top of it.
context.evaluateScript("""
globalThis.__connectionGeneration = 'pending';
(function () {
  const L = globalThis.JitsiMeetJS;
  const original = L.JitsiConnection;
  const connections = [];
  function FakeConnection() {
    this.jid = 'fake@example.test';
    this.listeners = {};
    this.initJitsiConference = function () {
      return { on: function () {}, join: function () {}, leave: function () {} };
    };
    this.addEventListener = function (event, handler) {
      (this.listeners[event] || (this.listeners[event] = [])).push(handler);
    };
    this.connect = function () {
      const Events = L.events.connection;
      (this.listeners[Events.CONNECTION_ESTABLISHED] || []).forEach(fn => fn());
    };
    this.disconnect = function () {};
    connections.push(this);
  }
  L.JitsiConnection = FakeConnection;
  const restore = () => { L.JitsiConnection = original; };
  const fire = function (conn, name, arg) {
    const Events = L.events.connection;
    (conn.listeners[Events[name]] || []).forEach(fn => fn(arg));
  };
  const lostCount = function () {
    return globalThis.__nativeCalls.filter(function (call) {
      return call.method === 'sdk.event' && call.args && call.args.name === 'connectionLost';
    }).length;
  };
  const dropped = { name: 'connection.droppedError' };
  const spec = JSON.stringify({ serviceUrl: 'https://example.test/http-bind', hosts: { domain: 'd', muc: 'm' } });
  __sdkSettle('connection.connect', spec, function () {
    __sdkSettle('connection.connect', spec, function () {
      fire(connections[0], 'CONNECTION_FAILED', dropped);
      const afterStale = lostCount();
      fire(connections[1], 'CONNECTION_FAILED', dropped);
      const afterCurrent = lostCount();
      __sdkSettle('connection.disconnect', '{}', function () {
        fire(connections[1], 'CONNECTION_FAILED', dropped);
        const afterDisconnect = lostCount();
        const prepare = JSON.stringify({ name: 'gen', options: {}, userInfo: { displayName: 'A' } });
        __sdkSettle('conference.prepare', prepare, function () {
          globalThis.__connectionGeneration = 'join accepted after disconnect';
          restore();
        }, function (message) {
          globalThis.__connectionGeneration = JSON.stringify({
            stale: afterStale, current: afterCurrent, disconnected: afterDisconnect, prepare: message
          });
          restore();
        });
      }, function (message) {
        globalThis.__connectionGeneration = 'disconnect rejected: ' + message;
        restore();
      });
    }, function (message) {
      globalThis.__connectionGeneration = 'second connect rejected: ' + message;
      restore();
    });
  }, function (message) {
    globalThis.__connectionGeneration = 'connect rejected: ' + message;
    restore();
  });
})();
""")
RunLoop.current.run(until: Date().addingTimeInterval(2))
let generation = context.evaluateScript("__connectionGeneration")?.toString() ?? "nil"
let expectedGeneration = """
{"stale":0,"current":1,"disconnected":1,"prepare":"not connected"}
"""
.trimmingCharacters(in: .whitespacesAndNewlines)
if generation == expectedGeneration {
    print("ok   a replaced connection cannot drive events or be reused")
} else {
    failures.append("connection generation guard")
    print("FAIL connection generation guard -> \(generation)")
}

let identitySurface = context.evaluateScript("__identitySurface")?.toString() ?? "nil"
let expectedIdentity = """
{"commands":"avatar-url,email","events":[["participantAvatarChanged","remote-1","https://example.test/b.png"],["participantEmailChanged","remote-1","b@example.test"]]}
"""
.trimmingCharacters(in: .whitespacesAndNewlines)
if identitySurface == expectedIdentity {
    print("ok   inbound avatar-url/email presence reaches the event channel")
} else {
    failures.append("inbound identity presence")
    print("FAIL inbound identity presence -> \(identitySurface)")
}

// A reconnect cannot treat `join()` as success: it returns while the MUC join is still in
// flight. With `waitForJoin` the facade must hold the call until CONFERENCE_JOINED and turn
// a failed join into a rejection, otherwise a broken rejoin would reset the retry budget.
context.evaluateScript("""
globalThis.__joinWait = 'pending';
globalThis.__joinSecond = 'not started';
(function () {
  const L = globalThis.JitsiMeetJS;
  const original = L.JitsiConnection;
  const makeConference = function () {
    const listeners = {};
    return {
      on: function (name, handler) { (listeners[name] || (listeners[name] = [])).push(handler); },
      off: function (name, handler) {
        listeners[name] = (listeners[name] || []).filter(function (fn) { return fn !== handler; });
      },
      emit: function (name, value) {
        (listeners[name] || []).slice().forEach(function (fn) { fn(value); });
      },
      join: function () {},
      leave: function () {}
    };
  };
  const first = makeConference();
  let created = 0;
  function FakeConnection() {
    this.jid = 'fake@example.test';
    this.listeners = {};
    this.initJitsiConference = function () { created += 1; return created === 1 ? first : globalThis.__joinSecondConference; };
    this.addEventListener = function (event, handler) {
      (this.listeners[event] || (this.listeners[event] = [])).push(handler);
    };
    this.connect = function () {
      const Events = L.events.connection;
      (this.listeners[Events.CONNECTION_ESTABLISHED] || []).forEach(fn => fn());
    };
  }
  globalThis.__joinFirst = first;
  globalThis.__joinSecondConference = makeConference();
  L.JitsiConnection = FakeConnection;
  globalThis.__restoreJoinWait = function () { L.JitsiConnection = original; };
  const spec = JSON.stringify({ serviceUrl: 'https://example.test/http-bind', hosts: { domain: 'd', muc: 'm' } });
  const join = JSON.stringify({ name: 'wait', options: {}, waitForJoin: true, waitTimeout: 60000 });
  __sdkSettle('connection.connect', spec, function () {
    __sdkSettle('conference.join', join, function (value) {
      globalThis.__joinWait = 'resolved:' + JSON.stringify(value);
    }, function (message) {
      globalThis.__joinWait = 'rejected:' + message;
    });
  }, function (message) {
    globalThis.__joinWait = 'connect rejected: ' + message;
  });
})();
""")
RunLoop.current.run(until: Date().addingTimeInterval(1))
let joinPending = context.evaluateScript("__joinWait")?.toString() ?? "nil"
if joinPending == "pending" {
    print("ok   waitForJoin holds until CONFERENCE_JOINED")
} else {
    failures.append("waitForJoin gating")
    print("FAIL waitForJoin gating -> \(joinPending)")
}
context.evaluateScript("""
globalThis.__joinWait = 'pending';
__joinFirst.emit(globalThis.JitsiMeetJS.events.conference.CONFERENCE_JOINED, 'wait');
""")
RunLoop.current.run(until: Date().addingTimeInterval(1))
let joinResolved = context.evaluateScript("__joinWait")?.toString() ?? "nil"
let expectedJoinResolved = "resolved:" + #"{"name":"wait","joined":true,"id":"wait"}"#
if joinResolved == expectedJoinResolved {
    print("ok   a joined conference resolves the rejoin")
} else {
    failures.append("waitForJoin resolves on joined")
    print("FAIL waitForJoin resolves on joined -> \(joinResolved)")
}
context.evaluateScript("""
globalThis.__joinSecond = 'pending';
(function () {
  const join = JSON.stringify({ name: 'wait2', options: {}, waitForJoin: true, waitTimeout: 60000 });
  __sdkSettle('conference.join', join, function (value) {
    globalThis.__joinSecond = 'resolved:' + JSON.stringify(value);
  }, function (message) {
    globalThis.__joinSecond = 'rejected:' + message;
  });
})();
""")
RunLoop.current.run(until: Date().addingTimeInterval(1))
context.evaluateScript("""
__joinSecondConference.emit(globalThis.JitsiMeetJS.events.conference.CONFERENCE_FAILED,
  { name: 'conference.passwordRequired' });
""")
RunLoop.current.run(until: Date().addingTimeInterval(1))
let joinFailed = context.evaluateScript("__joinSecond")?.toString() ?? "nil"
if joinFailed == "rejected:conference join failed: conference.passwordRequired" {
    print("ok   a failed join rejects so the retry budget is not reset")
} else {
    failures.append("waitForJoin rejects on failed")
    print("FAIL waitForJoin rejects on failed -> \(joinFailed)")
}
context.evaluateScript("__restoreJoinWait();")

// Moderator controls end-to-end: each façade method must reach the matching lib call with the
// Swift argument names translated correctly (`participantId`, `silent`, `subject`, `audio` /
// `video`), and `conference.state()` must mirror LOCK_STATE_CHANGED because the lib has no
// getter for the lock. `setSilent` is the façade label for the lib's `setIsSilent`.
context.evaluateScript("""
globalThis.__controlProbe = 'pending';
(function () {
  const L = globalThis.JitsiMeetJS;
  const original = L.JitsiConnection;
  const calls = [];
  const remote = { getId: function () { return 'remote-1'; } };
  const handlers = {};
  const fake = {
    on: function (name, handler) { handlers[name] = handler; },
    join: function () {},
    isJoined: function () { return true; },
    isAuthRequired: function () { return false; },
    isPasswordRequired: function () { return false; },
    isE2EEEnabled: function () { return false; },
    isModerator: function () { return true; },
    isLobbySupported: function () { return false; },
    isMembersOnly: function () { return false; },
    isVisitorsSupported: function () { return false; },
    isEndConferenceSupported: function () { return true; },
    myUserId: function () { return 'local-1'; },
    getParticipants: function () { return []; },
    getParticipantById: function (id) { return id === 'remote-1' ? remote : null; },
    lock: function (password) { calls.push(['lock', password]); return Promise.resolve(); },
    unlock: function () { calls.push(['unlock']); return Promise.resolve(); },
    end: function () { calls.push(['end']); },
    grantOwner: function (id) { calls.push(['grant', id]); },
    revokeOwner: function (id) { calls.push(['revoke', id]); },
    setIsSilent: function (silent) { calls.push(['silent', silent]); },
    setSubject: function (subject) { calls.push(['subject', subject]); },
    setStartMutedPolicy: function (policy) { calls.push(['policy', policy.audio, policy.video]); },
    getStartMutedPolicy: function () { return { audio: true, video: false }; }
  };
  function FakeConnection() {
    this.jid = 'fake@example.test';
    this.listeners = {};
    this.initJitsiConference = function () { return fake; };
    this.addEventListener = function (event, handler) {
      (this.listeners[event] || (this.listeners[event] = [])).push(handler);
    };
    this.connect = function () {
      const Events = L.events.connection;
      (this.listeners[Events.CONNECTION_ESTABLISHED] || []).forEach(fn => fn());
    };
  }
  L.JitsiConnection = FakeConnection;
  const restore = function () { L.JitsiConnection = original; };
  const fail = function (label) {
    return function (message) {
      globalThis.__controlProbe = label + ' rejected: ' + message;
      restore();
    };
  };
  const steps = [];

  function run() {
    const step = steps.shift();
    if (!step) {
      // `conference.state()` reads the policy back through the lib getter.
      __sdkSettle('conference.state', '{}', function (state) {
        globalThis.__controlProbe = JSON.stringify({
          calls: calls,
          locked: state.isLocked,
          endSupported: state.endConferenceSupported,
          statePolicy: state.startMutedPolicy,
          events: globalThis.__nativeCalls.filter(function (call) {
            return call.method === 'sdk.event' && call.args && call.args.name === 'lockStateChanged';
          }).length
        });
        restore();
      }, fail('state'));
      return;
    }
    step();
  }

  // Pushed in execution order: `run()` shifts from the front.
  steps.push(function () {
    // The lock mirror is event-only, so fire LOCK_STATE_CHANGED before reading state.
    const lockEvent = L.events.conference.LOCK_STATE_CHANGED;
    if (!handlers[lockEvent]) {
      globalThis.__controlProbe = 'lockStateChanged listener missing';
      restore();
      return;
    }
    handlers[lockEvent](true);
    run();
  });
  steps.push(function () {
    __sdkSettle('conference.lock', '{"password":"1234"}', function () { run(); }, fail('lock'));
  });
  steps.push(function () {
    __sdkSettle('conference.unlock', '{}', function () { run(); }, fail('unlock'));
  });
  steps.push(function () {
    __sdkSettle('conference.grantOwner', '{"participantId":"remote-1"}', function () { run(); }, fail('grantOwner'));
  });
  steps.push(function () {
    __sdkSettle('conference.revokeOwner', '{"participantId":"local-1"}', function () { run(); }, fail('revokeOwner (self)'));
  });
  steps.push(function () {
    __sdkSettle('conference.setSilent', '{"silent":true}', function () { run(); }, fail('setSilent'));
  });
  steps.push(function () {
    __sdkSettle('conference.setSubject', '{"subject":"Weekly sync"}', function () { run(); }, fail('setSubject'));
  });
  steps.push(function () {
    __sdkSettle('conference.setStartMutedPolicy', '{"audio":true,"video":false}',
      function () { run(); }, fail('setStartMutedPolicy'));
  });
  steps.push(function () {
    __sdkSettle('conference.end', '{}', function () { run(); }, fail('end'));
  });

  __sdkSettle('connection.connect', JSON.stringify({
    serviceUrl: 'https://example.test/http-bind', hosts: { domain: 'd', muc: 'm' }
  }), function () {
    __sdkSettle('conference.prepare', JSON.stringify({
      name: 'control', options: {}, configOverwrite: {}
    }), function () {
      run();
    }, fail('prepare'));
  }, fail('connect'));
})();
""")
RunLoop.current.run(until: Date().addingTimeInterval(2))
let controlProbe = context.evaluateScript("__controlProbe")?.toString() ?? "nil"
let expectedControlProbe = """
{"calls":[["lock","1234"],["unlock"],["grant","remote-1"],["revoke","local-1"],["silent",true],["subject","Weekly sync"],["policy",true,false],["end"]],"locked":true,"endSupported":true,"statePolicy":{"audio":true,"video":false},"events":1}
"""
.trimmingCharacters(in: .whitespacesAndNewlines)
if controlProbe == expectedControlProbe {
    print("ok   moderator controls reach the lib and the lock state mirrors the event")
} else {
    failures.append("conference control probe")
    print("FAIL conference control probe -> \(controlProbe)")
}

// Local properties, lobby moderation and AV moderation end-to-end. The property mirror has to
// win over the lib's string-only getter, the lobby calls map to the lib's lobby*Access names,
// and each lib event must surface as the façade event the Swift reducer expects.
context.evaluateScript("""
globalThis.__propertyProbe = 'pending';
(function () {
  const L = globalThis.JitsiMeetJS;
  const original = L.JitsiConnection;
  const calls = [];
  const handlers = {};
  const remote = { getId: function () { return 'remote-1'; } };
  const fake = {
    on: function (name, handler) { handlers[name] = handler; },
    join: function () {},
    isJoined: function () { return true; },
    isAuthRequired: function () { return false; },
    isPasswordRequired: function () { return false; },
    isE2EEEnabled: function () { return false; },
    isModerator: function () { return true; },
    isLobbySupported: function () { return true; },
    isMembersOnly: function () { return true; },
    isVisitorsSupported: function () { return true; },
    isEndConferenceSupported: function () { return false; },
    myUserId: function () { return 'local-1'; },
    getParticipants: function () { return []; },
    getParticipantById: function (id) { return id === 'remote-1' ? remote : null; },
    setLocalParticipantProperty: function (name, value) { calls.push(['set', name, value]); },
    removeLocalParticipantProperty: function (name) { calls.push(['remove', name]); },
    getLocalParticipantProperty: function (name) { return 'flattened:' + name; },
    myLobbyUserId: function () { return 'guest-1'; },
    lobbyApproveAccess: function (id) { calls.push(['approveLobby', id]); },
    lobbyDenyAccess: function (id) { calls.push(['denyLobby', id]); },
    sendLobbyMessage: function (message, id) { calls.push(['lobbyMessage', message, id]); },
    addLobbyMessageListener: function (handler) { globalThis.__lobbyListener = handler; },
    isAVModerationSupported: function () { return true; },
    enableAVModeration: function (type) { calls.push(['enableAV', type]); },
    disableAVModeration: function (type) { calls.push(['disableAV', type]); },
    avModerationApprove: function (type, id) { calls.push(['approveAV', type, id]); },
    avModerationReject: function (type, id) { calls.push(['rejectAV', type, id]); },
    getProperty: function () { return undefined; },
    getStartMutedPolicy: function () { return null; }
  };
  function FakeConnection() {
    this.jid = 'fake@example.test';
    this.listeners = {};
    this.initJitsiConference = function () { return fake; };
    this.addEventListener = function (event, handler) {
      (this.listeners[event] || (this.listeners[event] = [])).push(handler);
    };
    this.connect = function () {
      const Events = L.events.connection;
      (this.listeners[Events.CONNECTION_ESTABLISHED] || []).forEach(fn => fn());
    };
  }
  L.JitsiConnection = FakeConnection;
  const restore = function () { L.JitsiConnection = original; };
  const fail = function (label) {
    return function (message) {
      globalThis.__propertyProbe = label + ' rejected: ' + message;
      restore();
    };
  };
  const steps = [];
  let setResult = null;
  let mirrorResult = null;
  let fallbackResult = null;
  let lobbyUserID = null;
  let avSupported = null;

  function finish() {
    const Events = L.events.conference;
    // Fire the lib events after the method checks: the façade listeners are already wired.
    handlers[Events.PARTICIPANT_PROPERTY_CHANGED](
      remote, 'jitsi_participant_lang', undefined, ['zh', 'en']);
    handlers[Events.PROPERTIES_CHANGED]({ 'audio-limit-reached': true, 'bridge-count': 2 });
    handlers[Events.LOBBY_USER_JOINED]('guest-2', 'Bob', 'https://example.test/b.png');
    handlers[Events.LOBBY_USER_UPDATED]('guest-2', { email: 'new@example.test' });
    globalThis.__lobbyListener({ type: 'ping' }, 'guest-2');
    handlers[Events.AV_MODERATION_CHANGED](true, 'audio', remote);
    handlers[Events.AV_MODERATION_APPROVED]('video');
    handlers[Events.AV_MODERATION_REJECTED]('desktop');
    handlers[Events.AV_MODERATION_PARTICIPANT_APPROVED]({ mediaType: 'audio', participant: remote });
    handlers[Events.LOBBY_USER_LEFT]('guest-2');

    __sdkSettle('conference.state', '{}', function (state) {
      const events = globalThis.__nativeCalls.filter(function (call) {
        return call.method === 'sdk.event' && call.args && call.args.name;
      });
      const payload = function (name) {
        const hit = events.filter(function (call) { return call.args.name === name; }).pop();
        return hit ? hit.args.payload : null;
      };
      const propertyEvent = payload('participantPropertyChanged') || {};
      const lobbyJoined = payload('lobbyUserJoined') || {};
      const lobbyUpdated = payload('lobbyUserUpdated') || {};
      const lobbyMessage = payload('lobbyMessageReceived') || {};
      const avChanged = payload('avModerationChanged') || {};
      const avParticipant = payload('avModerationParticipantApproved') || {};
      const problems = [];
      if (JSON.stringify(setResult) !== '["a","b"]') problems.push('set mirror: ' + JSON.stringify(setResult));
      if (JSON.stringify(mirrorResult) !== '["a","b"]') problems.push('array lost: ' + JSON.stringify(mirrorResult));
      if (fallbackResult !== 'flattened:tags') problems.push('getter fallback: ' + fallbackResult);
      if (lobbyUserID !== 'guest-1') problems.push('lobby id: ' + lobbyUserID);
      if (avSupported !== true) problems.push('av supported: ' + avSupported);
      if (JSON.stringify(calls) !== JSON.stringify([
        ['set', 'tags', ['a', 'b']], ['remove', 'tags'], ['approveLobby', 'guest-1'],
        ['denyLobby', 'guest-2'], ['lobbyMessage', { type: 'hi' }, 'guest-1'],
        ['enableAV', 'audio'], ['disableAV', 'video'],
        ['approveAV', 'audio', 'remote-1'], ['rejectAV', 'desktop', 'remote-1']
      ])) problems.push('calls: ' + JSON.stringify(calls));
      if (JSON.stringify(state.avModeration) !== '{"audio":true}') problems.push('av state: ' + JSON.stringify(state.avModeration));
      if (JSON.stringify(state.lobbyUsers) !== '[]') problems.push('lobby after leave: ' + JSON.stringify(state.lobbyUsers));
      if (!state.localParticipantProperties || Object.keys(state.localParticipantProperties).length !== 0) {
        problems.push('local mirror after remove: ' + JSON.stringify(state.localParticipantProperties));
      }
      if (!state.conferenceProperties || state.conferenceProperties['bridge-count'] !== 2) {
        problems.push('conference properties: ' + JSON.stringify(state.conferenceProperties));
      }
      if (!state.visitorsSupported) problems.push('visitorsSupported missing');
      if (propertyEvent.id !== 'remote-1' || propertyEvent.key !== 'jitsi_participant_lang'
          || JSON.stringify(propertyEvent.value) !== '["zh","en"]') {
        problems.push('participantPropertyChanged: ' + JSON.stringify(propertyEvent));
      }
      if (lobbyJoined.displayName !== 'Bob' || lobbyUpdated.email !== 'new@example.test'
          || lobbyUpdated.displayName !== 'Bob') {
        problems.push('lobby rows: ' + JSON.stringify([lobbyJoined, lobbyUpdated]));
      }
      if (lobbyMessage.from !== 'guest-2' || !lobbyMessage.message
          || lobbyMessage.message.type !== 'ping') {
        problems.push('lobby message: ' + JSON.stringify(lobbyMessage));
      }
      if (avChanged.enabled !== true || avChanged.mediaType !== 'audio'
          || avChanged.actor !== 'remote-1') {
        problems.push('avModerationChanged: ' + JSON.stringify(avChanged));
      }
      if (avParticipant.id !== 'remote-1' || avParticipant.mediaType !== 'audio') {
        problems.push('av participant approval: ' + JSON.stringify(avParticipant));
      }
      globalThis.__propertyProbe = problems.length === 0 ? 'ok' : problems.join(' | ');
      restore();
    }, fail('state'));
  }

  function run() {
    // Pushed in reverse execution order, so the last one pushed (connect) runs first.
    const step = steps.pop();
    if (!step) { finish(); return; }
    step();
  }

  steps.push(function () {
    __sdkSettle('conference.rejectAVModeration', '{"participantId":"remote-1","mediaType":"desktop"}',
      function () { run(); }, fail('rejectAVModeration'));
  });
  steps.push(function () {
    __sdkSettle('conference.approveAVModeration', '{"participantId":"remote-1","mediaType":"audio"}',
      function () { run(); }, fail('approveAVModeration'));
  });
  steps.push(function () {
    __sdkSettle('conference.disableAVModeration', '{"mediaType":"video"}',
      function () { run(); }, fail('disableAVModeration'));
  });
  steps.push(function () {
    __sdkSettle('conference.enableAVModeration', '{"mediaType":"audio"}',
      function () { run(); }, fail('enableAVModeration'));
  });
  steps.push(function () {
    __sdkSettle('conference.isAVModerationSupported', '{}', function (value) {
      avSupported = value;
      run();
    }, fail('isAVModerationSupported'));
  });
  steps.push(function () {
    __sdkSettle('conference.sendLobbyMessage',
      '{"message":{"type":"hi"},"participantId":"guest-1"}',
      function () { run(); }, fail('sendLobbyMessage'));
  });
  steps.push(function () {
    __sdkSettle('conference.denyLobbyUser', '{"participantId":"guest-2"}',
      function () { run(); }, fail('denyLobbyUser'));
  });
  steps.push(function () {
    __sdkSettle('conference.approveLobbyUser', '{"participantId":"guest-1"}',
      function () { run(); }, fail('approveLobbyUser'));
  });
  steps.push(function () {
    __sdkSettle('conference.myLobbyUserID', '{}', function (value) {
      lobbyUserID = value;
      run();
    }, fail('myLobbyUserID'));
  });
  steps.push(function () {
    __sdkSettle('conference.localParticipantProperty', '{"name":"tags"}', function (value) {
      mirrorResult = value;
      __sdkSettle('conference.removeLocalParticipantProperty', '{"name":"tags"}',
        function () {
          __sdkSettle('conference.localParticipantProperty', '{"name":"tags"}', function (fallback) {
            fallbackResult = fallback;
            run();
          }, fail('localParticipantProperty after remove'));
        }, fail('removeLocalParticipantProperty'));
    }, fail('localParticipantProperty'));
  });
  steps.push(function () {
    __sdkSettle('conference.setLocalParticipantProperty', '{"name":"tags","value":["a","b"]}',
      function (value) { setResult = value; run(); }, fail('setLocalParticipantProperty'));
  });
  steps.push(function () {
    __sdkSettle('conference.prepare', JSON.stringify({ name: 'props', options: {}, configOverwrite: {} }),
      function () { run(); }, fail('prepare'));
  });
  steps.push(function () {
    __sdkSettle('connection.connect', JSON.stringify({
      serviceUrl: 'https://example.test/http-bind', hosts: { domain: 'd', muc: 'm' }
    }), function () { run(); }, fail('connect'));
  });

  run();
})();
""")
RunLoop.current.run(until: Date().addingTimeInterval(3))
let propertyProbe = context.evaluateScript("__propertyProbe")?.toString() ?? "nil"
if propertyProbe == "ok" {
    print("ok   local properties, lobby moderation and AV moderation reach the lib")
} else {
    failures.append("property/lobby/AV probe")
    print("FAIL property/lobby/AV probe -> \(propertyProbe)")
}

// Breakout rooms end-to-end: the snapshot has to flatten the lib's room map (Swift decodes an
// array), the management calls must reach `getBreakoutRooms()` with full JIDs, and a room
// switch must leave with `switch_room`, recreate the conference with the breakout domain,
// re-add the live tracks and re-stage local properties before joining. The transient
// CONFERENCE_LEFT of the old room must never surface as `conferenceLeft`.
context.evaluateScript("""
globalThis.__breakoutProbe = 'pending';
globalThis.__breakoutSwitch = 'not started';
(function () {
  const L = globalThis.JitsiMeetJS;
  const original = L.JitsiConnection;
  const Events = L.events.conference;
  const managerCalls = [];
  const makeManager = function () {
    return {
      isSupported: function () { return true; },
      isFeatureSupported: function (feature) { return feature === 'rename'; },
      isBreakoutRoom: function () { return false; },
      getMainRoomJid: function () { return 'main@meet.jitsi'; },
      createBreakoutRoom: function (subject) { managerCalls.push(['create', subject]); },
      renameBreakoutRoom: function (jid, subject) { managerCalls.push(['rename', jid, subject]); },
      removeBreakoutRoom: function (jid) { managerCalls.push(['remove', jid]); },
      sendParticipantToRoom: function (participantJid, roomJid) {
        managerCalls.push(['move', participantJid, roomJid]);
      }
    };
  };
  const makeConference = function (label) {
    const handlers = {};
    const conf = {
      joinPassword: null,
      leaveReason: null,
      options: null,
      trackIDs: [],
      propertyCalls: [],
      handlers: handlers,
      manager: makeManager(),
      on: function (name, handler) { (handlers[name] || (handlers[name] = [])).push(handler); },
      off: function (name, handler) {
        handlers[name] = (handlers[name] || []).filter(function (fn) { return fn !== handler; });
      },
      emit: function (name, value) {
        (handlers[name] || []).slice().forEach(function (fn) { fn(value); });
      },
      getBreakoutRooms: function () { return conf.manager; },
      isModerator: function () { return true; },
      isJoined: function () { return true; },
      isAuthRequired: function () { return false; },
      isPasswordRequired: function () { return false; },
      isE2EEEnabled: function () { return false; },
      isLobbySupported: function () { return false; },
      isMembersOnly: function () { return false; },
      isVisitorsSupported: function () { return false; },
      isEndConferenceSupported: function () { return false; },
      myUserId: function () { return 'local-1'; },
      getParticipants: function () {
        return [{
          getId: function () { return 'p1'; },
          getJid: function () { return 'p1@meet.jitsi/res'; }
        }];
      },
      getParticipantById: function (id) {
        return conf.getParticipants().find(function (p) { return p.getId() === id; }) || null;
      },
      setLocalParticipantProperty: function (name, value) {
        conf.propertyCalls.push([name, value]);
      },
      leave: function (reason) {
        conf.leaveReason = reason;
        // The real lib emits CONFERENCE_LEFT once the MUC leave completes; the facade has to
        // swallow it during a switch.
        conf.emit(Events.CONFERENCE_LEFT, label);
        return Promise.resolve();
      },
      addTrack: function (track) { conf.trackIDs.push(track.getId()); return Promise.resolve(); },
      join: function (password) { conf.joinPassword = password; }
    };
    return conf;
  };
  const first = makeConference('main');
  const second = makeConference('abc');
  globalThis.__breakoutSecond = second;
  let created = 0;
  function FakeConnection() {
    this.jid = 'fake@example.test';
    this.listeners = {};
    this.initJitsiConference = function (name, options) {
      created += 1;
      const conf = created === 1 ? first : second;
      conf.options = options;
      conf.name = name;
      return conf;
    };
    this.addEventListener = function (event, handler) {
      (this.listeners[event] || (this.listeners[event] = [])).push(handler);
    };
    this.connect = function () {
      (this.listeners[L.events.connection.CONNECTION_ESTABLISHED] || []).forEach(fn => fn());
    };
  }
  L.JitsiConnection = FakeConnection;
  const restore = function () { L.JitsiConnection = original; };
  const fail = function (label) {
    return function (message) {
      globalThis.__breakoutProbe = label + ' rejected: ' + message;
      restore();
    };
  };
  const steps = [];
  let snapshot = null;
  const track = {
    getId: function () { return 'cam'; },
    getTrackId: function () { return 'cam'; },
    getType: function () { return 'video'; },
    isLocal: function () { return true; },
    isMuted: function () { return false; },
    stream: null
  };

  function finish() {
    const calls = globalThis.__nativeCalls;
    const named = function (name) {
      return calls.filter(function (call) {
        return call.method === 'sdk.event' && call.args && call.args.name === name;
      });
    };
    const update = named('breakoutRoomsUpdated').pop();
    const move = named('breakoutRoomsMoveToRoom').pop();
    const problems = [];

    const rooms = (snapshot && snapshot.rooms) || [];
    if (!snapshot || snapshot.isSupported !== true || snapshot.canRename !== true
        || snapshot.isBreakoutRoom !== false || snapshot.mainRoomJID !== 'main@meet.jitsi'
        || snapshot.roomCounter !== 3) {
      problems.push('snapshot: ' + JSON.stringify(snapshot));
    }
    if (rooms.length !== 1 || rooms[0].id !== '1' || rooms[0].jid !== 'abc@breakout.meet.jitsi'
        || rooms[0].name !== 'Room A' || rooms[0].isMainRoom !== false
        || rooms[0].participants.length !== 1
        || rooms[0].participants[0].jid !== 'p1@meet.jitsi/res'
        || rooms[0].participants[0].displayName !== 'Ada'
        || rooms[0].participants[0].role !== 'participant') {
      problems.push('rooms: ' + JSON.stringify(rooms));
    }
    if (!update || (update.args.payload.rooms || []).length !== 1
        || update.args.payload.roomCounter !== 3) {
      problems.push('update event: ' + JSON.stringify(update && update.args.payload));
    }
    if (!move || move.args.payload.roomJid !== 'abc@breakout.meet.jitsi') {
      problems.push('move event: ' + JSON.stringify(move && move.args.payload));
    }
    if (JSON.stringify(managerCalls) !== JSON.stringify([
      ['create', 'Room B'], ['rename', 'abc@breakout.meet.jitsi', 'Room C'],
      ['remove', 'abc@breakout.meet.jitsi'], ['move', 'p1@meet.jitsi/res', 'abc@breakout.meet.jitsi']
    ])) {
      problems.push('manager calls: ' + JSON.stringify(managerCalls));
    }
    if (first.leaveReason !== 'switch_room') {
      problems.push('leave reason: ' + first.leaveReason);
    }
    if (!second.options || second.options.customDomain !== 'breakout.meet.jitsi'
        || second.name !== 'abc') {
      problems.push('switch target: ' + JSON.stringify([second.name, second.options]));
    }
    if (JSON.stringify(second.trackIDs) !== '["cam"]') {
      problems.push('re-added tracks: ' + JSON.stringify(second.trackIDs));
    }
    if (JSON.stringify(second.propertyCalls) !== '[["lang","zh"]]') {
      problems.push('re-applied properties: ' + JSON.stringify(second.propertyCalls));
    }
    if (named('conferenceLeft').length !== 0) {
      problems.push('transient conferenceLeft leaked');
    }
    if (globalThis.__breakoutSwitch !== 'resolved:{"name":"abc","joined":true,"id":"abc2"}') {
      problems.push('switch result: ' + globalThis.__breakoutSwitch);
    }
    globalThis.__breakoutProbe = problems.length === 0 ? 'ok' : problems.join(' | ');
    restore();
  }

  function run() {
    const step = steps.shift();
    if (!step) { return; }
    step();
  }

  steps.push(function () {
    __sdkSettle('connection.connect', JSON.stringify({
      serviceUrl: 'https://example.test/http-bind', hosts: { domain: 'meet.jitsi', muc: 'muc.meet.jitsi' }
    }), function () { run(); }, fail('connect'));
  });
  steps.push(function () {
    __sdkSettle('conference.prepare', JSON.stringify({
      name: 'main', options: {}, configOverwrite: {}
    }), function () { run(); }, fail('prepare'));
  });
  steps.push(function () {
    __sdkSettle('conference.setLocalParticipantProperty', '{"name":"lang","value":"zh"}',
      function () { run(); }, fail('setLocalParticipantProperty'));
  });
  steps.push(function () {
    first.emit(Events.TRACK_ADDED, track);
    __sdkSettle('conference.addTrack', '{"trackId":"cam"}',
      function () { run(); }, fail('addTrack'));
  });
  steps.push(function () {
    first.emit(Events.BREAKOUT_ROOMS_UPDATED, {
      rooms: {
        'abc@breakout.meet.jitsi': {
          id: 1,
          jid: 'abc@breakout.meet.jitsi',
          name: 'Room A',
          isMainRoom: false,
          participants: {
            'p1@meet.jitsi/res': { jid: 'p1@meet.jitsi/res', displayName: 'Ada', role: 'participant' }
          }
        }
      },
      roomCounter: 3
    });
    first.emit(Events.BREAKOUT_ROOMS_MOVE_TO_ROOM, 'abc@breakout.meet.jitsi');
    __sdkSettle('conference.breakoutRoomsState', '{}', function (value) {
      snapshot = value;
      run();
    }, fail('breakoutRoomsState'));
  });
  steps.push(function () {
    __sdkSettle('conference.createBreakoutRoom', '{"subject":"  Room B  "}', function () {
      __sdkSettle('conference.renameBreakoutRoom',
        '{"roomJid":"abc@breakout.meet.jitsi","subject":"Room C"}', function () {
          __sdkSettle('conference.removeBreakoutRoom',
            '{"roomJid":"abc@breakout.meet.jitsi"}', function () {
              __sdkSettle('conference.sendParticipantToBreakoutRoom',
                '{"participantId":"p1","roomJid":"abc@breakout.meet.jitsi"}', function () {
                  __sdkSettle('conference.switch', JSON.stringify({
                    name: 'abc',
                    options: {},
                    configOverwrite: { customDomain: 'breakout.meet.jitsi' },
                    waitForJoin: true,
                    waitTimeout: 60000
                  }), function (value) {
                    globalThis.__breakoutSwitch = 'resolved:' + JSON.stringify(value);
                    finish();
                  }, fail('conference.switch'));
                }, fail('sendParticipantToBreakoutRoom'));
            }, fail('removeBreakoutRoom'));
        }, fail('renameBreakoutRoom'));
    }, fail('createBreakoutRoom'));
  });

  run();
})();
""")
RunLoop.current.run(until: Date().addingTimeInterval(1))
context.evaluateScript("""
globalThis.__breakoutSecond.emit(globalThis.JitsiMeetJS.events.conference.CONFERENCE_JOINED, 'abc2');
""")
RunLoop.current.run(until: Date().addingTimeInterval(1))
let breakoutProbe = context.evaluateScript("__breakoutProbe")?.toString() ?? "nil"
if breakoutProbe == "ok" {
    print("ok   breakout rooms snapshot, moderation calls and room switch reach the lib")
} else {
    failures.append("breakout rooms probe")
    print("FAIL breakout rooms probe -> \(breakoutProbe)")
}

if loadErrors.isEmpty && failures.isEmpty {
    print("\nJS shim layer: PASS (\(scripts.count) scripts, \(assertions.count) assertions)")
    exit(0)
}
print("\nJS shim layer: FAIL (\(loadErrors.count) load errors, \(failures.count) assertions)")
exit(1)
