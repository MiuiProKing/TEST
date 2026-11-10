/**
 * Best-effort browser cache for a complete, read-only Supabase archive.
 *
 * One structured-clone record keeps the rounds and polling cursor atomic. The
 * public source identity is the key; never put a token or other secret in it.
 * Storage being blocked, unavailable, full, or slow must not stop live data.
 */
const DATABASE = 'god-preditor-v7-time-survival-archive';
const STORE = 'snapshots';
const VERSION = 1;
const INTEGER = /^-?\d+$/;

function validCursor(value) {
  return value === null || (typeof value === 'string' && INTEGER.test(value));
}

function normalizeSnapshot(value, now = Date.now()) {
  if (!value || value.complete !== true || !Array.isArray(value.rounds) ||
      !validCursor(value.cursor) || !Number.isFinite(value.updatedAt) ||
      value.updatedAt <= 0 || value.updatedAt > now) return null;

  const rounds = [];
  for (const row of value.rounds) {
    if (!row || typeof row.seq !== 'string' || !INTEGER.test(row.seq) ||
        !(typeof row.id === 'string' && row.id.length > 0) ||
        !Number.isFinite(row.x) || row.x < 1 ||
        !Number.isFinite(row.t) || row.t <= 0 || row.t > now) return null;
    // Copy only normalized data, never arbitrary server/cache properties.
    rounds.push({ id: row.id, seq: row.seq, x: row.x, t: row.t });
  }
  // Polling updates the stored rows without making the last full archive newer.
  // Older snapshots lack archiveAt and retain their former updatedAt fallback.
  const archiveAt = Number.isFinite(value.archiveAt) && value.archiveAt > 0 &&
    value.archiveAt <= value.updatedAt ? value.archiveAt : value.updatedAt;
  return { rounds, cursor: value.cursor, updatedAt: value.updatedAt, archiveAt, complete: true };
}

function openDatabase(indexedDB) {
  return new Promise((resolve) => {
    let request;
    let done = false;
    const finish = (db) => {
      if (done) {
        if (db) db.close();
        return;
      }
      done = true;
      clearTimeout(timeout);
      resolve(db);
    };
    const timeout = setTimeout(() => finish(null), 4000);
    try {
      request = indexedDB.open(DATABASE, VERSION);
      request.onupgradeneeded = () => {
        const db = request.result;
        if (!db.objectStoreNames.contains(STORE)) db.createObjectStore(STORE);
      };
      request.onsuccess = () => {
        const db = request.result;
        db.onversionchange = () => db.close();
        finish(db);
      };
      request.onerror = () => finish(null);
      request.onblocked = () => finish(null);
    } catch {
      finish(null);
    }
  });
}

function transact(db, mode, operation) {
  return new Promise((resolve) => {
    let transaction;
    let result;
    let done = false;
    const finish = (ok) => {
      if (done) return;
      done = true;
      clearTimeout(timeout);
      db.close();
      resolve(ok ? { ok: true, value: result } : { ok: false });
    };
    const timeout = setTimeout(() => {
      try { transaction?.abort(); } catch { /* Already finished. */ }
      finish(false);
    }, 15000);
    try {
      transaction = db.transaction(STORE, mode);
      transaction.oncomplete = () => finish(true);
      transaction.onabort = () => finish(false);
      transaction.onerror = () => finish(false);
      const request = operation(transaction.objectStore(STORE));
      request.onsuccess = () => { result = request.result; };
      request.onerror = () => finish(false);
    } catch {
      finish(false);
    }
  });
}

export function createArchiveCache({ identity } = {}) {
  // Invalid identities disable persistence without preventing application use.
  const key = typeof identity === 'string' && identity.trim() ? identity : null;
  return {
    async read() {
      try {
        if (!key || !globalThis.indexedDB) return null;
        const db = await openDatabase(globalThis.indexedDB);
        if (!db) return null;
        const result = await transact(db, 'readonly', store => store.get(key));
        if (!result.ok || result.value?.identity !== key) return null;
        return normalizeSnapshot(result.value);
      } catch {
        return null;
      }
    },
    async write(value) {
      try {
        if (!key || !globalThis.indexedDB) return false;
        const snapshot = normalizeSnapshot(value);
        // Never replace a complete archive with a partial download.
        if (!snapshot) return false;
        const db = await openDatabase(globalThis.indexedDB);
        if (!db) return false;
        const result = await transact(db, 'readwrite', store =>
          store.put({ identity: key, ...snapshot }, key));
        return result.ok;
      } catch {
        return false;
      }
    }
  };
}
