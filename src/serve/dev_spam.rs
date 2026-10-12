//! The spam dashboard at `/__soli/spam`: what `spam_check(req)` refused, what
//! it let through, and the model it scores with.
//!
//! A mistake is corrected here — "not spam" on a refused post, "spam" on an
//! accepted one — and each correction trains the model, which is how the
//! score learns this application's own traffic.
//!
//! Behind [`admin_auth`] like the errors page: open in `--dev` to a local
//! request; otherwise served only when `SOLI_SPAM_USER` +
//! `SOLI_SPAM_PASSWORD`, `SOLI_SPAM_TOKEN` or the shared `SOLI_ADMIN_*` are
//! set, and 404 when none is. The action forms are same-origin POSTs, which
//! the Origin/Referer gate checks.

use hyper::{header::HeaderMap, Response, StatusCode};

use crate::interpreter::builtins::server::parse_query_string;

use super::dev_errors::{html_status, relative};
use super::operator_shell::{self, Section};
use super::spam;
use super::{admin_auth, dev_bar, full, html_ok, Bytes, ResponseBody};

pub(super) const BASE: &str = "/__soli/spam";

/// Submissions listed per tab.
const LIST_LIMIT: usize = 200;

/// Characters of a submission shown in the list.
const PREVIEW_CHARS: usize = 240;

fn esc(value: &str) -> String {
    dev_bar::html_escape(value)
}

fn str_field<'a>(row: &'a serde_json::Value, field: &str) -> &'a str {
    row.get(field).and_then(|v| v.as_str()).unwrap_or("")
}

fn spam_page(title: &str, body: &str) -> String {
    operator_shell::page(
        Section::Spam,
        title,
        "Posts checked by <code>spam_check(req)</code>: refused ones, and accepted ones. \
Correct a mistake here and the model learns from it.",
        body,
    )
}

/// Decide whether this request is the spam dashboard (any method).
pub(crate) fn is_spam_dashboard_path(method: &str, path: &str) -> bool {
    if path == BASE {
        return method == "GET" || method == "HEAD";
    }
    let Some(rest) = path.strip_prefix("/__soli/spam/") else {
        return false;
    };
    !rest.is_empty() && matches!(method, "GET" | "HEAD" | "POST")
}

/// Serve `/__soli/spam` when the path matches. `None` if this is not a
/// dashboard request. Production without credentials is a plain 404.
pub(crate) fn dispatch(
    method: &str,
    path: &str,
    query: Option<&str>,
    headers: &HeaderMap,
    dev_mode: bool,
    peer_ip: std::net::IpAddr,
) -> Option<Response<ResponseBody>> {
    if !is_spam_dashboard_path(method, path) {
        return None;
    }
    let decision = admin_auth::authorize(headers, dev_mode, peer_ip, "SPAM");
    if let Some(refused) = admin_auth::refusal(decision, "Soli spam") {
        return Some(refused);
    }
    if path == BASE {
        return Some(handle_index(query));
    }
    let rest = path.strip_prefix("/__soli/spam/").unwrap_or("");
    if method == "POST" {
        return Some(handle_action(rest));
    }
    Some(handle_show(rest))
}

fn status_from_query(query: Option<&str>) -> &'static str {
    let wanted = query
        .map(parse_query_string)
        .and_then(|params| params.get("status").cloned())
        .unwrap_or_default();
    if wanted == "ham" {
        "ham"
    } else {
        "spam"
    }
}

fn tabs(current: &str) -> String {
    let tab = |status: &str, label: &str| {
        let on = if status == current { " on" } else { "" };
        format!("<a class=\"tab{on}\" href=\"{BASE}?status={status}\">{label}</a>")
    };
    format!(
        "<nav class=\"tabs\">{}{}</nav>",
        tab("spam", "refused"),
        tab("ham", "accepted")
    )
}

fn model_panel() -> String {
    let (spam_docs, ham_docs, words, trained) = spam::with_model(|model| {
        (
            model.spam_docs,
            model.ham_docs,
            model.words.len(),
            model.trained(),
        )
    });
    let state = if trained {
        format!(
            "scores posts: one at {} or more is refused",
            spam::DEFAULT_MAX_SCORE
        )
    } else {
        format!(
            "learning: it refuses nothing until it has seen {} posts of each kind",
            spam::MIN_TRAINED_DOCS
        )
    };
    format!(
        "<div class=\"panel\"><dl><dt>Model</dt><dd>{state}</dd>\
<dt>Learnt as spam</dt><dd class=\"num\">{spam_docs}</dd>\
<dt>Learnt as ham</dt><dd class=\"num\">{ham_docs}</dd>\
<dt>Words</dt><dd class=\"num\">{words}</dd></dl></div>"
    )
}

fn notices() -> String {
    let mut out = String::new();
    if !spam::enabled() {
        out.push_str(
            "<p class=\"notice\">Recording is off (<code>SOLI_SPAM=off</code>, or \
<code>APP_ENV=test</code>): posts are checked but not kept, and the model is not saved.</p>",
        );
    }
    let stats = spam::stats();
    if stats.dropped > 0 {
        out.push_str(&format!(
            "<p class=\"notice\">{} post(s) dropped since this process started: they arrived \
faster than they could be written.</p>",
            stats.dropped
        ));
    }
    if stats.failed > 0 {
        out.push_str(&format!(
            "<p class=\"notice bad\">{} write(s) failed since this process started \
(see the <code>[spam]</code> lines on stderr).</p>",
            stats.failed
        ));
    }
    out
}

fn action_form(key: &str, action: &str, label: &str, class: &str, title: &str) -> String {
    format!(
        "<form method=\"post\" action=\"{BASE}/{key}/{action}\" style=\"display:inline;margin:0;\">\
<button class=\"{class}\" type=\"submit\" title=\"{title}\">{label}</button></form>"
    )
}

fn actions_for(key: &str, status: &str) -> String {
    let flip = if status == "spam" {
        action_form(
            key,
            "ham",
            "not spam",
            "ghost",
            "File it as accepted and learn it as ham",
        )
    } else {
        action_form(
            key,
            "spam",
            "spam",
            "ghost",
            "File it as refused and learn it as spam",
        )
    };
    format!(
        "{flip} {}",
        action_form(key, "delete", "delete", "danger", "Forget this post")
    )
}

fn preview(text: &str) -> String {
    let one_line: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut out: String = one_line.chars().take(PREVIEW_CHARS).collect();
    if one_line.chars().count() > PREVIEW_CHARS {
        out.push('\u{2026}');
    }
    out
}

/// `GET /__soli/spam` — one tab of posts, newest first.
fn handle_index(query: Option<&str>) -> Response<ResponseBody> {
    let status = status_from_query(query);
    let now = chrono::Utc::now();
    let mut body = tabs(status);
    body.push_str(&notices());
    body.push_str(&model_panel());

    let rows = match spam::list(status, LIST_LIMIT) {
        Ok(rows) => rows,
        Err(e) if super::internal_store::is_missing_collection(&e) => {
            body.push_str(
                "<div class=\"empty\"><b>Nothing checked yet.</b>\
<span>Posts show up here once an action calls <code>spam_check(req)</code>.</span></div>",
            );
            return html_ok(spam_page("Spam", &body));
        }
        Err(e) => {
            body.push_str(&format!(
                "<p class=\"notice bad\">Could not read {}: {}</p>",
                spam::QUARANTINE_COLLECTION,
                esc(&e)
            ));
            return html_status(StatusCode::INTERNAL_SERVER_ERROR, spam_page("Spam", &body));
        }
    };

    if rows.is_empty() {
        body.push_str(if status == "spam" {
            "<div class=\"empty\"><b>Nothing refused.</b></div>"
        } else {
            "<div class=\"empty\"><b>Nothing accepted yet.</b></div>"
        });
        return html_ok(spam_page("Spam", &body));
    }

    body.push_str(&format!(
        "<p class=\"summary\">{} post{}{}</p><div class=\"list\">",
        rows.len(),
        if rows.len() == 1 { "" } else { "s" },
        if rows.len() >= LIST_LIMIT {
            " (the newest)"
        } else {
            ""
        }
    ));
    for row in &rows {
        let key = str_field(row, "_key");
        if !spam::valid_key(key) {
            continue;
        }
        let reason = str_field(row, "reason");
        let tag = if reason.is_empty() {
            String::new()
        } else {
            format!("<span class=\"tag\">{}</span>", esc(reason))
        };
        let score = row.get("score").and_then(|v| v.as_f64()).unwrap_or(0.5);
        let created = str_field(row, "created_at");
        body.push_str(&format!(
            "<article class=\"row\">\
<div class=\"main\"><a class=\"msg\" href=\"{BASE}/{key}\">{text}</a>\
<div class=\"meta\">{tag}<span class=\"req\">{path}</span><span class=\"mono\">{ip}</span>\
<span>score {score:.2}</span></div></div>\
<div class=\"when\"><span title=\"{created_iso}\">{created_rel}</span></div>\
<div class=\"actions\">{actions}</div></article>",
            text = esc(&preview(str_field(row, "text"))),
            path = esc(str_field(row, "path")),
            ip = esc(str_field(row, "ip")),
            created_iso = esc(created),
            created_rel = esc(&relative(created, now)),
            actions = actions_for(key, status),
        ));
    }
    body.push_str("</div>");
    html_ok(spam_page("Spam", &body))
}

/// `GET /__soli/spam/:key` — one post, every field.
fn handle_show(key: &str) -> Response<ResponseBody> {
    if !spam::valid_key(key) {
        return not_found("No such post.");
    }
    let row = match spam::get(key) {
        Ok(Some(row)) => row,
        Ok(None) => return not_found("No such post."),
        Err(e) => {
            return html_status(
                StatusCode::INTERNAL_SERVER_ERROR,
                spam_page("Post", &format!("<p class=\"err\">{}</p>", esc(&e))),
            )
        }
    };
    let status = str_field(&row, "status");
    let now = chrono::Utc::now();
    let created = str_field(&row, "created_at");
    let reason = str_field(&row, "reason");
    let mut body = format!(
        "<div class=\"bar\"><a href=\"{BASE}?status={status}\">\u{2190} back</a>\
<span class=\"grow\"></span><span class=\"actions\">{actions}</span></div>\
<div class=\"panel\"><dl><dt>Status</dt><dd>{status_label}</dd>\
<dt>Reason</dt><dd>{reason}</dd><dt>Score</dt><dd>{score:.3}</dd>\
<dt>Path</dt><dd class=\"mono\">{path}</dd><dt>Client</dt><dd class=\"mono\">{ip}</dd>\
<dt>When</dt><dd>{created_rel} <span class=\"muted mono\">{created_iso}</span></dd></dl></div>",
        actions = actions_for(key, status),
        status_label = if status == "spam" {
            "refused"
        } else {
            "accepted"
        },
        reason = if reason.is_empty() {
            "\u{2014}".to_string()
        } else {
            esc(reason)
        },
        score = row.get("score").and_then(|v| v.as_f64()).unwrap_or(0.5),
        path = esc(str_field(&row, "path")),
        ip = esc(str_field(&row, "ip")),
        created_rel = esc(&relative(created, now)),
        created_iso = esc(created),
    );
    if let Some(fields) = row.get("fields").and_then(|f| f.as_object()) {
        body.push_str("<h3>Fields</h3><div class=\"panel\"><dl>");
        for (name, value) in fields {
            body.push_str(&format!(
                "<dt class=\"mono\">{}</dt><dd><pre>{}</pre></dd>",
                esc(name),
                esc(value.as_str().unwrap_or(&value.to_string()))
            ));
        }
        body.push_str("</dl></div>");
    }
    html_ok(spam_page("Post", &body))
}

/// `POST /__soli/spam/:key/{spam,ham,delete}`.
fn handle_action(rest: &str) -> Response<ResponseBody> {
    let Some((key, action)) = rest.split_once('/') else {
        return not_found("Unknown action.");
    };
    if !spam::valid_key(key) {
        return not_found("No such post.");
    }
    let (result, back) = match action {
        "spam" => (spam::mark(key, "spam"), "ham"),
        "ham" => (spam::mark(key, "ham"), "spam"),
        "delete" => (spam::delete(key), "spam"),
        _ => return not_found("Unknown action."),
    };
    match result {
        Ok(true) => Response::builder()
            .status(StatusCode::SEE_OTHER)
            .header("Location", format!("{BASE}?status={back}"))
            .body(full(Bytes::new()))
            .unwrap(),
        Ok(false) => not_found("No such post."),
        Err(e) => html_status(
            StatusCode::INTERNAL_SERVER_ERROR,
            spam_page(
                "Spam",
                &format!(
                    "<p class=\"err\">{}</p><p><a href=\"{BASE}\">back</a></p>",
                    esc(&e)
                ),
            ),
        ),
    }
}

fn not_found(message: &str) -> Response<ResponseBody> {
    Response::builder()
        .status(StatusCode::NOT_FOUND)
        .header("Content-Type", "text/html; charset=utf-8")
        .body(full(Bytes::from(spam_page(
            "Spam",
            &format!(
                "<p class=\"err\">{}</p><p><a href=\"{BASE}\">back to spam</a></p>",
                esc(message)
            ),
        ))))
        .unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_dashboard_paths_are_recognised() {
        assert!(is_spam_dashboard_path("GET", "/__soli/spam"));
        assert!(!is_spam_dashboard_path("POST", "/__soli/spam"));
        assert!(is_spam_dashboard_path("GET", "/__soli/spam/0123"));
        assert!(is_spam_dashboard_path("POST", "/__soli/spam/0123/ham"));
        assert!(!is_spam_dashboard_path("GET", "/__soli/spam/"));
        assert!(!is_spam_dashboard_path("GET", "/__soli/spammer"));
        assert!(!is_spam_dashboard_path("DELETE", "/__soli/spam/0123"));
    }

    #[test]
    fn the_tab_defaults_to_refused() {
        assert_eq!(status_from_query(None), "spam");
        assert_eq!(status_from_query(Some("status=ham")), "ham");
        assert_eq!(status_from_query(Some("status=../x")), "spam");
    }

    #[test]
    fn previews_are_one_line_and_bounded() {
        assert_eq!(preview("a\n\n  b"), "a b");
        let long = "x".repeat(PREVIEW_CHARS + 10);
        assert_eq!(preview(&long).chars().count(), PREVIEW_CHARS + 1);
    }

    #[test]
    fn a_refused_post_offers_not_spam_and_an_accepted_one_spam() {
        let key = "0123456789abcdef0123456789abcdef";
        assert!(actions_for(key, "spam").contains("/ham\""));
        assert!(actions_for(key, "ham").contains("/spam\""));
        assert!(actions_for(key, "ham").contains("/delete\""));
    }
}
