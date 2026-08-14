#![forbid(unsafe_code)]

//! Milestone 0 F6 feasibility spike.
//!
//! This crate is test-only and is not part of the shipped Gitility runtime.

#[cfg(test)]
mod tests {
    use std::num::NonZeroUsize;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::{Arc, Barrier};
    use std::thread::{self, JoinHandle};
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    use turso_core::{
        Connection, Database, DatabaseOpts, OpenFlags, PlatformIO, Row, Statement, StepResult,
        Value, IO,
    };

    type SpikeResult<T> = Result<T, String>;

    const PACK_ID: &str = "pack-main";
    const CHUNK_SIZE: usize = 1024 * 1024;
    const CHUNK_COUNT: usize = 64;
    const CONCURRENT_THREADS: usize = 16;
    const OPERATIONS_PER_THREAD: usize = 2_000;
    const MIXED_READER_THREADS: usize = 8;
    const MIXED_CHURN_THREADS: usize = 8;
    const MIXED_READS_PER_READER: usize = 250;
    const MIXED_CONNECT_CYCLES: usize = 100;
    const DATA_SEED: u64 = 0xd1b5_4a32_d192_ed03;
    const THREAD_SEED: u64 = 0x9e37_79b9_7f4a_7c15;

    static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

    #[derive(Default)]
    struct WorkerStats {
        point_operations: usize,
        range_operations: usize,
        verified_chunks: usize,
    }

    impl WorkerStats {
        fn add(&mut self, other: Self) {
            self.point_operations += other.point_operations;
            self.range_operations += other.range_operations;
            self.verified_chunks += other.verified_chunks;
        }
    }

    struct TestDirectory {
        path: PathBuf,
    }

    impl TestDirectory {
        fn new() -> SpikeResult<Self> {
            let timestamp = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_err(|error| format!("system clock is before Unix epoch: {error}"))?
                .as_nanos();

            for _ in 0..100 {
                let sequence = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
                let path = std::env::temp_dir().join(format!(
                    "gitility-f6-{}-{timestamp}-{sequence}",
                    std::process::id()
                ));
                match std::fs::create_dir(&path) {
                    Ok(()) => return Ok(Self { path }),
                    Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                    Err(error) => {
                        return Err(format!(
                            "create temporary directory {}: {error}",
                            path.display()
                        ));
                    }
                }
            }

            Err("could not allocate a unique temporary directory".to_string())
        }

        fn path(&self) -> &Path {
            &self.path
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            if let Err(error) = std::fs::remove_dir_all(&self.path) {
                eprintln!(
                    "warning: could not remove F6 temporary directory {}: {error}",
                    self.path.display()
                );
            }
        }
    }

    struct XorShift64 {
        state: u64,
    }

    impl XorShift64 {
        fn new(seed: u64) -> Self {
            debug_assert_ne!(seed, 0);
            Self { state: seed }
        }

        fn next(&mut self) -> u64 {
            let mut value = self.state;
            value ^= value << 13;
            value ^= value >> 7;
            value ^= value << 17;
            self.state = value;
            value
        }

        fn bounded(&mut self, upper: usize) -> usize {
            debug_assert!(upper > 0);
            (self.next() % upper as u64) as usize
        }
    }

    fn deterministic_corpus() -> Vec<Vec<u8>> {
        (0..CHUNK_COUNT).map(deterministic_chunk).collect()
    }

    fn deterministic_chunk(chunk_index: usize) -> Vec<u8> {
        let seed = DATA_SEED ^ (chunk_index as u64 + 1).wrapping_mul(0xa076_1d64_78bd_642f);
        let mut generator = XorShift64::new(seed);
        let mut bytes = vec![0_u8; CHUNK_SIZE];

        for block in bytes.chunks_exact_mut(size_of::<u64>()) {
            block.copy_from_slice(&generator.next().to_le_bytes());
        }

        bytes
    }

    fn path_text(path: &Path) -> SpikeResult<&str> {
        path.to_str()
            .ok_or_else(|| format!("database path is not UTF-8: {}", path.display()))
    }

    fn platform_io() -> SpikeResult<Arc<dyn IO>> {
        PlatformIO::new()
            .map(|io| Arc::new(io) as Arc<dyn IO>)
            .map_err(|error| format!("initialize Turso platform I/O: {error}"))
    }

    fn open_database(path: &Path, read_only: bool) -> SpikeResult<Arc<Database>> {
        let flags = if read_only {
            OpenFlags::ReadOnly
        } else {
            OpenFlags::default()
        };
        Database::open_file_with_flags(
            platform_io()?,
            path_text(path)?,
            flags,
            DatabaseOpts::new(),
            None,
        )
        .map_err(|error| format!("open Turso database {}: {error}", path.display()))
    }

    fn parameter(index: usize) -> SpikeResult<NonZeroUsize> {
        NonZeroUsize::new(index).ok_or_else(|| "SQL parameter index must be non-zero".to_string())
    }

    /// Turso's VM yields at I/O boundaries. Explicitly stepping both the VM
    /// and its owning Database I/O is the synchronous contract used by the
    /// CLI and is the load-bearing behavior the future NIF needs.
    fn drive_statement(
        database: &Database,
        statement: &mut Statement,
        mut on_row: impl FnMut(&Row) -> SpikeResult<()>,
    ) -> SpikeResult<usize> {
        let mut row_count = 0;
        loop {
            match statement
                .step()
                .map_err(|error| format!("step SQL statement: {error}"))?
            {
                StepResult::Row => {
                    let row = statement
                        .row()
                        .ok_or_else(|| "Turso returned Row without row data".to_string())?;
                    on_row(row)?;
                    row_count += 1;
                }
                StepResult::IO | StepResult::Yield => database
                    .io
                    .step()
                    .map_err(|error| format!("poll Turso I/O: {error}"))?,
                StepResult::Done => {
                    statement
                        .reset()
                        .map_err(|error| format!("reset SQL statement: {error}"))?;
                    return Ok(row_count);
                }
                StepResult::Busy => return Err("Turso statement returned Busy".to_string()),
                StepResult::Interrupt => {
                    return Err("Turso statement returned Interrupt".to_string());
                }
            }
        }
    }

    fn execute(database: &Database, connection: &Arc<Connection>, sql: &str) -> SpikeResult<()> {
        let mut statement = connection
            .prepare(sql)
            .map_err(|error| format!("prepare `{sql}`: {error}"))?;
        drive_statement(database, &mut statement, |_| Ok(())).map(|_| ())
    }

    fn build_bundle(path: &Path, expected: &[Vec<u8>]) -> SpikeResult<Duration> {
        let started = Instant::now();
        let database = open_database(path, false)?;
        let connection = database
            .connect()
            .map_err(|error| format!("connect bundle writer: {error}"))?;

        execute(
            &database,
            &connection,
            "CREATE TABLE chunks(\
                pack_id TEXT NOT NULL,\
                chunk_index INTEGER NOT NULL,\
                data BLOB NOT NULL,\
                PRIMARY KEY (pack_id, chunk_index)\
             )",
        )?;
        execute(
            &database,
            &connection,
            "CREATE TABLE refs(name TEXT PRIMARY KEY, oid TEXT NOT NULL)",
        )?;
        execute(
            &database,
            &connection,
            "CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)",
        )?;
        execute(&database, &connection, "BEGIN")?;

        let mut insert = connection
            .prepare("INSERT INTO chunks(pack_id, chunk_index, data) VALUES (?1, ?2, ?3)")
            .map_err(|error| format!("prepare chunk insert: {error}"))?;
        for (chunk_index, data) in expected.iter().enumerate() {
            insert
                .bind_at(parameter(1)?, Value::build_text(PACK_ID))
                .map_err(|error| format!("bind pack ID for chunk {chunk_index}: {error}"))?;
            insert
                .bind_at(parameter(2)?, Value::from_i64(chunk_index as i64))
                .map_err(|error| format!("bind index for chunk {chunk_index}: {error}"))?;
            insert
                .bind_at(parameter(3)?, Value::from_blob(data.clone()))
                .map_err(|error| format!("bind data for chunk {chunk_index}: {error}"))?;
            drive_statement(&database, &mut insert, |_| Ok(()))?;
        }
        drop(insert);

        execute(
            &database,
            &connection,
            "INSERT INTO refs(name, oid) VALUES \
             ('refs/heads/main', '0123456789abcdef0123456789abcdef01234567')",
        )?;
        execute(
            &database,
            &connection,
            "INSERT INTO metadata(key, value) VALUES \
             ('bundle_format_version', '1'), ('hash_algorithm', 'sha1')",
        )?;
        execute(&database, &connection, "COMMIT")?;
        verify_integrity(&database, &connection)?;

        connection
            .close()
            .map_err(|error| format!("close bundle writer: {error}"))?;
        Ok(started.elapsed())
    }

    fn verify_integrity(database: &Database, connection: &Arc<Connection>) -> SpikeResult<()> {
        let mut statement = connection
            .prepare("PRAGMA integrity_check")
            .map_err(|error| format!("prepare integrity_check: {error}"))?;
        let mut result = None;
        let rows = drive_statement(database, &mut statement, |row| {
            let value = row
                .get::<&str>(0)
                .map_err(|error| format!("read integrity_check result: {error}"))?;
            result = Some(value.to_string());
            Ok(())
        })?;

        if rows == 1 && result.as_deref() == Some("ok") {
            Ok(())
        } else {
            Err(format!(
                "integrity_check returned {rows} rows and result {result:?}"
            ))
        }
    }

    fn verify_auxiliary_tables(
        database: &Database,
        connection: &Arc<Connection>,
    ) -> SpikeResult<()> {
        let mut statement = connection
            .prepare(
                "SELECT \
                    (SELECT COUNT(*) FROM refs), \
                    (SELECT COUNT(*) FROM metadata), \
                    (SELECT COUNT(*) FROM chunks)",
            )
            .map_err(|error| format!("prepare bundle shape check: {error}"))?;
        let rows = drive_statement(database, &mut statement, |row| {
            let refs = row
                .get::<i64>(0)
                .map_err(|error| format!("read refs count: {error}"))?;
            let metadata = row
                .get::<i64>(1)
                .map_err(|error| format!("read metadata count: {error}"))?;
            let chunks = row
                .get::<i64>(2)
                .map_err(|error| format!("read chunk count: {error}"))?;
            if (refs, metadata, chunks) == (1, 2, CHUNK_COUNT as i64) {
                Ok(())
            } else {
                Err(format!(
                    "unexpected table counts: refs={refs}, metadata={metadata}, chunks={chunks}"
                ))
            }
        })?;

        if rows == 1 {
            Ok(())
        } else {
            Err(format!("bundle shape check returned {rows} rows"))
        }
    }

    fn bind_point(statement: &mut Statement, chunk_index: usize) -> SpikeResult<()> {
        statement
            .bind_at(parameter(1)?, Value::build_text(PACK_ID))
            .map_err(|error| format!("bind point lookup pack ID: {error}"))?;
        statement
            .bind_at(parameter(2)?, Value::from_i64(chunk_index as i64))
            .map_err(|error| format!("bind point lookup chunk index: {error}"))
    }

    fn verify_chunk_row(row: &Row, expected: &[Vec<u8>]) -> SpikeResult<usize> {
        let chunk_index = row
            .get::<i64>(0)
            .map_err(|error| format!("read returned chunk index: {error}"))?;
        let chunk_index = usize::try_from(chunk_index)
            .map_err(|_| format!("returned negative chunk index {chunk_index}"))?;
        let expected_bytes = expected
            .get(chunk_index)
            .ok_or_else(|| format!("returned out-of-range chunk index {chunk_index}"))?;
        let value = row
            .get::<&Value>(1)
            .map_err(|error| format!("read chunk {chunk_index} value: {error}"))?;
        let actual_bytes = value
            .to_blob()
            .ok_or_else(|| format!("chunk {chunk_index} data was not a BLOB"))?;

        if actual_bytes != expected_bytes {
            let first_difference = actual_bytes
                .iter()
                .zip(expected_bytes)
                .position(|(actual, expected)| actual != expected)
                .unwrap_or(actual_bytes.len().min(expected_bytes.len()));
            return Err(format!(
                "chunk {chunk_index} differs at byte {first_difference}; actual length {}, expected length {}",
                actual_bytes.len(),
                expected_bytes.len()
            ));
        }

        Ok(chunk_index)
    }

    fn point_lookup(
        database: &Database,
        statement: &mut Statement,
        chunk_index: usize,
        expected: &[Vec<u8>],
    ) -> SpikeResult<usize> {
        bind_point(statement, chunk_index)?;
        let rows = drive_statement(database, statement, |row| {
            let returned_index = verify_chunk_row(row, expected)?;
            if returned_index == chunk_index {
                Ok(())
            } else {
                Err(format!(
                    "point lookup requested chunk {chunk_index}, returned {returned_index}"
                ))
            }
        })?;

        if rows == 1 {
            Ok(rows)
        } else {
            Err(format!(
                "point lookup for chunk {chunk_index} returned {rows} rows"
            ))
        }
    }

    fn range_lookup(
        database: &Database,
        statement: &mut Statement,
        first: usize,
        last: usize,
        expected: &[Vec<u8>],
    ) -> SpikeResult<usize> {
        statement
            .bind_at(parameter(1)?, Value::build_text(PACK_ID))
            .map_err(|error| format!("bind range lookup pack ID: {error}"))?;
        statement
            .bind_at(parameter(2)?, Value::from_i64(first as i64))
            .map_err(|error| format!("bind range start: {error}"))?;
        statement
            .bind_at(parameter(3)?, Value::from_i64(last as i64))
            .map_err(|error| format!("bind range end: {error}"))?;

        let mut next_expected = first;
        let rows = drive_statement(database, statement, |row| {
            let returned_index = verify_chunk_row(row, expected)?;
            if returned_index != next_expected {
                return Err(format!(
                    "range {first}..={last} expected chunk {next_expected}, returned {returned_index}"
                ));
            }
            next_expected += 1;
            Ok(())
        })?;
        let expected_rows = last - first + 1;

        if rows == expected_rows {
            Ok(rows)
        } else {
            Err(format!(
                "range {first}..={last} returned {rows} rows, expected {expected_rows}"
            ))
        }
    }

    fn concurrent_worker(
        thread_index: usize,
        database: Arc<Database>,
        expected: Arc<Vec<Vec<u8>>>,
        barrier: Arc<Barrier>,
    ) -> SpikeResult<WorkerStats> {
        barrier.wait();
        let connection = database
            .connect()
            .map_err(|error| format!("reader {thread_index} connect: {error}"))?;
        let mut point_statement = connection
            .prepare(
                "SELECT chunk_index, data FROM chunks \
                 WHERE pack_id = ?1 AND chunk_index = ?2",
            )
            .map_err(|error| format!("reader {thread_index} prepare point lookup: {error}"))?;
        let mut range_statement = connection
            .prepare(
                "SELECT chunk_index, data FROM chunks \
                 WHERE pack_id = ?1 AND chunk_index BETWEEN ?2 AND ?3 \
                 ORDER BY chunk_index",
            )
            .map_err(|error| format!("reader {thread_index} prepare range lookup: {error}"))?;
        let mut generator = XorShift64::new(
            THREAD_SEED ^ (thread_index as u64 + 1).wrapping_mul(0x94d0_49bb_1331_11eb),
        );
        let mut stats = WorkerStats::default();

        for _ in 0..OPERATIONS_PER_THREAD {
            if generator.bounded(4) == 0 {
                let width = 2 + generator.bounded(3);
                let first = generator.bounded(CHUNK_COUNT - width + 1);
                let last = first + width - 1;
                stats.verified_chunks +=
                    range_lookup(&database, &mut range_statement, first, last, &expected)?;
                stats.range_operations += 1;
            } else {
                let chunk_index = generator.bounded(CHUNK_COUNT);
                stats.verified_chunks +=
                    point_lookup(&database, &mut point_statement, chunk_index, &expected)?;
                stats.point_operations += 1;
            }
        }

        drop(point_statement);
        drop(range_statement);
        connection
            .close()
            .map_err(|error| format!("reader {thread_index} close: {error}"))?;
        Ok(stats)
    }

    fn spawn_worker<T: Send + 'static>(
        name: String,
        worker: impl FnOnce() -> SpikeResult<T> + Send + 'static,
    ) -> SpikeResult<JoinHandle<SpikeResult<T>>> {
        thread::Builder::new()
            .name(name.clone())
            .spawn(worker)
            .map_err(|error| format!("spawn {name}: {error}"))
    }

    fn join_worker<T>(handle: JoinHandle<SpikeResult<T>>) -> SpikeResult<T> {
        handle
            .join()
            .map_err(|_| "F6 native worker thread panicked".to_string())?
    }

    fn concurrent_read_phase(
        database: Arc<Database>,
        expected: Arc<Vec<Vec<u8>>>,
    ) -> SpikeResult<(WorkerStats, Duration)> {
        let barrier = Arc::new(Barrier::new(CONCURRENT_THREADS + 1));
        let mut handles = Vec::with_capacity(CONCURRENT_THREADS);
        for thread_index in 0..CONCURRENT_THREADS {
            let worker_database = Arc::clone(&database);
            let worker_expected = Arc::clone(&expected);
            let worker_barrier = Arc::clone(&barrier);
            handles.push(spawn_worker(
                format!("f6-reader-{thread_index}"),
                move || {
                    concurrent_worker(
                        thread_index,
                        worker_database,
                        worker_expected,
                        worker_barrier,
                    )
                },
            )?);
        }

        let started = Instant::now();
        barrier.wait();
        let mut aggregate = WorkerStats::default();
        for handle in handles {
            aggregate.add(join_worker(handle)?);
        }
        Ok((aggregate, started.elapsed()))
    }

    fn stable_mixed_reader(
        thread_index: usize,
        database: Arc<Database>,
        expected: Arc<Vec<Vec<u8>>>,
        barrier: Arc<Barrier>,
    ) -> SpikeResult<usize> {
        barrier.wait();
        let connection = database
            .connect()
            .map_err(|error| format!("mixed reader {thread_index} connect: {error}"))?;
        let mut statement = connection
            .prepare(
                "SELECT chunk_index, data FROM chunks \
                 WHERE pack_id = ?1 AND chunk_index = ?2",
            )
            .map_err(|error| format!("mixed reader {thread_index} prepare: {error}"))?;
        let mut generator = XorShift64::new(
            THREAD_SEED ^ (thread_index as u64 + 101).wrapping_mul(0xbf58_476d_1ce4_e5b9),
        );
        let mut verified = 0;

        for _ in 0..MIXED_READS_PER_READER {
            let chunk_index = generator.bounded(CHUNK_COUNT);
            verified += point_lookup(&database, &mut statement, chunk_index, &expected)?;
        }

        drop(statement);
        connection
            .close()
            .map_err(|error| format!("mixed reader {thread_index} close: {error}"))?;
        Ok(verified)
    }

    fn connection_churn_worker(
        thread_index: usize,
        database: Arc<Database>,
        expected: Arc<Vec<Vec<u8>>>,
        barrier: Arc<Barrier>,
    ) -> SpikeResult<usize> {
        barrier.wait();
        let mut generator = XorShift64::new(
            THREAD_SEED ^ (thread_index as u64 + 201).wrapping_mul(0xd6e8_feb8_6659_fd93),
        );
        let mut verified = 0;

        for cycle in 0..MIXED_CONNECT_CYCLES {
            let connection = database.connect().map_err(|error| {
                format!("churner {thread_index} connect during cycle {cycle}: {error}")
            })?;
            let mut statement = connection
                .prepare(
                    "SELECT chunk_index, data FROM chunks \
                     WHERE pack_id = ?1 AND chunk_index = ?2",
                )
                .map_err(|error| {
                    format!("churner {thread_index} prepare during cycle {cycle}: {error}")
                })?;
            let chunk_index = generator.bounded(CHUNK_COUNT);
            verified += point_lookup(&database, &mut statement, chunk_index, &expected)?;
            drop(statement);

            // Exercise both public close and the Drop teardown that a released
            // NIF resource would use. They share connection-count bookkeeping
            // but take distinct paths in turso_core.
            if cycle % 2 == 0 {
                connection.close().map_err(|error| {
                    format!("churner {thread_index} close during cycle {cycle}: {error}")
                })?;
            } else {
                drop(connection);
            }
        }

        Ok(verified)
    }

    fn mixed_lifetime_phase(
        database: Arc<Database>,
        expected: Arc<Vec<Vec<u8>>>,
    ) -> SpikeResult<(usize, Duration)> {
        let worker_count = MIXED_READER_THREADS + MIXED_CHURN_THREADS;
        let barrier = Arc::new(Barrier::new(worker_count + 1));
        let mut handles = Vec::with_capacity(worker_count);

        for thread_index in 0..MIXED_READER_THREADS {
            let worker_database = Arc::clone(&database);
            let worker_expected = Arc::clone(&expected);
            let worker_barrier = Arc::clone(&barrier);
            handles.push(spawn_worker(
                format!("f6-mixed-reader-{thread_index}"),
                move || {
                    stable_mixed_reader(
                        thread_index,
                        worker_database,
                        worker_expected,
                        worker_barrier,
                    )
                },
            )?);
        }
        for thread_index in 0..MIXED_CHURN_THREADS {
            let worker_database = Arc::clone(&database);
            let worker_expected = Arc::clone(&expected);
            let worker_barrier = Arc::clone(&barrier);
            handles.push(spawn_worker(
                format!("f6-churner-{thread_index}"),
                move || {
                    connection_churn_worker(
                        thread_index,
                        worker_database,
                        worker_expected,
                        worker_barrier,
                    )
                },
            )?);
        }

        let started = Instant::now();
        barrier.wait();
        let mut verified = 0;
        for handle in handles {
            verified += join_worker(handle)?;
        }
        Ok((verified, started.elapsed()))
    }

    fn gibibytes(chunks: usize) -> f64 {
        (chunks * CHUNK_SIZE) as f64 / (1024.0 * 1024.0 * 1024.0)
    }

    fn print_throughput(label: &str, chunks: usize, elapsed: Duration) {
        let seconds = elapsed.as_secs_f64();
        println!(
            "F6 {label}: {chunks} byte-verified chunks ({:.2} GiB) in {:.3}s = {:.0} chunks/s ({:.2} GiB/s)",
            gibibytes(chunks),
            seconds,
            chunks as f64 / seconds,
            gibibytes(chunks) / seconds
        );
    }

    #[test]
    fn many_connections_read_one_bundle_correctly_under_load() -> SpikeResult<()> {
        let temporary_directory = TestDirectory::new()?;
        let database_path = temporary_directory.path().join("bundle.sqlite3");
        let expected = Arc::new(deterministic_corpus());

        let build_elapsed = build_bundle(&database_path, &expected)?;
        let file_size = std::fs::metadata(&database_path)
            .map_err(|error| format!("stat built bundle {}: {error}", database_path.display()))?
            .len();
        println!(
            "F6 build: {} chunks ({:.2} MiB payload, {:.2} MiB file) in {:.3}s",
            CHUNK_COUNT,
            (CHUNK_COUNT * CHUNK_SIZE) as f64 / (1024.0 * 1024.0),
            file_size as f64 / (1024.0 * 1024.0),
            build_elapsed.as_secs_f64()
        );

        let database = open_database(&database_path, true)?;
        let shape_connection = database
            .connect()
            .map_err(|error| format!("connect bundle shape verifier: {error}"))?;
        verify_auxiliary_tables(&database, &shape_connection)?;
        shape_connection
            .close()
            .map_err(|error| format!("close bundle shape verifier: {error}"))?;

        let (read_stats, read_elapsed) =
            concurrent_read_phase(Arc::clone(&database), Arc::clone(&expected))?;
        println!(
            "F6 concurrent mix: {} point lookups + {} range scans across {} OS threads",
            read_stats.point_operations, read_stats.range_operations, CONCURRENT_THREADS
        );
        print_throughput("concurrent read", read_stats.verified_chunks, read_elapsed);

        let (mixed_chunks, mixed_elapsed) = mixed_lifetime_phase(database, expected)?;
        println!(
            "F6 mixed lifetime: {MIXED_READER_THREADS} persistent readers + \
             {MIXED_CHURN_THREADS} connection churners ({} connect/read/close cycles)",
            MIXED_CHURN_THREADS * MIXED_CONNECT_CYCLES
        );
        print_throughput("mixed lifetime", mixed_chunks, mixed_elapsed);
        println!(
            "F6 verdict: PASS — turso_core concurrent immutable bundle reads are byte-correct"
        );

        Ok(())
    }
}
