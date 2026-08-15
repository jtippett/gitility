use super::*;
use crate::object::HashKind;
use loom::sync::atomic::AtomicU64;
use std::sync::atomic::{AtomicUsize as StdAtomicUsize, Ordering as StdOrdering};
use std::sync::Arc as StdArc;

struct CountingObserver {
    completion: Arc<(Mutex<u64>, Condvar)>,
    calls: Arc<AtomicU64>,
}

impl JobObserver for CountingObserver {
    fn completed(&self, _job: &Job) {
        let mut completion = sync::lock(&self.completion.0);
        *completion += 1;
        self.calls.fetch_add(1, Ordering::Release);
        self.completion.1.notify_all();
    }
}

struct Observation {
    observer: Arc<dyn JobObserver>,
    completion: Arc<(Mutex<u64>, Condvar)>,
    calls: Arc<AtomicU64>,
}

fn observer() -> Observation {
    let completion = Arc::new((Mutex::new(0), Condvar::new()));
    let calls = Arc::new(AtomicU64::new(0));
    let concrete = CountingObserver {
        completion: Arc::clone(&completion),
        calls: Arc::clone(&calls),
    };
    let erased: std::sync::Arc<dyn JobObserver> = std::sync::Arc::new(concrete);
    Observation {
        observer: Arc::from_std(erased),
        completion,
        calls,
    }
}

fn wait_for_completion(completion: &Arc<(Mutex<u64>, Condvar)>, wanted: u64) {
    let mut count = sync::lock(&completion.0);
    while *count < wanted {
        count = sync::wait(&completion.1, count);
    }
}

fn spec(observer: Arc<dyn JobObserver>) -> JobSpec {
    task_spec(observer, |budget| {
        budget.check()?;
        Ok(test_output())
    })
}

fn task_spec(
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

fn test_output() -> JobOutput {
    JobOutput::Oid(
        Oid::new(HashKind::Sha1, &[1; 20])
            .unwrap_or_else(|_| unreachable!("fixed SHA-1 test OID is valid")),
    )
}

fn model(name: &'static str, check: impl Fn() + Sync + Send + 'static) {
    let executions = StdArc::new(StdAtomicUsize::new(0));
    let counted_executions = StdArc::clone(&executions);
    let mut builder = loom::model::Builder::new();
    builder.preemption_bound = Some(2);
    builder.max_branches = 1_000;
    builder.check(move || {
        counted_executions.fetch_add(1, StdOrdering::Relaxed);
        check();
    });
    eprintln!(
        "{name}: {} modeled executions",
        executions.load(StdOrdering::Relaxed)
    );
}

#[test]
fn loom_queue_has_no_lost_wakeup() {
    model("loom_queue_has_no_lost_wakeup", || {
        let runtime = Runtime::start(RuntimeConfig {
            workers: 1,
            max_queue: 1,
            max_jobs_per_owner: 1,
            retry_after_ms: 1,
            shutdown_join_timeout_ms: 5_000,
        });
        let observation = observer();
        let job = runtime
            .submit(1, spec(observation.observer))
            .expect("one job is admitted");
        wait_for_completion(&observation.completion, 1);
        assert!(job.is_terminal());
        assert_eq!(observation.calls.load(Ordering::Acquire), 1);
        runtime.shutdown();
    });
}

#[test]
fn loom_cancel_dequeue_race_has_one_terminal_transition() {
    model(
        "loom_cancel_dequeue_race_has_one_terminal_transition",
        || {
            let runtime = Runtime::start(RuntimeConfig {
                workers: 1,
                max_queue: 1,
                max_jobs_per_owner: 1,
                retry_after_ms: 1,
                shutdown_join_timeout_ms: 5_000,
            });
            let observation = observer();
            let invocations = Arc::new(AtomicU64::new(0));
            let task_invocations = Arc::clone(&invocations);
            let job = runtime
                .submit(
                    1,
                    task_spec(observation.observer, move |budget| {
                        task_invocations.fetch_add(1, Ordering::AcqRel);
                        budget.check()?;
                        Ok(test_output())
                    }),
                )
                .expect("one job is admitted");
            let cancelling_job = Arc::clone(&job);
            let canceller = loom::thread::spawn(move || cancelling_job.cancel());
            canceller.join().expect("canceller does not panic");

            assert_eq!(runtime.queue_len(), 0);
            runtime.shutdown();
            assert!(job.is_terminal());
            assert!(invocations.load(Ordering::Acquire) <= 1);
            let counters = runtime.counters();
            assert_eq!(counters.submitted, 1);
            assert_eq!(counters.completed + counters.failed + counters.cancelled, 1);
            assert_eq!(observation.calls.load(Ordering::Acquire), 1);
            assert!(job.take_output().is_some());
            assert_eq!(job.take_output(), None);
            assert_eq!(runtime.queue_len(), 0);
        },
    );
}

#[test]
fn loom_terminal_state_publishes_output_first() {
    model("loom_terminal_state_publishes_output_first", || {
        let runtime = Runtime::start(RuntimeConfig {
            workers: 1,
            max_queue: 1,
            max_jobs_per_owner: 1,
            retry_after_ms: 1,
            shutdown_join_timeout_ms: 5_000,
        });
        let observation = observer();
        let job = runtime
            .submit(1, spec(observation.observer))
            .expect("one job is admitted");
        let inspecting_job = Arc::clone(&job);
        let inspector = loom::thread::spawn(move || {
            if inspecting_job.is_terminal() {
                assert!(inspecting_job.take_output().is_some());
            }
        });
        inspector.join().expect("inspector does not panic");
        runtime.shutdown();
        assert!(job.is_terminal());
        assert_eq!(observation.calls.load(Ordering::Acquire), 1);
    });
}

#[test]
fn loom_shutdown_submit_race_never_strands_a_job() {
    model("loom_shutdown_submit_race_never_strands_a_job", || {
        let runtime = Runtime::start(RuntimeConfig {
            workers: 1,
            max_queue: 1,
            max_jobs_per_owner: 1,
            retry_after_ms: 1,
            shutdown_join_timeout_ms: 5_000,
        });
        let submitting_runtime = Arc::clone(&runtime);
        let submitter = loom::thread::spawn(move || {
            let observation = observer();
            submitting_runtime.submit(1, spec(observation.observer))
        });
        runtime.shutdown();
        let submitted = submitter.join().expect("submitter does not panic");

        match submitted {
            Ok(job) => assert!(job.is_terminal()),
            Err(SubmitError::ShuttingDown) => {}
            Err(other) => panic!("unexpected admission outcome: {other:?}"),
        }
        let counters = runtime.counters();
        assert_eq!(counters.submitted + counters.rejected, 1);
        assert_eq!(
            counters.submitted,
            counters.completed + counters.failed + counters.cancelled
        );
    });
}

#[test]
fn loom_two_workers_two_jobs_have_no_lost_wakeup() {
    model("loom_two_workers_two_jobs_have_no_lost_wakeup", || {
        let runtime = Runtime::start(RuntimeConfig {
            workers: 2,
            max_queue: 2,
            max_jobs_per_owner: 2,
            retry_after_ms: 1,
            shutdown_join_timeout_ms: 5_000,
        });
        let observation = observer();
        let first = runtime
            .submit(1, spec(Arc::clone(&observation.observer)))
            .expect("first job is admitted");
        let second = runtime
            .submit(1, spec(observation.observer))
            .expect("second job is admitted");
        wait_for_completion(&observation.completion, 2);
        assert!(first.is_terminal());
        assert!(second.is_terminal());
        assert_eq!(observation.calls.load(Ordering::Acquire), 2);
        runtime.shutdown();
    });
}

#[test]
fn loom_shutdown_races_queued_cancel() {
    model("loom_shutdown_races_queued_cancel", || {
        let runtime = Runtime::start(RuntimeConfig {
            workers: 1,
            max_queue: 2,
            max_jobs_per_owner: 2,
            retry_after_ms: 1,
            shutdown_join_timeout_ms: 5_000,
        });
        let observation = observer();
        let started = Arc::new(AtomicBool::new(false));
        let task_started = Arc::clone(&started);
        let running = runtime
            .submit(
                1,
                task_spec(Arc::clone(&observation.observer), move |budget| {
                    task_started.store(true, Ordering::Release);
                    loop {
                        budget.check()?;
                        loom::thread::yield_now();
                    }
                }),
            )
            .expect("running job is admitted");
        while !started.load(Ordering::Acquire) {
            loom::thread::yield_now();
        }
        let queued = runtime
            .submit(1, spec(observation.observer))
            .expect("queued job is admitted");
        let cancelling_job = Arc::clone(&queued);
        let canceller = loom::thread::spawn(move || cancelling_job.cancel());
        runtime.shutdown();
        canceller.join().expect("canceller does not panic");

        assert!(running.is_terminal());
        assert!(queued.is_terminal());
        assert_eq!(runtime.queue_len(), 0);
        assert_eq!(observation.calls.load(Ordering::Acquire), 2);
        let counters = runtime.counters();
        assert_eq!(counters.submitted, 2);
        assert_eq!(counters.completed + counters.failed + counters.cancelled, 2);
    });
}

#[test]
fn loom_double_cancel_from_two_threads_fires_once() {
    model("loom_double_cancel_from_two_threads_fires_once", || {
        let runtime = Runtime::start(RuntimeConfig {
            workers: 1,
            max_queue: 1,
            max_jobs_per_owner: 1,
            retry_after_ms: 1,
            shutdown_join_timeout_ms: 5_000,
        });
        let observation = observer();
        let job = runtime
            .submit(1, spec(observation.observer))
            .expect("one job is admitted");
        let first_job = Arc::clone(&job);
        let second_job = Arc::clone(&job);
        let first = loom::thread::spawn(move || first_job.cancel());
        let second = loom::thread::spawn(move || second_job.cancel());
        first.join().expect("first canceller does not panic");
        second.join().expect("second canceller does not panic");
        runtime.shutdown();

        assert!(job.is_terminal());
        assert_eq!(observation.calls.load(Ordering::Acquire), 1);
        let counters = runtime.counters();
        assert_eq!(counters.submitted, 1);
        assert_eq!(counters.completed + counters.failed + counters.cancelled, 1);
        assert!(job.take_output().is_some());
        assert_eq!(job.take_output(), None);
        assert_eq!(runtime.queue_len(), 0);
    });
}

#[test]
fn loom_shutdown_races_reentrant_shutdown_without_deadlock() {
    model(
        "loom_shutdown_races_reentrant_shutdown_without_deadlock",
        || {
            let runtime = Runtime::start(RuntimeConfig {
                workers: 1,
                max_queue: 1,
                max_jobs_per_owner: 1,
                retry_after_ms: 1,
                shutdown_join_timeout_ms: 5_000,
            });
            let observation = observer();
            let started = Arc::new(AtomicBool::new(false));
            let task_started = Arc::clone(&started);
            let task_runtime = Arc::clone(&runtime);
            let job = runtime
                .submit(
                    1,
                    task_spec(observation.observer, move |_| {
                        task_started.store(true, Ordering::Release);
                        loom::thread::yield_now();
                        task_runtime.shutdown();
                        Ok(test_output())
                    }),
                )
                .expect("reentrant job is admitted");
            while !started.load(Ordering::Acquire) {
                loom::thread::yield_now();
            }
            runtime.shutdown();

            assert!(job.is_terminal());
            assert_eq!(observation.calls.load(Ordering::Acquire), 1);
            assert!(sync::lock(&runtime.workers).is_empty());
        },
    );
}
