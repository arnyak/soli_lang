//! `to_string`: a value written as YAML the way `serde_yaml` 0.9 wrote it —
//! block style, two-space indentation, a sequence at its key's indentation,
//! a string quoted only when its plain form would read back as something
//! else, and a multi-line string as a literal block.

use serde_json::{Map, Value};

use crate::scalar;

/// The YAML document for `value`, ending in a line break.
pub fn to_string(value: &Value) -> String {
    let mut out = String::new();
    match value {
        Value::Object(map) if !map.is_empty() => mapping(&mut out, map, 0, false),
        Value::Array(items) if !items.is_empty() => sequence(&mut out, items, 0, false),
        Value::String(s) if multiline(s) => literal(&mut out, s, 2),
        other => {
            out.push_str(&scalar_text(other));
            out.push('\n');
        }
    }
    out
}

/// `first_inline`: the first entry continues a line already started (after a
/// sequence entry's `- `).
fn mapping(out: &mut String, map: &Map<String, Value>, indent: usize, first_inline: bool) {
    for (i, (key, value)) in map.iter().enumerate() {
        if i > 0 || !first_inline {
            out.push_str(&" ".repeat(indent));
        }
        out.push_str(&string_text(key));
        out.push(':');
        after_key(out, value, indent);
    }
}

fn after_key(out: &mut String, value: &Value, indent: usize) {
    match value {
        Value::Object(map) if !map.is_empty() => {
            out.push('\n');
            mapping(out, map, indent + 2, false);
        }
        Value::Array(items) if !items.is_empty() => {
            out.push('\n');
            sequence(out, items, indent, false);
        }
        Value::String(s) if multiline(s) => {
            out.push(' ');
            literal(out, s, indent + 2);
        }
        other => {
            out.push(' ');
            out.push_str(&scalar_text(other));
            out.push('\n');
        }
    }
}

fn sequence(out: &mut String, items: &[Value], indent: usize, first_inline: bool) {
    for (i, item) in items.iter().enumerate() {
        if i > 0 || !first_inline {
            out.push_str(&" ".repeat(indent));
        }
        out.push_str("- ");
        match item {
            Value::Object(map) if !map.is_empty() => mapping(out, map, indent + 2, true),
            Value::Array(inner) if !inner.is_empty() => sequence(out, inner, indent + 2, true),
            Value::String(s) if multiline(s) => literal(out, s, indent + 2),
            other => {
                out.push_str(&scalar_text(other));
                out.push('\n');
            }
        }
    }
}

/// A string that is written as a literal block (`|`): several lines, nothing
/// a block cannot hold.
fn multiline(s: &str) -> bool {
    s.contains('\n')
        && !s.starts_with([' ', '\t', '\n'])
        && !s
            .chars()
            .any(|c| (c.is_control() && c != '\n') || c == '\u{FEFF}')
        && s.split('\n').all(|line| !line.ends_with([' ', '\t']))
}

/// `|`, `|-` or `|+` (by the string's trailing line breaks), then its lines.
fn literal(out: &mut String, s: &str, indent: usize) {
    let body = s.trim_end_matches('\n');
    let trailing = s.len() - body.len();
    out.push_str(match trailing {
        0 => "|-",
        1 => "|",
        _ => "|+",
    });
    out.push('\n');
    let pad = " ".repeat(indent);
    for line in body.split('\n') {
        if !line.is_empty() {
            out.push_str(&pad);
            out.push_str(line);
        }
        out.push('\n');
    }
    for _ in 1..trailing {
        out.push('\n');
    }
}

fn scalar_text(value: &Value) -> String {
    match value {
        Value::Null => "null".to_string(),
        Value::Bool(b) => b.to_string(),
        // `1e20`, as serde_yaml wrote it; serde_json says `1e+20`.
        Value::Number(n) => n.to_string().replace("e+", "e"),
        Value::String(s) => string_text(s),
        Value::Array(_) => "[]".to_string(),
        Value::Object(_) => "{}".to_string(),
    }
}

/// A string as a plain scalar when it reads back as itself, single-quoted
/// when only its meaning needs protecting, double-quoted when it holds a
/// character that has to be escaped.
fn string_text(s: &str) -> String {
    if scalar::plain_safe(s) {
        return s.to_string();
    }
    if s.chars().any(needs_escape) {
        return double_quoted(s);
    }
    format!("'{}'", s.replace('\'', "''"))
}

fn needs_escape(c: char) -> bool {
    c.is_control() || matches!(c, '\u{FEFF}' | '\u{2028}' | '\u{2029}' | '\u{85}')
}

fn double_quoted(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            '\0' => out.push_str("\\0"),
            '\u{7}' => out.push_str("\\a"),
            '\u{8}' => out.push_str("\\b"),
            '\u{b}' => out.push_str("\\v"),
            '\u{c}' => out.push_str("\\f"),
            '\u{1b}' => out.push_str("\\e"),
            '\u{85}' => out.push_str("\\N"),
            '\u{2028}' => out.push_str("\\L"),
            '\u{2029}' => out.push_str("\\P"),
            c if needs_escape(c) && (c as u32) <= 0xFF => {
                out.push_str(&format!("\\x{:02X}", c as u32))
            }
            c if needs_escape(c) => out.push_str(&format!("\\u{:04X}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}
