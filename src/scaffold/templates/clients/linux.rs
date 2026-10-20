//! Linux GTK + WebKitGTK shell templates.

pub const README: &str = include_str!("linux/README.txt");
// `.tmpl`: a directory holding a `Cargo.toml` is a package of its own, and
// `cargo package` leaves it out of the published crate.
pub const CARGO_TOML: &str = include_str!("linux/Cargo.toml.tmpl");
pub const DESKTOP_FILE: &str = include_str!("linux/app.desktop");
pub const INSTALL_SH: &str = include_str!("linux/install.sh");
pub const MAIN_RS: &str = include_str!("linux/main.rs");
