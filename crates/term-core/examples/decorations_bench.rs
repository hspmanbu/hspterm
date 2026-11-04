//! Reproducible synthetic CPU-only visible-grid benchmark, never a real SSH log.
use hspterm_term_core::{
    Size, Terminal,
    decorations::{Config, Decorator, Rule, Style},
};
use std::time::Instant;
fn rule(index: usize, regex: bool) -> Rule {
    Rule {
        id: format!("bench-{index}"),
        name: format!("Synthetic {index}"),
        pattern: if regex {
            r"\b(ERROR|WARN|FAIL)\b".into()
        } else if index == 0 {
            "ERROR".into()
        } else {
            format!("NOT_PRESENT_{index}")
        },
        regex,
        case_sensitive: true,
        enabled: true,
        force_color: false,
        style: Style {
            foreground: Some(0xffea8686),
            ..Style::default()
        },
    }
}
fn main() {
    let mut terminal = Terminal::new(Size::new(160, 60).unwrap(), 100).unwrap();
    for index in 0..80 {
        terminal.feed(format!("ERROR 2026-10-26 12:00:00 /var/log/app 127.0.0.1 [value=({index})] 中文 e\u{301} \x1b[31mERROR\x1b[0m\r\n").as_bytes()).unwrap();
    }
    let snapshot = terminal.snapshot();
    println!("scenario\titerations\tmean_ms\tp95_ms\tpainted_cells\tlimited");
    for (name, config) in [
        ("disabled", Config::default()),
        (
            "keyword",
            Config {
                enabled: true,
                rules: vec![rule(0, false)],
                ..Config::default()
            },
        ),
        (
            "regex",
            Config {
                enabled: true,
                rules: vec![rule(0, true)],
                ..Config::default()
            },
        ),
        (
            "32_rules",
            Config {
                enabled: true,
                rules: (0..32).map(|i| rule(i, false)).collect(),
                ..Config::default()
            },
        ),
        (
            "semantic_rainbow",
            Config {
                enabled: true,
                semantic: true,
                rainbow: true,
                ..Config::default()
            },
        ),
    ] {
        let decorator = Decorator::new(config).unwrap();
        let mut samples = Vec::new();
        let (mut cells, mut limited) = (0, false);
        for _ in 0..100 {
            let start = Instant::now();
            let result = std::hint::black_box(decorator.decorate(std::hint::black_box(&snapshot)));
            samples.push(start.elapsed().as_secs_f64() * 1000.0);
            cells = result.cells.len();
            limited |= result.limited;
        }
        let mean = samples.iter().sum::<f64>() / samples.len() as f64;
        samples.sort_by(f64::total_cmp);
        println!(
            "{name}\t100\t{mean:.6}\t{:.6}\t{cells}\t{limited}",
            samples[94]
        );
    }
    assert_eq!(snapshot, terminal.snapshot());
}
