//! Log lines for the app's log (`link:` stats, sessions opened / closed, path changes, guard events). One process-wide
//! sink, set by the app; without one the lines go to `tracing`.

use std::sync::{Arc, RwLock};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum LogLevel {
    Debug,
    Info,
    Warn,
    Error,
}

pub type LogSink = Arc<dyn Fn(LogLevel, &str) + Send + Sync>;

static SINK: RwLock<Option<LogSink>> = RwLock::new(None);

/// Sends every line to `sink` from now on (`None`: back to `tracing`).
pub fn set_log_sink(sink: Option<LogSink>) {
    *SINK.write().unwrap() = sink;
}

pub fn log(level: LogLevel, message: &str) {
    let sink = SINK.read().unwrap().clone();
    match sink {
        Some(s) => s(level, message),
        None => match level {
            LogLevel::Debug => tracing::debug!("{message}"),
            LogLevel::Info => tracing::info!("{message}"),
            LogLevel::Warn => tracing::warn!("{message}"),
            LogLevel::Error => tracing::error!("{message}"),
        },
    }
}

macro_rules! log_info {
    ($($arg:tt)*) => { $crate::log::log($crate::log::LogLevel::Info, &format!($($arg)*)) };
}
macro_rules! log_warn {
    ($($arg:tt)*) => { $crate::log::log($crate::log::LogLevel::Warn, &format!($($arg)*)) };
}
macro_rules! log_debug {
    ($($arg:tt)*) => { $crate::log::log($crate::log::LogLevel::Debug, &format!($($arg)*)) };
}
pub(crate) use {log_debug as debug, log_info as info, log_warn as warn};
