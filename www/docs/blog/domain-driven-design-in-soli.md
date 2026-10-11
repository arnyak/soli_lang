# Domain-driven design in Soli

Every app has rules that are not about HTTP or SQL: an amount of money is
never negative, an invoice is paid once, an account cannot spend credit it
does not have. In most codebases those rules end up wherever the first bug
report put them — a check in one controller, a validation on one model, a
condition in a background job — and the second place that needs one forgets
it. Domain-driven design's tactical patterns are a way to give them a home:
**value objects** that refuse to exist in a bad state, **aggregates** that
guard their own consistency, and **domain errors** that say which rule was
broken.

Soli now has the three of them, without a new framework on the side: a value
object is a class that inherits `ValueObject`, an aggregate is the `Model` you
already write, and a domain error is a class that inherits `DomainError`. This
post builds a small billing domain with them — accounts with prepaid credit,
invoices paid from that credit — and every snippet below was run against that
app.

<figure style="margin:1.5rem auto;max-width:1024px;">
  <img src="/images/blog/domain-driven-design-in-soli.svg" width="1024" height="576" alt="Paying an invoice in a Soli app. A request POST /invoices/:id/pay reaches a thin controller, which calls the PayInvoice service. Inside one transaction, the Invoice aggregate (total and paid are Amount value objects, guarded by invariants) asks the Account (credit is an Amount) to debit itself. The outcome is 200 paid, 422 InsufficientFunds with its message, or 409 InvoiceAlreadyPaid; an Amount below zero cannot exist." style="display:block;width:100%;height:auto;border-radius:12px;border:1px solid #30363d;background:#0b0d0f;">
  <figcaption style="text-align:center;color:#8b949e;font-size:0.875rem;margin-top:0.5rem;">The rules live in the domain classes; the controller asks, and the domain errors become HTTP statuses.</figcaption>
</figure>

## A value object: `Amount`

Money is the textbook value object. Five hundred euro cents is five hundred
euro cents wherever it appears; it has no identity, and changing it means
having a different amount. Keeping it as a bare integer is how a price ends up
added to a quantity, or euros to dollars.

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
```

What `ValueObject` gives the class:

- **Construction from the fields.** `Amount.new(500, "USD")`,
  `Amount.new(cents: 500)` and `Amount.new({"cents": 500})` (a hash, as it
  arrives from JSON) all work, and `currency` takes its default. A class that
  needs to clean its input up — trimming and downcasing an email — keeps a
  constructor of its own.
- **Equality by value.** `Amount.new(500) == Amount.new(500, "EUR")` is
  `true`, so `includes?` and `uniq` work on lists of amounts.
- **Immutability.** `amount.cents = 1` raises *value objects are immutable —
  build a changed copy with with(cents: …)*. `with` is how `plus` and `minus`
  return a new amount; it goes through the constructor again.
- **Invariants.** Each `invariant` block runs every time an amount is built,
  `with` included. A falsy one throws an `InvariantViolation`.

That last point is what makes the type worth having. `minus` does not check
for a negative result: if the subtraction goes below zero, building the new
`Amount` fails, and *no code anywhere* can hold a negative amount. An
`Amount.new(-1)` in a served app answers 422 with *Amount: an amount is never
negative*, and `Amount.new(100, "eur")` with *Amount: must be a three-letter
code*.

The file sits in `app/models/values/`, a subdirectory, and the models in
`app/models/` still find it: files that declare a value object or an enum load
before the other models.

## The errors the domain raises

Domain errors are ordinary classes:

```soli
# app/models/domain_errors.sl
class CurrencyMismatch < DomainError
end

class InsufficientFunds < DomainError
end

class InvoiceAlreadyPaid < DomainError
  static http_status: Int = 409
end
```

`DomainError` inherits `Error`, which carries a `message` and optional
`details`. What sets it apart is what happens when nobody catches it in a
served app: the request answers **422** with the error page showing its
message — a broken business rule is an answer to the request, not a crash —
and the `static http_status` above turns `InvoiceAlreadyPaid` into a 409. No
500 block lands in the log, and the action stays on the bytecode VM. Any other
uncaught `throw` is still a 500.

## The account and the invoice: aggregates on `Model`

Soli keeps aggregates on `Model` rather than asking for a parallel layer of
repositories and mappers. The model holds its value objects with `value_field`
and states its own rules:

```soli
# app/models/account.sl
class Account < Model
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
```

```soli
# app/models/invoice.sl
class Invoice < Model
  value_field :total, Amount
  value_field :paid, Amount
  validates("number", {"presence": true})
  validates("account_key", {"presence": true})

  invariant(:total, "must be more than zero") { @total.cents > 0 }
  invariant(:paid, "cannot exceed the total") { @paid.nil? || @total.covers?(@paid) }
  invariant(:status, "a paid invoice records its payment") { @status != "paid" || !@paid.nil? }

  def pay_from(account: Account)
    throw InvoiceAlreadyPaid.new("invoice #{@number} is already paid") if @status == "paid"

    account.debit(@total)
    @paid = @total
    @status = "paid"
  end
end
```

`value_field :total, Amount` stores the amount as an object of its fields and
gives it back as an `Amount` on every read. In SQLite, the row is:

```json
{"number":"F-001","status":"paid","total":{"cents":3000,"currency":"EUR"},"paid":{"cents":3000,"currency":"EUR"}, …}
```

Anything that is not an `Amount` (or a hash of its fields) is refused with
*must be a Amount*.

An `invariant` on a model is not an exception but a validation: a falsy one
puts `{field, message}` into `_errors` and the record is not saved, through
`create`, `save`, `update` or the static `Model.update`. Model invariants run
once every `validates` rule has passed, so `@total.cents` never meets a
missing total — that one is for `presence` to report. They are about the
record as a whole: `paid` alone and `status` alone are fine, but a paid
invoice with no payment recorded is not.

`pay_from` and `debit` are the aggregate's behaviour. Nothing outside these
classes sets `status` to `"paid"` or lowers a credit; code that wants an
invoice paid calls `pay_from`, and the rules come along.

## One use case, one transaction

Paying an invoice changes two records, and they change together or not at
all:

```soli
# app/services/pay_invoice.sl
class PayInvoice
  static def call(invoice_key: String) -> Invoice
    Invoice.transaction do
      invoice = Invoice.find(invoice_key)
      account = Account.find(invoice.account_key)
      invoice.pay_from(account)
      unless account.save && invoice.save
        throw DomainError.new("payment refused", {"account": account._errors, "invoice": invoice._errors})
      end
      invoice
    end
  end
end
```

`Model.transaction` commits when the block returns and rolls back when it
throws. A `throw` from `pay_from` or `debit` happens before anything is
written. The one after the saves matters more: `save` reports a refused
record by returning `false` and filling `_errors` rather than by raising, so
without that line a debited account could commit next to an invoice that
failed its invariants. Throwing there rolls the debit back — we checked: the
account still has its credit afterwards.

## The controller only asks

```soli
# app/controllers/invoices_controller.sl
class InvoicesController < Controller
  # POST /invoices
  def create(req)
    total = Amount.new(params["total_cents"], params["currency"] || "EUR")
    invoice = Invoice.create({
      "number": params["number"],
      "account_key": params["account_key"],
      "total": total,
      "status": "open"
    })
    return render_json({"errors": invoice._errors}, 422) if invoice._errors

    render_json(invoice, 201)
  end

  # POST /invoices/:id/pay — a DomainError left uncaught answers 422 (409 for InvoiceAlreadyPaid)
  def pay(req)
    invoice = PayInvoice.call(params["id"])
    render_json({"number": invoice.number, "status": invoice.status, "paid": invoice.paid.to_display})
  end

  # POST /api/invoices/:id/pay — the same, answering JSON
  def pay_json(req)
    try
      invoice = PayInvoice.call(params["id"])
      render_json({"status": invoice.status})
    catch DomainError e
      render_json({"error": e.message, "details": e.details}, 422)
    end
  end
end
```

`pay` has no error handling at all, and needs none: every way paying can fail
is a domain error with a status. An API that wants JSON instead of the error
page catches `DomainError` once, as `pay_json` does, and gets the message and
the details the domain attached.

## On the wire

An account with 50 € of credit, two invoices of 30 € and 25 €:

```text
POST /accounts {"name": "Acme", "credit_cents": 5000}
→ 201 {"_key":"8737f8e7-…","name":"Acme","credit":{"cents":5000,"currency":"EUR"}, …}

POST /invoices {"number": "F-003", "total_cents": 0, …}
→ 422 {"errors":[{"field":"total","message":"must be more than zero"}]}

POST /invoices/<F-001>/pay
→ 200 {"number":"F-001","status":"paid","paid":"30.00 EUR"}

POST /invoices/<F-001>/pay
→ 409  error page: "invoice F-001 is already paid"

POST /invoices/<F-002>/pay
→ 422  error page: "Acme has 20.00 EUR of credit, the invoice needs 25.00 EUR"

POST /api/invoices/<F-002>/pay
→ 422 {"error":"Acme has 20.00 EUR of credit, the invoice needs 25.00 EUR",
       "details":{"credit":{"cents":2000,"currency":"EUR"},"needed":{"cents":2500,"currency":"EUR"}}}

POST /api/invoices/<a USD invoice>/pay
→ 422 {"error":"cannot combine EUR and USD","details":null}

GET /accounts/<Acme>
→ 200 {"name":"Acme","credit":"20.00 EUR"}
```

`render_json` writes a value object as its fields, in the order they are
declared. In a script or a log line, `print(amount)` shows
`Amount(cents: 2000, currency: "EUR")`.

## What is not there yet

This is the first part of DDD support, and some of the rest is still to come:

- **Domain events and an outbox.** Today a use case that must notify
  something after paying enqueues a job itself. Events recorded by the
  aggregate and dispatched after commit come next, with optimistic locking for
  aggregates two requests edit at once.
- **Bounded contexts.** All application classes share one namespace (and a
  duplicate name now stops the boot rather than replacing a class silently).
  Contexts with their own namespaces are on the list after events.
- **Value objects as hash keys**, and a `value_field` that holds a list of
  them — an invoice's lines as values rather than a related model. Use
  `amount.to_s` as a key for now, and a `has_many` for lines.

The guides go further: [Value Objects](/docs/language/value-objects),
[Value fields and invariants](/docs/database/validations#value-fields-and-invariants)
and [error classes](/docs/language/error-handling#error-classes).
