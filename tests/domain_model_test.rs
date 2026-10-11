//! Value objects in models, and domain errors in a served app: a
//! `value_field` stored as a hash and read back as its value object, model
//! invariants as validation errors, and an uncaught `DomainError` answering
//! 422 (or its `http_status`) from the VM, with no fallback to the
//! interpreter.

use std::path::Path;

fn write(root: &Path, path: &str, body: &str) {
    let file = root.join(path);
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(file, body).unwrap();
}

/// `Price` lives in a subdirectory that loads after `invoice.sl`: value
/// objects load first, or `value_field :total, Price` would not find it.
const PRICE: &str = r#"class Price < ValueObject
  cents: Int
  currency: String
  invariant(:cents, "must not be negative") { @cents >= 0 }

  def add(other: Price) -> Price
    @with(cents: @cents + other.cents)
  end
end
"#;

const INVOICE: &str = r#"class Invoice < Model
  value_field :total, Price
  validates("number", {"presence": true})
  invariant(:total, "total must be positive") { @total.cents > 0 }
end
"#;

#[test]
fn a_value_field_round_trips_and_invariants_refuse_the_save() {
    let dir = tempfile::tempdir().unwrap();
    let script = format!(
        "{PRICE}\n{INVOICE}\n{}",
        r#"
ok = Invoice.create({"number": "F-1", "total": Price.new(500, "EUR")})
print(ok._errors)
loaded = Invoice.find(ok._key)
print(loaded.total, loaded.total == Price.new(500, "EUR"))
print(Invoice.create({"number": "F-2", "total": Price.new(0, "EUR")})._errors)
print(Invoice.create({"number": "F-3", "total": 12})._errors)
print(Invoice.create({"total": Price.new(0, "EUR")})._errors)
print(Invoice.update(ok._key, {"total": Price.new(0, "EUR")}))
loaded.total = Price.new(0, "EUR")
loaded.save
print(loaded._errors)
print(Invoice.count, Invoice.find(ok._key).total.cents)
"#
    );
    write(dir.path(), "invoices.sl", &script);
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_soli"))
        .arg("invoices.sl")
        .current_dir(dir.path())
        .env("SOLI_DB_ADAPTER", "sqlite")
        .env(
            "DATABASE_URL",
            format!("sqlite://{}/app.sqlite3", dir.path().display()),
        )
        .output()
        .expect("run soli");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        output.status.success(),
        "{stdout}{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let lines: Vec<&str> = stdout.lines().collect();
    assert_eq!(
        lines,
        vec![
            "null",
            "Price(cents: 500, currency: \"EUR\") true",
            "[{field => total, message => total must be positive}]",
            "[{field => total, message => must be a Price}]",
            // Invariants wait for the other validations to pass.
            "[{field => number, message => can't be blank}]",
            "{_errors => [{field => total, message => total must be positive}]}",
            "[{field => total, message => total must be positive}]",
            "1 500",
        ],
        "{stdout}"
    );
}

fn served_app(root: &Path) {
    write(
        root,
        "config/routes.sl",
        r#"get("/up", "billing#up")
get("/vo", "billing#vo")
get("/insufficient", "billing#insufficient")
get("/stale", "billing#stale")
get("/plain", "billing#plain")
post("/invoices", "billing#create")
"#,
    );
    write(root, "app/models/values/price.sl", PRICE);
    write(root, "app/models/invoice.sl", INVOICE);
    write(
        root,
        "app/models/errors.sl",
        r#"class InsufficientFunds < DomainError
end

class StaleInvoice < DomainError
  static http_status: Int = 409
end
"#,
    );
    write(
        root,
        "app/controllers/billing_controller.sl",
        r#"class BillingController < Controller
  # GET /up
  def up(req)
    "ok"
  end

  # GET /vo
  def vo(req)
    total = Price.new(500, "EUR").add(Price.new(cents: 250, currency: "EUR"))
    render_json({"total": total.to_h, "same": total == Price.new(750, "EUR"), "shown": total.to_s, "price": total})
  end

  # GET /insufficient
  def insufficient(req)
    throw InsufficientFunds.new("balance too low", {"needed": 30})
  end

  # GET /stale
  def stale(req)
    throw new StaleInvoice("invoice changed since you loaded it")
  end

  # GET /plain
  def plain(req)
    throw "not a domain error"
  end

  # POST /invoices
  def create(req)
    invoice = Invoice.create({"number": params["number"], "total": Price.new(params["cents"], "EUR")})
    return render_json({"errors": invoice._errors}, 422) if invoice._errors

    loaded = Invoice.find(invoice._key)
    render_json({"total": loaded.total.to_h, "price": loaded.total.is_a?("Price")})
  end
end
"#,
    );
}

struct Server(std::process::Child, u16);

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn serve(root: &Path) -> Server {
    let port = std::net::TcpListener::bind("127.0.0.1:0")
        .and_then(|l| l.local_addr())
        .map(|a| a.port())
        .unwrap_or(28741);
    let child = std::process::Command::new(env!("CARGO_BIN_EXE_soli"))
        .arg("serve")
        .arg(root)
        .arg("--port")
        .arg(port.to_string())
        .arg("--workers")
        .arg("1")
        .current_dir(root)
        .env("SOLI_DB_ADAPTER", "sqlite")
        .env(
            "DATABASE_URL",
            format!("sqlite://{}/app.sqlite3", root.display()),
        )
        // A handler the VM handed back to the interpreter fails the request.
        .env("SOLI_FAIL_ON_VM_DEMOTION", "1")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .expect("spawn soli serve");
    let server = Server(child, port);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while std::time::Instant::now() < deadline {
        if ureq::get(&format!("http://127.0.0.1:{port}/up"))
            .call()
            .is_ok()
        {
            return server;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    panic!("soli serve did not answer on {port}");
}

fn call(server: &Server, method: &str, path: &str, body: Option<&str>) -> (u16, String) {
    let request = ureq::request(method, &format!("http://127.0.0.1:{}{path}", server.1));
    let response = match body {
        Some(body) => request
            .set("Content-Type", "application/json")
            .send_string(body),
        None => request.call(),
    };
    let response = match response {
        Ok(r) => r,
        Err(ureq::Error::Status(_, r)) => r,
        Err(e) => panic!("{method} {path}: {e}"),
    };
    (
        response.status(),
        response.into_string().unwrap_or_default(),
    )
}

#[test]
fn a_served_app_answers_a_domain_error_with_its_status() {
    let dir = tempfile::tempdir().unwrap();
    served_app(dir.path());
    let server = serve(dir.path());

    let (status, body) = call(&server, "GET", "/vo", None);
    assert_eq!(status, 200, "{body}");
    let json: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(json["total"]["cents"], 750);
    assert_eq!(json["same"], true);
    assert_eq!(json["shown"], "Price(cents: 750, currency: \"EUR\")");
    // `render_json` writes a value object's fields in declaration order.
    assert!(
        body.contains(r#""price":{"cents":750,"currency":"EUR"}"#),
        "{body}"
    );

    let (status, body) = call(&server, "GET", "/insufficient", None);
    assert_eq!(status, 422);
    assert!(body.contains("balance too low"), "{body}");

    let (status, body) = call(&server, "GET", "/stale", None);
    assert_eq!(status, 409);
    assert!(
        body.contains("invoice changed since you loaded it"),
        "{body}"
    );

    // Any other uncaught throw is still a failure.
    let (status, _) = call(&server, "GET", "/plain", None);
    assert_eq!(status, 500);

    let (status, body) = call(
        &server,
        "POST",
        "/invoices",
        Some(r#"{"number": "F-1", "cents": 900}"#),
    );
    assert_eq!(status, 200, "{body}");
    assert!(body.contains(r#""price":true"#), "{body}");
    let (status, body) = call(
        &server,
        "POST",
        "/invoices",
        Some(r#"{"number": "F-2", "cents": 0}"#),
    );
    assert_eq!(status, 422, "{body}");
    assert!(body.contains("total must be positive"), "{body}");
}
