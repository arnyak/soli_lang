//! The catalogue's score engraver, native (`eui-score`).
//!
//! `score()` and the score editor of the catalogue (`eui_builders_score.sl`)
//! engrave LilyPond's input into canvas paths. The Soli engraver that does it
//! is the reference, and `eui-score` is the same engraver in Rust, held to it
//! to the hundredth of a pixel by that crate's golden tests — some hundred
//! times faster, which is the difference between an edit that redraws a
//! symphony in a frame and one that takes a fifth of a second. These are
//! its doors:
//!
//! - `eui_score_layout(src, width, layout)` engraves and answers what a view
//!   reads to place things and hit-test them: the systems, their pages and
//!   tops, and each bar's items with their numbers, x and heads. The engraving
//!   itself stays here, keyed by its source and layout.
//! - `eui_score_bands(laid, sp, opts, total)` draws a page of it as bands,
//!   one canvas each (`score_bands`), with `opts["marks"]` lighting items.
//! - `eui_score_midi(src, opts)` and `eui_score_pdf(src, title)` write the
//!   files, byte for byte as the Soli functions do.
//!
//! A source the engraver cannot set is refused with the engraver's message,
//! "score: … (at character N)": `eui_score_layout` answers it as
//! `{"error": message}`, which the catalogue throws as the Soli engraver
//! throws it — a native function's error would carry the call's position
//! after it, and the editor shows the message to the person. The other
//! three fail with it as an error.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex, OnceLock};

use eui_score::{Engraved, Layout, MidiOptions, Path};

use crate::interpreter::value::{hash_from_pairs, hash_get_value, Value};

/// The last engravings made, by source and layout: a view engraves on every
/// render, and the bands of the same engraving are asked for just after.
const KEPT: usize = 16;

struct Kept {
    order: VecDeque<String>,
    map: HashMap<String, Arc<Engraved>>,
}

fn kept() -> &'static Mutex<Kept> {
    static KEPT_ENGRAVINGS: OnceLock<Mutex<Kept>> = OnceLock::new();
    KEPT_ENGRAVINGS.get_or_init(|| {
        Mutex::new(Kept {
            order: VecDeque::new(),
            map: HashMap::new(),
        })
    })
}

fn num(v: Option<&Value>) -> Option<f64> {
    match v {
        Some(Value::Int(n)) => Some(*n as f64),
        Some(Value::Float(f)) => Some(*f),
        _ => None,
    }
}

fn get(h: &Value, key: &str) -> Option<Value> {
    match h {
        Value::Hash(pairs) => hash_get_value(&pairs.borrow(), &Value::String(key.into())).cloned(),
        _ => None,
    }
}

fn layout_of(v: &Value) -> Layout {
    let n = |k: &str| num(get(v, k).as_ref());
    Layout {
        page_h: n("page_h"),
        top: n("top"),
        bottom: n("bottom"),
        left: n("left"),
        indent: n("indent"),
        gap: n("gap"),
    }
}

fn key_of(src: &str, width: f64, l: &Layout) -> String {
    format!(
        "{width}|{:?}|{:?}|{:?}|{:?}|{:?}|{:?}|{src}",
        l.page_h, l.top, l.bottom, l.left, l.indent, l.gap
    )
}

fn engraving(src: &str, width: f64, layout: &Layout) -> Result<Arc<Engraved>, String> {
    let key = key_of(src, width, layout);
    if let Ok(k) = kept().lock() {
        if let Some(hit) = k.map.get(&key) {
            return Ok(hit.clone());
        }
    }
    let eng = Arc::new(eui_score::engrave(src, width, layout).map_err(|e| e.message)?);
    if let Ok(mut k) = kept().lock() {
        if !k.map.contains_key(&key) {
            k.order.push_back(key.clone());
            if k.order.len() > KEPT {
                if let Some(gone) = k.order.pop_front() {
                    k.map.remove(&gone);
                }
            }
        }
        k.map.insert(key, eng.clone());
    }
    Ok(eng)
}

fn string_arg(args: &[Value], at: usize, what: &str) -> Result<String, String> {
    match args.get(at) {
        Some(Value::String(s)) => Ok(s.to_string()),
        other => Err(format!(
            "{what} expects a string, got {}",
            other.map_or("nothing".to_string(), |v| v.type_name().to_string())
        )),
    }
}

fn floats(xs: &[f64]) -> Value {
    Value::Array(std::rc::Rc::new(std::cell::RefCell::new(
        xs.iter().map(|x| Value::Float(*x)).collect(),
    )))
}

fn array(xs: Vec<Value>) -> Value {
    Value::Array(std::rc::Rc::new(std::cell::RefCell::new(xs)))
}

fn bars_value(bars: &[eui_score::measure::Bar], range: std::ops::Range<usize>) -> Value {
    array(
        bars[range]
            .iter()
            .map(|bar| {
                let items = bar
                    .items
                    .iter()
                    .map(|ev| {
                        let note = ev.k == eui_score::parse::Kind::Note;
                        hash_from_pairs([
                            ("i", Value::Int(ev.i as i64)),
                            (
                                "k",
                                Value::String(if note { "note" } else { "rest" }.into()),
                            ),
                            ("x", Value::Float(ev.x)),
                            ("head_w", ev.head_w.map_or(Value::Null, Value::Float)),
                            (
                                "heads",
                                array(
                                    ev.heads
                                        .iter()
                                        .map(|h| hash_from_pairs([("pos", Value::Int(h.pos))]))
                                        .collect(),
                                ),
                            ),
                        ])
                    })
                    .collect();
                hash_from_pairs([
                    ("number", Value::Int(bar.number)),
                    ("x0", Value::Float(bar.x0)),
                    ("x1", Value::Float(bar.x1)),
                    ("items", array(items)),
                ])
            })
            .collect(),
    )
}

/// `eui_score_layout(src, width, layout)`.
pub fn layout(args: &[Value]) -> Result<Value, String> {
    let src = string_arg(args, 0, "eui_score_layout()")?;
    let width = num(args.get(1)).ok_or("eui_score_layout() expects a width in staff spaces")?;
    let laid = args.get(2).cloned().unwrap_or(Value::Null);
    let l = layout_of(&laid);
    let eng = match engraving(&src, width, &l) {
        Ok(eng) => eng,
        Err(message) => return Ok(hash_from_pairs([("error", Value::String(message.into()))])),
    };
    let systems = eng
        .systems
        .iter()
        .map(|sys| {
            let mut pairs = vec![
                ("page", Value::Int(sys.page as i64)),
                ("top", Value::Float(sys.top)),
                ("bottom", Value::Float(sys.bottom)),
                ("reach_hi", Value::Float(sys.reach_hi)),
                ("left", Value::Float(sys.left)),
                ("right", Value::Float(sys.right)),
            ];
            if sys.multi {
                pairs.push(("offsets", floats(&sys.offsets)));
                let staves = sys
                    .lines
                    .iter()
                    .enumerate()
                    .map(|(s, line)| {
                        hash_from_pairs([("bars", bars_value(&eng.staves[s], line.bars.clone()))])
                    })
                    .collect();
                pairs.push(("staves", array(staves)));
            } else if let Some(line) = sys.lines.first() {
                pairs.push(("bars", bars_value(&eng.staves[0], line.bars.clone())));
            }
            hash_from_pairs(pairs)
        })
        .collect();
    let pages = eng
        .pages
        .iter()
        .map(|pg| hash_from_pairs([("index", Value::Int(pg.index as i64))]))
        .collect();
    Ok(hash_from_pairs([
        ("native", Value::Bool(true)),
        ("src", Value::String(src.into())),
        ("width_ss", Value::Float(width)),
        ("layout", laid),
        ("systems", array(systems)),
        ("pages", array(pages)),
        ("height", Value::Float(eng.height)),
        ("width", Value::Float(eng.width)),
        ("left", Value::Float(eng.left)),
        ("paper", eng.paper.map_or(Value::Null, Value::Float)),
    ]))
}

fn path_value(p: &Path, ink: &Value) -> Value {
    match p {
        Path::Rect([x, y, w, h]) => array(vec![
            Value::Int(1),
            ink.clone(),
            Value::Float(*x),
            Value::Float(*y),
            Value::Float(*w),
            Value::Float(*h),
            Value::Int(0),
        ]),
        Path::Fill(cmds) => {
            let mut out = Vec::with_capacity(cmds.len() + 2);
            out.push(Value::Int(5));
            out.push(ink.clone());
            let mut k = 0;
            while k < cmds.len() {
                let c = cmds[k];
                out.push(Value::Int(c as i64));
                let args = match c as i64 {
                    0 | 1 => 2,
                    2 => 4,
                    3 => 6,
                    _ => 0,
                };
                for v in cmds.iter().skip(k + 1).take(args) {
                    out.push(Value::Float(*v));
                }
                k += 1 + args;
            }
            array(out)
        }
    }
}

/// `eui_score_bands(laid, sp, opts, total)`: `laid` is what
/// `eui_score_layout` answered; `opts` takes "colour", "marks" (an item's
/// number, as a string, to the role it is lit in) and "page_index". Each
/// band answers its `paths` in the plain ink and, apart, a copy of its lit
/// items' paths in their colours (`lit`), which the catalogue lays over it:
/// the playhead changes `lit` and leaves the band as it was.
pub fn bands(args: &[Value]) -> Result<Value, String> {
    let laid = args.first().cloned().unwrap_or(Value::Null);
    let src = match get(&laid, "src") {
        Some(Value::String(s)) => s.to_string(),
        _ => return Err("eui_score_bands() expects what eui_score_layout() answered".into()),
    };
    let width = num(get(&laid, "width_ss").as_ref()).unwrap_or(75.0);
    let l = layout_of(&get(&laid, "layout").unwrap_or(Value::Null));
    let sp = num(args.get(1)).ok_or("eui_score_bands() expects px a staff space")?;
    let opts = args.get(2).cloned().unwrap_or(Value::Null);
    let total = num(args.get(3)).unwrap_or(0.0) as i64;
    let ink = get(&opts, "colour").unwrap_or_else(|| Value::String("text.default".into()));
    let page = num(get(&opts, "page_index").as_ref())
        .unwrap_or(0.0)
        .max(0.0) as usize;
    let marks: HashMap<String, Value> = match get(&opts, "marks") {
        Some(Value::Hash(pairs)) => pairs
            .borrow()
            .iter()
            .map(|(k, v)| (k.to_string(), v.clone()))
            .collect(),
        _ => HashMap::new(),
    };
    let eng = engraving(&src, width, &l)?;
    let bands = eui_score::bands(&eng, sp, page, total).map_err(|e| e.message)?;
    let out = bands
        .iter()
        .map(|bd| {
            let mut lit = Vec::new();
            for (item, range) in &bd.ranges {
                if let Some(colour) = marks.get(&item.to_string()) {
                    lit.extend(
                        bd.paths
                            .get(range.clone())
                            .unwrap_or(&[])
                            .iter()
                            .map(|p| path_value(p, colour)),
                    );
                }
            }
            let paths = bd.paths.iter().map(|p| path_value(p, &ink)).collect();
            hash_from_pairs([
                ("y", Value::Int(bd.y)),
                ("h", Value::Int(bd.h)),
                ("paths", array(paths)),
                ("lit", array(lit)),
            ])
        })
        .collect();
    Ok(array(out))
}

/// `eui_score_midi(src, opts)`: "bpm" and "beat" for a source with no
/// `\tempo`, "program" for a staff that names no instrument.
pub fn midi(args: &[Value]) -> Result<Value, String> {
    let src = string_arg(args, 0, "eui_score_midi()")?;
    let opts = args.get(1).cloned().unwrap_or(Value::Null);
    let d = MidiOptions::default();
    let o = MidiOptions {
        bpm: num(get(&opts, "bpm").as_ref()).unwrap_or(d.bpm),
        beat: num(get(&opts, "beat").as_ref()).map_or(d.beat, |b| b as i64),
        program: num(get(&opts, "program").as_ref()).map_or(d.program, |p| p as i64),
    };
    let bytes = eui_score::midi(&src, &o).map_err(|e| e.message)?;
    Ok(array(
        bytes.into_iter().map(|b| Value::Int(b as i64)).collect(),
    ))
}

/// `eui_score_pdf(src, title)`: the A4 pages; `title` for a source whose
/// header names none.
pub fn pdf(args: &[Value]) -> Result<Value, String> {
    let src = string_arg(args, 0, "eui_score_pdf()")?;
    let title = match args.get(1) {
        Some(Value::String(s)) => s.to_string(),
        _ => String::new(),
    };
    Ok(Value::String(
        eui_score::pdf(&src, &title).map_err(|e| e.message)?.into(),
    ))
}
