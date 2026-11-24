//! Separate-process synthetic search memory baseline. No SSH/user data.
use hspterm_term_core::{Size, Terminal};
use std::{collections::BTreeMap, time::Instant};
fn memory() -> BTreeMap<String, u64> {
    let mut values = BTreeMap::new();
    if let Ok(status) = std::fs::read_to_string("/proc/self/status") {
        for line in status.lines() {
            if let Some((name, body)) = line.split_once(':')
                && matches!(name, "VmRSS" | "VmHWM")
                && let Some(value) = body
                    .split_whitespace()
                    .next()
                    .and_then(|s| s.parse::<u64>().ok())
            {
                values.insert(name.into(), value * 1024);
            }
        }
    }
    values
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let unicode = std::env::args().any(|a| a == "--unicode");
    let mut term = Terminal::new(Size::new(140, 34)?, 100_000)?;
    let suffix = if unicode {
        "中文 e\u{301} 😀 ".repeat(10)
    } else {
        "abcdefg ".repeat(13)
    };
    for batch in 0..1000 {
        let mut text = String::new();
        for row in batch * 100..batch * 100 + 100 {
            text.push_str(&format!("{row:08} {suffix}\r\n"));
        }
        term.feed(text.as_bytes())?;
        drop(term.take_events());
    }
    let before = memory();
    let started = Instant::now();
    let index = term
        .document()?
        .search(if unicode { "中文" } else { "abcdefg" }, false, true)?;
    let build_ms = started.elapsed().as_millis();
    let retained = memory();
    let navigation = Instant::now();
    let mut checksum = 0u64;
    for i in 0..200 {
        let hit = index
            .hit(i * index.count / 200)?
            .expect("synthetic history has matches");
        checksum += u64::from(hit.start.row) + u64::from(hit.start.column);
    }
    for row in (0..index.rows().saturating_sub(34)).step_by(997) {
        checksum += index.visible_hits(row, 34)?.len() as u64;
    }
    let navigation_ms = navigation.elapsed().as_millis();
    let after_navigation = memory();
    let count = index.count;
    let rows = index.rows();
    drop(index);
    let cleared = memory();
    println!(
        "{}",
        serde_json::json!({"platform":std::env::consts::OS,"unicode":unicode,"rows":rows,"matches":count,"checksum":checksum,"build_ms":build_ms,"navigation_ms":navigation_ms,"before":before,"retained":retained,"after_navigation":after_navigation,"cleared":cleared})
    );
    Ok(())
}
