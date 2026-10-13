//! Regression test: the classes of a bounded context — declared inside a
//! `module` — must be counted in code coverage.
//!
//! The coverage walk registered a class's methods but not the classes nested
//! in it. A `module Billing … end` is a class whose classes are nested, so a
//! file whose code lived in a module registered one executable line (the
//! `module` itself) and reported 100 % covered whatever its specs did: an
//! application moved into contexts escaped its coverage gate.

use solilang::coverage::CoverageTracker;
use std::sync::{Arc, Mutex};

#[test]
fn classes_inside_a_module_are_line_counted() {
    let dir = tempfile::tempdir().unwrap();
    let model_path = dir.path().join("ledger.sl");
    let test_path = dir.path().join("ledger_run.sl");

    // Line 4 runs; line 7 never does.
    let model_src = "\
module Billing
  class Ledger
    static def total -> Int
      return 42
    end
    static def unused -> Int
      return 7
    end
  end
end
";
    std::fs::write(&model_path, model_src).unwrap();
    let test_src = "let t = Billing::Ledger.total()\n";
    std::fs::write(&test_path, test_src).unwrap();

    let mut tracker = CoverageTracker::new();
    tracker.register_executable_lines_from_source(&model_path, model_src);
    let tracker = Arc::new(Mutex::new(tracker));
    let (_assertions, result) = solilang::run_with_path_and_coverage(
        test_src,
        Some(&test_path),
        false,
        Some(&tracker),
        Some(&test_path),
        &[(model_path.clone(), model_src.to_string())],
    );
    assert!(result.is_ok(), "run failed: {:?}", result.err());

    let aggregated = tracker.lock().unwrap().get_aggregated_coverage();
    let file_cov = aggregated
        .file_coverages
        .iter()
        .find(|(path, _)| path.file_name().is_some_and(|n| n == "ledger.sl"))
        .map(|(_, cov)| cov)
        .expect("model file should appear in coverage");

    let ran = file_cov
        .lines
        .get(&4)
        .expect("a method body of a class in a module should be registered");
    assert!(
        ran.hits > 0,
        "the method that ran is not counted as covered"
    );
    let never = file_cov
        .lines
        .get(&7)
        .expect("a method body that never ran should still be registered");
    assert_eq!(
        never.hits, 0,
        "a method that never ran is counted as covered"
    );
}
