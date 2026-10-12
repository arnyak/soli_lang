# Spam without a captcha

Put a contact form on the internet and within a week it receives offers of
SEO backlinks, replica watches and crypto signals. The usual answer is a
captcha. It works, at a price paid by the wrong people: a third-party script
on your page, a cookie banner to go with it, puzzles that screen readers
struggle with, and customers who give up on the third grid of traffic lights.

Most form spam is not clever. It comes from scripts that fill every field
they find, post without loading the page, and do it within a second. Soli
2.25 catches that kind with checks a person never notices, and catches the
patient kind with a score learnt from your own app's posts. There is no
script to embed, no external service, and nothing to click.

This post wires a contact form to it, sends it thirteen posts from bots and
people, and shows what came back. Every snippet and every output below comes
from that run.

<figure style="margin:1.5rem auto;max-width:1024px;">
  <img src="/images/blog/spam-without-a-captcha.svg" width="1024" height="576" alt="A post to /contacts goes through spam_check, cheapest check first: the honeypot field, the signed render time (at least 3 seconds, at most two days), an optional proof of work and rate budget, at most two links, and the learnt score under 0.9. Any failed check refuses the post with a reason, and the bot gets the same page a person would. A post that passes every check is accepted and learnt as ham. Every post lands in the /__soli/spam quarantine, where not spam and spam correct the model." style="display:block;width:100%;height:auto;border-radius:12px;border:1px solid #30363d;background:#0b0d0f;">
  <figcaption style="text-align:center;color:#8b949e;font-size:0.875rem;margin-top:0.5rem;">The cheapest checks run first. A refused bot is told nothing it could learn from.</figcaption>
</figure>

## The form already carries the traps

There is nothing to add to the view. `csrf_field()`, and so every
`form_with` and `button_to`, now renders two more fields next to the CSRF
token:

```erb
<form method="post" action="/contacts">
  <%- csrf_field() %>
  <label for="email">Email</label>
  <input id="email" name="email" type="email" required>
  <label for="text">Message</label>
  <textarea id="text" name="text" required></textarea>
  <button type="submit">Send</button>
</form>
```

```html
<input type="hidden" name="_csrf_token" value="2f7fec611102483091c6ecd3e0950593">
<div hidden aria-hidden="true"><label for="_soli_url_1">Website</label><input type="text" id="_soli_url_1" name="_soli_url" value="" tabindex="-1" autocomplete="off"></div>
<input type="hidden" name="_soli_ts" value="1791819705.QvY7jDvDoIuYSyUjbIHWPEAbn-6o9_sbWTu_4ew3v6w">
```

`_soli_url` is a **honeypot**: a "Website" field inside a `hidden`,
`aria-hidden` block, out of the tab order and with autofill off. A person
never sees it and a screen reader never announces it. A script that fills
every input fills it too. It has a real `<label for>` and an id of its own on
each form, so an accessibility audit that wants every field labelled does
not flag it.

`_soli_ts` is the **render time**, signed with a key derived from
`SOLI_SESSION_SECRET`. A post that lacks it never loaded the page. A post
that carries a forged one is refused just the same. One that arrives less than
three seconds after the render was not typed by a person.

## The action asks one question

```soli
class ContactsController < Controller
  # GET /contact
  def new
    @sent = params["sent"].present?
  end

  # POST /contacts
  def create
    refused = spam_check(req, {"fields": ["text"]})
    unless refused.nil?
      # A bot gets the same answer as a person, and learns nothing.
      return redirect("/contact?sent=1") unless refused["show"]

      # A person can act on it: reload the page and send again.
      return render("new", {"error": refused["reason"]}, {"status": 422})
    end

    Message.create(permit(params, {"email": true, "text": true}))
    redirect("/contact?sent=1")
  end
end
```

`spam_check(req)` answers `nil` when the post may go through. Otherwise it
answers a hash with three keys:

- `reason`: which check refused the post;
- `show`: whether a person could have caused it;
- `score`: the model's spam probability for the message.

`"fields": ["text"]` names the field that holds the message. Without it,
every posted field is read, except the framework's own and the ones that
look private (`pass`, `token`, `secret`, `card`, `iban`…). Here that would
have scored the email address along with the words.

The `show` branch is the important one. A bot that is told "you were too
fast" waits four seconds next time. A bot that is told "thanks, we'll answer
within a day" has nothing to adjust. So `honeypot`, `fast`, `links` and
`score` get the same redirect a real message gets. `token` and `expired` can
happen to a person: a page left open for three days, or a server restarted
without `SOLI_SESSION_SECRET`. They get a 422 and a sentence telling them to
reload.

## Thirteen posts

A small script played both sides against `soli serve --dev`. Bots loaded the
form and posted it at once, or filled the honeypot. People waited four
seconds, about the time it takes to type a sentence. Then a "patient" bot
waited five seconds, left the honeypot empty and sent the stamp back intact.
The model started empty:

```json
{"spam": 0, "ham": 0, "words": 0, "trained": false}
```

What `spam_check` answered, in order:

| # | Sender | Message | Answer |
|---|---|---|---|
| 1 | bot, 0 s | Get 500 high quality SEO backlinks today… | `fast`, score 0.50 |
| 2 | bot, 0 s | Cheap replica watches, free worldwide shipping… | `fast`, score 0.50 |
| 3 | bot, honeypot | Earn 3000 dollars a week from home with crypto… | `honeypot`, score 0.75 |
| 4 | bot, 0 s | SEO backlinks package: rank first page in 30 days… | `fast`, score 0.9992 |
| 5 | bot, honeypot | Buy cheap pills online without prescription… | `honeypot`, score 0.90 |
| 6 | bot, 0 s | Crypto signals guaranteed profit… | `fast`, score 0.9975 |
| 7–11 | person, 4 s | Hello, do you have a room for 40 people… (five messages) | `nil` |
| 12 | patient bot, 5 s | Guaranteed first page of Google: buy our SEO backlinks package today | `score`, score 0.99999944 |
| 13 | person, 5 s | Hello, can we move our room booking from November 14 to November 21? | `nil` |

Every bot got the same `302 /contact?sent=1` as the people. Two more runs
checked the other stamp failures. A post without `_soli_ts`, and one with a
forged `_soli_ts`, both answered `{"reason": "token", "show": true}` and the
422 page. A message with three links answered `links` (the default
`max_links` is 2).

Post 12 is why the score exists. That bot did everything a careful script
can do: it loaded the page, waited, filled only the visible fields and kept
the stamp. No trap caught it. Its words did, because the model had already
learnt them from posts 1 to 6.

## The score learns from your own posts

The score is a naive Bayes model, the technique behind the first good email
spam filters. It reads the words of a message, numbers (as one token) and the
host of each link. It is trained on this application's posts and nothing
else, so it learns what spam looks like on *your* form: a furniture shop and
a SaaS help desk get different spam.

Nobody has to label anything to start it. `spam_check` trains on the cases
it is sure about: a `honeypot` or `fast` hit is learnt as spam, and an
accepted post is learnt as ham. After the run:

```json
{"spam": 6, "ham": 6, "words": 94, "trained": true}
```

And three messages it had never seen:

```soli
SpamFilter.score("Hello, could we book the room for 12 people on December 3?")  # 0.0000020156
SpamFilter.score("Cheap SEO backlinks, guaranteed first page, order today")    # 0.9999969524
SpamFilter.score("Bonjour")                                                    # 0.5
```

`Bonjour` scores 0.5 because the model knows none of its words. 0.5 means no
opinion, and no opinion never refuses anything.

`spam_check` refuses on the score only once the model has seen five posts of
each kind (`trained: true`). The run shows why that rule is needed. While the
model had seen nothing but spam, *every* known word pointed to spam. The
second person's message, "Hi, I ordered a table last week and the delivery
date is not in my account yet", scored 0.90 when it arrived. It went through
anyway, because the model was not trained yet. Now that the model has seen
the people, the same kind of message scores near zero.

The model is also yours to drive. `SpamFilter.train(text, "spam")`,
`untrain`, `score`, `stats` and `reset` are plain builtins. Its state lives
in the app's database, and it keeps at most 20 000 words, forgetting the
rarest first.

## The quarantine

Every checked post, refused or accepted, is kept at `/__soli/spam`, next to
`/__soli/errors` and the slow queries:

<figure style="margin:1.5rem auto;max-width:1100px;">
  <img src="/images/blog/spam-without-a-captcha-quarantine.png" width="1100" height="920" alt="The /__soli/spam page, refused tab: the model panel says posts scoring 0.9 or more are refused, 6 learnt as spam, 6 as ham, 94 words. Seven refused posts follow, each with its score, message, path, client address, reason tag (score, honeypot, fast), time, and not spam and delete buttons. The patient bot's SEO message is first, refused on score 1.00; the two first bots show a faint 0.50, scored before the model knew any word." style="display:block;width:100%;height:auto;border-radius:12px;border:1px solid #30363d;background:#0b0d0f;">
  <figcaption style="text-align:center;color:#8b949e;font-size:0.875rem;margin-top:0.5rem;">The refused tab after the run. The colour of a score says how close it came to the refusal line.</figcaption>
</figure>

Each row shows the score the post got when it arrived. It is red from 0.9,
the line `spam_check` refuses at, amber when it leans spam, faint at 0.5 and
green when it leans ham. Then come the message, the path, the client
address, the reason (hover the tag to see what it means) and the time.

A wrong call is fixed with one click. "not spam" on a refused post moves it
to the accepted tab. The model forgets what it had learnt from that post, if
anything, and learns it as ham. "spam" on an accepted post does the reverse. The quarantine is how a mistake gets
noticed, and every correction makes the next score better. The newest 1000
posts are kept. Private-looking fields are never stored.

The page is protected like `/__soli/errors`: it is open to this machine under
`--dev`. Otherwise it needs `SOLI_SPAM_USER` and `SOLI_SPAM_PASSWORD`, a
`SOLI_SPAM_TOKEN`, or the shared `SOLI_ADMIN_*` credentials, and answers 404
when none is set.

## When the cheap checks are not enough

Two more layers are opt-in, for forms under real pressure.

**Proof of work.** `form_with(contact, {"url": "/contacts", "pow": true})`,
or `pow_field()` in a hand-written form, adds a signed challenge. The page
then loads `/__soli/pow.js`, which solves it in the background as soon as the
page shows: about 130 000 SHA-256 hashes, well under a second, usually done
before the visitor has finished typing. A submit before then waits for it.
`spam_check(req, {"pow": true})` verifies it, and each solution is accepted
once. It costs a person nothing, but posting ten thousand messages now costs
ten thousand solutions. It needs JavaScript, and a visitor without it gets
`pow` with `show: true`, so say so on the page.

**A budget per client.** `spam_check(req, {"rate": {"limit": 5, "window": 3600}})`
allows five posts an hour per client address on this path. Behind Cloudflare
or a proxy that puts the client in a header of its own, set
`SOLI_TRUST_PROXY=1` and `SOLI_CLIENT_IP_HEADER=cf-connecting-ip` (or
`x-real-ip`). `client_ip(req)` returns the same address to your own code.
The header is read only with trust proxy on; otherwise a client could claim
any address it likes.

The other limits are options too: `min_seconds`, `max_age`, `max_links`,
`max_score`. An option name `spam_check` does not know raises an error
rather than being ignored, so a typo cannot quietly turn a check off.

## What it does not stop

A person paid to paste spam by hand passes the honeypot, the timing and the
proof of work, because they are a person. Against them only the score
helps, and only once it has seen enough of their kind of message. A brand
new spam campaign scores 0.5 until the first corrections arrive.

The checks also have conditions of their own:

- The signing keys come from `SOLI_SESSION_SECRET`. Without it, as on a bare
  `soli serve --dev`, each process draws a key, and a page rendered before a
  restart comes back as `token`. Production should set it anyway, for
  sessions.
- Under `APP_ENV=test` the posts and the model are not stored, unless
  `SOLI_SPAM=on`, so a spec suite does not train your filter. The checks
  still run. `SOLI_SPAM=off` stops storing them everywhere.

## Try it

On Soli 2.25 or later, call `spam_check(req)` at the top of any action that
receives a public form, and send the same answer to every refusal whose
`show` is false. That is the whole integration. Then open `/__soli/spam`
after a week.

- [Spam on public forms](/docs/security/spam): every reason, option and
  builtin.
- [Observability](/docs/development-tools/observability#spam): the quarantine
  page next to errors and slow queries.
- [Forms](/docs/core-concepts/forms): `form_with`, `csrf_field`.
