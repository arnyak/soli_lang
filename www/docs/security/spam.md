# Spam on public forms

A contact form, a comment box, a sign-up page: anything a stranger can post
to gets spam. Soli stops most of it without a captcha, a third-party script or
a cookie banner, in four layers, cheapest first:

| Layer | What it catches | Cost to a person |
|---|---|---|
| Honeypot + signed render time | bots that fill every field, post without loading the page, or answer within seconds | none |
| Proof of work (opt-in) | bulk posting: each post costs real CPU | ~0.1 s in the background |
| Bayes score | messages that read like the spam this app already saw | none |
| Quarantine (`/__soli/spam`) | — it is where mistakes are seen and corrected, which trains the score | — |

## Quick start

`csrf_field()` — and so every `form_with` and `button_to` — already renders
the honeypot and the signed render time. The honeypot sits in a `hidden`,
`aria-hidden` block, with a `<label for>` and an id of its own per form, so an
accessibility check that wants every field labelled does not flag it. Check
the post in the action:

```soli
# POST /contacts
def create
  refused = spam_check(req)
  unless refused.nil?
    # A bot gets the same answer as a person, and learns nothing.
    return redirect("/contact#sent") unless refused["show"]

    # A person can act on it: reload the page, wait, enable JavaScript.
    return redirect("/contact#error")
  end

  ContactMailer.inquiry(params["email"], params["text"]).deliver_later
  redirect("/contact#sent")
end
```

`spam_check(req)` answers `nil` when the post may go through, or a hash:

| Key | Value |
|---|---|
| `reason` | `"honeypot"`, `"token"`, `"fast"`, `"expired"`, `"rate"`, `"pow"`, `"links"`, `"score"` |
| `show` | `true` when a person could have caused it and can fix it (`token`, `expired`, `pow`, `rate`); `false` for what only a bot does |
| `score` | the model's spam probability for the message, 0 to 1 |

A hand-written `<form method="post">` gets the fields from `<%- csrf_field() %>`
like any other form, or from `<%- spam_fields() %>` alone.

## The reasons

| Reason | Means | Shown |
|---|---|---|
| `honeypot` | the hidden `_soli_url` field was filled | no |
| `token` | no render time, or one this app did not sign (a post that never loaded the page) | yes |
| `fast` | posted less than `min_seconds` (3) after the page was rendered | no |
| `expired` | the page was rendered more than `max_age` (two days) ago | yes |
| `rate` | this client used up the `rate` budget on this path | yes |
| `pow` | the proof of work is missing, wrong, expired or already spent | yes |
| `links` | the message holds more than `max_links` (2) links | no |
| `score` | the trained model gives `max_score` (0.9) or more | no |

## Options

```soli
spam_check(req, {
  "min_seconds": 3,          # faster than this after the render is a bot
  "max_age": 172800,         # a page older than this must be reloaded
  "max_links": 2,            # http://, https:// and [url count as links
  "max_score": 0.9,          # once trained, refuse from this score
  "stamp": true,             # false for a form without csrf_field()/spam_fields()
  "pow": false,              # true: require a solved proof of work
  "rate": {"limit": 5, "window": 3600},  # posts per client and path; off by default
  "fields": ["text"],        # read only these fields as the message (name or contact[text])
  "record": true,            # keep the post in the quarantine
  "learn": true              # train the model on the certain cases
})
```

An unknown option is an error, not a silently ignored typo.

Which fields are the message: by default every posted field except the
framework's (`_`-prefixed) and private-looking ones (names containing `pass`,
`token`, `secret`, `card`, `cvv`, `cvc`, `iban`, `csrf`). Nested names are
read too: `contact[text]`.

## Proof of work

```erb
<%- form_with(contact, {"url": "/contacts", "pow": true}) do |f| -%>
```

or, in a hand-written form, `<%- pow_field() %>` (difficulty in bits,
`pow_field(18)`; 17 by default, at most 24). The page then loads
`/__soli/pow.js`, which starts solving as soon as the page shows: about
130 000 SHA-256 hashes, well under a second, usually done before the visitor
has finished typing. A submit before then waits for it. Check it with
`spam_check(req, {"pow": true})`; each solution is accepted once.

It needs JavaScript. A visitor without it gets `pow`, which is shown — tell
them so.

## The score

`spam_check` scores every message with a naive Bayes model learnt from this
application's own posts, and refuses on the score only once the model has seen
five posts of each kind. It learns from the certain cases by itself: a
honeypot or `fast` hit is spam, an accepted post is ham. Mistakes are
corrected on `/__soli/spam`, and each correction teaches it.

```soli
SpamFilter.train(text, "spam")     # or "ham"
SpamFilter.untrain(text, "spam")   # take a train() back
SpamFilter.score(text)             # 0.0 .. 1.0, 0.5 when nothing is known
SpamFilter.trained?                # five of each kind seen
SpamFilter.stats                   # {"spam": n, "ham": n, "words": n, "trained": bool}
SpamFilter.reset                   # forget everything
```

The model reads words, numbers (as one token) and the host of each link. It
keeps 20 000 words at most, forgetting the rarest first.

## The quarantine: `/__soli/spam`

Every checked post is kept — refused ones under **refused**, accepted ones
under **accepted** — with its fields (private ones left out), the client
address, the reason and the score. "not spam" on a refused post and "spam" on
an accepted one move it, and retrain the model accordingly. The newest 1000
posts are kept.

Access works like `/__soli/errors`: open to this machine under `--dev`;
otherwise `SOLI_SPAM_USER` + `SOLI_SPAM_PASSWORD`, `SOLI_SPAM_TOKEN`, or the
shared `SOLI_ADMIN_*`, and a 404 when none is set.

Posts and the model are stored in the app's database (`_soli_spam`,
`_soli_spam_model`). `SOLI_SPAM=off` stops storing them; under
`APP_ENV=test` they are not stored unless `SOLI_SPAM=on`. The checks work
either way.

## The client address: `client_ip(req)`

`spam_check` keys `rate` on the client's address, and `client_ip(req)` gives
it to your own code: the TCP peer, or — with trust proxy on — the right-most
`X-Forwarded-For` entry. Behind a proxy that puts the client in a header of
its own, name it:

```bash
SOLI_TRUST_PROXY=1
SOLI_CLIENT_IP_HEADER=cf-connecting-ip   # Cloudflare; or x-real-ip
```

The header is read only with trust proxy on: without it, a client could send
any address it likes.

## Keys

The render time and the proof-of-work challenges are signed with keys derived
from `SOLI_SESSION_SECRET`. Without a secret (a bare `soli serve --dev`), a
key is drawn per process: a page rendered before a restart comes back as
`token`.

## See also

- [Forms](/docs/core-concepts/forms) — `form_with`, `csrf_field`
- [Production security defaults](/docs/security/defaults)
- [Hardening builtins](/docs/builtins/hardening) — rate limiting, trust proxy
