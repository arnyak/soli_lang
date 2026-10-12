//! What `serde_yaml` 0.9.34 read and wrote, recorded in `fixtures/`: every
//! document it read is read here to the same value, every one it refused is
//! refused, and every value is written byte for byte as it wrote it. The two
//! cases it read and this crate refuses on purpose (an anchor, a `?` key) are
//! recorded as errors.

use serde_json::Value;

fn fixture(name: &str) -> Vec<Value> {
    let path = format!("{}/tests/fixtures/{name}", env!("CARGO_MANIFEST_DIR"));
    let text = std::fs::read_to_string(&path).expect("fixture");
    serde_json::from_str(&text).expect("fixture is JSON")
}

#[test]
fn reads_what_serde_yaml_read() {
    for case in fixture("parse.json") {
        let yaml = case["yaml"].as_str().expect("yaml");
        let got = soli_yaml::parse(yaml);
        if case.get("error").is_some() {
            assert!(got.is_err(), "{yaml:?} should be refused, read {got:?}");
        } else {
            assert_eq!(got.as_ref().ok(), Some(&case["value"]), "{yaml:?}: {got:?}");
        }
    }
}

#[test]
fn writes_what_serde_yaml_wrote() {
    for case in fixture("emit.json") {
        let written = soli_yaml::to_string(&case["value"]);
        assert_eq!(
            written,
            case["yaml"].as_str().expect("yaml"),
            "{}",
            case["value"]
        );
        assert_eq!(
            soli_yaml::parse(&written).ok().as_ref(),
            Some(&case["value"]),
            "round trip of {written:?}"
        );
    }
}

#[test]
fn an_error_names_its_line_and_column() {
    let err = soli_yaml::parse("a: 1\nb: &x 2\n").unwrap_err();
    assert_eq!((err.line, err.column), (2, 4));
    assert!(err.to_string().ends_with("at line 2 column 4"), "{err}");
}

#[test]
fn refuses_what_it_does_not_read() {
    for yaml in [
        "a: &x 1",
        "a: *x",
        "a: !!str 1",
        "? k\n: v",
        "%YAML 1.2\n---\na: 1",
        "a: 1\n---\nb: 2",
        "a:\n\tb: 1",
    ] {
        assert!(soli_yaml::parse(yaml).is_err(), "{yaml:?}");
    }
}

#[test]
fn a_locale_file() {
    let yaml = "\
en:
  greeting: \"Hello, %{name}!\"
  items:
    one: 1 item
    other: '%{count} items'
  notice: >-
    Folded
    over two lines
";
    let value = soli_yaml::parse(yaml).unwrap();
    assert_eq!(value["en"]["greeting"], "Hello, %{name}!");
    assert_eq!(value["en"]["items"]["other"], "%{count} items");
    assert_eq!(value["en"]["notice"], "Folded over two lines");
}

#[test]
fn refuses_nesting_past_128_levels() {
    let ok = format!("{}{}", "[".repeat(127), "]".repeat(127));
    assert!(soli_yaml::parse(&ok).is_ok());
    for deep in [
        format!("{}{}", "[".repeat(100_000), "]".repeat(100_000)),
        format!("{}{}", "{a: ".repeat(200), "}".repeat(200)),
        (0..200).map(|i| format!("{}k:\n", " ".repeat(i))).collect(),
        (0..200).map(|i| format!("{}-\n", " ".repeat(i))).collect(),
        format!(
            "a:
  x: {}{}",
            "[".repeat(200),
            "]".repeat(200)
        ),
    ] {
        let err = soli_yaml::parse(&deep).unwrap_err();
        assert_eq!(err.message, "recursion limit exceeded", "{err}");
    }
}
