(function() {
  'use strict';

  // ======== doufu.db.* — Direct SQL API ========
  // Provides simple SQLite access via sql.js, persisted to AppData/{name}.sqlite.

  var _APPDATAURL = '__DOUFU_APPDATAURL__';
  var _handles = {};     // name → { db, flushTimer, dirty }
  var _nextHandle = 1;
  var _handleMap = {};   // handleId → name

  function _validName(name) {
    return typeof name === 'string' && /^[a-zA-Z0-9_-]+$/.test(name);
  }

  function _waitForSQL() {
    if (window.__doufuSQL) return Promise.resolve(window.__doufuSQL);
    return new Promise(function(resolve) {
      var check = setInterval(function() {
        if (window.__doufuSQL) { clearInterval(check); resolve(window.__doufuSQL); }
      }, 50);
    });
  }

  function _scheduleFlush(name) {
    var h = _handles[name];
    if (!h) return;
    h.dirty = true;
    if (h.flushTimer) clearTimeout(h.flushTimer);
    h.flushTimer = setTimeout(function() {
      h.flushTimer = null;
      if (!h.db) return;
      var data = h.db.export();
      fetch(_APPDATAURL + '/' + encodeURIComponent(name) + '.sqlite', { method: 'PUT', body: data })
        .then(function() { h.dirty = false; })
        .catch(function(e) { console.error('[Doufu] db persist failed:', e); });
    }, 80);
  }

  if (typeof window !== 'undefined' && typeof window.addEventListener === 'function') {
    var _flushAllDbs = function() {
      for (var name in _handles) {
        var h = _handles[name];
        if (h.dirty && h.db) {
          if (h.flushTimer) { clearTimeout(h.flushTimer); h.flushTimer = null; }
          var data = h.db.export();
          try {
            var xhr = new XMLHttpRequest();
            xhr.open('PUT', _APPDATAURL + '/' + encodeURIComponent(name) + '.sqlite', false);
            xhr.send(data);
          } catch(e) {
            fetch(_APPDATAURL + '/' + encodeURIComponent(name) + '.sqlite', { method: 'PUT', body: data })
              .catch(function() {});
          }
          h.dirty = false;
        }
      }
    };
    window.addEventListener('beforeunload', _flushAllDbs);
    window.addEventListener('pagehide', _flushAllDbs);
  }

  window.doufu = window.doufu || {};
  window.doufu.db = {
    open: function(name) {
      if (!_validName(name)) return Promise.reject(new Error('Invalid database name. Use [a-zA-Z0-9_-] only.'));
      if (_handles[name]) {
        // Already open — return existing handle
        for (var hid in _handleMap) {
          if (_handleMap[hid] === name) return Promise.resolve(parseInt(hid));
        }
      }
      return _waitForSQL().then(function(SQL) {
        return fetch(_APPDATAURL + '/' + encodeURIComponent(name) + '.sqlite')
          .then(function(r) {
            if (r.ok) return r.arrayBuffer().then(function(b) {
              return new SQL.Database(new Uint8Array(b));
            });
            return new SQL.Database();
          })
          .then(function(db) {
            var id = _nextHandle++;
            _handles[name] = { db: db, flushTimer: null, dirty: false };
            _handleMap[id] = name;
            return id;
          });
      });
    },

    exec: function(handle, sql, params) {
      var name = _handleMap[handle];
      if (!name || !_handles[name]) return Promise.reject(new Error('Invalid handle'));
      try {
        var results = _handles[name].db.exec(sql, params || []);
        // Schedule persist so that INSERT/UPDATE/DELETE ... RETURNING is durable.
        // For pure SELECTs the flush is a no-op (exports unchanged data).
        _scheduleFlush(name);
        return Promise.resolve(results);
      } catch(e) {
        return Promise.reject(e);
      }
    },

    run: function(handle, sql, params) {
      var name = _handleMap[handle];
      if (!name || !_handles[name]) return Promise.reject(new Error('Invalid handle'));
      try {
        _handles[name].db.run(sql, params || []);
        _scheduleFlush(name);
        return Promise.resolve();
      } catch(e) {
        return Promise.reject(e);
      }
    },

    close: function(handle) {
      var name = _handleMap[handle];
      if (!name || !_handles[name]) return Promise.resolve();
      var h = _handles[name];
      // Flush immediately before closing
      if (h.flushTimer) clearTimeout(h.flushTimer);
      var flushPromise;
      if (h.db) {
        var data = h.db.export();
        flushPromise = fetch(_APPDATAURL + '/' + encodeURIComponent(name) + '.sqlite', { method: 'PUT', body: data })
          .catch(function() {});
      } else {
        flushPromise = Promise.resolve();
      }
      return flushPromise.then(function() {
        if (h.db) { try { h.db.close(); } catch(e) {} }
        delete _handles[name];
        delete _handleMap[handle];
      });
    }
  };

  // Exposed for native to flush all open databases synchronously before
  // page navigation or WebView teardown (same pattern as __doufuIDBCancelPersist).
  window.__doufuDbFlushAllSync = _flushAllDbs;

})();
