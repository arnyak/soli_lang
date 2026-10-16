# calamine 0.36.1, patched for zip 9

Why: every `zip` release before 9.0.3 was yanked from crates.io on 2026-10-16
for security advisories (zip-rs/zip2#1075: GHSA-vv5m-jxxh-4627,
GHSA-4v9h-p7m9-rh26, GHSA-4684-h2q9-2vcp, more announced). calamine 0.36.1,
its latest release, requires `zip ^8.6`, so `cargo audit --deny warnings`
failed on the yanked crate and Soli kept reading spreadsheets with it.

What: the published `calamine-0.36.1.crate` (sha256
`5fa68281b1a76b54a62156474adb06bb380a67e07dd60656e3217152b42183f3`, the
checksum Cargo.lock recorded) with two changes, both from tafia/calamine#741
(commit 7fa951c9):

- `Cargo.toml`: `zip` 8.6 -> 9.0. The `[[example]]`, `[[bench]]` and
  `[dev-dependencies]` sections are dropped: their files are not vendored.
- `src/utils.rs`, `build_zip_path_cache`: `ZipArchive::file_names()` yields
  `Result`s on zip 9; an entry whose name does not decode is skipped.

Wired in by `[patch.crates-io]` in the root Cargo.toml.

Remove: once calamine publishes a release on zip 9, delete this directory and
the `[patch.crates-io]` entry, and bump `calamine` in Cargo.toml.

Note: `cargo audit` does not scan a path dependency, so a calamine advisory
would not be reported while this is in place — check
https://rustsec.org/packages/calamine.html by hand before each release.
