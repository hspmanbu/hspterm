//! Stable bridge DTOs and lifecycle ownership; generated FFI is the sole unsafe boundary.
#![deny(unsafe_code)]
mod agents;
pub mod api;
mod backups;
mod configuration_sync;
mod connections;
pub mod diagnostics;
mod directories;
mod display;
mod drive_authorization;
mod editors;
mod forwardings;
mod frame;
#[allow(unsafe_code)]
mod frb_generated;
pub mod host_bulk;
pub mod host_ordering;
mod inspection;
mod network_settings;
mod openssh_import;
mod previews;
mod public_errors;
mod remote_transfers;
mod tmux;
mod transfer_channels;
mod transfers;

pub mod history_controls;

pub mod shortcut_settings;
