# Domain-driven design in Soli

Every app has rules that are not about HTTP or SQL: an amount of money is
never negative, an invoice is paid once, an account cannot spend credit it
does not have, and when an invoice is paid the warehouse should hear about it.
In most codebases those rules end up wherever the first bug report put them
— a check in one controller, a callback on one model, a line in a job — and
the second place that needs one forgets it.

Domain-driven design gives them a home. Soli now ships its building blocks
as part of the language and the ORM, with no framework on the side:

- **value objects** that refuse to exist in a bad state;
- **aggregates** — the `Model` you already write — with invariants and
  optimistic locking;
- **domain errors** that answer the HTTP status of the rule they broke;
- **domain events** published after the commit, to in-process subscribers,
  to jobs through a transactional outbox, and to an
  [es](/docs/builtins/es) stream;
- **bounded contexts**: modules with their own models, tables and names;
- **event-sourced aggregates**, rebuilt from their own stream of events.

This post builds one small billing domain with all of it — accounts with
prepaid credit, invoices paid from that credit, a shipping context that
reacts — and every snippet and every output below comes from running that
app.

<figure style="margin:1.5rem auto;max-width:1024px;">
  <img src="/images/blog/domain-driven-design-in-soli.svg" width="1024" height="576" alt="Paying an invoice. POST /invoices/:id/pay calls Billing::PayInvoice, which runs one transaction: the Invoice aggregate (Amount value fields, invariants, optimistic lock) debits the Account and records InvoicePaid. The answer is 200, 422 InsufficientFunds or 409 InvoiceAlreadyPaid / StaleRecord. After the commit, InvoicePaid reaches a Shipping subscriber that creates a shipment, a ReceiptJob enqueued in the transaction (the outbox), and the billing topic of es." style="display:block;width:100%;height:auto;border-radius:12px;border:1px solid #30363d;background:#0b0d0f;">
  <figcaption style="text-align:center;color:#8b949e;font-size:0.875rem;margin-top:0.5rem;">One use case, one transaction; what happened travels on as an event, once it is committed.</figcaption>
</figure>

## A value object: `Amount`

Money is the textbook value object. Five hundred euro cents is five hundred
euro cents wherever it appears; it has no identity, and changing it means
having a different amount. As a bare integer it ends up added to a quantity,
or euros to dollars.

```soli
# app/models/values/amount.sl
class Amount < ValueObject
  cents: Int
  currency: String = "EUR"

  invariant(:cents, "an amount is never negative") { @cents >= 0 }
  invariant(:currency, "must be a three-letter code") { @currency.length == 3 && @currency == @currency.upcase }

  def plus(other: Amount) -> Amount
    @_same_currency(other)
    @with(cents: @cents + other.cents)
  end

  def minus(other: Amount) -> Amount
    @_same_currency(other)
    @with(cents: @cents - other.cents)
  end

  def covers?(other: Amount) -> Bool
    @_same_currency(other)
    @cents >= other.cents
  end

  def to_display -> String
    "#{@cents / 100}.#{(@cents % 100).to_s.rjust(2, "0")} #{@currency}"
  end

  private

  def _same_currency(other: Amount)
    return nil if other.currency == @currency

    throw CurrencyMismatch.new("cannot combine #{@currency} and #{other.currency}")
  end
end

class CurrencyMismatch < DomainError
end
```

`ValueObject` builds an `Amount` from its fields — `Amount.new(500)`,
`Amount.new(cents: 500)`, `Amount.new({"cents": 500})` from JSON — makes two
amounts with the same fields equal (`Amount.new(500) == Amount.new(500, "EUR")`
is `true`, so `includes?` and `uniq` work), and freezes it: `amount.cents = 1`
raises, and `with(cents: …)` is how `plus` and `minus` return a new one.

The invariants run every time an amount is built, `with` included. `minus`
does not check for a negative result: if the subtraction goes below zero,
building the new `Amount` fails, so no code anywhere can hold a negative
amount. `Amount.new(-1)` throws an `InvariantViolation` — *Amount: an amount
is never negative* — and in a served app, left uncaught, it answers 422.

## Domain errors

```soli
# app/models/billing/errors.sl
module Billing
  class InsufficientFunds < DomainError
  end

  class InvoiceAlreadyPaid < DomainError
    static http_status: Int = 409
  end
end
```

`DomainError` carries a `message` and optional `details`. What sets it apart
is what happens when nobody catches it in a served app: the request answers
**422** with the error page showing its message — a broken business rule is
an answer, not a crash — and `static http_status` picks another status. No
500 block lands in the log. `StaleRecord`, which we will meet below, is a
built-in one with status 409.

## The aggregates: `Account` and `Invoice`

Soli keeps aggregates on `Model` rather than asking for a parallel layer of
repositories and mappers. They live in the `Billing` context — a module — and
state their own rules:

```soli
# app/models/billing/account.sl
module Billing
  class Account < Model
    optimistic_lock
    value_field :credit, Amount
    validates("name", {"presence": true})

    def debit(amount: Amount)
      unless @credit.covers?(amount)
        throw InsufficientFunds.new(
          "#{@name} has #{@credit.to_display} of credit, the invoice needs #{amount.to_display}",
          {"credit": @credit.to_h, "needed": amount.to_h}
        )
      end
      @credit = @credit.minus(amount)
    end
  end
end
```

```soli
# app/models/billing/invoice.sl
module Billing
  class Invoice < Model
    optimistic_lock
    value_field :total, Amount
    value_field :paid, Amount
    belongs_to("account")
    validates("number", {"presence": true})

    invariant(:total, "must be more than zero") { @total.cents > 0 }
    invariant(:paid, "cannot exceed the total") { @paid.nil? || @total.covers?(@paid) }
    invariant(:status, "a paid invoice records its payment") { @status != "paid" || !@paid.nil? }

    def pay_from(account: Account)
      throw InvoiceAlreadyPaid.new("invoice #{@number} is already paid") if @status == "paid"

      account.debit(@total)
      @paid = @total
      @status = "paid"
      @record_event(InvoicePaid.new(@number, account._key, @total.cents))
    end
  end

  class Receipt < Model
  end
end
```

Four things are at work here.

**`value_field :total, Amount`** stores the amount as an object of its fields
and gives it back as an `Amount` on every read. Anything else is refused with
*must be a Amount*.

**Model invariants** are validations of the record as a whole: a falsy one
puts `{field, message}` into `_errors` and the record is not saved — through
`create`, `save`, `update` or `Model.update`. They run once every `validates`
rule has passed, so `@total.cents` never meets a missing total.

**`optimistic_lock`** gives each record a `lock_version`. Every update checks
that the stored version is still the one the record was read with, and bumps
it, in one atomic write; a stale save returns `false` with `record.stale?`
true. More on it below.

**`record_event`** keeps an event on the record; it is published when the
record is saved. A method that raises an event and then fails to save
publishes nothing. The event itself is a value object:

```soli
# app/models/billing/events.sl
module Billing
  class InvoicePaid < DomainEvent
    number: String
    account_key: String
    cents: Int
  end
end
```

## One use case, one transaction

Paying an invoice changes two records, and they change together or not at
all:

```soli
# app/services/pay_invoice.sl
module Billing
  class PayInvoice
    static def call(invoice_key: String) -> Invoice
      Invoice.transaction do
        invoice = Invoice.find(invoice_key)
        account = Account.find(invoice.account_id)
        invoice.pay_from(account)
        unless account.save && invoice.save
          throw StaleRecord.new("invoice #{invoice.number} changed while it was being paid")
        end
        after_commit { broadcast("invoices", {"paid": invoice.number}) }
        invoice
      end
    end
  end
end
```

Inside the `Billing` module, `Invoice` and `Account` need no prefix: a class
name that is not a global resolves in the context the code is written in.

`Model.transaction` commits when the block returns and rolls back when it
throws. A `throw` from `pay_from` or `debit` happens before anything is
written. The one after the saves matters more: `save` reports a refused
record by returning `false` rather than raising — an invariant, or a stale
`lock_version` because someone else paid from the same account a moment ago —
and throwing there rolls the debit back. `StaleRecord` answers 409, the
status for "reload and try again".

`after_commit { … }` runs once the data is durable: after the outermost
commit, never after a rollback. Side effects that must not happen for a
payment that was never stored go there.

## Reacting to what happened

Billing does not know who cares that an invoice was paid. The subscribers,
in `app/subscribers/`, say so:

```soli
# app/subscribers/billing.sl
# Shipping reacts to Billing's event, in this process, once the payment is committed.
subscribe(Billing::InvoicePaid) do |event|
  Shipping::Shipment.create({"invoice_number": event.number, "status": "ready"})
end

# A job, enqueued in the payment's transaction: the outbox.
subscribe(Billing::InvoicePaid, ReceiptJob)

# The same event, appended to the `billing` topic of es for other services.
subscribe(Billing::InvoicePaid, {"stream": "billing", "key": "number"})
```

```soli
# app/jobs/receipt_job.sl
class ReceiptJob
  static def perform(event)
    Billing::Receipt.create({"invoice_number": event["number"], "cents": event["cents"]})
  end
end
```

Three kinds of handler, three delivery guarantees:

- A **block** runs in the same process after the commit — never for a payment
  that rolled back. It is the simplest, and it fails with the request: use it
  for work that cannot fail, or does not matter if it does.
- A **job** is enqueued when the event is published, inside the transaction.
  The job row is written by that transaction, so it commits or rolls back with
  the payment: a *transactional outbox*, with the job queue's retries for
  delivery. Nothing to forget, nothing sent twice for one payment.
- A **stream** appends the event to an es topic, for services outside this
  app. It goes through the same outbox — a built-in `EventStreamJob` — so the
  topic receives every committed payment, at least once, and never one that
  was rolled back.

## Bounded contexts

`Billing` and `Shipping` are modules, and a model in a module is its own
thing: `Billing::Invoice` is what `print` and `.class` show, its table is
`billing_invoices`, and a `Shipping::Invoice` could exist beside it without a
collision. A module can be declared in several files, so each context keeps
its own folder:

```soli
# app/models/shipping/shipment.sl
module Shipping
  class Shipment < Model
    validates("invoice_number", {"presence": true})
  end
end
```

Inside a context, relations name its own models — `belongs_to("account")` on
`Billing::Invoice` is `Billing::Account` — and `class_name:` reaches any
other. Shipping depends on Billing only through `Billing::InvoicePaid`: the
event is the contract between them.

## The controller only asks

```soli
# app/controllers/invoices_controller.sl
class InvoicesController < Controller
  # POST /invoices
  def create(req)
    total = Amount.new(params["total_cents"], params["currency"] || "EUR")
    invoice = Billing::Invoice.create({
      "number": params["number"],
      "account_id": params["account_id"],
      "total": total,
      "status": "open"
    })
    return render_json({"errors": invoice._errors}, 422) if invoice._errors

    render_json(invoice, 201)
  end

  # POST /invoices/:id/pay — a DomainError left uncaught answers 422 (409 for InvoiceAlreadyPaid, StaleRecord)
  def pay(req)
    invoice = Billing::PayInvoice.call(params["id"])
    render_json({"number": invoice.number, "status": invoice.status, "paid": invoice.paid.to_display})
  end
end
```

`pay` has no error handling, and needs none: every way paying can fail is a
domain error with a status.

## On the wire

An account with 50 € of credit, two invoices of 30 € and 25 €:

```text
POST /accounts {"name": "Acme", "credit_cents": 5000}
→ 201 {"_key":"938c3630-…","name":"Acme","credit":{"cents":5000,"currency":"EUR"},"lock_version":0, …}

POST /invoices {"number": "F-003", "total_cents": 0, …}
→ 422 {"errors":[{"field":"total","message":"must be more than zero"}]}

POST /invoices/<F-001>/pay
→ 200 {"number":"F-001","status":"paid","paid":"30.00 EUR"}

POST /invoices/<F-001>/pay
→ 409  error page: "invoice F-001 is already paid"

POST /invoices/<F-002>/pay
→ 422  error page: "Acme has 20.00 EUR of credit, the invoice needs 25.00 EUR"

GET /shipments
→ 200 {"shipments":["F-001"],"receipts":1}
```

The shipment was created by Shipping's subscriber after the commit, the
receipt by the job; the second and third payments, refused, published
nothing. On the es side:

```text
$ es consume --topic billing --partition 0 --offset 0
p=0 off=0 key=Some("F-001") value={"data":{"account_key":"938c3630-…","cents":3000,"number":"F-001"},
  "occurred_at":"2026-10-11T19:34:41Z","type":"Billing::InvoicePaid"}
```

And what SQLite holds — each context its tables, each amount an object of
its fields, each record its version:

```text
billing_accounts   billing_invoices   billing_receipts   shipping_shipments   _jobs

{"name":"Acme","credit":{"cents":2000,"currency":"EUR"},"lock_version":1, …}
{"number":"F-001","status":"paid","total":{"cents":3000,"currency":"EUR"},
 "paid":{"cents":3000,"currency":"EUR"},"lock_version":1, …}
```

## Two people, one record

Optimistic locking in one picture — two requests that loaded the same
account:

```soli
first = Billing::Account.find(acme._key)
second = Billing::Account.find(acme._key)
first.debit(Amount.new(1000))
first.save            # true — lock_version 1
second.debit(Amount.new(1000))
second.save           # false — second.stale? is true
Billing::Account.find(acme._key).credit   # Amount(cents: 4000, currency: "EUR")
```

Without the lock, the second save would have written 40 € over the first
one's 40 €, and 10 € of debit would have vanished. With it, `PayInvoice`
throws `StaleRecord` and the client retries on fresh data. A form can do the
same: a hidden `lock_version` field makes `Model.update` refuse a submission
made after someone else's edit.

## When the history is the state

An `Account` row says how much credit is left; it does not say how it got
there. When that question matters — a prepaid wallet, a ledger, anything an
auditor will ask about — store the events and let the state follow from
them. `EventSourced` is the base class for that:

```soli
# app/models/billing/wallet.sl
module Billing
  class Credited < DomainEvent
    cents: Int
    reason: String
  end

  class Spent < DomainEvent
    cents: Int
    invoice: String
  end

  class Wallet < EventSourced
    balance: Int = 0

    def credit(cents: Int, reason: String)
      @emit(Credited.new(cents, reason))
    end

    def spend(cents: Int, invoice: String)
      throw InsufficientFunds.new("#{@balance} left, #{cents} asked") if cents > @balance

      @emit(Spent.new(cents, invoice))
    end

    def apply(event)
      match event.class {
        "Billing::Credited" => @balance = @balance + event.cents,
        "Billing::Spent" => @balance = @balance - event.cents,
        _ => nil
      }
    end
  end
end
```

The methods decide; `apply` is the only place the state changes, and it runs
both when an event is emitted and when the stream is replayed:

```soli
wallet = Billing::Wallet.new()
wallet.credit(5000, "top-up")
wallet.save                         # version 1, balance 5000

wallet = Billing::Wallet.load(wallet.id)
wallet.spend(3000, "F-001")
wallet.save                         # version 2, balance 2000
```

`save` appends the new events to the wallet's stream in one transaction and
publishes them after the commit, so the subscribers, the outbox and the es
stream from earlier see them like any other event. The stream itself is
plain rows:

```text
1 Billing::Credited {cents => 5000, reason => top-up}
2 Billing::Spent    {cents => 3000, invoice => F-001}
```

Each row's key is the stream and the version, which is what makes the
concurrency check free. Two requests that loaded version 2 both try to
append version 3; the second one cannot:

```soli
first = Billing::Wallet.load(wallet.id)
second = Billing::Wallet.load(wallet.id)
first.spend(1500, "F-002")
first.save
second.spend(1500, "F-003")
second.save
# StaleRecord: Billing::Wallet:6cdc…b048 changed since it was loaded at version 2
```

In a served app that is a 409, and the wallet never goes below zero —
`Billing::Wallet.load(wallet.id).balance` is 500.

## Also in the box

A few building blocks the billing example did not need:

- **Lists of value objects.** `value_field :lines, [Line]` keeps an invoice's
  lines as values in one field, read back as `Line`s, with invariants over
  the whole list.
- **Value objects as hash keys**: `prices[Amount.new(500)]` is found by any
  equal amount.
- **Locking existing tables.** `optimistic_lock` works on column-mode models
  over an existing SQL schema too, given a `lock_version` column.
- **Private classes, models included.** `private class Ledger < Model`
  inside `module Billing` is Billing's alone: its code and its relations use
  it (`account.ledgers`), and another context reaches it neither by name nor
  through a relation — a `belongs_to("ledger", {"class_name":
  "Billing::Ledger"})` declared in Shipping raises *Shipping::Parcel cannot
  reach Billing::Ledger through a relation: Billing::Ledger is private to
  Billing*. The other contexts go through Billing's public classes and its
  events.
- **Aggregate roots.** `part_of :invoice` on an invoice line refuses to write
  it outside `Invoice.transaction do … end` — the aggregate changes through
  its root.
- **Versioned events.** `static version: Int = 2` and a `static def
  upcast(data, from_version)` bring older stream records up to date when
  they are consumed.
- **The consuming side of a stream.** Another app reacts to `InvoicePaid` by
  declaring the same event class and calling
  `EventStream.consume("billing", {"group": "shipping"})` from a cron job:
  each record is published to its own subscribers, and the group's offset is
  committed record by record.

Controllers can join their context as well: `module Billing` around
`class InvoicesController < Controller` in `app/controllers/billing/`.

The reference: [value objects](/docs/language/value-objects),
[value fields and invariants](/docs/database/validations#value-fields-and-invariants),
[domain events, after-commit, locking and event sourcing](/docs/database/domain-events),
[bounded contexts](/docs/language/modules#bounded-contexts) and
[error classes](/docs/language/error-handling#error-classes).
