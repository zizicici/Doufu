import JavaScriptCore
import XCTest

/// Tests for the doufu.db direct SQL API (DoufuDbAPI.js).
///
/// Uses the same JSContext + MockSqlJs approach as IndexedDBShimTests.
/// The IndexedDB shim is loaded first (it sets up `window.__doufuSQL`),
/// then DoufuDbAPI.js is loaded on top.
final class DoufuDbAPITests: XCTestCase {

    private var ctx: JSContext!

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        ctx = JSContext()
        ctx.exceptionHandler = { _, value in
            XCTFail("JS exception: \(value?.toString() ?? "nil")")
        }

        // ---- Polyfills (same as IndexedDBShimTests) ----

        ctx.evaluateScript("var window = this;")

        ctx.evaluateScript("""
        function DOMException(message, name) {
            this.message = message || '';
            this.name = name || 'Error';
        }
        DOMException.prototype = Object.create(Error.prototype);
        DOMException.prototype.constructor = DOMException;
        """)

        ctx.evaluateScript("""
        var __microtasks = [];
        var __macrotasks = [];

        var _OrigPromise = Promise;
        var _FakeResolvedPromise = {
            then: function(fn) {
                __microtasks.push(fn);
                return _FakeResolvedPromise;
            }
        };
        Promise = {
            resolve: function(v) { return _FakeResolvedPromise; },
            reject: function(e) {
                return {
                    then: function() { return this; },
                    catch: function(fn) { __microtasks.push(function() { fn(e); }); return _FakeResolvedPromise; }
                };
            },
            all: _OrigPromise.all.bind(_OrigPromise),
            _real: _OrigPromise
        };

        function setTimeout(fn, delay) {
            __macrotasks.push(fn);
            return __macrotasks.length;
        }
        function clearTimeout(id) {
            if (id > 0 && id <= __macrotasks.length) __macrotasks[id - 1] = null;
        }
        function setInterval(fn, delay) {
            __macrotasks.push(fn);
            return __macrotasks.length + 10000;
        }
        function clearInterval(id) {}

        function __drainMicrotasks() {
            var safety = 1000;
            while (__microtasks.length > 0 && safety-- > 0) {
                var batch = __microtasks.splice(0);
                for (var i = 0; i < batch.length; i++) batch[i]();
            }
        }

        function __drainAll() {
            var safety = 1000;
            while (safety-- > 0) {
                __drainMicrotasks();
                if (__macrotasks.length === 0) break;
                var batch = __macrotasks.splice(0);
                for (var i = 0; i < batch.length; i++) {
                    if (batch[i]) batch[i]();
                }
            }
            __drainMicrotasks();
        }
        """)

        ctx.evaluateScript("""
        var _b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
        function btoa(input) {
            var output = '';
            for (var i = 0; i < input.length; i += 3) {
                var a = input.charCodeAt(i), b = input.charCodeAt(i+1), c = input.charCodeAt(i+2);
                var enc1 = a >> 2, enc2 = ((a & 3) << 4) | ((b || 0) >> 4);
                var enc3 = isNaN(b) ? 64 : ((b & 15) << 2) | ((c || 0) >> 6);
                var enc4 = isNaN(c) ? 64 : (c & 63);
                output += _b64chars[enc1] + _b64chars[enc2]
                    + (enc3 === 64 ? '=' : _b64chars[enc3])
                    + (enc4 === 64 ? '=' : _b64chars[enc4]);
            }
            return output;
        }
        function atob(input) {
            input = input.replace(/=+$/, '');
            var output = '';
            for (var i = 0; i < input.length; i += 4) {
                var a = _b64chars.indexOf(input[i]), b = _b64chars.indexOf(input[i+1]);
                var c = _b64chars.indexOf(input[i+2]), d = _b64chars.indexOf(input[i+3]);
                output += String.fromCharCode((a << 2) | (b >> 4));
                if (c !== -1) output += String.fromCharCode(((b & 15) << 4) | (c >> 2));
                if (d !== -1) output += String.fromCharCode(((c & 3) << 6) | d);
            }
            return output;
        }
        """)

        ctx.evaluateScript("""
        function TextEncoder() {}
        TextEncoder.prototype.encode = function(str) {
            var arr = [];
            for (var i = 0; i < str.length; i++) {
                var code = str.charCodeAt(i);
                if (code < 0x80) { arr.push(code); }
                else if (code < 0x800) { arr.push(0xC0 | (code >> 6)); arr.push(0x80 | (code & 0x3F)); }
                else { arr.push(0xE0 | (code >> 12)); arr.push(0x80 | ((code >> 6) & 0x3F)); arr.push(0x80 | (code & 0x3F)); }
            }
            return new Uint8Array(arr);
        };
        function TextDecoder() {}
        TextDecoder.prototype.decode = function(arr) {
            if (!(arr instanceof Uint8Array)) arr = new Uint8Array(arr);
            var str = '';
            for (var i = 0; i < arr.length; ) {
                var byte = arr[i];
                if (byte < 0x80) { str += String.fromCharCode(byte); i++; }
                else if ((byte & 0xE0) === 0xC0) { str += String.fromCharCode(((byte & 0x1F) << 6) | (arr[i+1] & 0x3F)); i += 2; }
                else { str += String.fromCharCode(((byte & 0x0F) << 12) | ((arr[i+1] & 0x3F) << 6) | (arr[i+2] & 0x3F)); i += 3; }
            }
            return str;
        };
        """)

        // Load MockSqlJs
        let mockURL = productsURL(forResource: "MockSqlJs", withExtension: "js", inTests: true)
        let mockJS = try! String(contentsOf: mockURL)
        ctx.evaluateScript(mockJS)

        // Load the IndexedDB shim first (sets up window.__doufuSQL via initSqlJs)
        let shimURL = productsURL(forResource: "DoufuSqlJsIndexedDB", withExtension: "js")
        let shimJS = try! String(contentsOf: shimURL)
            .replacingOccurrences(of: "'__DOUFU_WASMURL__'", with: "'mock://sql-wasm.wasm'")
            .replacingOccurrences(of: "'__DOUFU_APPDATAURL__'", with: "'mock://appdata'")
        ctx.evaluateScript(shimJS)
        drain()

        // Replace the async-microtask Promise mock with a synchronous version.
        // doufu.db operations are all synchronous under the hood (sql.js + sync
        // fetch mock), so the sync Promise makes chained .then() work correctly
        // without needing multi-level microtask draining.
        ctx.evaluateScript("""
        (function() {
            function _SyncResolved(v) { this._v = v; }
            _SyncResolved.prototype.then = function(fn, rej) {
                if (!fn) return this;
                try {
                    var r = fn(this._v);
                    if (r && typeof r === 'object' && typeof r.then === 'function' && !(r instanceof _SyncResolved) && !(r instanceof _SyncRejected)) {
                        var out; var err;
                        r.then(function(v) { out = v; }, function(e) { err = e; });
                        if (err !== undefined) return new _SyncRejected(err);
                        return new _SyncResolved(out);
                    }
                    if (r instanceof _SyncRejected) return r;
                    return new _SyncResolved(r);
                } catch(e) { return new _SyncRejected(e); }
            };
            _SyncResolved.prototype.catch = function() { return this; };

            function _SyncRejected(e) { this._e = e; }
            _SyncRejected.prototype.then = function(fn, rej) {
                if (rej) return new _SyncResolved(rej(this._e));
                return this;
            };
            _SyncRejected.prototype.catch = function(fn) {
                if (fn) return new _SyncResolved(fn(this._e));
                return this;
            };

            Promise.resolve = function(v) { return new _SyncResolved(v); };
            Promise.reject = function(e) { return new _SyncRejected(e); };
        })();
        """)

        // Override fetch mock to use sync Promises (MockSqlJs fetch
        // doesn't call .then callbacks for PUT, breaking close() chains).
        ctx.evaluateScript("""
        var _mockFetchGET = window.fetch;
        window.fetch = function(url, opts) {
            if (opts && opts.method === 'PUT') return Promise.resolve();
            return _mockFetchGET(url, opts);
        };
        """)

        // Load DoufuDbAPI.js
        let dbAPIURL = productsURL(forResource: "DoufuDbAPI", withExtension: "js")
        let dbAPIJS = try! String(contentsOf: dbAPIURL)
            .replacingOccurrences(of: "'__DOUFU_APPDATAURL__'", with: "'mock://appdata'")
        ctx.evaluateScript(dbAPIJS)
        drain()
    }

    private func productsURL(forResource name: String, withExtension ext: String, inTests: Bool = false) -> URL {
        if let url = Bundle(for: type(of: self)).url(forResource: name, withExtension: ext) {
            return url
        }
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let subdir = inTests ? "DoufuTests" : "Doufu/Resources"
        let url = projectRoot.appendingPathComponent("\(subdir)/\(name).\(ext)")
        precondition(FileManager.default.fileExists(atPath: url.path),
                     "\(name).\(ext) not found at \(url.path)")
        return url
    }

    // MARK: - Helpers

    @discardableResult
    private func eval(_ js: String) -> JSValue? {
        ctx.evaluateScript(js)
    }

    private func drain() {
        eval("__drainAll()")
    }

    /// Open a doufu.db database. With sync Promise mock, resolves immediately.
    private func openDB(name: String = "testdb") {
        eval("""
        var __dbHandle = null;
        var __dbError = null;
        doufu.db.open('\(name)').then(function(h) { __dbHandle = h; });
        """)
    }

    // MARK: - Tests

    func testOpenReturnsHandle() {
        openDB()
        XCTAssertTrue(eval("__dbHandle !== null")!.toBool())
        XCTAssertTrue(eval("typeof __dbHandle === 'number'")!.toBool())
    }

    func testOpenSameNameReturnsSameHandle() {
        openDB()
        eval("""
        var __handle2 = null;
        doufu.db.open('testdb').then(function(h) { __handle2 = h; });
        """)
        XCTAssertTrue(eval("__handle2 === __dbHandle")!.toBool())
    }

    func testInvalidNameRejects() {
        eval("""
        var __rejected = false;
        doufu.db.open('bad name!').catch(function(e) { __rejected = true; });
        """)
        XCTAssertTrue(eval("__rejected")!.toBool())
    }

    func testCreateTableAndInsert() {
        openDB()
        eval("""
        var __runOk = false;
        doufu.db.run(__dbHandle, 'CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, name TEXT, value REAL)')
            .then(function() { __runOk = true; });
        """)
        XCTAssertTrue(eval("__runOk")!.toBool())

        eval("""
        var __insertOk = false;
        doufu.db.run(__dbHandle, 'INSERT INTO items (name, value) VALUES (?, ?)', ['score', 42])
            .then(function() { __insertOk = true; });
        """)
        XCTAssertTrue(eval("__insertOk")!.toBool())
    }

    func testExecReturnsResults() {
        openDB()
        eval("doufu.db.run(__dbHandle, 'CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, name TEXT, value REAL)');")
        eval("doufu.db.run(__dbHandle, 'INSERT INTO items (name, value) VALUES (?, ?)', ['alpha', 10]);")
        eval("doufu.db.run(__dbHandle, 'INSERT INTO items (name, value) VALUES (?, ?)', ['beta', 20]);")

        eval("""
        var __results = null;
        doufu.db.exec(__dbHandle, 'SELECT name, value FROM items ORDER BY value')
            .then(function(r) { __results = r; });
        """)

        XCTAssertTrue(eval("__results !== null")!.toBool())
        XCTAssertEqual(eval("__results.length")!.toInt32(), 1)
        XCTAssertEqual(eval("__results[0].columns.length")!.toInt32(), 2)
        XCTAssertEqual(eval("__results[0].values.length")!.toInt32(), 2)
        XCTAssertEqual(eval("__results[0].values[0][0]")!.toString(), "alpha")
        XCTAssertEqual(eval("__results[0].values[0][1]")!.toInt32(), 10)
        XCTAssertEqual(eval("__results[0].values[1][0]")!.toString(), "beta")
        XCTAssertEqual(eval("__results[0].values[1][1]")!.toInt32(), 20)
    }

    func testExecEmptyResult() {
        openDB()
        eval("doufu.db.run(__dbHandle, 'CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, name TEXT)');")

        eval("""
        var __results = null;
        doufu.db.exec(__dbHandle, 'SELECT * FROM items').then(function(r) { __results = r; });
        """)

        XCTAssertTrue(eval("__results !== null")!.toBool())
        XCTAssertEqual(eval("__results.length")!.toInt32(), 0)
    }

    func testUpdateAndDelete() {
        openDB()
        eval("doufu.db.run(__dbHandle, 'CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, name TEXT, value REAL)');")
        eval("doufu.db.run(__dbHandle, 'INSERT INTO items (name, value) VALUES (?, ?)', ['x', 1]);")

        // Update
        eval("doufu.db.run(__dbHandle, 'UPDATE items SET value = ? WHERE name = ?', [99, 'x']);")

        eval("""
        var __val = null;
        doufu.db.exec(__dbHandle, 'SELECT value FROM items WHERE name = ?', ['x'])
            .then(function(r) { __val = r[0].values[0][0]; });
        """)
        XCTAssertEqual(eval("__val")!.toInt32(), 99)

        // Delete
        eval("doufu.db.run(__dbHandle, 'DELETE FROM items WHERE name = ?', ['x']);")

        eval("""
        var __count = null;
        doufu.db.exec(__dbHandle, 'SELECT COUNT(*) FROM items')
            .then(function(r) { __count = r[0].values[0][0]; });
        """)
        XCTAssertEqual(eval("__count")!.toInt32(), 0)
    }

    func testRunWithInvalidHandleRejects() {
        eval("""
        var __err = null;
        doufu.db.run(9999, 'SELECT 1').catch(function(e) { __err = e.message; });
        """)
        XCTAssertTrue(eval("__err !== null")!.toBool())
    }

    func testExecWithInvalidHandleRejects() {
        eval("""
        var __err = null;
        doufu.db.exec(9999, 'SELECT 1').catch(function(e) { __err = e.message; });
        """)
        XCTAssertTrue(eval("__err !== null")!.toBool())
    }

    func testCloseAndReopenLosesHandle() {
        openDB()
        eval("doufu.db.run(__dbHandle, 'CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, name TEXT)');")

        eval("""
        var __closed = false;
        doufu.db.close(__dbHandle).then(function() { __closed = true; });
        """)
        XCTAssertTrue(eval("__closed")!.toBool())

        // Old handle should be invalid
        eval("""
        var __errAfterClose = null;
        doufu.db.run(__dbHandle, 'SELECT 1').catch(function(e) { __errAfterClose = e.message; });
        """)
        XCTAssertTrue(eval("__errAfterClose !== null")!.toBool())
    }

    func testMultipleDatabasesIndependent() {
        eval("""
        var __h1 = null, __h2 = null;
        doufu.db.open('db1').then(function(h) { __h1 = h; });
        doufu.db.open('db2').then(function(h) { __h2 = h; });
        """)

        XCTAssertTrue(eval("__h1 !== null && __h2 !== null")!.toBool())
        XCTAssertTrue(eval("__h1 !== __h2")!.toBool())

        eval("doufu.db.run(__h1, 'CREATE TABLE IF NOT EXISTS t1 (id INTEGER PRIMARY KEY, v TEXT)');")
        eval("doufu.db.run(__h1, 'INSERT INTO t1 (v) VALUES (?)', ['only-in-db1']);")

        // db2 should not have t1 data (MockSqlJs returns empty for non-existent tables)
        eval("""
        var __db2results = null;
        doufu.db.exec(__h2, 'SELECT * FROM t1').then(function(r) { __db2results = r; });
        """)
        XCTAssertEqual(eval("__db2results.length")!.toInt32(), 0)
    }

    func testExecSchedulesFlush() {
        openDB()
        eval("doufu.db.run(__dbHandle, 'CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, name TEXT)');")

        // Track if fetch PUT was called
        eval("""
        var __putCalled = false;
        var _origFetch = window.fetch;
        window.fetch = function(url, opts) {
            if (opts && opts.method === 'PUT') __putCalled = true;
            return _origFetch(url, opts);
        };
        """)

        // exec triggers _scheduleFlush (setTimeout), need drain to fire it
        eval("doufu.db.exec(__dbHandle, 'INSERT INTO items (name) VALUES (?)', ['test']);")
        drain() // fire the setTimeout from _scheduleFlush

        XCTAssertTrue(eval("__putCalled")!.toBool())
    }

    func testLastInsertRowId() {
        openDB()
        eval("doufu.db.run(__dbHandle, 'CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, name TEXT)');")
        eval("doufu.db.run(__dbHandle, 'INSERT INTO items (name) VALUES (?)', ['first']);")
        eval("doufu.db.run(__dbHandle, 'INSERT INTO items (name) VALUES (?)', ['second']);")

        eval("""
        var __lastId = null;
        doufu.db.exec(__dbHandle, 'SELECT last_insert_rowid()')
            .then(function(r) { __lastId = r[0].values[0][0]; });
        """)
        XCTAssertEqual(eval("__lastId")!.toInt32(), 2)
    }

    func testNameValidation() {
        // Valid names
        for name in ["mydb", "my-db", "my_db", "DB123"] {
            let varName = name.replacingOccurrences(of: "-", with: "_")
            eval("""
            var __ok_\(varName) = false;
            doufu.db.open('\(name)').then(function() { __ok_\(varName) = true; });
            """)
            XCTAssertTrue(eval("__ok_\(varName)")!.toBool(), "Name '\(name)' should be valid")
        }

        // Invalid names
        for name in ["bad name", "bad.name", "bad/name", ""] {
            eval("""
            var __bad = false;
            doufu.db.open('\(name)').catch(function() { __bad = true; });
            """)
            XCTAssertTrue(eval("__bad")!.toBool(), "Name '\(name)' should be rejected")
        }
    }
}
