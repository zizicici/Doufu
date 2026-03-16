import JavaScriptCore
import XCTest

/// Tests for the IndexedDB JavaScript shim (DoufuSqlJsIndexedDB.js).
///
/// The shim runs in a `JSContext` (JavaScriptCore). Because JSC lacks browser
/// APIs (`window`, `DOMException`, `setTimeout`, `Promise.resolve().then()`
/// microtask draining, `fetch`, `TextEncoder/TextDecoder`), we inject lightweight
/// polyfills, a `MockSqlJs.js` that provides the sql.js API surface without WASM,
/// and a manual `__drainAll()` function that deterministically flushes both
/// microtask and macrotask queues.
final class IndexedDBShimTests: XCTestCase {

    private var ctx: JSContext!

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        ctx = JSContext()
        ctx.exceptionHandler = { _, value in
            XCTFail("JS exception: \(value?.toString() ?? "nil")")
        }

        // ---- Polyfills ----

        // `window` = global object
        ctx.evaluateScript("var window = this;")

        // `DOMException`
        ctx.evaluateScript("""
        function DOMException(message, name) {
            this.message = message || '';
            this.name = name || 'Error';
        }
        DOMException.prototype = Object.create(Error.prototype);
        DOMException.prototype.constructor = DOMException;
        """)

        // Manual microtask / macrotask queues.
        ctx.evaluateScript("""
        var __microtasks = [];
        var __macrotasks = [];

        // Override Promise.resolve().then to queue instead of relying on JSC event loop.
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
            all: function(arr) {
                var results = [];
                for (var i = 0; i < arr.length; i++) {
                    (function(idx) {
                        if (arr[idx] && typeof arr[idx].then === 'function') {
                            arr[idx].then(function(v) { results[idx] = v; });
                        } else {
                            results[idx] = arr[idx];
                        }
                    })(i);
                }
                function _chain(val) {
                    return {
                        then: function(fn) { return _chain(fn(val)); },
                        catch: function() { return this; }
                    };
                }
                return _chain(results);
            },
            // Keep real Promise for databases() which returns a real promise
            _real: _OrigPromise
        };

        function setTimeout(fn, delay) {
            __macrotasks.push(fn);
            return __macrotasks.length;
        }

        function clearTimeout(id) {
            // Simple: just null out the entry
            if (id > 0 && id <= __macrotasks.length) __macrotasks[id - 1] = null;
        }

        function setInterval(fn, delay) {
            // Not truly periodic in test — just push once
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

        // btoa/atob polyfill (not available in JSC)
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

        // TextEncoder/TextDecoder polyfill (not available in JSC)
        ctx.evaluateScript("""
        function TextEncoder() {}
        TextEncoder.prototype.encode = function(str) {
            var arr = [];
            for (var i = 0; i < str.length; i++) {
                var code = str.charCodeAt(i);
                if (code < 0x80) {
                    arr.push(code);
                } else if (code < 0x800) {
                    arr.push(0xC0 | (code >> 6));
                    arr.push(0x80 | (code & 0x3F));
                } else {
                    arr.push(0xE0 | (code >> 12));
                    arr.push(0x80 | ((code >> 6) & 0x3F));
                    arr.push(0x80 | (code & 0x3F));
                }
            }
            return new Uint8Array(arr);
        };

        function TextDecoder() {}
        TextDecoder.prototype.decode = function(arr) {
            if (!(arr instanceof Uint8Array)) arr = new Uint8Array(arr);
            var str = '';
            for (var i = 0; i < arr.length; ) {
                var byte = arr[i];
                if (byte < 0x80) {
                    str += String.fromCharCode(byte);
                    i++;
                } else if ((byte & 0xE0) === 0xC0) {
                    str += String.fromCharCode(((byte & 0x1F) << 6) | (arr[i+1] & 0x3F));
                    i += 2;
                } else {
                    str += String.fromCharCode(((byte & 0x0F) << 12) | ((arr[i+1] & 0x3F) << 6) | (arr[i+2] & 0x3F));
                    i += 3;
                }
            }
            return str;
        };
        """)

        // Load MockSqlJs (provides initSqlJs and fetch mocks)
        let mockURL = productsURL(forResource: "MockSqlJs", withExtension: "js", inTests: true)
        let mockJS = try! String(contentsOf: mockURL)
        ctx.evaluateScript(mockJS)

        // Load the new shim with placeholders replaced
        let shimURL = productsURL(forResource: "DoufuSqlJsIndexedDB", withExtension: "js")
        let shimJS = try! String(contentsOf: shimURL)
            .replacingOccurrences(of: "'__DOUFU_WASMURL__'", with: "'mock://sql-wasm.wasm'")
            .replacingOccurrences(of: "'__DOUFU_APPDATAURL__'", with: "'mock://appdata'")
        ctx.evaluateScript(shimJS)

        // Drain to complete async initialization (initSqlJs → fetch → _flushPending)
        drain()
    }

    /// Locate a .js resource from the test bundle or file system.
    private func productsURL(forResource name: String, withExtension ext: String, inTests: Bool = false) -> URL {
        // Try test bundle first
        if let url = Bundle(for: type(of: self)).url(forResource: name, withExtension: ext) {
            return url
        }
        // Fallback: direct file path relative to project root
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DoufuTests/
            .deletingLastPathComponent() // project root
        let subdir = inTests ? "DoufuTests" : "Doufu/Resources"
        let url = projectRoot
            .appendingPathComponent("\(subdir)/\(name).\(ext)")
        precondition(FileManager.default.fileExists(atPath: url.path),
                     "\(name).\(ext) not found at \(url.path)")
        return url
    }

    // MARK: - Helpers

    @discardableResult
    private func eval(_ js: String) -> JSValue? {
        return ctx.evaluateScript(js)
    }

    private func drain() {
        eval("__drainAll()")
    }

    /// Open a database, create stores in `onupgradeneeded`, drain, and return
    /// the JS variable name holding the `IDBDatabase`.
    private func openDB(
        name: String = "testDB",
        version: Int = 1,
        upgrade: String = ""
    ) {
        eval("""
        var __db = null;
        var __upgradeRan = false;
        var req = indexedDB.open('\(name)', \(version));
        req.onupgradeneeded = function(e) {
            var db = e.target.result;
            \(upgrade)
            __upgradeRan = true;
        };
        req.onsuccess = function(e) { __db = e.target.result; };
        """)
        drain()
    }

    // MARK: - Tests

    func testOpenAndUpgrade() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")
        XCTAssertTrue(eval("__upgradeRan")!.toBool())
        XCTAssertTrue(eval("__db !== null")!.toBool())
        XCTAssertEqual(eval("__db.name")!.toString(), "testDB")
        XCTAssertEqual(eval("__db.version")!.toInt32(), 1)
        XCTAssertTrue(eval("__db.objectStoreNames.contains('items')")!.toBool())
    }

    func testPutAndGet() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var __getResult = null;
        var tx = __db.transaction('items', 'readwrite');
        var store = tx.objectStore('items');
        store.put({ id: 1, name: 'Alice' });
        store.put({ id: 2, name: 'Bob' });
        """)
        drain()

        // Read back
        eval("""
        var tx2 = __db.transaction('items', 'readonly');
        var store2 = tx2.objectStore('items');
        var gr = store2.get(1);
        gr.onsuccess = function() { __getResult = gr.result; };
        """)
        drain()

        XCTAssertEqual(eval("__getResult.name")!.toString(), "Alice")
    }

    func testGetAll() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        var s = tx.objectStore('items');
        s.put({ id: 1, name: 'A' });
        s.put({ id: 2, name: 'B' });
        s.put({ id: 3, name: 'C' });
        """)
        drain()

        eval("""
        var __all = null;
        var tx2 = __db.transaction('items', 'readonly');
        var s2 = tx2.objectStore('items');
        var r = s2.getAll();
        r.onsuccess = function() { __all = r.result; };
        """)
        drain()

        XCTAssertEqual(eval("__all.length")!.toInt32(), 3)
        XCTAssertEqual(eval("__all[0].name")!.toString(), "A")
        XCTAssertEqual(eval("__all[2].name")!.toString(), "C")
    }

    func testGetAllKeys() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        var s = tx.objectStore('items');
        s.put({ id: 10, name: 'X' });
        s.put({ id: 20, name: 'Y' });
        """)
        drain()

        eval("""
        var __keys = null;
        var tx2 = __db.transaction('items', 'readonly');
        var r = tx2.objectStore('items').getAllKeys();
        r.onsuccess = function() { __keys = r.result; };
        """)
        drain()

        XCTAssertEqual(eval("__keys.length")!.toInt32(), 2)
        XCTAssertEqual(eval("__keys[0]")!.toInt32(), 10)
        XCTAssertEqual(eval("__keys[1]")!.toInt32(), 20)
    }

    func testAddDuplicateKeyFails() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var __addError = null;
        var tx = __db.transaction('items', 'readwrite');
        var s = tx.objectStore('items');
        s.add({ id: 1, name: 'Alice' });
        var r = s.add({ id: 1, name: 'Bob' });
        r.onerror = function() { __addError = r.error.name; };
        """)
        drain()

        XCTAssertEqual(eval("__addError")!.toString(), "ConstraintError")
    }

    func testDeleteRecord() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        var s = tx.objectStore('items');
        s.put({ id: 1, name: 'Alice' });
        s.put({ id: 2, name: 'Bob' });
        """)
        drain()

        eval("""
        var tx2 = __db.transaction('items', 'readwrite');
        tx2.objectStore('items').delete(1);
        """)
        drain()

        eval("""
        var __cnt = -1;
        var tx3 = __db.transaction('items', 'readonly');
        var r = tx3.objectStore('items').count();
        r.onsuccess = function() { __cnt = r.result; };
        """)
        drain()

        XCTAssertEqual(eval("__cnt")!.toInt32(), 1)
    }

    func testClear() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        var s = tx.objectStore('items');
        s.put({ id: 1 }); s.put({ id: 2 }); s.put({ id: 3 });
        """)
        drain()

        eval("""
        var tx2 = __db.transaction('items', 'readwrite');
        tx2.objectStore('items').clear();
        """)
        drain()

        eval("""
        var __cnt = -1;
        var tx3 = __db.transaction('items', 'readonly');
        var r = tx3.objectStore('items').count();
        r.onsuccess = function() { __cnt = r.result; };
        """)
        drain()

        XCTAssertEqual(eval("__cnt")!.toInt32(), 0)
    }

    func testAutoIncrement() {
        openDB(upgrade: "db.createObjectStore('items', { autoIncrement: true });")

        eval("""
        var __k1 = null, __k2 = null;
        var tx = __db.transaction('items', 'readwrite');
        var s = tx.objectStore('items');
        var r1 = s.add({ name: 'Alice' });
        r1.onsuccess = function() { __k1 = r1.result; };
        var r2 = s.add({ name: 'Bob' });
        r2.onsuccess = function() { __k2 = r2.result; };
        """)
        drain()

        XCTAssertEqual(eval("__k1")!.toInt32(), 1)
        XCTAssertEqual(eval("__k2")!.toInt32(), 2)
    }

    func testAutoIncrementWithKeyPath() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id', autoIncrement: true });")

        eval("""
        var __val = null;
        var tx = __db.transaction('items', 'readwrite');
        var s = tx.objectStore('items');
        s.add({ name: 'Alice' });
        """)
        drain()

        eval("""
        var tx2 = __db.transaction('items', 'readonly');
        var r = tx2.objectStore('items').get(1);
        r.onsuccess = function() { __val = r.result; };
        """)
        drain()

        XCTAssertEqual(eval("__val.id")!.toInt32(), 1)
        XCTAssertEqual(eval("__val.name")!.toString(), "Alice")
    }

    func testKeyPathDotNotation() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'meta.id' });")

        eval("""
        var __val = null;
        var tx = __db.transaction('items', 'readwrite');
        tx.objectStore('items').put({ meta: { id: 42 }, name: 'Deep' });
        """)
        drain()

        eval("""
        var tx2 = __db.transaction('items', 'readonly');
        var r = tx2.objectStore('items').get(42);
        r.onsuccess = function() { __val = r.result; };
        """)
        drain()

        XCTAssertEqual(eval("__val.name")!.toString(), "Deep")
    }

    func testCursorForward() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        var s = tx.objectStore('items');
        s.put({ id: 3 }); s.put({ id: 1 }); s.put({ id: 2 });
        """)
        drain()

        eval("""
        var __keys = [];
        var tx2 = __db.transaction('items', 'readonly');
        var r = tx2.objectStore('items').openCursor();
        r.onsuccess = function() {
            var cursor = r.result;
            if (cursor) { __keys.push(cursor.key); cursor.continue(); }
        };
        """)
        drain()

        XCTAssertEqual(eval("__keys.length")!.toInt32(), 3)
        XCTAssertEqual(eval("__keys[0]")!.toInt32(), 1)
        XCTAssertEqual(eval("__keys[1]")!.toInt32(), 2)
        XCTAssertEqual(eval("__keys[2]")!.toInt32(), 3)
    }

    func testCursorReverse() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        var s = tx.objectStore('items');
        s.put({ id: 1 }); s.put({ id: 2 }); s.put({ id: 3 });
        """)
        drain()

        eval("""
        var __keys = [];
        var tx2 = __db.transaction('items', 'readonly');
        var r = tx2.objectStore('items').openCursor(null, 'prev');
        r.onsuccess = function() {
            var cursor = r.result;
            if (cursor) { __keys.push(cursor.key); cursor.continue(); }
        };
        """)
        drain()

        XCTAssertEqual(eval("__keys[0]")!.toInt32(), 3)
        XCTAssertEqual(eval("__keys[1]")!.toInt32(), 2)
        XCTAssertEqual(eval("__keys[2]")!.toInt32(), 1)
    }

    func testIndex() {
        openDB(upgrade: """
        var store = db.createObjectStore('users', { keyPath: 'id' });
        store.createIndex('by_name', 'name', { unique: false });
        """)

        eval("""
        var tx = __db.transaction('users', 'readwrite');
        var s = tx.objectStore('users');
        s.put({ id: 1, name: 'Charlie' });
        s.put({ id: 2, name: 'Alice' });
        s.put({ id: 3, name: 'Bob' });
        """)
        drain()

        eval("""
        var __idxResult = null;
        var tx2 = __db.transaction('users', 'readonly');
        var idx = tx2.objectStore('users').index('by_name');
        var r = idx.get('Bob');
        r.onsuccess = function() { __idxResult = r.result; };
        """)
        drain()

        XCTAssertEqual(eval("__idxResult.id")!.toInt32(), 3)
    }

    func testIndexGetAll() {
        openDB(upgrade: """
        var store = db.createObjectStore('users', { keyPath: 'id' });
        store.createIndex('by_age', 'age', { unique: false });
        """)

        eval("""
        var tx = __db.transaction('users', 'readwrite');
        var s = tx.objectStore('users');
        s.put({ id: 1, age: 25 });
        s.put({ id: 2, age: 30 });
        s.put({ id: 3, age: 25 });
        """)
        drain()

        eval("""
        var __all = null;
        var tx2 = __db.transaction('users', 'readonly');
        var r = tx2.objectStore('users').index('by_age').getAll(25);
        r.onsuccess = function() { __all = r.result; };
        """)
        drain()

        XCTAssertEqual(eval("__all.length")!.toInt32(), 2)
    }

    func testUniqueIndexConstraint() {
        openDB(upgrade: """
        var store = db.createObjectStore('users', { keyPath: 'id' });
        store.createIndex('by_email', 'email', { unique: true });
        """)

        eval("""
        var __err = null;
        var tx = __db.transaction('users', 'readwrite');
        var s = tx.objectStore('users');
        s.put({ id: 1, email: 'a@b.com' });
        var r = s.put({ id: 2, email: 'a@b.com' });
        r.onerror = function() { __err = r.error.name; };
        """)
        drain()

        XCTAssertEqual(eval("__err")!.toString(), "ConstraintError")
    }

    func testUniqueIndexAllowsSameKeyOnUpdate() {
        openDB(upgrade: """
        var store = db.createObjectStore('users', { keyPath: 'id' });
        store.createIndex('by_email', 'email', { unique: true });
        """)

        eval("""
        var __ok = false;
        var tx = __db.transaction('users', 'readwrite');
        var s = tx.objectStore('users');
        s.put({ id: 1, email: 'a@b.com' });
        """)
        drain()

        // Updating the same record (same primary key) should be fine
        eval("""
        var tx2 = __db.transaction('users', 'readwrite');
        var r = tx2.objectStore('users').put({ id: 1, email: 'a@b.com', name: 'Updated' });
        r.onsuccess = function() { __ok = true; };
        """)
        drain()

        XCTAssertTrue(eval("__ok")!.toBool())
    }

    func testDeleteDatabase() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var __deleted = false;
        var r = indexedDB.deleteDatabase('testDB');
        r.onsuccess = function() { __deleted = true; };
        """)
        drain()

        XCTAssertTrue(eval("__deleted")!.toBool())

        // Re-opening should trigger upgrade from version 0
        eval("""
        var __newUpgrade = false;
        var r2 = indexedDB.open('testDB', 1);
        r2.onupgradeneeded = function(e) {
            __newUpgrade = true;
        };
        r2.onsuccess = function() {};
        """)
        drain()

        XCTAssertTrue(eval("__newUpgrade")!.toBool())
    }

    func testKeyRangeBound() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        var s = tx.objectStore('items');
        for (var i = 1; i <= 10; i++) s.put({ id: i });
        """)
        drain()

        eval("""
        var __result = null;
        var tx2 = __db.transaction('items', 'readonly');
        var r = tx2.objectStore('items').getAll(IDBKeyRange.bound(3, 7));
        r.onsuccess = function() { __result = r.result; };
        """)
        drain()

        XCTAssertEqual(eval("__result.length")!.toInt32(), 5)
        XCTAssertEqual(eval("__result[0].id")!.toInt32(), 3)
        XCTAssertEqual(eval("__result[4].id")!.toInt32(), 7)
    }

    func testKeyRangeOpenBounds() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        var s = tx.objectStore('items');
        for (var i = 1; i <= 5; i++) s.put({ id: i });
        """)
        drain()

        // Open lower bound (exclude 2), open upper bound (exclude 4)
        eval("""
        var __result = null;
        var tx2 = __db.transaction('items', 'readonly');
        var r = tx2.objectStore('items').getAll(IDBKeyRange.bound(2, 4, true, true));
        r.onsuccess = function() { __result = r.result; };
        """)
        drain()

        XCTAssertEqual(eval("__result.length")!.toInt32(), 1)
        XCTAssertEqual(eval("__result[0].id")!.toInt32(), 3)
    }

    func testVersionUpgrade() {
        // Open v1
        openDB(name: "upgradeDB", version: 1, upgrade: """
        db.createObjectStore('v1store', { keyPath: 'id' });
        """)

        // Insert data
        eval("""
        var tx = __db.transaction('v1store', 'readwrite');
        tx.objectStore('v1store').put({ id: 1, data: 'v1' });
        """)
        drain()

        // Open v2 — should trigger upgrade
        eval("""
        var __v2upgrade = false;
        var __v2db = null;
        var r = indexedDB.open('upgradeDB', 2);
        r.onupgradeneeded = function(e) {
            __v2upgrade = true;
            e.target.result.createObjectStore('v2store', { keyPath: 'id' });
        };
        r.onsuccess = function(e) { __v2db = e.target.result; };
        """)
        drain()

        XCTAssertTrue(eval("__v2upgrade")!.toBool())
        XCTAssertEqual(eval("__v2db.version")!.toInt32(), 2)
        XCTAssertTrue(eval("__v2db.objectStoreNames.contains('v1store')")!.toBool())
        XCTAssertTrue(eval("__v2db.objectStoreNames.contains('v2store')")!.toBool())

        // Old data should still be there
        eval("""
        var __oldData = null;
        var tx2 = __v2db.transaction('v1store', 'readonly');
        var r2 = tx2.objectStore('v1store').get(1);
        r2.onsuccess = function() { __oldData = r2.result; };
        """)
        drain()

        XCTAssertEqual(eval("__oldData.data")!.toString(), "v1")
    }

    func testCmpFunction() {
        XCTAssertEqual(eval("indexedDB.cmp(1, 2)")!.toInt32(), -1)
        XCTAssertEqual(eval("indexedDB.cmp(2, 2)")!.toInt32(), 0)
        XCTAssertEqual(eval("indexedDB.cmp(3, 2)")!.toInt32(), 1)
        XCTAssertEqual(eval("indexedDB.cmp('a', 'b')")!.toInt32(), -1)
        // Numbers come before strings in IDB key ordering
        XCTAssertEqual(eval("indexedDB.cmp(1, 'a')")!.toInt32(), -1)
    }

    func testMultipleObjectStores() {
        openDB(upgrade: """
        db.createObjectStore('a', { keyPath: 'id' });
        db.createObjectStore('b', { keyPath: 'id' });
        """)

        eval("""
        var tx = __db.transaction(['a', 'b'], 'readwrite');
        tx.objectStore('a').put({ id: 1, from: 'a' });
        tx.objectStore('b').put({ id: 1, from: 'b' });
        """)
        drain()

        eval("""
        var __ra = null, __rb = null;
        var tx2 = __db.transaction(['a', 'b'], 'readonly');
        var r1 = tx2.objectStore('a').get(1);
        r1.onsuccess = function() { __ra = r1.result; };
        var r2 = tx2.objectStore('b').get(1);
        r2.onsuccess = function() { __rb = r2.result; };
        """)
        drain()

        XCTAssertEqual(eval("__ra.from")!.toString(), "a")
        XCTAssertEqual(eval("__rb.from")!.toString(), "b")
    }

    func testPutOverwrite() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        var s = tx.objectStore('items');
        s.put({ id: 1, name: 'Alice' });
        s.put({ id: 1, name: 'Updated' });
        """)
        drain()

        eval("""
        var __val = null;
        var tx2 = __db.transaction('items', 'readonly');
        var r = tx2.objectStore('items').get(1);
        r.onsuccess = function() { __val = r.result; };
        """)
        drain()

        XCTAssertEqual(eval("__val.name")!.toString(), "Updated")
    }

    func testCount() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        var s = tx.objectStore('items');
        s.put({ id: 1 }); s.put({ id: 2 }); s.put({ id: 3 });
        """)
        drain()

        eval("""
        var __total = -1, __ranged = -1;
        var tx2 = __db.transaction('items', 'readonly');
        var s2 = tx2.objectStore('items');
        var r1 = s2.count();
        r1.onsuccess = function() { __total = r1.result; };
        var r2 = s2.count(IDBKeyRange.bound(1, 2));
        r2.onsuccess = function() { __ranged = r2.result; };
        """)
        drain()

        XCTAssertEqual(eval("__total")!.toInt32(), 3)
        XCTAssertEqual(eval("__ranged")!.toInt32(), 2)
    }

    func testIndexCursor() {
        openDB(upgrade: """
        var store = db.createObjectStore('users', { keyPath: 'id' });
        store.createIndex('by_name', 'name');
        """)

        eval("""
        var tx = __db.transaction('users', 'readwrite');
        var s = tx.objectStore('users');
        s.put({ id: 1, name: 'Charlie' });
        s.put({ id: 2, name: 'Alice' });
        s.put({ id: 3, name: 'Bob' });
        """)
        drain()

        // Cursor on index should iterate in index key order (alphabetical)
        eval("""
        var __names = [];
        var tx2 = __db.transaction('users', 'readonly');
        var r = tx2.objectStore('users').index('by_name').openCursor();
        r.onsuccess = function() {
            var c = r.result;
            if (c) { __names.push(c.value.name); c.continue(); }
        };
        """)
        drain()

        XCTAssertEqual(eval("__names[0]")!.toString(), "Alice")
        XCTAssertEqual(eval("__names[1]")!.toString(), "Bob")
        XCTAssertEqual(eval("__names[2]")!.toString(), "Charlie")
    }

    func testArrayBufferRoundTrip() {
        openDB(upgrade: "db.createObjectStore('bin', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('bin', 'readwrite');
        var buf = new Uint8Array([72, 101, 108, 108, 111]).buffer; // "Hello"
        tx.objectStore('bin').put({ id: 1, data: buf });
        """)
        drain()

        eval("""
        var __val = null;
        var tx2 = __db.transaction('bin', 'readonly');
        var r = tx2.objectStore('bin').get(1);
        r.onsuccess = function() { __val = r.result; };
        """)
        drain()

        XCTAssertTrue(eval("__val.data instanceof ArrayBuffer")!.toBool())
        XCTAssertEqual(eval("new Uint8Array(__val.data).length")!.toInt32(), 5)
        XCTAssertEqual(eval("new Uint8Array(__val.data)[0]")!.toInt32(), 72)  // 'H'
        XCTAssertEqual(eval("new Uint8Array(__val.data)[4]")!.toInt32(), 111) // 'o'
    }

    func testTypedArrayRoundTrip() {
        openDB(upgrade: "db.createObjectStore('bin', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('bin', 'readwrite');
        var s = tx.objectStore('bin');
        s.put({ id: 1, data: new Uint8Array([1, 2, 3]) });
        s.put({ id: 2, data: new Float32Array([1.5, 2.5]) });
        """)
        drain()

        eval("""
        var __u8 = null, __f32 = null;
        var tx2 = __db.transaction('bin', 'readonly');
        var s2 = tx2.objectStore('bin');
        var r1 = s2.get(1);
        r1.onsuccess = function() { __u8 = r1.result.data; };
        var r2 = s2.get(2);
        r2.onsuccess = function() { __f32 = r2.result.data; };
        """)
        drain()

        XCTAssertTrue(eval("__u8 instanceof Uint8Array")!.toBool())
        XCTAssertEqual(eval("__u8.length")!.toInt32(), 3)
        XCTAssertEqual(eval("__u8[2]")!.toInt32(), 3)

        XCTAssertTrue(eval("__f32 instanceof Float32Array")!.toBool())
        XCTAssertEqual(eval("__f32.length")!.toInt32(), 2)
        XCTAssertEqual(eval("__f32[0]")!.toDouble(), 1.5)
    }

    func testTransactionAbortRollback() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        // Insert baseline
        eval("""
        var tx = __db.transaction('items', 'readwrite');
        tx.objectStore('items').put({ id: 1, name: 'Original' });
        """)
        drain()

        // Modify then abort
        eval("""
        var tx2 = __db.transaction('items', 'readwrite');
        var s = tx2.objectStore('items');
        s.put({ id: 1, name: 'Modified' });
        s.put({ id: 2, name: 'New' });
        tx2.abort();
        """)
        drain()

        // Verify rollback
        eval("""
        var __val = null, __cnt = -1;
        var tx3 = __db.transaction('items', 'readonly');
        var s3 = tx3.objectStore('items');
        var r = s3.get(1);
        r.onsuccess = function() { __val = r.result; };
        var r2 = s3.count();
        r2.onsuccess = function() { __cnt = r2.result; };
        """)
        drain()

        XCTAssertEqual(eval("__val.name")!.toString(), "Original")
        XCTAssertEqual(eval("__cnt")!.toInt32(), 1)
    }

    // MARK: - Gap Fix Tests

    func testMapSetRoundTrip() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        var s = tx.objectStore('items');
        s.put({ id: 1, tags: new Set(['a', 'b', 'c']), meta: new Map([['x', 1], ['y', 2]]) });
        """)
        drain()

        eval("""
        var __val = null;
        var tx2 = __db.transaction('items', 'readonly');
        var r = tx2.objectStore('items').get(1);
        r.onsuccess = function() { __val = r.result; };
        """)
        drain()

        XCTAssertTrue(eval("__val.tags instanceof Set")!.toBool())
        XCTAssertEqual(eval("__val.tags.size")!.toInt32(), 3)
        XCTAssertTrue(eval("__val.tags.has('b')")!.toBool())
        XCTAssertTrue(eval("__val.meta instanceof Map")!.toBool())
        XCTAssertEqual(eval("__val.meta.get('x')")!.toInt32(), 1)
    }

    func testRegExpRoundTrip() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        tx.objectStore('items').put({ id: 1, pattern: /hello\\sworld/gi });
        """)
        drain()

        eval("""
        var __val = null;
        var tx2 = __db.transaction('items', 'readonly');
        var r = tx2.objectStore('items').get(1);
        r.onsuccess = function() { __val = r.result; };
        """)
        drain()

        XCTAssertTrue(eval("__val.pattern instanceof RegExp")!.toBool())
        XCTAssertEqual(eval("__val.pattern.source")!.toString(), "hello\\sworld")
        XCTAssertTrue(eval("__val.pattern.global")!.toBool())
        XCTAssertTrue(eval("__val.pattern.ignoreCase")!.toBool())
    }

    func testInvalidKeyRejected() {
        openDB(upgrade: "db.createObjectStore('items');")

        // null key should fail
        eval("""
        var __err1 = null;
        var tx = __db.transaction('items', 'readwrite');
        var r = tx.objectStore('items').put({ x: 1 }, null);
        r.onerror = function() { __err1 = r.error.name; };
        """)
        drain()
        XCTAssertEqual(eval("__err1")!.toString(), "DataError")

        // boolean key should fail
        eval("""
        var __err2 = null;
        var tx2 = __db.transaction('items', 'readwrite');
        var r2 = tx2.objectStore('items').put({ x: 1 }, true);
        r2.onerror = function() { __err2 = r2.error.name; };
        """)
        drain()
        XCTAssertEqual(eval("__err2")!.toString(), "DataError")
    }

    func testVersionDowngradeRejected() {
        openDB(name: "vDB", version: 3, upgrade: "db.createObjectStore('s');")

        eval("""
        var __downgradeErr = null;
        var req = indexedDB.open('vDB', 1);
        req.onerror = function() { __downgradeErr = req.error.name; };
        req.onsuccess = function() {};
        """)
        drain()

        XCTAssertEqual(eval("__downgradeErr")!.toString(), "VersionError")
    }

    func testCursorNextUnique() {
        openDB(upgrade: """
        var store = db.createObjectStore('items', { keyPath: 'id' });
        store.createIndex('by_cat', 'cat');
        """)

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        var s = tx.objectStore('items');
        s.put({ id: 1, cat: 'A' });
        s.put({ id: 2, cat: 'A' });
        s.put({ id: 3, cat: 'B' });
        s.put({ id: 4, cat: 'B' });
        s.put({ id: 5, cat: 'C' });
        """)
        drain()

        eval("""
        var __cats = [];
        var tx2 = __db.transaction('items', 'readonly');
        var r = tx2.objectStore('items').index('by_cat').openCursor(null, 'nextunique');
        r.onsuccess = function() {
            var c = r.result;
            if (c) { __cats.push(c.key); c.continue(); }
        };
        """)
        drain()

        XCTAssertEqual(eval("__cats.length")!.toInt32(), 3)
        XCTAssertEqual(eval("__cats[0]")!.toString(), "A")
        XCTAssertEqual(eval("__cats[1]")!.toString(), "B")
        XCTAssertEqual(eval("__cats[2]")!.toString(), "C")
    }

    func testCompoundIndexKeyPath() {
        openDB(upgrade: """
        var store = db.createObjectStore('items', { keyPath: 'id' });
        store.createIndex('by_cat_name', ['cat', 'name']);
        """)

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        var s = tx.objectStore('items');
        s.put({ id: 1, cat: 'A', name: 'Alice' });
        s.put({ id: 2, cat: 'B', name: 'Bob' });
        """)
        drain()

        // Query via index — getAll returns records whose compound key matches
        eval("""
        var __result = null;
        var tx2 = __db.transaction('items', 'readonly');
        var idx = tx2.objectStore('items').index('by_cat_name');
        var r = idx.get(['A', 'Alice']);
        r.onsuccess = function() { __result = r.result; };
        """)
        drain()

        XCTAssertEqual(eval("__result.id")!.toInt32(), 1)
    }

    func testErrorBubblesToTransaction() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        tx.objectStore('items').put({ id: 1 });
        """)
        drain()

        eval("""
        var __txError = false;
        var tx2 = __db.transaction('items', 'readwrite');
        tx2.onerror = function() { __txError = true; };
        tx2.objectStore('items').add({ id: 1 });
        """)
        drain()

        XCTAssertTrue(eval("__txError")!.toBool())
    }

    // MARK: - Blob / File Tests

    func testBlobRoundTrip() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        tx.objectStore('items').put({ id: 1, data: new Blob(['hello'], { type: 'text/plain' }) });
        """)
        drain()

        eval("""
        var __getResult = null;
        var tx2 = __db.transaction('items', 'readonly');
        var r = tx2.objectStore('items').get(1);
        r.onsuccess = function() { __getResult = r.result; };
        """)
        drain()

        XCTAssertTrue(eval("__getResult.data instanceof Blob")!.toBool())
        XCTAssertEqual(eval("__getResult.data.type")!.toString(), "text/plain")

        // Verify content via arrayBuffer()
        eval("""
        var __blobContent = '';
        __getResult.data.arrayBuffer().then(function(buf) {
            __blobContent = new TextDecoder().decode(new Uint8Array(buf));
        });
        """)
        XCTAssertEqual(eval("__blobContent")!.toString(), "hello")
    }

    func testFileRoundTrip() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        tx.objectStore('items').put({ id: 1, file: new File(['data'], 'test.txt', { type: 'text/plain', lastModified: 12345 }) });
        """)
        drain()

        eval("""
        var __getResult = null;
        var tx2 = __db.transaction('items', 'readonly');
        var r = tx2.objectStore('items').get(1);
        r.onsuccess = function() { __getResult = r.result; };
        """)
        drain()

        XCTAssertTrue(eval("__getResult.file instanceof File")!.toBool())
        XCTAssertEqual(eval("__getResult.file.name")!.toString(), "test.txt")
        XCTAssertEqual(eval("__getResult.file.type")!.toString(), "text/plain")
        XCTAssertEqual(eval("__getResult.file.lastModified")!.toInt32(), 12345)

        // Verify content
        eval("""
        var __fileContent = '';
        __getResult.file.arrayBuffer().then(function(buf) {
            __fileContent = new TextDecoder().decode(new Uint8Array(buf));
        });
        """)
        XCTAssertEqual(eval("__fileContent")!.toString(), "data")
    }

    func testNestedBlobInObject() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        tx.objectStore('items').put({ id: 1, nested: { img: new Blob([new Uint8Array([1, 2, 3])], { type: 'image/png' }) } });
        """)
        drain()

        eval("""
        var __getResult = null;
        var tx2 = __db.transaction('items', 'readonly');
        var r = tx2.objectStore('items').get(1);
        r.onsuccess = function() { __getResult = r.result; };
        """)
        drain()

        XCTAssertTrue(eval("__getResult.nested.img instanceof Blob")!.toBool())
        XCTAssertEqual(eval("__getResult.nested.img.type")!.toString(), "image/png")
        XCTAssertEqual(eval("__getResult.nested.img.size")!.toInt32(), 3)
    }

    // MARK: - P0/P1 Gap Fix Tests

    func testCursorRequest() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        tx.objectStore('items').put({ id: 1 });
        tx.objectStore('items').put({ id: 2 });
        """)
        drain()

        eval("""
        var __cursorReq = null;
        var __match = false;
        var tx2 = __db.transaction('items', 'readonly');
        var r = tx2.objectStore('items').openCursor();
        __cursorReq = r;
        r.onsuccess = function() {
            var cursor = r.result;
            if (cursor) { __match = (cursor.request === __cursorReq); }
        };
        """)
        drain()

        XCTAssertTrue(eval("__match")!.toBool())
    }

    func testContinuePrimaryKey() {
        openDB(upgrade: """
        var store = db.createObjectStore('items', { keyPath: 'id' });
        store.createIndex('by_cat', 'cat');
        """)

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        var s = tx.objectStore('items');
        s.put({ id: 1, cat: 'A' });
        s.put({ id: 2, cat: 'A' });
        s.put({ id: 3, cat: 'B' });
        s.put({ id: 4, cat: 'B' });
        """)
        drain()

        eval("""
        var __pk = null;
        var tx2 = __db.transaction('items', 'readonly');
        var r = tx2.objectStore('items').index('by_cat').openCursor();
        r.onsuccess = function() {
            var cursor = r.result;
            if (cursor && __pk === null) {
                cursor.continuePrimaryKey('B', 4);
                __pk = 'waiting';
            } else if (cursor && __pk === 'waiting') {
                __pk = cursor.primaryKey;
            }
        };
        """)
        drain()

        XCTAssertEqual(eval("__pk")!.toInt32(), 4)
    }

    func testCompoundObjectStoreKeyPath() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: ['a', 'b'] });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        tx.objectStore('items').put({ a: 1, b: 2, data: 'hello' });
        """)
        drain()

        eval("""
        var __val = null;
        var tx2 = __db.transaction('items', 'readonly');
        var r = tx2.objectStore('items').get([1, 2]);
        r.onsuccess = function() { __val = r.result; };
        """)
        drain()

        XCTAssertEqual(eval("__val.data")!.toString(), "hello")
    }

    func testTransactionErrorAndAutoAbort() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        // Insert baseline
        eval("""
        var tx = __db.transaction('items', 'readwrite');
        tx.objectStore('items').put({ id: 1, name: 'Original' });
        """)
        drain()

        // Trigger error (duplicate add) — should auto-abort
        eval("""
        var __txError = null;
        var __txAborted = false;
        var tx2 = __db.transaction('items', 'readwrite');
        tx2.onerror = function() { __txError = tx2.error; };
        tx2.onabort = function() { __txAborted = true; };
        tx2.objectStore('items').put({ id: 1, name: 'Modified' });
        tx2.objectStore('items').add({ id: 1, name: 'Duplicate' });
        """)
        drain()

        XCTAssertTrue(eval("__txError !== null")!.toBool())
        XCTAssertTrue(eval("__txAborted")!.toBool())

        // Verify data was rolled back
        eval("""
        var __val = null;
        var tx3 = __db.transaction('items', 'readonly');
        var r = tx3.objectStore('items').get(1);
        r.onsuccess = function() { __val = r.result; };
        """)
        drain()

        XCTAssertEqual(eval("__val.name")!.toString(), "Original")
    }

    func testPreventDefaultStopsAbort() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        tx.objectStore('items').put({ id: 1 });
        """)
        drain()

        eval("""
        var __aborted = false;
        var tx2 = __db.transaction('items', 'readwrite');
        tx2.onabort = function() { __aborted = true; };
        var r = tx2.objectStore('items').add({ id: 1 });
        r.onerror = function(e) { e.preventDefault(); };
        """)
        drain()

        XCTAssertFalse(eval("__aborted")!.toBool())
    }

    func testUndefinedValuePreservation() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        var s = tx.objectStore('items');
        s.put({ id: 1, a: 1, b: undefined });
        s.put({ id: 2, arr: [1, undefined, 3] });
        """)
        drain()

        eval("""
        var __v1 = null, __v2 = null;
        var tx2 = __db.transaction('items', 'readonly');
        var s2 = tx2.objectStore('items');
        var r1 = s2.get(1);
        r1.onsuccess = function() { __v1 = r1.result; };
        var r2 = s2.get(2);
        r2.onsuccess = function() { __v2 = r2.result; };
        """)
        drain()

        XCTAssertEqual(eval("__v1.a")!.toInt32(), 1)
        XCTAssertTrue(eval("'b' in __v1 && __v1.b === undefined")!.toBool())
        XCTAssertEqual(eval("__v2.arr[0]")!.toInt32(), 1)
        XCTAssertTrue(eval("__v2.arr[1] === undefined")!.toBool())
        XCTAssertEqual(eval("__v2.arr[2]")!.toInt32(), 3)
    }

    func testImageDataRoundTrip() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        var imgData = new ImageData(2, 2);
        imgData.data[0] = 255; // R
        imgData.data[3] = 128; // A of first pixel
        tx.objectStore('items').put({ id: 1, img: imgData });
        """)
        drain()

        eval("""
        var __val = null;
        var tx2 = __db.transaction('items', 'readonly');
        var r = tx2.objectStore('items').get(1);
        r.onsuccess = function() { __val = r.result; };
        """)
        drain()

        XCTAssertTrue(eval("__val.img instanceof ImageData")!.toBool())
        XCTAssertEqual(eval("__val.img.width")!.toInt32(), 2)
        XCTAssertEqual(eval("__val.img.height")!.toInt32(), 2)
        XCTAssertEqual(eval("__val.img.data[0]")!.toInt32(), 255)
        XCTAssertEqual(eval("__val.img.data[3]")!.toInt32(), 128)
    }

    func testBlobInsideMap() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        tx.objectStore('items').put({ id: 1, m: new Map([['k', new Blob(['mapblob'], { type: 'text/plain' })]]) });
        """)
        drain()

        eval("""
        var __val = null;
        var tx2 = __db.transaction('items', 'readonly');
        var r = tx2.objectStore('items').get(1);
        r.onsuccess = function() { __val = r.result; };
        """)
        drain()

        XCTAssertTrue(eval("__val.m instanceof Map")!.toBool())
        XCTAssertTrue(eval("__val.m.get('k') instanceof Blob")!.toBool())
        XCTAssertEqual(eval("__val.m.get('k').type")!.toString(), "text/plain")

        eval("""
        var __blobText = '';
        __val.m.get('k').arrayBuffer().then(function(buf) {
            __blobText = new TextDecoder().decode(new Uint8Array(buf));
        });
        """)
        XCTAssertEqual(eval("__blobText")!.toString(), "mapblob")
    }

    func testCircularReferenceError() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        // Temporarily suppress the global exception handler since the DOMException
        // thrown synchronously by _clone is caught by put() but still surfaces.
        ctx.exceptionHandler = nil
        eval("""
        var __errName = null;
        var tx = __db.transaction('items', 'readwrite');
        var obj = { id: 1 };
        obj.self = obj;
        var r = tx.objectStore('items').put(obj);
        r.onerror = function() { __errName = r.error.name; };
        """)
        drain()
        ctx.exceptionHandler = { _, value in
            XCTFail("JS exception: \(value?.toString() ?? "nil")")
        }

        XCTAssertEqual(eval("__errName")!.toString(), "DataCloneError")
    }

    // MARK: - Fix 1: Transaction lifecycle

    func testTransactionStaysAliveAcrossRequests() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        var store = tx.objectStore('items');
        store.put({ id: 1, val: 'first' });
        """)
        drain()

        // get → onsuccess → put inside the same tx
        eval("""
        var __putOk = false;
        var tx2 = __db.transaction('items', 'readwrite');
        var s2 = tx2.objectStore('items');
        var r = s2.get(1);
        r.onsuccess = function() {
            s2.put({ id: 1, val: 'updated' });
            __putOk = true;
        };
        """)
        drain()

        XCTAssertTrue(eval("__putOk")!.toBool())

        // Verify the update persisted
        eval("""
        var __val = null;
        var tx3 = __db.transaction('items', 'readonly');
        var r3 = tx3.objectStore('items').get(1);
        r3.onsuccess = function() { __val = r3.result.val; };
        """)
        drain()

        XCTAssertEqual(eval("__val")!.toString(), "updated")
    }

    func testCursorTransactionAutoCommits() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        tx.objectStore('items').put({ id: 1, val: 'a' });
        tx.objectStore('items').put({ id: 2, val: 'b' });
        """)
        drain()

        // Cursor-based readwrite tx: update via cursor, then check oncomplete fires
        eval("""
        var __complete = false;
        var tx2 = __db.transaction('items', 'readwrite');
        tx2.oncomplete = function() { __complete = true; };
        var r = tx2.objectStore('items').openCursor();
        r.onsuccess = function() {
            var cursor = r.result;
            if (cursor) {
                cursor.update({ id: cursor.value.id, val: cursor.value.val + '!' });
                cursor.continue();
            }
        };
        """)
        drain()

        XCTAssertTrue(eval("__complete")!.toBool())

        // Verify cursor updates persisted
        eval("""
        var __vals = [];
        var tx3 = __db.transaction('items', 'readonly');
        var r3 = tx3.objectStore('items').openCursor();
        r3.onsuccess = function() {
            var c = r3.result;
            if (c) { __vals.push(c.value.val); c.continue(); }
        };
        """)
        drain()

        XCTAssertEqual(eval("__vals[0]")!.toString(), "a!")
        XCTAssertEqual(eval("__vals[1]")!.toString(), "b!")
    }

    // MARK: - Fix 2: Transaction state checks

    func testReadonlyTransactionRejectsWrite() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var __errName = null;
        try {
            var tx = __db.transaction('items', 'readonly');
            tx.objectStore('items').put({ id: 1 });
        } catch(e) {
            __errName = e.name;
        }
        """)

        XCTAssertEqual(eval("__errName")!.toString(), "ReadOnlyError")
    }

    func testAbortedTransactionRejectsRequest() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var __errName = null;
        var tx = __db.transaction('items', 'readwrite');
        var store = tx.objectStore('items');
        tx.abort();
        try {
            store.get(1);
        } catch(e) {
            __errName = e.name;
        }
        """)

        XCTAssertEqual(eval("__errName")!.toString(), "TransactionInactiveError")
    }

    func testClosedDatabaseRejectsTransaction() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var __errName = null;
        __db.close();
        try {
            __db.transaction('items', 'readonly');
        } catch(e) {
            __errName = e.name;
        }
        """)

        XCTAssertEqual(eval("__errName")!.toString(), "InvalidStateError")
    }

    func testCreateObjectStoreOutsideVersionchange() {
        openDB(upgrade: "db.createObjectStore('items');")

        eval("""
        var __errName = null;
        try {
            __db.createObjectStore('extra');
        } catch(e) {
            __errName = e.name;
        }
        """)

        XCTAssertEqual(eval("__errName")!.toString(), "InvalidStateError")
    }

    // MARK: - Fix 3: Error bubbles to database

    func testErrorBubblesToDatabase() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        // Insert initial record
        eval("""
        var tx = __db.transaction('items', 'readwrite');
        tx.objectStore('items').put({ id: 1 });
        """)
        drain()

        // Trigger a ConstraintError via duplicate add → should bubble to db.onerror
        eval("""
        var __dbErrorFired = false;
        __db.onerror = function() { __dbErrorFired = true; };
        var tx2 = __db.transaction('items', 'readwrite');
        tx2.objectStore('items').add({ id: 1 });
        """)
        drain()

        XCTAssertTrue(eval("__dbErrorFired")!.toBool())
    }

    // MARK: - Fix 4: keyPath + explicit key conflict

    func testInlineKeyPathWithExplicitKeyFails() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var __errName = null;
        try {
            var tx = __db.transaction('items', 'readwrite');
            tx.objectStore('items').put({ id: 1 }, 42);
        } catch(e) {
            __errName = e.name;
        }
        """)

        XCTAssertEqual(eval("__errName")!.toString(), "DataError")
    }

    // MARK: - Fix 5: NaN/Infinity/-0 round-trip

    func testNaNInfinityNegZeroRoundTrip() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        tx.objectStore('items').put({ id: 1, a: NaN, b: -0, c: Infinity, d: -Infinity });
        """)
        drain()

        eval("""
        var __r = null;
        var tx2 = __db.transaction('items', 'readonly');
        var r = tx2.objectStore('items').get(1);
        r.onsuccess = function() { __r = r.result; };
        """)
        drain()

        XCTAssertTrue(eval("isNaN(__r.a)")!.toBool())
        XCTAssertTrue(eval("Object.is(__r.b, -0)")!.toBool())
        XCTAssertTrue(eval("__r.c === Infinity")!.toBool())
        XCTAssertTrue(eval("__r.d === -Infinity")!.toBool())
    }

    // MARK: - Fix 6: objectStore/index rename

    func testObjectStoreRename() {
        eval("""
        var __db2 = null;
        var req = indexedDB.open('renameDB', 1);
        req.onupgradeneeded = function(e) {
            var db = e.target.result;
            var store = db.createObjectStore('oldName', { keyPath: 'id' });
            store.name = 'newName';
        };
        req.onsuccess = function() { __db2 = req.result; };
        """)
        drain()

        XCTAssertTrue(eval("__db2.objectStoreNames.contains('newName')")!.toBool())
        XCTAssertFalse(eval("__db2.objectStoreNames.contains('oldName')")!.toBool())
    }

    func testIndexRename() {
        eval("""
        var __db3 = null;
        var req = indexedDB.open('renameIdxDB', 1);
        req.onupgradeneeded = function(e) {
            var db = e.target.result;
            var store = db.createObjectStore('items', { keyPath: 'id' });
            var idx = store.createIndex('oldIdx', 'name');
            idx.name = 'newIdx';
        };
        req.onsuccess = function() { __db3 = req.result; };
        """)
        drain()

        eval("""
        var __hasNew = false, __hasOld = true;
        var tx = __db3.transaction('items', 'readonly');
        var s = tx.objectStore('items');
        __hasNew = s.indexNames.contains('newIdx');
        __hasOld = s.indexNames.contains('oldIdx');
        """)

        XCTAssertTrue(eval("__hasNew")!.toBool())
        XCTAssertFalse(eval("__hasOld")!.toBool())
    }

    func testGlobalConstructorsExposed() {
        XCTAssertTrue(eval("typeof IDBDatabase === 'function'")!.toBool())
        XCTAssertTrue(eval("typeof IDBTransaction === 'function'")!.toBool())
        XCTAssertTrue(eval("typeof IDBObjectStore === 'function'")!.toBool())
        XCTAssertTrue(eval("typeof IDBIndex === 'function'")!.toBool())
        XCTAssertTrue(eval("typeof IDBCursor === 'function'")!.toBool())
        XCTAssertTrue(eval("typeof IDBRequest === 'function'")!.toBool())
        XCTAssertTrue(eval("typeof IDBOpenDBRequest === 'function'")!.toBool())
        XCTAssertTrue(eval("typeof IDBVersionChangeEvent === 'function'")!.toBool())
        XCTAssertTrue(eval("typeof IDBKeyRange === 'function'")!.toBool())
    }
}
