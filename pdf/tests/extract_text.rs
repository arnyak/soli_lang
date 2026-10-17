//! `extract_text`: the text of PDFs this crate renders, read back.
//!
//! The repository carries no `.pdf` fixture, so every input is rendered here
//! with the bundled `titillium` font.

use std::time::Duration;

use soli_pdf::{extract_text, render_to_bytes, EncryptOptions, RenderOptions};

fn opts() -> RenderOptions {
    RenderOptions {
        fetch_images: false,
        http_timeout: Duration::from_secs(1),
        font_dirs: vec!["fonts".into()],
        ..Default::default()
    }
}

fn render_with(template: &str, opts: &RenderOptions) -> Vec<u8> {
    render_to_bytes(template.as_bytes(), b"{}", opts).expect("render")
}

fn render(template: &str) -> Vec<u8> {
    render_with(template, &opts())
}

fn paragraphs(values: &[&str]) -> String {
    let items: Vec<String> = values
        .iter()
        .map(|v| {
            if *v == "---" {
                r#"{ "type": "page_break" }"#.to_string()
            } else {
                format!(r#"{{ "type": "paragraph", "value": "{v}" }}"#)
            }
        })
        .collect();
    format!(
        r#"{{ "fonts": ["titillium"], "content": [{}] }}"#,
        items.join(",")
    )
}

#[test]
fn paragraphs_come_back_in_order_with_their_spaces() {
    let pdf = render(&paragraphs(&["Invoice number 42", "Total due: 120.00 EUR"]));
    let pages = extract_text(&pdf, None).expect("text");
    assert_eq!(pages.len(), 1);
    let lines: Vec<&str> = pages[0].lines().filter(|l| !l.is_empty()).collect();
    assert_eq!(lines, ["Invoice number 42", "Total due: 120.00 EUR"]);
}

#[test]
fn a_wrapped_paragraph_keeps_its_words_apart() {
    let words = "lorem ipsum dolor sit amet consectetur adipiscing elit ".repeat(12);
    let pdf = render(&paragraphs(&[words.trim()]));
    let text = extract_text(&pdf, None).expect("text").join("\n");
    let joined: Vec<&str> = text.split_whitespace().collect();
    assert_eq!(joined, words.split_whitespace().collect::<Vec<_>>());
    assert!(text.lines().count() > 1, "a long paragraph wraps: {text:?}");
}

#[test]
fn one_string_per_page_and_a_page_selection() {
    let pdf = render(&paragraphs(&[
        "first page",
        "---",
        "second page",
        "---",
        "third page",
    ]));
    let pages = extract_text(&pdf, None).expect("text");
    assert_eq!(pages, ["first page", "second page", "third page"]);
    assert_eq!(
        extract_text(&pdf, Some(&[3, 1])).expect("text"),
        ["third page", "first page"]
    );
    let err = extract_text(&pdf, Some(&[4])).expect_err("no page 4");
    assert!(err.to_string().contains("page 4 does not exist"), "{err}");
}

#[test]
fn letterhead_text_drawn_through_a_form_xobject_is_read() {
    let letterhead = render(&paragraphs(&["ACME Letterhead"]));
    let mut o = opts();
    o.stationery = Some(letterhead);
    let pdf = render_with(&paragraphs(&["Body text"]), &o);
    let text = extract_text(&pdf, None).expect("text").join("\n");
    assert!(text.contains("ACME Letterhead"), "{text:?}");
    assert!(text.contains("Body text"), "{text:?}");
}

#[test]
fn an_empty_user_password_opens_and_a_real_one_does_not() {
    let mut o = opts();
    o.encrypt = Some(EncryptOptions {
        user_password: String::new(),
        owner_password: "owner-secret".into(),
        allow: vec![],
    });
    let open = render_with(&paragraphs(&["readable"]), &o);
    assert_eq!(extract_text(&open, None).expect("text"), ["readable"]);

    o.encrypt = Some(EncryptOptions {
        user_password: "user-secret".into(),
        owner_password: "owner-secret".into(),
        allow: vec![],
    });
    let locked = render_with(&paragraphs(&["hidden"]), &o);
    let err = extract_text(&locked, None).expect_err("locked");
    assert!(err.to_string().contains("encrypted"), "{err}");
}

#[test]
fn a_truncated_file_is_an_error_not_a_panic() {
    let pdf = render(&paragraphs(&["cut short"]));
    for len in [10, pdf.len() / 3, pdf.len() / 2, pdf.len() - 20] {
        let _ = extract_text(&pdf[..len], None);
    }
}
