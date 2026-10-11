# Value objects (`< ValueObject`), invariants, and the domain error classes.

class Amount < ValueObject
  cents: Int
  currency: String = "EUR"
  invariant(:cents, "cents must not be negative") { @cents >= 0 }

  def plus(other: Amount) -> Amount
    @with(cents: @cents + other.cents)
  end
end

class Email < ValueObject
  address: String

  new(address: String)
    @address = address.trim.downcase
  end

  invariant("must contain @") { @address.includes?("@") }
end

class InsufficientFunds < DomainError
end

describe("Value objects") do
  test("binds arguments to the declared fields, in order or by name") do
    assert_eq(Amount.new(500, "USD").to_h, {"cents": 500, "currency": "USD"})
    assert_eq(Amount.new(cents: 5).currency, "EUR")
    assert_eq(new Amount(7).cents, 7)
    assert_eq(Amount.new({"cents": 9}).cents, 9)
  end

  test("are equal when their fields are") do
    assert(Amount.new(500) == Amount.new(500, "EUR"))
    assert(Amount.new(500) != Amount.new(500, "USD"))
    assert([Amount.new(1), Amount.new(2)].includes?(Amount.new(2)))
    assert_eq([Amount.new(1), Amount.new(1), Amount.new(2)].uniq.length, 2)
  end

  test("are frozen once built") do
    amount = Amount.new(500)
    error = nil
    try
      amount.cents = 1
    catch e
      error = str(e)
    end
    assert(error.includes?("value objects are immutable"))
    assert_eq(amount.cents, 500)
  end

  test("with builds a changed copy through the constructor") do
    amount = Amount.new(500)
    assert_eq(amount.with(cents: 600).cents, 600)
    assert_eq(amount.with({"currency": "USD"}).currency, "USD")
    assert_eq(amount.cents, 500)
    assert(amount.plus(Amount.new(250)) == Amount.new(750))
    assert_eq(Email.new(" Ada@Example.COM ").with(address: "BOB@X.IO").address, "bob@x.io")
  end

  test("print as their fields") do
    assert_eq(Amount.new(500).to_s, "Amount(cents: 500, currency: \"EUR\")")
    assert_eq("#{Amount.new(1, "USD")}", "Amount(cents: 1, currency: \"USD\")")
  end
end

describe("Invariants") do
  test("a broken one raises InvariantViolation, a DomainError") do
    caught = nil
    try
      Amount.new(-5)
    catch InvariantViolation e
      caught = e
    end
    assert_eq(caught.message, "Amount: cents must not be negative")
    assert_eq(caught.details["field"], "cents")
    assert(caught.is_a?("DomainError"))
  end

  test("run after the constructor, on what it stored") do
    assert_eq(Email.new("  A@B.C ").address, "a@b.c")
    message = nil
    try
      Email.new("nope")
    catch DomainError e
      message = e.message
    end
    assert_eq(message, "Email: must contain @")
  end

  test("run again on with") do
    raised = false
    try
      Amount.new(1).with(cents: -1)
    catch InvariantViolation e
      raised = true
    end
    assert(raised)
  end
end

describe("Domain errors") do
  test("carry a message and details") do
    caught = nil
    try
      throw InsufficientFunds.new("balance too low", {"needed": 30})
    catch DomainError e
      caught = e
    end
    assert_eq(caught.message, "balance too low")
    assert_eq(caught.details["needed"], 30)
    assert(caught.is_a?("Error"))
  end
end
