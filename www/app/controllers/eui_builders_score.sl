# EUI view builders, part 7: music notation.
#
#   score("\\relative c' { \\time 3/4 c4( d e) | g2. \\bar \"|.\" }",
#         {"width": 640})
#
# A score is engraved on the server and drawn as one `canvas`: staff lines,
# stems and bar lines as rectangles, and every curved thing — a notehead, a
# clef, a beam, a slur that thickens in the middle — as a fill (03 §1.1,
# kind 5) cut from the outlines of Emmentaler, LilyPond's own music font
# (`eui_builders_smufl.sl`, keyed by SMuFL's glyph names).
# No font travels and no text node is involved: a glyph lands at the size
# and the place the engraving wants, to the hundredth of a pixel.
#
# The input is a subset of LilyPond's own language, because LilyPond is
# what this tries to look like and the person writing a score already knows
# it: `\relative`, `\clef`, `\key`, `\time`, `\bar`, notes with `is`/`es`,
# `'` and `,`, durations 1–32 with dots, rests (`r`, and `R` for a whole
# bar), chords `< >`, ties `~`, slurs `( )` and beams `[ ]`. Anything else
# is refused with its position — a score that silently lost a note would
# look almost right, which is the costly way to be wrong (03 §4).
#
# The rules are LilyPond's where they can be stated in a line: spacing
# grows by 1.2 staff spaces each time a duration doubles from the shortest
# (`spacing-increment`, `shortest-duration-space`), stems are 3.5 spaces
# and reach the middle line, beam ends are quanted so they sit, straddle or
# hang on a staff line, and a slur's height is `height-limit · 2/π ·
# atan(π/2 · ratio / height-limit · width)`. What LilyPond does that this
# does not: several staves, lyrics, dynamics, tuplets, grace notes, cross-
# staff anything, and a page breaker better than greedy.
#
# Every length below is in staff spaces, y down, the top staff line at 0
# and the bottom one at 4. A staff position counts half spaces up from the
# middle line, as LilyPond's does: the top line is 4, the bottom one -4.

const SCORE_MEMO = {}
# The dynamics `score()` prints, each a run of the music font's letters.
const SCORE_DYNAMICS = ["pppp", "ppp", "pp", "p", "mp", "mf", "f", "ff", "fff", "ffff", "fp", "sf", "sff", "sp", "spp", "sfz", "sfp", "rfz", "rf", "fz", "n"]
# Articulations: their glyph above and below, LilyPond's padding, and its
# priority — the lower the nearer the note. `side` 0 is opposite the stem,
# -1 above whatever the stem does; `quant` keeps one in a space of the staff.
const SCORE_SCRIPTS = {
  "staccato": {"up": "articStaccatoAbove", "down": "articStaccatoAbove", "pad": 0.2, "prio": -100, "side": 0, "quant": true},
  "tenuto": {"up": "articTenutoAbove", "down": "articTenutoAbove", "pad": 0.2, "prio": -50, "side": 0, "quant": true},
  "accent": {"up": "articAccentAbove", "down": "articAccentAbove", "pad": 0.2, "prio": 0, "side": 0, "quant": false},
  "marcato": {"up": "articMarcatoAbove", "down": "articMarcatoBelow", "pad": 0.2, "prio": 0, "side": 0, "quant": true},
  "staccatissimo": {"up": "articStaccatissimoAbove", "down": "articStaccatissimoBelow", "pad": 0.2, "prio": 0, "side": 0, "quant": false},
  "portato": {"up": "articTenutoStaccatoAbove", "down": "articTenutoStaccatoBelow", "pad": 0.45, "prio": 0, "side": 0, "quant": false},
  "fermata": {"up": "fermataAbove", "down": "fermataBelow", "pad": 0.4, "prio": 4000, "side": -1, "quant": false}
}

# The thicknesses, LilyPond's defaults at its staff size 20, in staff
# spaces. LilyPond counts most of them in `line-thickness`, a tenth of a
# space: a staff line is one, a stem 1.3, a thin bar line 1.9, a thick one
# 6 with a kern of 3 before it; a ledger line is one plus a tenth of a
# space and reaches a quarter of the head past it each side.
const SCORE_RULE = {
  "staff": 0.1,
  "stem": 0.13,
  "ledger": 0.2,
  "ledger_out": 0.25,
  "thin": 0.19,
  "thick": 0.6,
  "kern": 0.3,
  "beam": 0.48,
  "beam_step": 0.75,
  "curve_tip": 0.08,
  "curve_mid": 0.2
}

# ---- The builder -----------------------------------------------------------

# `opts`: "width" (px, default 600), "staff_space" (px, default 8),
# "colour" (a role, default "text.default"), "marks" — a hash from an
# item's number (its place among the notes and rests, from 0, as a string)
# to the role it is drawn in instead: how an editor shows what is selected —
# and "page": "a4", which lays the music out on A4 sheets at LilyPond's
# staff size and answers a column of pages `width` px wide.
def score(src, opts)
  width = opts["width"] ?? 600
  if opts["page"] == "a4"
    sheets = score_pages(src, opts)["pages"]
    return column({"gap": 6, "width": width}, sheets.map { |sheet| score_sheet(sheet, width) })
  end
  sp = opts["staff_space"] ?? 8
  engraved = score_layout(src, float(width) / sp, {})
  score_band_column(engraved, sp, opts, width, int(Math.ceil(engraved["height"] * sp)))
end

# A4 at LilyPond's default staff size, 20 pt — a staff space of 5 pt, 1.764
# mm — and its default margins: 10 mm at the sides, 5 at the top, 6 at the
# bottom, the first system indented 15. In staff spaces.
def score_a4()
  space = 25.4 * 5.0 / 72.0
  {"w": 210.0 / space, "h": 297.0 / space, "left": 10.0 / space, "right": 10.0 / space, "top": 5.0 / space, "bottom": 6.0 / space, "indent": 15.0 / space}
end

# The music on A4: the engraving, the px per staff space that makes a
# sheet `width` px wide, and one canvas a page.
def score_pages(src, opts)
  paper = score_a4()
  width = opts["width"] ?? 600
  sp = float(width) / paper["w"]
  line_w = paper["w"] - paper["left"] - paper["right"]
  engraved = score_layout(src, line_w, {"page_h": paper["h"], "top": paper["top"], "bottom": paper["bottom"], "left": paper["left"], "indent": paper["indent"], "gap": 12.0})
  height = int(paper["h"] * sp)
  sheets = engraved["pages"].map { |pg| score_band_column(engraved, sp, opts.merge({"page_index": pg["index"]}), width, height) }
  {"engraved": engraved, "sp": sp, "pages": sheets, "height": height}
end

# A sheet of paper: the page's own canvas on the raised surface, a shadow
# under it, so a screen shows where each page ends.
def score_sheet(sheet, width)
  {"k": "box", "s": {"bg": "surface.raised", "shadow": 2, "width": width, "border": 1, "border_color": "border.subtle"}, "c": [sheet]}
end

# The engraving a view draws, by `score_engrave_page`'s arguments: lang's
# native engraver's (`eui_score_layout`, the `eui-score` crate) when the
# server has it, this file's own otherwise. The two place everything alike
# to the hundredth of a pixel (eui-score's golden tests hold them to it);
# the native one answers in a millisecond what this file takes a fifth of a
# second over for a symphony, and keeps the engraving itself on its side —
# what it hands back is what a view reads: the systems, their pages and
# tops, and each bar's items with their numbers and x. `score_band_column`
# draws either.
# A refusal comes back as `{"error": message}` and is thrown here, word
# for word what `score_refuse` throws.
def score_layout(src, width_ss, layout)
  return score_engrave_page(src, width_ss, layout) unless defined("eui_score_layout")

  laid = eui_score_layout(src, width_ss, layout)
  throw laid["error"] unless laid["error"].nil?
  laid
end

# Parse, lay out and place everything, in staff spaces: what `score_paths`
# draws. Separate so a spec can ask where a thing went without a client.
def score_engrave(src, width_ss)
  score_engrave_page(src, width_ss, {})
end

# The same, laid out on paper when `layout` says how: `page_h` (absent: one
# endless page, a screen), the margins `top`, `bottom` and `left`, the first
# system's `indent`, and `gap`, the distance from one staff to the next.
# Every coordinate in the answer is the page's own.
def score_engrave_page(src, width_ss, layout)
  # The same source at the same width is engraved once: a click, an arrow
  # or the playhead changes what is lit, not the engraving. The answer is
  # never changed after it is made, so it can be handed out again.
  key = src + "|" + str(width_ss) + "|" + str(layout["page_h"]) + "|" + str(layout["left"]) + "|" + str(layout["indent"]) + "|" + str(layout["top"]) + "|" + str(layout["bottom"]) + "|" + str(layout["gap"])
  hit = score_memo_get("engraving", key)
  return hit unless hit.nil?

  engraved = score_engrave_fresh(src, width_ss, layout)
  engraved["memo_key"] = key
  score_memo_put("engraving", key, engraved, 8)
end

# A small cache per worker, by kind: the last `size` answers, the oldest
# dropped first.
def score_memo_get(kind, key)
  store = SCORE_MEMO[kind]
  return nil if store.nil?

  store["v"][key]
end

def score_memo_put(kind, key, value, size)
  SCORE_MEMO[kind] = {"v": {}, "order": []} unless SCORE_MEMO.has_key(kind)
  store = SCORE_MEMO[kind]
  unless store["v"].has_key(key)
    store["order"].push(key)
    if store["order"].length > size
      gone = store["order"][0]
      store["order"] = range(1, store["order"].length).map { |k| store["order"][k] }
      store["v"].delete(gone)
    end
  end
  store["v"][key] = value
  value
end

def score_engrave_fresh(src, width_ss, layout)
  parsed = score_parse(src)
  return score_engrave_many(parsed, width_ss, layout) if parsed["staves"].length > 1

  bars = score_measures(parsed["events"])
  score_beams(bars)
  score_columns(bars, score_shortest(bars))
  left = layout["left"] ?? 0.0
  indent = layout["indent"] ?? 0.0
  systems = score_break(bars, width_ss, indent)
  # A line after the first opens with its bar number, set just left of the
  # staff as LilyPond sets it. Paper has a margin for it to stand in; a
  # screen has none, so music that takes more than one line there gives
  # up the room the widest number needs, and is broken again in what is left.
  if layout["left"].nil? && systems.length > 1
    left = score_text_width(str(bars[-1]["number"]), "regular", score_em(-2.0)) + 0.2
    width_ss -= left
    for bar in bars
      bar["bar_drawn"] = nil
      bar["open_repeat"] = nil
    end
    systems = score_break(bars, width_ss, indent)
  end
  score_place(systems, width_ss, left, indent)
  score_curves(parsed, systems)
  score_marks(systems)
  head = score_header_lines(parsed["header"], width_ss)
  pages = score_stack(systems, layout, head)
  bottom = 0.0
  for sys in systems
    bottom = sys["bottom"] if sys["bottom"] > bottom
  end
  {"systems": systems, "height": bottom + 1.0, "width": width_ss, "left": left, "header": head, "pages": pages, "paper": layout["page_h"], "numbered": score_numbered(layout)}
end

# The ticks in a whole note. 256 × 105: a 1/32 with three dots is still a
# whole number of ticks, and so is any of them in a triplet, a quintuplet,
# a sextuplet or a septuplet.
def score_whole()
  26880
end

# ---- Several staves --------------------------------------------------------
#
# A piano's two staves, an orchestra's dozen: each staff is read, measured,
# beamed and spaced on its own, exactly as a single one is. What they share
# is horizontal — LilyPond's columns: every moment any staff has a note on
# is one column, as far from the next as the shortest note sounding across
# it asks, and as wide as its widest member. A row of those columns, one
# "master" bar per bar, is broken into lines and placed like a single
# staff's bars, and each staff's notes take their column's place. Then each
# staff is a system of its own for its ties, slurs and marks, and the
# staves of a line are stacked: nine spaces from top line to top line, or
# what their ink needs and a space more.

def score_engrave_many(parsed, width_ss, layout)
  staves = parsed["staves"]
  all_bars = staves.map { |stf| score_measures(stf["events"]) }
  count = all_bars[0].length
  for bars, si in all_bars
    score_refuse("staff #{si + 1} has #{bars.length} bars and the first has #{count}: every staff has the same bars", 0) if bars.length != count
    for bar, k in bars
      score_refuse("bar #{k + 1} is not as long in staff #{si + 1} as in the first", 0) if bar["length"] * (bar["span"] ?? 1) != all_bars[0][k]["length"] * (all_bars[0][k]["span"] ?? 1)
    end
  end
  flat = []
  for bars in all_bars
    score_beams(bars)
    flat = flat + bars
  end
  shortest = score_shortest(flat)
  for bars in all_bars
    score_columns(bars, shortest)
  end
  master = range(0, count).map { |k| score_master_bar(all_bars.map { |bars| bars[k] }, shortest) }
  # Room on the left for the names and for the brace or the bracket.
  deco = score_groups_width(parsed["groups"], staves.length)
  em = score_em(0.0)
  names = staves.map { |stf| (stf["props"] ?? {})["instrumentName"] ?? "" } + parsed["groups"].map { |g| g["name"] }
  shorts = staves.map { |stf| (stf["props"] ?? {})["shortInstrumentName"] ?? "" } + parsed["groups"].map { |g| g["short"] }
  name_w = names.map { |nm| nm == "" ? 0.0 : score_text_width(nm, "regular", em) + 1.0 }.reduce(fn(acc, w) score_max(acc, w), 0.0)
  short_w = shorts.map { |nm| nm == "" ? 0.0 : score_text_width(nm, "regular", em) + 1.0 }.reduce(fn(acc, w) score_max(acc, w), 0.0)
  left = layout["left"] ?? 0.0
  # On paper the names may hang into the left margin, as LilyPond's do:
  # the first line keeps its indent unless they need more than it and the
  # margin together; a screen has no margin to hang them in.
  indent = score_max(layout["indent"] ?? 0.0, deco + name_w - left)
  rest = score_max(deco, deco + short_w - left)
  systems = score_break(master, width_ss, indent, rest)
  score_place(systems, width_ss, left, indent, rest)
  outer = []
  for sys, si in systems
    score_spread(sys)
    staff_systems = []
    for stf, s in staves
      ss = {"bars": sys["bars"].map { |mb| mb["staff_bars"][s] }, "staff_index": s}
      for key in ["left", "prefix", "right", "bar_end", "k", "courtesy"]
        ss[key] = sys[key]
      end
      if si + 1 < systems.length && (sys["courtesy"] ?? 0.0) > 0.0
        ss["courtesy_bar"] = score_courtesy_of(systems[si + 1]["bars"][0]["staff_bars"][s])
      end
      staff_systems.push(ss)
    end
    # The opening lines up across the staves: every key starts after the
    # widest clef, every metre after the widest key.
    clef_w = 0.0
    key_w = 0.0
    for ss in staff_systems
      first = ss["bars"][0]
      clef_w = score_max(clef_w, score_glyph(score_clef_glyph(first["clef"]))["advance"])
      key_w = score_max(key_w, first["fifths"] == 0 ? 0.0 : score_key_width(first["fifths"]))
    end
    for ss in staff_systems
      ss["clef_w"] = clef_w
      ss["key_w"] = key_w
    end
    outer.push({"staves": staff_systems, "bars": staff_systems[0]["bars"], "left": sys["left"], "right": sys["right"], "first_line": si == 0})
  end
  for s in range(0, staves.length)
    lines = outer.map { |o| o["staves"][s] }
    score_curves(parsed, lines)
    score_marks(lines)
  end
  for o in outer
    score_stack_staves(o, parsed["groups"], staves)
  end
  head = score_header_lines(parsed["header"], width_ss)
  pages = score_stack(outer, layout, head)
  bottom = 0.0
  for o in outer
    for ss, s in o["staves"]
      ss["top"] = o["top"] + o["offsets"][s]
      ss["page"] = o["page"]
    end
    bottom = o["bottom"] if o["bottom"] > bottom
  end
  {"systems": outer, "height": bottom + 1.0, "width": width_ss, "left": left, "header": head, "pages": pages, "paper": layout["page_h"], "numbered": score_numbered(layout)}
end

# One bar of the shared row: the first staff's bar for what a bar is
# (its number, its bar line, its repeats), and as its items one column per
# moment any staff starts something on.
def score_master_bar(staff_bars, shortest)
  first = staff_bars[0]
  mb = {}
  for key in first.keys
    mb[key] = first[key] unless key == "items"
  end
  mb["staff_bars"] = staff_bars
  starts = []
  for sb in staff_bars
    for ev in sb["items"]
      starts.push(ev["start"]) unless starts.includes?(ev["start"])
    end
  end
  starts = starts.sort()
  length = first["length"] * (first["span"] ?? 1)
  cols = []
  for at, ci in starts
    upto = ci + 1 < starts.length ? starts[ci + 1] : length
    col = {"k": "col", "start": at, "ticks": upto - at, "ideal": nil, "left": 0.0, "right": 0.0, "members": []}
    for sb in staff_bars
      items = sb["items"]
      for ev, j in items
        next unless ev["start"] == at

        col["members"].push(ev)
        own = ev["ticks"] * (ev["mm"] ?? 1)
        # A note that sounds on past the next column is spaced, here, as
        # the time to that column, as LilyPond spaces a held note.
        want = own <= upto - at ? ev["ideal"] : score_duration_space(upto - at, shortest)
        col["ideal"] = col["ideal"].nil? ? want : score_min(col["ideal"], want)
        col["left"] = score_max(col["left"], ev["left"])
        after = j + 1 < items.length ? items[j + 1]["start"] : length
        col["right"] = score_max(col["right"], ev["right"]) if after == upto
      end
    end
    cols.push(col)
  end
  mb["items"] = cols
  mb
end

# The shared row's places, down to each staff: bar edges, repeat signs,
# each column's x to its notes; a bar of rest centred in its bar; then the
# stems and beams, which need the places.
def score_spread(sys)
  for mb in sys["bars"]
    content0 = mb["items"].length > 0 ? mb["items"][0]["x"] - 1.2 - mb["items"][0]["left"] : mb["x0"]
    for sb in mb["staff_bars"]
      for key in ["x0", "x1", "bar_drawn", "open_repeat", "open_repeat_x"]
        sb[key] = mb[key]
      end
    end
    for col in mb["items"]
      for ev in col["members"]
        ev["x"] = col["x"]
      end
    end
    for sb in mb["staff_bars"]
      items = sb["items"]
      if items.length == 1 && items[0]["k"] == "rest" && (items[0]["full"] == true || items[0]["ticks"] == sb["length"])
        items[0]["x"] = (content0 + mb["x1"]) / 2.0 - score_glyph("restWhole")["advance"] / 2.0
        items[0]["whole_bar"] = true
        items[0]["span0"] = content0
        items[0]["span1"] = mb["x1"]
      end
    end
  end
  for s in range(0, sys["bars"][0]["staff_bars"].length)
    score_stems_beams(sys["bars"].map { |mb| mb["staff_bars"][s] })
  end
end

# How much room the braces and brackets take left of the staves: each one,
# and its padding, a level further out for a group inside a group.
def score_groups_width(groups, count)
  widest = 0.0
  for g in groups
    next if g["kind"] == "none"

    widest = score_max(widest, (g["depth"] + 1) * 1.6)
  end
  widest + (count > 1 ? 0.3 : 0.0)
end

# A line's staves stacked: top line to top line at least nine spaces, or
# what the ink of the two needs and a space between. Where bar lines run
# through (a piano's brace, a bracket), each staff's reach down to the next.
def score_stack_staves(sys, groups, staves)
  reaches = sys["staves"].map { |ss| score_reach(ss) }
  offsets = [0.0]
  for s in range(1, reaches.length)
    offsets.push(score_max(offsets[s - 1] + 9.0, offsets[s - 1] + reaches[s - 1][1] + 1.0 - reaches[s][0]))
  end
  sys["offsets"] = offsets
  sys["reach"] = [reaches[0][0], offsets[-1] + reaches[-1][1]]
  sys["groups"] = groups
  sys["names"] = staves.map { |stf| sys["first_line"] ? ((stf["props"] ?? {})["instrumentName"] ?? "") : ((stf["props"] ?? {})["shortInstrumentName"] ?? "") }
  for ss, s in sys["staves"]
    through = groups.any? { |g| (g["kind"] == "brace" || g["kind"] == "bracket") && g["first"] <= s && s < g["last"] }
    ss["connect_down"] = through ? offsets[s + 1] - offsets[s] - 4.0 : 0.0
  end
end

def score_glyphs()
  SCORE_MEMO["glyphs"] = smufl_glyph_table() unless SCORE_MEMO.has_key("glyphs")
  SCORE_MEMO["glyphs"]
end

def score_glyph(name)
  score_glyphs()[name]
end

# ---- Text ------------------------------------------------------------------
#
# The words a score prints — its titles, its tempo marks — are drawn like
# everything else on it: fills, from the outlines of TeX Gyre Schola, the
# face LilyPond sets its text in (`eui_builders_letters.sl`). A size is the
# em in staff spaces; LilyPond's text is 11 pt on a 20 pt staff, 2.2 spaces,
# and each step of its `font-size` multiplies that by the sixth root of two.

def score_letters()
  SCORE_MEMO["letters"] = letter_glyph_table() unless SCORE_MEMO.has_key("letters")
  SCORE_MEMO["letters"]
end

def score_em(font_size)
  2.2 * Math.exp(font_size * 0.1155245300933242)
end

# A letter the face has not got is a quarter-em space: a title with one
# odd character still prints, with a gap where it was.
def score_text_width(words, weight, em)
  face = score_letters()[weight]
  total = 0
  for ch in words.chars()
    total += face.has_key(ch) ? face[ch]["a"] : 250
  end
  total * em / 1000.0
end

# Draws `words` with its baseline at `y`, starting at `x`; answers the x it
# ended at.
def score_draw_text(paths, ink, words, weight, x, y, em, sp)
  face = score_letters()[weight]
  k = em / 1000.0
  at = x
  for ch in words.chars()
    if face.has_key(ch)
      g = face[ch]
      paths.push(score_fill_k(ink, g["f"], at, y, k, sp)) if g["f"].length > 0
      at += g["a"] * k
    else
      at += 0.25 * em
    end
  end
  at
end

# The title block, LilyPond's `bookTitleMarkup`: the dedication, a huge bold
# title, a large bold subtitle, a smaller one, then poet left, instrument
# centre and composer right, then meter left and arranger right — each line
# a `fill-line` across the width, baselines 3.5 spaces apart unless a line
# is taller. Answers the lines with their baselines, and where they end.
def score_header_lines(header, width)
  rows = [
    [ ["", "regular", 0.0], [header["dedication"] ?? "", "regular", 0.0], ["", "regular", 0.0] ],
    [ ["", "bold", 4.0], [header["title"] ?? "", "bold", 4.0], ["", "bold", 4.0] ],
    [ ["", "bold", 1.0], [header["subtitle"] ?? "", "bold", 1.0], ["", "bold", 1.0] ],
    [ ["", "bold", -1.0], [header["subsubtitle"] ?? "", "bold", -1.0], ["", "bold", -1.0] ],
    [ [header["poet"] ?? "", "regular", 0.0], [header["instrument"] ?? "", "bold", 1.0], [header["composer"] ?? "", "regular", 0.0] ],
    [ [header["meter"] ?? "", "regular", 0.0], ["", "regular", 0.0], [header["arranger"] ?? "", "regular", 0.0] ]
  ]
  out = []
  y = 0.0
  prev_descent = 0.0
  for row in rows
    tallest = 0.0
    for cell in row
      tallest = score_max(tallest, score_em(cell[2])) if cell[0] != ""
    end
    next if tallest == 0.0

    ascent = 0.72 * tallest
    y = out.length == 0 ? ascent : score_max(y + 3.5, y + prev_descent + ascent + 0.3)
    cells = []
    for cell, ci in row
      next if cell[0] == ""

      em = score_em(cell[2])
      w = score_text_width(cell[0], cell[1], em)
      x = 0.0
      x = (width - w) / 2.0 if ci == 1
      x = width - w if ci == 2
      cells.push({"text": cell[0], "weight": cell[1], "em": em, "x": x})
    end
    out.push({"y": y, "cells": cells})
    prev_descent = 0.25 * tallest
  end
  {"lines": out, "bottom": out.length == 0 ? 0.0 : y + prev_descent}
end

# A fill in its own units scaled by `k`, then moved and scaled to px: how a
# letter, kept in thousandths of an em, or a small note in a tempo mark is
# drawn.
def score_fill_k(ink, cmds, ox, oy, k, sp)
  out = [5, ink]
  i = 0
  n = cmds.length
  while i < n
    c = cmds[i]
    out.push(c)
    args = [2, 2, 4, 6, 0][c]
    for jj in 0..args
      v = cmds[i + 1 + jj]
      out.push(score_r((jj % 2 == 0 ? ox + v * k : oy + v * k) * sp))
    end
    i += 1 + args
  end
  out
end

def score_max(u, v)
  u > v ? u : v
end

def score_min(u, v)
  u < v ? u : v
end

# A modulo that is never negative: Soli's `%` keeps the dividend's sign.
def score_mod(u, m)
  (u % m + m) % m
end

def score_log2(v)
  Math.log(float(v)) / Math.log(2.0)
end

def score_refuse(what, at)
  throw "score: #{what} (at character #{at})"
end

# ---- Reading LilyPond ------------------------------------------------------

def score_tokens(src)
  cs = src.chars()
  out = []
  i = 0
  n = cs.length
  while i < n
    ch = cs[i]
    if ch == " " || ch == "\n" || ch == "\t" || ch == "\r"
      i += 1
    elsif ch == "%"
      while i < n && cs[i] != "\n"
        i += 1
      end
    elsif ch == "\\" && i + 1 < n && "<>!".contains(cs[i + 1])
      # The hairpins: `\<`, `\>`, and `\!` that ends one.
      out.push({"t": "cmd", "v": cs[i + 1], "at": i})
      i += 2
    elsif ch == "\\"
      jj = i + 1
      word = ""
      while jj < n && score_letter?(cs[jj])
        word += cs[jj]
        jj += 1
      end
      score_refuse("a backslash with no command after it", i) if word == ""
      out.push({"t": "cmd", "v": word, "at": i})
      i = jj
    elsif ch == "\""
      jj = i + 1
      word = ""
      while jj < n && cs[jj] != "\""
        word += cs[jj]
        jj += 1
      end
      score_refuse("a string that is never closed", i) if jj >= n
      out.push({"t": "str", "v": word, "at": i})
      i = jj + 1
    elsif "{}<>[]()~|.=*-^_!#".contains(ch)
      out.push({"t": ch, "v": ch, "at": i})
      i += 1
    elsif score_digit?(ch)
      jj = i
      word = ""
      while jj < n && (score_digit?(cs[jj]) || cs[jj] == "/")
        word += cs[jj]
        jj += 1
      end
      out.push({"t": "num", "v": word, "at": i})
      i = jj
    elsif score_letter?(ch)
      jj = i
      word = ""
      while jj < n && score_letter?(cs[jj])
        word += cs[jj]
        jj += 1
      end
      marks = 0
      while jj < n && (cs[jj] == "'" || cs[jj] == ",")
        marks += cs[jj] == "'" ? 1 : -1
        jj += 1
      end
      out.push({"t": "word", "v": word, "marks": marks, "at": i})
      i = jj
    else
      score_refuse("'#{ch}' is not part of the notation this reads", i)
    end
  end
  out
end

def score_letter?(ch)
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".contains(ch)
end

def score_digit?(ch)
  "0123456789".contains(ch)
end

# A note name, Dutch as LilyPond's default: `c` … `b`, `is` sharp, `es`
# flat (`as`, `es` for a and e), doubled for double. `nil` if it is not one.
def score_pitch_name(word)
  return nil if word.length == 0

  step = "cdefgab".index_of(word.chars()[0])
  return nil if step < 0

  rest = word.length > 1 ? word.substring(1, word.length) : ""
  alter = nil
  alter = 0 if rest == ""
  alter = 1 if rest == "is"
  alter = 2 if rest == "isis"
  alter = -1 if rest == "es"
  alter = -2 if rest == "eses"
  alter = -1 if rest == "s" && (step == 2 || step == 5)
  alter = -2 if rest == "ses" && (step == 2 || step == 5)
  return nil if alter.nil?

  {"step": step, "alter": alter}
end

# The diatonic number of a pitch: `c'` (middle C) is 7, one step is one.
# `\relative` picks the octave that puts the note within a fourth of the
# one before it, then moves it by its marks.
def score_resolve(name, marks, ref)
  return name["step"] + 7 * marks if ref.nil?

  ref_step = score_mod(ref, 7)
  d = ref - ref_step + name["step"]
  d -= 7 if d - ref > 3
  d += 7 if ref - d > 3
  d + 7 * marks
end

def score_parse(src)
  toks = score_tokens(src)
  st = {"header": {}, "counter": 0, "notes": 0}
  i = score_preamble(toks, 0, st)
  # `\\score { … \\layout { } \\midi { } }`, as LilyPond files are written:
  # the music, and blocks that say how to print it and play it, which this
  # engraver does not need.
  in_score = i < toks.length && toks[i]["t"] == "cmd" && toks[i]["v"] == "score"
  if in_score
    score_refuse("\\score wants a { block }", toks[i]["at"]) unless i + 1 < toks.length && toks[i + 1]["t"] == "{"
    i = score_preamble(toks, i + 2, st)
  end
  staves = []
  groups = []
  i = score_part(toks, i, st, staves, groups, 0)
  if in_score
    while i < toks.length && toks[i]["t"] == "cmd" && ["layout", "midi", "header"].includes?(toks[i]["v"])
      if toks[i]["v"] == "header"
        i = score_header(toks, i, st)
      else
        i = score_skip_block(toks, i + 1)
      end
    end
    score_refuse("a \\score block that is never closed", 0) if i >= toks.length || toks[i]["t"] != "}"
    i += 1
  end
  score_refuse("'#{toks[i]["v"]}' after the end of the music", toks[i]["at"]) if i < toks.length
  {"header": st["header"], "staves": staves, "groups": groups, "events": staves[0]["events"]}
end

# `\\version` and `\\header` may come first, in either order.
def score_preamble(toks, i, st)
  while i < toks.length && toks[i]["t"] == "cmd" && (toks[i]["v"] == "version" || toks[i]["v"] == "header")
    if toks[i]["v"] == "version"
      i += 2
    else
      i = score_header(toks, i, st)
    end
  end
  i
end

# Past a `{ … }` block, braces counted.
def score_skip_block(toks, i)
  score_refuse("a { block } was expected", i < toks.length ? toks[i]["at"] : 0) if i >= toks.length || toks[i]["t"] != "{"
  depth = 0
  while i < toks.length
    depth += 1 if toks[i]["t"] == "{"
    depth -= 1 if toks[i]["t"] == "}"
    i += 1
    break if depth == 0
  end
  i
end

# `<<` and `>>`: two angle brackets with nothing between them.
def score_double?(toks, i, kind)
  i + 1 < toks.length && toks[i]["t"] == kind && toks[i + 1]["t"] == kind && toks[i + 1]["at"] == toks[i]["at"] + 1
end

# The staves LilyPond groups and how it marks the group: a piano's two
# staves under a brace with bar lines drawn through, an orchestra's
# sections under a bracket, a choir's under a bracket with bar lines
# that stop at each staff.
const SCORE_GROUPS = {"PianoStaff": "brace", "GrandStaff": "brace", "StaffGroup": "bracket", "ChoirStaff": "choir"}

# One part of the music: a staff — `\\new Staff`, or music on its own — or
# a group of them, `\\new PianoStaff << … >>` and its kin, or `<< … >>`.
def score_part(toks, i, st, staves, groups, depth)
  score_refuse("there is no music", 0) if i >= toks.length
  tk = toks[i]
  if tk["t"] == "cmd" && tk["v"] == "new"
    kind = i + 1 < toks.length ? toks[i + 1]["v"] : ""
    score_refuse("\\new #{kind} is not drawn: a Staff, a PianoStaff, a GrandStaff, a StaffGroup or a ChoirStaff is", tk["at"]) unless kind == "Staff" || SCORE_GROUPS.has_key(kind)
    i += 2
    i += 2 if i + 1 < toks.length && toks[i]["t"] == "=" && toks[i + 1]["t"] == "str"
    props = {}
    i = score_with(toks, i, props) if i < toks.length && toks[i]["t"] == "cmd" && toks[i]["v"] == "with"
    return score_staff(toks, i, st, staves, props) if kind == "Staff"

    score_refuse("\\new #{kind} wants its staves between << and >>", tk["at"]) unless score_double?(toks, i, "<")
    return score_group(toks, i, st, staves, groups, depth, SCORE_GROUPS[kind], props)
  end
  return score_group(toks, i, st, staves, groups, depth, "none", {}) if score_double?(toks, i, "<")

  score_staff(toks, i, st, staves, {})
end

# `<< … >>`: the staves (or groups) between, each a `\\new` one.
def score_group(toks, i, st, staves, groups, depth, kind, props)
  at = toks[i]["at"]
  i += 2
  first = staves.length
  while i < toks.length && !score_double?(toks, i, ">")
    score_refuse("two voices in one staff are not drawn: give each its own \\new Staff", toks[i]["at"]) unless toks[i]["t"] == "cmd" && toks[i]["v"] == "new"
    i = score_part(toks, i, st, staves, groups, depth + 1)
  end
  score_refuse("a << that is never closed by >>", at) if i >= toks.length
  score_refuse("<< >> with no staff in it", at) if staves.length == first
  groups.push({"kind": kind, "first": first, "last": staves.length - 1, "depth": depth, "name": props["instrumentName"] ?? "", "short": props["shortInstrumentName"] ?? ""})
  i + 2
end

# `\\with { instrumentName = "Flûte" shortInstrumentName = "Fl." midiInstrument = #"flute" }`
def score_with(toks, i, props)
  at = toks[i]["at"]
  score_refuse("\\with wants a { block }", at) unless i + 1 < toks.length && toks[i + 1]["t"] == "{"
  i += 2
  while i < toks.length && toks[i]["t"] != "}"
    i = score_staff_prop(toks, i, props, "\\with")
  end
  score_refuse("a \\with block that is never closed", at) if i >= toks.length
  i + 1
end

# `name = "value"` (or `= #"value"`), for the staff properties this reads.
def score_staff_prop(toks, i, props, what)
  tk = toks[i]
  ok = tk["t"] == "word" && ["instrumentName", "shortInstrumentName", "midiInstrument", "midiMaximumVolume", "midiPanPosition"].includes?(tk["v"]) && i + 1 < toks.length && toks[i + 1]["t"] == "="
  score_refuse("#{what} sets instrumentName, shortInstrumentName, midiInstrument, midiMaximumVolume or midiPanPosition, not '#{tk["v"]}'", tk["at"]) unless ok
  i += 2
  i += 1 if i < toks.length && toks[i]["t"] == "#"
  if tk["v"] == "midiMaximumVolume" || tk["v"] == "midiPanPosition"
    # A number, as Scheme writes one: `#0.8`, `#-0.5`, `#1`.
    sign = 1.0
    if i < toks.length && toks[i]["t"] == "-"
      sign = -1.0
      i += 1
    end
    score_refuse("#{tk["v"]} wants a number", tk["at"]) unless i < toks.length && toks[i]["t"] == "num" && !toks[i]["v"].contains("/")
    value = float(toks[i]["v"])
    i += 1
    if i + 1 < toks.length && toks[i]["t"] == "." && toks[i + 1]["t"] == "num" && toks[i + 1]["at"] == toks[i]["at"] + 1
      digits = toks[i + 1]["v"]
      tenths = 1.0
      for _ in range(0, digits.length)
        tenths = tenths * 10.0
      end
      value += float(digits) / tenths
      i += 2
    end
    props[tk["v"]] = sign * value
    return i
  end
  score_refuse("#{tk["v"]} wants a \"string\"", tk["at"]) unless i < toks.length && toks[i]["t"] == "str"
  props[tk["v"]] = toks[i]["v"]
  i + 1
end

# One staff's music: `\\relative c' { … }` or `{ … }`, read with its own
# octave and duration memory, and its notes numbered after the staves
# before it so that no two items anywhere share a number.
def score_staff(toks, i, base, staves, props)
  st = {"ref": nil, "base": 4, "dots": 0, "events": [], "notes": base["notes"], "items": base["counter"], "header": base["header"], "props": props}
  if i < toks.length && toks[i]["t"] == "cmd" && toks[i]["v"] == "relative"
    pitch = i + 1 < toks.length ? toks[i + 1] : nil
    name = pitch.nil? ? nil : score_pitch_name(pitch["v"])
    score_refuse("\\relative wants a pitch", toks[i]["at"]) if name.nil? || pitch["t"] != "word"
    st["ref"] = score_resolve(name, pitch["marks"], nil)
    i += 2
  end
  braced = i < toks.length && toks[i]["t"] == "{"
  i += 1 if braced
  i = score_music(toks, i, st)
  if braced
    score_refuse("a '{' that is never closed", 0) if i >= toks.length || toks[i]["t"] != "}"
    i += 1
  end
  base["counter"] = st["items"]
  base["notes"] = st["notes"]
  staves.push({"events": st["events"], "props": st["props"]})
  i
end

# The fields of a `\header { … }` block LilyPond's title page prints:
# `field = "text"`, each once. Answers where the block ended.
def score_header(toks, i, st)
  fields = ["dedication", "title", "subtitle", "subsubtitle", "poet", "instrument", "composer", "meter", "arranger", "piece", "opus", "copyright"]
  at = toks[i]["at"]
  i += 1
  score_refuse("\\header wants a { block }", at) if i >= toks.length || toks[i]["t"] != "{"
  i += 1
  while i < toks.length && toks[i]["t"] != "}"
    name = toks[i]
    score_refuse("a header field is a name, = and a string", name["at"]) unless name["t"] == "word" && i + 2 < toks.length && toks[i + 1]["t"] == "=" && toks[i + 2]["t"] == "str"
    score_refuse("the header field '#{name["v"]}' is not one a title page prints", name["at"]) unless fields.includes?(name["v"])
    st["header"][name["v"]] = toks[i + 2]["v"]
    i += 3
  end
  score_refuse("a \\header that is never closed", at) if i >= toks.length
  i + 1
end

# Everything up to a closing brace or the end; answers where it stopped.
def score_music(toks, i, st)
  evs = st["events"]
  while i < toks.length
    tk = toks[i]
    kind = tk["t"]
    break if kind == "}"

    if kind == "cmd"
      i = score_command(toks, i, st)
    elsif kind == "word" || kind == "<"
      i = score_note(toks, i, st)
    elsif kind == "|"
      i += 1
    elsif kind == "~"
      last = score_last_note(evs, tk)
      last["tie"] = true
      i += 1
    elsif kind == "-" || kind == "^" || kind == "_"
      i = score_postfix(toks, i, st)
    elsif kind == "(" || kind == ")" || kind == "[" || kind == "]"
      last = score_last_note(evs, tk)
      key = {"(": "slur_on", ")": "slur_off", "[": "beam_on", "]": "beam_off"}[kind]
      last[key] = true
      i += 1
    else
      score_refuse("'#{tk["v"]}' is not expected here", tk["at"])
    end
  end
  i
end

# After a note: `-.` `->` `--` `-^` `-!` `-_` (staccato, accent, tenuto,
# marcato, staccatissimo, portato), a command (`-\fermata`, `_\p`) or
# words (`^"dolce"`). `-` leaves the side to the engraver, `^` puts it
# above, `_` below.
def score_postfix(toks, i, st)
  tk = toks[i]
  dir = {"-": 0, "^": -1, "_": 1}[tk["t"]]
  score_refuse("'#{tk["v"]}' wants something after it: -. -> -- ^\"text\"", tk["at"]) if i + 1 >= toks.length
  nxt = toks[i + 1]
  if nxt["t"] == "str"
    last = score_last_item(st["events"], tk)
    last["texts"] = (last["texts"] ?? []) + [ {"text": nxt["v"], "dir": dir == 0 ? 1 : dir} ]
    return i + 2
  end
  if nxt["t"] == "cmd"
    if SCORE_SCRIPTS.has_key(nxt["v"])
      score_add_script(score_last_note(st["events"], tk), nxt["v"], dir)
      return i + 2
    end
    return score_command(toks, i + 1, st)
  end
  name = {".": "staccato", ">": "accent", "-": "tenuto", "^": "marcato", "!": "staccatissimo", "_": "portato"}[nxt["t"]]
  score_refuse("'#{tk["v"]}#{nxt["v"]}' is not an articulation this draws", tk["at"]) if name.nil?
  score_add_script(score_last_note(st["events"], tk), name, dir)
  i + 2
end

def score_add_script(ev, name, dir)
  ev["scripts"] = (ev["scripts"] ?? []) + [ {"name": name, "dir": dir} ]
end

# The note or the rest a dynamic, a hairpin or words belong to.
def score_last_item(evs, tk)
  last = evs.length > 0 ? evs[-1] : nil
  score_refuse("'#{tk["v"]}' must follow a note or a rest", tk["at"]) if last.nil? || (last["k"] != "note" && last["k"] != "rest")
  last
end

def score_last_note(evs, tk)
  last = evs.length > 0 ? evs[-1] : nil
  score_refuse("'#{tk["v"]}' must follow a note", tk["at"]) if last.nil? || last["k"] != "note"
  last
end

def score_command(toks, i, st)
  tk = toks[i]
  word = tk["v"]
  arg = i + 1 < toks.length ? toks[i + 1] : nil
  evs = st["events"]
  if word == "clef"
    score_refuse("\\clef wants a name", tk["at"]) if arg.nil?
    clef = {"treble": "treble", "violin": "treble", "G": "treble", "bass": "bass", "F": "bass", "alto": "alto", "C": "alto"}[arg["v"]]
    score_refuse("the clef '#{arg["v"]}' is not one this draws (treble, bass, alto)", arg["at"]) if clef.nil?
    evs.push({"k": "clef", "v": clef, "at": tk["at"]})
    return i + 2
  end
  if word == "key"
    mode = i + 2 < toks.length ? toks[i + 2] : nil
    name = arg.nil? ? nil : score_pitch_name(arg["v"])
    score_refuse("\\key wants a pitch and \\major or \\minor", tk["at"]) if name.nil? || mode.nil? || mode["t"] != "cmd"
    score_refuse("the mode '#{mode["v"]}' is not \\major or \\minor", mode["at"]) unless mode["v"] == "major" || mode["v"] == "minor"
    fifths = [0, 2, 4, -1, 1, 3, 5][name["step"]] + 7 * name["alter"]
    fifths -= 3 if mode["v"] == "minor"
    score_refuse("a key of #{fifths} fifths has no signature", tk["at"]) if fifths > 7 || fifths < -7
    evs.push({"k": "key", "fifths": fifths, "at": tk["at"]})
    return i + 3
  end
  if word == "time"
    parts = arg.nil? ? [] : arg["v"].split("/")
    score_refuse("\\time wants a fraction like 3/4", tk["at"]) if parts.length != 2
    num = int(parts[0])
    den = int(parts[1])
    score_refuse("\\time #{arg["v"]} is not a metre this draws", arg["at"]) unless num > 0 && num < 13 && [1, 2, 4, 8, 16].includes?(den)
    evs.push({"k": "time", "n": num, "d": den, "at": tk["at"]})
    return i + 2
  end
  if word == "bar"
    score_refuse("\\bar wants a string", tk["at"]) if arg.nil? || arg["t"] != "str"
    score_refuse("the bar line \"#{arg["v"]}\" is not one this draws (|, ||, |., .|:, :|., :|.|:)", arg["at"]) unless ["|", "||", "|.", ".|:", ":|.", ":|.|:"].includes?(arg["v"])
    evs.push({"k": "bar", "v": arg["v"], "at": tk["at"]})
    return i + 2
  end
  if word == "tempo"
    return score_tempo(toks, i, st)
  end
  # Dynamics, hairpins and the articulations named by a command, on the
  # note or the rest before them.
  if SCORE_DYNAMICS.includes?(word)
    score_last_item(evs, tk)["dyn"] = word
    return i + 1
  end
  if word == "<" || word == ">"
    score_last_item(evs, tk)["hairpin"] = word
    return i + 1
  end
  if word == "!"
    score_last_item(evs, tk)["hairpin_end"] = true
    return i + 1
  end
  if SCORE_SCRIPTS.has_key(word)
    score_add_script(score_last_note(evs, tk), word, 0)
    return i + 1
  end
  # A line or a page that must end at the next bar line, as the engraver
  # would not have ended it.
  if word == "break" || word == "pageBreak"
    evs.push({"k": "break", "page": word == "pageBreak", "at": tk["at"]})
    return i + 1
  end
  # `\\set Staff.instrumentName = "…"` and its two kin.
  if word == "set"
    ok = i + 3 < toks.length && toks[i + 1]["t"] == "word" && toks[i + 1]["v"] == "Staff" && toks[i + 2]["t"] == "."
    score_refuse("\\set sets Staff.instrumentName, Staff.shortInstrumentName or Staff.midiInstrument", tk["at"]) unless ok
    st["props"] = st["props"] ?? {}
    return score_staff_prop(toks, i + 3, st["props"], "\\set Staff")
  end
  if word == "tuplet" || word == "times"
    return score_tuplet(toks, i, st, word)
  end
  if word == "repeat"
    return score_repeat(toks, i, st)
  end
  if word == "alternative"
    return score_alternative(toks, i, st)
  end
  # LilyPond prints a run of whole-bar rests bar by bar unless asked to
  # gather it into one bar with a count; these two ask.
  if word == "compressEmptyMeasures"
    evs.push({"k": "compress", "at": tk["at"]})
    return i + 1
  end
  if word == "compressMMRests"
    evs.push({"k": "compress", "at": tk["at"]})
    score_refuse("\\compressMMRests wants a { block }", tk["at"]) if arg.nil? || arg["t"] != "{"
    i = score_music(toks, i + 2, st)
    score_refuse("a \\compressMMRests block that is never closed", tk["at"]) if i >= toks.length || toks[i]["t"] != "}"
    return i + 1
  end
  score_refuse("\\#{word} is not a command this reads", tk["at"])
end

# `\repeat volta 2 { … }`: a start repeat, the music, and an end repeat —
# or, when `\alternative` follows the block or ends it (LilyPond 2.24
# writes it inside), the alternatives, each but the last ending the repeat.
def score_repeat(toks, i, st)
  tk = toks[i]
  ok = i + 3 < toks.length && toks[i + 1]["t"] == "word" && toks[i + 1]["v"] == "volta" && toks[i + 2]["t"] == "num" && toks[i + 3]["t"] == "{"
  score_refuse("\\repeat wants volta, a count and a { block } — the others are not drawn", tk["at"]) unless ok
  st["events"].push({"k": "repeat_start", "at": tk["at"]})
  alts_before = st["alts"] ?? 0
  i = score_music(toks, i + 4, st)
  score_refuse("a \\repeat block that is never closed", tk["at"]) if i >= toks.length || toks[i]["t"] != "}"
  i += 1
  if i < toks.length && toks[i]["t"] == "cmd" && toks[i]["v"] == "alternative"
    i = score_alternative(toks, i, st)
  end
  st["events"].push({"k": "repeat_end", "at": tk["at"]}) if (st["alts"] ?? 0) == alts_before
  i
end

# `\alternative { { … } { … } }`: the endings, bracketed "1." and "2." over
# the staff; all but the last go back to the start.
def score_alternative(toks, i, st)
  tk = toks[i]
  score_refuse("\\alternative wants a { block } of { endings }", tk["at"]) if i + 1 >= toks.length || toks[i + 1]["t"] != "{"
  i += 2
  endings = []
  while i < toks.length && toks[i]["t"] == "{"
    endings.push(i)
    depth = 0
    jj = i
    while jj < toks.length
      depth += 1 if toks[jj]["t"] == "{"
      depth -= 1 if toks[jj]["t"] == "}"
      break if depth == 0

      jj += 1
    end
    i = jj + 1
  end
  score_refuse("an \\alternative with no endings", tk["at"]) if endings.length == 0
  score_refuse("an \\alternative that is never closed", tk["at"]) if i >= toks.length || toks[i]["t"] != "}"
  close_at = i
  for start, k in endings
    last = k == endings.length - 1
    st["events"].push({"k": "volta_start", "label": str(k + 1) + ".", "at": toks[start]["at"]})
    stop = score_music(toks, start + 1, st)
    st["events"].push({"k": "repeat_end", "at": toks[start]["at"]}) unless last
    st["events"].push({"k": "volta_end", "closed": !last, "at": toks[start]["at"]})
  end
  st["alts"] = (st["alts"] ?? 0) + 1
  close_at + 1
end

# `\tuplet 3/2 { … }`: three notes in the time of two — a triplet; 6/4 is
# a sextuplet. A span after the ratio, `\tuplet 3/2 4 { c8 d e f g a }`,
# makes a group of each quarter's worth, as LilyPond does. `\times 2/3`
# is the older spelling, its fraction the other way up.
def score_tuplet(toks, i, st, word)
  tk = toks[i]
  ok = i + 1 < toks.length && toks[i + 1]["t"] == "num" && toks[i + 1]["v"].contains("/")
  score_refuse("\\#{word} wants a ratio, like 3/2, and a { block }", tk["at"]) unless ok
  parts = toks[i + 1]["v"].split("/")
  n = int(parts[0])
  d = int(parts[1])
  if word == "times"
    n = int(parts[1])
    d = int(parts[0])
  end
  score_refuse("a tuplet of #{n} in the time of #{d} is not one this draws", tk["at"]) unless n >= 2 && n <= 12 && d >= 1 && d <= 12 && n != d
  score_refuse("a tuplet inside a tuplet is not drawn", tk["at"]) unless st["tuplet"].nil?
  i += 2
  span = 0
  if i < toks.length && toks[i]["t"] == "num"
    base = int(toks[i]["v"])
    score_refuse("a tuplet's span is a note value: 1, 2, 4, 8 or 16", toks[i]["at"]) unless [1, 2, 4, 8, 16].includes?(base)
    span = score_whole() / base
    i += 1
  end
  score_refuse("\\#{word} wants a { block }", tk["at"]) if i >= toks.length || toks[i]["t"] != "{"
  st["tuplets"] = (st["tuplets"] ?? 0) + 1
  st["tuplet"] = {"id": st["tuplets"], "n": n, "d": d, "span": span, "used": 0}
  i = score_music(toks, i + 1, st)
  score_refuse("a tuplet that is never closed", tk["at"]) if i >= toks.length || toks[i]["t"] != "}"
  st["tuplet"] = nil
  i + 1
end

# `\tempo "Allegro" 4 = 120`, `\tempo 4 = 120` or `\tempo "Allegro"`:
# the words, the beat's note value and the beats a minute, any of the
# first or the last two left out.
def score_tempo(toks, i, st)
  tk = toks[i]
  i += 1
  mark = {"k": "tempo", "text": "", "base": 0, "bpm": 0, "at": tk["at"]}
  if i < toks.length && toks[i]["t"] == "str"
    mark["text"] = toks[i]["v"]
    i += 1
  end
  if i < toks.length && toks[i]["t"] == "num"
    base = int(toks[i]["v"])
    score_refuse("\\tempo wants a note value, = and a number, like 4 = 120", tk["at"]) unless [1, 2, 4, 8, 16].includes?(base) && i + 2 < toks.length && toks[i + 1]["t"] == "=" && toks[i + 2]["t"] == "num"
    mark["base"] = base
    mark["bpm"] = int(toks[i + 2]["v"])
    score_refuse("a tempo of #{mark["bpm"]} is not one anybody plays", tk["at"]) unless mark["bpm"] >= 10 && mark["bpm"] <= 400
    i += 3
  end
  score_refuse("\\tempo wants words, a beat or both", tk["at"]) if mark["text"] == "" && mark["bpm"] == 0
  st["events"].push(mark)
  i
end

def score_note(toks, i, st)
  tk = toks[i]
  pitches = []
  rest = nil
  if tk["t"] == "<"
    i += 1
    ref = st["ref"]
    first = nil
    while i < toks.length && toks[i]["t"] == "word"
      name = score_pitch_name(toks[i]["v"])
      score_refuse("'#{toks[i]["v"]}' is not a note name", toks[i]["at"]) if name.nil?
      d = score_resolve(name, toks[i]["marks"], ref)
      ref = d unless ref.nil?
      first = d if first.nil?
      pitches.push({"d": d, "alter": name["alter"]})
      i += 1
    end
    score_refuse("a chord that is never closed", tk["at"]) if i >= toks.length || toks[i]["t"] != ">"
    score_refuse("an empty chord", tk["at"]) if pitches.length == 0
    st["ref"] = first unless st["ref"].nil?
    i += 1
  else
    word = tk["v"]
    if word == "r" || word == "R"
      rest = word
    else
      name = score_pitch_name(word)
      score_refuse("'#{word}' is not a note name", tk["at"]) if name.nil?
      d = score_resolve(name, tk["marks"], st["ref"])
      st["ref"] = d unless st["ref"].nil?
      pitches.push({"d": d, "alter": name["alter"]})
    end
    i += 1
  end
  if i < toks.length && toks[i]["t"] == "num"
    base = int(toks[i]["v"])
    score_refuse("the duration #{toks[i]["v"]} is not one this draws (1, 2, 4, 8, 16, 32)", toks[i]["at"]) unless [1, 2, 4, 8, 16, 32].includes?(base)
    st["base"] = base
    st["dots"] = 0
    i += 1
    while i < toks.length && toks[i]["t"] == "."
      st["dots"] = st["dots"] + 1
      i += 1
    end
  end
  count = 1
  if i < toks.length && toks[i]["t"] == "*"
    score_refuse("a * count is for whole-bar rests, R1*4", toks[i]["at"]) unless rest == "R"
    score_refuse("a * wants a count, R1*4", toks[i]["at"]) unless i + 1 < toks.length && toks[i + 1]["t"] == "num" && !toks[i + 1]["v"].contains("/")
    count = int(toks[i + 1]["v"])
    score_refuse("a count of bars is at least one", toks[i]["at"]) if count < 1
    i += 2
  end
  base = st["base"]
  dots = st["dots"]
  ticks = score_whole() / base
  add = ticks
  for _ in 0..dots
    score_refuse("too many dots for a 1/#{base}", tk["at"]) if add % 2 == 1
    add = add / 2
    ticks += add
  end
  ev = {"k": "note", "pitches": pitches, "base": base, "dots": dots, "ticks": ticks, "at": tk["at"], "i": st["items"]}
  tup = st["tuplet"]
  unless tup.nil?
    # In a tuplet a note lasts d/n of what it says. A span starts a new
    # group, drawn with its own number, each time the last is full.
    score_refuse("a whole-bar rest cannot be in a tuplet", tk["at"]) if rest == "R"
    if tup["span"] > 0 && tup["used"] >= tup["span"]
      st["tuplets"] = st["tuplets"] + 1
      tup["id"] = st["tuplets"]
      tup["used"] = 0
    end
    score_refuse("a 1/#{base} cannot be cut #{tup["n"]} ways", tk["at"]) unless (ticks * tup["d"]) % tup["n"] == 0
    ev["ticks"] = ticks * tup["d"] / tup["n"]
    ev["tuplet"] = {"id": tup["id"], "n": tup["n"], "d": tup["d"]}
    tup["used"] = tup["used"] + ev["ticks"]
  end
  st["items"] = st["items"] + 1
  if rest.nil?
    ev["n"] = st["notes"]
    st["notes"] = st["notes"] + 1
  else
    ev["k"] = "rest"
    ev["full"] = rest == "R"
    ev["count"] = count
  end
  st["events"].push(ev)
  i
end

# ---- Bars ------------------------------------------------------------------

# The middle line's diatonic number under each clef: a staff position is the
# distance from it.
def score_clef_mid(clef)
  {"treble": 13, "bass": 1, "alto": 7}[clef]
end

# The alteration a key gives each step, c = 0 … b = 6.
def score_key_alters(fifths)
  out = [0, 0, 0, 0, 0, 0, 0]
  sharps = [3, 0, 4, 1, 5, 2, 6]
  flats = [6, 2, 5, 1, 4, 0, 3]
  for k in 0..score_max(fifths, -fifths)
    if fifths > 0
      out[sharps[k]] = 1
    else
      out[flats[k]] = -1
    end
  end
  out
end

def score_measures(events)
  clef = "treble"
  fifths = 0
  tn = 4
  td = 4
  bars = []
  cur = nil
  pos = 0
  seen = {}
  alters = score_key_alters(0)
  tied = {}
  tempo = nil
  volta_open = nil
  tuplet_bar = {}
  # A run of whole-bar rests, R1*4, is one bar with a count when the music
  # asked to compress them, and that many bars of a rest each when not —
  # LilyPond's default.
  compress = events.any? { |ev| ev["k"] == "compress" }
  flat = []
  for ev in events
    if ev["k"] == "rest" && (ev["count"] ?? 1) > 1 && !compress
      for _ in range(0, ev["count"])
        flat.push(ev.merge({"count": 1}))
      end
    else
      flat.push(ev)
    end
  end
  for ev in flat
    kind = ev["k"]
    # A tempo mark belongs to the note or rest it is written before.
    if kind == "tempo"
      tempo = ev
      next
    end
    next if kind == "compress"

    if cur.nil?
      cur = {"clef": clef, "fifths": fifths, "time": [tn, td], "items": [], "bar": "|", "changes": {}, "length": tn * score_whole() / td}
      cur["volta_in"] = volta_open unless volta_open.nil?
      bars.push(cur)
      pos = 0
      seen = {}
    end
    if kind == "break"
      score_refuse("a \\break goes at a bar line", ev["at"]) if pos > 0
      score_refuse("a \\break before any music", ev["at"]) if bars.length < 2
      ending = bars[-2]
      ending["brk"] = ev["page"] || ending["brk"] == "page" ? "page" : "line"
      next
    end
    if kind == "repeat_start"
      score_refuse("a repeat starts at a bar line", ev["at"]) if pos > 0
      cur["start_repeat"] = true
      next
    end
    if kind == "volta_start"
      score_refuse("an alternative starts at a bar line", ev["at"]) if pos > 0
      volta_open = ev["label"]
      cur["volta_in"] = volta_open
      cur["volta_first"] = true
      next
    end
    if kind == "volta_end"
      ended_before = pos == 0 && bars.length > 1
      ending = ended_before ? bars[-2] : cur
      ending["volta_last"] = true
      ending["volta_closed"] = ev["closed"]
      volta_open = nil
      # The empty bar the next notes will fill is past the ending.
      cur["volta_in"] = nil if ended_before
      next
    end
    if kind == "repeat_end"
      if pos == 0 && bars.length > 1
        bars[-2]["bar"] = ":|."
      elsif pos > 0
        cur["bar"] = ":|."
        cur["length"] = pos
        cur = nil
      else
        score_refuse("an end repeat before any music", ev["at"])
      end
      next
    end
    if kind == "clef" || kind == "key" || kind == "time"
      score_refuse("\\#{kind} in the middle of a bar", ev["at"]) if pos > 0
      if kind == "clef"
        clef = ev["v"]
        cur["clef"] = clef
        cur["changes"]["clef"] = true
      elsif kind == "key"
        cur["changes"]["key_from"] = fifths
        fifths = ev["fifths"]
        cur["fifths"] = fifths
        cur["changes"]["key"] = true
      else
        tn = ev["n"]
        td = ev["d"]
        cur["time"] = [tn, td]
        cur["length"] = tn * score_whole() / td
        cur["changes"]["time"] = true
      end
      alters = score_key_alters(fifths)
      next
    end
    if kind == "bar"
      if pos == 0 && bars.length > 1
        bars[-2]["bar"] = ev["v"]
      elsif pos > 0
        cur["bar"] = ev["v"]
        cur["length"] = pos
        cur = nil
      elsif ev["v"] == ".|:"
        # A start repeat before the first note: LilyPond draws it at the
        # start of the first line, after the clef, key and time — where
        # `\repeat volta` from the very start draws nothing.
        cur["open_bar"] = true
      else
        score_refuse("a bar line before any music", ev["at"])
      end
      next
    end
    if (ev["count"] ?? 1) > 1
      score_refuse("a run of bars' rest lasts a whole bar each: in #{tn}/#{td} write R and the bar's length", ev["at"]) unless pos == 0 && ev["ticks"] == cur["length"]
      ev["mm"] = ev["count"]
      cur["span"] = ev["count"]
    end
    score_refuse("a note runs past the bar line (bar #{bars.length})", ev["at"]) if pos + ev["ticks"] > cur["length"]
    ev["start"] = pos
    ev["bar"] = bars.length - 1
    unless ev["tuplet"].nil?
      tid = str(ev["tuplet"]["id"])
      score_refuse("a tuplet runs across a bar line", ev["at"]) if tuplet_bar.has_key(tid) && tuplet_bar[tid] != ev["bar"]
      tuplet_bar[tid] = ev["bar"]
    end
    unless tempo.nil?
      ev["tempo"] = tempo
      tempo = nil
    end
    if kind == "note"
      mid = score_clef_mid(clef)
      heads = []
      for p in ev["pitches"]
        d = p["d"]
        key = str(d)
        now = seen.has_key(key) ? seen[key] : alters[score_mod(d, 7)]
        show = p["alter"] != now
        show = false if tied.has_key(key) && tied[key] == p["alter"]
        seen[key] = p["alter"]
        heads.push({"pos": d - mid, "d": d, "alter": p["alter"], "acc": show ? p["alter"] : nil})
      end
      ev["heads"] = heads.sort_by { |hd| hd["pos"] }
      tied = {}
      if ev["tie"] == true
        for p in ev["pitches"]
          tied[str(p["d"])] = p["alter"]
        end
      end
    else
      tied = {}
    end
    cur["items"].push(ev)
    pos += ev["ticks"]
    cur = nil if pos == cur["length"]
  end
  bars = bars.filter { |b| b["items"].length > 0 || b["changes"].keys.length > 0 }
  score_refuse("there is no music", 0) if bars.length == 0
  # A bar's number counts the bars a gathered rest stands for.
  number = 1
  for b, bi in bars
    b["number"] = number
    number += b["span"] ?? 1
    # A repeat that starts here is drawn on the bar line before it: a start
    # repeat, or both signs back to back where one repeat ends as the next
    # begins. At the very start of the piece LilyPond draws none.
    if b["start_repeat"] == true && bi > 0
      before = bars[bi - 1]
      before["bar"] = before["bar"] == ":|." ? ":|.|:" : ".|:"
    end
  end
  bars
end

# ---- Stems and beams -------------------------------------------------------

def score_flags(base)
  {"1": 0, "2": 0, "4": 0, "8": 1, "16": 2, "32": 3}[str(base)]
end

# The note farthest from the middle line decides, and a tie goes down — as
# LilyPond's `neutral-direction`.
def score_stem_up?(heads)
  top = heads[-1]["pos"]
  low = heads[0]["pos"]
  low + top < 0
end

# How the eighths and the shorter notes of a bar group under one beam:
# within these spans of ticks, by metre, the way LilyPond's
# `beamExceptions` group them for the common ones.
def score_beam_windows(time)
  num = time[0]
  den = time[1]
  whole = score_whole()
  beat = whole / den
  return [whole * 3 / 8, whole * 3 / 8] if den == 8 && num % 3 == 0
  return [whole / 2, whole / 4] if num == 4 && den == 4
  return [num * beat, whole / 4] if den == 4 && (num == 2 || num == 3)
  return [whole / 2, whole / 4] if num == 2 && den == 2

  [beat, beat]
end

def score_beams(bars)
  for bar in bars
    wins = score_beam_windows(bar["time"])
    groups = []
    cur = []
    manual = false
    win = -1
    for ev in bar["items"]
      flags = ev["k"] == "note" ? score_flags(ev["base"]) : 0
      if manual
        score_refuse("a beam over a note that has no flag", ev["at"]) if flags == 0 && ev["k"] == "note"
        cur.push(ev) if ev["k"] == "note"
        if ev["beam_off"] == true
          groups.push(cur)
          cur = []
          manual = false
        end
        next
      end
      if ev["beam_on"] == true && flags > 0
        groups.push(cur) if cur.length > 0
        cur = [ev]
        manual = true
        next
      end
      w = ev["start"] / wins[0]
      if flags == 0 || w != win
        groups.push(cur) if cur.length > 0
        cur = []
      end
      if flags > 0
        cur.push(ev)
        win = w
      end
    end
    groups.push(cur) if cur.length > 0
    # A group with sixteenths in it is split again by the beat, and so is
    # one with a tuplet: LilyPond's exceptions are for plain eighths, and a
    # tuplet's notes fall back on the beat. A tuplet ends its beam.
    by_beat = []
    for g in groups
      short = g.any? { |ev| score_flags(ev["base"]) > 1 || !ev["tuplet"].nil? }
      if g.length > 1 && short && g[0]["beam_on"] != true
        part = []
        pw = -1
        pt = nil
        for ev in g
          w = ev["start"] / wins[1]
          tid = ev["tuplet"].nil? ? nil : ev["tuplet"]["id"]
          if (w != pw || tid != pt) && part.length > 0
            by_beat.push(part)
            part = []
          end
          part.push(ev)
          pw = w
          pt = tid
        end
        by_beat.push(part)
      else
        by_beat.push(g)
      end
    end
    for g in by_beat
      if g.length < 2
        next
      end

      lowest = 0
      highest = 0
      for ev in g
        lowest = ev["heads"][0]["pos"] if ev["heads"][0]["pos"] < lowest
        highest = ev["heads"][-1]["pos"] if ev["heads"][-1]["pos"] > highest
      end
      up = -lowest > highest
      group = {"notes": g, "up": up}
      for ev in g
        ev["beam"] = group
        ev["up"] = up
      end
    end
    for ev in bar["items"]
      ev["up"] = score_stem_up?(ev["heads"]) if ev["k"] == "note" && ev["beam"].nil?
    end
  end
end

# ---- Columns: what each note occupies, and how far it wants the next -------

# LilyPond's duration space: two increments of 1.2 spaces for the common
# shortest note, one more for each doubling past it, and a note shorter
# than it in proportion (`shortest-duration-space`, `spacing-increment`).
# The tenth on top is what its columns' own widths add; with it, the three
# gallery pieces land within a few tenths of a space of LilyPond 2.24's.
def score_duration_space(t, shortest)
  ratio = float(t) / shortest
  return 1.2 * (1.0 + ratio) + 0.1 if ratio < 1.0

  1.2 * (2.0 + score_log2(ratio)) + 0.1
end

# The duration the spacing is measured from: as LilyPond's
# `common-shortest-duration`, the shortest note of each bar, and of those the
# one most bars have — the shorter on a tie. A run of sixteenths in one bar
# of a chorale does not open up every other bar. And never longer than a
# dotted eighth (`base-shortest-duration`, 3/16): a page of quarters is
# spaced as though shorter notes could come, so it does not sprawl.
def score_shortest(bars)
  counts = {}
  for bar in bars
    least = 0
    for ev in bar["items"]
      t = score_space_ticks(ev)
      least = t if least == 0 || t < least
    end
    counts[str(least)] = (counts[str(least)] ?? 0) + 1 if least > 0
  end
  best = score_whole() / 4
  most = 0
  for key in counts.keys
    t = int(key)
    if counts[key] > most || (counts[key] == most && t < best)
      best = t
      most = counts[key]
    end
  end
  score_min(best, score_whole() * 3 / 16)
end

# What a note's spacing is measured by: its written value, dots aside, and
# in a tuplet the share of it that it really lasts.
def score_space_ticks(ev)
  t = score_whole() / ev["base"]
  return t if ev["tuplet"].nil?

  t * ev["tuplet"]["d"] / ev["tuplet"]["n"]
end

def score_head_name(base)
  return "noteheadWhole" if base == 1
  return "noteheadHalf" if base == 2

  "noteheadBlack"
end

def score_rest_name(base)
  {"1": "restWhole", "2": "restHalf", "4": "restQuarter", "8": "rest8th", "16": "rest16th", "32": "rest32nd"}[str(base)]
end

def score_acc_name(alter)
  {"-2": "accidentalDoubleFlat", "-1": "accidentalFlat", "0": "accidentalNatural", "1": "accidentalSharp", "2": "accidentalDoubleSharp"}[str(alter)]
end

def score_flag_name(base, up)
  stem = {"8": "8th", "16": "16th", "32": "32nd"}[str(base)]
  "flag#{stem}#{up ? "Up" : "Down"}"
end

# For each note: which heads sit on the wrong side of the stem (a second
# in a chord), where each accidental goes, and how far the ink reaches left
# and right of the head's own left edge. For each item: the space it would
# like after it — LilyPond's, 1.2 spaces more for each doubling of the
# duration past the shortest, which is given two increments.
def score_columns(bars, shortest)
  for bar in bars
    for ev in bar["items"]
      t = score_space_ticks(ev)
      ev["ideal"] = score_duration_space(t, shortest)
      if ev["k"] == "rest" && !ev["mm"].nil?
        # A bar's rest for several bars: up to ten, LilyPond's church rests
        # side by side; past that, its wide bar. Either way its count over it.
        ev["ideal"] = ev["mm"] <= 10 ? 3.0 + score_church_width(ev["mm"]) : 7.0 + score_log2(ev["mm"])
        ev["left"] = 0.0
        ev["right"] = ev["mm"] <= 10 ? score_church_width(ev["mm"]) + 1.0 : 4.0
        next
      end
      if ev["k"] == "rest"
        g = score_glyph(score_rest_name(ev["base"]))
        ev["left"] = 0.0
        ev["right"] = g["advance"] + (ev["dots"] > 0 ? 0.3 + 0.6 * ev["dots"] : 0.0)
        next
      end
      head_name = score_glyph(score_head_name(ev["base"]))
      hw = head_name["advance"]
      ev["head_w"] = hw
      score_displace(ev)
      right = hw
      right += hw - SCORE_RULE["stem"] if ev["heads"].any? { |hd| hd["side"] == 1 }
      right += 0.3 + 0.6 * ev["dots"] if ev["dots"] > 0
      if ev["up"] && ev["beam"].nil? && score_flags(ev["base"]) > 0
        right += score_glyph(score_flag_name(ev["base"], true))["advance"] - SCORE_RULE["stem"]
      end
      ev["right"] = right
      shifted = ev["heads"].any? { |hd| hd["side"] == -1 }
      lefts = shifted ? hw - SCORE_RULE["stem"] : 0.0
      ev["left"] = lefts + score_place_accidentals(ev)
    end
  end
end

# A second in a chord cannot share the stem's side: walking from the end
# the stem starts at, every head a step from one on the normal side goes to
# the other. `side` is 0, 1 (right of an up stem) or -1 (left of a down one).
def score_displace(ev)
  heads = ev["heads"]
  order = ev["up"] ? heads : heads.reverse()
  prev = nil
  for hd in order
    hd["side"] = 0
    if !prev.nil? && (hd["pos"] - prev["pos"]).abs == 1 && prev["side"] == 0
      hd["side"] = ev["up"] ? 1 : -1
    end
    prev = hd
  end
end

# Accidentals stack leftwards in columns, top to bottom, each in the
# rightmost column it does not collide in. Answers how far the stack
# reaches left of the heads.
def score_place_accidentals(ev)
  cols = []
  reach = 0.0
  for hd in ev["heads"].reverse()
    next if hd["acc"].nil?

    g = score_glyph(score_acc_name(hd["acc"]))
    y = 2.0 - hd["pos"] / 2.0
    top = y + g["bbox"][1]
    low = y + g["bbox"][3]
    placed = false
    x = 0.0
    for col in cols
      x = col["x"]
      clear = col["spans"].all? { |sn| low <= sn[0] + 0.1 || top >= sn[1] - 0.1 }
      if clear
        col["spans"].push([top, low])
        col["w"] = score_max(col["w"], g["advance"])
        hd["acc_col"] = col
        placed = true
        break
      end
    end
    unless placed
      col = {"spans": [ [top, low] ], "w": g["advance"], "x": 0.0}
      cols.push(col)
      hd["acc_col"] = col
    end
  end
  # Columns from the heads outwards: each sits left of the one before.
  shifted = ev["heads"].any? { |hd| hd["side"] == -1 }
  rim = shifted ? -(ev["head_w"] - SCORE_RULE["stem"]) : 0.0
  for col in cols
    col["x"] = rim - 0.2 - col["w"]
    rim = col["x"]
  end
  for hd in ev["heads"]
    hd["acc_x"] = hd["acc_col"]["x"] unless hd["acc_col"].nil?
  end
  reach = -rim if rim < 0.0
  reach
end

# ---- Systems ---------------------------------------------------------------

def score_key_width(fifths)
  return 0.0 if fifths == 0

  g = score_glyph(fifths > 0 ? "accidentalSharp" : "accidentalFlat")
  n = score_max(fifths, -fifths)
  n * (g["advance"] + 0.1)
end

def score_time_glyphs(time)
  return ["timeSigCommon"] if time[0] == 4 && time[1] == 4
  return ["timeSigCutCommon"] if time[0] == 2 && time[1] == 2

  nil
end

def score_digits(v)
  str(v).chars().map { |ch| "timeSig#{ch}" }
end

def score_time_width(time)
  one = score_time_glyphs(time)
  return score_glyph(one[0])["advance"] unless one.nil?

  wide = 0.0
  for part in [time[0], time[1]]
    w = score_digits(part).reduce(fn(acc, nm) acc + score_glyph(nm)["advance"], 0.0)
    wide = w if w > wide
  end
  wide
end

# What a system opens with: the clef, the key, and the time if this is the
# first or the time changes here.
def score_prefix_width(bar, first)
  return bar["staff_bars"].map { |sb| score_prefix_width(sb, first) }.reduce(fn(acc, w) score_max(acc, w), 0.0) if bar.has_key("staff_bars")

  w = 0.8 + score_glyph(score_clef_glyph(bar["clef"]))["advance"] + 1.0
  w += score_key_width(bar["fifths"]) + 0.8 if bar["fifths"] != 0
  w += score_time_width(bar["time"]) + 1.0 if first || bar["changes"]["time"] == true
  w
end

def score_clef_glyph(clef)
  {"treble": "gClef", "bass": "fClef", "alto": "cClef"}[clef]
end

# A bar's changes drawn at its start, when it does not open a system.
def score_change_width(bar)
  return bar["staff_bars"].map { |sb| score_change_width(sb) }.reduce(fn(acc, w) score_max(acc, w), 0.0) if bar.has_key("staff_bars")

  w = 0.0
  ch = bar["changes"]
  w += score_glyph(score_clef_glyph(bar["clef"]))["advance"] + 0.8 if ch["clef"] == true
  if ch["key"] == true
    skip = score_key_cancel(ch["key_from"], bar["fifths"])
    if skip >= 0
      cancelled = score_max(ch["key_from"], -ch["key_from"]) - skip
      w += cancelled * (score_glyph("accidentalNatural")["advance"] + 0.1) + 0.5
    end
    w += score_key_width(bar["fifths"]) + 0.8 if bar["fifths"] != 0
  end
  w += score_time_width(bar["time"]) + 1.0 if ch["time"] == true
  w
end

# The gaps of a bar at a stretch `k`: from its start to the first head,
# between heads, and from the last to the bar line.
def score_gaps(bar, k)
  items = bar["items"]
  out = []
  return [score_max(6.0 * k, 4.0)] if items.length == 0

  out.push(1.2 + items[0]["left"])
  for i in 0..items.length
    ev = items[i]
    if i + 1 < items.length
      nxt = items[i + 1]
      out.push(score_max(ev["ideal"] * k, ev["right"] + 0.6 + nxt["left"]))
    else
      out.push(score_max(ev["ideal"] * k, ev["right"] + 0.8))
    end
  end
  out
end

# The springs of a bar: the room its notes ask for by their durations,
# which is what stretches when a line is justified.
def score_bar_springs(bar)
  return 6.0 if bar["items"].length == 0

  bar["items"].reduce(fn(acc, ev) acc + ev["ideal"], 0.0)
end

# A flat summary of a bar's opening changes — a bar itself is cyclic (its
# notes hold their beams, which hold the notes) and is not carried about.
def score_courtesy_of(bar)
  return {"multi": bar["staff_bars"].map { |sb| score_courtesy_of(sb) }} if bar.has_key("staff_bars")

  changes = bar["changes"]
  {"clef": bar["clef"], "fifths": bar["fifths"], "time": bar["time"], "changes": {"key": changes["key"] == true, "key_from": changes["key_from"] ?? 0, "time": changes["time"] == true}}
end

# What a line ends with when the next one opens with a new key or metre:
# the old key's naturals, the new key, the new time, after a little air.
def score_courtesy_width(bar)
  return bar["multi"].map { |one| score_courtesy_width(one) }.reduce(fn(acc, w) score_max(acc, w), 0.0) if bar.has_key("multi")

  cw_changes = bar["changes"]
  cw = 0.0
  cw_skip = -1
  if cw_changes["key"] == true
    cw_skip = score_key_cancel(cw_changes["key_from"], bar["fifths"])
    cw += (score_max(cw_changes["key_from"], 0 - cw_changes["key_from"]) - cw_skip) * (score_glyph("accidentalNatural")["advance"] + 0.1) + 0.5 if cw_skip >= 0
    cw += score_key_width(bar["fifths"]) + 0.5 if bar["fifths"] != 0
  end
  cw += score_time_width(bar["time"]) + 0.5 if cw_changes["time"] == true
  cw > 0.0 ? cw + 0.6 : 0.0
end

def score_bar_width(bar, k, opening)
  gaps = score_gaps(bar, k)
  total = gaps.reduce(fn(acc, g) acc + g, 0.0)
  total += score_change_width(bar) unless opening
  total += score_barline_width(".|:") + 0.4 if opening && !bar["open_repeat"].nil?
  total + score_barline_width(bar["bar_drawn"] ?? bar["bar"])
end

# The parts of a bar line, left to right, and how wide it is in all: thin
# and thick lines and repeat dots, a kern apart, as LilyPond spaces them.
def score_barline_parts(kind)
  {"|": ["thin"], "||": ["thin", "thin"], "|.": ["thin", "thick"], ".|:": ["thick", "thin", "dots"], ":|.": ["dots", "thin", "thick"], ":|.|:": ["dots", "thin", "thick", "thin", "dots"]}[kind] ?? ["thin"]
end

def score_barline_width(kind)
  parts = score_barline_parts(kind)
  sizes = {"thin": SCORE_RULE["thin"], "thick": SCORE_RULE["thick"], "dots": score_glyph("augmentationDot")["advance"]}
  parts.reduce(fn(acc, part) acc + sizes[part], 0.0) + SCORE_RULE["kern"] * (parts.length - 1)
end

def score_system_width(bars, k)
  total = score_prefix_width(bars[0], bars[0]["first"] == true)
  for b, i in bars
    total += score_bar_width(b, k, i == 0)
  end
  total
end

# Where the lines break: as LilyPond's default breaker does, not greedily
# but for the page — the set of breaks whose lines need the least
# stretching, each line costing the square of how far its springs must
# open, the last left as it falls. Filling each line to the brim instead left
# the next with too few bars, stretched a fifth wider than LilyPond's.
# Then each system that broke is stretched to the width; the last — and so
# a score of one line — keeps its natural spacing unless it nearly fills
# the line anyway. A bar wider than the line on its own is drawn as tight
# as its ink allows, and overflows only if that is still too wide.
def score_break(bars, width, indent, rest = 0.0)
  bars[0]["first"] = true
  bars[0]["open_repeat"] = ".|:" if bars[0]["open_bar"] == true
  count = bars.length
  opening_w = bars.map { |b| score_bar_width(b, 1.0, true) }
  inner_w = bars.map { |b| score_bar_width(b, 1.0, false) }
  opening_min = bars.map { |b| score_bar_width(b, 0.0, true) }
  inner_min = bars.map { |b| score_bar_width(b, 0.0, false) }
  springs = bars.map { |b| score_bar_springs(b) }
  # What announcing the next line's opening would cost, bar by bar: each
  # line's end asks it of the bar after it, once and not once per line.
  courtesy_w = bars.map { |b| score_courtesy_width(score_courtesy_of(b)) }
  prefix_w = range(0, count).map { |t| score_prefix_width(bars[t], t == 0) }
  memo_key = score_break_key(width, indent + rest * 1000.0, [opening_w, inner_w, opening_min, inner_min, springs, courtesy_w, prefix_w])
  known = score_memo_get("breaks", memo_key)
  return score_break_lines(bars, width, indent, known, rest) unless known.nil?

  best = [0.0]
  from_bar = [0]
  for _ in range(0, count)
    best.push(-1.0)
    from_bar.push(0)
  end
  for i in 0..count
    next if best[i] < 0.0

    room = i == 0 ? width - indent : width - rest
    w = prefix_w[i] + opening_w[i]
    tight = prefix_w[i] + opening_min[i]
    spring = springs[i]
    jj = i + 1
    while jj <= count
      # A line never runs past a bar that a \break or a \pageBreak ends.
      break if jj > i + 1 && !bars[jj - 2]["brk"].nil?

      if jj > i + 1
        w += inner_w[jj - 1]
        tight += inner_min[jj - 1]
        spring += springs[jj - 1]
      end
      courtesy = jj < count ? courtesy_w[jj] : 0.0
      line_w = w + courtesy
      # A line may also be pressed a little closer than its natural spacing,
      # as LilyPond's may, down to what its ink needs and at a steeper
      # price than stretching; past that it is not a line.
      break if tight + courtesy > room && jj > i + 1

      cost = 0.0
      ratio = (room - line_w) / score_max(spring, 1.0)
      if tight + courtesy > room
        cost = 1000.0
      elsif ratio < 0.0
        cost = ratio * ratio * 40.0 + 1.0
      elsif jj < count
        cost = ratio * ratio * 10.0 + 1.0
      end
      total = best[i] + cost
      if best[jj] < 0.0 || total < best[jj]
        best[jj] = total
        from_bar[jj] = i
      end
      jj += 1
    end
  end
  cuts = []
  at = count
  while at > 0
    cuts.push(from_bar[at])
    at = from_bar[at]
  end
  starts = cuts.reverse()
  score_memo_put("breaks", memo_key, starts, 16)
  score_break_lines(bars, width, indent, starts, rest)
end

# The lines a search found for exactly these widths. Its answer is a pure
# function of them, so taking it from the cache gives the lines a search
# would: a note moved to another line or space of the staff, which widens
# nothing, is not searched for again.
def score_break_key(width, indent, columns)
  parts = [str(width), str(indent)]
  for col in columns
    parts.push(col.map { |v| str(v.round(6)) }.join(","))
  end
  parts.join("|")
end

# The lines from their first bars: repeat signs split where a line breaks,
# each line's courtesy announcement, and its stretch.
def score_break_lines(bars, width, indent, starts, rest = 0.0)
  count = bars.length
  systems = []
  for start, si in starts
    stop = si + 1 < starts.length ? starts[si + 1] : count
    systems.push({"bars": range(start, stop).map { |t| bars[t] }})
  end
  # A repeat sign on a line break is split as LilyPond splits it: the line
  # ends with what closes (a plain line, or the end repeat), and the next
  # opens, after its clef and key, with the start repeat.
  for sys, si in systems
    tail = sys["bars"][-1]
    kind = tail["bar"]
    next if si + 1 >= systems.length

    if kind == ".|:" || kind == ":|.|:"
      tail["bar_drawn"] = kind == ".|:" ? "|" : ":|."
      systems[si + 1]["bars"][0]["open_repeat"] = ".|:"
    end
  end
  for sys, si in systems
    room = si == 0 ? width - indent : width - rest
    # A change at the start of the next line is announced at the end of
    # this one, after its bar line, as LilyPond does: room for it first.
    sys["courtesy"] = 0.0
    # A plain summary of the next line's opening: a bar is cyclic (its notes
    # hold their beams, which hold the notes), and is better not carried
    # about. Declared before the `if`, and named for this function alone.
    next_open = nil
    if si + 1 < systems.length
      next_open = systems[si + 1]["bars"][0]
      sys["courtesy_bar"] = score_courtesy_of(next_open)
      sys["courtesy"] = score_courtesy_width(sys["courtesy_bar"])
      room -= sys["courtesy"]
    end
    natural = score_system_width(sys["bars"], 1.0)
    last = si == systems.length - 1
    k = 1.0
    if natural > room
      k = score_fit(sys["bars"], room, 0.0, 1.0)
    elsif !last || natural >= room * 0.85
      k = score_fit(sys["bars"], room, 1.0, 8.0)
    end
    sys["k"] = k
  end
  systems
end

# The stretch that makes `bars` exactly `width` wide, by bisection: a
# system's width only ever grows with it.
# A line's width is a constant and a sum of `max(ideal × k, least)`, one
# term for each of its gaps: `score_gaps` and `score_bar_width` taken
# apart, once, so that finding the stretch that fills a line is
# arithmetic on two flat lists and not thirty layouts of every bar.
def score_line_terms(bars)
  base = score_prefix_width(bars[0], bars[0]["first"] == true)
  ideals = []
  leasts = []
  for bar, i in bars
    items = bar["items"]
    if items.length == 0
      ideals.push(6.0)
      leasts.push(4.0)
    else
      base += 1.2 + items[0]["left"]
      for j in 0..items.length
        ev = items[j]
        ideals.push(ev["ideal"])
        leasts.push(j + 1 < items.length ? ev["right"] + 0.6 + items[j + 1]["left"] : ev["right"] + 0.8)
      end
    end
    base += score_change_width(bar) unless i == 0
    base += score_barline_width(".|:") + 0.4 if i == 0 && !bar["open_repeat"].nil?
    base += score_barline_width(bar["bar_drawn"] ?? bar["bar"])
  end
  {"base": base, "ideals": ideals, "leasts": leasts}
end

def score_terms_width(terms, k)
  total = terms["base"]
  ideals = terms["ideals"]
  leasts = terms["leasts"]
  for j in 0..ideals.length
    total += score_max(ideals[j] * k, leasts[j])
  end
  total
end

def score_fit(bars, width, lo, hi)
  terms = score_line_terms(bars)
  for _ in 0..30
    mid = (lo + hi) / 2.0
    if score_terms_width(terms, mid) > width
      hi = mid
    else
      lo = mid
    end
  end
  lo
end

# ---- Placing ---------------------------------------------------------------

def score_place(systems, width, left, indent, rest = 0.0)
  for sys, si in systems
    bars = sys["bars"]
    sys["left"] = left + (si == 0 ? indent : rest)
    x = sys["left"] + score_prefix_width(bars[0], bars[0]["first"] == true)
    sys["prefix"] = x
    sys["right"] = 0.0
    for bar, bi in bars
      bar["x0"] = x
      x += score_change_width(bar) unless bi == 0
      if bi == 0 && !bar["open_repeat"].nil?
        x += score_barline_width(".|:")
        bar["open_repeat_x"] = x
        x += 0.4
      end
      gaps = score_gaps(bar, sys["k"])
      items = bar["items"]
      if items.length == 1 && items[0]["k"] == "rest" && (items[0]["full"] == true || items[0]["ticks"] == bar["length"])
        span = gaps.reduce(fn(acc, g) acc + g, 0.0)
        items[0]["x"] = x + span / 2.0 - score_glyph("restWhole")["advance"] / 2.0
        items[0]["whole_bar"] = true
        items[0]["span0"] = x
        items[0]["span1"] = x + span
        x += span
      else
        x += gaps[0]
        for ev, i in items
          ev["x"] = x
          x += gaps[i + 1]
        end
      end
      bar["x1"] = x
      x += score_barline_width(bar["bar_drawn"] ?? bar["bar"])
    end
    sys["bar_end"] = x
    sys["right"] = x + (sys["courtesy"] ?? 0.0)
    score_stems_beams(bars)
  end
end

# Every note's stem and beam, once the notes have their places.
def score_stems_beams(bars)
  for bar in bars
    for ev in bar["items"]
      score_stem(ev) if ev["k"] == "note" && ev["beam"].nil?
    end
    groups = []
    for ev in bar["items"]
      groups.push(ev["beam"]) if !ev["beam"].nil? && ev["beam"]["notes"][0]["n"] == ev["n"]
    end
    for g in groups
      score_beam(g)
    end
  end
end

# Systems one under the other, and on paper, pages: LilyPond's vertical
# spacing. A staff is `gap` from the one above (its `system-system-spacing`,
# 12 spaces on paper) and a space clear of its ink; the first is 5 below the
# titles (`markup-system-spacing`) or a space below the margin; a system that
# would cross the bottom margin starts a page, whose page number takes the
# top. Full pages are then spread to the bottom margin, as `ragged-bottom`
# being false asks, and the last is left as it falls (`ragged-last-bottom`).
# Answers the pages, each with the systems on it.
def score_stack(systems, layout, head)
  page_h = layout["page_h"]
  margin = layout["top"] ?? 0.0
  floor_y = page_h.nil? ? 0.0 : page_h - (layout["bottom"] ?? 0.0)
  gap = layout["gap"] ?? 10.0
  titled = head["lines"].length > 0
  pages = [ {"index": 0, "systems": []} ]
  prev = nil
  for sys in systems
    reach = score_reach(sys)
    tp = 0.0
    if prev.nil?
      tp = titled ? score_max(margin + head["bottom"] + 3.0, margin + head["bottom"] + 0.5 - reach[0]) : margin + 0.5 - reach[0]
      tp += 1.0 if titled && page_h.nil?
    else
      tp = score_max(prev["top"] + gap, prev["bottom"] + 1.0 - reach[0])
    end
    forced = !prev.nil? && prev["bars"][-1]["brk"] == "page"
    if !page_h.nil? && !prev.nil? && (forced || tp + reach[1] + 1.0 > floor_y)
      pages.push({"index": pages.length, "systems": []})
      tp = margin + 3.5 + 1.0 - reach[0]
    end
    sys["top"] = tp
    sys["bottom"] = tp + reach[1]
    sys["reach_hi"] = reach[0]
    sys["page"] = pages.length - 1
    pages[-1]["systems"].push(sys)
    prev = sys
  end
  unless page_h.nil?
    for pg, pi in pages
      on_page = pg["systems"]
      next if pi == pages.length - 1 || on_page.length < 2

      extra = floor_y - 1.0 - on_page[-1]["bottom"]
      step = score_min(extra / (on_page.length - 1), 6.0)
      next if step <= 0.0

      for sys, k in on_page
        sys["top"] = sys["top"] + step * k
        sys["bottom"] = sys["bottom"] + step * k
      end
    end
  end
  pages
end

# Tempo marks: over the note they were written before, bold words and then
# LilyPond's metronome, `(♩ = 112)`, a space clear of the ink below. At the
# start of a system they stand where the key and time do.
def score_marks(systems)
  score_hairpins(systems)
  for sys in systems
    # Brackets over repeat endings go over the top staff only.
    sys["voltas"] = (sys["staff_index"] ?? 0) == 0 ? score_voltas(sys) : []
    sys["tuplets"] = score_tuplets(sys)
    score_scripts(sys)
    score_dynamics(sys)
    score_texts(sys)
    sys["marks"] = []
    for bar, bi in sys["bars"]
      for ev, ii in bar["items"]
        mark = ev["tempo"]
        next if mark.nil?

        x = ev["x"]
        x = sys["left"] + 0.8 + score_glyph(score_clef_glyph(bar["clef"]))["advance"] + 1.0 if bi == 0 && ii == 0
        w = score_mark_width(mark)
        low = -1.0
        for other_bar in sys["bars"]
          for other in other_bar["items"]
            next if other["x"] + 1.5 < x || other["x"] > x + w + 1.0
            next unless other["k"] == "note"

            low = score_min(low, score_y(other["heads"][-1]["pos"]) - 0.7)
            low = score_min(low, other["stem_end"] - 0.3)
          end
        end
        for tp in sys["tuplets"]
          next if !tp["up"] || tp["x1"] < x - 1.0 || tp["x0"] > x + w + 1.0

          low = score_min(low, score_min(tp["ya"], tp["yb"]) - 1.0)
        end
        for other_bar in sys["bars"]
          for other in other_bar["items"]
            next if other["x"] + 1.5 < x || other["x"] > x + w + 1.0

            low = score_min(low, (other["reach_up"] ?? 0.0) - 0.3)
          end
        end
        for tx in sys["texts"]
          next if tx["dir"] > 0 || tx["x1"] < x - 1.0 || tx["x0"] > x + w + 1.0

          low = score_min(low, tx["top"] - 0.3)
        end
        # And clear of the slurs and ties under it: their outline's points.
        for c in sys["curves"]
          ci = 0
          while ci < c.length
            args = [2, 2, 4, 6, 0][c[ci]]
            for jj in 0..args
              if jj % 2 == 0
                px = c[ci + 1 + jj]
                py = c[ci + 2 + jj]
                low = score_min(low, py - 0.2) if px >= x - 1.0 && px <= x + w + 1.0
              end
            end
            ci += 1 + args
          end
        end
        sys["marks"].push({"x": x, "y": low - 0.9, "mark": mark})
      end
    end
  end
end

# The brackets over an ending, "1." and "2.": a line over its bars, a hook
# down where it starts, and one where it ends if it goes back to the
# repeat; a bracket a line break cuts is drawn on both lines, hooked where
# its ending really starts and stops. A space clear of the notes under it.
# The tuplets of a system, each placed as LilyPond places it: on the side
# its stems point to, its number centred on a line 1.1 spaces clear of the
# notes. Under one beam the line follows the beam and only the number is
# drawn (`bracket-visibility` 'if-no-beam); otherwise a bracket is, its
# hooks 0.7 spaces long, reaching 0.2 past the first and the last note.
def score_tuplets(sys)
  groups = []
  by_id = {}
  for bar in sys["bars"]
    for ev in bar["items"]
      next if ev["tuplet"].nil?

      key = str(ev["tuplet"]["id"])
      unless by_id.has_key(key)
        by_id[key] = {"items": [], "n": ev["tuplet"]["n"]}
        groups.push(by_id[key])
      end
      by_id[key]["items"].push(ev)
    end
  end
  groups.map { |tg| score_tuplet_place(tg) }
end

def score_tuplet_place(tg)
  items = tg["items"]
  notes = items.filter { |ev| ev["k"] == "note" }
  first_beam = notes.length > 0 && !notes[0]["beam"].nil? ? notes[0]["beam"]["notes"][0]["i"] : -1
  beamed = notes.length == items.length && notes.length > 1 && first_beam >= 0 && notes.all? { |ev| !ev["beam"].nil? && ev["beam"]["notes"][0]["i"] == first_beam }
  ups = notes.filter { |ev| ev["up"] == true }.length
  up = beamed ? notes[0]["beam"]["up"] : ups * 2 >= notes.length
  last = items[-1]
  x0 = items[0]["x"] - 0.2
  x1 = last["x"] + (last["head_w"] ?? 1.2) + 0.2
  dir = up ? -1.0 : 1.0
  ya = 0.0
  yb = 0.0
  if beamed
    g = notes[0]["beam"]
    ya = score_beam_y(g, x0) + 1.1 * dir
    yb = score_beam_y(g, x1) + 1.1 * dir
  else
    # A line through the outermost ink of the first and the last, its
    # slope held to a space, then moved out until every note clears it.
    edges = items.map { |ev| score_tuplet_edge(ev, up) }
    ya = edges[0] + 1.1 * dir
    yb = edges[-1] + 1.1 * dir
    yb = ya + score_max(-1.0, score_min(1.0, yb - ya))
    span = score_max(x1 - x0, 0.01)
    push = 0.0
    for ev, k in items
      at = ya + (yb - ya) * (ev["x"] - x0) / span
      need = edges[k] + 1.1 * dir
      push = up ? score_min(push, need - at) : score_max(push, need - at)
    end
    # And off the staff by a quarter space, hooks included.
    reach = up ? score_min(ya, yb) + push + 0.7 : score_max(ya, yb) + push - 0.7
    push += up ? score_min(0.0, -0.25 - reach) : score_max(0.0, 4.25 - reach)
    ya += push
    yb += push
  end
  {"x0": x0, "x1": x1, "ya": ya, "yb": yb, "up": up, "bracket": !beamed, "label": str(tg["n"])}
end

# How far a note or a rest reaches on one side, in staff y: its stem's end
# or the outside of its heads; a rest, the middle of the staff and a space.
def score_tuplet_edge(ev, up)
  if ev["k"] != "note"
    return up ? 1.0 : 3.0
  end

  y_top = score_y(ev["heads"][-1]["pos"]) - 0.5
  y_bottom = score_y(ev["heads"][0]["pos"]) + 0.5
  return score_min(y_top, ev["up"] && ev["base"] > 1 ? ev["stem_end"] : y_top) if up

  score_max(y_bottom, !ev["up"] && ev["base"] > 1 ? ev["stem_end"] : y_bottom)
end

# ---- Expression: articulations, dynamics, hairpins, words -------------------

# How far a note or a rest reaches up and down before anything is put on
# it: its heads and its stem, or a rest's middle space and a half.
def score_item_extent(ev)
  return [1.0, 3.0] if ev["k"] != "note"

  [score_tuplet_edge(ev, true), score_tuplet_edge(ev, false)]
end

def score_item_w(ev)
  return ev["head_w"] unless ev["head_w"].nil?
  return score_max(ev["span1"] - ev["span0"] - 2.0, 1.0) unless ev["mm"].nil?

  score_glyph(score_rest_name(ev["base"]))["advance"]
end

# Each note's articulations, stacked away from it by LilyPond's rules:
# opposite the stem unless the source says a side, the fermata above; the
# nearest first by priority, each `pad` off the last. A staccato, a tenuto
# or a marcato inside the staff sits in a space; the others leave the
# staff by a quarter space (`staff-padding`). What they reach is kept on
# the note, for what goes outside them.
def score_scripts(sys)
  sys["scripts"] = []
  for bar in sys["bars"]
    for ev in bar["items"]
      ext = score_item_extent(ev)
      ev["reach_up"] = ext[0]
      ev["reach_down"] = ext[1]
      next if ev["scripts"].nil?

      xc = ev["x"] + score_item_w(ev) / 2.0
      heads_top = ev["k"] == "note" ? score_y(ev["heads"][-1]["pos"]) - 0.5 : 1.0
      heads_bottom = ev["k"] == "note" ? score_y(ev["heads"][0]["pos"]) + 0.5 : 3.0
      up_cursor = heads_top
      down_cursor = heads_bottom
      # A side the stem is on starts past the stem's end.
      up_cursor = ext[0] if ev["k"] == "note" && ev["up"] == true
      down_cursor = ext[1] if ev["k"] == "note" && ev["up"] != true
      list = ev["scripts"].sort_by { |sc| SCORE_SCRIPTS[sc["name"]]["prio"] }
      for sc in list
        rule = SCORE_SCRIPTS[sc["name"]]
        dir = sc["dir"]
        dir = rule["side"] if dir == 0 && rule["side"] != 0
        dir = ev["up"] == true ? 1 : -1 if dir == 0
        name = dir < 0 ? rule["up"] : rule["down"]
        bb = score_glyph(name)["bbox"]
        y = 0.0
        if dir < 0
          y = up_cursor - rule["pad"] - bb[3]
          if rule["quant"]
            mid = y + (bb[1] + bb[3]) / 2.0
            y += score_space_above(mid) - mid if mid > -0.5 && mid < 4.5
          elsif y + bb[3] > -0.25
            y = -0.25 - bb[3]
          end
          up_cursor = y + bb[1]
        else
          y = down_cursor + rule["pad"] - bb[1]
          if rule["quant"]
            mid = y + (bb[1] + bb[3]) / 2.0
            y += score_space_below(mid) - mid if mid > -0.5 && mid < 4.5
          elsif y + bb[1] < 4.25
            y = 4.25 - bb[1]
          end
          down_cursor = y + bb[3]
        end
        sys["scripts"].push({"glyph": name, "x": xc, "y": y})
      end
      ev["reach_up"] = score_min(ext[0], up_cursor)
      ev["reach_down"] = score_max(ext[1], down_cursor)
    end
  end
end

# The middle of the space at or above `y`, and at or below it.
def score_space_above(y)
  Math.floor(y - 0.5) + 0.5
end

def score_space_below(y)
  Math.ceil(y - 0.5) + 0.5
end

# Hairpins, from where each starts to where it ends: a `\!`, the next
# dynamic, or the next hairpin; cut into one piece for each system it
# crosses. Placed on their systems later, with the dynamics.
def score_hairpins(systems)
  flat = []
  for sys, si in systems
    sys["hairpins"] = []
    for bar in sys["bars"]
      for ev in bar["items"]
        flat.push({"ev": ev, "sys": si, "bar": bar})
      end
    end
  end
  for at, k in flat
    grow = at["ev"]["hairpin"]
    next if grow.nil?

    stop = flat.length - 1
    how = "end"
    jj = k + 1
    while jj < flat.length
      other = flat[jj]["ev"]
      if other["hairpin_end"] == true
        stop = jj
        how = "note"
        break
      end
      if !other["dyn"].nil? || !other["hairpin"].nil?
        stop = jj
        how = "next"
        break
      end
      jj += 1
    end
    start_ev = at["ev"]
    # It leaves a dynamic on its own note by LilyPond's `bound-padding`.
    x0 = start_ev["x"]
    x0 = score_max(x0, score_dyn_x(start_ev) + score_dyn_width(start_ev["dyn"]) + 1.0) unless start_ev["dyn"].nil?
    end_at = flat[stop]
    end_ev = end_at["ev"]
    x1 = end_ev["x"] + score_item_w(end_ev) + 0.15
    if how == "next"
      x1 = end_ev["dyn"].nil? ? end_ev["x"] - 0.6 : score_dyn_x(end_ev) - 1.0
    end
    # One that ends on a bar's first note stops at the bar line before it
    # (`to-barline`).
    if how != "end" && end_ev["start"] == 0 && stop > k && flat[stop - 1]["bar"]["number"] != end_at["bar"]["number"]
      x1 = score_min(x1, flat[stop - 1]["bar"]["x1"] + score_barline_width(flat[stop - 1]["bar"]["bar"]) - 0.8)
      end_at = flat[stop - 1]
    end
    first = at["sys"]
    last = end_at["sys"]
    for si in range(first, last + 1)
      sys = systems[si]
      a = si == first ? x0 : sys["prefix"]
      b = si == last ? x1 : sys["right"]
      parts = last - first + 1
      ka = float(si - first) / parts
      kb = float(si - first + 1) / parts
      sys["hairpins"].push({"x0": a, "x1": score_max(b, a + 2.0), "grow": grow, "from": ka, "to": kb})
    end
  end
end

def score_dyn_letters(dyn)
  names = {"p": "dynamicPiano", "m": "dynamicMezzo", "f": "dynamicForte", "r": "dynamicRinforzando", "s": "dynamicSforzando", "z": "dynamicZ", "n": "dynamicNiente"}
  dyn.chars().map { |ch| names[ch] }
end

def score_dyn_width(dyn)
  score_dyn_letters(dyn).map { |name| score_glyph(name)["advance"] }.reduce(fn(acc, w) acc + w, 0.0)
end

# A dynamic is centred on its note's head by its letters' advances, as
# LilyPond centres it.
def score_dyn_x(ev)
  ev["x"] + score_item_w(ev) / 2.0 - score_dyn_width(ev["dyn"]) / 2.0
end

# Dynamics and hairpins below the staff, on lines: those that touch share
# one, placed as LilyPond's `DynamicLineSpanner` is — its ink 0.6 spaces
# clear of the staff and of what the notes reach down to, a hairpin 2/3 of
# a space open, a dynamic's baseline 0.6 below the line it is centred on.
def score_dynamics(sys)
  els = []
  for bar in sys["bars"]
    for ev in bar["items"]
      next if ev["dyn"].nil?

      x = score_dyn_x(ev)
      top = 0.0
      bottom = 0.0
      for name in score_dyn_letters(ev["dyn"])
        bb = score_glyph(name)["bbox"]
        top = score_min(top, bb[1])
        bottom = score_max(bottom, bb[3])
      end
      els.push({"kind": "dyn", "text": ev["dyn"], "x0": x, "x1": x + score_dyn_width(ev["dyn"]), "top": 0.6 + top, "bottom": 0.6 + bottom})
    end
  end
  for hp in sys["hairpins"]
    els.push({"kind": "hairpin", "x0": hp["x0"], "x1": hp["x1"], "grow": hp["grow"], "from": hp["from"], "to": hp["to"], "top": -0.6666, "bottom": 0.6666})
  end
  els = els.sort_by { |el| el["x0"] }
  sys["dynamics"] = []
  k = 0
  while k < els.length
    group = [els[k]]
    reach = els[k]["x1"]
    k += 1
    while k < els.length && els[k]["x0"] - reach < 1.5
      group.push(els[k])
      reach = score_max(reach, els[k]["x1"])
      k += 1
    end
    line = 0.0
    for el in group
      line = score_max(line, score_dyn_line(sys, el))
    end
    for el in group
      el["y"] = line
      el["bottom"] = line + el["bottom"] + 0.3
      sys["dynamics"].push(el)
    end
  end
end

# The lowest line `el` may sit on: its ink 0.6 below the staff and below
# every note it is under. A hairpin's ink rises toward its open end.
def score_dyn_line(sys, el)
  need = 4.0 + 0.6 - el["top"]
  for bar in sys["bars"]
    for ev in bar["items"]
      right = ev["x"] + score_item_w(ev)
      next if right < el["x0"] - 0.2 || ev["x"] > el["x1"] + 0.2

      rise = -el["top"]
      if el["kind"] == "hairpin"
        span = score_max(el["x1"] - el["x0"], 0.01)
        at = score_max(0.0, score_min(1.0, (ev["x"] - el["x0"]) / span))
        open = el["from"] + (el["to"] - el["from"]) * at
        open = 1.0 - open if el["grow"] == ">"
        rise = 0.6666 * open
      end
      need = score_max(need, (ev["reach_down"] ?? 4.0) + 0.6 + rise)
    end
  end
  for tp in sys["tuplets"] ?? []
    next if tp["up"] || tp["x1"] < el["x0"] || tp["x0"] > el["x1"]

    need = score_max(need, score_max(tp["ya"], tp["yb"]) + 0.9 + 0.6 - el["top"])
  end
  need
end

# Words over or under a note, left-aligned on it as LilyPond's
# `TextScript` is: outside what the notes and their articulations reach
# by 0.45 and the staff by half a space; under the staff, below the
# dynamics too.
def score_texts(sys)
  sys["texts"] = []
  em = score_em(0.0)
  for bar in sys["bars"]
    for ev in bar["items"]
      for tx in ev["texts"] ?? []
        w = score_text_width(tx["text"], "regular", em)
        box = score_text_box(tx["text"], "regular", em)
        x0 = ev["x"]
        x1 = x0 + w
        y = 0.0
        if tx["dir"] < 0
          edge = -0.5
          for other_bar in sys["bars"]
            for other in other_bar["items"]
              next if other["x"] + score_item_w(other) < x0 - 0.2 || other["x"] > x1 + 0.2

              edge = score_min(edge, other["reach_up"] ?? 0.0)
            end
          end
          for prev in sys["texts"]
            edge = score_min(edge, prev["top"]) if prev["dir"] < 0 && prev["x1"] > x0 && prev["x0"] < x1
          end
          y = edge - 0.45 - box[1]
        else
          edge = 4.5
          for other_bar in sys["bars"]
            for other in other_bar["items"]
              next if other["x"] + score_item_w(other) < x0 - 0.2 || other["x"] > x1 + 0.2

              edge = score_max(edge, other["reach_down"] ?? 4.0)
            end
          end
          for dy in sys["dynamics"]
            edge = score_max(edge, dy["bottom"]) if dy["x1"] > x0 - 0.2 && dy["x0"] < x1 + 0.2
          end
          for prev in sys["texts"]
            edge = score_max(edge, prev["bottom"]) if prev["dir"] > 0 && prev["x1"] > x0 && prev["x0"] < x1
          end
          y = edge + 0.45 - box[0]
        end
        sys["texts"].push({"text": tx["text"], "x0": x0, "x1": x1, "y": y, "top": y + box[0], "bottom": y + box[1], "dir": tx["dir"]})
      end
    end
  end
end

# How far words rise above their baseline and fall below it, in staff
# spaces at `em`, from their letters' outlines.
def score_text_box(words, weight, em)
  face = score_letters()[weight]
  rise = 0
  fall = 0
  for ch in words.chars()
    next unless face.has_key(ch)

    cmds = face[ch]["f"]
    ci = 0
    while ci < cmds.length
      args = [2, 2, 4, 6, 0][cmds[ci]]
      jj = 1
      while jj < args
        rise = score_min(rise, cmds[ci + 1 + jj])
        fall = score_max(fall, cmds[ci + 1 + jj])
        jj += 2
      end
      ci += 1 + args
    end
  end
  [rise * em / 1000.0, fall * em / 1000.0]
end

def score_voltas(sys)
  out = []
  run = nil
  for bar, bi in sys["bars"]
    label = bar["volta_in"]
    if !label.nil? && run.nil?
      run = {"label": label, "first": bar["volta_first"] == true, "x0": bar["x0"], "bars": []}
    end
    unless run.nil?
      run["bars"].push(bi)
      run["x1"] = bar["x1"] + score_barline_width(bar["bar_drawn"] ?? bar["bar"])
      run["closed"] = bar["volta_last"] == true && bar["volta_closed"] == true
      if bar["volta_last"] == true || bi == sys["bars"].length - 1 || sys["bars"][bi + 1]["volta_in"] != label
        out.push(run)
        run = nil
      end
    end
  end
  for vb in out
    low = -2.0
    for bi in vb["bars"]
      for ev in sys["bars"][bi]["items"]
        next unless ev["k"] == "note"

        low = score_min(low, score_y(ev["heads"][-1]["pos"]) - 0.7)
        low = score_min(low, ev["stem_end"] - 0.3)
      end
    end
    vb["y"] = low - 1.0
  end
  out
end

def score_mark_width(mark)
  em = score_em(0.0)
  w = mark["text"] == "" ? 0.0 : score_text_width(mark["text"], "bold", em)
  if mark["bpm"] > 0
    w += 0.6 if w > 0.0
    w += score_text_width("( = " + str(mark["bpm"]) + ")", "regular", em) + 1.6
  end
  w
end

# How far above the top line (negative) and below it the ink goes: heads
# and their accidentals, stems and beams, and the hull of every curve.
def score_reach(sys)
  return sys["reach"] if sys.has_key("reach")

  hi = 0.0
  lo = 4.0
  for bar in sys["bars"]
    for ev in bar["items"]
      next unless ev["k"] == "note"

      for hd in ev["heads"]
        y = score_y(hd["pos"])
        hi = score_min(hi, y - (hd["acc"].nil? ? 0.6 : 1.8))
        lo = score_max(lo, y + (hd["acc"].nil? ? 0.6 : 1.8))
      end
      hi = score_min(hi, ev["stem_end"] - 0.6)
      lo = score_max(lo, ev["stem_end"] + 0.6)
    end
  end
  for mk in sys["marks"] ?? []
    hi = score_min(hi, mk["y"] - 1.8)
  end
  hi = score_min(hi, -3.0) if sys["bars"][0]["number"] > 1
  for vb in sys["voltas"] ?? []
    hi = score_min(hi, vb["y"] - 0.4)
  end
  for tp in sys["tuplets"] ?? []
    hi = score_min(hi, score_min(tp["ya"], tp["yb"]) - 0.9) if tp["up"]
    lo = score_max(lo, score_max(tp["ya"], tp["yb"]) + 0.9) unless tp["up"]
  end
  for bar in sys["bars"]
    for ev in bar["items"]
      hi = score_min(hi, ev["reach_up"] ?? 0.0)
      lo = score_max(lo, ev["reach_down"] ?? 4.0)
    end
  end
  for dy in sys["dynamics"] ?? []
    lo = score_max(lo, dy["bottom"])
  end
  for tx in sys["texts"] ?? []
    hi = score_min(hi, tx["top"]) if tx["dir"] < 0
    lo = score_max(lo, tx["bottom"]) if tx["dir"] > 0
  end
  for bar in sys["bars"]
    hi = score_min(hi, -2.6) if bar["items"].length > 0 && !bar["items"][0]["mm"].nil?
  end
  for c in sys["curves"]
    i = 0
    while i < c.length
      args = [2, 2, 4, 6, 0][c[i]]
      for jj in 0..args
        if jj % 2 == 1
          hi = score_min(hi, c[i + 1 + jj])
          lo = score_max(lo, c[i + 1 + jj])
        end
      end
      i += 1 + args
    end
  end
  [hi, lo]
end

def score_y(pos)
  2.0 - pos / 2.0
end

# An unbeamed stem: 3.5 spaces from its outermost head, longer for the
# hooks of a thirty-second, and never stopping short of the middle line.
def score_stem(ev)
  if ev["base"] == 1
    ev["stem_end"] = score_y(ev["heads"][-1]["pos"])
    return nil
  end
  stem_len = 3.5 + (ev["base"] == 32 ? 0.75 : 0.0)
  if ev["up"]
    tip = score_y(ev["heads"][-1]["pos"]) - stem_len
    ev["stem_end"] = score_min(tip, 2.0)
  else
    tip = score_y(ev["heads"][0]["pos"]) + stem_len
    ev["stem_end"] = score_max(tip, 2.0)
  end
end

# The x of a stem's outer edge: right of the head going up, left of it
# going down.
def score_stem_x(ev)
  ev["up"] ? ev["x"] + ev["head_w"] : ev["x"]
end

# A beam's top edge, quanted: inside the staff a beam half a space thick
# either sits on a line, straddles it or hangs from it, so its top edge
# lies a line's half-thickness off a line or a quarter above one. Outside
# the staff anything a quarter space apart will do. `toward` is the
# direction a stem may grow.
def score_quant(y, toward)
  inside = y > -0.6 && y < 4.6
  best = nil
  base = y.floor - 2
  for i in 0..6
    line = float(base + i)
    half_line = SCORE_RULE["staff"] / 2.0
    bt = SCORE_RULE["beam"]
    for c in inside ? [line - bt - half_line, line - bt / 2.0, line + half_line] : [line, line + 0.25, line + 0.5, line + 0.75]
      ok = true
      ok = c <= y + 0.0001 if toward < 0
      ok = c >= y - 0.0001 if toward > 0
      if ok && (best.nil? || (c - y).abs < (best - y).abs)
        best = c
      end
    end
  end
  best ?? y
end

# A beam: its slope from the outer notes, damped and held to a space and a
# half; flat
# when an inner note is more extreme than both ends (a concave group);
# placed so its shortest stem is 3.5 spaces and every stem reaches the
# middle line; then each end quanted.
def score_beam(g)
  notes = g["notes"]
  up = g["up"]
  n_beams = notes.reduce(fn(acc, ev) score_max(acc, score_flags(ev["base"])), 0)
  thick = SCORE_RULE["beam"]
  near = notes.map { |ev| score_y(up ? ev["heads"][-1]["pos"] : ev["heads"][0]["pos"]) }
  x0 = score_stem_x(notes[0])
  x1 = score_stem_x(notes[-1])
  dx = score_max(x1 - x0, 0.01)
  dy = near[-1] - near[0]
  # Damped to a little over half the notes' own rise, and never more than
  # a space and a half end to end: LilyPond 2.24 tilts a falling e-d-c-b
  # by 0.8 of a space and a rising sixth of eighths by about 1.4.
  slope = (dy * 0.55).clamp(-1.5, 1.5) / dx
  concave = false
  for y, i in near
    next if i == 0 || i == near.length - 1

    if up && y < score_min(near[0], near[-1])
      concave = true
    end
    if !up && y > score_max(near[0], near[-1])
      concave = true
    end
  end
  slope = 0.0 if concave
  # Where the outer edge sits at x0. LilyPond scores each stem by how far
  # it is from its ideal length and takes the best total, which with the
  # slope settled puts the *mean* stem at the ideal: so do that, then make
  # sure no stem is shorter than its minimum. Measured on LilyPond 2.24's
  # own output, a one-beam group's stems average 3.36 spaces to the outer
  # edge; more beams want a little more, as its `beamed-lengths` do.
  ideal = [3.36, 3.6, 3.8][score_min(n_beams, 3) - 1]
  shortest = 2.5 + (n_beams - 1) * SCORE_RULE["beam_step"]
  b = 0.0
  for ev, i in notes
    xs = score_stem_x(ev) - x0
    b += up ? near[i] - ideal - slope * xs : near[i] + ideal - slope * xs
  end
  b = b / notes.length
  for ev, i in notes
    xs = score_stem_x(ev) - x0
    stem_len = up ? near[i] - (b + slope * xs) : (b + slope * xs) - near[i]
    b -= shortest - stem_len if up && stem_len < shortest
    b += shortest - stem_len if !up && stem_len < shortest
  end
  # Every stem reaches the middle line: the beam hangs from it at the
  # nearest, or sits on it.
  for ev, i in notes
    xs = score_stem_x(ev) - x0
    rim = b + slope * xs
    b -= rim - 2.0 if up && rim > 2.0
    b += 2.0 - rim if !up && rim < 2.0
  end
  # Quant both ends of the outer beam: the top edge of an up beam, the
  # bottom edge of a down one (whose top is a thickness above).
  y_left = b
  y_right = b + slope * dx
  q_left = y_left
  q_right = y_right
  # To the nearest allowed place, unless that would leave a stem short.
  toward = 0
  for ev, i in notes
    xs = score_stem_x(ev) - x0
    stem_len = up ? near[i] - (b + slope * xs) : (b + slope * xs) - near[i]
    if stem_len < shortest + 0.25
      toward = up ? -1 : 1
    end
  end
  if up
    q_left = score_quant(y_left, toward)
    q_right = score_quant(y_right, toward)
  else
    q_left = score_quant(y_left - thick, toward) + thick
    q_right = score_quant(y_right - thick, toward) + thick
  end
  # Quanting each end on its own can open the slope past its limit: bring
  # the right end back within it, toward the left.
  if (q_right - q_left).abs > 1.5
    held = q_right > q_left ? q_left + 1.5 : q_left - 1.5
    back = q_right > q_left ? -1 : 1
    q_right = up ? score_quant(held, back) : score_quant(held - thick, back) + thick
  end
  # Quanting must not turn the slope round.
  turned = (q_right - q_left) * (y_right - y_left) < 0.0
  levelled = slope == 0.0 && q_right != q_left
  if turned || levelled
    q = up ? score_min(q_left, q_right) : score_max(q_left, q_right)
    q_left = q
    q_right = q
  end
  g["x0"] = x0
  g["x1"] = x1
  g["y0"] = q_left
  g["y1"] = q_right
  g["n"] = n_beams
  for ev in notes
    ev["stem_end"] = score_beam_y(g, score_stem_x(ev))
  end
end

def score_beam_y(g, x)
  span = g["x1"] - g["x0"]
  return g["y0"] if span <= 0.0

  g["y0"] + (g["y1"] - g["y0"]) * (x - g["x0"]) / span
end

# ---- Ties and slurs --------------------------------------------------------

# LilyPond's height of a curve over `width`: it grows with the width and
# levels off at `limit`.
def score_curve_height(width, limit, ratio)
  limit * 2.0 / 3.141592653589793 * score_atan(3.141592653589793 / 2.0 * ratio / limit * width)
end

# Soli has no arctangent; this is the classic reduction to [0, 1] and a
# minimax polynomial there, good to 1e-5.
def score_atan(v)
  return -score_atan(-v) if v < 0.0
  return 3.141592653589793 / 2.0 - score_atan(1.0 / v) if v > 1.0

  v2 = v * v
  v * (0.99997726 + v2 * (-0.33262347 + v2 * (0.19354346 + v2 * (-0.11643287 + v2 * (0.05265332 + v2 * -0.01172120)))))
end

def score_curves(parsed, systems)
  notes = []
  for sys, si in systems
    for bar in sys["bars"]
      for ev in bar["items"]
        if ev["k"] == "note"
          ev["sys"] = si
          notes.push(ev)
        end
      end
    end
  end
  for sys in systems
    sys["curves"] = []
  end
  # Ties: each head of a tied note to the same pitch in the next.
  for ev, i in notes
    next unless ev["tie"] == true && i + 1 < notes.length

    nxt = notes[i + 1]
    count = ev["heads"].length
    for hd, hi in ev["heads"]
      other = nxt["heads"].find { |o| o["d"] == hd["d"] }
      next if other.nil?

      # Upper half of a chord over, lower half under; a single note away
      # from its stem.
      over = count == 1 ? !ev["up"] : hi >= count / 2
      score_tie(systems, ev, hd, nxt, other, over)
    end
  end
  # Slurs: from the note that opens one to the note that closes it.
  open = []
  for ev in notes
    open.push(ev) if ev["slur_on"] == true
    if ev["slur_off"] == true && open.length > 0
      first = open.pop()
      score_slur(systems, notes, first, ev)
    end
  end
end

def score_tie(systems, ev, hd, nxt, other, over)
  dir = over ? -1.0 : 1.0
  y = score_y(hd["pos"]) + dir * 0.35
  y2 = score_y(other["pos"]) + dir * 0.35
  xa = ev["x"] + ev["head_w"] + 0.15
  xb = nxt["x"] - 0.15
  if ev["sys"] == nxt["sys"]
    score_arc(systems[ev["sys"]], xa, y, xb, y2, dir, 1.0, 0.333, SCORE_RULE["curve_tip"], SCORE_RULE["curve_mid"])
  else
    sys = systems[ev["sys"]]
    score_arc(sys, xa, y, sys["bar_end"] - 0.5, y, dir, 1.0, 0.333, SCORE_RULE["curve_tip"], SCORE_RULE["curve_mid"])
    later = systems[nxt["sys"]]
    score_arc(later, later["prefix"] - 0.6, y2, xb, y2, dir, 1.0, 0.333, SCORE_RULE["curve_tip"], SCORE_RULE["curve_mid"])
  end
end

def score_slur(systems, notes, first, last)
  ups = notes.filter { |ev| ev["n"] >= first["n"] && ev["n"] <= last["n"] }
  all_up = ups.all? { |ev| ev["up"] }
  # On the heads' side when the stems agree, above when they do not.
  over = all_up ? false : true
  dir = over ? -1.0 : 1.0
  ends = [first, last].map { |ev| score_slur_end(ev, over) }
  inner = ups.filter { |ev| ev["n"] != first["n"] && ev["n"] != last["n"] }
  if first["sys"] == last["sys"]
    score_slur_piece(systems[first["sys"]], inner, ends[0][0], ends[0][1], ends[1][0], ends[1][1], dir, over)
    return nil
  end
  # Across a line break, two pieces, each clear of the notes on its own
  # line: the first runs on to just before the bar line, the second starts
  # just after the clef and key, level with its own end.
  sys = systems[first["sys"]]
  score_slur_piece(sys, inner.filter { |ev| ev["sys"] == first["sys"] }, ends[0][0], ends[0][1], sys["bar_end"] - 0.5, ends[0][1], dir, over)
  later = systems[last["sys"]]
  score_slur_piece(later, inner.filter { |ev| ev["sys"] == last["sys"] }, later["prefix"] - 0.6, ends[1][1], ends[1][0], ends[1][1], dir, over)
end

# One piece of a slur, from (xa, ya) to (xb, yb), clear of the `inner` notes
# under it.
def score_slur_piece(sys, inner, xa, ya, xb, yb, dir, over)
  width = xb - xa
  return nil if width <= 0.2

  # A slur leans as its notes do, but not as far: LilyPond holds its ends
  # near level and lets the curve do the climbing. The end away from the
  # slur's side is brought toward the other until the rise is at most an
  # eighth of the width.
  rise = yb - ya
  most = 0.125 * width
  if rise.abs > most
    if (rise > 0.0) == (dir < 0.0)
      yb = ya + (rise > 0.0 ? most : 0.0 - most)
    else
      ya = yb - (rise > 0.0 ? most : 0.0 - most)
    end
  end
  # When a note between stands in the way, LilyPond levels the ends first —
  # the lower one comes up to the other — and only then arches the curve:
  # a slur over a rising line is an even arc, not a ramp.
  blocked = false
  for ev in inner
    u = (ev["x"] + ev["head_w"] / 2.0 - xa) / width
    p = score_slur_end(ev, over)
    base = ya + (yb - ya) * u
    blocked = true if u > 0.0 && u < 1.0 && (base - p[1]) * -dir > 0.0
  end
  if blocked
    level = dir < 0.0 ? score_min(ya, yb) : score_max(ya, yb)
    ya = level
    yb = level
  end
  # Then the inner notes must clear: raise the curve, and past a point its
  # ends, until every head and stem tip between is outside it.
  hgt = score_curve_height(width, 2.0, 0.25)
  lift = 0.0
  for ev in inner
    u = (ev["x"] + ev["head_w"] / 2.0 - xa) / width
    next if u <= 0.0 || u >= 1.0

    p = score_slur_end(ev, over)
    base = ya + (yb - ya) * u
    need = (base - p[1]) * -dir
    bulge = 4.0 * u * (1.0 - u)
    if need > hgt * bulge
      want = need / bulge
      if want <= 3.0
        hgt = want
      else
        hgt = 3.0
        lift = score_max(lift, need - 3.0 * bulge)
      end
    end
  end
  ya += dir * lift
  yb += dir * lift
  score_arc_h(sys, xa, ya, xb, yb, dir, hgt, SCORE_RULE["curve_tip"], SCORE_RULE["curve_mid"])
end

# Where a slur meets a note: just outside its head, or past its stem tip
# when the stem is on the slur's side.
def score_slur_end(ev, over)
  mid_x = ev["x"] + ev["head_w"] / 2.0
  if over
    top = score_y(ev["heads"][-1]["pos"]) - 0.75
    if ev["up"] && ev["base"] > 1
      return [score_stem_x(ev) - 0.06, ev["stem_end"] - 0.3]
    end

    return [mid_x, top]
  end
  low = score_y(ev["heads"][0]["pos"]) + 0.75
  if !ev["up"] && ev["base"] > 1
    return [score_stem_x(ev) + 0.06, ev["stem_end"] + 0.3]
  end

  [mid_x, low]
end

def score_arc(sys, xa, ya, xb, yb, dir, limit, ratio, tip, mid)
  hgt = score_curve_height(score_max(xb - xa, 0.1), limit, ratio)
  score_arc_h(sys, xa, ya, xb, yb, dir, hgt, tip, mid)
end

# A curve as a closed outline: out along the outer Bézier, back along the
# inner one. Symmetric control points a quarter of the way in, at 4/3 of
# the height, put the curve's middle at the height; the two differ by the
# middle thickness there and by the tip thickness at the ends.
def score_arc_h(sys, xa, ya, xb, yb, dir, hgt, tip, mid)
  w = xb - xa
  return nil if w <= 0.0

  inset = w * 0.25
  c_out = (hgt + mid / 2.0) * 4.0 / 3.0
  c_in = (hgt - mid / 2.0) * 4.0 / 3.0
  t2 = tip / 2.0
  sys["curves"].push([0, xa, ya + dir * t2,
    3, xa + inset, ya + dir * c_out, xb - inset, yb + dir * c_out, xb, yb + dir * t2,
    1, xb, yb - dir * t2,
    3, xb - inset, yb + dir * c_in, xa + inset, ya + dir * c_in, xa, ya - dir * t2,
    4])
end

# ---- Drawing ---------------------------------------------------------------

def score_r(v)
  float(v).round(2)
end

# A rectangle at least a px each way: a staff line or a stem drawn small —
# a page of A4 on a screen — must not round away to nothing.
def score_rect(ink, x, y, w, ht, sp)
  [1, ink, score_r(x * sp), score_r(y * sp), score_r(score_max(w * sp, 1.0)), score_r(score_max(ht * sp, 1.0)), 0]
end

# A fill in staff spaces, `[cmd, args…]`, moved by (ox, oy) and scaled.
def score_fill(ink, cmds, ox, oy, sp)
  out = [5, ink]
  i = 0
  n = cmds.length
  while i < n
    c = cmds[i]
    out.push(c)
    args = [2, 2, 4, 6, 0][c]
    for jj in 0..args
      v = cmds[i + 1 + jj]
      out.push(score_r((jj % 2 == 0 ? ox + v : oy + v) * sp))
    end
    i += 1 + args
  end
  out
end

def score_draw_glyph(paths, ink, name, x, y, sp)
  paths.push(score_fill(ink, score_glyph(name)["fill"], x, y, sp))
end

# The paths of one page — the only one when the score is on a screen, or
# `opts["page_index"]` of those it was laid out on: its titles if it is
# the first, its page number if it is not, and its systems.
def score_paths(engraved, sp, opts)
  ink = opts["colour"] ?? "text.default"
  marks = opts["marks"] ?? {}
  page = opts["page_index"] ?? 0
  # Drawn once in the plain ink, with where each item's paths are; the
  # items `marks` lights are copies of theirs in its colour.
  key = (engraved["memo_key"] ?? "") + "|" + str(sp) + "|" + ink + "|" + str(page)
  drawn = engraved.has_key("memo_key") ? score_memo_get("paths", key) : nil
  if drawn.nil?
    ranges = {}
    drawn = {"paths": score_paths_plain(engraved, sp, ink, page, ranges), "ranges": ranges}
    score_memo_put("paths", key, drawn, 16) if engraved.has_key("memo_key")
  end
  score_recolour(drawn, marks)
end

# ---- MIDI ------------------------------------------------------------------
#
# The same source as a Standard MIDI File (format 0, one track, piano), as
# LilyPond's `\\midi` would write it: what is written, played once —
# repeats as they stand, not unfolded. A quarter is 6 720 of its ticks, the
# engraver's own, so a tuplet lands exactly where it is drawn. Dynamics set
# the loudness by LilyPond's `dynamic-absolute-volume`, a hairpin moves it
# note by note toward where it ends, an accent or a marcato pushes it, and a
# staccato plays half its note (a staccatissimo an eighth): the notes, their
# times and lengths are LilyPond 2.24's on the gallery pieces. `opts`: "bpm" and "beat" (the note value a
# beat is) for a source with no `\\tempo`; "program", the General MIDI
# instrument (0, a piano) for a staff that names none. Several staves are a
# format-1 file, a track each, its instrument its `midiInstrument`.
def score_midi(src, opts = {})
  return eui_score_midi(src, opts) if defined("eui_score_midi")

  parsed = score_parse(src)
  title = (parsed["header"] ?? {})["title"] ?? ""
  staves = parsed["staves"]
  tracks = []
  measured = staves.map { |stf| score_measures(stf["events"]) }
  holds = score_midi_holds(measured)
  for stf, si in staves
    props = stf["props"] ?? {}
    program = SCORE_MIDI_PROGRAMS[props["midiInstrument"] ?? ""] ?? (opts["program"] ?? 0)
    name = props["instrumentName"] ?? (si == 0 ? title : "")
    # One channel a staff; the tenth (9) is General MIDI's drums, skipped.
    channel = score_min(si < 9 ? si : si + 1, 15)
    track = score_midi_track(measured[si], opts.merge({"holds": holds}), program, name, channel, si == 0)
    # Its loudness and its place, as controllers 7 and 10 before anything
    # sounds: `midiMaximumVolume` 0–1, `midiPanPosition` -1 (left) to 1.
    controls = []
    controls = controls + [0, 176 + channel, 7, int(score_max(0.0, score_min(1.0, props["midiMaximumVolume"])) * 127.0 + 0.5)] unless props["midiMaximumVolume"].nil?
    controls = controls + [0, 176 + channel, 10, int(64.0 + score_max(-1.0, score_min(1.0, props["midiPanPosition"])) * 63.0 + 0.5)] unless props["midiPanPosition"].nil?
    tracks.push(controls + track)
  end
  quarter = score_whole() / 4
  out = [77, 84, 104, 100, 0, 0, 0, 6, 0, tracks.length > 1 ? 1 : 0] + score_midi_be(tracks.length, 2) + score_midi_be(quarter, 2)
  for track in tracks
    out = out + [77, 84, 114, 107] + score_midi_be(track.length, 4) + track
  end
  out
end

# One staff's track: its name, its instrument, its time signatures and
# keys, the tempos on the first, and its notes on its channel.
def score_midi_track(bars, opts, program, name, channel, first_track)
  ev_out = []
  ev_out.push([0, 0, [255, 3] + score_midi_vlq(score_midi_text(name).length) + score_midi_text(name)]) if name != ""
  ev_out.push([0, 0, [192 + channel, program]])
  bpm = opts["bpm"] ?? 0
  ev_out.push([0, 0, score_midi_tempo(bpm, opts["beat"] ?? 4)]) if bpm > 0 && first_track
  at = 0
  volume = 90
  hairpin = nil
  sounding = {}
  for bar, bi in bars
    if bi == 0 || bar["changes"]["time"] == true
      tn = bar["time"][0]
      td = bar["time"][1]
      ev_out.push([at, 0, [255, 88, 4, tn, score_midi_log2(td), 24, 8]])
    end
    if bi == 0 || bar["changes"]["key"] == true
      ev_out.push([at, 0, [255, 89, 2, score_mod(bar["fifths"], 256), 0]])
    end
    for ev in bar["items"]
      t0 = at + ev["start"]
      span = ev["ticks"] * (ev["mm"] ?? 1)
      mark = ev["tempo"]
      ev_out.push([t0, 0, score_midi_tempo(mark["bpm"], mark["base"])]) if !mark.nil? && mark["bpm"] > 0 && first_track
      unless ev["dyn"].nil?
        volume = SCORE_MIDI_VOLUMES[ev["dyn"]] ?? volume
        hairpin = nil
      end
      if !hairpin.nil? && hairpin["left"] > 0
        volume = score_max(8, score_min(127, volume + hairpin["step"]))
        hairpin["left"] = hairpin["left"] - 1
      end
      hairpin = score_midi_hairpin(bars, bi, ev, volume) unless ev["hairpin"].nil?
      hairpin = nil if ev["hairpin_end"] == true
      next if ev["k"] != "note"

      names = (ev["scripts"] ?? []).map { |sc| sc["name"] }
      vel = volume + (names.includes?("accent") ? 20 : 0) + (names.includes?("marcato") ? 30 : 0)
      vel = int(score_max(1.0, score_min(127.0, vel + 0.5)))
      length = span
      length = span / 2 if names.includes?("staccato")
      length = span / 8 if names.includes?("staccatissimo")
      length = span * 3 / 4 if names.includes?("portato")
      for hd in ev["heads"]
        key = score_midi_key(hd["d"], hd["alter"])
        held = sounding[str(key)]
        # A tie carries the sounding note on: no new attack, a later end.
        if !held.nil? && held["until"] == t0 && held["tied"]
          held["until"] = t0 + length
          held["tied"] = ev["tie"] == true
          held["off"][0] = t0 + length
          next
        end
        off = [t0 + length, 0, [128 + channel, key, 64]]
        ev_out.push([t0, 1, [144 + channel, key, vel]])
        ev_out.push(off)
        sounding[str(key)] = {"until": t0 + length, "tied": ev["tie"] == true, "off": off}
      end
    end
    at += bar["length"] * (bar["span"] ?? 1)
  end
  # A fermata holds: every time from where a held note ends on is later by
  # what it was held for, on every staff alike.
  holds = opts["holds"] ?? []
  if holds.length > 0
    ev_out = ev_out.map { |e| [score_midi_held(holds, e[0]), e[1], e[2]] }
  end
  # In time order; at one time, a note's end before the next one's start.
  ev_out = ev_out.sort_by { |e| e[0] * 4 + e[1] }
  track = []
  last = 0
  for e in ev_out
    track = track + score_midi_vlq(e[0] - last) + e[2]
    last = e[0]
  end
  track + [0, 255, 47, 0]
end

# Where the fermatas hold, as [tick the held note ends, ticks it is held
# for], over every staff: a note under one lasts twice its length, as
# LilyPond's `articulate.ly` plays it. Two staves holding at the same end
# hold once, for the longer.
def score_midi_holds(measured)
  by_end = {}
  for bars in measured
    at = 0
    for bar in bars
      for ev in bar["items"]
        names = (ev["scripts"] ?? []).map { |sc| sc["name"] }
        if ev["k"] == "note" && names.includes?("fermata")
          span = ev["ticks"] * (ev["mm"] ?? 1)
          ends = str(at + ev["start"] + span)
          by_end[ends] = score_max(by_end[ends] ?? 0, span)
        end
      end
      at += bar["length"] * (bar["span"] ?? 1)
    end
  end
  by_end.keys.map { |k| [int(k), by_end[k]] }.sort_by { |h| h[0] }
end

# A time moved past every hold that ends at it or before.
def score_midi_held(holds, t)
  out = t
  for h in holds
    out += h[1] if h[0] <= t
  end
  out
end

# General MIDI's instruments by LilyPond's names for them (`midiInstrument`),
# from its `instrument-names-alist`.
const SCORE_MIDI_PROGRAMS = {"acoustic grand": 0, "bright acoustic": 1, "electric grand": 2, "honky-tonk": 3, "electric piano 1": 4, "electric piano 2": 5, "harpsichord": 6, "clav": 7, "celesta": 8, "glockenspiel": 9, "music box": 10, "vibraphone": 11, "marimba": 12, "xylophone": 13, "tubular bells": 14, "dulcimer": 15, "drawbar organ": 16, "percussive organ": 17, "rock organ": 18, "church organ": 19, "reed organ": 20, "accordion": 21, "harmonica": 22, "concertina": 23, "acoustic guitar (nylon)": 24, "acoustic guitar (steel)": 25, "electric guitar (jazz)": 26, "electric guitar (clean)": 27, "electric guitar (muted)": 28, "overdriven guitar": 29, "distorted guitar": 30, "guitar harmonics": 31, "acoustic bass": 32, "electric bass (finger)": 33, "electric bass (pick)": 34, "fretless bass": 35, "slap bass 1": 36, "slap bass 2": 37, "synth bass 1": 38, "synth bass 2": 39, "violin": 40, "viola": 41, "cello": 42, "contrabass": 43, "tremolo strings": 44, "pizzicato strings": 45, "orchestral harp": 46, "timpani": 47, "string ensemble 1": 48, "string ensemble 2": 49, "synthstrings 1": 50, "synthstrings 2": 51, "choir aahs": 52, "voice oohs": 53, "synth voice": 54, "orchestra hit": 55, "trumpet": 56, "trombone": 57, "tuba": 58, "muted trumpet": 59, "french horn": 60, "brass section": 61, "synthbrass 1": 62, "synthbrass 2": 63, "soprano sax": 64, "alto sax": 65, "tenor sax": 66, "baritone sax": 67, "oboe": 68, "english horn": 69, "bassoon": 70, "clarinet": 71, "piccolo": 72, "flute": 73, "recorder": 74, "pan flute": 75, "blown bottle": 76, "shakuhachi": 77, "whistle": 78, "ocarina": 79, "lead 1 (square)": 80, "lead 2 (sawtooth)": 81, "lead 3 (calliope)": 82, "lead 4 (chiff)": 83, "lead 5 (charang)": 84, "lead 6 (voice)": 85, "lead 7 (fifths)": 86, "lead 8 (bass+lead)": 87, "pad 1 (new age)": 88, "pad 2 (warm)": 89, "pad 3 (polysynth)": 90, "pad 4 (choir)": 91, "pad 5 (bowed)": 92, "pad 6 (metallic)": 93, "pad 7 (halo)": 94, "pad 8 (sweep)": 95, "fx 1 (rain)": 96, "fx 2 (soundtrack)": 97, "fx 3 (crystal)": 98, "fx 4 (atmosphere)": 99, "fx 5 (brightness)": 100, "fx 6 (goblins)": 101, "fx 7 (echoes)": 102, "fx 8 (sci-fi)": 103, "sitar": 104, "banjo": 105, "shamisen": 106, "koto": 107, "kalimba": 108, "bagpipe": 109, "fiddle": 110, "shanai": 111, "tinkle bell": 112, "agogo": 113, "steel drums": 114, "woodblock": 115, "taiko drum": 116, "melodic tom": 117, "synth drum": 118, "reverse cymbal": 119, "guitar fret noise": 120, "breath noise": 121, "seashore": 122, "bird tweet": 123, "telephone ring": 124, "helicopter": 125, "applause": 126, "gunshot": 127}

# LilyPond's `dynamic-absolute-volume`, out of 127.
const SCORE_MIDI_VOLUMES = {"pppp": 25, "ppp": 32, "pp": 51, "p": 64, "mp": 76, "mf": 89, "f": 102, "ff": 114, "fff": 121, "ffff": 127, "fp": 102, "sf": 114, "sff": 121, "sp": 76, "spp": 64, "sfz": 114, "sfp": 114, "rfz": 114, "rf": 114, "fz": 114, "n": 16}

# A hairpin moves the loudness a step a note toward the dynamic it ends on,
# or, ending on nothing, a level (16) up or down.
def score_midi_hairpin(bars, bi, start_ev, volume)
  notes = 0
  target = nil
  started = false
  done = false
  for k in range(bi, bars.length)
    for ev in bars[k]["items"]
      next if done

      if !started
        started = ev["i"] == start_ev["i"]
        next
      end
      notes += 1
      target = SCORE_MIDI_VOLUMES[ev["dyn"]] unless ev["dyn"].nil?
      done = !ev["dyn"].nil? || ev["hairpin_end"] == true || !ev["hairpin"].nil?
    end
    break if done
  end
  target = volume + (start_ev["hairpin"] == "<" ? 16 : -16) if target.nil?
  {"left": score_max(notes, 1), "step": (target - volume) / float(score_max(notes, 1))}
end

def score_midi_key(d, alter)
  step = score_mod(d, 7)
  12 * ((d - step) / 7 + 4) + [0, 2, 4, 5, 7, 9, 11][step] + alter
end

def score_midi_tempo(bpm, beat)
  us = int(60000000.0 / bpm * beat / 4.0)
  [255, 81, 3] + score_midi_be(us, 3)
end

def score_midi_log2(v)
  out = 0
  while v > 1
    v = v / 2
    out += 1
  end
  out
end

# A number as MIDI writes a time: seven bits a byte, the high bit set on
# all but the last.
def score_midi_vlq(v)
  out = [v % 128]
  v = v / 128
  while v > 0
    out = [v % 128 + 128] + out
    v = v / 128
  end
  out
end

def score_midi_be(v, size)
  range(0, size).map { |k| (v / [1, 256, 65536, 16777216][size - 1 - k]) % 256 }
end

# Text as bytes, in UTF-8 as MIDI players expect.
def score_midi_text(words)
  words.bytes()
end

# ---- PDF -------------------------------------------------------------------
#
# The A4 pages as a PDF: the same paths the screen draws, as vector paths —
# a staff space is five points on LilyPond's 20-point staff, so the page is
# drawn at five units a space and needs no scaling. Every letter is an
# outline already, so no font is embedded; a quadratic piece becomes the
# cubic PDF draws. The file is ASCII from end to end, so it travels as a
# string: `{"state": state, "save": score_pdf(src)}` answers a save.
def score_pdf(src, opts = {})
  return eui_score_pdf(src, opts["title"] ?? "") if defined("eui_score_pdf")

  paper = score_a4()
  line_w = paper["w"] - paper["left"] - paper["right"]
  engraved = score_engrave_page(src, line_w, {"page_h": paper["h"], "top": paper["top"], "bottom": paper["bottom"], "left": paper["left"], "indent": paper["indent"], "gap": 12.0})
  sp = 5.0
  page_w = paper["w"] * sp
  page_h = paper["h"] * sp
  bodies = []
  bodies.push("<< /Type /Catalog /Pages 2 0 R >>")
  count = engraved["pages"].length
  kids = range(0, count).map { |k| str(4 + 2 * k) + " 0 R" }.join(" ")
  bodies.push("<< /Type /Pages /Kids [" + kids + "] /Count " + str(count) + " >>")
  title = (score_parse(src)["header"] ?? {})["title"] ?? (opts["title"] ?? "")
  bodies.push("<< /Title " + score_pdf_text(title) + " /Producer (EUI score) >>")
  for pg in engraved["pages"]
    k = pg["index"]
    data = score_pdf_page(score_paths(engraved, sp, {"page_index": k}), page_h)
    bodies.push("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 " + score_pdf_num(page_w) + " " + score_pdf_num(page_h) + "] /Contents " + str(5 + 2 * k) + " 0 R /Resources << >> >>")
    bodies.push("<< /Length " + str(data.length) + " >>\nstream\n" + data + "\nendstream")
  end
  out = ["%PDF-1.4\n"]
  at = out[0].length
  offsets = []
  for body, k in bodies
    obj = str(k + 1) + " 0 obj\n" + body + "\nendobj\n"
    offsets.push(at)
    out.push(obj)
    at += obj.length
  end
  xref = ["xref\n0 " + str(bodies.length + 1) + "\n0000000000 65535 f \n"] + offsets.map { |off| str(off).rjust(10, "0") + " 00000 n \n" }
  out = out + xref
  out.push("trailer\n<< /Size " + str(bodies.length + 1) + " /Root 1 0 R /Info 3 0 R >>\nstartxref\n" + str(at) + "\n%%EOF\n")
  out.join("")
end

# A page's content stream: every path filled in black by the non-zero
# rule, y turned up as PDF has it.
def score_pdf_page(paths, page_h)
  ops = ["0 g"]
  for pa in paths
    if pa[0] == 1
      ops.push(score_pdf_num(pa[2]) + " " + score_pdf_num(page_h - pa[3] - pa[5]) + " " + score_pdf_num(pa[4]) + " " + score_pdf_num(pa[5]) + " re f")
      next
    end
    next unless pa[0] == 5

    cx = 0.0
    cy = 0.0
    sx = 0.0
    sy = 0.0
    k = 2
    while k < pa.length
      c = pa[k]
      if c == 0 || c == 1
        cx = pa[k + 1]
        cy = pa[k + 2]
        if c == 0
          sx = cx
          sy = cy
        end
        ops.push(score_pdf_num(cx) + " " + score_pdf_num(page_h - cy) + (c == 0 ? " m" : " l"))
        k += 3
      elsif c == 2
        qx = pa[k + 1]
        qy = pa[k + 2]
        ex = pa[k + 3]
        ey = pa[k + 4]
        pts = [cx + (qx - cx) * 2.0 / 3.0, cy + (qy - cy) * 2.0 / 3.0, ex + (qx - ex) * 2.0 / 3.0, ey + (qy - ey) * 2.0 / 3.0, ex, ey]
        ops.push(range(0, 3).map { |j| score_pdf_num(pts[2 * j]) + " " + score_pdf_num(page_h - pts[2 * j + 1]) }.join(" ") + " c")
        cx = ex
        cy = ey
        k += 5
      elsif c == 3
        ops.push(range(0, 3).map { |j| score_pdf_num(pa[k + 1 + 2 * j]) + " " + score_pdf_num(page_h - pa[k + 2 + 2 * j]) }.join(" ") + " c")
        cx = pa[k + 5]
        cy = pa[k + 6]
        k += 7
      else
        ops.push("h")
        cx = sx
        cy = sy
        k += 1
      end
    end
    ops.push("f")
  end
  ops.join("\n")
end

# A number as PDF writes one: two decimals at most.
def score_pdf_num(v)
  r = Math.floor(v * 100.0 + 0.5) / 100.0
  r == Math.floor(r) ? str(int(r)) : str(r)
end

# Text for the document's information: UTF-16, as a hex string, so a title
# with accents is the title.
def score_pdf_text(words)
  b = words.bytes()
  units = []
  k = 0
  while k < b.length
    c = b[k]
    cp = c
    n = 1
    if c >= 240
      cp = (c % 8) * 262144 + (b[k + 1] % 64) * 4096 + (b[k + 2] % 64) * 64 + b[k + 3] % 64
      n = 4
    elsif c >= 224
      cp = (c % 16) * 4096 + (b[k + 1] % 64) * 64 + b[k + 2] % 64
      n = 3
    elsif c >= 192
      cp = (c % 32) * 64 + b[k + 1] % 64
      n = 2
    end
    if cp >= 65536
      cp -= 65536
      units.push(55296 + cp / 1024)
      units.push(56320 + cp % 1024)
    else
      units.push(cp)
    end
    k += n
  end
  "<FEFF" + units.map { |u| score_pdf_hex4(u) }.join("") + ">"
end

def score_pdf_hex4(u)
  digits = "0123456789ABCDEF"
  range(0, 4).map { |j| digits.chars()[(u / [4096, 256, 16, 1][j]) % 16] }.join("")
end

# ---- A canvas for each system ----------------------------------------------
#
# A page is cut into bands, one canvas each: the titles (or the page
# number), then each system. A band is drawn in its own frame — its staff's
# top line a whole number of pixels down — so its paths depend on nothing
# but its own system, and are kept under a signature of everything the
# drawing reads. Editing a note redraws, and sends, only the band it is in;
# the others' paths are the same values, and the tree's diff sends nothing
# for them.

# The bands of page `page`: [{"y": px from the page's top, "h": px,
# "paths": [...], "lit": [...]}], their heights adding up to `total` px.
# `paths` is the band in the plain ink, whatever is lit; `lit` is a copy
# of the paths of the items `opts["marks"]` lights, in their colours, drawn
# over it (`score_band_column`). The playhead and the selection change
# `lit` alone: a system of a full score is a quarter of a megabyte of
# paths, and recolouring a note inside it sent all of it again, every
# tenth of a second, while the music played.
def score_bands(engraved, sp, opts, total)
  return eui_score_bands(engraved, sp, opts, total) if engraved["native"] == true

  ink = opts["colour"] ?? "text.default"
  marks = opts["marks"] ?? {}
  page = opts["page_index"] ?? 0
  systems = engraved["systems"].filter { |sys| (sys["page"] ?? 0) == page }
  bands = []
  starts = []
  for sys in systems
    pad = int(Math.ceil(-sys["reach_hi"] * sp)) + 2
    starts.push([sys, pad, int(Math.floor(sys["top"] * sp + 0.5)) - pad])
  end
  first_y = starts.length > 0 ? score_max(starts[0][2], 0) : total
  head_key = str(sp) + "|" + ink + "|" + str(page) + "|" + str(engraved["left"]) + "|" + str(engraved["width"]) + "|" + str(engraved["paper"]) + "|" + str(engraved["numbered"]) + "|" + score_sig_value(engraved["header"])
  head = score_memo_get("heads", head_key)
  head = score_memo_put("heads", head_key, {"paths": score_paths_head(engraved, sp, ink, page), "ranges": {}}, 16) if head.nil?
  bands.push({"y": 0, "h": first_y, "drawn": head, "items": []})
  for st, k in starts
    y = k == 0 ? first_y : score_max(st[2], bands[-1]["y"])
    bands[-1]["h"] = y - bands[-1]["y"]
    bands.push({"y": y, "h": 0, "drawn": score_band_drawn(st[0], st[1], sp, ink), "items": score_band_items(st[0])})
  end
  bands[-1]["h"] = score_max(total - bands[-1]["y"], 0)
  bands.map { |bd| {"y": bd["y"], "h": bd["h"], "paths": bd["drawn"]["paths"], "lit": score_band_lit(bd, marks)} }
end

# The items of a system in drawing order, by their numbers.
def score_band_items(sys)
  return sys["staves"].map { |ss| score_band_items(ss) }.reduce(fn(acc, items) acc + items, []) if sys.has_key("staves")

  out = []
  for bar in sys["bars"]
    for ev in bar["items"]
      out.push(str(ev["i"]))
    end
  end
  out
end

# The paths of a band's lit items, copied in their colours.
def score_band_lit(bd, marks)
  drawn = bd["drawn"]
  out = []
  for item, k in bd["items"]
    next unless marks.has_key(item)

    span = drawn["ranges"][str(k)]
    next if span.nil?

    for j in range(span[0], span[1])
      lit = drawn["paths"][j].map { |v| v }
      lit[1] = marks[item]
      out.push(lit)
    end
  end
  out
end

# One system drawn with its staff's top line `pad` px down, from the cache
# when a system that draws the same was drawn before.
def score_band_drawn(sys, pad, sp, ink)
  key = str(sp) + "|" + ink + "|" + str(pad) + "|" + score_sys_sig(sys)
  hit = score_memo_get("bands", key)
  return hit unless hit.nil?

  paths = []
  by_item = {}
  score_draw_system(paths, sys.merge({"top": pad / float(sp)}), sp, ink, by_item)
  # The ranges by an item's place in the system, not its number: the same
  # system later in a longer piece has the same places and other numbers.
  ranges = {}
  for item, k in score_band_items(sys)
    ranges[str(k)] = by_item[item]
  end
  score_memo_put("bands", key, {"paths": paths, "ranges": ranges}, 96)
end

# Everything drawing a system reads, as one string. Where a note is in the
# piece (its number, its character in the source, its bar's number in the
# list) is left out: the same bar written later draws the same; so is what
# the drawing never reads (a note's written pitches: its heads say where
# it is drawn). Keys are taken in the order they were made, not sorted:
# the same engraving makes them in the same order, and a different order
# costs a redraw, never a wrong one.
def score_sys_sig(sys)
  if sys.has_key("staves")
    parts = sys["staves"].map { |ss| score_sys_sig(ss) }
    return parts.join("\n#") + "|" + score_sig_value({"offsets": sys["offsets"], "groups": sys["groups"], "names": sys["names"], "left": sys["left"], "first": sys["first_line"]})
  end
  bits = []
  for key in sys.keys
    next if ["bars", "top", "bottom", "reach_hi", "page", "staves"].includes?(key)

    bits.push(key + "=" + score_sig_value(sys[key]))
  end
  for bar in sys["bars"]
    bar_bits = []
    for key in bar.keys
      next if key == "items"

      bar_bits.push(key + "=" + score_sig_value(bar[key]))
    end
    bits.push("|" + bar_bits.join(";"))
    for ev in bar["items"]
      bits.push("." + score_sig_item(ev))
    end
  end
  bits.join("")
end

def score_sig_item(ev)
  bits = []
  for key in ev.keys
    next if ["at", "i", "n", "bar", "tuplet", "beam", "pitches", "tempo"].includes?(key)

    bits.push(key + "=" + score_sig_value(ev[key]))
  end
  g = ev["beam"]
  unless g.nil?
    bits.push("beam=" + score_sig_value({"x0": g["x0"], "x1": g["x1"], "y0": g["y0"], "y1": g["y1"], "n": g["n"], "up": g["up"], "lead": g["notes"][0]["i"] == ev["i"]}))
  end
  bits.join(";")
end

# A plain value as text; a hash by its sorted keys. "notes" and "bars" are
# the two ways back into the piece (a beam's notes, a bracket's bars) and
# are left out.
def score_sig_value(v)
  return "-" if v.nil?
  if v.is_a?("hash")
    return "{" + v.keys.filter { |key| key != "notes" && key != "bars" && key != "staff_bars" && key != "members" }.map { |key| key + ":" + score_sig_value(v[key]) }.join(",") + "}"
  end
  return "[" + v.map { |x| score_sig_value(x) }.join(",") + "]" if v.is_a?("array")

  str(v)
end

# The paths with the marked items' own in their colours. The list is a copy
# only when something is marked; the paths that are not lit are shared.
def score_recolour(drawn, marks)
  return drawn["paths"] if marks.keys.length == 0

  out = drawn["paths"].map { |pa| pa }
  for item in marks.keys
    span = drawn["ranges"][item]
    next if span.nil?

    for k in range(span[0], span[1])
      lit = out[k].map { |v| v }
      lit[1] = marks[item]
      out[k] = lit
    end
  end
  out
end

def score_paths_plain(engraved, sp, ink, page, ranges)
  paths = score_paths_head(engraved, sp, ink, page)
  for sys in engraved["systems"]
    score_draw_system(paths, sys, sp, ink, ranges) if (sys["page"] ?? 0) == page
  end
  paths
end

# Whether pages are numbered: on paper, which has margins, as LilyPond
# numbers them. A screen cut into pages (`page_h` and nothing else) has a
# pager that says which page it is, and a page number set in the text face
# at a screen's size loses the 4's hairline diagonal.
def score_numbered(layout)
  !layout["page_h"].nil? && !layout["top"].nil?
end

# A page's titles if it is the first, its number if it is numbered.
def score_paths_head(engraved, sp, ink, page)
  paths = []
  left = engraved["left"] ?? 0.0
  if page == 0
    margin = engraved["pages"].length > 0 && !engraved["paper"].nil? ? 2.83 : 1.0
    for line in engraved["header"]["lines"]
      for cell in line["cells"]
        score_draw_text(paths, ink, cell["text"], cell["weight"], left + cell["x"], margin + line["y"], cell["em"], sp)
      end
    end
  end
  if page > 0 && engraved["numbered"] == true
    # LilyPond's page numbers: from the second page, at the top, on the
    # outside edge — right on odd pages, left on even ones.
    number = str(page + 1)
    em = score_em(0.0)
    nx = (page + 1) % 2 == 1 ? left + engraved["width"] - score_text_width(number, "regular", em) : left
    score_draw_text(paths, ink, number, "regular", nx, 2.83 + 0.72 * em, em, sp)
  end
  paths
end

# A page as a column of bands, `total` px tall in all: each its canvas in
# the plain ink and, laid over it, a canvas of what is lit — so lighting a
# note changes the second, a few paths, and never the first.
def score_band_column(engraved, sp, opts, width, total)
  bands = score_bands(engraved, sp, opts, total)
  # A plain box, not `column()`: the bands stack with no gap and nothing else.
  {"k": "box", "s": {"display": "column", "width": width}, "c": bands.filter { |bd| bd["h"] > 0 }.map { |bd|
    {"k": "box", "s": {"display": "stack", "width": width, "height": bd["h"]}, "c": [canvas(width, bd["h"], bd["paths"]), canvas(width, bd["h"], bd["lit"] ?? [])]}
  }}
end

# A tempo mark: bold words, then the beat in brackets — a small note, an
# equals sign and the number — as LilyPond's `\tempo` prints them.
def score_draw_tempo(paths, ink, mk, top, sp)
  mark = mk["mark"]
  em = score_em(0.0)
  y = top + mk["y"]
  x = mk["x"]
  if mark["text"] != ""
    x = score_draw_text(paths, ink, mark["text"], "bold", x, y, em, sp)
    x += 0.6 if mark["bpm"] > 0
  end
  return nil if mark["bpm"] == 0

  x = score_draw_text(paths, ink, "(", "regular", x, y, em, sp) + 0.25
  k = 0.72
  head_name = score_head_name(mark["base"])
  head = score_glyph(head_name)
  hy = y - 0.35
  paths.push(score_fill_k(ink, head["fill"], x, hy, k, sp))
  if mark["base"] > 1
    sx = x + (head["advance"] - SCORE_RULE["stem"]) * k
    tip = hy - 3.0 * k
    paths.push(score_rect(ink, sx, tip, SCORE_RULE["stem"] * k, hy - 0.12 - tip, sp))
    if mark["base"] >= 8
      flag = score_glyph(score_flag_name(mark["base"], true))
      paths.push(score_fill_k(ink, flag["fill"], sx - flag["anchors"]["stemUpNW"][0] * k, tip, k, sp))
    end
  end
  x += head["advance"] * k + 0.7
  x += score_glyph(score_flag_name(mark["base"], true))["advance"] * k * 0.8 if mark["base"] >= 8
  score_draw_text(paths, ink, "= " + str(mark["bpm"]) + ")", "regular", x, y, em, sp)
end

def score_draw_system(paths, sys, sp, ink, ranges)
  if sys.has_key("staves")
    for ss, s in sys["staves"]
      score_draw_system(paths, ss.merge({"top": sys["top"] + sys["offsets"][s]}), sp, ink, ranges)
    end
    score_draw_groups(paths, sys, sp, ink)
    return nil
  end
  top = sys["top"]
  right = sys["right"]
  left = sys["left"] ?? 0.0
  for i in 0..5
    paths.push(score_rect(ink, left, top + i - SCORE_RULE["staff"] / 2.0, right - left, SCORE_RULE["staff"], sp))
  end
  bars = sys["bars"]
  first = bars[0]
  # LilyPond numbers the bar each system after the first opens with, small,
  # over the clef, its right edge a fifth of a space short of the staff.
  # Over the top staff only; where a brace or a bracket stands left of the
  # staves, over the clef instead, as LilyPond moves it.
  if first["number"] > 1 && (sys["staff_index"] ?? 0) == 0
    em = score_em(-2.0)
    number = str(first["number"])
    number_x = sys.has_key("staff_index") ? left : left - score_text_width(number, "regular", em) - 0.2
    score_draw_text(paths, ink, number, "regular", number_x, top - 1.6, em, sp)
  end
  # The opening: clef, key, time.
  x = left + 0.8
  clef = score_clef_glyph(first["clef"])
  score_draw_glyph(paths, ink, clef, x, top + score_clef_y(first["clef"]), sp)
  x += (sys["clef_w"] ?? score_glyph(clef)["advance"]) + 1.0
  if sys.has_key("key_w")
    score_draw_key(paths, ink, first["fifths"], first["clef"], x, top, sp, false) if first["fifths"] != 0
    x += sys["key_w"] + 0.8 if sys["key_w"] > 0.0
  elsif first["fifths"] != 0
    x = score_draw_key(paths, ink, first["fifths"], first["clef"], x, top, sp, false) + 0.8
  end
  if first["first"] == true || first["changes"]["time"] == true
    score_draw_time(paths, ink, first["time"], x, top, sp)
  end
  for bar, bi in bars
    if bi > 0
      score_draw_changes(paths, ink, bar, top, sp)
    end
    for ev in bar["items"]
      from_k = paths.length
      if ev["k"] == "rest"
        score_draw_rest(paths, ink, ev, top, sp)
      else
        score_draw_note(paths, ink, ev, top, sp)
      end
      ranges[str(ev["i"])] = [from_k, paths.length]
    end
    for ev in bar["items"]
      g = ev["beam"]
      score_draw_beam(paths, ink, g, top, sp) if !g.nil? && g["notes"][0]["n"] == ev["n"]
    end
    # A bar's line fills the room left for it after its last note, so it
    # ends exactly where the bar does — and on the last bar of a line,
    # where the staff does.
    drawn_kind = bar["bar_drawn"] ?? bar["bar"]
    score_draw_bar(paths, ink, drawn_kind, bar["x1"] + score_barline_width(drawn_kind), top, sp, sys["connect_down"] ?? 0.0)
    score_draw_bar(paths, ink, ".|:", bar["open_repeat_x"], top, sp) if bi == 0 && !bar["open_repeat_x"].nil?
  end
  for c in sys["curves"]
    paths.push(score_fill(ink, c, 0.0, top, sp))
  end
  for mk in sys["marks"] ?? []
    score_draw_tempo(paths, ink, mk, top, sp)
  end
  for vb in sys["voltas"] ?? []
    score_draw_volta(paths, ink, vb, top, sp)
  end
  for tp in sys["tuplets"] ?? []
    score_draw_tuplet(paths, ink, tp, top, sp)
  end
  for sc in sys["scripts"] ?? []
    score_draw_glyph(paths, ink, sc["glyph"], sc["x"], top + sc["y"], sp)
  end
  for dy in sys["dynamics"] ?? []
    score_draw_dynamic(paths, ink, dy, top, sp)
  end
  for tx in sys["texts"] ?? []
    score_draw_text(paths, ink, tx["text"], "regular", tx["x0"], top + tx["y"], score_em(0.0), sp)
  end
  score_draw_courtesy(paths, ink, sys, top, sp) if (sys["courtesy"] ?? 0.0) > 0.0
end

# A tuplet's number, in the italic LilyPond prints it in at `font-size` -2,
# centred on its line; and its bracket, 0.16 spaces thick (`thickness` 1.6
# lines), broken round the number, its hooks turned toward the notes.
def score_draw_tuplet(paths, ink, tp, top, sp)
  em = score_em(-2.0)
  w = score_text_width(tp["label"], "italic", em)
  h = score_digit_height(em)
  xm = (tp["x0"] + tp["x1"]) / 2.0
  span = score_max(tp["x1"] - tp["x0"], 0.01)
  slope = (tp["yb"] - tp["ya"]) / span
  ym = tp["ya"] + slope * (xm - tp["x0"])
  score_draw_text(paths, ink, tp["label"], "italic", xm - w / 2.0, top + ym + h / 2.0, em, sp)
  return nil unless tp["bracket"]

  half = 0.08
  gap = w / 2.0 + 0.35
  for seg in [ [tp["x0"], xm - gap], [xm + gap, tp["x1"]] ]
    ya = tp["ya"] + slope * (seg[0] - tp["x0"])
    yb = tp["ya"] + slope * (seg[1] - tp["x0"])
    paths.push(score_fill(ink, [0, seg[0], ya - half, 1, seg[1], yb - half, 1, seg[1], yb + half, 1, seg[0], ya + half, 4], 0.0, top, sp))
  end
  hook = 0.7
  for end_at in [ [tp["x0"], tp["ya"]], [tp["x1"] - 2.0 * half, tp["yb"]] ]
    y0 = tp["up"] ? end_at[1] - half : end_at[1] - hook
    paths.push(score_rect(ink, end_at[0], top + y0, 2.0 * half, hook + half, sp))
  end
end

# A dynamic's letters on their baseline, or a hairpin's two lines, a tenth
# of a space thick, from its tip to its open end.
def score_draw_dynamic(paths, ink, dy, top, sp)
  if dy["kind"] == "dyn"
    x = dy["x0"]
    for name in score_dyn_letters(dy["text"])
      score_draw_glyph(paths, ink, name, x, top + dy["y"] + 0.6, sp)
      x += score_glyph(name)["advance"]
    end
    return nil
  end
  h = 0.6666
  open_a = dy["grow"] == "<" ? dy["from"] : 1.0 - dy["from"]
  open_b = dy["grow"] == "<" ? dy["to"] : 1.0 - dy["to"]
  half = 0.05
  for side in [-1.0, 1.0]
    ya = dy["y"] + side * h * open_a
    yb = dy["y"] + side * h * open_b
    paths.push(score_fill(ink, [0, dy["x0"], ya - half, 1, dy["x1"], yb - half, 1, dy["x1"], yb + half, 1, dy["x0"], ya + half, 4], 0.0, top, sp))
  end
end

# The height of the italic digits at `em`, from their outlines.
def score_digit_height(em)
  rise = 0
  for ch in "0123456789".chars()
    cmds = score_letters()["italic"][ch]["f"]
    ci = 0
    while ci < cmds.length
      args = [2, 2, 4, 6, 0][cmds[ci]]
      jj = 1
      while jj < args
        rise = score_min(rise, cmds[ci + 1 + jj])
        jj += 2
      end
      ci += 1 + args
    end
  end
  -rise * em / 1000.0
end

# What stands left of a line of several staves: the line that joins them,
# each group's brace (LilyPond's own, the nearest of its sizes, stretched
# the rest of the way) or bracket (a thick line with its curled ends),
# inner groups nearest the staves; and the staves' names, right-aligned
# against them, a group's centred on the group.
def score_draw_groups(paths, sys, sp, ink)
  top = sys["top"]
  offsets = sys["offsets"]
  left = sys["left"]
  last = offsets.length - 1
  if offsets.length > 1
    paths.push(score_rect(ink, left - 0.08, top - 0.05, 0.16, offsets[last] + 4.1, sp))
  end
  edge = left - 0.3
  deepest = 0
  for g in sys["groups"]
    deepest = score_max(deepest, g["depth"])
  end
  for g in sys["groups"]
    next if g["kind"] == "none"

    y0 = top + offsets[g["first"]]
    y1 = top + offsets[g["last"]] + 4.0
    x = left - 0.3 - (deepest - g["depth"]) * 1.6
    if g["kind"] == "brace"
      score_draw_brace(paths, ink, x, y0, y1, sp)
      edge = score_min(edge, x - 1.3)
    else
      bx = x - 0.5
      paths.push(score_rect(ink, bx, y0, 0.45, y1 - y0, sp))
      score_draw_glyph(paths, ink, "bracketTop", bx, y0, sp)
      score_draw_glyph(paths, ink, "bracketBottom", bx, y1, sp)
      edge = score_min(edge, bx - 0.3)
    end
  end
  em = score_em(0.0)
  for name, s in sys["names"]
    next if name == ""

    in_group = sys["groups"].any? { |g| g["first"] <= s && s <= g["last"] && g["kind"] != "none" && g["first"] < g["last"] && (sys["first_line"] ? g["name"] : g["short"]) != "" }
    next if in_group

    score_draw_name(paths, ink, name, edge, top + offsets[s] + 2.0, em, sp)
  end
  for g in sys["groups"]
    label = sys["first_line"] ? g["name"] : g["short"]
    next if label == ""

    score_draw_name(paths, ink, label, edge, top + (offsets[g["first"]] + offsets[g["last"]] + 4.0) / 2.0, em, sp)
  end
end

def score_draw_name(paths, ink, name, right, middle, em, sp)
  box = score_text_box(name, "regular", em)
  score_draw_text(paths, ink, name, "regular", right - 0.6 - score_text_width(name, "regular", em), middle - (box[0] + box[1]) / 2.0, em, sp)
end

# A brace from `y0` to `y1`, its right edge at `x`: LilyPond's nearest
# size, stretched or squeezed vertically the rest of the way.
def score_draw_brace(paths, ink, x, y0, y1, sp)
  want = y1 - y0
  best = nil
  for n in range(10, 46)
    g = score_glyph("brace" + str(n * 10))
    next if g.nil?

    h = g["bbox"][3] - g["bbox"][1]
    best = g if best.nil? || (h - want).abs < (best["bbox"][3] - best["bbox"][1] - want).abs
  end
  return nil if best.nil?

  scale = want / (best["bbox"][3] - best["bbox"][1])
  mid = (y0 + y1) / 2.0
  cmds = best["fill"]
  out = []
  ci = 0
  while ci < cmds.length
    c = cmds[ci]
    out.push(c)
    args = [2, 2, 4, 6, 0][c]
    for jj in 0..args
      v = cmds[ci + 1 + jj]
      out.push(jj % 2 == 0 ? v - best["bbox"][2] : v * scale)
    end
    ci += 1 + args
  end
  paths.push(score_fill(ink, out, x, mid, sp))
end

def score_draw_volta(paths, ink, vb, top, sp)
  line = 0.16
  y = top + vb["y"]
  x0 = vb["x0"] + 0.3
  x1 = vb["x1"] - 0.3
  paths.push(score_rect(ink, x0, y - line / 2.0, x1 - x0, line, sp))
  if vb["first"]
    paths.push(score_rect(ink, x0, y - line / 2.0, line, 1.8, sp))
    score_draw_text(paths, ink, vb["label"], "bold", x0 + 0.5, y + 1.5, score_em(-2.0), sp)
  end
  paths.push(score_rect(ink, x1 - line, y - line / 2.0, line, 1.8, sp)) if vb["closed"]
end

def score_draw_courtesy(paths, ink, sys, top, sp)
  bar = sys["courtesy_bar"]
  ch = bar["changes"]
  x = sys["bar_end"] + 0.6
  if ch["key"] == true
    skip = score_key_cancel(ch["key_from"], bar["fifths"])
    x = score_draw_key_from(paths, ink, ch["key_from"], bar["clef"], x, top, sp, true, skip) + 0.5 if skip >= 0
    x = score_draw_key(paths, ink, bar["fifths"], bar["clef"], x, top, sp, false) + 0.5 if bar["fifths"] != 0
  end
  score_draw_time(paths, ink, bar["time"], x, top, sp) if ch["time"] == true
end

def score_clef_y(clef)
  {"treble": 3.0, "bass": 1.0, "alto": 2.0}[clef]
end

# The staff positions of a key's accidentals under the treble clef, in the
# order they are written; other clefs move them.
# Which of the old key's accidentals a change cancels with naturals, as
# LilyPond prints them: all of them when the new key has none or the other
# kind, the ones it drops when it has fewer of the same kind, none when it
# has more. Answers the first of them, or -1.
def score_key_cancel(old_key, new_key)
  return -1 if old_key == 0
  return 0 if new_key == 0 || (old_key > 0) != (new_key > 0)

  had = score_max(old_key, 0 - old_key)
  has = score_max(new_key, 0 - new_key)
  has < had ? has : -1
end

def score_draw_key(paths, ink, fifths, clef, x, top, sp, cancel)
  score_draw_key_from(paths, ink, fifths, clef, x, top, sp, cancel, 0)
end

def score_draw_key_from(paths, ink, fifths, clef, x, top, sp, cancel, skip)
  sharps = [4, 1, 5, 2, -1, 3, 0]
  flats = [0, 3, -1, 2, -2, 1, -3]
  shift = {"treble": 0, "bass": -2, "alto": -1}[clef]
  name = cancel ? "accidentalNatural" : (fifths > 0 ? "accidentalSharp" : "accidentalFlat")
  g = score_glyph(name)
  n = score_max(fifths, -fifths)
  for i in skip..n
    pos = (fifths > 0 ? sharps[i] : flats[i]) + shift
    score_draw_glyph(paths, ink, name, x, top + score_y(pos), sp)
    x += g["advance"] + 0.1
  end
  x
end

def score_draw_time(paths, ink, time, x, top, sp)
  one = score_time_glyphs(time)
  unless one.nil?
    score_draw_glyph(paths, ink, one[0], x, top + 2.0, sp)
    return nil
  end
  wide = score_time_width(time)
  for part, pi in [time[0], time[1]]
    names = score_digits(part)
    w = names.reduce(fn(acc, nm) acc + score_glyph(nm)["advance"], 0.0)
    cx = x + (wide - w) / 2.0
    for nm in names
      score_draw_glyph(paths, ink, nm, cx, top + (pi == 0 ? 1.0 : 3.0), sp)
      cx += score_glyph(nm)["advance"]
    end
  end
end

def score_draw_changes(paths, ink, bar, top, sp)
  ch = bar["changes"]
  x = bar["x0"] + 0.6
  if ch["clef"] == true
    clef = score_clef_glyph(bar["clef"])
    score_draw_glyph(paths, ink, clef, x, top + score_clef_y(bar["clef"]), sp)
    x += score_glyph(clef)["advance"] + 0.8
  end
  if ch["key"] == true
    skip = score_key_cancel(ch["key_from"], bar["fifths"])
    x = score_draw_key_from(paths, ink, ch["key_from"], bar["clef"], x, top, sp, true, skip) + 0.5 if skip >= 0
    x = score_draw_key(paths, ink, bar["fifths"], bar["clef"], x, top, sp, false) + 0.8 if bar["fifths"] != 0
  end
  score_draw_time(paths, ink, bar["time"], x, top, sp) if ch["time"] == true
end

# A bar line whose right edge is at `x`: its parts drawn left to right from
# where they begin, the thin and thick lines standing on the staff's outer
# lines, the repeat dots in the two middle spaces.
def score_draw_bar(paths, ink, kind, x, top, sp, down = 0.0)
  bar_top = top - SCORE_RULE["staff"] / 2.0
  # `down`: on to the next staff, where a group's bar lines run through.
  bar_h = 4.0 + SCORE_RULE["staff"] + down
  at = x - score_barline_width(kind)
  for part in score_barline_parts(kind)
    if part == "dots"
      dot = score_glyph("augmentationDot")
      score_draw_glyph(paths, ink, "augmentationDot", at, top + 1.5, sp)
      score_draw_glyph(paths, ink, "augmentationDot", at, top + 2.5, sp)
      at += dot["advance"]
    else
      w = SCORE_RULE[part]
      paths.push(score_rect(ink, at, bar_top, w, bar_h, sp))
      at += w
    end
    at += SCORE_RULE["kern"]
  end
end

# How wide a run of church rests is: longas and breves half a space each,
# a whole rest its own width, six tenths of a space between.
def score_church_width(count)
  left_bars = count
  w = 0.0
  parts = 0
  while left_bars > 0
    if left_bars >= 4
      w += 0.5
      left_bars -= 4
    elsif left_bars >= 2
      w += 0.5
      left_bars -= 2
    else
      w += score_glyph("restWhole")["advance"]
      left_bars -= 1
    end
    parts += 1
  end
  w + 0.6 * (parts - 1)
end

def score_draw_rest(paths, ink, ev, top, sp)
  if !ev["mm"].nil?
    # LilyPond's multi-measure rest. Up to ten bars, church rests: a longa
    # rest (two spaces tall, from the second line to the fourth) for each
    # four bars, a breve rest (one space, hung from the fourth line) for two,
    # a whole rest for one. Past ten, a thick bar on the middle line with a
    # serif at each end. The count over the staff, in the metre's digits.
    x0 = ev["span0"] + 1.0
    x1 = ev["span1"] - 1.0
    if ev["mm"] <= 10
      cx = (x0 + x1) / 2.0 - score_church_width(ev["mm"]) / 2.0
      left_bars = ev["mm"]
      while left_bars > 0
        if left_bars >= 4
          paths.push(score_rect(ink, cx, top + 1.0, 0.5, 2.0, sp))
          left_bars -= 4
          cx += 0.5 + 0.6
        elsif left_bars >= 2
          paths.push(score_rect(ink, cx, top + 1.0, 0.5, 1.0, sp))
          left_bars -= 2
          cx += 0.5 + 0.6
        else
          score_draw_glyph(paths, ink, "restWhole", cx, top + 1.0, sp)
          left_bars -= 1
          cx += score_glyph("restWhole")["advance"] + 0.6
        end
      end
    else
      paths.push(score_rect(ink, x0, top + 1.75, x1 - x0, 0.5, sp))
      paths.push(score_rect(ink, x0, top + 1.0, 0.18, 2.0, sp))
      paths.push(score_rect(ink, x1 - 0.18, top + 1.0, 0.18, 2.0, sp))
    end
    names = score_digits(ev["mm"])
    wide = names.reduce(fn(acc, nm) acc + score_glyph(nm)["advance"], 0.0)
    nx = (x0 + x1) / 2.0 - wide / 2.0
    for nm in names
      score_draw_glyph(paths, ink, nm, nx, top - 1.3, sp)
      nx += score_glyph(nm)["advance"]
    end
    return nil
  end
  if ev["whole_bar"] == true
    score_draw_glyph(paths, ink, "restWhole", ev["x"], top + 1.0, sp)
    return nil
  end
  name = score_rest_name(ev["base"])
  y = ev["base"] == 1 ? 1.0 : 2.0
  score_draw_glyph(paths, ink, name, ev["x"], top + y, sp)
  if ev["dots"] > 0
    dx = ev["x"] + score_glyph(name)["advance"] + 0.3
    for _ in 0..ev["dots"]
      score_draw_glyph(paths, ink, "augmentationDot", dx, top + 1.5, sp)
      dx += 0.6
    end
  end
end

def score_draw_note(paths, ink, ev, top, sp)
  head_name = score_head_name(ev["base"])
  hw = ev["head_w"]
  # Ledger lines, a little wider than the heads they carry.
  hi = ev["heads"][-1]["pos"]
  lo = ev["heads"][0]["pos"]
  wide = ev["heads"].any? { |hd| hd["side"] != 0 }
  reach_out = hw * SCORE_RULE["ledger_out"]
  lx = ev["x"] - reach_out
  lw = hw + 2.0 * reach_out
  if wide && ev["up"]
    lw += hw - SCORE_RULE["stem"]
  end
  if wide && !ev["up"]
    lx -= hw - SCORE_RULE["stem"]
    lw += hw - SCORE_RULE["stem"]
  end
  lt = SCORE_RULE["ledger"]
  pos = 6
  while pos <= hi
    paths.push(score_rect(ink, lx, top + score_y(pos) - lt / 2.0, lw, lt, sp))
    pos += 2
  end
  pos = -6
  while pos >= lo
    paths.push(score_rect(ink, lx, top + score_y(pos) - lt / 2.0, lw, lt, sp))
    pos -= 2
  end
  # Heads, accidentals, dots.
  dot_x = ev["x"] + hw + 0.3
  dot_x += hw - SCORE_RULE["stem"] if wide && ev["up"]
  for hd in ev["heads"]
    hx = ev["x"] + hd["side"] * (hw - SCORE_RULE["stem"])
    y = top + score_y(hd["pos"])
    score_draw_glyph(paths, ink, head_name, hx, y, sp)
    unless hd["acc"].nil?
      score_draw_glyph(paths, ink, score_acc_name(hd["acc"]), ev["x"] + hd["acc_x"], y, sp)
    end
    if ev["dots"] > 0
      dot_pos = hd["pos"] % 2 == 0 ? hd["pos"] + 1 : hd["pos"]
      dx = dot_x
      for _ in 0..ev["dots"]
        score_draw_glyph(paths, ink, "augmentationDot", dx, top + score_y(dot_pos), sp)
        dx += 0.6
      end
    end
  end
  return nil if ev["base"] == 1

  # The stem, from the head it leaves to its end; then a flag if it is
  # alone.
  g = score_glyph(head_name)
  sx = 0.0
  tip = 0.0
  root = 0.0
  if ev["up"]
    root = top + score_y(lo) + g["anchors"]["stemUpSE"][1]
    sx = score_stem_x(ev) - SCORE_RULE["stem"]
    tip = top + ev["stem_end"]
    paths.push(score_rect(ink, sx, tip, SCORE_RULE["stem"], root - tip, sp))
  else
    root = top + score_y(hi) + g["anchors"]["stemDownNW"][1]
    sx = score_stem_x(ev)
    tip = top + ev["stem_end"]
    paths.push(score_rect(ink, sx, root, SCORE_RULE["stem"], tip - root, sp))
  end
  if ev["beam"].nil? && score_flags(ev["base"]) > 0
    flag = score_flag_name(ev["base"], ev["up"])
    anchor = score_glyph(flag)["anchors"][ev["up"] ? "stemUpNW" : "stemDownSW"]
    score_draw_glyph(paths, ink, flag, sx - anchor[0], tip - anchor[1], sp)
  end
end

# The beams of a group: the outermost through every stem, each inner one
# through the notes that have that many, and a stub a head wide for a note
# that has more beams than both its neighbours.
def score_draw_beam(paths, ink, g, top, sp)
  notes = g["notes"]
  dir = g["up"] ? 1.0 : -1.0
  for level in 0..g["n"]
    off = level * SCORE_RULE["beam_step"] * dir
    i = 0
    while i < notes.length
      if score_flags(notes[i]["base"]) <= level
        i += 1
        next
      end
      jj = i
      while jj + 1 < notes.length && score_flags(notes[jj + 1]["base"]) > level
        jj += 1
      end
      xa = score_stem_x(notes[i]) - (g["up"] ? SCORE_RULE["stem"] : 0.0)
      xb = score_stem_x(notes[jj]) + (g["up"] ? 0.0 : SCORE_RULE["stem"])
      if i == jj
        stub = 1.1
        if i == 0
          xb = xa + stub
        else
          xb = xa + SCORE_RULE["stem"]
          xa = xb - stub
        end
      end
      ya = score_beam_y(g, xa) + off
      yb = score_beam_y(g, xb) + off
      cmds = []
      bt = SCORE_RULE["beam"]
      if g["up"]
        cmds = [0, xa, ya, 1, xb, yb, 1, xb, yb + bt, 1, xa, ya + bt, 4]
      else
        cmds = [0, xa, ya - bt, 1, xb, yb - bt, 1, xb, yb, 1, xa, ya, 4]
      end
      paths.push(score_fill(ink, cmds, 0.0, top, sp))
      i = jj + 1
    end
  end
end
