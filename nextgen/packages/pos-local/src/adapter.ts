/**
 * CHEESYOS NEXTGEN POS LOCAL — PERSISTENCE ADAPTER CONTRACT
 * 
 * Defines abstract SQLite connection and database interface contracts
 * enabling pos-local and pos-sync to run interchangeably on:
 * 1. Node.js native node:sqlite (for unit/integration tests & server CLI)
 * 2. Tauri Native Desktop SQLite IPC bridge (for Windows POS renderer)
 */

export interface ISQLiteStatement {
  run(...params: unknown[]): { changes: number; lastInsertRowid: number | bigint };
  get(...params: unknown[]): unknown;
  all(...params: unknown[]): unknown[];
}

export interface ISQLiteDatabase {
  close(): void;
  exec(sql: string): void;
  prepare(sql: string): ISQLiteStatement;
}

export interface IPosLocalDatabase {
  getRawDb(): ISQLiteDatabase;
  getPath(): string;
  close(): void;
  getSchemaVersion(): number;
  runTransaction<T>(fn: (db: ISQLiteDatabase) => T): T;
}
