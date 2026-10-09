//! A synchronous lifetime gate for callbacks whose foreign context is borrowed.

use std::sync::{Arc, Mutex};

/// Own this scope until the ABI call returns, before its caller frees the context.
pub(crate) struct CallbackScope {
    gate: Arc<Mutex<bool>>,
}

/// Worker clones can outlive the scope; they must not touch foreign state then.
#[derive(Clone)]
pub(crate) struct CallbackDispatcher {
    gate: Arc<Mutex<bool>>,
}

impl CallbackScope {
    pub(crate) fn new() -> Self {
        Self {
            gate: Arc::new(Mutex::new(true)),
        }
    }

    pub(crate) fn dispatcher(&self) -> CallbackDispatcher {
        CallbackDispatcher {
            gate: Arc::clone(&self.gate),
        }
    }
}

impl CallbackDispatcher {
    /// Returns whether the callback ran. Never reenter this same gate from a callback.
    pub(crate) fn dispatch(&self, callback: impl FnOnce()) -> bool {
        let Ok(active) = self.gate.lock() else {
            // A panicking callback poisons the gate. Do not reuse its context.
            return false;
        };
        if !*active {
            return false;
        }
        // Keep the lock through the entire foreign call. Scope shutdown takes
        // this same lock and therefore cannot finish while a callback is active.
        callback();
        drop(active);
        true
    }
}

impl Drop for CallbackScope {
    fn drop(&mut self) {
        // Poison still releases the mutex when unwinding the callback. Recover
        // only to shut down; dispatch always rejects a poisoned gate.
        match self.gate.lock() {
            Ok(mut active) => *active = false,
            Err(poisoned) => *poisoned.into_inner() = false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        panic::{catch_unwind, AssertUnwindSafe},
        sync::{
            atomic::{AtomicUsize, Ordering},
            mpsc,
        },
        thread,
        time::Duration,
    };

    const DEADLINE: Duration = Duration::from_secs(2);

    #[test]
    fn late_worker_clones_ignore_callbacks_after_scope_shutdown() {
        let scope = CallbackScope::new();
        let dispatcher = scope.dispatcher();
        let late_worker = dispatcher.clone();
        let calls = AtomicUsize::new(0);
        assert!(dispatcher.dispatch(|| {
            calls.fetch_add(1, Ordering::SeqCst);
        }));
        drop(scope);
        assert!(!late_worker.dispatch(|| {
            calls.fetch_add(1, Ordering::SeqCst);
        }));
        assert!(!dispatcher.dispatch(|| {
            calls.fetch_add(1, Ordering::SeqCst);
        }));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn shutdown_waits_for_the_active_callback_and_blocks_late_workers() {
        let scope = CallbackScope::new();
        let dispatcher = scope.dispatcher();
        let late_worker = dispatcher.clone();
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let callback = thread::spawn(move || {
            dispatcher.dispatch(|| {
                entered_tx.send(()).unwrap();
                release_rx
                    .recv_timeout(DEADLINE)
                    .expect("test must release the active callback");
            })
        });
        entered_rx
            .recv_timeout(DEADLINE)
            .expect("callback must enter");
        let (closing_tx, closing_rx) = mpsc::channel();
        let (closed_tx, closed_rx) = mpsc::channel();
        let closing = thread::spawn(move || {
            closing_tx.send(()).unwrap();
            drop(scope);
            closed_tx.send(()).unwrap();
        });
        closing_rx
            .recv_timeout(DEADLINE)
            .expect("shutdown thread must start");
        let premature_shutdown = closed_rx.recv_timeout(Duration::from_millis(50));
        // Release both threads before asserting, including on the red path.
        release_tx.send(()).unwrap();
        if premature_shutdown.is_err() {
            closed_rx
                .recv_timeout(DEADLINE)
                .expect("shutdown must finish after the callback");
        }
        assert!(callback.join().unwrap());
        closing.join().unwrap();
        assert!(
            matches!(premature_shutdown, Err(mpsc::RecvTimeoutError::Timeout)),
            "scope returned while the callback was still using its borrowed context"
        );
        assert!(!late_worker.dispatch(|| panic!("closed scope must ignore late callbacks")));
    }

    #[test]
    fn a_poisoned_callback_gate_fails_closed_and_shutdown_does_not_panic() {
        let scope = CallbackScope::new();
        let dispatcher = scope.dispatcher();
        assert!(catch_unwind(AssertUnwindSafe(
            || dispatcher.dispatch(|| panic!("callback panic"))
        ))
        .is_err());
        assert!(!dispatcher.dispatch(|| panic!("poisoned gate must not invoke callbacks")));
        drop(scope);
        assert!(!dispatcher.dispatch(|| panic!("shutdown must keep a poisoned gate closed")));
    }
}
