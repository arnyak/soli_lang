//! The YAML Soli reads and writes, in safe Rust and with no dependency but
//! `serde_json`.
//!
//! It replaces `serde_yaml`, deprecated, whose parser is `unsafe-libyaml` — a
//! machine translation of libyaml's C into unsafe Rust, archived in 2024
//! (RUSTSEC-2024-0449). What Soli reads is a small part of YAML: locale files
//! (`config/locales/*.yml`) and whatever `Yaml.parse` is handed, which in
//! practice is the same kind of document. This crate reads that part, the way
//! `serde_yaml` 0.9 read it, and **refuses** the rest with an error naming the
//! line and column, rather than reading it some other way.
//!
//! Read:
//!
//! - block mappings and sequences, including a sequence at its key's
//!   indentation (`key:` then `- item`) and compact nesting (`- a: 1`,
//!   `- - x`);
//! - plain, `'single'` and `"double"`-quoted scalars, over several lines
//!   (folded as YAML folds them), with every double-quoted escape;
//! - literal `|` and folded `>` block scalars, with chomping (`-`, `+`) and an
//!   indentation indicator;
//! - flow sequences and mappings (`[a, b]`, `{k: v}`), nested, over several
//!   lines;
//! - comments, a leading `---` and a trailing `...`;
//! - the YAML 1.2 core schema, as `serde_yaml` 0.9 applies it: `null`/`~`/
//!   empty, `true`/`false` (any case), decimal, `0o`, `0x` and `0b` integers,
//!   floats including `.inf`/`.nan` (which become `null`, as JSON has no
//!   such number), and everything else a string — `yes`, `on`, `012`, `1_000`
//!   and `2026-10-12` among them.
//!
//! Refused: anchors and aliases (`&a`, `*a`), tags (`!x`), complex keys
//! (`? k`), directives (`%YAML`), more than one document, tabs in
//! indentation, nesting deeper than 128 levels, and what YAML itself rejects
//! (`a: b: c`, `@x`).
//!
//! Keys become strings (`1: a` is `{"1": "a"}`), and a key given twice keeps
//! its last value, as `serde_yaml` did when reading into JSON.

mod emitter;
mod parser;
mod scalar;

use std::fmt;

pub use emitter::to_string;

/// Why a document could not be read: what was found, and where (1-based).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    pub message: String,
    pub line: usize,
    pub column: usize,
}

impl Error {
    pub(crate) fn new(message: impl Into<String>, line: usize, column: usize) -> Self {
        Error {
            message: message.into(),
            line,
            column,
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{} at line {} column {}",
            self.message, self.line, self.column
        )
    }
}

impl std::error::Error for Error {}

/// Read one YAML document. An empty document (or one of comments only) is
/// `null`.
pub fn parse(text: &str) -> Result<serde_json::Value, Error> {
    parser::parse(text)
}
