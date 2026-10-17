//! Text extraction: the text a reader sees on each page, in reading order.
//!
//! lopdf's own `extract_text` concatenates the strings a page shows. It
//! ignores text positioning (`Td`, `Tm`), so the lines of one text object run
//! together and no space is inferred from a gap, and it never enters a Form
//! XObject — where this crate's own SVG pages and letterheads live. This
//! module interprets the content stream far enough to know where each string
//! lands on the page, then rebuilds the lines from those positions.
//!
//! What it does not do: OCR (a scanned page has no text to find), and fonts
//! that carry neither a usable `/Encoding` nor a `/ToUnicode` map decode to
//! whatever their codes mean in the standard encoding.

use std::collections::{HashMap, HashSet};

use lopdf::content::Content;
use lopdf::{Dictionary, Document, Encoding, Object, ObjectId};

use crate::error::{PdfError, Result};

/// Nesting of Form XObjects followed before giving up on a branch.
const MAX_FORM_DEPTH: usize = 8;
/// Content-stream operations interpreted for one page, forms included. A
/// hostile file cannot make a page cost more than this.
const MAX_OPERATIONS: usize = 2_000_000;
/// Text returned for the whole document.
const MAX_OUTPUT_BYTES: usize = 64 * 1024 * 1024;
/// Entries read from a CID font's `/W` array.
const MAX_CID_WIDTHS: usize = 65_536;

/// The text of `pdf`, one string per page: every page, or those `pages`
/// names (1-based, in the order given). A page with no text — a scan — is an
/// empty string.
pub fn extract_text(pdf: &[u8], pages: Option<&[u32]>) -> Result<Vec<String>> {
    let doc = Document::load_mem(pdf)
        .map_err(|e| PdfError::Backend(format!("text: could not parse the PDF: {e}")))?;
    // lopdf opens a document whose user password is empty on its own; one it
    // could not open stays encrypted, and its streams read as noise.
    if doc.is_encrypted() && !doc.was_encrypted() {
        return Err(PdfError::Backend(
            "text: the PDF is encrypted with a password".into(),
        ));
    }

    let page_ids = doc.get_pages();
    let wanted: Vec<u32> = match pages {
        Some(list) => list.to_vec(),
        None => page_ids.keys().copied().collect(),
    };

    let mut extractor = Extractor::new(&doc);
    let mut out = Vec::with_capacity(wanted.len());
    let mut total = 0usize;
    for number in wanted {
        let page_id = *page_ids.get(&number).ok_or_else(|| {
            PdfError::Backend(format!(
                "text: page {number} does not exist (the PDF has {})",
                page_ids.len()
            ))
        })?;
        let text = extractor.page_text(page_id, number)?;
        total += text.len();
        if total > MAX_OUTPUT_BYTES {
            return Err(PdfError::Backend(format!(
                "text: more than {} MB of text",
                MAX_OUTPUT_BYTES / (1024 * 1024)
            )));
        }
        out.push(text);
    }
    Ok(out)
}

// --- geometry ---------------------------------------------------------------

/// An affine matrix `[a b c d e f]`, applied to row vectors as PDF does.
type Matrix = [f32; 6];

const IDENTITY: Matrix = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0];

/// `m × n`: apply `m`, then `n`.
fn mul(m: &Matrix, n: &Matrix) -> Matrix {
    [
        m[0] * n[0] + m[1] * n[2],
        m[0] * n[1] + m[1] * n[3],
        m[2] * n[0] + m[3] * n[2],
        m[2] * n[1] + m[3] * n[3],
        m[4] * n[0] + m[5] * n[2] + n[4],
        m[4] * n[1] + m[5] * n[3] + n[5],
    ]
}

fn translate(x: f32, y: f32) -> Matrix {
    [1.0, 0.0, 0.0, 1.0, x, y]
}

fn apply(m: &Matrix, x: f32, y: f32) -> (f32, f32) {
    (x * m[0] + y * m[2] + m[4], x * m[1] + y * m[3] + m[5])
}

// --- fonts --------------------------------------------------------------------

/// Glyph advances, in glyph units (1/1000 em for all but Type 3 fonts).
enum Widths {
    Simple {
        first: u32,
        widths: Vec<f32>,
        missing: f32,
    },
    Cid {
        widths: HashMap<u32, f32>,
        default: f32,
    },
}

impl Widths {
    fn get(&self, code: u32) -> f32 {
        match self {
            Widths::Simple {
                first,
                widths,
                missing,
            } => code
                .checked_sub(*first)
                .and_then(|i| widths.get(i as usize).copied())
                .filter(|w| *w > 0.0)
                .unwrap_or(*missing),
            Widths::Cid { widths, default } => widths.get(&code).copied().unwrap_or(*default),
        }
    }
}

struct FontInfo<'a> {
    encoding: Option<Encoding<'a>>,
    /// A Type 0 font: two bytes per code (Identity-H and the like).
    two_byte: bool,
    widths: Widths,
    /// Glyph units to text space: 0.001, or a Type 3 font's `/FontMatrix`.
    scale: f32,
}

impl<'a> FontInfo<'a> {
    fn new(doc: &'a Document, font: &'a Dictionary) -> FontInfo<'a> {
        let subtype = font
            .get(b"Subtype")
            .and_then(Object::as_name)
            .unwrap_or(b"");
        let encoding = font.get_font_encoding(doc).ok();
        if subtype == b"Type0" {
            let descendant = font
                .get_deref(b"DescendantFonts", doc)
                .and_then(Object::as_array)
                .ok()
                .and_then(|fonts| fonts.first())
                .and_then(|first| deref_dict(doc, first));
            let default = descendant
                .and_then(|d| d.get(b"DW").and_then(Object::as_float).ok())
                .unwrap_or(1000.0);
            let widths = descendant
                .and_then(|d| d.get_deref(b"W", doc).and_then(Object::as_array).ok())
                .map(|w| cid_widths(doc, w))
                .unwrap_or_default();
            return FontInfo {
                encoding,
                two_byte: true,
                widths: Widths::Cid { widths, default },
                scale: 0.001,
            };
        }

        let scale = if subtype == b"Type3" {
            font.get_deref(b"FontMatrix", doc)
                .and_then(Object::as_array)
                .ok()
                .and_then(|m| m.first())
                .and_then(|a| a.as_float().ok())
                .filter(|a| a.is_finite() && *a != 0.0)
                .map(f32::abs)
                .unwrap_or(0.001)
        } else {
            0.001
        };
        let first = font
            .get(b"FirstChar")
            .and_then(Object::as_i64)
            .ok()
            .and_then(|c| u32::try_from(c).ok())
            .unwrap_or(0);
        let widths: Vec<f32> = font
            .get_deref(b"Widths", doc)
            .and_then(Object::as_array)
            .map(|ws| {
                ws.iter()
                    .take(256)
                    .map(|w| deref(doc, w).and_then(|o| o.as_float().ok()).unwrap_or(0.0))
                    .collect()
            })
            .unwrap_or_default();
        let missing = font
            .get_deref(b"FontDescriptor", doc)
            .and_then(Object::as_dict)
            .and_then(|d| d.get(b"MissingWidth"))
            .and_then(Object::as_float)
            .ok()
            .filter(|w| *w > 0.0)
            // No width at all: half an em is the usual average.
            .unwrap_or(if scale == 0.001 { 500.0 } else { 0.5 / scale });
        FontInfo {
            encoding,
            two_byte: false,
            widths: Widths::Simple {
                first,
                widths,
                missing,
            },
            scale,
        }
    }

    fn decode(&self, bytes: &[u8]) -> String {
        if let Some(encoding) = &self.encoding {
            if let Ok(text) = encoding.bytes_to_string(bytes) {
                return text;
            }
        }
        if self.two_byte {
            // Glyph ids with no map back to characters: nothing to show.
            return String::new();
        }
        bytes.iter().map(|b| char::from(*b)).collect()
    }
}

/// A CID font's `/W`: `c [w1 w2 …]` (consecutive codes from `c`) and
/// `c_first c_last w` (one width for a range).
fn cid_widths(doc: &Document, w: &[Object]) -> HashMap<u32, f32> {
    let mut out = HashMap::new();
    let mut i = 0;
    while i < w.len() && out.len() < MAX_CID_WIDTHS {
        let Some(start) = w[i].as_i64().ok().and_then(|c| u32::try_from(c).ok()) else {
            break;
        };
        match w.get(i + 1).and_then(|o| deref(doc, o)) {
            Some(Object::Array(list)) => {
                for (offset, width) in list.iter().enumerate() {
                    if out.len() >= MAX_CID_WIDTHS {
                        break;
                    }
                    if let Ok(width) = width.as_float() {
                        out.insert(start.saturating_add(offset as u32), width);
                    }
                }
                i += 2;
            }
            Some(end) => {
                let end = end.as_i64().ok().and_then(|c| u32::try_from(c).ok());
                let width = w.get(i + 2).and_then(|o| o.as_float().ok());
                let (Some(end), Some(width)) = (end, width) else {
                    break;
                };
                let last = end.min(start.saturating_add(MAX_CID_WIDTHS as u32));
                for code in start..=last {
                    if out.len() >= MAX_CID_WIDTHS {
                        break;
                    }
                    out.insert(code, width);
                }
                i += 3;
            }
            None => break,
        }
    }
    out
}

fn deref<'a>(doc: &'a Document, object: &'a Object) -> Option<&'a Object> {
    doc.dereference(object).ok().map(|(_, o)| o)
}

fn deref_dict<'a>(doc: &'a Document, object: &'a Object) -> Option<&'a Dictionary> {
    deref(doc, object).and_then(|o| o.as_dict().ok())
}

// --- content interpretation -----------------------------------------------------

/// A string drawn on the page, in device space (points, y up).
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Segment {
    pub x0: f32,
    pub x1: f32,
    pub y: f32,
    pub size: f32,
    pub text: String,
}

/// The resource dictionaries a content stream sees, nearest first.
type Resources<'a> = Vec<&'a Dictionary>;

#[derive(Clone)]
struct GraphicsState {
    ctm: Matrix,
    font: Option<usize>,
    size: f32,
    char_spacing: f32,
    word_spacing: f32,
    horizontal_scale: f32,
    leading: f32,
    rise: f32,
}

impl Default for GraphicsState {
    fn default() -> Self {
        GraphicsState {
            ctm: IDENTITY,
            font: None,
            size: 0.0,
            char_spacing: 0.0,
            word_spacing: 0.0,
            horizontal_scale: 1.0,
            leading: 0.0,
            rise: 0.0,
        }
    }
}

struct Extractor<'a> {
    doc: &'a Document,
    fonts: Vec<FontInfo<'a>>,
    font_ids: HashMap<ObjectId, usize>,
    operations: usize,
    page: u32,
}

/// Where one run of the interpreter is: its state, and what it has found.
struct Run {
    state: GraphicsState,
    stack: Vec<GraphicsState>,
    text_matrix: Matrix,
    line_matrix: Matrix,
    segments: Vec<Segment>,
}

impl<'a> Extractor<'a> {
    fn new(doc: &'a Document) -> Self {
        Extractor {
            doc,
            fonts: Vec::new(),
            font_ids: HashMap::new(),
            operations: 0,
            page: 0,
        }
    }

    fn page_text(&mut self, page_id: ObjectId, number: u32) -> Result<String> {
        self.operations = 0;
        self.page = number;
        let resources = self.page_resources(page_id);
        let Ok(content) = self.doc.get_and_decode_page_content(page_id) else {
            // A page whose content does not parse has no text to offer; the
            // others still do.
            return Ok(String::new());
        };
        let mut run = Run {
            state: GraphicsState::default(),
            stack: Vec::new(),
            text_matrix: IDENTITY,
            line_matrix: IDENTITY,
            segments: Vec::new(),
        };
        let mut visited = HashSet::new();
        self.interpret(&content, &resources, &mut run, 0, &mut visited)?;
        Ok(layout_page(run.segments))
    }

    fn page_resources(&self, page_id: ObjectId) -> Resources<'a> {
        let mut out = Vec::new();
        if let Ok((inline, ids)) = self.doc.get_page_resources(page_id) {
            out.extend(inline);
            out.extend(
                ids.into_iter()
                    .filter_map(|id| self.doc.get_dictionary(id).ok()),
            );
        }
        out
    }

    /// The object `name` names in the `category` (`Font`, `XObject`) of the
    /// nearest resource dictionary that has it.
    fn resource(
        &self,
        resources: &Resources<'a>,
        category: &[u8],
        name: &[u8],
    ) -> Option<(Option<ObjectId>, &'a Object)> {
        resources.iter().find_map(|dict| {
            let entries = dict
                .get(category)
                .ok()
                .and_then(|o| deref_dict(self.doc, o))?;
            let entry = entries.get(name).ok()?;
            self.doc.dereference(entry).ok()
        })
    }

    fn font(&mut self, resources: &Resources<'a>, name: &[u8]) -> Option<usize> {
        let (id, object) = self.resource(resources, b"Font", name)?;
        if let Some(index) = id.and_then(|id| self.font_ids.get(&id)) {
            return Some(*index);
        }
        let dict = object.as_dict().ok()?;
        self.fonts.push(FontInfo::new(self.doc, dict));
        let index = self.fonts.len() - 1;
        if let Some(id) = id {
            self.font_ids.insert(id, index);
        }
        Some(index)
    }

    fn interpret(
        &mut self,
        content: &Content,
        resources: &Resources<'a>,
        run: &mut Run,
        depth: usize,
        visited: &mut HashSet<ObjectId>,
    ) -> Result<()> {
        for op in &content.operations {
            self.operations += 1;
            if self.operations > MAX_OPERATIONS {
                return Err(PdfError::Backend(format!(
                    "text: page {} has more than {MAX_OPERATIONS} drawing operations",
                    self.page
                )));
            }
            let nums: Vec<f32> = op
                .operands
                .iter()
                .filter_map(|o| o.as_float().ok())
                .collect();
            let num = |i: usize| nums.get(i).copied().unwrap_or(0.0);
            match op.operator.as_str() {
                "q" => run.stack.push(run.state.clone()),
                "Q" => {
                    if let Some(saved) = run.stack.pop() {
                        run.state = saved;
                    }
                }
                "cm" if nums.len() == 6 => {
                    let m = [nums[0], nums[1], nums[2], nums[3], nums[4], nums[5]];
                    run.state.ctm = mul(&m, &run.state.ctm);
                }
                "BT" => {
                    run.text_matrix = IDENTITY;
                    run.line_matrix = IDENTITY;
                }
                "Tf" => {
                    run.state.font = op
                        .operands
                        .first()
                        .and_then(|o| o.as_name().ok())
                        .and_then(|name| self.font(resources, name));
                    run.state.size = op
                        .operands
                        .get(1)
                        .and_then(|o| o.as_float().ok())
                        .unwrap_or(0.0);
                }
                "Tc" => run.state.char_spacing = num(0),
                "Tw" => run.state.word_spacing = num(0),
                "Tz" => run.state.horizontal_scale = num(0) / 100.0,
                "TL" => run.state.leading = num(0),
                "Ts" => run.state.rise = num(0),
                "Td" => move_line(run, num(0), num(1)),
                "TD" => {
                    run.state.leading = -num(1);
                    move_line(run, num(0), num(1));
                }
                "Tm" if nums.len() == 6 => {
                    let m = [nums[0], nums[1], nums[2], nums[3], nums[4], nums[5]];
                    run.text_matrix = m;
                    run.line_matrix = m;
                }
                "T*" => next_line(run),
                "Tj" => {
                    if let Some(Object::String(bytes, _)) = op.operands.first() {
                        self.show(run, bytes);
                    }
                }
                "'" => {
                    next_line(run);
                    if let Some(Object::String(bytes, _)) = op.operands.first() {
                        self.show(run, bytes);
                    }
                }
                "\"" => {
                    run.state.word_spacing = num(0);
                    run.state.char_spacing = num(1);
                    next_line(run);
                    if let Some(Object::String(bytes, _)) = op.operands.get(2) {
                        self.show(run, bytes);
                    }
                }
                "TJ" => {
                    if let Some(Object::Array(items)) = op.operands.first() {
                        for item in items {
                            match item {
                                Object::String(bytes, _) => self.show(run, bytes),
                                other => {
                                    if let Ok(adjust) = other.as_float() {
                                        let tx = -adjust / 1000.0
                                            * run.state.size
                                            * run.state.horizontal_scale;
                                        run.text_matrix =
                                            mul(&translate(tx, 0.0), &run.text_matrix);
                                    }
                                }
                            }
                        }
                    }
                }
                "Do" => {
                    if let Some(name) = op.operands.first().and_then(|o| o.as_name().ok()) {
                        self.form(name, resources, run, depth, visited)?;
                    }
                }
                _ => {}
            }
        }
        Ok(())
    }

    /// `Do` on a Form XObject: its content, in its own coordinate system and
    /// with its own resources (or the caller's, when it has none).
    fn form(
        &mut self,
        name: &[u8],
        resources: &Resources<'a>,
        run: &mut Run,
        depth: usize,
        visited: &mut HashSet<ObjectId>,
    ) -> Result<()> {
        if depth >= MAX_FORM_DEPTH {
            return Ok(());
        }
        let Some((id, object)) = self.resource(resources, b"XObject", name) else {
            return Ok(());
        };
        let Ok(stream) = object.as_stream() else {
            return Ok(());
        };
        if stream.dict.get(b"Subtype").and_then(Object::as_name).ok() != Some(b"Form") {
            return Ok(());
        }
        // A form drawing itself, directly or through another, is drawn once
        // per branch.
        if let Some(id) = id {
            if !visited.insert(id) {
                return Ok(());
            }
        }
        let Some(content) = stream
            .get_plain_content()
            .ok()
            .and_then(|bytes| Content::decode(&bytes).ok())
        else {
            return Ok(());
        };
        let matrix: Matrix = stream
            .dict
            .get(b"Matrix")
            .and_then(Object::as_array)
            .ok()
            .and_then(|m| {
                let v: Vec<f32> = m.iter().filter_map(|o| o.as_float().ok()).collect();
                (v.len() == 6).then(|| [v[0], v[1], v[2], v[3], v[4], v[5]])
            })
            .unwrap_or(IDENTITY);
        let form_resources: Resources<'a> = match stream
            .dict
            .get(b"Resources")
            .ok()
            .and_then(|o| deref_dict(self.doc, o))
        {
            Some(own) => vec![own],
            None => resources.clone(),
        };

        let saved_state = run.state.clone();
        let saved_depth = run.stack.len();
        let saved_text = (run.text_matrix, run.line_matrix);
        run.state.ctm = mul(&matrix, &run.state.ctm);
        let result = self.interpret(&content, &form_resources, run, depth + 1, visited);
        run.state = saved_state;
        run.stack.truncate(saved_depth);
        (run.text_matrix, run.line_matrix) = saved_text;
        if let Some(id) = id {
            visited.remove(&id);
        }
        result
    }

    /// Show `bytes` with the current font: record where the string lands and
    /// move the text matrix past it.
    fn show(&mut self, run: &mut Run, bytes: &[u8]) {
        let state = &run.state;
        let Some(font) = state.font.and_then(|i| self.fonts.get(i)) else {
            return;
        };
        let text = font.decode(bytes);

        let codes: Vec<u32> = if font.two_byte {
            bytes
                .chunks(2)
                .map(|pair| match pair {
                    [hi, lo] => u32::from(*hi) << 8 | u32::from(*lo),
                    [one] => u32::from(*one),
                    _ => 0,
                })
                .collect()
        } else {
            bytes.iter().map(|b| u32::from(*b)).collect()
        };
        let mut advance = 0.0;
        for code in codes {
            let width = font.widths.get(code) * font.scale;
            let word = if !font.two_byte && code == 32 {
                state.word_spacing
            } else {
                0.0
            };
            advance += (width * state.size + state.char_spacing + word) * state.horizontal_scale;
        }

        let device = mul(&run.text_matrix, &state.ctm);
        let (x0, y) = apply(&device, 0.0, state.rise);
        let (x1, _) = apply(&device, advance, state.rise);
        let size = state.size * device[2].hypot(device[3]);
        run.text_matrix = mul(&translate(advance, 0.0), &run.text_matrix);

        if text.trim().is_empty() || !x0.is_finite() || !y.is_finite() {
            return;
        }
        run.segments.push(Segment {
            x0: x0.min(x1),
            x1: x0.max(x1),
            y,
            size: if size.is_finite() && size > 0.0 {
                size
            } else {
                1.0
            },
            text,
        });
    }
}

fn move_line(run: &mut Run, x: f32, y: f32) {
    run.line_matrix = mul(&translate(x, y), &run.line_matrix);
    run.text_matrix = run.line_matrix;
}

fn next_line(run: &mut Run) {
    let leading = run.state.leading;
    move_line(run, 0.0, -leading);
}

// --- page reconstruction ----------------------------------------------------------

/// The text of a page from where its strings landed: lines top to bottom,
/// strings left to right on each line, a space where a gap shows one, and an
/// empty line where the vertical gap is a paragraph's rather than a line's.
pub(crate) fn layout_page(mut segments: Vec<Segment>) -> String {
    segments.sort_by(|a, b| b.y.total_cmp(&a.y).then(a.x0.total_cmp(&b.x0)));

    // Group into lines: a string belongs to the line whose baseline is within
    // half its size.
    let mut lines: Vec<(f32, f32, Vec<Segment>)> = Vec::new();
    for segment in segments {
        match lines.last_mut() {
            Some((baseline, size, members))
                if (*baseline - segment.y).abs() <= 0.5 * size.max(segment.size) =>
            {
                *size = size.max(segment.size);
                members.push(segment);
            }
            _ => lines.push((segment.y, segment.size, vec![segment])),
        }
    }

    let mut out = String::new();
    let mut previous: Option<(f32, f32)> = None;
    for (baseline, size, mut members) in lines {
        members.sort_by(|a, b| a.x0.total_cmp(&b.x0));
        let mut line = String::new();
        let mut end = f32::NEG_INFINITY;
        for segment in members {
            let gap = segment.x0 - end;
            let starts_blank = segment.text.starts_with(char::is_whitespace);
            if !line.is_empty()
                && gap > 0.25 * segment.size
                && !line.ends_with(char::is_whitespace)
                && !starts_blank
            {
                line.push(' ');
            }
            line.push_str(&segment.text);
            end = end.max(segment.x1);
        }
        let line = clean_line(&line);
        if line.is_empty() {
            continue;
        }
        if let Some((previous_baseline, previous_size)) = previous {
            out.push('\n');
            if previous_baseline - baseline > 1.9 * previous_size.max(size) {
                out.push('\n');
            }
        }
        out.push_str(&line);
        previous = Some((baseline, size));
    }
    out
}

/// One line as text: ligatures spelt out, control characters dropped,
/// trailing blanks trimmed.
fn clean_line(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    for c in line.chars() {
        match c {
            '\u{FB00}' => out.push_str("ff"),
            '\u{FB01}' => out.push_str("fi"),
            '\u{FB02}' => out.push_str("fl"),
            '\u{FB03}' => out.push_str("ffi"),
            '\u{FB04}' => out.push_str("ffl"),
            '\u{FB05}' | '\u{FB06}' => out.push_str("st"),
            '\t' => out.push(' '),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    out.trim_end().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seg(x0: f32, x1: f32, y: f32, text: &str) -> Segment {
        Segment {
            x0,
            x1,
            y,
            size: 10.0,
            text: text.to_string(),
        }
    }

    #[test]
    fn strings_on_one_baseline_are_one_line_in_x_order() {
        let text = layout_page(vec![
            seg(60.0, 90.0, 700.0, "world"),
            seg(10.0, 40.0, 700.0, "Hello"),
        ]);
        assert_eq!(text, "Hello world");
    }

    #[test]
    fn a_kerning_gap_is_not_a_space() {
        let text = layout_page(vec![
            seg(10.0, 30.0, 700.0, "Wa"),
            seg(31.0, 50.0, 700.0, "ter"),
        ]);
        assert_eq!(text, "Water");
    }

    #[test]
    fn a_small_baseline_shift_stays_on_the_line() {
        let text = layout_page(vec![
            seg(10.0, 30.0, 700.0, "x"),
            seg(30.5, 35.0, 703.0, "2"),
        ]);
        assert_eq!(text, "x2");
    }

    #[test]
    fn lines_go_top_to_bottom_and_a_wide_gap_is_a_paragraph() {
        let text = layout_page(vec![
            seg(10.0, 50.0, 650.0, "third"),
            seg(10.0, 50.0, 700.0, "first"),
            seg(10.0, 50.0, 688.0, "second"),
        ]);
        assert_eq!(text, "first\nsecond\n\nthird");
    }

    #[test]
    fn ligatures_are_spelt_out_and_trailing_blanks_trimmed() {
        let text = layout_page(vec![seg(10.0, 50.0, 700.0, "\u{FB01}nal  ")]);
        assert_eq!(text, "final");
    }

    #[test]
    fn matrices_compose_in_pdf_order() {
        let scale = [2.0, 0.0, 0.0, 2.0, 0.0, 0.0];
        let moved = mul(&translate(10.0, 0.0), &scale);
        assert_eq!(apply(&moved, 1.0, 1.0), (22.0, 2.0));
    }

    #[test]
    fn garbage_is_an_error_not_a_panic() {
        assert!(extract_text(b"not a pdf", None).is_err());
        assert!(extract_text(b"%PDF-1.7\n1 0 obj << /Type /Catalog", None).is_err());
    }
}
