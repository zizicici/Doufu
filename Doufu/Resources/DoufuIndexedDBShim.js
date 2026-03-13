(function() {
  'use strict';

  // ======== IndexedDB persistence shim ========
  // Replaces window.indexedDB with an in-memory implementation that
  // flushes to native via webkit messageHandler → AppData/indexedDB.json.

  // Structured-clone-lite: preserves Date and binary types through JSON.
  // Binary data (ArrayBuffer / TypedArray) is stored as base64 with a tag.

  function _bufToB64(buf) {
    var bytes = new Uint8Array(buf);
    var binary = '';
    for (var i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    return btoa(binary);
  }

  function _b64ToBuf(b64) {
    var binary = atob(b64);
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes.buffer;
  }

  var _typedArrayTypes = {
    'Int8Array': Int8Array, 'Uint8Array': Uint8Array,
    'Uint8ClampedArray': Uint8ClampedArray,
    'Int16Array': Int16Array, 'Uint16Array': Uint16Array,
    'Int32Array': Int32Array, 'Uint32Array': Uint32Array,
    'Float32Array': Float32Array, 'Float64Array': Float64Array
  };

  function _replacer(k, v) {
    var raw = this[k];
    if (raw instanceof Date) return { __doufuDate__: raw.getTime() };
    if (raw instanceof ArrayBuffer)
      return { __doufuBuf__: _bufToB64(raw), __doufuType__: 'ArrayBuffer' };
    if (ArrayBuffer.isView(raw) && !(raw instanceof DataView))
      return { __doufuBuf__: _bufToB64(raw.buffer), __doufuType__: raw.constructor.name,
               __off__: raw.byteOffset, __len__: raw.length };
    return v;
  }

  function _reviver(k, v) {
    if (v && typeof v === 'object') {
      if (typeof v.__doufuDate__ === 'number') return new Date(v.__doufuDate__);
      if (typeof v.__doufuBuf__ === 'string') {
        var buf = _b64ToBuf(v.__doufuBuf__);
        if (v.__doufuType__ === 'ArrayBuffer') return buf;
        var Ctor = _typedArrayTypes[v.__doufuType__] || Uint8Array;
        return new Ctor(buf, v.__off__ || 0, v.__len__ !== undefined ? v.__len__ : undefined);
      }
    }
    return v;
  }

  function _clone(v) {
    return JSON.parse(JSON.stringify(v, _replacer), _reviver);
  }

  var _idb = (function() {
    var raw = '__DOUFU_IDB_SNAPSHOT__';
    if (typeof raw === 'string') return JSON.parse(raw, _reviver);
    // When replaced with an object literal, run reviver via round-trip.
    return JSON.parse(JSON.stringify(raw), _reviver);
  })();

  function _idbFlush() {
    try {
      // Send the JSON-safe tagged form (Date → __doufuDate__, binary → __doufuBuf__).
      // The native side stores this as-is; the reviver restores types on next load.
      window.webkit.messageHandlers.doufuIndexedDB.postMessage(
        JSON.parse(JSON.stringify(_idb, _replacer))
      );
    } catch(e) {}
  }

  function _async(fn) { Promise.resolve().then(fn); }

  // ---- Key utilities ----

  function _keyType(k) {
    if (typeof k === 'number') return 1;
    if (k instanceof Date) return 2;
    if (typeof k === 'string') return 3;
    if (Array.isArray(k)) return 4;
    return 0;
  }

  function _cmp(a, b) {
    var ta = _keyType(a), tb = _keyType(b);
    if (ta !== tb) return ta < tb ? -1 : 1;
    if (ta === 1) return a < b ? -1 : a > b ? 1 : 0;
    if (ta === 2) { var na = +a, nb = +b; return na < nb ? -1 : na > nb ? 1 : 0; }
    if (ta === 3) return a < b ? -1 : a > b ? 1 : 0;
    if (ta === 4) {
      for (var i = 0; i < Math.min(a.length, b.length); i++) {
        var c = _cmp(a[i], b[i]);
        if (c !== 0) return c;
      }
      return a.length < b.length ? -1 : a.length > b.length ? 1 : 0;
    }
    return 0;
  }

  function _getByKeyPath(obj, keyPath) {
    if (Array.isArray(keyPath)) {
      return keyPath.map(function(kp) { return _getByKeyPath(obj, kp); });
    }
    var parts = String(keyPath).split('.');
    var cur = obj;
    for (var i = 0; i < parts.length; i++) {
      if (cur == null) return undefined;
      cur = cur[parts[i]];
    }
    return cur;
  }

  function _setByKeyPath(obj, keyPath, value) {
    var parts = String(keyPath).split('.');
    var cur = obj;
    for (var i = 0; i < parts.length - 1; i++) {
      if (cur[parts[i]] == null) cur[parts[i]] = {};
      cur = cur[parts[i]];
    }
    cur[parts[parts.length - 1]] = value;
  }

  function _inRange(key, range) {
    if (!range) return true;
    if (range._lower !== undefined) {
      var c = _cmp(key, range._lower);
      if (c < 0 || (c === 0 && range._lowerOpen)) return false;
    }
    if (range._upper !== undefined) {
      var c2 = _cmp(key, range._upper);
      if (c2 > 0 || (c2 === 0 && range._upperOpen)) return false;
    }
    return true;
  }

  // ---- DOMStringList ----

  function _DOMStringList(arr) {
    var list = Object.create(_DOMStringList.prototype);
    for (var i = 0; i < arr.length; i++) list[i] = arr[i];
    list.length = arr.length;
    return list;
  }
  _DOMStringList.prototype.contains = function(s) {
    for (var i = 0; i < this.length; i++) if (this[i] === s) return true;
    return false;
  };
  _DOMStringList.prototype.item = function(i) { return this[i] || null; };
  _DOMStringList.prototype[Symbol.iterator] = function() {
    var idx = 0, self = this;
    return { next: function() {
      return idx < self.length ? { value: self[idx++], done: false } : { done: true };
    }};
  };

  // ---- IDBKeyRange ----

  function _IDBKeyRange(lower, upper, lowerOpen, upperOpen) {
    this._lower = lower; this._upper = upper;
    this._lowerOpen = !!lowerOpen; this._upperOpen = !!upperOpen;
  }
  Object.defineProperties(_IDBKeyRange.prototype, {
    lower: { get: function() { return this._lower; } },
    upper: { get: function() { return this._upper; } },
    lowerOpen: { get: function() { return this._lowerOpen; } },
    upperOpen: { get: function() { return this._upperOpen; } }
  });
  _IDBKeyRange.prototype.includes = function(key) { return _inRange(key, this); };
  _IDBKeyRange.only = function(v) { return new _IDBKeyRange(v, v, false, false); };
  _IDBKeyRange.lowerBound = function(l, o) { return new _IDBKeyRange(l, undefined, !!o, false); };
  _IDBKeyRange.upperBound = function(u, o) { return new _IDBKeyRange(undefined, u, false, !!o); };
  _IDBKeyRange.bound = function(l, u, lo, uo) { return new _IDBKeyRange(l, u, !!lo, !!uo); };

  // ---- Event helpers ----

  function _Event(type) {
    this.type = type; this.target = null; this.currentTarget = null;
    this.bubbles = false; this.cancelable = false; this.defaultPrevented = false;
  }
  _Event.prototype.preventDefault = function() { this.defaultPrevented = true; };
  _Event.prototype.stopPropagation = function() {};
  _Event.prototype.stopImmediatePropagation = function() {};

  function _VersionChangeEvent(type, oldVersion, newVersion) {
    _Event.call(this, type);
    this.oldVersion = oldVersion; this.newVersion = newVersion;
  }
  _VersionChangeEvent.prototype = Object.create(_Event.prototype);

  // ---- Mixin: event target ----

  function _mixEvents(obj) {
    obj._listeners = {};
    obj.addEventListener = function(t, fn) {
      if (!this._listeners[t]) this._listeners[t] = [];
      this._listeners[t].push(fn);
    };
    obj.removeEventListener = function(t, fn) {
      if (!this._listeners[t]) return;
      this._listeners[t] = this._listeners[t].filter(function(f) { return f !== fn; });
    };
    obj.dispatchEvent = function(evt) {
      evt.target = this; evt.currentTarget = this;
      var h = this['on' + evt.type];
      if (h) h.call(this, evt);
      var ls = this._listeners[evt.type];
      if (ls) ls.forEach(function(fn) { fn.call(this, evt); }.bind(this));
    };
  }

  // ---- IDBRequest ----

  function _IDBRequest(source, transaction) {
    this.result = undefined; this.error = null;
    this.source = source || null; this.transaction = transaction || null;
    this.readyState = 'pending';
    this.onsuccess = null; this.onerror = null;
    _mixEvents(this);
  }
  _IDBRequest.prototype._succeed = function(result) {
    this.readyState = 'done'; this.result = result;
    var self = this;
    _async(function() { self.dispatchEvent(new _Event('success')); });
  };
  _IDBRequest.prototype._fail = function(err) {
    this.readyState = 'done'; this.error = err;
    var self = this;
    _async(function() { self.dispatchEvent(new _Event('error')); });
  };

  // ---- IDBCursor / IDBCursorWithValue ----

  function _IDBCursor(source, records, direction, request, tx, storeName, keysOnly) {
    this._source = source; this._records = records;
    this._direction = direction || 'next'; this._request = request;
    this._tx = tx; this._storeName = storeName; this._keysOnly = keysOnly;
    this._pos = -1;
    this.key = undefined; this.primaryKey = undefined;
    if (!keysOnly) this.value = undefined;
  }
  Object.defineProperties(_IDBCursor.prototype, {
    direction: { get: function() { return this._direction; } },
    source: { get: function() { return this._source; } }
  });
  _IDBCursor.prototype._advance = function(n) {
    this._pos += n;
    if (this._pos >= this._records.length) {
      this.key = undefined; this.primaryKey = undefined;
      if (!this._keysOnly) this.value = undefined;
      this._request.result = null;
    } else {
      var r = this._records[this._pos];
      this.key = r.key; this.primaryKey = r.primaryKey;
      if (!this._keysOnly) this.value = r.value;
      this._request.result = this;
    }
    this._request.readyState = 'done';
    var self = this;
    _async(function() { self._request.dispatchEvent(new _Event('success')); });
  };
  _IDBCursor.prototype.continue = function(key) {
    if (key !== undefined) {
      var fwd = this._direction === 'next' || this._direction === 'nextunique';
      while (this._pos + 1 < this._records.length) {
        var c = _cmp(this._records[this._pos + 1].key, key);
        if (fwd ? c >= 0 : c <= 0) break;
        this._pos++;
      }
    }
    this._advance(1);
  };
  _IDBCursor.prototype.advance = function(n) { this._advance(n); };
  _IDBCursor.prototype.update = function(value) {
    if (this._keysOnly) throw new DOMException('', 'InvalidStateError');
    var req = new _IDBRequest(this._source, this._tx);
    var store = this._tx._getStoreData(this._storeName);
    if (store) {
      var pk = this.primaryKey;
      for (var i = 0; i < store.records.length; i++) {
        if (_cmp(store.records[i].key, pk) === 0) {
          store.records[i].value = _clone(value); break;
        }
      }
      this.value = _clone(value);
      this._records[this._pos].value = this.value;
      this._tx._dirty = true;
      req._succeed(pk);
    }
    return req;
  };
  _IDBCursor.prototype.delete = function() {
    var req = new _IDBRequest(this._source, this._tx);
    var store = this._tx._getStoreData(this._storeName);
    if (store) {
      var pk = this.primaryKey;
      store.records = store.records.filter(function(r) { return _cmp(r.key, pk) !== 0; });
      this._tx._dirty = true;
      req._succeed(undefined);
    }
    return req;
  };

  // ---- IDBIndex ----

  function _IDBIndex(store, name, def) {
    this._store = store; this._name = name;
    this._keyPath = def.keyPath; this._unique = !!def.unique;
    this._multiEntry = !!def.multiEntry;
  }
  Object.defineProperties(_IDBIndex.prototype, {
    name: { get: function() { return this._name; } },
    keyPath: { get: function() { return this._keyPath; } },
    unique: { get: function() { return this._unique; } },
    multiEntry: { get: function() { return this._multiEntry; } },
    objectStore: { get: function() { return this._store; } }
  });
  _IDBIndex.prototype._getRecords = function(query) {
    var range = (query instanceof _IDBKeyRange) ? query
      : (query !== undefined ? _IDBKeyRange.only(query) : null);
    var sd = this._store._tx._getStoreData(this._store._name);
    if (!sd) return [];
    var kp = this._keyPath, me = this._multiEntry, out = [];
    for (var i = 0; i < sd.records.length; i++) {
      var rec = sd.records[i];
      var ik = _getByKeyPath(rec.value, kp);
      if (ik === undefined) continue;
      if (me && Array.isArray(ik)) {
        for (var j = 0; j < ik.length; j++) {
          if (_inRange(ik[j], range))
            out.push({ key: ik[j], primaryKey: rec.key, value: _clone(rec.value) });
        }
      } else {
        if (_inRange(ik, range))
          out.push({ key: ik, primaryKey: rec.key, value: _clone(rec.value) });
      }
    }
    out.sort(function(a, b) { return _cmp(a.key, b.key) || _cmp(a.primaryKey, b.primaryKey); });
    return out;
  };
  _IDBIndex.prototype.get = function(q) {
    var req = new _IDBRequest(this, this._store._tx);
    var recs = this._getRecords(q);
    req._succeed(recs.length > 0 ? recs[0].value : undefined);
    return req;
  };
  _IDBIndex.prototype.getKey = function(q) {
    var req = new _IDBRequest(this, this._store._tx);
    var recs = this._getRecords(q);
    req._succeed(recs.length > 0 ? recs[0].primaryKey : undefined);
    return req;
  };
  _IDBIndex.prototype.getAll = function(q, cnt) {
    var req = new _IDBRequest(this, this._store._tx);
    var recs = this._getRecords(q);
    if (cnt !== undefined) recs = recs.slice(0, cnt);
    req._succeed(recs.map(function(r) { return r.value; }));
    return req;
  };
  _IDBIndex.prototype.getAllKeys = function(q, cnt) {
    var req = new _IDBRequest(this, this._store._tx);
    var recs = this._getRecords(q);
    if (cnt !== undefined) recs = recs.slice(0, cnt);
    req._succeed(recs.map(function(r) { return r.primaryKey; }));
    return req;
  };
  _IDBIndex.prototype.count = function(q) {
    var req = new _IDBRequest(this, this._store._tx);
    req._succeed(this._getRecords(q).length);
    return req;
  };
  _IDBIndex.prototype.openCursor = function(q, dir) {
    var req = new _IDBRequest(this, this._store._tx);
    var recs = this._getRecords(q);
    if (dir === 'prev' || dir === 'prevunique') recs.reverse();
    var c = new _IDBCursor(this, recs, dir || 'next', req, this._store._tx, this._store._name, false);
    c._advance(1); return req;
  };
  _IDBIndex.prototype.openKeyCursor = function(q, dir) {
    var req = new _IDBRequest(this, this._store._tx);
    var recs = this._getRecords(q);
    if (dir === 'prev' || dir === 'prevunique') recs.reverse();
    var c = new _IDBCursor(this, recs, dir || 'next', req, this._store._tx, this._store._name, true);
    c._advance(1); return req;
  };

  // ---- IDBObjectStore ----

  function _IDBObjectStore(tx, name, storeDef) {
    this._tx = tx; this._name = name;
    this._keyPath = storeDef.keyPath;
    this._autoIncrement = !!storeDef.autoIncrement;
    this._indexes = storeDef.indexes || {};
  }
  Object.defineProperties(_IDBObjectStore.prototype, {
    name: { get: function() { return this._name; } },
    keyPath: { get: function() { return this._keyPath; } },
    autoIncrement: { get: function() { return this._autoIncrement; } },
    indexNames: { get: function() { return _DOMStringList(Object.keys(this._indexes)); } },
    transaction: { get: function() { return this._tx; } }
  });
  _IDBObjectStore.prototype._sd = function() {
    return this._tx._getStoreData(this._name);
  };
  // Check unique index constraints. Returns error message or null.
  _IDBObjectStore.prototype._checkUnique = function(value, primaryKey, store) {
    var idxs = store.indexes;
    for (var iname in idxs) {
      if (!idxs[iname].unique) continue;
      var ikp = idxs[iname].keyPath;
      var ik = _getByKeyPath(value, ikp);
      if (ik === undefined) continue;
      for (var i = 0; i < store.records.length; i++) {
        var rec = store.records[i];
        // Skip the record being replaced (put with same primary key).
        if (primaryKey !== undefined && _cmp(rec.key, primaryKey) === 0) continue;
        var existingIK = _getByKeyPath(rec.value, ikp);
        if (existingIK !== undefined && _cmp(existingIK, ik) === 0)
          return 'Unique index "' + iname + '" constraint violated';
      }
    }
    return null;
  };
  _IDBObjectStore.prototype._resolveKey = function(value, key, store) {
    var ek = key;
    if (this._keyPath) {
      ek = _getByKeyPath(value, this._keyPath);
      if (ek === undefined && this._autoIncrement) {
        ek = store.nextKey || 1; store.nextKey = ek + 1;
        _setByKeyPath(value, this._keyPath, ek);
      }
    } else if (ek === undefined && this._autoIncrement) {
      ek = store.nextKey || 1; store.nextKey = ek + 1;
    }
    return ek;
  };
  _IDBObjectStore.prototype.put = function(value, key) {
    var req = new _IDBRequest(this, this._tx);
    var s = this._sd();
    if (!s) { req._fail(new DOMException('Store not found', 'NotFoundError')); return req; }
    value = _clone(value);
    var ek = this._resolveKey(value, key, s);
    var uErr = this._checkUnique(value, ek, s);
    if (uErr) { req._fail(new DOMException(uErr, 'ConstraintError')); return req; }
    var found = false;
    for (var i = 0; i < s.records.length; i++) {
      if (_cmp(s.records[i].key, ek) === 0) { s.records[i].value = value; found = true; break; }
    }
    if (!found) {
      s.records.push({ key: ek, value: value });
      s.records.sort(function(a, b) { return _cmp(a.key, b.key); });
    }
    this._tx._dirty = true; req._succeed(ek); return req;
  };
  _IDBObjectStore.prototype.add = function(value, key) {
    var req = new _IDBRequest(this, this._tx);
    var s = this._sd();
    if (!s) { req._fail(new DOMException('Store not found', 'NotFoundError')); return req; }
    value = _clone(value);
    var ek = this._resolveKey(value, key, s);
    var uErr = this._checkUnique(value, undefined, s);
    if (uErr) { req._fail(new DOMException(uErr, 'ConstraintError')); return req; }
    for (var i = 0; i < s.records.length; i++) {
      if (_cmp(s.records[i].key, ek) === 0) {
        req._fail(new DOMException('Key already exists', 'ConstraintError')); return req;
      }
    }
    s.records.push({ key: ek, value: value });
    s.records.sort(function(a, b) { return _cmp(a.key, b.key); });
    this._tx._dirty = true; req._succeed(ek); return req;
  };
  _IDBObjectStore.prototype.get = function(query) {
    var req = new _IDBRequest(this, this._tx);
    var s = this._sd();
    if (!s) { req._fail(new DOMException('Store not found', 'NotFoundError')); return req; }
    var range = (query instanceof _IDBKeyRange) ? query : _IDBKeyRange.only(query);
    for (var i = 0; i < s.records.length; i++) {
      if (_inRange(s.records[i].key, range)) {
        req._succeed(_clone(s.records[i].value)); return req;
      }
    }
    req._succeed(undefined); return req;
  };
  _IDBObjectStore.prototype.getKey = function(query) {
    var req = new _IDBRequest(this, this._tx);
    var s = this._sd();
    if (!s) { req._fail(new DOMException('Store not found', 'NotFoundError')); return req; }
    var range = (query instanceof _IDBKeyRange) ? query : _IDBKeyRange.only(query);
    for (var i = 0; i < s.records.length; i++) {
      if (_inRange(s.records[i].key, range)) {
        req._succeed(s.records[i].key); return req;
      }
    }
    req._succeed(undefined); return req;
  };
  _IDBObjectStore.prototype.getAll = function(query, cnt) {
    var req = new _IDBRequest(this, this._tx);
    var s = this._sd();
    if (!s) { req._fail(new DOMException('Store not found', 'NotFoundError')); return req; }
    var range = (query !== undefined && query !== null)
      ? ((query instanceof _IDBKeyRange) ? query : _IDBKeyRange.only(query))
      : null;
    var out = [];
    for (var i = 0; i < s.records.length; i++) {
      if (_inRange(s.records[i].key, range)) {
        out.push(_clone(s.records[i].value));
        if (cnt !== undefined && out.length >= cnt) break;
      }
    }
    req._succeed(out); return req;
  };
  _IDBObjectStore.prototype.getAllKeys = function(query, cnt) {
    var req = new _IDBRequest(this, this._tx);
    var s = this._sd();
    if (!s) { req._fail(new DOMException('Store not found', 'NotFoundError')); return req; }
    var range = (query !== undefined && query !== null)
      ? ((query instanceof _IDBKeyRange) ? query : _IDBKeyRange.only(query))
      : null;
    var out = [];
    for (var i = 0; i < s.records.length; i++) {
      if (_inRange(s.records[i].key, range)) {
        out.push(s.records[i].key);
        if (cnt !== undefined && out.length >= cnt) break;
      }
    }
    req._succeed(out); return req;
  };
  _IDBObjectStore.prototype.delete = function(query) {
    var req = new _IDBRequest(this, this._tx);
    var s = this._sd();
    if (!s) { req._fail(new DOMException('Store not found', 'NotFoundError')); return req; }
    var range = (query instanceof _IDBKeyRange) ? query : _IDBKeyRange.only(query);
    s.records = s.records.filter(function(r) { return !_inRange(r.key, range); });
    this._tx._dirty = true; req._succeed(undefined); return req;
  };
  _IDBObjectStore.prototype.clear = function() {
    var req = new _IDBRequest(this, this._tx);
    var s = this._sd();
    if (!s) { req._fail(new DOMException('Store not found', 'NotFoundError')); return req; }
    s.records = []; this._tx._dirty = true; req._succeed(undefined); return req;
  };
  _IDBObjectStore.prototype.count = function(query) {
    var req = new _IDBRequest(this, this._tx);
    var s = this._sd();
    if (!s) { req._fail(new DOMException('Store not found', 'NotFoundError')); return req; }
    if (query === undefined) { req._succeed(s.records.length); return req; }
    var range = (query instanceof _IDBKeyRange) ? query : _IDBKeyRange.only(query);
    var c = 0;
    for (var i = 0; i < s.records.length; i++) { if (_inRange(s.records[i].key, range)) c++; }
    req._succeed(c); return req;
  };
  _IDBObjectStore.prototype.createIndex = function(name, keyPath, opts) {
    opts = opts || {};
    var def = { keyPath: keyPath, unique: !!opts.unique, multiEntry: !!opts.multiEntry };
    this._indexes[name] = def;
    var s = this._sd(); if (s) s.indexes[name] = def;
    return new _IDBIndex(this, name, def);
  };
  _IDBObjectStore.prototype.deleteIndex = function(name) {
    delete this._indexes[name];
    var s = this._sd(); if (s) delete s.indexes[name];
  };
  _IDBObjectStore.prototype.index = function(name) {
    var def = this._indexes[name];
    if (!def) throw new DOMException('Index not found: ' + name, 'NotFoundError');
    return new _IDBIndex(this, name, def);
  };
  _IDBObjectStore.prototype.openCursor = function(query, dir) {
    var req = new _IDBRequest(this, this._tx);
    var s = this._sd();
    if (!s) { req._fail(new DOMException('Store not found', 'NotFoundError')); return req; }
    var range = (query !== undefined && query !== null)
      ? ((query instanceof _IDBKeyRange) ? query : _IDBKeyRange.only(query))
      : null;
    var recs = [];
    for (var i = 0; i < s.records.length; i++) {
      if (_inRange(s.records[i].key, range))
        recs.push({ key: s.records[i].key, primaryKey: s.records[i].key, value: _clone(s.records[i].value) });
    }
    if (dir === 'prev' || dir === 'prevunique') recs.reverse();
    var c = new _IDBCursor(this, recs, dir || 'next', req, this._tx, this._name, false);
    c._advance(1); return req;
  };
  _IDBObjectStore.prototype.openKeyCursor = function(query, dir) {
    var req = new _IDBRequest(this, this._tx);
    var s = this._sd();
    if (!s) { req._fail(new DOMException('Store not found', 'NotFoundError')); return req; }
    var range = (query !== undefined && query !== null)
      ? ((query instanceof _IDBKeyRange) ? query : _IDBKeyRange.only(query))
      : null;
    var recs = [];
    for (var i = 0; i < s.records.length; i++) {
      if (_inRange(s.records[i].key, range))
        recs.push({ key: s.records[i].key, primaryKey: s.records[i].key });
    }
    if (dir === 'prev' || dir === 'prevunique') recs.reverse();
    var c = new _IDBCursor(this, recs, dir || 'next', req, this._tx, this._name, true);
    c._advance(1); return req;
  };

  // ---- IDBTransaction ----

  function _IDBTransaction(db, storeNames, mode) {
    this._db = db; this._storeNames = storeNames; this._mode = mode;
    this._dirty = false; this._aborted = false; this._committed = false;
    this.oncomplete = null; this.onerror = null; this.onabort = null;
    _mixEvents(this);
    // Snapshot stores for rollback on abort (only for readwrite/versionchange).
    if (mode === 'readwrite' || mode === 'versionchange') {
      var d = _idb[db._name];
      this._snapshot = d ? _clone(d.stores) : {};
    } else {
      this._snapshot = null;
    }
    // Auto-commit after current task completes (macrotask ensures all
    // microtask-based onsuccess callbacks have fired first).
    var self = this;
    setTimeout(function() { self._tryCommit(); }, 0);
  }
  Object.defineProperties(_IDBTransaction.prototype, {
    db: { get: function() { return this._db; } },
    mode: { get: function() { return this._mode; } },
    objectStoreNames: { get: function() { return _DOMStringList(this._storeNames); } },
    error: { get: function() { return null; } }
  });
  _IDBTransaction.prototype._getStoreData = function(name) {
    var d = _idb[this._db._name]; return d ? (d.stores[name] || null) : null;
  };
  _IDBTransaction.prototype.objectStore = function(name) {
    if (this._storeNames.indexOf(name) === -1)
      throw new DOMException('Store not in scope: ' + name, 'NotFoundError');
    var sd = this._getStoreData(name);
    if (!sd) throw new DOMException('Store not found: ' + name, 'NotFoundError');
    return new _IDBObjectStore(this, name, sd);
  };
  _IDBTransaction.prototype.abort = function() {
    if (this._aborted || this._committed) return;
    this._aborted = true;
    // Rollback: restore stores from snapshot taken at transaction start.
    if (this._snapshot) {
      var d = _idb[this._db._name];
      if (d) d.stores = this._snapshot;
    }
    var self = this;
    _async(function() { self.dispatchEvent(new _Event('abort')); });
  };
  _IDBTransaction.prototype._tryCommit = function() {
    if (this._aborted || this._committed) return;
    this._committed = true;
    if (this._dirty) _idbFlush();
    var self = this;
    _async(function() { self.dispatchEvent(new _Event('complete')); });
  };
  _IDBTransaction.prototype.commit = function() { this._tryCommit(); };

  // ---- IDBDatabase ----

  function _IDBDatabase(name, version) {
    this._name = name; this._version = version; this._closed = false;
    this.onclose = null; this.onversionchange = null;
    _mixEvents(this);
  }
  Object.defineProperties(_IDBDatabase.prototype, {
    name: { get: function() { return this._name; } },
    version: { get: function() { return this._version; } },
    objectStoreNames: {
      get: function() {
        var d = _idb[this._name];
        return _DOMStringList(d ? Object.keys(d.stores) : []);
      }
    }
  });
  _IDBDatabase.prototype.createObjectStore = function(name, opts) {
    opts = opts || {};
    var d = _idb[this._name]; if (!d) return null;
    d.stores[name] = {
      keyPath: opts.keyPath !== undefined ? opts.keyPath : null,
      autoIncrement: !!opts.autoIncrement,
      nextKey: 1, indexes: {}, records: []
    };
    // Expand the versionchange transaction scope to include the new store.
    var tx = this._versionChangeTx;
    if (tx && tx._storeNames.indexOf(name) === -1) tx._storeNames.push(name);
    return new _IDBObjectStore(tx, name, d.stores[name]);
  };
  _IDBDatabase.prototype.deleteObjectStore = function(name) {
    var d = _idb[this._name]; if (d) delete d.stores[name];
    var tx = this._versionChangeTx;
    if (tx) {
      var idx = tx._storeNames.indexOf(name);
      if (idx !== -1) tx._storeNames.splice(idx, 1);
    }
  };
  _IDBDatabase.prototype.transaction = function(storeNames, mode) {
    if (typeof storeNames === 'string') storeNames = [storeNames];
    if (storeNames instanceof _DOMStringList) {
      var arr = []; for (var i = 0; i < storeNames.length; i++) arr.push(storeNames[i]);
      storeNames = arr;
    }
    return new _IDBTransaction(this, storeNames, mode || 'readonly');
  };
  _IDBDatabase.prototype.close = function() { this._closed = true; };

  // ---- IDBFactory ----

  var _idbFactory = {
    open: function(name, version) {
      version = version !== undefined ? version : undefined;
      var req = new _IDBRequest(null, null);
      req.onupgradeneeded = null;

      _async(function() {
        var dbData = _idb[name];
        var oldVersion = dbData ? dbData.version : 0;
        var targetVersion = version !== undefined ? version : (oldVersion || 1);

        if (!dbData || targetVersion > oldVersion) {
          if (!dbData) { _idb[name] = { version: targetVersion, stores: {} }; dbData = _idb[name]; }
          else { dbData.version = targetVersion; }

          var db = new _IDBDatabase(name, targetVersion);
          var storeNames = Object.keys(dbData.stores);
          var tx = new _IDBTransaction(db, storeNames, 'versionchange');
          db._versionChangeTx = tx;
          req.result = db; req.transaction = tx;

          var evt = new _VersionChangeEvent('upgradeneeded', oldVersion, targetVersion);
          evt.target = req;
          if (req.onupgradeneeded) req.onupgradeneeded.call(req, evt);
          var lisUpgrade = req._listeners && req._listeners['upgradeneeded'];
          if (lisUpgrade) lisUpgrade.forEach(function(fn) { fn.call(req, evt); });

          tx._dirty = true; tx._tryCommit();
          db._versionChangeTx = null;
          req.readyState = 'done'; req.transaction = null;
          _async(function() { req.dispatchEvent(new _Event('success')); });
        } else {
          var db2 = new _IDBDatabase(name, dbData.version);
          req._succeed(db2);
        }
      });

      return req;
    },
    deleteDatabase: function(name) {
      var req = new _IDBRequest(null, null);
      var oldVersion = _idb[name] ? _idb[name].version : 0;
      delete _idb[name]; _idbFlush();
      _async(function() {
        req.readyState = 'done'; req.result = undefined;
        req.dispatchEvent(new _VersionChangeEvent('success', oldVersion, null));
      });
      return req;
    },
    databases: function() {
      return Promise.resolve(
        Object.keys(_idb).map(function(n) { return { name: n, version: _idb[n].version }; })
      );
    },
    cmp: function(a, b) { return _cmp(a, b); }
  };

  // ---- Expose globals ----

  try {
    Object.defineProperty(window, 'indexedDB', {
      get: function() { return _idbFactory; },
      configurable: true
    });
  } catch(e) {}
  window.IDBKeyRange = _IDBKeyRange;

})();
