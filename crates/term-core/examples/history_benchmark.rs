//! Synthetic core-only resource/search benchmark. Emits aggregate JSON only.
use hspterm_term_core::{Size, Terminal};
use std::{io, time::Instant};
fn rss() -> u64 {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines().find_map(|l| {
                l.strip_prefix("VmRSS:")
                    .and_then(|v| v.split_whitespace().next()?.parse::<u64>().ok())
            })
        })
        .unwrap_or(0)
        * 1024
}
fn sample(label: &str, term: &Terminal, started: Instant, count: u32) {
    let stats = term.history_stats();
    println!(
        "{{\"phase\":\"{label}\",\"elapsed_ms\":{},\"rss_bytes\":{},\"disk_bytes\":{},\"disk_reads\":{},\"disk_writes\":{},\"resident_cells\":{},\"retained_rows\":{},\"matches\":{count}}}",
        started.elapsed().as_millis(),
        rss(),
        stats.disk_bytes,
        stats.disk_reads,
        stats.disk_writes,
        stats.resident_history_cells,
        stats.retained_rows
    );
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut term = Terminal::new(Size::new(140, 34)?, 100_000)?;
    sample("created", &term, Instant::now(), 0);
    let start = Instant::now();
    for block in 0..10_000 {
        let mut text = String::with_capacity(12_000);
        for row in block * 100..block * 100 + 100 {
            text.push_str(&format!("{row:08} 中文 é {}\r\n", "abcdefg".repeat(10)));
        }
        term.feed(text.as_bytes())?;
        drop(term.take_events());
        if [99, 999, 2999, 5999, 9999].contains(&block) {
            sample(&format!("output_{}", (block + 1) * 100), &term, start, 0);
            assert!(term.history_stats().retained_rows <= 100_000);
            assert!(term.history_stats().resident_history_cells <= 256 * 140);
            assert!(term.history_stats().disk_bytes < 32 * 1024 * 1024);
        }
    }
    let start = Instant::now();
    let search = term.document()?.search(r"(?m)^\d{8} 中文", true, true)?;
    assert!(search.count >= 100_000 && search.count <= 100_034);
    assert!(search.hit(search.count - 1)?.is_some());
    sample("regex_100k_rows", &term, start, search.count);
    drop(search);
    let start = Instant::now();
    let search = term.document()?.search(".", true, true)?;
    let hits = search.visible_hits(1000, 34)?;
    assert!(hits.len() > 2000);
    sample(
        "single_character_regex_visible_hits",
        &term,
        start,
        search.count,
    );
    drop(search);
    for columns in [60, 140, 70, 120] {
        let start = Instant::now();
        term.resize(Size::new(columns, 34)?)?;
        let _ = term.try_snapshot()?;
        sample(&format!("reflow_{columns}"), &term, start, 0);
        assert!(term.history_stats().resident_history_cells <= (256 + 34) * usize::from(columns));
    }
    let start = Instant::now();
    term.document()?.export(&mut io::sink())?;
    sample("stream_export", &term, start, 0);
    drop(term);
    println!("{{\"phase\":\"dropped\",\"rss_bytes\":{}}}", rss());
    Ok(())
}
