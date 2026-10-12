//! What a plain scalar means (the YAML 1.2 core schema, as `serde_yaml` 0.9
//! resolved it), and whether a string can be written plain.

use serde_json::{Number, Value};

/// The value of a plain (unquoted) scalar.
pub(crate) fn resolve(text: &str) -> Value {
    match text {
        "" | "~" | "null" | "Null" | "NULL" => return Value::Null,
        "true" | "True" | "TRUE" => return Value::Bool(true),
        "false" | "False" | "FALSE" => return Value::Bool(false),
        // JSON has no infinity or NaN: serde_yaml read them as null too.
        ".inf" | ".Inf" | ".INF" | "+.inf" | "+.Inf" | "+.INF" | "-.inf" | "-.Inf" | "-.INF"
        | ".nan" | ".NaN" | ".NAN" => return Value::Null,
        _ => {}
    }
    if let Some(n) = integer(text) {
        return n;
    }
    if is_float(text) {
        if let Ok(f) = text.parse::<f64>() {
            if let Some(n) = Number::from_f64(f) {
                return Value::Number(n);
            }
        }
    }
    Value::String(text.to_string())
}

/// `[-+]?[0-9]+` (no leading zero, which makes `012` a string), or
/// `0o`/`0x`/`0b` followed by digits of that base.
fn integer(text: &str) -> Option<Value> {
    let (negative, digits) = match text.as_bytes().first()? {
        b'-' => (true, &text[1..]),
        b'+' => (false, &text[1..]),
        _ => (false, text),
    };
    if digits.is_empty() {
        return None;
    }
    let (radix, body) = if let Some(rest) = digits.strip_prefix("0o") {
        (8, rest)
    } else if let Some(rest) = digits.strip_prefix("0x") {
        (16, rest)
    } else if let Some(rest) = digits.strip_prefix("0b") {
        (2, rest)
    } else {
        if !digits.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        if digits.len() > 1 && digits.starts_with('0') {
            return None;
        }
        (10, digits)
    };
    if body.is_empty() || !body.chars().all(|c| c.is_digit(radix)) {
        return None;
    }
    // Too large for an i64 / u64: serde_yaml read it as a float.
    if let Ok(n) = u64::from_str_radix(body, radix) {
        if negative {
            if n <= i64::MAX as u64 + 1 {
                return Some(Value::Number(Number::from(
                    (n as i128).wrapping_neg() as i64
                )));
            }
        } else {
            return Some(Value::Number(Number::from(n)));
        }
    }
    if radix == 10 {
        let f: f64 = text.parse().ok()?;
        return Number::from_f64(f).map(Value::Number);
    }
    None
}

/// `[-+]? ( \. [0-9]+ | [0-9]+ ( \. [0-9]* )? ) ( [eE] [-+]? [0-9]+ )?`
fn is_float(text: &str) -> bool {
    let s = text.strip_prefix(['-', '+']).unwrap_or(text);
    let (mantissa, exponent) = match s.find(['e', 'E']) {
        Some(i) => (&s[..i], Some(&s[i + 1..])),
        None => (s, None),
    };
    let mantissa_ok = match mantissa.split_once('.') {
        Some((int, frac)) => {
            (!int.is_empty() || !frac.is_empty())
                && int.bytes().all(|b| b.is_ascii_digit())
                && frac.bytes().all(|b| b.is_ascii_digit())
        }
        None => !mantissa.is_empty() && mantissa.bytes().all(|b| b.is_ascii_digit()),
    };
    // A bare integer is not a float here (`integer` saw it first); `1.` and
    // `.5` are.
    if !mantissa_ok || (exponent.is_none() && !mantissa.contains('.')) {
        return false;
    }
    match exponent {
        None => true,
        Some(e) => {
            let digits = e.strip_prefix(['-', '+']).unwrap_or(e);
            !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit())
        }
    }
}

/// Whether `s` can be written as a plain scalar and read back as the same
/// string.
pub(crate) fn plain_safe(s: &str) -> bool {
    if s.is_empty() || s.trim() != s {
        return false;
    }
    // It would read back as something else: null, a bool, a number — or as
    // a number to a YAML 1.1 reader (`012`, `inf`), which serde_yaml quoted.
    if !matches!(resolve(s), Value::String(_)) || s.parse::<f64>().is_ok() {
        return false;
    }
    let first = s.chars().next().unwrap_or(' ');
    if matches!(
        first,
        '-' | '?'
            | ':'
            | ','
            | '['
            | ']'
            | '{'
            | '}'
            | '#'
            | '&'
            | '*'
            | '!'
            | '|'
            | '>'
            | '\''
            | '"'
            | '%'
            | '@'
            | '`'
    ) {
        // `-x`, `?x` and `:x` read as plain; an indicator followed by a space
        // does not.
        let second = s.chars().nth(1);
        let indicator_alone =
            matches!(first, '-' | '?' | ':') && second.is_some_and(|c| c != ' ' && c != '\t');
        if !indicator_alone {
            return false;
        }
    }
    if s.contains(": ") || s.ends_with(':') || s.contains(" #") {
        return false;
    }
    if s == "---" || s == "..." {
        return false;
    }
    !s.chars()
        .any(|c| c.is_control() || c == '\u{FEFF}' || c == '\u{2028}' || c == '\u{2029}')
}
