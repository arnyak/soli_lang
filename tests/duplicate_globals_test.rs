//! Two files declaring one top-level name: `soli serve` refuses to boot, and
//! `soli lint` reports it. Without the check the second declaration replaced
//! the first in silence — a method of the first class stopped existing.

use std::path::Path;
use std::process::Command;
use std::time::{Duration, Instant};

fn write(root: &Path, path: &str, body: &str) {
    let file = root.join(path);
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(file, body).unwrap();
}

fn app_with_a_duplicate(root: &Path) {
    write(root, "config/routes.sl", "get(\"/\", \"home#index\")\n");
    write(
        root,
        "app/controllers/home_controller.sl",
        "class HomeController < Controller\n  # GET /\n  def index(req)\n    \"ok\"\n  end\nend\n",
    );
    write(
        root,
        "app/models/notifications.sl",
        "class Notifications\n  def unread\n    0\n  end\nend\n",
    );
    write(
        root,
        "app/services/notifications.sl",
        "# the same name, for another job\nclass Notifications\n  def send_all\n    nil\n  end\nend\n",
    );
}

#[test]
fn serve_refuses_an_app_that_declares_a_name_twice() {
    let dir = tempfile::tempdir().unwrap();
    app_with_a_duplicate(dir.path());
    let port = std::net::TcpListener::bind("127.0.0.1:0")
        .and_then(|l| l.local_addr())
        .map(|a| a.port())
        .unwrap_or(28911);
    let mut child = Command::new(env!("CARGO_BIN_EXE_soli"))
        .arg("serve")
        .arg(dir.path())
        .arg("--port")
        .arg(port.to_string())
        .current_dir(dir.path())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .expect("spawn soli serve");
    let deadline = Instant::now() + Duration::from_secs(30);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if Instant::now() > deadline {
            let _ = child.kill();
            panic!("soli serve booted an app with a duplicate class");
        }
        std::thread::sleep(Duration::from_millis(100));
    };
    let output = child.wait_with_output().unwrap();
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!status.success(), "{text}");
    assert!(text.contains("`Notifications` is declared twice"), "{text}");
    assert!(text.contains("app/models/notifications.sl:1"), "{text}");
    assert!(text.contains("app/services/notifications.sl:2"), "{text}");
}

#[test]
fn lint_reports_the_second_declaration() {
    let dir = tempfile::tempdir().unwrap();
    app_with_a_duplicate(dir.path());
    let output = Command::new(env!("CARGO_BIN_EXE_soli"))
        .arg("lint")
        .arg(".")
        .current_dir(dir.path())
        .output()
        .expect("run soli lint");
    let text = String::from_utf8_lossy(&output.stdout);
    assert!(!output.status.success(), "{text}");
    assert!(
        text.contains("app/services/notifications.sl:2:1 - [smell/duplicate-global]"),
        "{text}"
    );
}
