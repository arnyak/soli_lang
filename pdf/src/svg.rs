//! Convert an SVG document to a standalone PDF (page 1 is later imported as a
//! Form XObject). Fonts come from the caller — no system-font scan.
//!
//! Parsing is separate from conversion because the raster backend needs the
//! same tree: it hands it to `resvg::render` instead. The type is always
//! spelled `svg2pdf::usvg::Tree`, never `resvg::usvg::Tree`, so that if the
//! two crates ever resolve to different `usvg` versions the result is a
//! compile error rather than a silently duplicated dependency.

use svg2pdf::{ConversionOptions, PageOptions};

use crate::error::{PdfError, Result};

/// Parse `bytes` as SVG. `font_bytes` are loaded into usvg's font database so
/// `<text>` glyphs resolve the same way body text does.
pub fn parse_svg(bytes: &[u8], font_bytes: &[&[u8]]) -> Result<svg2pdf::usvg::Tree> {
    use svg2pdf::usvg;

    let mut opt = usvg::Options::default();
    // usvg's default resolver `fs::read`s any path that exists: an
    // `<image href="/abs/path">` in an SVG rendered from user content embedded
    // the server's images and attachments in the PDF, past the image-source
    // policy. Paths take the same route as a top-level image source now; the
    // bytes then go through usvg's own data resolver, which sniffs the format.
    opt.image_href_resolver.resolve_string = Box::new(|href, opts| {
        let data = crate::images::read_local_source(href).ok()?;
        (usvg::ImageHrefResolver::default_data_resolver())(
            "text/plain",
            std::sync::Arc::new(data),
            opts,
        )
    });
    {
        let db = opt.fontdb_mut();
        for &face in font_bytes {
            db.load_font_data(face.to_vec());
        }
    }
    usvg::Tree::from_data(bytes, &opt).map_err(|e| PdfError::Image(format!("SVG parse: {e}")))
}

/// Convert an already-parsed tree to a standalone PDF, returning it with the
/// tree's intrinsic size (SVG user units, treated as pt at 72 dpi).
pub fn tree_to_pdf(tree: &svg2pdf::usvg::Tree) -> Result<(Vec<u8>, f32, f32)> {
    let size = tree.size();
    let (w, h) = (size.width(), size.height());
    if w <= 0.0 || h <= 0.0 {
        return Err(PdfError::Image("SVG has zero size".into()));
    }

    let conversion = ConversionOptions {
        compress: true,
        embed_text: true,
        ..ConversionOptions::default()
    };

    let pdf = svg2pdf::to_pdf(tree, conversion, PageOptions { dpi: 72.0 })
        .map_err(|e| PdfError::Image(format!("SVG to PDF: {e}")))?;
    Ok((pdf, w, h))
}

/// Parse `bytes` as SVG and convert to PDF.
pub fn svg_to_pdf(bytes: &[u8], font_bytes: &[&[u8]]) -> Result<(Vec<u8>, f32, f32)> {
    let tree = parse_svg(bytes, font_bytes)?;
    tree_to_pdf(&tree)
}

#[cfg(test)]
mod tests {
    use super::*;
    use svg2pdf::usvg;

    fn image_count(group: &usvg::Group) -> usize {
        group
            .children()
            .iter()
            .map(|node| match node {
                usvg::Node::Image(_) => 1,
                usvg::Node::Group(inner) => image_count(inner),
                _ => 0,
            })
            .sum()
    }

    fn png_bytes() -> Vec<u8> {
        let mut bytes = Vec::new();
        image::RgbImage::new(2, 2)
            .write_to(
                &mut std::io::Cursor::new(&mut bytes),
                image::ImageFormat::Png,
            )
            .unwrap();
        bytes
    }

    fn svg_with_image(href: &str) -> String {
        format!(
            r#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><image href="{href}" width="2" height="2"/></svg>"#
        )
    }

    /// usvg's default resolver read any existing path. With no image-source
    /// policy installed, a path in an `<image href>` must load nothing.
    #[test]
    fn an_image_href_path_goes_through_the_source_policy() {
        let dir = std::env::temp_dir().join(format!("soli-svg-href-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let secret = dir.join("secret.png");
        std::fs::write(&secret, png_bytes()).unwrap();

        let tree = parse_svg(
            svg_with_image(&secret.display().to_string()).as_bytes(),
            &[],
        )
        .unwrap();
        assert_eq!(
            image_count(tree.root()),
            0,
            "the file was read past the policy"
        );

        std::fs::remove_dir_all(&dir).ok();
    }

    /// A `data:` image carries its own bytes and still renders.
    #[test]
    fn a_data_uri_image_still_renders() {
        use base64::Engine as _;
        let encoded = base64::engine::general_purpose::STANDARD.encode(png_bytes());
        let href = format!("data:image/png;base64,{encoded}");
        let tree = parse_svg(svg_with_image(&href).as_bytes(), &[]).unwrap();
        assert_eq!(image_count(tree.root()), 1);
    }
}
