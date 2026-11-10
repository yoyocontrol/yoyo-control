//! Errors and the codes that cross the wire (docs/LINK.md「Session」).

use std::fmt;

/// Why a server refused a session (`denied.code`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DenyCode {
    Unauthorized,
    RateLimited,
    Busy,
}

impl DenyCode {
    pub fn as_str(self) -> &'static str {
        match self {
            DenyCode::Unauthorized => "unauthorized",
            DenyCode::RateLimited => "rate-limited",
            DenyCode::Busy => "busy",
        }
    }

    /// Unknown codes (a newer server) read as `busy`: try again later, don't forget the computer.
    pub fn parse(s: &str) -> DenyCode {
        match s {
            "unauthorized" => DenyCode::Unauthorized,
            "rate-limited" => DenyCode::RateLimited,
            _ => DenyCode::Busy,
        }
    }

    /// The QUIC application close code that goes with it.
    pub fn close_code(self) -> CloseCode {
        match self {
            DenyCode::Unauthorized => CloseCode::Unauthorized,
            DenyCode::RateLimited => CloseCode::RateLimited,
            DenyCode::Busy => CloseCode::Busy,
        }
    }
}

impl fmt::Display for DenyCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// QUIC application close codes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CloseCode {
    Normal,
    Unauthorized,
    RateLimited,
    Busy,
    Protocol,
    ShuttingDown,
    Replaced,
    /// A code this version doesn't know.
    Other(u64),
}

impl CloseCode {
    pub fn code(self) -> u64 {
        match self {
            CloseCode::Normal => 0,
            CloseCode::Unauthorized => 1,
            CloseCode::RateLimited => 2,
            CloseCode::Busy => 3,
            CloseCode::Protocol => 4,
            CloseCode::ShuttingDown => 5,
            CloseCode::Replaced => 6,
            CloseCode::Other(c) => c,
        }
    }

    pub fn from_code(code: u64) -> CloseCode {
        match code {
            0 => CloseCode::Normal,
            1 => CloseCode::Unauthorized,
            2 => CloseCode::RateLimited,
            3 => CloseCode::Busy,
            4 => CloseCode::Protocol,
            5 => CloseCode::ShuttingDown,
            6 => CloseCode::Replaced,
            c => CloseCode::Other(c),
        }
    }

    /// The deny code a client reports when the connection was closed with this code before a `denied` arrived.
    pub fn deny_code(self) -> Option<DenyCode> {
        match self {
            CloseCode::Unauthorized => Some(DenyCode::Unauthorized),
            CloseCode::RateLimited => Some(DenyCode::RateLimited),
            CloseCode::Busy => Some(DenyCode::Busy),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            CloseCode::Normal => "normal",
            CloseCode::Unauthorized => "unauthorized",
            CloseCode::RateLimited => "rate-limited",
            CloseCode::Busy => "busy",
            CloseCode::Protocol => "protocol",
            CloseCode::ShuttingDown => "shutting-down",
            CloseCode::Replaced => "replaced",
            CloseCode::Other(_) => "other",
        }
    }
}

#[derive(Debug, Clone, thiserror::Error)]
pub enum LinkError {
    #[error("invalid argument: {0}")]
    InvalidArgument(String),
    #[error("bind failed: {0}")]
    Bind(String),
    #[error("connect failed: {0}")]
    Connect(String),
    #[error("timed out: {0}")]
    Timeout(String),
    #[error("denied ({code}): {message}")]
    Denied { code: DenyCode, message: String },
    #[error("protocol error: {0}")]
    Protocol(String),
    #[error("session closed: {0}")]
    Closed(String),
    #[error("binding: {0}")]
    Binding(String),
    #[error("datagram: {0}")]
    Datagram(String),
    #[error("{0}")]
    Io(String),
    #[error("media: {0}")]
    Media(String),
}

pub type Result<T, E = LinkError> = std::result::Result<T, E>;

impl LinkError {
    pub(crate) fn protocol(s: impl Into<String>) -> Self {
        LinkError::Protocol(s.into())
    }
}
