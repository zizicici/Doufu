// MockSqlJs.js — Provides a sql.js-compatible API surface for testing in JSContext.
// JSContext (JavaScriptCore) does not support WASM, so we implement a minimal
// in-memory SQL engine that supports the subset used by DoufuSqlJsIndexedDB.js.

(function() {
  'use strict';

  // ---- Minimal in-memory SQL engine ----
  // Supports: CREATE TABLE, CREATE INDEX, INSERT, INSERT OR REPLACE, UPDATE, DELETE, SELECT, PRAGMA
  // Uses plain JS objects as storage.

  function MockDatabase(data) {
    this._tables = {};
    this._autoIncrements = {};

    // If data is provided (Uint8Array), deserialize from JSON encoding
    if (data && data.length > 0) {
      try {
        var json = '';
        for (var i = 0; i < data.length; i++) json += String.fromCharCode(data[i]);
        var parsed = JSON.parse(json);
        this._tables = parsed.tables || {};
        this._autoIncrements = parsed.autoIncrements || {};
      } catch(e) {
        // Invalid data, start fresh
      }
    }
  }

  MockDatabase.prototype.run = function(sql, params) {
    this._exec(sql, params || [], false);
  };

  MockDatabase.prototype.exec = function(sql, params) {
    return this._exec(sql, params || [], true);
  };

  MockDatabase.prototype.export = function() {
    var json = JSON.stringify({ tables: this._tables, autoIncrements: this._autoIncrements });
    var arr = new Uint8Array(json.length);
    for (var i = 0; i < json.length; i++) arr[i] = json.charCodeAt(i);
    return arr;
  };

  MockDatabase.prototype.close = function() {
    this._tables = {};
  };

  MockDatabase.prototype._exec = function(sql, params, returnResults) {
    sql = sql.trim();
    // Handle multiple statements separated by ;
    // But be careful not to split inside strings
    var normalized = sql.replace(/\s+/g, ' ').trim();

    if (/^PRAGMA/i.test(normalized)) return [];
    if (/^CREATE\s+TABLE/i.test(normalized)) return this._createTable(normalized);
    if (/^CREATE\s+INDEX/i.test(normalized)) return []; // Index is a no-op in mock
    if (/^INSERT\s+OR\s+REPLACE/i.test(normalized)) return this._insertOrReplace(normalized, params);
    if (/^INSERT/i.test(normalized)) return this._insert(normalized, params, returnResults);
    if (/^UPDATE/i.test(normalized)) return this._update(normalized, params);
    if (/^DELETE/i.test(normalized)) return this._delete(normalized, params);
    if (/^SELECT/i.test(normalized)) return this._select(normalized, params);
    if (/^SAVEPOINT/i.test(normalized)) return this._savepoint(normalized);
    if (/^ROLLBACK\s+TO/i.test(normalized)) return this._rollbackTo(normalized);
    if (/^RELEASE/i.test(normalized)) return this._release(normalized);

    return [];
  };

  MockDatabase.prototype._createTable = function(sql) {
    var match = sql.match(/CREATE TABLE IF NOT EXISTS (\w+)/i) || sql.match(/CREATE TABLE (\w+)/i);
    if (!match) return [];
    var name = match[1];
    if (!this._tables[name]) {
      this._tables[name] = { rows: [], columns: this._parseColumns(sql) };
    }
    return [];
  };

  MockDatabase.prototype._parseColumns = function(sql) {
    // Extract column names from CREATE TABLE
    var match = sql.match(/\((.+)\)$/);
    if (!match) return [];
    var body = match[1];
    var cols = [];
    var depth = 0;
    var current = '';
    for (var i = 0; i < body.length; i++) {
      var ch = body[i];
      if (ch === '(') depth++;
      else if (ch === ')') depth--;
      else if (ch === ',' && depth === 0) {
        var trimmed = current.trim();
        if (trimmed && !/^(PRIMARY|UNIQUE|FOREIGN|CHECK|CONSTRAINT)/i.test(trimmed)) {
          var colName = trimmed.split(/\s+/)[0];
          cols.push(colName);
        }
        current = '';
        continue;
      }
      current += ch;
    }
    if (current.trim()) {
      var trimmed2 = current.trim();
      if (!/^(PRIMARY|UNIQUE|FOREIGN|CHECK|CONSTRAINT)/i.test(trimmed2)) {
        cols.push(trimmed2.split(/\s+/)[0]);
      }
    }
    return cols;
  };

  MockDatabase.prototype._resolveParams = function(sql, params) {
    // Replace ? placeholders with indexed params
    var idx = 0;
    var resolved = [];
    for (var i = 0; i < params.length; i++) {
      resolved.push(params[i]);
    }
    return resolved;
  };

  MockDatabase.prototype._insert = function(sql, params, returnResults) {
    var match = sql.match(/INSERT INTO (\w+)\s*\(([^)]+)\)\s*VALUES\s*\(([^)]+)\)/i);
    if (!match) {
      // SELECT last_insert_rowid()
      if (/last_insert_rowid/i.test(sql)) return this._select(sql, params);
      return [];
    }
    var table = match[1];
    var colStr = match[2];
    var valStr = match[3];
    var cols = colStr.split(',').map(function(c) { return c.trim(); });
    var valTokens = valStr.split(',').map(function(v) { return v.trim(); });

    if (!this._tables[table]) this._tables[table] = { rows: [], columns: cols };
    var t = this._tables[table];

    var row = {};
    var pIdx = 0;
    for (var i = 0; i < cols.length; i++) {
      if (valTokens[i] === '?') {
        row[cols[i]] = params[pIdx++];
      } else {
        row[cols[i]] = this._parseLiteral(valTokens[i]);
      }
    }

    // Handle AUTOINCREMENT for 'id' column
    if (row.id === undefined || row.id === null) {
      if (!this._autoIncrements[table]) this._autoIncrements[table] = 0;
      this._autoIncrements[table]++;
      row.id = this._autoIncrements[table];
    } else if (typeof row.id === 'number') {
      if (!this._autoIncrements[table]) this._autoIncrements[table] = 0;
      if (row.id > this._autoIncrements[table]) this._autoIncrements[table] = row.id;
    }

    t.rows.push(row);
    this._lastInsertRowId = row.id;
    return [];
  };

  MockDatabase.prototype._insertOrReplace = function(sql, params) {
    var match = sql.match(/INSERT OR REPLACE INTO (\w+)\s*\(([^)]+)\)\s*VALUES\s*\(([^)]+)\)/i);
    if (!match) return [];
    var table = match[1];
    var colStr = match[2];
    var valStr = match[3];
    var cols = colStr.split(',').map(function(c) { return c.trim(); });
    var valTokens = valStr.split(',').map(function(v) { return v.trim(); });

    if (!this._tables[table]) this._tables[table] = { rows: [], columns: cols };
    var t = this._tables[table];

    var row = {};
    var pIdx = 0;
    for (var i = 0; i < cols.length; i++) {
      if (valTokens[i] === '?') {
        row[cols[i]] = params[pIdx++];
      } else {
        row[cols[i]] = this._parseLiteral(valTokens[i]);
      }
    }

    // Find the primary key columns (first column or 'id' or composite)
    // For 'records' table, PK is (object_store_id, key)
    var existingIdx = -1;
    if (table === 'records') {
      for (var j = 0; j < t.rows.length; j++) {
        if (_blobEqual(t.rows[j].object_store_id, row.object_store_id) &&
            _blobEqual(t.rows[j].key, row.key)) {
          existingIdx = j; break;
        }
      }
    } else {
      for (var k = 0; k < t.rows.length; k++) {
        if (t.rows[k].id !== undefined && row.id !== undefined && t.rows[k].id === row.id) {
          existingIdx = k; break;
        }
      }
    }

    if (existingIdx >= 0) {
      t.rows[existingIdx] = row;
    } else {
      t.rows.push(row);
    }

    if (typeof row.id === 'number') {
      if (!this._autoIncrements[table]) this._autoIncrements[table] = 0;
      if (row.id > this._autoIncrements[table]) this._autoIncrements[table] = row.id;
    }
    this._lastInsertRowId = row.id;
    return [];
  };

  MockDatabase.prototype._update = function(sql, params) {
    var match = sql.match(/UPDATE (\w+) SET (.+?) WHERE (.+)/i);
    if (!match) return [];
    var table = match[1];
    var setClause = match[2].trim();
    var whereClause = match[3].trim();

    var t = this._tables[table];
    if (!t) return [];

    // Parse SET clause
    var sets = this._parseSetClause(setClause, params);
    var whereFn = this._parseWhere(whereClause, params, sets.paramOffset);

    for (var i = 0; i < t.rows.length; i++) {
      if (whereFn(t.rows[i])) {
        for (var k in sets.values) {
          t.rows[i][k] = sets.values[k];
        }
      }
    }
    return [];
  };

  MockDatabase.prototype._parseSetClause = function(clause, params) {
    var parts = clause.split(',');
    var values = {};
    var pIdx = 0;
    for (var i = 0; i < parts.length; i++) {
      var kv = parts[i].split('=');
      var col = kv[0].trim();
      var val = kv[1].trim();
      if (val === '?') {
        values[col] = params[pIdx++];
      } else {
        values[col] = this._parseLiteral(val);
      }
    }
    return { values: values, paramOffset: pIdx };
  };

  MockDatabase.prototype._delete = function(sql, params) {
    var match = sql.match(/DELETE FROM (\w+)(?: WHERE (.+))?/i);
    if (!match) return [];
    var table = match[1];
    var whereStr = match[2];
    var t = this._tables[table];
    if (!t) return [];

    if (!whereStr) {
      t.rows = [];
      return [];
    }

    var whereFn = this._parseWhere(whereStr.trim(), params, 0);
    t.rows = t.rows.filter(function(r) { return !whereFn(r); });
    return [];
  };

  MockDatabase.prototype._select = function(sql, params) {
    // Handle last_insert_rowid()
    if (/last_insert_rowid/i.test(sql)) {
      return [{ columns: ['last_insert_rowid()'], values: [[this._lastInsertRowId || 0]] }];
    }

    // Detect JOIN queries and delegate
    if (/\bJOIN\b/i.test(sql)) {
      return this._selectJoin(sql, params);
    }

    var match = sql.match(/SELECT (.+?) FROM (\w+)(.*)/i);
    if (!match) {
      return [];
    }

    var colsStr = match[1].trim();
    var table = match[2].trim();
    var rest = (match[3] || '').trim();

    var t = this._tables[table];
    if (!t) return [];

    // Parse WHERE
    var rows = t.rows;
    var whereMatch = rest.match(/WHERE (.+?)(?:\s+ORDER|\s+LIMIT|\s*$)/i);
    if (whereMatch) {
      var whereFn = this._parseWhere(whereMatch[1].trim(), params, 0);
      rows = rows.filter(function(r) { return whereFn(r); });
    }

    // Parse ORDER BY
    var orderMatch = rest.match(/ORDER BY (\w+)(?: (ASC|DESC))?/i);
    if (orderMatch) {
      var orderCol = orderMatch[1];
      var desc = orderMatch[2] && orderMatch[2].toUpperCase() === 'DESC';
      rows = rows.slice().sort(function(a, b) {
        var va = a[orderCol], vb = b[orderCol];
        var cmp = _blobCompare(va, vb);
        return desc ? -cmp : cmp;
      });
    }

    // Parse LIMIT
    var limitMatch = rest.match(/LIMIT (\d+)/i);
    if (limitMatch) {
      rows = rows.slice(0, parseInt(limitMatch[1]));
    }

    // Build result
    if (/^COUNT\(\*\)/i.test(colsStr)) {
      return [{ columns: ['COUNT(*)'], values: [[rows.length]] }];
    }

    if (colsStr === '1') {
      if (rows.length === 0) return [];
      return [{ columns: ['1'], values: rows.map(function() { return [1]; }) }];
    }

    var cols = colsStr.split(',').map(function(c) { return c.trim(); });
    if (rows.length === 0) return [];

    var values = rows.map(function(r) {
      return cols.map(function(c) { return r[c]; });
    });

    return [{ columns: cols, values: values }];
  };

  MockDatabase.prototype._selectJoin = function(sql, params) {
    // Handle: SELECT ir.key, ir.primary_key, r.value FROM index_records ir
    //         JOIN records r ON r.object_store_id = ? AND r.key = ir.primary_key
    //         WHERE ir.index_id = ? [AND ...] ORDER BY ir.key, ir.primary_key

    var joinMatch = sql.match(/SELECT (.+?) FROM (\w+) (\w+)\s+JOIN (\w+) (\w+) ON (.+?) WHERE (.+?)(?:\s+ORDER BY (.+?))?(?:\s+LIMIT (\d+))?\s*$/i);
    if (!joinMatch) return [];

    var selectCols = joinMatch[1].trim();
    var leftTable = joinMatch[2];
    var leftAlias = joinMatch[3];
    var rightTable = joinMatch[4];
    var rightAlias = joinMatch[5];
    var onClause = joinMatch[6].trim();
    var whereClause = joinMatch[7].trim();
    var orderClause = joinMatch[8];

    var lt = this._tables[leftTable];
    var rt = this._tables[rightTable];
    if (!lt || !rt) return [];

    // Parse params: first param is for ON clause (r.object_store_id = ?), then WHERE params
    var pIdx = 0;
    var onStoreId = params[pIdx++]; // r.object_store_id = ?

    // Parse WHERE: ir.index_id = ? [AND ir.key >= ? AND ir.key <= ?]
    var indexId = params[pIdx++];
    var extraFilters = [];
    // Parse remaining AND clauses for range
    var andParts = whereClause.split(/\s+AND\s+/i);
    for (var i = 1; i < andParts.length; i++) {
      var part = andParts[i].trim();
      var opMatch = part.match(/(\w+)\.(\w+)\s*(>=|<=|>|<|=)\s*\?/);
      if (opMatch) {
        extraFilters.push({ col: opMatch[2], op: opMatch[3], val: params[pIdx++] });
      }
    }

    // Perform join
    var results = [];
    for (var li = 0; li < lt.rows.length; li++) {
      var lr = lt.rows[li];
      if (lr.index_id !== indexId) continue;

      // Apply range filters on left row
      var pass = true;
      for (var fi = 0; fi < extraFilters.length; fi++) {
        var f = extraFilters[fi];
        var lval = lr[f.col];
        var cmp = _blobCompare(lval, f.val);
        if (f.op === '>=' && cmp < 0) { pass = false; break; }
        if (f.op === '>' && cmp <= 0) { pass = false; break; }
        if (f.op === '<=' && cmp > 0) { pass = false; break; }
        if (f.op === '<' && cmp >= 0) { pass = false; break; }
      }
      if (!pass) continue;

      // Find matching right row
      for (var ri = 0; ri < rt.rows.length; ri++) {
        var rr = rt.rows[ri];
        if (!_blobEqual(rr.object_store_id, onStoreId)) continue;
        if (!_blobEqual(rr.key, lr.primary_key)) continue;

        // Build result row
        var row = {};
        row[leftAlias + '.key'] = lr.key;
        row[leftAlias + '.primary_key'] = lr.primary_key;
        row[rightAlias + '.value'] = rr.value;
        results.push(row);
      }
    }

    // Sort by ir.key, ir.primary_key
    results.sort(function(a, b) {
      var cmp1 = _blobCompare(a[leftAlias + '.key'], b[leftAlias + '.key']);
      if (cmp1 !== 0) return cmp1;
      return _blobCompare(a[leftAlias + '.primary_key'], b[leftAlias + '.primary_key']);
    });

    // Build columns from select
    var cols = selectCols.split(',').map(function(c) { return c.trim(); });
    if (results.length === 0) return [];
    var values = results.map(function(r) {
      return cols.map(function(c) { return r[c]; });
    });

    return [{ columns: cols, values: values }];
  };

  MockDatabase.prototype._parseWhere = function(whereStr, params, paramOffset) {
    // Simple WHERE parser: supports col = ?, col >= ?, col <= ?, col > ?, col < ?,
    // and AND combinations
    var pIdx = paramOffset || 0;
    var conditions = [];
    var parts = whereStr.split(/\s+AND\s+/i);
    for (var i = 0; i < parts.length; i++) {
      var part = parts[i].trim();
      var m = part.match(/(\w+)\s*(>=|<=|>|<|=)\s*\?/);
      if (m) {
        conditions.push({ col: m[1], op: m[2], val: params[pIdx++] });
      }
    }
    return function(row) {
      for (var i = 0; i < conditions.length; i++) {
        var c = conditions[i];
        var rv = row[c.col];
        var cmp = _blobCompare(rv, c.val);
        if (c.op === '=' && cmp !== 0) return false;
        if (c.op === '>=' && cmp < 0) return false;
        if (c.op === '>' && cmp <= 0) return false;
        if (c.op === '<=' && cmp > 0) return false;
        if (c.op === '<' && cmp >= 0) return false;
      }
      return true;
    };
  };

  // ---- SAVEPOINT / ROLLBACK / RELEASE ----

  MockDatabase.prototype._savepoint = function(sql) {
    var match = sql.match(/SAVEPOINT\s+(\w+)/i);
    if (!match) return [];
    var name = match[1];
    if (!this._savepoints) this._savepoints = {};
    // Deep-clone all tables
    this._savepoints[name] = JSON.parse(JSON.stringify({ tables: this._tables, autoIncrements: this._autoIncrements }));
    return [];
  };

  MockDatabase.prototype._rollbackTo = function(sql) {
    var match = sql.match(/ROLLBACK\s+TO\s+(\w+)/i);
    if (!match) return [];
    var name = match[1];
    if (this._savepoints && this._savepoints[name]) {
      var snapshot = this._savepoints[name];
      this._tables = JSON.parse(JSON.stringify(snapshot.tables));
      this._autoIncrements = JSON.parse(JSON.stringify(snapshot.autoIncrements));
    }
    return [];
  };

  MockDatabase.prototype._release = function(sql) {
    var match = sql.match(/RELEASE\s+(\w+)/i);
    if (!match) return [];
    var name = match[1];
    if (this._savepoints) {
      delete this._savepoints[name];
    }
    return [];
  };

  MockDatabase.prototype._parseLiteral = function(val) {
    if (val === 'NULL' || val === 'null') return null;
    var num = Number(val);
    if (!isNaN(num)) return num;
    // Strip quotes
    if ((val[0] === "'" && val[val.length-1] === "'") ||
        (val[0] === '"' && val[val.length-1] === '"')) {
      return val.slice(1, -1);
    }
    return val;
  };

  // ---- Blob comparison ----

  function _blobEqual(a, b) {
    if (a === b) return true;
    if (a === null || a === undefined || b === null || b === undefined) return a === b;
    if (typeof a === 'number' && typeof b === 'number') return a === b;
    if (typeof a === 'string' && typeof b === 'string') return a === b;
    // Array (blob) comparison
    if (Array.isArray(a) && Array.isArray(b)) {
      if (a.length !== b.length) return false;
      for (var i = 0; i < a.length; i++) { if (a[i] !== b[i]) return false; }
      return true;
    }
    if (a instanceof Uint8Array && b instanceof Uint8Array) {
      if (a.length !== b.length) return false;
      for (var j = 0; j < a.length; j++) { if (a[j] !== b[j]) return false; }
      return true;
    }
    // Mixed array/Uint8Array
    var aa = Array.isArray(a) ? a : (a instanceof Uint8Array ? Array.from(a) : [a]);
    var bb = Array.isArray(b) ? b : (b instanceof Uint8Array ? Array.from(b) : [b]);
    if (aa.length !== bb.length) return false;
    for (var k = 0; k < aa.length; k++) { if (aa[k] !== bb[k]) return false; }
    return true;
  }

  function _blobCompare(a, b) {
    if (a === b) return 0;
    if (a === null || a === undefined) return -1;
    if (b === null || b === undefined) return 1;
    if (typeof a === 'number' && typeof b === 'number') return a < b ? -1 : a > b ? 1 : 0;
    if (typeof a === 'string' && typeof b === 'string') return a < b ? -1 : a > b ? 1 : 0;
    // Blob comparison (byte by byte)
    var aa = Array.isArray(a) ? a : (a instanceof Uint8Array ? Array.from(a) : []);
    var bb = Array.isArray(b) ? b : (b instanceof Uint8Array ? Array.from(b) : []);
    var minLen = Math.min(aa.length, bb.length);
    for (var i = 0; i < minLen; i++) {
      if (aa[i] < bb[i]) return -1;
      if (aa[i] > bb[i]) return 1;
    }
    return aa.length < bb.length ? -1 : aa.length > bb.length ? 1 : 0;
  }

  // ---- Blob / File polyfill (not available in JSContext) ----

  function Blob(parts, options) {
    options = options || {};
    this.type = options.type || '';
    this._data = new Uint8Array(0);
    if (parts && parts.length > 0) {
      var p = parts[0];
      if (p instanceof ArrayBuffer) this._data = new Uint8Array(p);
      else if (p instanceof Uint8Array) this._data = new Uint8Array(p);
      else if (typeof p === 'string') this._data = new TextEncoder().encode(p);
    }
    this.size = this._data.length;
  }
  Blob.prototype.arrayBuffer = function() {
    var buf = this._data.buffer;
    return {
      then: function(fn) {
        var r = fn(buf);
        return { then: function(fn2) { if (fn2) fn2(r); return this; }, catch: function() { return this; } };
      },
      catch: function() { return this; }
    };
  };

  function File(parts, name, options) {
    Blob.call(this, parts, options);
    this.name = name || '';
    this.lastModified = (options && options.lastModified) || Date.now();
  }
  File.prototype = Object.create(Blob.prototype);
  File.prototype.constructor = File;

  // ---- ImageData polyfill (not available in JSContext) ----

  function ImageData(dataOrWidth, widthOrHeight, height) {
    if (dataOrWidth instanceof Uint8ClampedArray) {
      this.data = dataOrWidth;
      this.width = widthOrHeight;
      this.height = height;
    } else {
      this.width = dataOrWidth;
      this.height = widthOrHeight;
      this.data = new Uint8ClampedArray(this.width * this.height * 4);
    }
  }

  window.Blob = Blob;
  window.File = File;
  window.ImageData = ImageData;

  // ---- initSqlJs mock ----

  window.initSqlJs = function(config) {
    var SQL = {
      Database: function(data) {
        return new MockDatabase(data);
      }
    };
    // Return a thenable (sync) that resolves immediately
    return {
      then: function(fn) {
        var result = fn(SQL);
        return {
          then: function(fn2) {
            if (result && typeof result.then === 'function') {
              return result.then(fn2);
            }
            var r2 = fn2(result);
            return {
              then: function(fn3) { if (fn3) fn3(r2); return this; },
              catch: function() { return this; }
            };
          },
          catch: function() { return this; }
        };
      },
      catch: function() { return this; }
    };
  };

  // ---- fetch mock ----
  // The shim uses fetch() to load/save the SQLite file.
  // In test environment we mock it to always return 404 (fresh DB).

  window.fetch = function(url, opts) {
    if (opts && opts.method === 'PUT') {
      // Mock PUT — just succeed silently
      return {
        then: function(fn) { return { then: function(fn2) { return this; }, catch: function() { return this; } }; },
        catch: function() { return this; }
      };
    }
    // Mock GET — return 404
    return {
      then: function(fn) {
        var result = fn({ ok: false, status: 404 });
        return {
          then: function(fn2) {
            if (result && typeof result.then === 'function') {
              return result.then(fn2);
            }
            var r2 = fn2 ? fn2(result) : result;
            return {
              then: function(fn3) { if (fn3) fn3(r2); return this; },
              catch: function() { return this; }
            };
          },
          catch: function() { return this; }
        };
      },
      catch: function() { return this; }
    };
  };

})();
