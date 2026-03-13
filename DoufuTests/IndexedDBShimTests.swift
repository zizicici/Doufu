import JavaScriptCore
import XCTest

/// Tests for the IndexedDB JavaScript shim (DoufuIndexedDBShim.js).
///
/// The shim runs in a `JSContext` (JavaScriptCore). Because JSC lacks browser
/// APIs (`window`, `DOMException`, `setTimeout`, `Promise.resolve().then()`
/// microtask draining), we inject lightweight polyfills and a manual
/// `__drainAll()` function that deterministically flushes both microtask and
/// macrotask queues.
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
            // Keep real Promise for databases() which returns a real promise
            _real: _OrigPromise
        };

        function setTimeout(fn) {
            __macrotasks.push(fn);
            return __macrotasks.length;
        }

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
                for (var i = 0; i < batch.length; i++) batch[i]();
            }
            __drainMicrotasks();
        }
        """)

        // Flush spy
        ctx.evaluateScript("var __flushed = null;")
        ctx.evaluateScript("""
        window.webkit = {
            messageHandlers: {
                doufuIndexedDB: {
                    postMessage: function(data) { __flushed = data; }
                }
            }
        };
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

        // Load shim with empty snapshot
        let shimURL = productsURL(forResource: "DoufuIndexedDBShim", withExtension: "js")
        let shimJS = try! String(contentsOf: shimURL)
            .replacingOccurrences(of: "'__DOUFU_IDB_SNAPSHOT__'", with: "{}")
        ctx.evaluateScript(shimJS)
    }

    /// Locate the .js resource from the main bundle, test bundle, or file system.
    private func productsURL(forResource name: String, withExtension ext: String) -> URL {
        // Try test bundle first
        if let url = Bundle(for: type(of: self)).url(forResource: name, withExtension: ext) {
            return url
        }
        // Fallback: direct file path relative to project root
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DoufuTests/
            .deletingLastPathComponent() // project root
        let url = projectRoot
            .appendingPathComponent("Doufu/Resources/\(name).\(ext)")
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

    func testFlushOnCommit() {
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("__flushed = null;")
        eval("""
        var tx = __db.transaction('items', 'readwrite');
        tx.objectStore('items').put({ id: 1 });
        """)
        drain()

        // After drain, the transaction should have committed and flushed.
        XCTAssertTrue(eval("__flushed !== null")!.toBool())
        XCTAssertTrue(eval("__flushed.testDB !== undefined")!.toBool())
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

    func testSnapshotReload() {
        // Simulates: write data → flush → reload from snapshot
        openDB(upgrade: "db.createObjectStore('items', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('items', 'readwrite');
        tx.objectStore('items').put({ id: 1, name: 'Persist' });
        """)
        drain()

        // Grab the flushed snapshot and re-initialize with it
        let flushed = eval("JSON.stringify(__flushed)")!.toString()!
        let shimURL = productsURL(forResource: "DoufuIndexedDBShim", withExtension: "js")
        let shimJS = try! String(contentsOf: shimURL)
            .replacingOccurrences(of: "'__DOUFU_IDB_SNAPSHOT__'",
                                  with: "JSON.parse('\(flushed.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))')")

        // Reset context
        eval("__flushed = null;")
        ctx.evaluateScript(shimJS)

        // Read data from restored snapshot
        eval("""
        var __restored = null;
        var req = indexedDB.open('testDB', 1);
        req.onsuccess = function(e) {
            var db = e.target.result;
            var tx = db.transaction('items', 'readonly');
            var r = tx.objectStore('items').get(1);
            r.onsuccess = function() { __restored = r.result; };
        };
        """)
        drain()

        XCTAssertEqual(eval("__restored.name")!.toString(), "Persist")
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

    func testBinaryFlushAndReload() {
        openDB(upgrade: "db.createObjectStore('bin', { keyPath: 'id' });")

        eval("""
        var tx = __db.transaction('bin', 'readwrite');
        tx.objectStore('bin').put({ id: 1, data: new Uint8Array([10, 20, 30]) });
        """)
        drain()

        // Verify flush contains base64-encoded binary
        XCTAssertTrue(eval("__flushed !== null")!.toBool())

        // Reload from flushed snapshot
        let flushed = eval("JSON.stringify(__flushed)")!.toString()!
        let shimURL = productsURL(forResource: "DoufuIndexedDBShim", withExtension: "js")
        let shimJS = try! String(contentsOf: shimURL)
            .replacingOccurrences(of: "'__DOUFU_IDB_SNAPSHOT__'",
                                  with: "JSON.parse('\(flushed.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))')")

        eval("__flushed = null;")
        ctx.evaluateScript(shimJS)

        eval("""
        var __restored = null;
        var req = indexedDB.open('testDB', 1);
        req.onsuccess = function(e) {
            var db = e.target.result;
            var tx = db.transaction('bin', 'readonly');
            var r = tx.objectStore('bin').get(1);
            r.onsuccess = function() { __restored = r.result; };
        };
        """)
        drain()

        XCTAssertTrue(eval("__restored.data instanceof Uint8Array")!.toBool())
        XCTAssertEqual(eval("__restored.data.length")!.toInt32(), 3)
        XCTAssertEqual(eval("__restored.data[0]")!.toInt32(), 10)
        XCTAssertEqual(eval("__restored.data[2]")!.toInt32(), 30)
    }
}
