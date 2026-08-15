use super::*;
use crate::local_odb::LocalOdb;
use crate::odb::ObjectDb;
use crate::test_support::{fixture_oid, fixture_repo};
use crate::{list_tree, read_file, FileOptions, HashKind, TreeOptions};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering as StdOrdering};
use std::sync::{mpsc, Arc as StdArc, Barrier};
use std::thread;
use std::time::Duration;

fn oid(byte: u8) -> Oid {
    Oid::new(HashKind::Sha1, &[byte; 20]).expect("test OID is valid")
}

fn observer_spec(
    observer: Arc<dyn JobObserver>,
    task: impl FnOnce(&Budget) -> Result<JobOutput, Error> + Send + 'static,
) -> JobSpec {
    JobSpec {
        task: Box::new(task),
        limits: BudgetLimits::default(),
        timeout_ms: None,
        observer,
    }
}

fn wait_for_terminal(job: &Job) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !job.is_terminal() && Instant::now() < deadline {
        thread::yield_now();
    }
    assert!(job.is_terminal(), "job did not become terminal");
}

#[test]
fn default_config_matches_the_public_contract() {
    assert_eq!(
        RuntimeConfig::default(),
        RuntimeConfig {
            workers: 4,
            max_queue: 1_000,
            max_jobs_per_owner: 16,
            retry_after_ms: 100,
            shutdown_join_timeout_ms: 5_000,
        }
    );
}

#[derive(Default)]
struct InspectObserver {
    calls: AtomicU64,
    saw_terminal_with_output: AtomicBool,
}

impl JobObserver for InspectObserver {
    fn completed(&self, job: &Job) {
        let output_ready = sync::lock(&job.output).is_some();
        self.saw_terminal_with_output
            .store(job.is_terminal() && output_ready, StdOrdering::Release);
        self.calls.fetch_add(1, StdOrdering::Release);
    }
}

#[test]
fn completed_output_is_published_before_one_observer_callback() {
    let runtime = Runtime::start(RuntimeConfig {
        workers: 1,
        ..RuntimeConfig::default()
    });
    let observer = Arc::new(InspectObserver::default());
    let job = runtime
        .submit(
            7,
            observer_spec(observer.clone(), |_| Ok(JobOutput::Oid(oid(1)))),
        )
        .expect("job is admitted");

    // The state machine publishes the terminal state (and the output slot)
    // BEFORE it fires the observer, so `is_terminal()` can be true while the
    // callback is still in flight. Wait on the observer itself — that is the
    // signal this test is about. (Waiting on `is_terminal()` here was a real
    // race: it passed on macOS by scheduling luck and failed 3/3 on Linux.)
    let deadline = Instant::now() + Duration::from_secs(5);
    while observer.calls.load(StdOrdering::Acquire) == 0 && Instant::now() < deadline {
        thread::yield_now();
    }
    assert_eq!(job.state(), JobState::Completed);
    assert_eq!(observer.calls.load(StdOrdering::Acquire), 1);
    assert!(observer.saw_terminal_with_output.load(StdOrdering::Acquire));
    assert_eq!(job.take_output(), Some(Ok(JobOutput::Oid(oid(1)))));
    assert_eq!(job.take_output(), None);
    assert_eq!(job.id(), 1);
    assert_eq!(job.owner(), 7);
    runtime.shutdown();
}

#[test]
fn queued_cancel_is_immediate_take_once_and_idempotent() {
    let runtime = Runtime::start(RuntimeConfig {
        workers: 1,
        max_queue: 2,
        max_jobs_per_owner: 2,
        ..RuntimeConfig::default()
    });
    let observer = Arc::new(TestObserver::default());
    let (started_tx, started_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let blocker = runtime
        .submit(
            1,
            observer_spec(observer.clone(), move |_| {
                let _ = started_tx.send(());
                release_rx.recv().map_err(|_| {
                    Error::new(ErrorCode::BackendError, "test release channel closed")
                })?;
                Ok(JobOutput::Oid(oid(2)))
            }),
        )
        .expect("blocker is admitted");
    started_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("worker starts blocker");

    let queued = runtime
        .submit(
            1,
            observer_spec(observer.clone(), |_| Ok(JobOutput::Oid(oid(3)))),
        )
        .expect("queued job is admitted");
    queued.cancel();
    queued.cancel();
    assert_eq!(queued.state(), JobState::Cancelled);
    let error = queued
        .take_output()
        .expect("cancelled output exists")
        .expect_err("cancel returns an error output");
    assert_eq!(error.code, ErrorCode::Cancelled);
    assert_eq!(queued.take_output(), None);

    release_tx.send(()).expect("blocker is released");
    assert!(observer.wait_for(2, Duration::from_secs(2)));
    wait_for_terminal(&blocker);
    assert_eq!(runtime.cancelled_count(), 1);
    runtime.shutdown();
}

#[test]
fn cancelled_queue_corpses_cannot_bypass_owner_ceiling_and_wedge_admission() {
    let runtime = Runtime::start(RuntimeConfig {
        workers: 1,
        max_queue: 8,
        max_jobs_per_owner: 2,
        ..RuntimeConfig::default()
    });
    let observer = Arc::new(TestObserver::default());
    let (started_tx, started_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let blocker = runtime
        .submit(
            1,
            observer_spec(observer.clone(), move |_| {
                let _ = started_tx.send(());
                release_rx.recv().map_err(|_| {
                    Error::new(ErrorCode::BackendError, "test release channel closed")
                })?;
                Ok(JobOutput::Oid(oid(30)))
            }),
        )
        .expect("blocker is admitted");
    started_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("worker starts blocker");

    let mut cancelled = Vec::new();
    for index in 0..8 {
        let job = runtime
            .submit(
                2,
                observer_spec(observer.clone(), move |_| {
                    Ok(JobOutput::Oid(oid(31 + index)))
                }),
            )
            .expect("owner can reuse its released slot");
        job.cancel();
        assert_eq!(runtime.queue_len(), 0);
        cancelled.push(job);
    }

    let innocent = runtime
        .submit(
            3,
            observer_spec(observer.clone(), |_| Ok(JobOutput::Oid(oid(40)))),
        )
        .expect("cancelled corpses do not occupy global capacity");
    assert_eq!(runtime.queue_len(), 1);

    release_tx.send(()).expect("blocker is released");
    assert!(observer.wait_for(10, Duration::from_secs(2)));
    wait_for_terminal(&blocker);
    wait_for_terminal(&innocent);
    assert!(cancelled
        .iter()
        .all(|job| job.state() == JobState::Cancelled));
    runtime.shutdown();
}

#[test]
fn cancelling_two_queued_jobs_immediately_restores_queue_capacity() {
    let runtime = Runtime::start(RuntimeConfig {
        workers: 1,
        max_queue: 2,
        max_jobs_per_owner: 8,
        ..RuntimeConfig::default()
    });
    let observer = Arc::new(TestObserver::default());
    let (started_tx, started_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let blocker = runtime
        .submit(
            1,
            observer_spec(observer.clone(), move |_| {
                let _ = started_tx.send(());
                release_rx.recv().map_err(|_| {
                    Error::new(ErrorCode::BackendError, "test release channel closed")
                })?;
                Ok(JobOutput::Oid(oid(41)))
            }),
        )
        .expect("blocker is admitted");
    started_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("worker starts blocker");

    let first = runtime
        .submit(
            2,
            observer_spec(observer.clone(), |_| Ok(JobOutput::Oid(oid(42)))),
        )
        .expect("first queued job is admitted");
    let second = runtime
        .submit(
            3,
            observer_spec(observer.clone(), |_| Ok(JobOutput::Oid(oid(43)))),
        )
        .expect("second queued job is admitted");
    assert_eq!(runtime.queue_len(), 2);
    first.cancel();
    second.cancel();
    assert_eq!(runtime.queue_len(), 0);

    let replacement = runtime
        .submit(
            4,
            observer_spec(observer.clone(), |_| Ok(JobOutput::Oid(oid(44)))),
        )
        .expect("both cancelled queue slots are immediately reusable");
    release_tx.send(()).expect("blocker is released");
    assert!(observer.wait_for(4, Duration::from_secs(2)));
    wait_for_terminal(&blocker);
    wait_for_terminal(&replacement);
    runtime.shutdown();
}

#[test]
fn queue_full_reports_reason_and_retry_delay() {
    let runtime = Runtime::start(RuntimeConfig {
        workers: 1,
        max_queue: 1,
        max_jobs_per_owner: 10,
        retry_after_ms: 777,
        ..RuntimeConfig::default()
    });
    let observer = Arc::new(TestObserver::default());
    let (started_tx, started_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let first = runtime
        .submit(
            1,
            observer_spec(observer.clone(), move |_| {
                let _ = started_tx.send(());
                release_rx.recv().map_err(|_| {
                    Error::new(ErrorCode::BackendError, "test release channel closed")
                })?;
                Ok(JobOutput::Oid(oid(4)))
            }),
        )
        .expect("first job is admitted");
    started_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("first job starts");
    let second = runtime
        .submit(
            2,
            observer_spec(observer.clone(), |_| Ok(JobOutput::Oid(oid(5)))),
        )
        .expect("one job fits in the queue");
    let rejected = runtime.submit(
        3,
        observer_spec(observer.clone(), |_| Ok(JobOutput::Oid(oid(6)))),
    );
    assert!(matches!(
        rejected,
        Err(SubmitError::Busy {
            reason: BusyReason::QueueFull,
            retry_after_ms: 777
        })
    ));

    release_tx.send(()).expect("first job is released");
    assert!(observer.wait_for(2, Duration::from_secs(2)));
    wait_for_terminal(&first);
    wait_for_terminal(&second);
    assert_eq!(runtime.rejected_count(), 1);
    runtime.shutdown();
}

#[test]
fn one_worker_dequeues_fifo_on_named_threads() {
    let runtime = Runtime::start(RuntimeConfig {
        workers: 1,
        max_queue: 3,
        max_jobs_per_owner: 4,
        ..RuntimeConfig::default()
    });
    let observer = Arc::new(TestObserver::default());
    let (started_tx, started_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let blocker = runtime
        .submit(
            1,
            observer_spec(observer.clone(), move |_| {
                let _ = started_tx.send(());
                release_rx.recv().map_err(|_| {
                    Error::new(ErrorCode::BackendError, "test release channel closed")
                })?;
                Ok(JobOutput::Oid(oid(15)))
            }),
        )
        .expect("blocker is admitted");
    started_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("blocker starts");

    let (order_tx, order_rx) = mpsc::channel();
    let mut queued = Vec::new();
    for sequence in 0..3 {
        let order_tx = order_tx.clone();
        queued.push(
            runtime
                .submit(
                    1,
                    observer_spec(observer.clone(), move |_| {
                        let thread_name = thread::current().name().unwrap_or_default().to_owned();
                        let _ = order_tx.send((sequence, thread_name));
                        Ok(JobOutput::Oid(oid(16 + sequence)))
                    }),
                )
                .expect("FIFO job is admitted"),
        );
    }
    drop(order_tx);
    release_tx.send(()).expect("blocker is released");
    assert!(observer.wait_for(4, Duration::from_secs(2)));

    let observed: Vec<_> = order_rx.iter().collect();
    assert_eq!(
        observed
            .iter()
            .map(|(sequence, _)| *sequence)
            .collect::<Vec<_>>(),
        vec![0, 1, 2]
    );
    assert!(observed.iter().all(|(_, name)| name == "gitility-worker-0"));
    assert!(blocker.is_terminal());
    assert!(queued.iter().all(|job| job.is_terminal()));
    runtime.shutdown();
}

#[test]
fn owner_ceiling_is_independent_of_queue_capacity() {
    let runtime = Runtime::start(RuntimeConfig {
        workers: 1,
        max_queue: 2,
        max_jobs_per_owner: 1,
        retry_after_ms: 321,
        ..RuntimeConfig::default()
    });
    let observer = Arc::new(TestObserver::default());
    let (started_tx, started_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let first = runtime
        .submit(
            10,
            observer_spec(observer.clone(), move |_| {
                let _ = started_tx.send(());
                release_rx.recv().map_err(|_| {
                    Error::new(ErrorCode::BackendError, "test release channel closed")
                })?;
                Ok(JobOutput::Oid(oid(7)))
            }),
        )
        .expect("owner's first job is admitted");
    started_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("first job starts");

    let rejected = runtime.submit(
        10,
        observer_spec(observer.clone(), |_| Ok(JobOutput::Oid(oid(8)))),
    );
    assert!(matches!(
        rejected,
        Err(SubmitError::Busy {
            reason: BusyReason::OwnerCeiling,
            retry_after_ms: 321
        })
    ));
    let other_owner = runtime
        .submit(
            11,
            observer_spec(observer.clone(), |_| Ok(JobOutput::Oid(oid(9)))),
        )
        .expect("another owner can use the queue");

    release_tx.send(()).expect("first job is released");
    assert!(observer.wait_for(2, Duration::from_secs(2)));
    wait_for_terminal(&first);
    wait_for_terminal(&other_owner);
    runtime.shutdown();
}

#[test]
fn expired_queued_job_fails_without_invoking_task() {
    let runtime = Runtime::start(RuntimeConfig {
        workers: 1,
        max_queue: 2,
        max_jobs_per_owner: 2,
        ..RuntimeConfig::default()
    });
    let observer = Arc::new(TestObserver::default());
    let (started_tx, started_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let blocker = runtime
        .submit(
            1,
            observer_spec(observer.clone(), move |_| {
                let _ = started_tx.send(());
                release_rx.recv().map_err(|_| {
                    Error::new(ErrorCode::BackendError, "test release channel closed")
                })?;
                Ok(JobOutput::Oid(oid(10)))
            }),
        )
        .expect("blocker is admitted");
    started_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("blocker starts");

    let invoked = StdArc::new(AtomicBool::new(false));
    let invoked_by_task = StdArc::clone(&invoked);
    let mut spec = observer_spec(observer.clone(), move |_| {
        invoked_by_task.store(true, StdOrdering::Release);
        Ok(JobOutput::Oid(oid(11)))
    });
    spec.timeout_ms = Some(1);
    let expired = runtime.submit(1, spec).expect("expiring job is admitted");
    thread::sleep(Duration::from_millis(5));
    release_tx.send(()).expect("blocker is released");

    assert!(observer.wait_for(2, Duration::from_secs(2)));
    wait_for_terminal(&blocker);
    assert_eq!(expired.state(), JobState::Failed);
    assert!(!invoked.load(StdOrdering::Acquire));
    let error = expired
        .take_output()
        .expect("timeout output exists")
        .expect_err("deadline failure is an error");
    assert_eq!(error.code, ErrorCode::Timeout);
    runtime.shutdown();
}

#[test]
fn panicking_task_fails_and_worker_survives() {
    let runtime = Runtime::start(RuntimeConfig {
        workers: 1,
        ..RuntimeConfig::default()
    });
    let observer = Arc::new(TestObserver::default());
    let panicked = runtime
        .submit(
            1,
            observer_spec(observer.clone(), |_| panic!("injected task panic")),
        )
        .expect("panicking job is admitted");
    assert!(observer.wait_for(1, Duration::from_secs(2)));
    let survivor = runtime
        .submit(
            1,
            observer_spec(observer.clone(), |_| Ok(JobOutput::Oid(oid(12)))),
        )
        .expect("second job is admitted");
    assert!(observer.wait_for(2, Duration::from_secs(2)));

    assert_eq!(panicked.state(), JobState::Failed);
    let error = panicked
        .take_output()
        .expect("panic output exists")
        .expect_err("panic maps to an error");
    assert_eq!(error.code, ErrorCode::BackendError);
    assert!(!error.retryable);
    assert_eq!(
        error.message,
        "internal engine panic — this is a Gitility bug"
    );
    assert_eq!(survivor.state(), JobState::Completed);
    runtime.shutdown();
}

#[test]
fn shutdown_cancels_drains_and_joins_then_rejects() {
    let runtime = Runtime::start(RuntimeConfig {
        workers: 2,
        max_queue: 32,
        max_jobs_per_owner: 32,
        ..RuntimeConfig::default()
    });
    let observer = Arc::new(TestObserver::default());
    let jobs: Vec<_> = (0..20)
        .map(|index| {
            runtime
                .submit(
                    1,
                    observer_spec(observer.clone(), move |budget| loop {
                        budget.check()?;
                        thread::yield_now();
                        if index == usize::MAX {
                            return Ok(JobOutput::Oid(oid(13)));
                        }
                    }),
                )
                .expect("shutdown test job is admitted")
        })
        .collect();

    runtime.shutdown();
    assert!(jobs.iter().all(|job| job.is_terminal()));
    assert!(jobs.iter().all(|job| job.state() == JobState::Cancelled));
    assert_eq!(runtime.queue_len(), 0);
    assert_eq!(runtime.running_count(), 0);
    assert!(sync::lock(&runtime.workers).is_empty());
    assert_eq!(runtime.counters().detached_workers, 0);
    assert_eq!(runtime.last_detach_reason(), None);
    runtime.shutdown();

    let rejected = runtime.submit(2, observer_spec(observer, |_| Ok(JobOutput::Oid(oid(14)))));
    assert!(matches!(rejected, Err(SubmitError::ShuttingDown)));
    assert_eq!(runtime.rejected_count(), 1);
}

#[test]
fn concurrent_external_and_reentrant_shutdown_cannot_deadlock() {
    let runtime = Runtime::start(RuntimeConfig {
        workers: 1,
        max_queue: 8,
        max_jobs_per_owner: 8,
        ..RuntimeConfig::default()
    });
    let observer = Arc::new(TestObserver::default());
    let (started_tx, started_rx) = mpsc::channel();
    let task_runtime = Arc::clone(&runtime);
    let running = runtime
        .submit(
            1,
            observer_spec(observer.clone(), move |_| {
                let _ = started_tx.send(());
                thread::sleep(Duration::from_millis(300));
                task_runtime.shutdown();
                Ok(JobOutput::Oid(oid(45)))
            }),
        )
        .expect("reentrant job is admitted");
    started_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("reentrant job starts");

    let queued: Vec<_> = (0..4)
        .map(|index| {
            runtime
                .submit(
                    2,
                    observer_spec(observer.clone(), move |_| {
                        Ok(JobOutput::Oid(oid(46 + index)))
                    }),
                )
                .expect("queued shutdown job is admitted")
        })
        .collect();
    let external_runtime = Arc::clone(&runtime);
    let (done_tx, done_rx) = mpsc::channel();
    let external = thread::spawn(move || {
        external_runtime.shutdown();
        let _ = done_tx.send(());
    });

    done_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("external shutdown completes without joining a blocked worker");
    external.join().expect("external shutdown thread survives");
    assert!(running.is_terminal());
    assert!(queued.iter().all(|job| job.is_terminal()));
    assert_eq!(runtime.queue_len(), 0);
    assert_eq!(runtime.running_count(), 0);
    assert!(sync::lock(&runtime.workers).is_empty());
}

#[test]
fn reentrant_shutdown_request_is_completed_by_later_external_shutdown() {
    let runtime = Runtime::start(RuntimeConfig {
        workers: 1,
        ..RuntimeConfig::default()
    });
    let observer = Arc::new(TestObserver::default());
    let task_runtime = Arc::clone(&runtime);
    let (requested_tx, requested_rx) = mpsc::channel();
    let job = runtime
        .submit(
            1,
            observer_spec(observer, move |_| {
                task_runtime.shutdown();
                let _ = requested_tx.send(());
                Ok(JobOutput::Oid(oid(50)))
            }),
        )
        .expect("reentrant job is admitted");

    requested_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("worker shutdown request returns immediately");
    runtime.shutdown();
    assert!(job.is_terminal());
    assert_eq!(job.state(), JobState::Cancelled);
    assert_eq!(runtime.running_count(), 0);
    assert!(sync::lock(&runtime.workers).is_empty());
}

#[test]
fn shutdown_detaches_an_uncooperative_worker_with_its_budget_slot_held() {
    const JOIN_TIMEOUT_MS: u64 = 50;
    const SHUTDOWN_MARGIN_MS: u64 = 1_000;

    let budget = Box::leak(Box::new(thread_budget::ThreadBudget::new(1)));
    let runtime = Runtime::start_with_budget(
        RuntimeConfig {
            workers: 1,
            shutdown_join_timeout_ms: JOIN_TIMEOUT_MS,
            ..RuntimeConfig::default()
        },
        budget,
    )
    .expect("one worker fits");
    let observer = Arc::new(TestObserver::default());
    let (started_tx, started_rx) = mpsc::channel();
    let _job = runtime
        .submit(
            1,
            observer_spec(observer, move |_| -> Result<JobOutput, Error> {
                let _ = started_tx.send(());
                loop {
                    // Deliberately no Budget::check: this models a dependency
                    // wedged outside Gitility's cooperative cancellation path.
                    thread::sleep(Duration::from_secs(60));
                }
            }),
        )
        .expect("uncooperative job is admitted");
    started_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("uncooperative job starts");

    let started = Instant::now();
    runtime.shutdown();
    let elapsed = started.elapsed();

    assert!(
        elapsed <= Duration::from_millis(JOIN_TIMEOUT_MS + SHUTDOWN_MARGIN_MS),
        "shutdown took {elapsed:?}"
    );
    assert_eq!(runtime.counters().detached_workers, 1);
    assert_eq!(
        runtime.last_detach_reason().as_deref(),
        Some("worker gitility-worker-0 did not exit within shutdown_join_timeout_ms=50; detached")
    );
    assert_eq!(
        budget.used(),
        1,
        "a detached live worker must retain its honest budget cost"
    );
}

#[test]
fn debug_views_expose_identity_configuration_and_counters_without_output() {
    let runtime = Runtime::start(RuntimeConfig {
        workers: 1,
        ..RuntimeConfig::default()
    });
    let observer = Arc::new(TestObserver::default());
    let job = runtime
        .submit(
            77,
            observer_spec(observer.clone(), |_| Ok(JobOutput::Oid(oid(51)))),
        )
        .expect("debug job is admitted");
    assert!(observer.wait_for(1, Duration::from_secs(2)));

    let job_debug = format!("{job:?}");
    assert!(job_debug.contains("id: 1"));
    assert!(job_debug.contains("owner: 77"));
    assert!(job_debug.contains("state: Completed"));
    assert!(!job_debug.contains("Oid"));
    let runtime_debug = format!("{runtime:?}");
    assert!(runtime_debug.contains("config: RuntimeConfig"));
    assert!(runtime_debug.contains("counters: RuntimeCounters"));
    runtime.shutdown();
}

struct InjectingDb {
    inner: StdArc<LocalOdb>,
    trip_at: usize,
    calls: AtomicUsize,
}

impl InjectingDb {
    fn trip(&self, budget: &Budget) {
        if self.calls.fetch_add(1, StdOrdering::SeqCst) == self.trip_at {
            budget.cancel_flag().store(true, StdOrdering::Release);
        }
    }
}

impl ObjectDb for InjectingDb {
    fn hash_kind(&self) -> HashKind {
        self.inner.hash_kind()
    }

    fn try_header(&self, object: &Oid, budget: &Budget) -> Result<Option<ObjectHeader>, Error> {
        self.trip(budget);
        self.inner.try_header(object, budget)
    }

    fn try_find(
        &self,
        object: &Oid,
        out: &mut Vec<u8>,
        budget: &Budget,
    ) -> Result<Option<ObjectKind>, Error> {
        self.trip(budget);
        self.inner.try_find(object, out, budget)
    }
}

#[test]
fn cancellation_injection_sweep_keeps_real_query_results_atomic() {
    const LAST_INJECTION_POINT: usize = 16;

    let (store, _) =
        LocalOdb::open(fixture_repo("sha1-basic.git"), Default::default()).expect("fixture opens");
    let store = StdArc::new(store);
    let snapshot = Snapshot::open(
        store.as_ref(),
        fixture_oid("sha1_basic_head"),
        &Budget::unlimited(),
    )
    .expect("fixture snapshot opens");
    let runtime = Runtime::start(RuntimeConfig {
        workers: 4,
        max_queue: 64,
        max_jobs_per_owner: 64,
        ..RuntimeConfig::default()
    });
    let observer = Arc::new(TestObserver::default());
    let mut jobs = Vec::new();

    for trip_at in 0..=LAST_INJECTION_POINT {
        let tree_store = InjectingDb {
            inner: StdArc::clone(&store),
            trip_at,
            calls: AtomicUsize::new(0),
        };
        jobs.push(
            runtime
                .submit(
                    1,
                    observer_spec(observer.clone(), move |budget| {
                        list_tree(
                            &tree_store,
                            &snapshot,
                            &TreeOptions {
                                recursive: true,
                                limit: 100,
                                ..TreeOptions::default()
                            },
                            budget,
                        )
                        .map(JobOutput::Tree)
                    }),
                )
                .expect("tree sweep job is admitted"),
        );

        let file_store = InjectingDb {
            inner: StdArc::clone(&store),
            trip_at,
            calls: AtomicUsize::new(0),
        };
        jobs.push(
            runtime
                .submit(
                    1,
                    observer_spec(observer.clone(), move |budget| {
                        read_file(
                            &file_store,
                            &snapshot,
                            b"README.md",
                            &FileOptions::default(),
                            budget,
                        )
                        .map(JobOutput::File)
                    }),
                )
                .expect("file sweep job is admitted"),
        );
    }

    assert!(observer.wait_for(jobs.len() as u64, Duration::from_secs(10)));
    for job in &jobs {
        assert!(job.is_terminal());
        match job.take_output() {
            Some(Ok(JobOutput::Tree(_) | JobOutput::File(_))) => {
                assert_eq!(job.state(), JobState::Completed);
            }
            Some(Err(error)) if error.code == ErrorCode::Cancelled => {
                assert_eq!(job.state(), JobState::Cancelled);
            }
            unexpected => panic!("unexpected atomic sweep result: {unexpected:?}"),
        }
        assert_eq!(job.take_output(), None);
    }
    runtime.shutdown();
}

#[test]
fn deterministic_four_worker_mixed_stress_reconciles_counters() {
    const JOBS_PER_WORKER: usize = 200;
    const JOBS: usize = 4 * JOBS_PER_WORKER;

    let runtime = Runtime::start(RuntimeConfig {
        workers: 4,
        max_queue: JOBS,
        max_jobs_per_owner: JOBS,
        ..RuntimeConfig::default()
    });
    let observer = Arc::new(TestObserver::default());
    let mut jobs = Vec::with_capacity(JOBS);

    // Occupy all four workers before cancellation so this test always covers
    // running (not merely queued) cancellation.
    let started = StdArc::new(Barrier::new(5));
    for _ in 0..4 {
        let task_started = StdArc::clone(&started);
        jobs.push(
            runtime
                .submit(
                    42,
                    observer_spec(observer.clone(), move |budget| {
                        task_started.wait();
                        loop {
                            budget.check()?;
                            thread::yield_now();
                        }
                    }),
                )
                .expect("mid-flight cancellation job is admitted"),
        );
    }
    started.wait();
    for job in &jobs {
        job.cancel();
    }

    for index in 4..JOBS {
        let mut spec = match index % 4 {
            0 => observer_spec(observer.clone(), |budget| loop {
                budget.check()?;
                thread::yield_now();
            }),
            1 => observer_spec(observer.clone(), |budget| loop {
                budget.check()?;
                thread::yield_now();
            }),
            2 => observer_spec(observer.clone(), move |_| {
                Ok(JobOutput::Oid(oid((index % 251) as u8)))
            }),
            _ => observer_spec(observer.clone(), |_| {
                Err(Error::new(ErrorCode::BackendError, "injected failure"))
            }),
        };
        if index % 4 == 1 {
            spec.timeout_ms = Some(1);
        }
        let job = runtime.submit(42, spec).expect("stress job is admitted");
        if index % 4 == 0 {
            job.cancel();
        }
        jobs.push(job);
    }

    assert!(observer.wait_for(JOBS as u64, Duration::from_secs(15)));
    runtime.shutdown();
    assert!(jobs.iter().all(|job| job.is_terminal()));
    assert!(jobs.iter().all(|job| job.take_output().is_some()));

    let counters = runtime.counters();
    assert_eq!(counters.submitted, JOBS as u64);
    assert_eq!(counters.rejected, 0);
    assert_eq!(
        counters.submitted,
        counters.completed + counters.failed + counters.cancelled
    );
    assert_eq!(runtime.running_count(), 0);
    assert_eq!(runtime.queue_len(), 0);
}

mod thread_budget_tests {
    use super::super::thread_budget::{BudgetExhausted, ThreadBudget};
    use super::super::{Runtime, RuntimeConfig};

    fn leaked_budget(limit: usize) -> &'static ThreadBudget {
        Box::leak(Box::new(ThreadBudget::new(limit)))
    }

    fn config(workers: usize) -> RuntimeConfig {
        RuntimeConfig {
            workers,
            max_queue: 4,
            max_jobs_per_owner: 4,
            retry_after_ms: 1,
            shutdown_join_timeout_ms: 5_000,
        }
    }

    #[test]
    fn reservations_release_on_drop() {
        let budget = leaked_budget(8);
        let first = budget.try_reserve(3).expect("3 of 8 fits");
        assert_eq!(budget.used(), 3);
        let second = budget.try_reserve(5).expect("8 of 8 fits");
        assert_eq!(budget.used(), 8);
        drop(first);
        assert_eq!(budget.used(), 5);
        drop(second);
        assert_eq!(budget.used(), 0);
    }

    #[test]
    fn exhaustion_reports_observed_state() {
        let budget = leaked_budget(4);
        let _held = budget.try_reserve(3).expect("3 of 4 fits");
        let error = budget.try_reserve(2).expect_err("2 more exceeds 4");
        assert_eq!(
            error,
            BudgetExhausted {
                requested: 2,
                used: 3,
                limit: 4
            }
        );
    }

    #[test]
    fn split_reservations_release_independently() {
        let budget = leaked_budget(4);
        let mut reservation = budget.try_reserve(2).expect("2 of 4 fits");
        let split = reservation.split_one();
        assert_eq!(reservation.count(), 1);
        assert_eq!(split.count(), 1);
        drop(reservation);
        assert_eq!(budget.used(), 1);
        drop(split);
        assert_eq!(budget.used(), 0);
    }

    #[test]
    fn start_fails_before_spawning_when_budget_is_exhausted() {
        let budget = leaked_budget(4);
        let _held = budget.try_reserve(2).expect("2 of 4 fits");
        let error = Runtime::start_with_budget(config(3), budget).expect_err("3 more exceeds 4");
        assert_eq!(error.requested, 3);
        assert_eq!(error.used, 2);
        assert_eq!(error.limit, 4);
        assert_eq!(budget.used(), 2, "a refused start reserves nothing");
    }

    #[test]
    fn shutdown_returns_every_worker_slot() {
        let budget = leaked_budget(4);
        let runtime = Runtime::start_with_budget(config(3), budget).expect("3 of 4 fits");
        assert_eq!(budget.used(), 3);
        runtime.shutdown();
        // These cooperative workers exit within the bounded join phase, and
        // each reservation drops when its loop returns.
        assert_eq!(budget.used(), 0);
        assert_eq!(runtime.counters().detached_workers, 0);
    }

    #[test]
    fn zero_workers_reserves_the_normalized_single_worker() {
        let budget = leaked_budget(4);
        let runtime = Runtime::start_with_budget(config(0), budget).expect("1 of 4 fits");
        assert_eq!(budget.used(), 1);
        runtime.shutdown();
        assert_eq!(budget.used(), 0);
    }

    #[test]
    fn global_budget_has_a_positive_limit() {
        let budget = super::super::thread_budget::global();
        assert!(budget.limit() > 0);
        assert!(budget.used() <= budget.limit());
    }
}
