// Browser side of LearnMath's platform layer (see lib/platform/files_web.dart
// and lib/tts/kokoro_web_engine.dart). Loaded by index.html before the app.
//
// learnmathFiles: the app's large files (recorded lectures) as Blobs in
// IndexedDB, addressed by the same path strings the app uses on a device.
// learnmathKokoro: the Kokoro voice, running in kokoro_worker.js.
(() => {
  'use strict';

  // Keeps a hosting site's caching service worker away from the app; see
  // learnmath_sw.js. Service workers need https:// or localhost.
  navigator.serviceWorker?.register('learnmath_sw.js').catch(() => {});

  // ------------------------------------------------------------- files
  const DB = 'learnmath-files';
  const STORE = 'files';
  let dbPromise = null;
  const urls = new Map(); // path -> object URL handed out for playback

  function open(version) {
    return new Promise((resolve, reject) => {
      const request = indexedDB.open(DB, version);
      request.onupgradeneeded = () => {
        if (!request.result.objectStoreNames.contains(STORE)) {
          request.result.createObjectStore(STORE);
        }
      };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
  }

  function db() {
    dbPromise ??= (async () => {
      let d = await open();
      // A database left without its store (made by something else under
      // this name): add the store in a new version.
      if (!d.objectStoreNames.contains(STORE)) {
        const next = d.version + 1;
        d.close();
        d = await open(next);
      }
      // Another tab upgrading the database must not wait for this one.
      d.onversionchange = () => {
        d.close();
        dbPromise = null;
      };
      return d;
    })();
    return dbPromise;
  }

  // Runs [work] on the store in one transaction and resolves with its
  // request's result once the transaction has committed.
  async function tx(mode, work) {
    const d = await db();
    return new Promise((resolve, reject) => {
      const t = d.transaction(STORE, mode);
      const request = work(t.objectStore(STORE));
      t.oncomplete = () => resolve(request ? request.result : undefined);
      t.onerror = () => reject(t.error);
      t.onabort = () => reject(t.error ?? new Error('Storage write aborted'));
    });
  }

  function forget(path) {
    const url = urls.get(path);
    if (url) URL.revokeObjectURL(url);
    urls.delete(path);
  }

  // Everything at [path] or below it ("dir/" prefix).
  function treeRange(path) {
    const dir = path.endsWith('/') ? path : path + '/';
    return IDBKeyRange.bound(dir, dir + '￿');
  }

  globalThis.learnmathFiles = {
    async put(path, parts, type) {
      forget(path);
      await tx('readwrite', (s) => s.put(new Blob(parts, { type }), path));
      // Ask the browser not to evict recordings when disk runs low.
      navigator.storage?.persist?.().catch(() => {});
    },
    async exists(path) {
      return (await tx('readonly', (s) => s.count(path))) > 0;
    },
    async size(path) {
      const blob = await tx('readonly', (s) => s.get(path));
      return blob ? blob.size : -1;
    },
    async remove(path) {
      forget(path);
      await tx('readwrite', (s) => s.delete(path));
    },
    async removeTree(path) {
      for (const key of [...urls.keys()]) {
        if (key === path || key.startsWith(path + '/')) forget(key);
      }
      await tx('readwrite', (s) => {
        s.delete(path);
        return s.delete(treeRange(path));
      });
    },
    async move(from, to) {
      const blob = await tx('readonly', (s) => s.get(from));
      if (!blob) throw new Error('No such file: ' + from);
      forget(from);
      forget(to);
      await tx('readwrite', (s) => {
        s.put(blob, to);
        return s.delete(from);
      });
    },
    // A URL an <audio> element can play, or null when there is no such file.
    async url(path) {
      const known = urls.get(path);
      if (known) return known;
      const blob = await tx('readonly', (s) => s.get(path));
      if (!blob) return null;
      const url = URL.createObjectURL(blob);
      urls.set(path, url);
      return url;
    },
  };

  // ------------------------------------------------------------ kokoro
  let worker = null;
  let nextId = 1;
  const pending = new Map(); // id -> {resolve, reject, onProgress}
  let loading = null; // the load in flight or done, so engines share one model

  function ensureWorker() {
    if (worker) return worker;
    worker = new Worker('kokoro_worker.js', { type: 'module' });
    worker.onmessage = (e) => {
      const m = e.data;
      const p = pending.get(m.id);
      if (!p) return;
      if (m.type === 'progress') {
        p.onProgress?.(m.loaded, m.total);
        return;
      }
      pending.delete(m.id);
      if (m.type === 'error') p.reject(new Error(m.message));
      else p.resolve(m);
    };
    worker.onerror = (e) => {
      const error = new Error(e.message || 'The voice worker failed to start.');
      for (const p of pending.values()) p.reject(error);
      pending.clear();
      worker = null;
      loading = null;
    };
    return worker;
  }

  function call(message, onProgress) {
    const id = nextId++;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject, onProgress });
      ensureWorker().postMessage({ ...message, id });
    });
  }

  globalThis.learnmathKokoro = {
    // Loads the model once (downloading it the first time). Resolves with
    // {device, dtype}. [onProgress] gets (loadedBytes, totalBytes).
    load(onProgress) {
      loading ??= call({ type: 'load' }, onProgress).catch((e) => {
        loading = null;
        throw e;
      });
      return loading;
    },
    // Resolves with {samples: Float32Array, sampleRate}.
    generate(text, voice, speed) {
      return call({ type: 'generate', text, voice, speed });
    },
  };
})();
