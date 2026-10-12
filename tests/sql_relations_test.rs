//! Relations on a SQL adapter (SQLite): `has_many`, `belongs_to`, `has_one`,
//! has_and_belongs_to_many and `dependent:` cascades read and write through
//! the adapter. They built SoliDB queries, so on SQL every read raised — or,
//! for `.all` and `.length`, answered the error text as if it were the rows —
//! and `belongs_to` hydrated the target into the owner's class. A relation
//! from another bounded context to a `private class` is refused, as naming the
//! class is.

use std::path::Path;

fn sqlite_script(dir: &Path, script: &str) -> Vec<String> {
    std::fs::write(dir.join("script.sl"), script).unwrap();
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_soli"))
        .arg("script.sl")
        .current_dir(dir)
        .env("SOLI_DB_ADAPTER", "sqlite")
        .env(
            "DATABASE_URL",
            format!("sqlite://{}/app.sqlite3", dir.display()),
        )
        .output()
        .expect("run soli");
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    assert!(
        output.status.success(),
        "{stdout}{}",
        String::from_utf8_lossy(&output.stderr)
    );
    stdout.lines().map(str::to_string).collect()
}

const CHECK: &str = r#"
def check(label, action)
  try
    print(label, action())
  catch e
    print(label, "raised:", e)
  end
end
"#;

#[test]
fn relations_read_and_cascade_on_sqlite() {
    let dir = tempfile::tempdir().unwrap();
    let script = format!(
        "{CHECK}{}",
        r#"
class Owner < Model
  has_many("pets", {"dependent": "delete"})
  has_one("profile")
  has_many("toys", {"dependent": "nullify"})

  def greet
    "owner #{@name}"
  end
end
class Pet < Model
  belongs_to("owner")
end
class Profile < Model
  belongs_to("owner")
end
class Toy < Model
  belongs_to("owner")
end
class Article < Model
  has_and_belongs_to_many("tags")
end
class Tag < Model
  has_and_belongs_to_many("articles")
end

ada = Owner.create({"name": "ada"})
bob = Owner.create({"name": "bob"})
Pet.create({"name": "rex", "owner_id": ada._key})
Pet.create({"name": "tom", "owner_id": ada._key})
Pet.create({"name": "kit", "owner_id": bob._key})
Profile.create({"bio": "hi", "owner_id": ada._key})
Toy.create({"name": "ball", "owner_id": ada._key})

check("count", fn() { ada.pets.count })
check("names", fn() { ada.pets.all.map { |p| p.name }.sort() })
check("length", fn() { ada.pets.length })
check("chained where", fn() { ada.pets.where({"name": "tom"}).count })
check("index", fn() { ada.pets.order("name", "asc").all[0].name })
check("belongs_to", fn() { pet = Pet.where({"name": "kit"}).first
  [type(pet.owner), pet.owner.greet] })
check("has_one", fn() { ada.profile.bio })
check("unsaved owner", fn() { Owner.new().pets.count })
article = Article.create({"title": "t"})
article.add_tag(Tag.create({"name": "soli"}))
article.add_tag(Tag.create({"name": "ruby"}))
check("habtm", fn() { article.tags.map { |t| t.name } })
ada.delete
check("dependent delete", fn() { Pet.where({"owner_id": ada._key}).count })
check("dependent nullify", fn() { Toy.where({"name": "ball"}).first.owner_id })
check("other owner", fn() { bob.pets.count })
check("string where", fn() { Owner.where("doc.name == 'x'").all })
"#
    );
    let lines = sqlite_script(dir.path(), &script);
    let refused = lines.last().cloned().unwrap_or_default();
    assert_eq!(
        lines[..lines.len() - 1],
        [
            "count 2",
            "names [rex, tom]",
            "length 2",
            "chained where 1",
            "index rex",
            "belongs_to [Owner, owner bob]",
            "has_one hi",
            "unsaved owner 0",
            "habtm [soli, ruby]",
            "dependent delete 0",
            "dependent nullify null",
            "other owner 1",
        ]
    );
    // A failed read raises: it used to answer `.all` with its error text.
    assert!(
        refused.starts_with("string where raised:") && refused.contains("SoliDB-only"),
        "{refused}"
    );
}

#[test]
fn a_relation_cannot_reach_another_contexts_private_model() {
    let dir = tempfile::tempdir().unwrap();
    let script = format!(
        "{CHECK}{}",
        r#"
module Billing
  private class Ledger < Model
  end

  class Account < Model
    has_many("ledgers")
  end

  class Statement < Model
    belongs_to("ledger", {"class_name": "Billing::Ledger"})
  end
end

module Shipping
  class Parcel < Model
    belongs_to("ledger", {"class_name": "Billing::Ledger"})
  end
end

account = Billing::Account.create({"name": "acme"})
ledger = Billing::Account.find(account._key).ledgers.create({"amount": 30})
check("inside", fn() { Billing::Statement.create({"ledger_id": ledger._key}).ledger.amount })
check("inside has_many", fn() { account.ledgers.count })
parcel = Shipping::Parcel.create({"ledger_id": ledger._key})
check("outside", fn() { parcel.ledger })
check("outside includes", fn() { Shipping::Parcel.includes("ledger").all })
check("by name", fn() { Billing::Ledger.count })
"#
    );
    let lines = sqlite_script(dir.path(), &script);
    assert_eq!(lines[0], "inside 30");
    assert_eq!(lines[1], "inside has_many 1");
    for (line, label) in lines[2..]
        .iter()
        .zip(["outside", "outside includes", "by name"])
    {
        assert!(
            line.starts_with(&format!("{label} raised:"))
                && line.contains("Billing::Ledger")
                && line.contains("private to Billing"),
            "{line}"
        );
    }
}
