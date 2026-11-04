use hspterm_term_core::{
    Size, Terminal,
    decorations::{Config, Decorator, Rule, Style},
};
fn main() {
    let mut t = Terminal::new(Size::new(4096, 2).unwrap(), 0).unwrap();
    t.feed(&vec![b'A'; 8000]).unwrap();
    let snapshot = t.snapshot();
    for count in [1, 32] {
        let config = Config {
            enabled: true,
            rules: (0..count)
                .map(|i| Rule {
                    id: format!("stress-{i}"),
                    name: "Synthetic only".into(),
                    pattern: "(?:.*[^A-Z]|[A-Z])".into(),
                    regex: true,
                    case_sensitive: true,
                    enabled: true,
                    force_color: false,
                    style: Style {
                        foreground: Some(0xffeeeeee),
                        ..Style::default()
                    },
                })
                .collect(),
            ..Config::default()
        };
        let d = Decorator::new(config).unwrap();
        let start = std::time::Instant::now();
        let result = d.decorate(&snapshot);
        println!(
            "rules={count} elapsed_ms={:.3} limited={} painted={}",
            start.elapsed().as_secs_f64() * 1000.,
            result.limited,
            result.cells.len()
        );
    }
    assert_eq!(snapshot, t.snapshot());
}
