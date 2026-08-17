#![forbid(unsafe_code)]

//! M4b feasibility spike; test-only and outside the shipped dependency tree.

#[cfg(test)]
mod tests {
    use std::num::NonZeroUsize;
    use std::path::{Path, PathBuf};
    use std::sync::Arc;
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    use anyhow::{bail, ensure, Context, Result};
    use rusqlite::{Connection as Sqlite, OpenFlags as SqliteFlags, MAIN_DB};
    use turso_core::{
        Connection, Database, DatabaseOpts, OpenFlags, PlatformIO, Row, Statement, StepResult,
        Value, IO,
    };

    const FULL_CHUNKS: usize = 256;
    const CHUNK_SIZE: usize = 1024 * 1024;
    const TAIL_SIZE: usize = 64 * 1024;
    const RANGE_SIZE: usize = 64 * 1024;
    const RANGE_READS: usize = 512;
    const FILE_ID: i64 = 1;

    #[derive(Clone, Copy)]
    enum Shape {
        WithoutRowid,
        Rowid,
    }

    impl Shape {
        fn name(self) -> &'static str {
            match self {
                Self::WithoutRowid => "WITHOUT ROWID",
                Self::Rowid => "rowid",
            }
        }

        fn table(self) -> &'static str {
            match self {
                Self::WithoutRowid => "chunks_without_rowid",
                Self::Rowid => "chunks_rowid",
            }
        }
    }

    struct TempDir(PathBuf);

    impl TempDir {
        fn new() -> Result<Self> {
            let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
            let path =
                std::env::temp_dir().join(format!("gitility-m4b-{}-{stamp}", std::process::id()));
            std::fs::create_dir(&path).with_context(|| format!("create {}", path.display()))?;
            Ok(Self(path))
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            if let Err(error) = std::fs::remove_dir_all(&self.0) {
                eprintln!("warning: remove {}: {error}", self.0.display());
            }
        }
    }

    fn print_measurement(
        engine: &str,
        shape: &str,
        pattern: &str,
        useful: usize,
        materialized: usize,
        elapsed: Duration,
    ) {
        let seconds = elapsed.as_secs_f64();
        println!(
            "| {engine} | {shape} | {pattern} | {:.1} | {:.1} | {:.3} | {:.1} | {:.1} |",
            useful as f64 / 1_048_576.0,
            materialized as f64 / 1_048_576.0,
            seconds,
            useful as f64 / 1_048_576.0 / seconds,
            materialized as f64 / 1_048_576.0 / seconds
        );
    }

    struct XorShift64(u64);

    impl XorShift64 {
        fn next(&mut self) -> u64 {
            let mut value = self.0;
            value ^= value << 13;
            value ^= value >> 7;
            value ^= value << 17;
            self.0 = value;
            value
        }

        fn bounded(&mut self, upper: usize) -> usize {
            (self.next() % upper as u64) as usize
        }
    }

    fn corpus() -> Vec<Vec<u8>> {
        (0..=FULL_CHUNKS)
            .map(|seq| {
                let len = if seq == FULL_CHUNKS {
                    TAIL_SIZE
                } else {
                    CHUNK_SIZE
                };
                let mut bytes = vec![0; len];
                for (block, output) in bytes.chunks_mut(8).enumerate() {
                    let word = ((seq as u64) << 32) ^ block as u64 ^ 0xa076_1d64_78bd_642f;
                    output.copy_from_slice(&word.to_le_bytes()[..output.len()]);
                }
                bytes
            })
            .collect()
    }

    fn path_text(path: &Path) -> Result<&str> {
        path.to_str()
            .with_context(|| format!("non-UTF-8 path: {}", path.display()))
    }

    fn open_turso(path: &Path, read_only: bool) -> Result<Arc<Database>> {
        let io = Arc::new(PlatformIO::new()?) as Arc<dyn IO>;
        let flags = if read_only {
            OpenFlags::ReadOnly
        } else {
            OpenFlags::default()
        };
        Database::open_file_with_flags(
            io,
            path_text(path)?,
            flags,
            DatabaseOpts::new().with_without_rowid(true),
            None,
        )
        .with_context(|| format!("open {}", path.display()))
    }

    fn drive(
        database: &Database,
        statement: &mut Statement,
        mut row: impl FnMut(&Row) -> Result<()>,
    ) -> Result<usize> {
        let mut rows = 0;
        loop {
            match statement.step()? {
                StepResult::Row => {
                    row(statement.row().context("missing Turso row")?)?;
                    rows += 1;
                }
                StepResult::IO | StepResult::Yield => database.io.step()?,
                StepResult::Done => {
                    statement.reset()?;
                    return Ok(rows);
                }
                other => bail!("unexpected Turso step: {other:?}"),
            }
        }
    }

    fn exec(database: &Database, connection: &Arc<Connection>, sql: &str) -> Result<()> {
        let mut statement = connection.prepare(sql)?;
        drive(database, &mut statement, |_| Ok(())).map(|_| ())
    }

    fn text(database: &Database, connection: &Arc<Connection>, sql: &str) -> Result<String> {
        let mut statement = connection.prepare(sql)?;
        let mut value = None;
        if drive(database, &mut statement, |row| {
            value = Some(row.get::<&str>(0)?.to_string());
            Ok(())
        })? != 1
        {
            bail!("`{sql}` did not return one row");
        }
        value.with_context(|| format!("`{sql}` returned no text"))
    }

    fn bind(statement: &mut Statement, index: usize, value: Value) -> Result<()> {
        statement
            .bind_at(
                NonZeroUsize::new(index).context("zero parameter index")?,
                value,
            )
            .map_err(Into::into)
    }

    fn build_database(path: &Path, chunks: &[Vec<u8>]) -> Result<(Duration, String)> {
        let started = Instant::now();
        let database = open_turso(path, false)?;
        let connection = database.connect()?;
        exec(&database, &connection, "PRAGMA page_size=4096")?;
        exec(&database, &connection, "PRAGMA journal_mode=WAL")?;
        exec(
            &database,
            &connection,
            "CREATE TABLE chunks_without_rowid(\
                 file_id INTEGER NOT NULL, seq INTEGER NOT NULL, bytes BLOB NOT NULL,\
                 PRIMARY KEY(file_id, seq)) WITHOUT ROWID",
        )?;
        exec(
            &database,
            &connection,
            "CREATE TABLE chunks_rowid(\
                 file_id INTEGER NOT NULL, seq INTEGER NOT NULL, bytes BLOB NOT NULL,\
                 PRIMARY KEY(file_id, seq))",
        )?;
        exec(&database, &connection, "BEGIN IMMEDIATE")?;
        for shape in [Shape::WithoutRowid, Shape::Rowid] {
            let sql = format!(
                "INSERT INTO {}(file_id, seq, bytes) VALUES(?1, ?2, ?3)",
                shape.table()
            );
            let mut insert = connection.prepare(&sql)?;
            for (seq, bytes) in chunks.iter().enumerate() {
                bind(&mut insert, 1, Value::from_i64(FILE_ID))?;
                bind(&mut insert, 2, Value::from_i64(seq as i64))?;
                bind(&mut insert, 3, Value::from_blob(bytes.clone()))?;
                if drive(&database, &mut insert, |_| Ok(()))? != 0 {
                    bail!("INSERT unexpectedly returned a row");
                }
            }
        }
        exec(&database, &connection, "COMMIT")?;
        exec(&database, &connection, "PRAGMA wal_checkpoint(TRUNCATE)")?;
        let delete_result = text(&database, &connection, "PRAGMA journal_mode=DELETE")?;
        connection.close()?;
        drop(database);
        Ok((started.elapsed(), delete_result))
    }

    fn finish_single_file_with_rusqlite(path: &Path) -> Result<()> {
        let connection = Sqlite::open(path)?;
        connection.execute_batch("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;")?;
        connection.close().map_err(|(_, error)| error.into())
    }

    fn blob(row: &Row, index: usize) -> Result<&Vec<u8>> {
        match row.get::<&Value>(index)? {
            Value::Blob(bytes) => Ok(bytes),
            _ => bail!("Turso value is not a BLOB"),
        }
    }

    fn run_turso(path: &Path, shape: Shape, chunks: &[Vec<u8>]) -> Result<(usize, bool)> {
        let database = open_turso(path, true)?;
        let connection = database.connect()?;
        let measured = |pattern, useful, source, started: Instant| {
            print_measurement(
                "turso_core",
                shape.name(),
                pattern,
                useful,
                source,
                started.elapsed(),
            );
        };
        let sql = format!(
            "SELECT seq, bytes FROM {} WHERE file_id=1 ORDER BY seq",
            shape.table()
        );
        let mut whole = connection.prepare(&sql)?;
        let started = Instant::now();
        let rows = drive(&database, &mut whole, |row| {
            let seq = row.get::<i64>(0)? as usize;
            if blob(row, 1)? != &chunks[seq] {
                bail!("{} chunk {seq} mismatch", shape.name());
            }
            Ok(())
        })?;
        ensure!(
            rows == chunks.len(),
            "{} returned {rows} chunks",
            shape.name()
        );
        let total: usize = chunks.iter().map(Vec::len).sum();
        measured("sequential", total, total, started);

        let sql = format!(
            "SELECT bytes FROM {} WHERE file_id=?1 AND seq=?2",
            shape.table()
        );
        let mut point = connection.prepare(&sql)?;
        let mut random = XorShift64(0x9e37_79b9_7f4a_7c15);
        let mut first_pointer = None;
        let mut reused = true;
        let mut capacity = 0;
        let started = Instant::now();
        for _ in 0..RANGE_READS {
            let seq = random.bounded(FULL_CHUNKS);
            let offset = random.bounded(CHUNK_SIZE - RANGE_SIZE + 1);
            bind(&mut point, 1, Value::from_i64(FILE_ID))?;
            bind(&mut point, 2, Value::from_i64(seq as i64))?;
            if drive(&database, &mut point, |row| {
                let bytes = blob(row, 0)?;
                capacity = capacity.max(bytes.capacity());
                let pointer = bytes.as_ptr() as usize;
                reused &= first_pointer.is_none_or(|first| first == pointer);
                first_pointer.get_or_insert(pointer);
                if bytes[offset..offset + RANGE_SIZE] != chunks[seq][offset..offset + RANGE_SIZE] {
                    bail!("{} range mismatch", shape.name());
                }
                Ok(())
            })? != 1
            {
                bail!("Turso point read did not return one row");
            }
        }
        measured(
            "random 64 KiB",
            RANGE_READS * RANGE_SIZE,
            RANGE_READS * CHUNK_SIZE,
            started,
        );

        bind(&mut point, 1, Value::from_i64(FILE_ID))?;
        bind(&mut point, 2, Value::from_i64(FULL_CHUNKS as i64))?;
        let started = Instant::now();
        if drive(&database, &mut point, |row| {
            if blob(row, 0)? != &chunks[FULL_CHUNKS] {
                bail!("Turso tail mismatch");
            }
            Ok(())
        })? != 1
        {
            bail!("Turso tail read did not return one row");
        }
        measured("tail 64 KiB", TAIL_SIZE, TAIL_SIZE, started);
        connection.close()?;
        Ok((capacity, reused))
    }

    fn immutable_sqlite(path: &Path) -> Result<Sqlite> {
        let uri = format!("file:{}?immutable=1", path.display());
        Sqlite::open_with_flags(
            uri,
            SqliteFlags::SQLITE_OPEN_READ_ONLY | SqliteFlags::SQLITE_OPEN_URI,
        )
        .map_err(Into::into)
    }

    fn run_rusqlite(path: &Path, chunks: &[Vec<u8>]) -> Result<()> {
        let connection = immutable_sqlite(path)?;
        let measured = |pattern, useful, source, started: Instant| {
            print_measurement(
                "rusqlite Blob",
                "rowid",
                pattern,
                useful,
                source,
                started.elapsed(),
            );
        };
        let rowids = {
            let mut query = connection
                .prepare("SELECT rowid FROM chunks_rowid WHERE file_id=1 ORDER BY seq")?;
            let rows = query
                .query_map([], |row| row.get::<_, i64>(0))?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            rows
        };
        let mut handle = connection.blob_open(MAIN_DB, "chunks_rowid", "bytes", rowids[0], true)?;
        let mut whole_buffer = vec![0; CHUNK_SIZE];
        let started = Instant::now();
        for (seq, rowid) in rowids.iter().copied().enumerate() {
            handle.reopen(rowid)?;
            let expected = &chunks[seq];
            handle.read_at_exact(&mut whole_buffer[..expected.len()], 0)?;
            if whole_buffer[..expected.len()] != **expected {
                bail!("rusqlite chunk {seq} mismatch");
            }
        }
        let total: usize = chunks.iter().map(Vec::len).sum();
        measured("sequential", total, total, started);

        let mut range_buffer = vec![0; RANGE_SIZE];
        let mut random = XorShift64(0x9e37_79b9_7f4a_7c15);
        let started = Instant::now();
        for _ in 0..RANGE_READS {
            let seq = random.bounded(FULL_CHUNKS);
            let offset = random.bounded(CHUNK_SIZE - RANGE_SIZE + 1);
            handle.reopen(rowids[seq])?;
            handle.read_at_exact(&mut range_buffer, offset)?;
            if range_buffer != chunks[seq][offset..offset + RANGE_SIZE] {
                bail!("rusqlite range mismatch");
            }
        }
        measured(
            "random 64 KiB",
            RANGE_READS * RANGE_SIZE,
            RANGE_READS * RANGE_SIZE,
            started,
        );
        handle.reopen(rowids[FULL_CHUNKS])?;
        let started = Instant::now();
        handle.read_at_exact(&mut range_buffer, 0)?;
        if range_buffer != chunks[FULL_CHUNKS] {
            bail!("rusqlite tail mismatch");
        }
        measured("tail 64 KiB", TAIL_SIZE, TAIL_SIZE, started);

        let without_error = connection
            .blob_open(MAIN_DB, "chunks_without_rowid", "bytes", rowids[0], true)
            .err()
            .context("incremental Blob unexpectedly opened WITHOUT ROWID table")?;
        println!("rusqlite WITHOUT ROWID Blob open: expected failure: {without_error}");
        Ok(())
    }

    fn filenames(directory: &Path) -> Result<Vec<String>> {
        let mut names = std::fs::read_dir(directory)?
            .map(|entry| {
                entry?
                    .file_name()
                    .into_string()
                    .map_err(|_| anyhow::anyhow!("non-UTF-8 sidecar name"))
            })
            .collect::<Result<Vec<_>>>()?;
        names.sort();
        Ok(names)
    }

    fn verify_immutable_copy(source: &Path, directory: &Path, tail: &[u8]) -> Result<()> {
        let copy = directory.join("bundle-0444.sqlite3");
        std::fs::copy(source, &copy)?;
        let mut permissions = std::fs::metadata(&copy)?.permissions();
        permissions.set_readonly(true);
        std::fs::set_permissions(&copy, permissions)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            ensure!(std::fs::metadata(&copy)?.permissions().mode() & 0o777 == 0o444);
        }

        let database = open_turso(&copy, true)?;
        let connection = database.connect()?;
        let mut statement =
            connection.prepare("SELECT bytes FROM chunks_rowid WHERE file_id=1 AND seq=256")?;
        drive(&database, &mut statement, |row| {
            if blob(row, 0)? == tail {
                Ok(())
            } else {
                bail!("Turso immutable copy mismatch")
            }
        })?;
        drop(statement);
        connection.close()?;
        drop(database);

        let sqlite = immutable_sqlite(&copy)?;
        let count: i64 =
            sqlite.query_row("SELECT count(*) FROM chunks_rowid", [], |row| row.get(0))?;
        if count != (FULL_CHUNKS + 1) as i64 {
            bail!("immutable copy has {count} rows");
        }
        drop(sqlite);
        let expected = vec![
            "bundle-0444.sqlite3".to_string(),
            "bundle.sqlite3".to_string(),
        ];
        if filenames(directory)? != expected {
            bail!("read-only opens made sidecars: {:?}", filenames(directory)?);
        }
        Ok(())
    }

    #[test]
    fn compare_bundle_blob_read_paths() -> Result<()> {
        let temporary = TempDir::new()?;
        let path = temporary.0.join("bundle.sqlite3");
        let chunks = corpus();
        let (build, delete_result) = build_database(&path, &chunks)?;
        let turso_files = filenames(&temporary.0)?;
        let wal_path = temporary.0.join("bundle.sqlite3-wal");
        let wal_bytes = std::fs::metadata(&wal_path)
            .map(|metadata| metadata.len())
            .unwrap_or(0);
        if delete_result != "wal" || turso_files.len() > 2 || wal_bytes != 0 {
            bail!(
                "unexpected Turso finalization: mode={delete_result}, files={turso_files:?}, wal={wal_bytes}"
            );
        }
        println!(
            "Turso DELETE request returned {delete_result}; close left a {wal_bytes}-byte WAL; rusqlite finalizes it"
        );
        finish_single_file_with_rusqlite(&path)?;
        if filenames(&temporary.0)? != ["bundle.sqlite3"] {
            bail!("writer left sidecars: {:?}", filenames(&temporary.0)?);
        }
        let file_mib = std::fs::metadata(&path)?.len() as f64 / 1_048_576.0;
        println!(
            "M4b build: two identical 256 MiB tables plus 64 KiB tails; {:.1} MiB file in {:.3}s",
            file_mib,
            build.as_secs_f64()
        );
        println!("| engine | shape | pattern | useful MiB | source MiB | sec | useful MiB/s | source MiB/s |");
        println!("|---|---|---|---:|---:|---:|---:|---:|");
        for shape in [Shape::WithoutRowid, Shape::Rowid] {
            let (capacity, reused) = run_turso(&path, shape, &chunks)?;
            println!(
                "turso_core {} sub-range row buffer: {} bytes capacity; reused={reused}",
                shape.name(),
                capacity
            );
        }
        run_rusqlite(&path, &chunks)?;
        verify_immutable_copy(&path, &temporary.0, &chunks[FULL_CHUNKS])?;
        println!(
            "M4b verdict: rowid required for incremental fallback; turso_core materializes full rows"
        );
        Ok(())
    }
}
