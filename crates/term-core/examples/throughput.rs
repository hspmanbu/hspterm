//! Reproducible synthetic parser baseline. This does not measure Flutter rendering.
use hspterm_term_core::{Size, Terminal};
use std::time::Instant;
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut terminal = Terminal::new(Size::new(120, 40)?, 10_000)?;
    let line = "\x1b[38;2;120;200;80m2026-10-22 INFO 中文 e\u{301} box ┌─┐ 0123456789\x1b[0m\r\n";
    let block = line.repeat(800);
    let batches = (16 * 1024 * 1024) / block.len() + 1;
    let start = Instant::now();
    for _ in 0..batches {
        terminal.feed(block.as_bytes()).unwrap();
        // Synthetic output has no platform requests; exercise normal per-batch draining.
        drop(terminal.take_events());
    }
    terminal.feed(b"HSPTERM_BENCHMARK_COMPLETE").unwrap();
    let elapsed = start.elapsed();
    let snapshot = terminal.snapshot();
    assert!(snapshot.text().contains("HSPTERM_BENCHMARK_COMPLETE"));
    assert_eq!(snapshot.history_lines, 10_000);
    let bytes = batches * block.len();
    println!(
        "profile={} columns=120 rows=40 history=10000 bytes={} elapsed_ms={} throughput_mib_s={:.2}",
        if cfg!(debug_assertions) {
            "debug"
        } else {
            "release"
        },
        bytes,
        elapsed.as_millis(),
        bytes as f64 / (1024.0 * 1024.0) / elapsed.as_secs_f64()
    );
    Ok(())
}
