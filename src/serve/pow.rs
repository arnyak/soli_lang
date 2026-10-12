//! The proof-of-work client: ships `pow.js` at `/__soli/pow.js`, injected only
//! into pages that carry a challenge. The gate is the markup itself: the
//! `data-soli-pow` attribute that `pow_field()` emits.
//!
//! What the challenge is and how a solution is verified: `serve::spam`.

use bytes::Bytes;
use http_body_util::Full;
use hyper::Response;

use crate::serve::prefetch;

/// Client JS — compiled into the binary, like `nav.js`.
pub const POW_SCRIPT: &str = include_str!("pow.js");

/// Makes injection idempotent when a body is rewrapped.
const INJECTED_MARKER: &str = "__soli_pow_injected";

/// The attribute that turns the script on for a page.
const POW_ATTR: &str = "data-soli-pow";

fn pow_hash() -> u64 {
    use std::sync::OnceLock;
    static HASH: OnceLock<u64> = OnceLock::new();
    *HASH.get_or_init(|| prefetch::fnv1a_64(POW_SCRIPT.as_bytes()))
}

/// Does this page carry a proof-of-work challenge?
pub fn page_uses_pow(html: &str) -> bool {
    html.contains(POW_ATTR)
}

fn pow_tag() -> String {
    format!(
        "<!-- {} --><script src=\"/__soli/pow.js?v={:016x}\" defer></script>",
        INJECTED_MARKER,
        pow_hash()
    )
}

/// Insert the proof-of-work `<script>` before `</body>` — or `</html>`, or at
/// the end — when the page needs it.
pub fn inject_pow_tag(html: impl Into<String>) -> String {
    let html: String = html.into();
    if !page_uses_pow(&html) || html.contains(INJECTED_MARKER) {
        return html;
    }
    prefetch::insert_before_body_close(html, &pow_tag())
}

/// `GET /__soli/pow.js`.
pub fn handle_pow_js() -> Response<Full<Bytes>> {
    Response::builder()
        .status(200)
        .header("Content-Type", "application/javascript; charset=utf-8")
        .header("Cache-Control", "public, max-age=86400, immutable")
        .body(Full::new(Bytes::from_static(POW_SCRIPT.as_bytes())))
        .unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_pages_with_a_challenge_get_the_script() {
        let plain = "<html><body><form></form></body></html>";
        assert_eq!(inject_pow_tag(plain), plain);

        let with = "<html><body><input data-soli-pow=\"x\"></body></html>";
        let injected = inject_pow_tag(with);
        assert!(injected.contains("/__soli/pow.js?v="));
        assert!(injected.find("pow.js").unwrap() < injected.find("</body>").unwrap());
        // Idempotent.
        assert_eq!(inject_pow_tag(injected.clone()), injected);
    }

    #[test]
    fn the_script_is_served_as_cacheable_javascript() {
        let response = handle_pow_js();
        assert_eq!(response.status(), 200);
        assert_eq!(
            response.headers()["Content-Type"],
            "application/javascript; charset=utf-8"
        );
        assert!(response.headers()["Cache-Control"]
            .to_str()
            .unwrap()
            .contains("immutable"));
    }
}
