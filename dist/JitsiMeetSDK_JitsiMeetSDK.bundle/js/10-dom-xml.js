/*
 * 10-dom-xml.js — a deliberately small DOM + XML implementation.
 *
 * Scope: what Strophe.js and lib-jitsi-meet's XMLUtils/Caps actually touch.
 * Not a browser DOM: no layout, no CSS cascade, no innerHTML, no mutation observers.
 * Selector support is a documented subset (see `select()`), which is all `:scope>...`
 * in Caps.ts and the tag-name lookups in XMLUtils.ts require.
 */
(function (global) {
  'use strict';

  const ELEMENT_NODE = 1;
  const TEXT_NODE = 3;
  const CDATA_NODE = 4;
  const COMMENT_NODE = 8;
  const DOCUMENT_NODE = 9;
  const FRAGMENT_NODE = 11;

  function collectDescendants(node) {
    const found = [];
    const walk = current => {
      for (const child of current.childNodes) {
        if (child.nodeType === ELEMENT_NODE) {
          found.push(child);
          walk(child);
        }
      }
    };
    walk(node);
    return found;
  }

  /** Matches `tag`, `*`, `tag[attr]`, `tag[attr="value"]` against an element. */
  function matchesSimple(element, token) {
    if (element.nodeType !== ELEMENT_NODE) {
      return false;
    }
    const bracket = token.indexOf('[');
    const name = bracket < 0 ? token : token.slice(0, bracket);
    if (name && name !== '*' && element.nodeName !== name && element.localName !== name) {
      return false;
    }
    const predicatePattern = /\[([^\]]+)\]/g;
    let predicate;
    while ((predicate = predicatePattern.exec(token))) {
      const parsed = /^([^\]=]+?)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\]\s]+)))?$/.exec(predicate[1].trim());
      if (!parsed) {
        return false;
      }
      // `*|xmlns` and `prefix|xmlns` both select by local name here: the stanza parser
      // only records xmlns declarations, which are unprefixed in practice.
      const qualified = parsed[1];
      const localName = qualified.includes('|') ? qualified.slice(qualified.indexOf('|') + 1) : qualified;
      const attr = element.attributes.find(candidate => {
        const attrLocal = candidate.name.includes(':')
          ? candidate.name.slice(candidate.name.indexOf(':') + 1)
          : candidate.name;
        return candidate.name === qualified || attrLocal === localName;
      });
      if (!attr) {
        return false;
      }
      const expected = parsed[2] !== undefined ? parsed[2] : (parsed[3] !== undefined ? parsed[3] : parsed[4]);
      if (expected !== undefined && attr.value !== expected) {
        return false;
      }
    }
    return true;
  }

  class Event {
    constructor(type, options) {
      this.type = type;
      this.bubbles = !!(options && options.bubbles);
      this.target = null;
      this.defaultPrevented = false;
    }

    preventDefault() {
      this.defaultPrevented = true;
    }

    stopPropagation() {}
    stopImmediatePropagation() {}
  }

  class EventTarget {
    constructor() {
      this.__handlers = new Map();
    }

    addEventListener(type, handler) {
      if (!handler) {
        return;
      }
      if (!this.__handlers.has(type)) {
        this.__handlers.set(type, []);
      }
      this.__handlers.get(type).push(handler);
    }

    removeEventListener(type, handler) {
      const handlers = this.__handlers.get(type);
      if (!handlers) {
        return;
      }
      const index = handlers.indexOf(handler);
      if (index >= 0) {
        handlers.splice(index, 1);
      }
    }

    dispatchEvent(event) {
      event.target = event.target || this;
      const handlers = this.__handlers.get(event.type) || [];
      for (const handler of handlers.slice()) {
        if (typeof handler === 'function') {
          handler.call(this, event);
        } else if (typeof handler.handleEvent === 'function') {
          handler.handleEvent(event);
        }
      }
      // Strophe registers XHR/WebSocket callbacks as properties (`xhr.onreadystatechange`,
      // `socket.onopen`), not via addEventListener; without this the BOSH handshake and
      // the WebSocket transport never advance past their first state.
      const inline = this['on' + event.type];
      if (typeof inline === 'function') {
        inline.call(this, event);
      }
      return !event.defaultPrevented;
    }
  }

  class Node extends EventTarget {
    constructor(nodeType, nodeName) {
      super();
      this.nodeType = nodeType;
      this.nodeName = nodeName;
      this.namespaceURI = null;
      this.localName = nodeName;
      this.prefix = null;
      this.childNodes = [];
      this.parentNode = null;
      this.attributes = null;
    }

    get firstChild() {
      return this.childNodes.length ? this.childNodes[0] : null;
    }

    get lastChild() {
      return this.childNodes.length ? this.childNodes[this.childNodes.length - 1] : null;
    }

    get nextSibling() {
      if (!this.parentNode) {
        return null;
      }
      const siblings = this.parentNode.childNodes;
      const index = siblings.indexOf(this);
      return index >= 0 && index + 1 < siblings.length ? siblings[index + 1] : null;
    }

    get children() {
      return this.childNodes.filter(node => node.nodeType === ELEMENT_NODE);
    }

    get textContent() {
      if (this.nodeType === TEXT_NODE || this.nodeType === CDATA_NODE || this.nodeType === COMMENT_NODE) {
        return this.data;
      }
      return this.childNodes.map(node => node.textContent).join('');
    }

    set textContent(value) {
      this.childNodes = [];
      if (value !== '' && value !== null && value !== undefined) {
        this.appendChild(new Text(String(value)));
      }
    }

    appendChild(child) {
      if (child.nodeType === FRAGMENT_NODE) {
        for (const node of child.childNodes.slice()) {
          this.appendChild(node);
        }
        return child;
      }
      if (child.parentNode) {
        child.parentNode.removeChild(child);
      }
      child.parentNode = this;
      this.childNodes.push(child);
      return child;
    }

    insertBefore(child, reference) {
      if (!reference) {
        return this.appendChild(child);
      }
      const index = this.childNodes.indexOf(reference);
      if (index < 0) {
        return this.appendChild(child);
      }
      if (child.parentNode) {
        child.parentNode.removeChild(child);
      }
      child.parentNode = this;
      this.childNodes.splice(index, 0, child);
      return child;
    }

    removeChild(child) {
      const index = this.childNodes.indexOf(child);
      if (index >= 0) {
        this.childNodes.splice(index, 1);
        child.parentNode = null;
      }
      return child;
    }

    remove() {
      if (this.parentNode) {
        this.parentNode.removeChild(this);
      }
    }

    cloneNode(deep) {
      const copy = this.__makeEmptyCopy();
      if (deep) {
        for (const child of this.childNodes) {
          copy.appendChild(child.cloneNode(true));
        }
      }
      return copy;
    }

    __makeEmptyCopy() {
      const copy = new Node(this.nodeType, this.nodeName);
      copy.namespaceURI = this.namespaceURI;
      copy.localName = this.localName;
      return copy;
    }

    // Used by XMLUtils.ts / Strophe's element walk.
    getElementsByTagName(name) {
      const found = [];
      const walk = node => {
        for (const child of node.childNodes) {
          if (child.nodeType === ELEMENT_NODE) {
            if (name === '*' || child.nodeName === name || child.localName === name) {
              found.push(child);
            }
            walk(child);
          }
        }
      };
      walk(this);
      return found;
    }

    // XEP-0198 and the Jingle plugins look elements up by namespace.
    getElementsByTagNameNS(namespaceURI, localName) {
      const found = [];
      const walk = node => {
        for (const child of node.childNodes) {
          if (child.nodeType === ELEMENT_NODE) {
            const namespaceMatches = namespaceURI === '*' || child.namespaceURI === namespaceURI;
            const nameMatches = localName === '*' || child.localName === localName;
            if (namespaceMatches && nameMatches) {
              found.push(child);
            }
            walk(child);
          }
        }
      };
      walk(this);
      return found;
    }
  }

  class CharacterData extends Node {
    constructor(nodeType, data) {
      super(nodeType, nodeType === COMMENT_NODE ? '#comment' : '#text');
      this.data = data;
    }

    // Strophe's serializer walks text and CDATA nodes through `nodeValue`.
    get nodeValue() {
      return this.data;
    }

    set nodeValue(value) {
      this.data = String(value);
    }
  }

  class Text extends CharacterData {
    constructor(data) {
      super(TEXT_NODE, data);
    }
  }

  class CDATASection extends CharacterData {
    constructor(data) {
      super(CDATA_NODE, data);
    }
  }

  class Comment extends CharacterData {
    constructor(data) {
      super(COMMENT_NODE, data);
    }
  }

  class Attr {
    constructor(name, value, namespaceURI) {
      this.name = name;
      this.nodeName = name;
      this.value = String(value);
      this.namespaceURI = namespaceURI || null;
    }
  }

  // Strophe reads `elem.attributes.length`, indexes it and calls `getNamedItem` when it
  // serializes a stanza; an Array subclass keeps the indexed access while providing the
  // NamedNodeMap methods the DOM contract implies.
  class NamedNodeMap extends Array {
    getNamedItem(name) {
      return this.find(candidate => candidate.name === name) || null;
    }

    getNamedItemNS(namespaceURI, name) {
      return this.find(candidate => candidate.name === name && candidate.namespaceURI === namespaceURI) || null;
    }

    item(index) {
      return this[index] || null;
    }

    setNamedItem(attr) {
      const index = this.findIndex(candidate => candidate.name === attr.name);
      if (index < 0) {
        this.push(attr);
        return null;
      }
      const previous = this[index];
      this[index] = attr;
      return previous;
    }

    removeNamedItem(name) {
      const index = this.findIndex(candidate => candidate.name === name);
      return index < 0 ? null : this.splice(index, 1)[0];
    }
  }

  class Element extends Node {
    constructor(name, namespaceURI) {
      super(ELEMENT_NODE, name);
      this.tagName = name;
      this.attributes = new NamedNodeMap();
      if (namespaceURI) {
        this.namespaceURI = namespaceURI;
      }
      const colon = name.indexOf(':');
      if (colon > 0) {
        this.prefix = name.slice(0, colon);
        this.localName = name.slice(colon + 1);
      } else {
        this.localName = name;
      }
    }

    getAttribute(name) {
      const attr = this.attributes.find(candidate => candidate.name === name);
      return attr ? attr.value : null;
    }

    getAttributeNS(ns, name) {
      const attr = this.attributes.find(
        candidate => candidate.name === name && candidate.namespaceURI === ns
      );
      return attr ? attr.value : null;
    }

    hasAttribute(name) {
      return this.attributes.some(attr => attr.name === name);
    }

    setAttribute(name, value) {
      const attr = this.attributes.find(candidate => candidate.name === name);
      if (attr) {
        attr.value = String(value);
      } else {
        this.attributes.push(new Attr(name, value, null));
      }
    }

    setAttributeNS(ns, name, value) {
      const attr = this.attributes.find(candidate => candidate.name === name);
      if (attr) {
        attr.value = String(value);
        attr.namespaceURI = ns;
      } else {
        this.attributes.push(new Attr(name, value, ns));
      }
    }

    removeAttribute(name) {
      this.attributes = this.attributes.filter(attr => attr.name !== name);
    }

    __makeEmptyCopy() {
      const copy = new Element(this.nodeName, this.namespaceURI);
      copy.attributes = this.attributes.map(attr => new Attr(attr.name, attr.value, attr.namespaceURI));
      return copy;
    }

    querySelector(selector) {
      return this.querySelectorAll(selector)[0] || null;
    }

    /**
     * Selector subset: comma-separated compound selectors, `:scope`, child (`>`) and
     * descendant combinators, and `tag` / `tag[attr]` / `tag[attr="v"]` predicates.
     * That covers `:scope>query>feature` in Caps.ts and the tag lookups in XMLUtils.ts.
     * Unsupported syntax throws, so gaps surface instead of silently returning [].
     */
    querySelectorAll(selector) {
      const normalized = String(selector)
        .replace(/\s*>\s*/g, ' > ')
        .replace(/\s+/g, ' ')
        .trim();
      // `.` and `#` inside an attribute predicate are part of a namespace URI or value, not
      // class/id syntax; only the element-name portion is checked.
      if (/[.#]/.test(normalized.replace(/\[[^\]]*\]/g, ''))) {
        throw new Error('querySelectorAll: class/id selectors are not supported (' + selector + ')');
      }

      const results = [];
      for (const compound of normalized.split(',')) {
        let current = [this];
        // A bare selector matches any descendant; `:scope` and `>` narrow it to children.
        let descendant = true;
        for (const token of compound.split(' ').filter(Boolean)) {
          if (token === ':scope') {
            continue;
          }
          if (token === '>') {
            descendant = false;
            continue;
          }
          const next = [];
          for (const node of current) {
            const pool = descendant ? collectDescendants(node) : node.children;
            for (const candidate of pool) {
              if (matchesSimple(candidate, token) && next.indexOf(candidate) < 0) {
                next.push(candidate);
              }
            }
          }
          current = next;
          descendant = true;
        }
        for (const node of current) {
          if (results.indexOf(node) < 0) {
            results.push(node);
          }
        }
      }
      return results;
    }
  }

  class DocumentFragment extends Node {
    constructor() {
      super(FRAGMENT_NODE, '#document-fragment');
    }
  }

  class DocumentType {
    constructor(name) {
      this.name = name;
      this.publicId = '';
      this.systemId = '';
    }
  }

  class Document extends Node {
    constructor() {
      super(DOCUMENT_NODE, '#document');
      this.doctype = null;
    }

    get documentElement() {
      return this.childNodes.find(node => node.nodeType === ELEMENT_NODE) || null;
    }

    get head() {
      return this.documentElement ? this.documentElement.getElementsByTagName('head')[0] || null : null;
    }

    get body() {
      return this.documentElement ? this.documentElement.getElementsByTagName('body')[0] || null : null;
    }

    createElement(name) {
      // Case is significant: Strophe builds its BOSH wrapper with createElement("body"),
      // and an HTML-style "BODY" makes Prosody reject the session with `bad-request`.
      return new Element(name, null);
    }

    createElementNS(namespaceURI, name) {
      return new Element(name, namespaceURI);
    }

    createTextNode(data) {
      return new Text(String(data));
    }

    createCDATASection(data) {
      return new CDATASection(String(data));
    }

    createComment(data) {
      return new Comment(String(data));
    }

    createDocumentFragment() {
      return new DocumentFragment();
    }

    createEvent(type) {
      return new Event(type);
    }

    getElementById(id) {
      return this.getElementsByTagName('*').find(node => node.getAttribute('id') === id) || null;
    }

    querySelector(selector) {
      return (this.documentElement || this).querySelector(selector);
    }

    querySelectorAll(selector) {
      return (this.documentElement || this).querySelectorAll(selector);
    }
  }

  const ENTITIES = {
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&apos;': "'"
  };

  function decodeEntities(text) {
    return text.replace(/&(?:amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);/g, match => {
      if (ENTITIES[match]) {
        return ENTITIES[match];
      }
      const numeric = match.slice(2, -1);
      const code = numeric[0] === 'x' || numeric[0] === 'X'
        ? parseInt(numeric.slice(1), 16)
        : parseInt(numeric, 10);
      return Number.isNaN(code) ? match : String.fromCodePoint(code);
    });
  }

  function encodeEntities(text) {
    return String(text)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  /** Tolerant XML subset parser: elements, attributes, text, CDATA, comments, PIs. */
  function parseXML(source) {
    const document = new Document();
    const stack = [document];
    let cursor = 0;

    while (cursor < source.length) {
      const next = source.indexOf('<', cursor);
      if (next < 0) {
        break;
      }
      if (next > cursor) {
        const text = source.slice(cursor, next);
        if (text.trim()) {
          stack[stack.length - 1].appendChild(new Text(decodeEntities(text)));
        }
      }
      if (source.startsWith('<!--', next)) {
        const end = source.indexOf('-->', next);
        cursor = end < 0 ? source.length : end + 3;
        continue;
      }
      if (source.startsWith('<![CDATA[', next)) {
        const end = source.indexOf(']]>', next);
        const body = source.slice(next + 9, end < 0 ? source.length : end);
        stack[stack.length - 1].appendChild(new CDATASection(body));
        cursor = end < 0 ? source.length : end + 3;
        continue;
      }
      if (source.startsWith('<?', next)) {
        const end = source.indexOf('?>', next);
        if (source.startsWith('<?xml', next)) {
          const version = /version=["']([^"']+)["']/.exec(source.slice(next, end));
          document.doctype = new DocumentType(version ? version[1] : '1.0');
        }
        cursor = end < 0 ? source.length : end + 2;
        continue;
      }
      const close = source.indexOf('>', next);
      if (close < 0) {
        break;
      }
      const declaration = source.slice(next + 1, close);
      cursor = close + 1;

      if (declaration[0] === '/') {
        if (stack.length > 1) {
          stack.pop();
        }
        continue;
      }

      const selfClosing = declaration.endsWith('/');
      const body = selfClosing ? declaration.slice(0, -1).trim() : declaration.trim();
      const nameMatch = /^([^\s/]+)/.exec(body);
      if (!nameMatch) {
        continue;
      }
      const name = nameMatch[1];
      const parent = stack[stack.length - 1];
      const element = new Element(name, null);
      // Namespaces are resolved after every declaration on the tag is known: `<stream:features
      // xmlns='jabber:client'>` takes its prefix binding, not the default one, and unprefixed
      // children inherit the default mapping rather than the parent element's namespace.
      const prefixes = Object.create(parent.__prefixes || null);
      let defaultNamespace = parent.__defaultNamespace === undefined ? null : parent.__defaultNamespace;
      const attributePattern = /([\w:.-]+)\s*=\s*"([^"]*)"|([\w:.-]+)\s*=\s*'([^']*)'/g;
      let attribute;
      while ((attribute = attributePattern.exec(body.slice(name.length)))) {
        const key = attribute[1] || attribute[3];
        const value = decodeEntities(attribute[2] !== undefined ? attribute[2] : attribute[4]);
        element.setAttribute(key, value);
        if (key === 'xmlns') {
          defaultNamespace = value;
        } else if (key.startsWith('xmlns:')) {
          prefixes[key.slice(6)] = value;
        }
      }
      element.__prefixes = prefixes;
      element.__defaultNamespace = defaultNamespace;
      const colon = name.indexOf(':');
      element.namespaceURI = colon > 0 ? prefixes[name.slice(0, colon)] || null : defaultNamespace;
      stack[stack.length - 1].appendChild(element);
      if (!selfClosing) {
        stack.push(element);
      }
    }
    return document;
  }

  function serialize(node) {
    if (node.nodeType === DOCUMENT_NODE) {
      const root = node.documentElement;
      return (node.doctype ? '<?xml version="' + node.doctype.name + '"?>' : '') + (root ? serialize(root) : '');
    }
    if (node.nodeType === TEXT_NODE) {
      return encodeEntities(node.data);
    }
    if (node.nodeType === CDATA_NODE) {
      return '<![CDATA[' + node.data + ']]>';
    }
    if (node.nodeType === COMMENT_NODE) {
      return '<!--' + node.data + '-->';
    }
    if (node.nodeType === FRAGMENT_NODE) {
      return node.childNodes.map(serialize).join('');
    }
    const attributes = node.attributes
      .map(attr => ' ' + attr.name + '="' + encodeEntities(attr.value) + '"')
      .join('');
    if (!node.childNodes.length) {
      return '<' + node.nodeName + attributes + '/>';
    }
    return '<' + node.nodeName + attributes + '>' + node.childNodes.map(serialize).join('') + '</' + node.nodeName + '>';
  }

  global.DOMParser = class DOMParser {
    parseFromString(source, type) {
      if (type && type.indexOf('xml') < 0 && type.indexOf('html') < 0) {
        throw new Error('DOMParser: unsupported content type ' + type);
      }
      return parseXML(String(source));
    }
  };

  global.XMLSerializer = class XMLSerializer {
    serializeToString(node) {
      return serialize(node);
    }
  };

  global.Node = Node;
  global.Element = Element;
  global.Attr = Attr;
  global.NamedNodeMap = NamedNodeMap;
  global.Text = Text;
  global.Comment = Comment;
  global.DocumentFragment = DocumentFragment;
  global.Event = Event;
  global.EventTarget = EventTarget;

  const document = new Document();

  document.implementation = {
    createDocument(namespaceURI, name, doctype) {
      const created = new Document();
      if (name) {
        created.appendChild(new Element(name, namespaceURI || null));
      }
      created.doctype = doctype || null;
      return created;
    },
    createHTMLDocument(title) {
      const created = new Document();
      const root = created.appendChild(new Element('html', null));
      const head = root.appendChild(new Element('head', null));
      head.appendChild(new Element('title', null)).textContent = title || '';
      root.appendChild(new Element('body', null));
      return created;
    },
    hasFeature() {
      return true;
    }
  };

  global.document = document;
  global.__jitsiDom = { parseXML, serialize, Document, Element, Node, Event, EventTarget };
})(globalThis);
