//! Filesystem manipulation operations.
//!
//! This module contains methods for interacting with remote entities on high-level.
//! The architecture is quite simple because it is built as an analogue of [`std::fs`]

mod dir;
mod dir_stream;
mod file;

use crate::protocol::FileAttributes;

pub use dir::{DirEntry, ReadDir};
pub use dir_stream::ReadDirStream;
pub use file::File;
pub type Metadata = FileAttributes;
