//! The process's one tokio runtime for the bindings (Swift, Node): multi-thread, 2 workers. The Rust API itself is
//! plain async and runs on whatever tokio runtime calls it.

use std::sync::OnceLock;

use tokio::runtime::{Builder, Runtime};

static RUNTIME: OnceLock<Runtime> = OnceLock::new();

pub fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("uu-link")
            .enable_all()
            .build()
            .expect("uu-link: cannot start the tokio runtime")
    })
}
