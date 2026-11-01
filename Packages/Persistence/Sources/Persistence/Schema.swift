import Foundation

/// Versioned schema (spec 14.8). Never edit a shipped migration; append a new one.
public enum Schema {
    public static let migrations: [Migration] = [
        Migration(version: 1, sql: """
        CREATE TABLE history (
            id TEXT PRIMARY KEY,
            url TEXT NOT NULL UNIQUE,
            host TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT '',
            first_visited_at REAL NOT NULL,
            last_visited_at REAL NOT NULL,
            visit_count INTEGER NOT NULL DEFAULT 1,
            expires_at REAL,
            is_protected INTEGER NOT NULL DEFAULT 0,
            profile_id TEXT
        );
        CREATE INDEX history_expires ON history(expires_at) WHERE expires_at IS NOT NULL;
        CREATE INDEX history_host ON history(host);
        CREATE INDEX history_last ON history(last_visited_at DESC);
        CREATE VIRTUAL TABLE history_fts USING fts5(title, url, content='history', content_rowid='rowid', tokenize='unicode61');
        CREATE TRIGGER history_ai AFTER INSERT ON history BEGIN
            INSERT INTO history_fts(rowid, title, url) VALUES (new.rowid, new.title, new.url);
        END;
        CREATE TRIGGER history_ad AFTER DELETE ON history BEGIN
            INSERT INTO history_fts(history_fts, rowid, title, url) VALUES ('delete', old.rowid, old.title, old.url);
        END;
        CREATE TRIGGER history_au AFTER UPDATE ON history BEGIN
            INSERT INTO history_fts(history_fts, rowid, title, url) VALUES ('delete', old.rowid, old.title, old.url);
            INSERT INTO history_fts(rowid, title, url) VALUES (new.rowid, new.title, new.url);
        END;

        CREATE TABLE tab_groups (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            colour TEXT NOT NULL,
            sort_order INTEGER NOT NULL,
            default_profile_id TEXT
        );
        CREATE TABLE tabs (
            id TEXT PRIMARY KEY,
            url TEXT,
            title TEXT NOT NULL DEFAULT '',
            group_id TEXT REFERENCES tab_groups(id) ON DELETE SET NULL,
            profile_id TEXT NOT NULL,
            created_at REAL NOT NULL,
            last_active_at REAL NOT NULL,
            state TEXT NOT NULL,
            is_protected INTEGER NOT NULL DEFAULT 0,
            is_pinned INTEGER NOT NULL DEFAULT 0,
            sort_order INTEGER NOT NULL DEFAULT 0,
            snapshot_reference TEXT,
            interaction_state BLOB
        );
        CREATE INDEX tabs_profile ON tabs(profile_id, sort_order);

        CREATE TABLE bookmark_folders (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            parent_id TEXT REFERENCES bookmark_folders(id) ON DELETE CASCADE,
            sort_order INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE bookmarks (
            id TEXT PRIMARY KEY,
            url TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT '',
            folder_id TEXT REFERENCES bookmark_folders(id) ON DELETE CASCADE,
            tags TEXT NOT NULL DEFAULT '',
            is_favourite INTEGER NOT NULL DEFAULT 0,
            is_reading_list INTEGER NOT NULL DEFAULT 0,
            is_read INTEGER NOT NULL DEFAULT 0,
            saved_content TEXT,
            created_at REAL NOT NULL,
            modified_at REAL NOT NULL,
            deleted_at REAL
        );
        CREATE INDEX bookmarks_folder ON bookmarks(folder_id);

        CREATE TABLE protected_sites (
            id TEXT PRIMARY KEY,
            domain TEXT NOT NULL UNIQUE,
            include_subdomains INTEGER NOT NULL,
            allowed_data_types TEXT NOT NULL,
            created_at REAL NOT NULL,
            notes TEXT
        );

        CREATE TABLE site_settings (
            host TEXT NOT NULL,
            key TEXT NOT NULL,
            value TEXT NOT NULL,
            PRIMARY KEY (host, key)
        );

        CREATE TABLE downloads (
            id TEXT PRIMARY KEY,
            source_url TEXT NOT NULL,
            filename TEXT NOT NULL,
            destination_bookmark BLOB,
            status TEXT NOT NULL,
            progress REAL,
            resume_data BLOB,
            created_at REAL NOT NULL
        );

        CREATE TABLE ai_sessions (
            id TEXT PRIMARY KEY,
            tab_ids TEXT NOT NULL,
            model_id TEXT NOT NULL,
            created_at REAL NOT NULL,
            expires_at REAL,
            messages TEXT NOT NULL,
            source_references TEXT NOT NULL
        );

        CREATE TABLE research_notes (
            id TEXT PRIMARY KEY,
            session_id TEXT REFERENCES ai_sessions(id) ON DELETE CASCADE,
            text TEXT NOT NULL,
            source_url TEXT,
            created_at REAL NOT NULL
        );

        CREATE TABLE cleanup_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ran_at REAL NOT NULL,
            trigger TEXT NOT NULL,
            complete INTEGER NOT NULL,
            summary TEXT NOT NULL
        );
        """),
    ]
}
