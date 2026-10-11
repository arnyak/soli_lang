// A SQLite database in a Durable Object, for Soli's D1 adapter: a connection
// `url = "do://SITES/acme"` sends its statements to the object named "acme" of
// the SITES binding, which runs them here on its own storage. One object per
// tenant (`do://SITES/{tenant}`) is a database per tenant, created by naming
// it: nothing to declare per tenant, nothing to redeploy.
//
// wrangler.toml:
//   [[durable_objects.bindings]]
//   name = "SITES"
//   class_name = "SoliSqlObject"
//   [[migrations]]
//   tag = "v1"
//   new_sqlite_classes = ["SoliSqlObject"]
//
// Answers in D1's shape ({columns, rows, changes}), so jspi.js and the adapter
// treat both the same. A batch runs in one storage transaction, as D1's does.
import { DurableObject } from "cloudflare:workers";

export class SoliSqlObject extends DurableObject {
  query(sql, params) {
    return run(this.ctx.storage.sql, sql, params);
  }

  batch(statements) {
    return this.ctx.storage.transactionSync(() =>
      statements.map((s) => run(this.ctx.storage.sql, s.sql, s.params)),
    );
  }
}

function run(storage, sql, params) {
  const cursor = storage.exec(sql, ...params);
  const rows = [];
  for (const row of cursor.raw()) rows.push(row.map(cell));
  return { columns: cursor.columnNames, rows, changes: cursor.rowsWritten };
}

// Storage hands back strings, numbers, null and ArrayBuffers; JSON has no bytes.
function cell(value) {
  if (value instanceof ArrayBuffer) return `<blob ${value.byteLength} bytes>`;
  return value ?? null;
}
