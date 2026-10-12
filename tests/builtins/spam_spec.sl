# Spam defences for form posts: spam_fields, pow_field, spam_check, client_ip
# and the SpamFilter model. Recording to the quarantine is off under
# APP_ENV=test; the checks and the in-memory model work all the same.

# The signed render time spam_fields() puts in a form.
def spam_spec_stamp()
  html = spam_fields()
  html.split("name=\"_soli_ts\" value=\"")[1].split("\"")[0]
end

# A posted form, as `req` carries it.
def spam_spec_req(form, extra = nil)
  req = {"path": "/contact", "remote_addr": "203.0.113.5", "form": form}
  req = req.merge(extra) unless extra.nil?
  req
end

# Solve a pow_field() challenge the way /__soli/pow.js does.
def spam_spec_solve(challenge, bits)
  nonce = 0
  zeros = "0" * (bits / 4)
  while !sha256("#{challenge}:#{nonce}").starts_with?(zeros)
    nonce = nonce + 1
  end
  "#{challenge}:#{nonce}"
end

describe("spam defences") do
  before_each() do
    SpamFilter.reset
    RateLimiter.reset_all
  end

  describe("spam_fields()") do
    test("renders a hidden honeypot and a signed render time") do
      html = spam_fields()
      assert_contains(html, "<div hidden aria-hidden=\"true\"><label for=\"_soli_url_")
      assert_contains(html, "name=\"_soli_url\"")
      assert_contains(html, "name=\"_soli_ts\"")
      assert_match(spam_spec_stamp(), "^[0-9]+\\.[A-Za-z0-9_-]+$")
    end

    test("labels its honeypot, with an id of its own per form") do
      first = spam_fields()
      second = spam_fields()
      first_id = first.split("id=\"")[1].split("\"")[0]
      second_id = second.split("id=\"")[1].split("\"")[0]
      assert_contains(first, "<label for=\"" + first_id + "\">")
      assert(first_id != second_id)
    end
  end

  describe("spam_check(req)") do
    test("a form shown long enough ago, with a message, goes through") do
      req = spam_spec_req({"_soli_ts": spam_spec_stamp(), "email": "ann@example.com", "text": "Bonjour"})
      assert_null(spam_check(req, {"min_seconds": 0}))
    end

    test("a filled honeypot is a bot: a reason the visitor is not shown") do
      req = spam_spec_req({"_soli_ts": spam_spec_stamp(), "_soli_url": "http://spam", "text": "hi"})
      refused = spam_check(req, {"min_seconds": 0})
      assert_eq(refused["reason"], "honeypot")
      assert_eq(refused["show"], false)
    end

    test("no render time, or a forged one: token, shown") do
      assert_eq(spam_check(spam_spec_req({"text": "hi"}))["reason"], "token")
      forged = spam_spec_req({"_soli_ts": "1700000000.forged", "text": "hi"})
      refused = spam_check(forged, {"min_seconds": 0})
      assert_eq(refused["reason"], "token")
      assert_eq(refused["show"], true)
    end

    test("posted within three seconds of the render: fast") do
      req = spam_spec_req({"_soli_ts": spam_spec_stamp(), "text": "hi"})
      assert_eq(spam_check(req)["reason"], "fast")
    end

    test("stamp: false checks a form that has no render time") do
      assert_null(spam_check(spam_spec_req({"text": "hi"}), {"stamp": false}))
    end

    test("three links or more: links; two pass") do
      stamp = spam_spec_stamp()
      two = spam_spec_req({"_soli_ts": stamp, "text": "http://a https://b"})
      assert_null(spam_check(two, {"min_seconds": 0}))
      three = spam_spec_req({"_soli_ts": stamp, "text": "http://a https://b [url=c]"})
      assert_eq(spam_check(three, {"min_seconds": 0})["reason"], "links")
    end

    test("nested fields are read: contact[text]") do
      req = spam_spec_req({"_soli_ts": spam_spec_stamp(), "contact": {"text": "http://a http://b http://c"}})
      assert_eq(spam_check(req, {"min_seconds": 0})["reason"], "links")
    end

    test("private fields are not read as the message") do
      req = spam_spec_req({"_soli_ts": spam_spec_stamp(), "password": "http://a http://b http://c", "text": "hi"})
      assert_null(spam_check(req, {"min_seconds": 0}))
    end

    test("fields: limits the check to the named fields") do
      req = spam_spec_req({"_soli_ts": spam_spec_stamp(), "website": "http://a http://b http://c", "text": "hi"})
      assert_null(spam_check(req, {"min_seconds": 0, "fields": ["text"]}))
    end

    test("rate: the budget of one client on one path") do
      options = {"min_seconds": 0, "rate": {"limit": 1, "window": 60}}
      assert_null(spam_check(spam_spec_req({"_soli_ts": spam_spec_stamp(), "text": "hi"}), options))
      refused = spam_check(spam_spec_req({"_soli_ts": spam_spec_stamp(), "text": "again"}), options)
      assert_eq(refused["reason"], "rate")
      assert_eq(refused["show"], true)
    end

    test("pow: a missing or unsolved proof of work is refused, a solved one passes once") do
      html = pow_field(4)
      challenge = html.split("data-soli-pow=\"")[1].split("\"")[0]
      options = {"min_seconds": 0, "pow": true}
      assert_eq(spam_check(spam_spec_req({"_soli_ts": spam_spec_stamp(), "text": "hi"}), options)["reason"], "pow")

      solution = spam_spec_solve(challenge, 4)
      req = spam_spec_req({"_soli_ts": spam_spec_stamp(), "_soli_pow": solution, "text": "hi"})
      assert_null(spam_check(req, options))
      # A solution is spent once.
      assert_eq(spam_check(req, options)["reason"], "pow")
    end

    test("a trained model refuses what reads like spam") do
      5.times do
        SpamFilter.train("cheap pills casino bonus", "spam")
        SpamFilter.train("une question sur le concert de samedi", "ham")
      end
      refused = spam_check(spam_spec_req({"_soli_ts": spam_spec_stamp(), "text": "cheap casino pills"}), {"min_seconds": 0})
      assert_eq(refused["reason"], "score")
      assert_gt(refused["score"], 0.9)
      assert_null(spam_check(spam_spec_req({"_soli_ts": spam_spec_stamp(), "text": "le concert de samedi"}), {"min_seconds": 0}))
    end

    test("it learns: an accepted post as ham, a honeypot hit as spam") do
      spam_check(spam_spec_req({"_soli_ts": spam_spec_stamp(), "text": "Bonjour"}), {"min_seconds": 0})
      spam_check(spam_spec_req({"_soli_ts": spam_spec_stamp(), "_soli_url": "x", "text": "buy now"}), {"min_seconds": 0})
      assert_eq(SpamFilter.stats["ham"], 1)
      assert_eq(SpamFilter.stats["spam"], 1)
    end

    test("learn: false leaves the model alone") do
      spam_check(spam_spec_req({"_soli_ts": spam_spec_stamp(), "text": "Bonjour"}), {"min_seconds": 0, "learn": false})
      assert_eq(SpamFilter.stats["ham"], 0)
    end

    test("an unknown option is an error, not a silent default") do
      assert_raises(fn() { spam_check(spam_spec_req({}), {"min_secs": 0}) })
    end
  end

  describe("SpamFilter") do
    test("scores 0.5 until it has seen something") do
      assert_eq(SpamFilter.score("anything"), 0.5)
      assert_eq(SpamFilter.trained?, false)
    end

    test("untrain takes a document back") do
      SpamFilter.train("cheap pills", "spam")
      SpamFilter.untrain("cheap pills", "spam")
      assert_eq(SpamFilter.stats, {"spam": 0, "ham": 0, "words": 0, "trained": false})
    end

    test("the label is spam or ham") do
      assert_raises(fn() { SpamFilter.train("x", "eggs") })
    end
  end

  describe("client_ip(req)") do
    test("the TCP peer by default, even when the request names another") do
      req = {"remote_addr": "203.0.113.5", "headers": {"x-forwarded-for": "198.51.100.1"}}
      assert_eq(client_ip(req), "203.0.113.5")
    end

    test("nil outside a request") do
      assert_null(client_ip({}))
    end
  end
end
