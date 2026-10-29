import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { expect, it } from "vitest";
import { openDatabase } from "../src/db/database.js";

it("upgrades existing calls to the default mode without changing their identity", () => {
  const directory = mkdtempSync(join(tmpdir(), "agentring-migration-"));
  const path = join(directory, "relay.db");
  try {
    const old = new DatabaseSync(path);
    old.exec(`CREATE TABLE schema_version (version INTEGER NOT NULL);
      INSERT INTO schema_version VALUES (5);
      CREATE TABLE calls (call_id TEXT PRIMARY KEY, state TEXT NOT NULL);
      INSERT INTO calls VALUES ('call_existing', 'active');`);
    old.close();
    const db = openDatabase(path);
    try {
      expect(db.prepare("SELECT * FROM calls").get()).toMatchObject({ call_id: "call_existing", state: "active", voice_mode: "default" });
      db.prepare("UPDATE calls SET voice_mode = ?").run("openclaw_direct");
      expect(() => db.prepare("UPDATE calls SET voice_mode = ?").run("unknown")).toThrow();
    } finally { db.close(); }
    const reopened = openDatabase(path);
    try { expect(reopened.prepare("SELECT voice_mode FROM calls").get()?.voice_mode).toBe("openclaw_direct"); }
    finally { reopened.close(); }
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
