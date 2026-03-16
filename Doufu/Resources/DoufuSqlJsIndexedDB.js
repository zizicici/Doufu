(function() {
  'use strict';

  // ======== IndexedDB persistence shim (sql.js backend) ========
  // Replaces window.indexedDB with a sql.js-backed implementation that
  // persists to AppData/indexedDB.sqlite via HTTP PUT/GET.

  var _ready = false, _db = null, _pendingOps = [];
  var _APPDATAURL = '__DOUFU_APPDATAURL__';

  function _whenReady(fn) {
    if (_ready) fn(); else _pendingOps.push(fn);
  }
  function _flushPending() {
    _ready = true;
    var ops = _pendingOps.splice(0);
    for (var i = 0; i < ops.length; i++) ops[i]();
  }

  // ---- Structured-clone-lite: preserves Date and binary types through JSON ----

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

  // Sentinel value included in every tagged object so that plain user objects
  // whose keys happen to start with __doufu are not misinterpreted by _reviver.
  var _TAG = '__doufuTag__';

  function _replacer(k, v) {
    var raw = this[k];
    if (raw === undefined && k !== '') return { __doufuUndef__: true, __doufuTag__: 1 };
    if (raw instanceof Date) return { __doufuDate__: raw.getTime(), __doufuTag__: 1 };
    if (raw instanceof ArrayBuffer)
      return { __doufuBuf__: _bufToB64(raw), __doufuType__: 'ArrayBuffer', __doufuTag__: 1 };
    if (raw instanceof DataView)
      return { __doufuBuf__: _bufToB64(raw.buffer), __doufuType__: 'DataView',
               __off__: raw.byteOffset, __len__: raw.byteLength, __doufuTag__: 1 };
    if (ArrayBuffer.isView(raw))
      return { __doufuBuf__: _bufToB64(raw.buffer), __doufuType__: raw.constructor.name,
               __off__: raw.byteOffset, __len__: raw.length, __doufuTag__: 1 };
    if (raw instanceof Map) return { __doufuMap__: Array.from(raw.entries()), __doufuTag__: 1 };
    if (raw instanceof Set) return { __doufuSet__: Array.from(raw), __doufuTag__: 1 };
    if (raw instanceof RegExp) return { __doufuRegExp__: raw.source, __flags__: raw.flags, __doufuTag__: 1 };
    if (raw instanceof Error)
      return { __doufuError__: raw.message, __errName__: raw.name, __errStack__: raw.stack || '', __doufuTag__: 1 };
    if (typeof ImageData !== 'undefined' && raw instanceof ImageData) {
      var pixBuf = raw.data.buffer.slice(raw.data.byteOffset, raw.data.byteOffset + raw.data.byteLength);
      return { __doufuImageData__: true, __data__: _bufToB64(pixBuf),
               __width__: raw.width, __height__: raw.height, __doufuTag__: 1 };
    }
    if (typeof raw === 'number') {
      if (raw !== raw) return { __doufuNaN__: true, __doufuTag__: 1 };
      if (raw === 0 && 1/raw === -Infinity) return { __doufuNegZero__: true, __doufuTag__: 1 };
      if (raw === Infinity) return { __doufuInf__: 1, __doufuTag__: 1 };
      if (raw === -Infinity) return { __doufuInf__: -1, __doufuTag__: 1 };
    }
    return v;
  }

  function _reviver(k, v) {
    if (v && typeof v === 'object' && v[_TAG] === 1) {
      if (typeof v.__doufuDate__ === 'number') return new Date(v.__doufuDate__);
      // Blob/File — check before generic __doufuBuf__ (both share that key)
      if (v.__doufuBlob__ && typeof v.__doufuBuf__ === 'string') {
        var bbuf = _b64ToBuf(v.__doufuBuf__);
        return new Blob([bbuf], { type: v.__blobType__ || '' });
      }
      if (v.__doufuFile__ && typeof v.__doufuBuf__ === 'string') {
        var fbuf = _b64ToBuf(v.__doufuBuf__);
        return new File([fbuf], v.__fileName__ || '', {
          type: v.__blobType__ || '',
          lastModified: v.__lastModified__ || Date.now()
        });
      }
      if (typeof v.__doufuBuf__ === 'string') {
        var buf = _b64ToBuf(v.__doufuBuf__);
        if (v.__doufuType__ === 'ArrayBuffer') return buf;
        if (v.__doufuType__ === 'DataView')
          return new DataView(buf, v.__off__ || 0, v.__len__ !== undefined ? v.__len__ : buf.byteLength);
        var Ctor = _typedArrayTypes[v.__doufuType__] || Uint8Array;
        return new Ctor(buf, v.__off__ || 0, v.__len__ !== undefined ? v.__len__ : undefined);
      }
      if (Array.isArray(v.__doufuMap__)) return new Map(v.__doufuMap__);
      if (Array.isArray(v.__doufuSet__)) return new Set(v.__doufuSet__);
      if (typeof v.__doufuRegExp__ === 'string') return new RegExp(v.__doufuRegExp__, v.__flags__ || '');
      if (typeof v.__doufuError__ === 'string') {
        var e = new Error(v.__doufuError__); e.name = v.__errName__ || 'Error'; return e;
      }
      if (v.__doufuImageData__ && typeof v.__data__ === 'string') {
        var imgBuf = _b64ToBuf(v.__data__);
        if (typeof ImageData !== 'undefined')
          return new ImageData(new Uint8ClampedArray(imgBuf), v.__width__, v.__height__);
        return v;
      }
      if (v.__doufuNaN__ === true) return NaN;
      if (v.__doufuNegZero__ === true) return -0;
      if (typeof v.__doufuInf__ === 'number') return v.__doufuInf__ > 0 ? Infinity : -Infinity;
    }
    return v;
  }

  function _restoreUndefined(obj) {
    if (obj === null || obj === undefined || typeof obj !== 'object') return obj;
    if (obj instanceof Date || obj instanceof RegExp || obj instanceof Error ||
        obj instanceof ArrayBuffer || ArrayBuffer.isView(obj) ||
        obj instanceof Map || obj instanceof Set ||
        (_hasBlobSupport && obj instanceof Blob)) return obj;
    if (Array.isArray(obj)) {
      for (var i = 0; i < obj.length; i++) {
        if (obj[i] && typeof obj[i] === 'object' && obj[i].__doufuUndef__ === true && obj[i][_TAG] === 1) {
          obj[i] = undefined;
        } else {
          _restoreUndefined(obj[i]);
        }
      }
      return obj;
    }
    var keys = Object.keys(obj);
    for (var j = 0; j < keys.length; j++) {
      var val = obj[keys[j]];
      if (val && typeof val === 'object' && val.__doufuUndef__ === true && val[_TAG] === 1) {
        obj[keys[j]] = undefined;
      } else {
        _restoreUndefined(val);
      }
    }
    return obj;
  }

  function _parseValue(json) {
    var parsed = JSON.parse(json, _reviver);
    if (json.indexOf('"__doufuUndef__"') !== -1) _restoreUndefined(parsed);
    return parsed;
  }

  function _clone(v) {
    var json;
    try {
      json = JSON.stringify(v, _replacer);
    } catch(e) {
      if (e instanceof TypeError && /circular|cyclic/i.test(e.message))
        throw new DOMException('The object could not be cloned (circular reference).', 'DataCloneError');
      throw e;
    }
    var parsed = JSON.parse(json, _reviver);
    if (json.indexOf('"__doufuUndef__"') !== -1) _restoreUndefined(parsed);
    return parsed;
  }

  // ---- Blob/File async preprocessing ----

  var _hasBlobSupport = typeof Blob !== 'undefined';

  function _hasBlobs(obj) {
    if (!_hasBlobSupport) return false;
    try { return _hasBlobsInner(obj, new Set()); } catch(e) { return false; }
  }

  function _hasBlobsInner(obj, seen) {
    if (obj === null || obj === undefined || typeof obj !== 'object') return false;
    if (obj instanceof Blob) return true;
    if (obj instanceof Date || obj instanceof RegExp || obj instanceof Error ||
        obj instanceof ArrayBuffer || ArrayBuffer.isView(obj) ||
        (typeof ImageData !== 'undefined' && obj instanceof ImageData)) return false;
    if (seen.has(obj)) return false;
    seen.add(obj);
    if (obj instanceof Map) {
      var mapHas = false;
      obj.forEach(function(v) { if (!mapHas && _hasBlobsInner(v, seen)) mapHas = true; });
      return mapHas;
    }
    if (obj instanceof Set) {
      var setHas = false;
      obj.forEach(function(v) { if (!setHas && _hasBlobsInner(v, seen)) setHas = true; });
      return setHas;
    }
    if (Array.isArray(obj)) {
      for (var i = 0; i < obj.length; i++) {
        if (_hasBlobsInner(obj[i], seen)) return true;
      }
      return false;
    }
    var keys = Object.keys(obj);
    for (var j = 0; j < keys.length; j++) {
      if (_hasBlobsInner(obj[keys[j]], seen)) return true;
    }
    return false;
  }

  function _extractBlobs(obj) {
    var blobs = [];
    var seen = new Set();
    var _hasFileSupport = typeof File !== 'undefined';

    function _walk(node) {
      if (node === null || node === undefined || typeof node !== 'object') return;
      if (seen.has(node)) return;
      if (_hasFileSupport && node instanceof File) { blobs.push(node); return; }
      if (node instanceof Blob) { blobs.push(node); return; }
      if (node instanceof Date || node instanceof RegExp || node instanceof Error ||
          node instanceof ArrayBuffer || ArrayBuffer.isView(node) ||
          (typeof ImageData !== 'undefined' && node instanceof ImageData)) return;
      seen.add(node);
      if (node instanceof Map) {
        node.forEach(function(v) { _walk(v); });
        return;
      }
      if (node instanceof Set) {
        node.forEach(function(v) { _walk(v); });
        return;
      }
      if (Array.isArray(node)) {
        for (var i = 0; i < node.length; i++) _walk(node[i]);
        return;
      }
      var keys = Object.keys(node);
      for (var j = 0; j < keys.length; j++) _walk(node[keys[j]]);
    }

    _walk(obj);

    // De-duplicate blobs (same instance may appear multiple times)
    var uniqueBlobs = [];
    var blobSet = new Set();
    for (var bi = 0; bi < blobs.length; bi++) {
      if (!blobSet.has(blobs[bi])) { blobSet.add(blobs[bi]); uniqueBlobs.push(blobs[bi]); }
    }

    return Promise.all(uniqueBlobs.map(function(b) {
      return b.arrayBuffer();
    })).then(function(buffers) {
      // Build blobTags map: blob instance → tagged object
      var blobTags = new Map();
      for (var i = 0; i < uniqueBlobs.length; i++) {
        var b64 = _bufToB64(buffers[i]);
        var blob = uniqueBlobs[i];
        if (_hasFileSupport && blob instanceof File) {
          blobTags.set(blob, { __doufuFile__: true, __doufuBuf__: b64,
            __blobType__: blob.type || '', __fileName__: blob.name || '',
            __lastModified__: blob.lastModified || Date.now(), __doufuTag__: 1 });
        } else {
          blobTags.set(blob, { __doufuBlob__: true, __doufuBuf__: b64,
            __blobType__: blob.type || '', __doufuTag__: 1 });
        }
      }
      function _blobReplacer(k, v) {
        var raw = this[k];
        if (blobTags.has(raw)) return blobTags.get(raw);
        return _replacer.call(this, k, v);
      }
      var json;
      try {
        json = JSON.stringify(obj, _blobReplacer);
      } catch(e) {
        if (e instanceof TypeError && /circular|cyclic/i.test(e.message))
          throw new DOMException('The object could not be cloned (circular reference).', 'DataCloneError');
        throw e;
      }
      // Revive non-blob types but keep blob/file as tagged objects for DB storage
      var cloned = JSON.parse(json, function(k2, v2) {
        if (v2 && typeof v2 === 'object' && (v2.__doufuBlob__ || v2.__doufuFile__)) return v2;
        return _reviver.call(this, k2, v2);
      });
      if (json.indexOf('"__doufuUndef__"') !== -1) _restoreUndefined(cloned);
      return cloned;
    });
  }

  // ---- Key validation ----

  function _validateKey(key) {
    if (key === undefined || key === null) throw new DOMException('Key is not valid', 'DataError');
    var t = typeof key;
    if (t === 'boolean' || t === 'function' || t === 'symbol') throw new DOMException('Key is not valid', 'DataError');
    if (t === 'number') {
      if (isNaN(key)) throw new DOMException('Key is not valid', 'DataError');
      return;
    }
    if (t === 'string') return;
    if (key instanceof Date) {
      if (isNaN(key.getTime())) throw new DOMException('Key is not valid', 'DataError');
      return;
    }
    if (key instanceof ArrayBuffer || ArrayBuffer.isView(key)) return;
    if (Array.isArray(key)) {
      for (var i = 0; i < key.length; i++) _validateKey(key[i]);
      return;
    }
    throw new DOMException('Key is not valid', 'DataError');
  }

  // ---- IDB Key binary encoding (preserves spec sort order via BLOB comparison) ----
  // Type prefixes: 0x01=number, 0x02=date, 0x03=string, 0x04=binary, 0x05=array

  function _encodeKey(key) {
    if (typeof key === 'number') {
      var buf = new ArrayBuffer(9);
      var view = new DataView(buf);
      view.setUint8(0, 0x01);
      view.setFloat64(1, key);
      // Sign-flip for correct BLOB sort: positive → flip sign bit; negative → flip all bits
      var hi = view.getUint8(1);
      if (hi & 0x80) {
        // Negative: flip all 8 bytes
        for (var i = 1; i <= 8; i++) view.setUint8(i, view.getUint8(i) ^ 0xFF);
      } else {
        // Positive (or zero): flip sign bit
        view.setUint8(1, hi ^ 0x80);
      }
      return new Uint8Array(buf);
    }
    if (key instanceof Date) {
      var ts = key.getTime();
      var buf2 = new ArrayBuffer(9);
      var view2 = new DataView(buf2);
      view2.setUint8(0, 0x02);
      view2.setFloat64(1, ts);
      var hi2 = view2.getUint8(1);
      if (hi2 & 0x80) {
        for (var j = 1; j <= 8; j++) view2.setUint8(j, view2.getUint8(j) ^ 0xFF);
      } else {
        view2.setUint8(1, hi2 ^ 0x80);
      }
      return new Uint8Array(buf2);
    }
    if (typeof key === 'string') {
      var encoded = new TextEncoder().encode(key);
      var result = new Uint8Array(1 + encoded.length);
      result[0] = 0x03;
      result.set(encoded, 1);
      return result;
    }
    if (key instanceof ArrayBuffer || ArrayBuffer.isView(key)) {
      var bytes = key instanceof ArrayBuffer ? new Uint8Array(key) : new Uint8Array(key.buffer, key.byteOffset, key.byteLength);
      var result2 = new Uint8Array(1 + bytes.length);
      result2[0] = 0x04;
      result2.set(bytes, 1);
      return result2;
    }
    if (Array.isArray(key)) {
      var parts = [];
      var totalLen = 1; // prefix byte
      for (var ai = 0; ai < key.length; ai++) {
        var part = _encodeKey(key[ai]);
        // 2-byte length prefix + encoded part
        totalLen += 2 + part.length;
        parts.push(part);
      }
      var result3 = new Uint8Array(totalLen);
      result3[0] = 0x05;
      var offset = 1;
      for (var bi = 0; bi < parts.length; bi++) {
        var p = parts[bi];
        result3[offset] = (p.length >> 8) & 0xFF;
        result3[offset + 1] = p.length & 0xFF;
        result3.set(p, offset + 2);
        offset += 2 + p.length;
      }
      return result3;
    }
    // Fallback: treat as string
    return _encodeKey(String(key));
  }

  function _decodeKey(buf) {
    var arr = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
    if (arr.length === 0) return undefined;
    var type = arr[0];
    if (type === 0x01 || type === 0x02) {
      var view = new DataView(arr.buffer, arr.byteOffset, arr.byteLength);
      // Undo sign-flip
      var tmp = new Uint8Array(8);
      for (var i = 0; i < 8; i++) tmp[i] = arr[1 + i];
      if (tmp[0] & 0x80) {
        // Was positive: flip sign bit back
        tmp[0] ^= 0x80;
      } else {
        // Was negative: flip all bits back
        for (var j = 0; j < 8; j++) tmp[j] ^= 0xFF;
      }
      var dv = new DataView(tmp.buffer);
      var val = dv.getFloat64(0);
      return type === 0x02 ? new Date(val) : val;
    }
    if (type === 0x03) {
      return new TextDecoder().decode(arr.subarray(1));
    }
    if (type === 0x04) {
      return arr.slice(1).buffer;
    }
    if (type === 0x05) {
      var parts = [];
      var offset = 1;
      while (offset < arr.length) {
        var len = (arr[offset] << 8) | arr[offset + 1];
        offset += 2;
        parts.push(_decodeKey(arr.subarray(offset, offset + len)));
        offset += len;
      }
      return parts;
    }
    return undefined;
  }

  function _keyToBlob(key) {
    var encoded = _encodeKey(key);
    // Convert Uint8Array to array of numbers for sql.js binding
    return Array.from(encoded);
  }

  function _blobToKey(blob) {
    if (!blob) return undefined;
    var arr = blob instanceof Uint8Array ? blob : new Uint8Array(blob);
    return _decodeKey(arr);
  }

  // ---- JS-level key comparison (for non-SQL operations) ----

  function _keyType(k) {
    if (typeof k === 'number') return 1;
    if (k instanceof Date) return 2;
    if (typeof k === 'string') return 3;
    if (k instanceof ArrayBuffer || ArrayBuffer.isView(k)) return 4;
    if (Array.isArray(k)) return 5;
    return 0;
  }

  function _cmp(a, b) {
    var ta = _keyType(a), tb = _keyType(b);
    if (ta !== tb) return ta < tb ? -1 : 1;
    if (ta === 1) return a < b ? -1 : a > b ? 1 : 0;
    if (ta === 2) { var na = +a, nb = +b; return na < nb ? -1 : na > nb ? 1 : 0; }
    if (ta === 3) return a < b ? -1 : a > b ? 1 : 0;
    if (ta === 4) {
      var ab = a instanceof ArrayBuffer ? new Uint8Array(a) : new Uint8Array(a.buffer || a, a.byteOffset || 0, a.byteLength || a.length);
      var bb = b instanceof ArrayBuffer ? new Uint8Array(b) : new Uint8Array(b.buffer || b, b.byteOffset || 0, b.byteLength || b.length);
      for (var j = 0; j < Math.min(ab.length, bb.length); j++) {
        if (ab[j] < bb[j]) return -1;
        if (ab[j] > bb[j]) return 1;
      }
      return ab.length < bb.length ? -1 : ab.length > bb.length ? 1 : 0;
    }
    if (ta === 5) {
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

  // ---- SQL Schema ----

  function _initSchema(db) {
    db.run('PRAGMA foreign_keys = ON');
    db.run('CREATE TABLE IF NOT EXISTS databases (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE NOT NULL, version INTEGER NOT NULL DEFAULT 0)');
    db.run('CREATE TABLE IF NOT EXISTS object_stores (id INTEGER PRIMARY KEY AUTOINCREMENT, database_id INTEGER NOT NULL REFERENCES databases(id) ON DELETE CASCADE, name TEXT NOT NULL, key_path TEXT, auto_increment INTEGER NOT NULL DEFAULT 0, current_key INTEGER NOT NULL DEFAULT 0, UNIQUE(database_id, name))');
    db.run('CREATE TABLE IF NOT EXISTS indexes (id INTEGER PRIMARY KEY AUTOINCREMENT, object_store_id INTEGER NOT NULL REFERENCES object_stores(id) ON DELETE CASCADE, name TEXT NOT NULL, key_path TEXT NOT NULL, unique_flag INTEGER NOT NULL DEFAULT 0, multi_entry INTEGER NOT NULL DEFAULT 0, UNIQUE(object_store_id, name))');
    db.run('CREATE TABLE IF NOT EXISTS records (object_store_id INTEGER NOT NULL REFERENCES object_stores(id) ON DELETE CASCADE, key BLOB NOT NULL, value TEXT NOT NULL, PRIMARY KEY(object_store_id, key))');
    db.run('CREATE TABLE IF NOT EXISTS index_records (index_id INTEGER NOT NULL, key BLOB NOT NULL, primary_key BLOB NOT NULL, FOREIGN KEY(index_id) REFERENCES indexes(id) ON DELETE CASCADE)');
    db.run('CREATE INDEX IF NOT EXISTS idx_index_records ON index_records(index_id, key, primary_key)');
  }

  // ---- SQL helpers ----

  function _getDbId(name) {
    var rows = _db.exec('SELECT id, version FROM databases WHERE name = ?', [name]);
    if (rows.length > 0 && rows[0].values.length > 0) {
      return { id: rows[0].values[0][0], version: rows[0].values[0][1] };
    }
    return null;
  }

  function _getStoreId(dbId, storeName) {
    var rows = _db.exec('SELECT id, key_path, auto_increment, current_key FROM object_stores WHERE database_id = ? AND name = ?', [dbId, storeName]);
    if (rows.length > 0 && rows[0].values.length > 0) {
      var r = rows[0].values[0];
      return { id: r[0], keyPath: _parseStoredKeyPath(r[1]), autoIncrement: !!r[2], currentKey: r[3] };
    }
    return null;
  }

  // Index keyPath is stored as JSON to support compound (array) keyPaths.
  function _parseStoredKeyPath(stored) {
    if (stored === null || stored === undefined) return null;
    try { return JSON.parse(stored); } catch(e) { return stored; }
  }

  function _serializeKeyPath(keyPath) {
    return JSON.stringify(keyPath);
  }

  function _getIndexId(storeId, indexName) {
    var rows = _db.exec('SELECT id, key_path, unique_flag, multi_entry FROM indexes WHERE object_store_id = ? AND name = ?', [storeId, indexName]);
    if (rows.length > 0 && rows[0].values.length > 0) {
      var r = rows[0].values[0];
      return { id: r[0], keyPath: _parseStoredKeyPath(r[1]), unique: !!r[2], multiEntry: !!r[3] };
    }
    return null;
  }

  function _getAllIndexesForStore(storeId) {
    var rows = _db.exec('SELECT id, name, key_path, unique_flag, multi_entry FROM indexes WHERE object_store_id = ?', [storeId]);
    var result = [];
    if (rows.length > 0) {
      for (var i = 0; i < rows[0].values.length; i++) {
        var r = rows[0].values[i];
        result.push({ id: r[0], name: r[1], keyPath: _parseStoredKeyPath(r[2]), unique: !!r[3], multiEntry: !!r[4] });
      }
    }
    return result;
  }

  // Update index_records for a record being inserted/updated
  function _updateIndexRecords(storeId, primaryKeyBlob, value) {
    var indexes = _getAllIndexesForStore(storeId);
    for (var i = 0; i < indexes.length; i++) {
      var idx = indexes[i];
      // Delete old index entries for this primary key
      _db.run('DELETE FROM index_records WHERE index_id = ? AND primary_key = ?', [idx.id, primaryKeyBlob]);
      var ik = _getByKeyPath(value, idx.keyPath);
      if (ik === undefined) continue;
      if (idx.multiEntry && Array.isArray(ik)) {
        var _seen = {};
        for (var j = 0; j < ik.length; j++) {
          if (ik[j] === undefined) continue;
          var ikBlob = _keyToBlob(ik[j]);
          var ikKey = String(ikBlob);
          if (_seen[ikKey]) continue;
          _seen[ikKey] = true;
          _db.run('INSERT INTO index_records (index_id, key, primary_key) VALUES (?, ?, ?)',
            [idx.id, ikBlob, primaryKeyBlob]);
        }
      } else {
        _db.run('INSERT INTO index_records (index_id, key, primary_key) VALUES (?, ?, ?)',
          [idx.id, _keyToBlob(ik), primaryKeyBlob]);
      }
    }
  }

  // ---- Persistence (debounced) ----

  var _flushTimer = null;
  function _schedulePersist() {
    if (_flushTimer) clearTimeout(_flushTimer);
    _flushTimer = setTimeout(_doPersist, 80);
  }
  function _doPersist() {
    _flushTimer = null;
    if (!_db) return;
    var data = _db.export();
    fetch(_APPDATAURL + '/indexedDB.sqlite', { method: 'PUT', body: data })
      .catch(function(e) { console.error('[Doufu] IDB persist failed:', e); });
  }
  // Synchronous persist for unload events — guarantees data is written before
  // the page is torn down. Uses sync XMLHttpRequest because async fetch can be
  // cancelled by WKWebView during navigation.
  function _doPersistSync() {
    if (!_db) return;
    try {
      var data = _db.export();
      var xhr = new XMLHttpRequest();
      xhr.open('PUT', _APPDATAURL + '/indexedDB.sqlite', false);
      xhr.send(data);
    } catch(e) {
      // Sync XHR blocked — fall back to async (best-effort)
      _doPersist();
    }
  }

  if (typeof window !== 'undefined' && typeof window.addEventListener === 'function') {
    var _flushBeforeUnload = function() {
      if (_flushTimer) { clearTimeout(_flushTimer); _flushTimer = null; }
      _doPersistSync();
    };
    window.addEventListener('beforeunload', _flushBeforeUnload);
    window.addEventListener('pagehide', _flushBeforeUnload);
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

  // Build SQL WHERE clause fragments for key range queries
  function _rangeToSQL(range, paramOffset) {
    if (!range) return { where: '', params: [] };
    var clauses = [], params = [];
    if (range._lower !== undefined) {
      var op = range._lowerOpen ? '>' : '>=';
      clauses.push('key ' + op + ' ?');
      params.push(_keyToBlob(range._lower));
    }
    if (range._upper !== undefined) {
      var op2 = range._upperOpen ? '<' : '<=';
      clauses.push('key ' + op2 + ' ?');
      params.push(_keyToBlob(range._upper));
    }
    return { where: clauses.length > 0 ? ' AND ' + clauses.join(' AND ') : '', params: params };
  }

  function _indexRangeToSQL(range) {
    if (!range) return { where: '', params: [] };
    var clauses = [], params = [];
    if (range._lower !== undefined) {
      var op = range._lowerOpen ? '>' : '>=';
      clauses.push('ir.key ' + op + ' ?');
      params.push(_keyToBlob(range._lower));
    }
    if (range._upper !== undefined) {
      var op2 = range._upperOpen ? '<' : '<=';
      clauses.push('ir.key ' + op2 + ' ?');
      params.push(_keyToBlob(range._upper));
    }
    return { where: clauses.length > 0 ? ' AND ' + clauses.join(' AND ') : '', params: params };
  }

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

  function _async(fn) { Promise.resolve().then(fn); }

  // ---- IDBRequest ----

  function _IDBRequest(source, transaction) {
    this.result = undefined; this.error = null;
    this.source = source || null; this.transaction = transaction || null;
    this.readyState = 'pending';
    this.onsuccess = null; this.onerror = null;
    _mixEvents(this);
    if (transaction) transaction._pendingRequests++;
  }
  _IDBRequest.prototype._succeed = function(result) {
    this.readyState = 'done'; this.result = result;
    var self = this;
    _async(function() {
      self.dispatchEvent(new _Event('success'));
      if (self.transaction) {
        self.transaction._pendingRequests--;
        self.transaction._scheduleCommit();
      }
    });
  };
  _IDBRequest.prototype._fail = function(err) {
    this.readyState = 'done'; this.error = err;
    if (this.transaction) this.transaction._error = err;
    var self = this;
    _async(function() {
      var evt = new _Event('error');
      evt.cancelable = true;
      self.dispatchEvent(evt);
      // Bubble error: request → transaction → database (IDB spec)
      if (self.transaction && !evt.defaultPrevented) {
        var txEvt = new _Event('error');
        self.transaction.dispatchEvent(txEvt);
        if (!txEvt.defaultPrevented && self.transaction._db) {
          self.transaction._db.dispatchEvent(new _Event('error'));
        }
        self.transaction.abort();
      }
      if (self.transaction) {
        self.transaction._pendingRequests--;
        self.transaction._scheduleCommit();
      }
    });
  };

  // ---- IDBCursor / IDBCursorWithValue ----

  function _IDBCursor(source, records, direction, request, tx, storeId, keysOnly) {
    this._source = source; this._records = records;
    this._direction = direction || 'next'; this._request = request;
    this._tx = tx; this._storeId = storeId; this._keysOnly = keysOnly;
    this._pos = -1;
    this.key = undefined; this.primaryKey = undefined;
    if (!keysOnly) this.value = undefined;
  }
  Object.defineProperties(_IDBCursor.prototype, {
    direction: { get: function() { return this._direction; } },
    source: { get: function() { return this._source; } },
    request: { get: function() { return this._request; } }
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
    _async(function() {
      self._gotContinue = false;
      self._request.dispatchEvent(new _Event('success'));
      // If onsuccess didn't call continue/advance, the cursor request is done
      if (!self._gotContinue && self._tx) {
        self._tx._pendingRequests--;
        self._tx._scheduleCommit();
      }
    });
  };
  _IDBCursor.prototype.continue = function(key) {
    this._gotContinue = true;
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
  _IDBCursor.prototype.advance = function(n) { this._gotContinue = true; this._advance(n); };
  _IDBCursor.prototype.continuePrimaryKey = function(key, primaryKey) {
    this._gotContinue = true;
    if (this._direction !== 'next' && this._direction !== 'prev')
      throw new DOMException('continuePrimaryKey requires next or prev direction', 'InvalidAccessError');
    var fwd = this._direction === 'next';
    while (this._pos + 1 < this._records.length) {
      var r = this._records[this._pos + 1];
      var ck = _cmp(r.key, key);
      if (fwd) {
        if (ck > 0 || (ck === 0 && _cmp(r.primaryKey, primaryKey) >= 0)) break;
      } else {
        if (ck < 0 || (ck === 0 && _cmp(r.primaryKey, primaryKey) <= 0)) break;
      }
      this._pos++;
    }
    this._advance(1);
  };

  // Deduplicate records for nextunique/prevunique cursor directions.
  // Keeps only the first record per key (records are already sorted).
  function _deduplicateByKey(recs) {
    var seen = [], out = [];
    for (var i = 0; i < recs.length; i++) {
      var dominated = false;
      for (var j = 0; j < seen.length; j++) {
        if (_cmp(recs[i].key, seen[j]) === 0) { dominated = true; break; }
      }
      if (!dominated) { seen.push(recs[i].key); out.push(recs[i]); }
    }
    return out;
  }
  _IDBCursor.prototype.update = function(value) {
    if (this._tx._aborted || this._tx._committed)
      throw new DOMException('Transaction is not active', 'TransactionInactiveError');
    if (this._tx._mode === 'readonly')
      throw new DOMException('Transaction is readonly', 'ReadOnlyError');
    if (this._keysOnly) throw new DOMException('', 'InvalidStateError');
    var req = new _IDBRequest(this._source, this._tx);
    var pk = this.primaryKey;
    var pkBlob = _keyToBlob(pk);
    var self = this;

    function _doUpdate(cloned) {
      var valueJSON = JSON.stringify(cloned, _replacer);
      _db.run('UPDATE records SET value = ? WHERE object_store_id = ? AND key = ?',
        [valueJSON, self._storeId, pkBlob]);
      _updateIndexRecords(self._storeId, pkBlob, cloned);
      self.value = _clone(cloned);
      self._records[self._pos].value = self.value;
      self._tx._dirty = true;
      req._succeed(pk);
    }

    if (_hasBlobs(value)) {
      _extractBlobs(value).then(_doUpdate).catch(function(e) {
        req._fail(new DOMException(e.message || 'Clone failed', 'DataCloneError'));
      });
    } else {
      try { _doUpdate(_clone(value)); } catch(e) {
        req._fail(e instanceof DOMException ? e : new DOMException(e.message || 'Clone failed', 'DataCloneError'));
      }
    }
    return req;
  };
  _IDBCursor.prototype.delete = function() {
    if (this._tx._aborted || this._tx._committed)
      throw new DOMException('Transaction is not active', 'TransactionInactiveError');
    if (this._tx._mode === 'readonly')
      throw new DOMException('Transaction is readonly', 'ReadOnlyError');
    var req = new _IDBRequest(this._source, this._tx);
    var pk = this.primaryKey;
    var pkBlob = _keyToBlob(pk);
    _db.run('DELETE FROM records WHERE object_store_id = ? AND key = ?',
      [this._storeId, pkBlob]);
    // Index records will be cleaned up by the index_records FK or manually
    var indexes = _getAllIndexesForStore(this._storeId);
    for (var i = 0; i < indexes.length; i++) {
      _db.run('DELETE FROM index_records WHERE index_id = ? AND primary_key = ?',
        [indexes[i].id, pkBlob]);
    }
    this._tx._dirty = true;
    req._succeed(undefined);
    return req;
  };

  // ---- IDBIndex ----

  function _IDBIndex(store, name, indexInfo) {
    this._store = store; this._name = name;
    this._indexId = indexInfo.id;
    this._keyPath = indexInfo.keyPath; this._unique = !!indexInfo.unique;
    this._multiEntry = !!indexInfo.multiEntry;
  }
  Object.defineProperties(_IDBIndex.prototype, {
    name: {
      get: function() { return this._name; },
      set: function(newName) {
        if (!this._store._tx || this._store._tx._mode !== 'versionchange')
          throw new DOMException('Can only rename during versionchange', 'InvalidStateError');
        _db.run('UPDATE indexes SET name = ? WHERE id = ?', [newName, this._indexId]);
        this._name = newName;
      }
    },
    keyPath: { get: function() { return this._keyPath; } },
    unique: { get: function() { return this._unique; } },
    multiEntry: { get: function() { return this._multiEntry; } },
    objectStore: { get: function() { return this._store; } }
  });

  _IDBIndex.prototype._checkActive = function() {
    if (this._store._tx._aborted || this._store._tx._committed)
      throw new DOMException('Transaction is not active', 'TransactionInactiveError');
  };

  _IDBIndex.prototype._getRecords = function(query) {
    var range = (query instanceof _IDBKeyRange) ? query
      : (query !== undefined && query !== null ? _IDBKeyRange.only(query) : null);
    var rng = _indexRangeToSQL(range);
    var sql = 'SELECT ir.key, ir.primary_key, r.value FROM index_records ir ' +
              'JOIN records r ON r.object_store_id = ? AND r.key = ir.primary_key ' +
              'WHERE ir.index_id = ?' + rng.where + ' ORDER BY ir.key, ir.primary_key';
    var params = [this._store._storeId, this._indexId].concat(rng.params);
    var rows = _db.exec(sql, params);
    var out = [];
    if (rows.length > 0) {
      for (var i = 0; i < rows[0].values.length; i++) {
        var row = rows[0].values[i];
        out.push({
          key: _blobToKey(row[0]),
          primaryKey: _blobToKey(row[1]),
          value: _parseValue(row[2])
        });
      }
    }
    return out;
  };

  _IDBIndex.prototype.get = function(q) {
    this._checkActive();
    var req = new _IDBRequest(this, this._store._tx);
    var recs = this._getRecords(q);
    req._succeed(recs.length > 0 ? _clone(recs[0].value) : undefined);
    return req;
  };
  _IDBIndex.prototype.getKey = function(q) {
    this._checkActive();
    var req = new _IDBRequest(this, this._store._tx);
    var recs = this._getRecords(q);
    req._succeed(recs.length > 0 ? recs[0].primaryKey : undefined);
    return req;
  };
  _IDBIndex.prototype.getAll = function(q, cnt) {
    this._checkActive();
    var req = new _IDBRequest(this, this._store._tx);
    var recs = this._getRecords(q);
    if (cnt !== undefined) recs = recs.slice(0, cnt);
    req._succeed(recs.map(function(r) { return _clone(r.value); }));
    return req;
  };
  _IDBIndex.prototype.getAllKeys = function(q, cnt) {
    this._checkActive();
    var req = new _IDBRequest(this, this._store._tx);
    var recs = this._getRecords(q);
    if (cnt !== undefined) recs = recs.slice(0, cnt);
    req._succeed(recs.map(function(r) { return r.primaryKey; }));
    return req;
  };
  _IDBIndex.prototype.count = function(q) {
    this._checkActive();
    var req = new _IDBRequest(this, this._store._tx);
    req._succeed(this._getRecords(q).length);
    return req;
  };
  _IDBIndex.prototype.openCursor = function(q, dir) {
    this._checkActive();
    var req = new _IDBRequest(this, this._store._tx);
    var recs = this._getRecords(q);
    if (dir === 'prev' || dir === 'prevunique') recs.reverse();
    if (dir === 'nextunique' || dir === 'prevunique') recs = _deduplicateByKey(recs);
    var c = new _IDBCursor(this, recs, dir || 'next', req, this._store._tx, this._store._storeId, false);
    c._advance(1); return req;
  };
  _IDBIndex.prototype.openKeyCursor = function(q, dir) {
    this._checkActive();
    var req = new _IDBRequest(this, this._store._tx);
    var recs = this._getRecords(q);
    if (dir === 'prev' || dir === 'prevunique') recs.reverse();
    if (dir === 'nextunique' || dir === 'prevunique') recs = _deduplicateByKey(recs);
    var c = new _IDBCursor(this, recs, dir || 'next', req, this._store._tx, this._store._storeId, true);
    c._advance(1); return req;
  };

  // ---- IDBObjectStore ----

  function _IDBObjectStore(tx, name, storeInfo, dbId) {
    this._tx = tx; this._name = name;
    this._storeId = storeInfo.id;
    this._keyPath = storeInfo.keyPath;
    this._autoIncrement = storeInfo.autoIncrement;
    this._dbId = dbId;
  }
  Object.defineProperties(_IDBObjectStore.prototype, {
    name: {
      get: function() { return this._name; },
      set: function(newName) {
        if (!this._tx || this._tx._mode !== 'versionchange')
          throw new DOMException('Can only rename during versionchange', 'InvalidStateError');
        _db.run('UPDATE object_stores SET name = ? WHERE id = ?', [newName, this._storeId]);
        var idx = this._tx._storeNames.indexOf(this._name);
        if (idx !== -1) this._tx._storeNames[idx] = newName;
        this._name = newName;
      }
    },
    keyPath: { get: function() { return this._keyPath; } },
    autoIncrement: { get: function() { return this._autoIncrement; } },
    indexNames: {
      get: function() {
        var rows = _db.exec('SELECT name FROM indexes WHERE object_store_id = ?', [this._storeId]);
        var names = [];
        if (rows.length > 0) {
          for (var i = 0; i < rows[0].values.length; i++) names.push(rows[0].values[i][0]);
        }
        return _DOMStringList(names);
      }
    },
    transaction: { get: function() { return this._tx; } }
  });

  _IDBObjectStore.prototype._checkActive = function() {
    if (this._tx._aborted || this._tx._committed)
      throw new DOMException('Transaction is not active', 'TransactionInactiveError');
  };
  _IDBObjectStore.prototype._checkWrite = function() {
    this._checkActive();
    if (this._tx._mode === 'readonly')
      throw new DOMException('Transaction is readonly', 'ReadOnlyError');
  };

  _IDBObjectStore.prototype._resolveKey = function(value, key) {
    var ek = key;
    if (this._keyPath) {
      ek = _getByKeyPath(value, this._keyPath);
      if (ek === undefined && this._autoIncrement) {
        var rows = _db.exec('SELECT current_key FROM object_stores WHERE id = ?', [this._storeId]);
        var ck = (rows.length > 0 && rows[0].values.length > 0) ? rows[0].values[0][0] : 0;
        ek = ck + 1;
        _db.run('UPDATE object_stores SET current_key = ? WHERE id = ?', [ek, this._storeId]);
        _setByKeyPath(value, this._keyPath, ek);
      }
    } else if (ek === undefined && this._autoIncrement) {
      var rows2 = _db.exec('SELECT current_key FROM object_stores WHERE id = ?', [this._storeId]);
      var ck2 = (rows2.length > 0 && rows2[0].values.length > 0) ? rows2[0].values[0][0] : 0;
      ek = ck2 + 1;
      _db.run('UPDATE object_stores SET current_key = ? WHERE id = ?', [ek, this._storeId]);
    }
    return ek;
  };

  // Check unique index constraints before insert/update
  _IDBObjectStore.prototype._checkUnique = function(value, primaryKeyBlob) {
    var indexes = _getAllIndexesForStore(this._storeId);
    for (var i = 0; i < indexes.length; i++) {
      if (!indexes[i].unique) continue;
      var ik = _getByKeyPath(value, indexes[i].keyPath);
      if (ik === undefined) continue;
      var ikBlob = _keyToBlob(ik);
      var sql = 'SELECT primary_key FROM index_records WHERE index_id = ? AND key = ?';
      var rows = _db.exec(sql, [indexes[i].id, ikBlob]);
      if (rows.length > 0) {
        for (var j = 0; j < rows[0].values.length; j++) {
          var existingPK = rows[0].values[j][0];
          // Compare as byte arrays
          if (primaryKeyBlob) {
            var a = primaryKeyBlob instanceof Array ? primaryKeyBlob : Array.from(primaryKeyBlob);
            var b = existingPK instanceof Uint8Array ? Array.from(existingPK) : (existingPK instanceof Array ? existingPK : []);
            if (a.length === b.length) {
              var same = true;
              for (var k = 0; k < a.length; k++) { if (a[k] !== b[k]) { same = false; break; } }
              if (same) continue; // Same primary key — ok for update
            }
          }
          return 'Unique index "' + indexes[i].name + '" constraint violated';
        }
      }
    }
    return null;
  };

  _IDBObjectStore.prototype.put = function(value, key) {
    this._checkWrite();
    if (this._keyPath !== null && key !== undefined)
      throw new DOMException('A key was provided for an object store with a key path', 'DataError');
    var req = new _IDBRequest(this, this._tx);
    var self = this;

    function _doPut(cloned) {
      var ek = self._resolveKey(cloned, key);
      if (ek === undefined) { req._fail(new DOMException('No key provided', 'DataError')); return; }
      try { _validateKey(ek); } catch(e) { req._fail(e); return; }
      var pkBlob = _keyToBlob(ek);
      var uErr = self._checkUnique(cloned, pkBlob);
      if (uErr) { req._fail(new DOMException(uErr, 'ConstraintError')); return; }
      var valueJSON = JSON.stringify(cloned, _replacer);
      _db.run('INSERT OR REPLACE INTO records (object_store_id, key, value) VALUES (?, ?, ?)',
        [self._storeId, pkBlob, valueJSON]);
      _updateIndexRecords(self._storeId, pkBlob, cloned);
      self._tx._dirty = true;
      req._succeed(ek);
    }

    if (_hasBlobs(value)) {
      // Known limitation: mixing blob and non-blob writes to the same key
      // in a single transaction may cause ordering issues because blob
      // extraction is async while non-blob writes are synchronous.
      _extractBlobs(value).then(_doPut).catch(function(e) {
        req._fail(new DOMException(e.message || 'Clone failed', 'DataCloneError'));
      });
    } else {
      try { _doPut(_clone(value)); } catch(e) {
        req._fail(e instanceof DOMException ? e : new DOMException(e.message || 'Clone failed', 'DataCloneError'));
      }
    }
    return req;
  };

  _IDBObjectStore.prototype.add = function(value, key) {
    this._checkWrite();
    if (this._keyPath !== null && key !== undefined)
      throw new DOMException('A key was provided for an object store with a key path', 'DataError');
    var req = new _IDBRequest(this, this._tx);
    var self = this;

    function _doAdd(cloned) {
      var ek = self._resolveKey(cloned, key);
      if (ek === undefined) { req._fail(new DOMException('No key provided', 'DataError')); return; }
      try { _validateKey(ek); } catch(e) { req._fail(e); return; }
      var pkBlob = _keyToBlob(ek);
      // Check for existing record
      var existing = _db.exec('SELECT 1 FROM records WHERE object_store_id = ? AND key = ?', [self._storeId, pkBlob]);
      if (existing.length > 0 && existing[0].values.length > 0) {
        req._fail(new DOMException('Key already exists', 'ConstraintError')); return;
      }
      var uErr = self._checkUnique(cloned, undefined);
      if (uErr) { req._fail(new DOMException(uErr, 'ConstraintError')); return; }
      var valueJSON = JSON.stringify(cloned, _replacer);
      _db.run('INSERT INTO records (object_store_id, key, value) VALUES (?, ?, ?)',
        [self._storeId, pkBlob, valueJSON]);
      _updateIndexRecords(self._storeId, pkBlob, cloned);
      self._tx._dirty = true;
      req._succeed(ek);
    }

    if (_hasBlobs(value)) {
      _extractBlobs(value).then(_doAdd).catch(function(e) {
        req._fail(new DOMException(e.message || 'Clone failed', 'DataCloneError'));
      });
    } else {
      try { _doAdd(_clone(value)); } catch(e) {
        req._fail(e instanceof DOMException ? e : new DOMException(e.message || 'Clone failed', 'DataCloneError'));
      }
    }
    return req;
  };

  _IDBObjectStore.prototype.get = function(query) {
    this._checkActive();
    var req = new _IDBRequest(this, this._tx);
    var range = (query instanceof _IDBKeyRange) ? query : _IDBKeyRange.only(query);
    var rng = _rangeToSQL(range);
    var sql = 'SELECT key, value FROM records WHERE object_store_id = ?' + rng.where + ' ORDER BY key LIMIT 1';
    var params = [this._storeId].concat(rng.params);
    var rows = _db.exec(sql, params);
    if (rows.length > 0 && rows[0].values.length > 0) {
      req._succeed(_parseValue(rows[0].values[0][1]));
    } else {
      req._succeed(undefined);
    }
    return req;
  };

  _IDBObjectStore.prototype.getKey = function(query) {
    this._checkActive();
    var req = new _IDBRequest(this, this._tx);
    var range = (query instanceof _IDBKeyRange) ? query : _IDBKeyRange.only(query);
    var rng = _rangeToSQL(range);
    var sql = 'SELECT key FROM records WHERE object_store_id = ?' + rng.where + ' ORDER BY key LIMIT 1';
    var params = [this._storeId].concat(rng.params);
    var rows = _db.exec(sql, params);
    if (rows.length > 0 && rows[0].values.length > 0) {
      req._succeed(_blobToKey(rows[0].values[0][0]));
    } else {
      req._succeed(undefined);
    }
    return req;
  };

  _IDBObjectStore.prototype.getAll = function(query, cnt) {
    this._checkActive();
    var req = new _IDBRequest(this, this._tx);
    var range = (query !== undefined && query !== null)
      ? ((query instanceof _IDBKeyRange) ? query : _IDBKeyRange.only(query))
      : null;
    var rng = _rangeToSQL(range);
    var sql = 'SELECT value FROM records WHERE object_store_id = ?' + rng.where + ' ORDER BY key';
    if (cnt !== undefined) sql += ' LIMIT ' + parseInt(cnt);
    var params = [this._storeId].concat(rng.params);
    var rows = _db.exec(sql, params);
    var out = [];
    if (rows.length > 0) {
      for (var i = 0; i < rows[0].values.length; i++) {
        out.push(_parseValue(rows[0].values[i][0]));
      }
    }
    req._succeed(out);
    return req;
  };

  _IDBObjectStore.prototype.getAllKeys = function(query, cnt) {
    this._checkActive();
    var req = new _IDBRequest(this, this._tx);
    var range = (query !== undefined && query !== null)
      ? ((query instanceof _IDBKeyRange) ? query : _IDBKeyRange.only(query))
      : null;
    var rng = _rangeToSQL(range);
    var sql = 'SELECT key FROM records WHERE object_store_id = ?' + rng.where + ' ORDER BY key';
    if (cnt !== undefined) sql += ' LIMIT ' + parseInt(cnt);
    var params = [this._storeId].concat(rng.params);
    var rows = _db.exec(sql, params);
    var out = [];
    if (rows.length > 0) {
      for (var i = 0; i < rows[0].values.length; i++) {
        out.push(_blobToKey(rows[0].values[i][0]));
      }
    }
    req._succeed(out);
    return req;
  };

  _IDBObjectStore.prototype.delete = function(query) {
    this._checkWrite();
    var req = new _IDBRequest(this, this._tx);
    var range = (query instanceof _IDBKeyRange) ? query : _IDBKeyRange.only(query);
    var rng = _rangeToSQL(range);
    // Delete index records first
    var keysSQL = 'SELECT key FROM records WHERE object_store_id = ?' + rng.where;
    var keysParams = [this._storeId].concat(rng.params);
    var keyRows = _db.exec(keysSQL, keysParams);
    if (keyRows.length > 0) {
      var indexes = _getAllIndexesForStore(this._storeId);
      for (var i = 0; i < keyRows[0].values.length; i++) {
        var pkBlob = keyRows[0].values[i][0];
        for (var j = 0; j < indexes.length; j++) {
          _db.run('DELETE FROM index_records WHERE index_id = ? AND primary_key = ?',
            [indexes[j].id, pkBlob]);
        }
      }
    }
    _db.run('DELETE FROM records WHERE object_store_id = ?' + rng.where,
      [this._storeId].concat(rng.params));
    this._tx._dirty = true;
    req._succeed(undefined);
    return req;
  };

  _IDBObjectStore.prototype.clear = function() {
    this._checkWrite();
    var req = new _IDBRequest(this, this._tx);
    // Clear index records
    var indexes = _getAllIndexesForStore(this._storeId);
    for (var i = 0; i < indexes.length; i++) {
      _db.run('DELETE FROM index_records WHERE index_id = ?', [indexes[i].id]);
    }
    _db.run('DELETE FROM records WHERE object_store_id = ?', [this._storeId]);
    this._tx._dirty = true;
    req._succeed(undefined);
    return req;
  };

  _IDBObjectStore.prototype.count = function(query) {
    this._checkActive();
    var req = new _IDBRequest(this, this._tx);
    if (query === undefined) {
      var rows = _db.exec('SELECT COUNT(*) FROM records WHERE object_store_id = ?', [this._storeId]);
      req._succeed(rows.length > 0 ? rows[0].values[0][0] : 0);
    } else {
      var range = (query instanceof _IDBKeyRange) ? query : _IDBKeyRange.only(query);
      var rng = _rangeToSQL(range);
      var sql = 'SELECT COUNT(*) FROM records WHERE object_store_id = ?' + rng.where;
      var params = [this._storeId].concat(rng.params);
      var rows2 = _db.exec(sql, params);
      req._succeed(rows2.length > 0 ? rows2[0].values[0][0] : 0);
    }
    return req;
  };

  _IDBObjectStore.prototype.createIndex = function(name, keyPath, opts) {
    this._checkWrite();
    opts = opts || {};
    var uniqueFlag = opts.unique ? 1 : 0;
    var multiEntry = opts.multiEntry ? 1 : 0;
    _db.run('INSERT INTO indexes (object_store_id, name, key_path, unique_flag, multi_entry) VALUES (?, ?, ?, ?, ?)',
      [this._storeId, name, _serializeKeyPath(keyPath), uniqueFlag, multiEntry]);
    var idxRows = _db.exec('SELECT last_insert_rowid()');
    var indexId = idxRows[0].values[0][0];

    // Populate index from existing records
    var recRows = _db.exec('SELECT key, value FROM records WHERE object_store_id = ?', [this._storeId]);
    if (recRows.length > 0) {
      for (var i = 0; i < recRows[0].values.length; i++) {
        var pkBlob = recRows[0].values[i][0];
        var val = _parseValue(recRows[0].values[i][1]);
        var ik = _getByKeyPath(val, keyPath);
        if (ik === undefined) continue;
        if (multiEntry && Array.isArray(ik)) {
          var _seenCI = {};
          for (var j = 0; j < ik.length; j++) {
            if (ik[j] === undefined) continue;
            var ikBlobCI = _keyToBlob(ik[j]);
            var ikKeyCI = String(ikBlobCI);
            if (_seenCI[ikKeyCI]) continue;
            _seenCI[ikKeyCI] = true;
            _db.run('INSERT INTO index_records (index_id, key, primary_key) VALUES (?, ?, ?)',
              [indexId, ikBlobCI, pkBlob]);
          }
        } else {
          _db.run('INSERT INTO index_records (index_id, key, primary_key) VALUES (?, ?, ?)',
            [indexId, _keyToBlob(ik), pkBlob]);
        }
      }
    }

    return new _IDBIndex(this, name, { id: indexId, keyPath: keyPath, unique: !!opts.unique, multiEntry: !!opts.multiEntry });
  };

  _IDBObjectStore.prototype.deleteIndex = function(name) {
    this._checkWrite();
    // CASCADE will clean up index_records
    _db.run('DELETE FROM indexes WHERE object_store_id = ? AND name = ?', [this._storeId, name]);
  };

  _IDBObjectStore.prototype.index = function(name) {
    this._checkActive();
    var info = _getIndexId(this._storeId, name);
    if (!info) throw new DOMException('Index not found: ' + name, 'NotFoundError');
    return new _IDBIndex(this, name, info);
  };

  _IDBObjectStore.prototype.openCursor = function(query, dir) {
    this._checkActive();
    var req = new _IDBRequest(this, this._tx);
    var range = (query !== undefined && query !== null)
      ? ((query instanceof _IDBKeyRange) ? query : _IDBKeyRange.only(query))
      : null;
    var rng = _rangeToSQL(range);
    var order = (dir === 'prev' || dir === 'prevunique') ? 'DESC' : 'ASC';
    var sql = 'SELECT key, value FROM records WHERE object_store_id = ?' + rng.where + ' ORDER BY key ' + order;
    var params = [this._storeId].concat(rng.params);
    var rows = _db.exec(sql, params);
    var recs = [];
    if (rows.length > 0) {
      for (var i = 0; i < rows[0].values.length; i++) {
        var k = _blobToKey(rows[0].values[i][0]);
        recs.push({ key: k, primaryKey: k, value: _parseValue(rows[0].values[i][1]) });
      }
    }
    if (dir === 'nextunique' || dir === 'prevunique') recs = _deduplicateByKey(recs);
    var c = new _IDBCursor(this, recs, dir || 'next', req, this._tx, this._storeId, false);
    c._advance(1); return req;
  };

  _IDBObjectStore.prototype.openKeyCursor = function(query, dir) {
    this._checkActive();
    var req = new _IDBRequest(this, this._tx);
    var range = (query !== undefined && query !== null)
      ? ((query instanceof _IDBKeyRange) ? query : _IDBKeyRange.only(query))
      : null;
    var rng = _rangeToSQL(range);
    var order = (dir === 'prev' || dir === 'prevunique') ? 'DESC' : 'ASC';
    var sql = 'SELECT key FROM records WHERE object_store_id = ?' + rng.where + ' ORDER BY key ' + order;
    var params = [this._storeId].concat(rng.params);
    var rows = _db.exec(sql, params);
    var recs = [];
    if (rows.length > 0) {
      for (var i = 0; i < rows[0].values.length; i++) {
        var k = _blobToKey(rows[0].values[i][0]);
        recs.push({ key: k, primaryKey: k });
      }
    }
    if (dir === 'nextunique' || dir === 'prevunique') recs = _deduplicateByKey(recs);
    var c = new _IDBCursor(this, recs, dir || 'next', req, this._tx, this._storeId, true);
    c._advance(1); return req;
  };

  // ---- IDBTransaction ----

  var _txCounter = 0;

  function _IDBTransaction(db, storeNames, mode) {
    this._db = db; this._storeNames = storeNames; this._mode = mode;
    this._dirty = false; this._aborted = false; this._committed = false;
    this._error = null; this._savepointName = null;
    this._pendingRequests = 0;
    this.oncomplete = null; this.onerror = null; this.onabort = null;
    _mixEvents(this);
    // Create a SAVEPOINT for readwrite/versionchange so abort() can rollback.
    if (_db && (mode === 'readwrite' || mode === 'versionchange')) {
      this._savepointName = 'tx_' + (++_txCounter);
      try { _db.run('SAVEPOINT ' + this._savepointName); } catch(e) {}
    }
    // Auto-commit after current task completes (only if no pending requests)
    var self = this;
    setTimeout(function() {
      if (self._pendingRequests === 0) self._tryCommit();
    }, 0);
  }
  Object.defineProperties(_IDBTransaction.prototype, {
    db: { get: function() { return this._db; } },
    mode: { get: function() { return this._mode; } },
    objectStoreNames: { get: function() { return _DOMStringList(this._storeNames); } },
    error: { get: function() { return this._error; } }
  });
  _IDBTransaction.prototype.objectStore = function(name) {
    if (this._storeNames.indexOf(name) === -1)
      throw new DOMException('Store not in scope: ' + name, 'NotFoundError');
    var storeInfo = _getStoreId(this._db._dbId, name);
    if (!storeInfo) throw new DOMException('Store not found: ' + name, 'NotFoundError');
    return new _IDBObjectStore(this, name, storeInfo, this._db._dbId);
  };
  _IDBTransaction.prototype.abort = function() {
    if (this._aborted || this._committed) return;
    this._aborted = true;
    if (!this._error) this._error = new DOMException('Transaction aborted', 'AbortError');
    // Rollback all mutations made within this transaction's SAVEPOINT.
    if (this._savepointName && _db) {
      try {
        _db.run('ROLLBACK TO ' + this._savepointName);
        _db.run('RELEASE ' + this._savepointName);
      } catch(e) {}
    }
    var self = this;
    _async(function() { self.dispatchEvent(new _Event('abort')); });
  };
  _IDBTransaction.prototype._tryCommit = function() {
    if (this._aborted || this._committed) return;
    this._committed = true;
    // Release the SAVEPOINT (commits all changes within it).
    if (this._savepointName && _db) {
      try { _db.run('RELEASE ' + this._savepointName); } catch(e) {}
    }
    if (this._dirty) _schedulePersist();
    var self = this;
    _async(function() { self.dispatchEvent(new _Event('complete')); });
  };
  _IDBTransaction.prototype.commit = function() { this._tryCommit(); };
  _IDBTransaction.prototype._scheduleCommit = function() {
    var self = this;
    _async(function() {
      if (self._pendingRequests === 0) self._tryCommit();
    });
  };

  // ---- IDBDatabase ----

  function _IDBDatabase(name, version, dbId) {
    this._name = name; this._version = version; this._dbId = dbId;
    this._closed = false;
    this.onclose = null; this.onversionchange = null; this.onerror = null;
    _mixEvents(this);
  }
  Object.defineProperties(_IDBDatabase.prototype, {
    name: { get: function() { return this._name; } },
    version: { get: function() { return this._version; } },
    objectStoreNames: {
      get: function() {
        var rows = _db.exec('SELECT name FROM object_stores WHERE database_id = ? ORDER BY name', [this._dbId]);
        var names = [];
        if (rows.length > 0) {
          for (var i = 0; i < rows[0].values.length; i++) names.push(rows[0].values[i][0]);
        }
        return _DOMStringList(names);
      }
    }
  });
  _IDBDatabase.prototype.createObjectStore = function(name, opts) {
    if (!this._versionChangeTx)
      throw new DOMException('Not in a version change transaction', 'InvalidStateError');
    opts = opts || {};
    var rawKeyPath = opts.keyPath !== undefined ? opts.keyPath : null;
    var storedKeyPath = (rawKeyPath !== null) ? _serializeKeyPath(rawKeyPath) : null;
    var autoInc = opts.autoIncrement ? 1 : 0;
    _db.run('INSERT INTO object_stores (database_id, name, key_path, auto_increment, current_key) VALUES (?, ?, ?, ?, 0)',
      [this._dbId, name, storedKeyPath, autoInc]);
    var idRows = _db.exec('SELECT last_insert_rowid()');
    var storeId = idRows[0].values[0][0];
    var tx = this._versionChangeTx;
    if (tx && tx._storeNames.indexOf(name) === -1) tx._storeNames.push(name);
    return new _IDBObjectStore(tx, name, { id: storeId, keyPath: rawKeyPath, autoIncrement: !!opts.autoIncrement, currentKey: 0 }, this._dbId);
  };
  _IDBDatabase.prototype.deleteObjectStore = function(name) {
    if (!this._versionChangeTx)
      throw new DOMException('Not in a version change transaction', 'InvalidStateError');
    var storeInfo = _getStoreId(this._dbId, name);
    if (storeInfo) {
      // Delete records and index records before the store row
      // (records table has no FK cascade, indexes/index_records cascade from object_stores FK)
      _db.run('DELETE FROM records WHERE object_store_id = ?', [storeInfo.id]);
      var indexes = _getAllIndexesForStore(storeInfo.id);
      for (var i = 0; i < indexes.length; i++) {
        _db.run('DELETE FROM index_records WHERE index_id = ?', [indexes[i].id]);
      }
    }
    _db.run('DELETE FROM object_stores WHERE database_id = ? AND name = ?', [this._dbId, name]);
    var tx = this._versionChangeTx;
    if (tx) {
      var idx = tx._storeNames.indexOf(name);
      if (idx !== -1) tx._storeNames.splice(idx, 1);
    }
  };
  _IDBDatabase.prototype.transaction = function(storeNames, mode) {
    if (this._closed)
      throw new DOMException('Database is closed', 'InvalidStateError');
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

      _whenReady(function() {
        _async(function() {
          var dbInfo = _getDbId(name);
          var oldVersion = dbInfo ? dbInfo.version : 0;
          var targetVersion = version !== undefined ? version : (oldVersion || 1);

          // Version downgrade is not allowed
          if (version !== undefined && dbInfo && targetVersion < oldVersion) {
            req._fail(new DOMException(
              'The requested version (' + targetVersion + ') is less than the existing version (' + oldVersion + ').',
              'VersionError'));
            return;
          }

          if (!dbInfo || targetVersion > oldVersion) {
            if (!dbInfo) {
              _db.run('INSERT INTO databases (name, version) VALUES (?, ?)', [name, targetVersion]);
              dbInfo = _getDbId(name);
            } else {
              _db.run('UPDATE databases SET version = ? WHERE id = ?', [targetVersion, dbInfo.id]);
              dbInfo.version = targetVersion;
            }

            var db = new _IDBDatabase(name, targetVersion, dbInfo.id);
            var storeRows = _db.exec('SELECT name FROM object_stores WHERE database_id = ?', [dbInfo.id]);
            var storeNames = [];
            if (storeRows.length > 0) {
              for (var i = 0; i < storeRows[0].values.length; i++) storeNames.push(storeRows[0].values[i][0]);
            }
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
            var db2 = new _IDBDatabase(name, dbInfo.version, dbInfo.id);
            req._succeed(db2);
          }
        });
      });

      return req;
    },
    deleteDatabase: function(name) {
      var req = new _IDBRequest(null, null);
      _whenReady(function() {
        var dbInfo = _getDbId(name);
        var oldVersion = dbInfo ? dbInfo.version : 0;
        if (dbInfo) {
          // CASCADE handles object_stores → indexes → index_records
          // But records need manual cleanup
          var storeRows = _db.exec('SELECT id FROM object_stores WHERE database_id = ?', [dbInfo.id]);
          if (storeRows.length > 0) {
            for (var i = 0; i < storeRows[0].values.length; i++) {
              _db.run('DELETE FROM records WHERE object_store_id = ?', [storeRows[0].values[i][0]]);
            }
          }
          _db.run('DELETE FROM databases WHERE id = ?', [dbInfo.id]);
          _schedulePersist();
        }
        _async(function() {
          req.readyState = 'done'; req.result = undefined;
          req.dispatchEvent(new _VersionChangeEvent('success', oldVersion, null));
        });
      });
      return req;
    },
    databases: function() {
      return new Promise(function(resolve) {
        _whenReady(function() {
          var rows = _db.exec('SELECT name, version FROM databases');
          var result = [];
          if (rows.length > 0) {
            for (var i = 0; i < rows[0].values.length; i++) {
              result.push({ name: rows[0].values[i][0], version: rows[0].values[i][1] });
            }
          }
          resolve(result);
        });
      });
    },
    cmp: function(a, b) { return _cmp(a, b); }
  };

  // ---- JSON migration ----

  function _migrateFromJSON(SQL, json) {
    var db = new SQL.Database();
    _initSchema(db);
    for (var dbName in json) {
      var dbData = json[dbName];
      db.run('INSERT INTO databases (name, version) VALUES (?, ?)', [dbName, dbData.version || 1]);
      var dbIdRows = db.exec('SELECT last_insert_rowid()');
      var dbId = dbIdRows[0].values[0][0];
      var stores = dbData.stores || {};
      for (var storeName in stores) {
        var storeDef = stores[storeName];
        var keyPath = storeDef.keyPath !== undefined ? storeDef.keyPath : null;
        var autoInc = storeDef.autoIncrement ? 1 : 0;
        var nextKey = storeDef.nextKey || 0;
        db.run('INSERT INTO object_stores (database_id, name, key_path, auto_increment, current_key) VALUES (?, ?, ?, ?, ?)',
          [dbId, storeName, keyPath, autoInc, nextKey]);
        var storeIdRows = db.exec('SELECT last_insert_rowid()');
        var storeId = storeIdRows[0].values[0][0];
        // Migrate indexes
        var idxDefs = storeDef.indexes || {};
        var indexIdMap = {};
        for (var idxName in idxDefs) {
          var idxDef = idxDefs[idxName];
          db.run('INSERT INTO indexes (object_store_id, name, key_path, unique_flag, multi_entry) VALUES (?, ?, ?, ?, ?)',
            [storeId, idxName, _serializeKeyPath(idxDef.keyPath), idxDef.unique ? 1 : 0, idxDef.multiEntry ? 1 : 0]);
          var idxIdRows = db.exec('SELECT last_insert_rowid()');
          indexIdMap[idxName] = idxIdRows[0].values[0][0];
        }
        // Migrate records
        var records = storeDef.records || [];
        for (var i = 0; i < records.length; i++) {
          var rec = records[i];
          // Revive the value through JSON round-trip to handle tagged types
          var value = JSON.parse(JSON.stringify(rec.value, _replacer), _reviver);
          // Revive the key too (old format may store Date keys as tagged objects)
          var revivedKey = JSON.parse(JSON.stringify(rec.key, _replacer), _reviver);
          var pkBlob = _keyToBlob(revivedKey);
          var valueJSON = JSON.stringify(value, _replacer);
          db.run('INSERT INTO records (object_store_id, key, value) VALUES (?, ?, ?)',
            [storeId, pkBlob, valueJSON]);
          // Populate index records
          for (var idxName2 in idxDefs) {
            var idxDef2 = idxDefs[idxName2];
            var ik = _getByKeyPath(value, idxDef2.keyPath);
            if (ik === undefined) continue;
            if (idxDef2.multiEntry && Array.isArray(ik)) {
              var _seenMig = {};
              for (var j = 0; j < ik.length; j++) {
                if (ik[j] === undefined) continue;
                var ikBlobMig = _keyToBlob(ik[j]);
                var ikKeyMig = String(ikBlobMig);
                if (_seenMig[ikKeyMig]) continue;
                _seenMig[ikKeyMig] = true;
                db.run('INSERT INTO index_records (index_id, key, primary_key) VALUES (?, ?, ?)',
                  [indexIdMap[idxName2], ikBlobMig, pkBlob]);
              }
            } else {
              db.run('INSERT INTO index_records (index_id, key, primary_key) VALUES (?, ?, ?)',
                [indexIdMap[idxName2], _keyToBlob(ik), pkBlob]);
            }
          }
        }
      }
    }
    return db;
  }

  // ---- Initialization ----

  initSqlJs({ locateFile: function() { return '__DOUFU_WASMURL__'; } })
    .then(function(SQL) {
      window.__doufuSQL = SQL;
      return fetch(_APPDATAURL + '/indexedDB.sqlite')
        .then(function(r) {
          if (r.ok) return r.arrayBuffer().then(function(b) {
            var sqlDb = new SQL.Database(new Uint8Array(b));
            // Ensure schema exists (for forward compatibility)
            _initSchema(sqlDb);
            return sqlDb;
          });
          // Try migrating from old JSON
          return fetch(_APPDATAURL + '/indexedDB.json')
            .then(function(r2) {
              if (r2.ok) return r2.json().then(function(json) {
                var migratedDb = _migrateFromJSON(SQL, json);
                // Persist the migrated SQLite file immediately
                var data = migratedDb.export();
                fetch(_APPDATAURL + '/indexedDB.sqlite', { method: 'PUT', body: data })
                  .catch(function(e) { console.error('[Doufu] Migration persist failed:', e); });
                return migratedDb;
              });
              // Fresh database
              var sqlDb = new SQL.Database();
              _initSchema(sqlDb);
              return sqlDb;
            });
        });
    })
    .then(function(sqlDb) { _db = sqlDb; _flushPending(); })
    .catch(function(err) {
      console.error('[Doufu] sql.js init failed:', err);
      // Create an empty in-memory database as fallback so the API doesn't hang.
      // Data won't persist, but at least the page functions.
      try {
        if (window.__doufuSQL) {
          _db = new window.__doufuSQL.Database();
          _initSchema(_db);
        }
      } catch(e) { /* last resort: leave _db null */ }
      _flushPending();
    });

  // ---- Expose globals ----

  try {
    Object.defineProperty(window, 'indexedDB', {
      get: function() { return _idbFactory; },
      configurable: true
    });
  } catch(e) {}
  window.IDBKeyRange = _IDBKeyRange;
  window.IDBDatabase = _IDBDatabase;
  window.IDBTransaction = _IDBTransaction;
  window.IDBObjectStore = _IDBObjectStore;
  window.IDBIndex = _IDBIndex;
  window.IDBCursor = _IDBCursor;
  window.IDBRequest = _IDBRequest;
  window.IDBOpenDBRequest = _IDBRequest;
  window.IDBVersionChangeEvent = _VersionChangeEvent;

  // Exposed for native clearIndexedDB() to cancel pending persist before reload.
  window.__doufuIDBCancelPersist = function() {
    if (_flushTimer) { clearTimeout(_flushTimer); _flushTimer = null; }
    if (_db) { try { _db.close(); } catch(e) {} _db = null; }
  };

  // Non-destructive flush: persist pending changes without closing the db.
  // Called by native before page navigation or WebView teardown.
  window.__doufuIDBFlushSync = function() {
    if (_flushTimer) { clearTimeout(_flushTimer); _flushTimer = null; }
    _doPersistSync();
  };

})();
