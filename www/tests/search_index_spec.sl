# ============================================================================
# Docs search index (public/js/search-index.json)
# ============================================================================
#
# The search modal (app/views/layouts/_search_modal.html.slv) runs Fuse over
# this hand-maintained file plus the blog posts from GET /docs/blog/search-index.
# A docs page with no entry cannot be found at all, which is how "D1", "R2" and
# "Cloudflare" came back empty: the Cloudflare Workers page was never indexed.

def search_entries
  JSON.parse(File.read("public/js/search-index.json"))["entries"]
end

# The docs views that a route renders, as the paths the index must carry:
# app/views/docs/database/sqlite.html.slv → /docs/database/sqlite.
def routed_docs_view_paths
  routes_source = File.read("config/routes.sl")
  view_files = File.glob("app/views/docs/*.html.slv")
  File.glob("app/views/docs/*").each do |entry|
    view_files = view_files + File.glob("#{entry}/*.html.slv") if File.is_dir(entry)
  end
  view_files
    .map { |file| file.replace("app/views", "").replace(".html.slv", "") }
    .filter { |path| !path.split("/").last.starts_with?("_") }
    .filter { |path| routes_source.includes?("get(\"#{path}\",") }
end

def indexed_page_paths
  search_entries.map { |entry| entry["path"].split("#")[0] }
end

# The paths of the entries carrying `term` as a keyword, in any case.
def paths_for_keyword(term)
  search_entries
    .filter { |entry| (entry["keywords"] ?? []).any? { |word| word.downcase == term.downcase } }
    .map { |entry| entry["path"] }
end

describe("Docs search index") do
  test("is valid JSON with entries that all have a title and a path") do
    search_entries.each do |entry|
      assert(entry["title"].present?)
      assert(entry["path"].starts_with?("/docs"))
    end
  end

  test("has an entry for every docs page a route renders") do
    indexed = indexed_page_paths
    missing = routed_docs_view_paths.filter { |path| !indexed.includes?(path) }
    assert_eq(missing, [])
  end

  test("finds the Cloudflare Workers page under cloudflare, D1 and R2") do
    assert(paths_for_keyword("cloudflare").includes?("/docs/development-tools/edge"))
    assert(paths_for_keyword("D1").includes?("/docs/development-tools/edge#d1"))
    assert(paths_for_keyword("d1").includes?("/docs/database/sqlite"))
    assert(paths_for_keyword("R2").includes?("/docs/development-tools/edge#files"))
    assert(paths_for_keyword("r2").includes?("/docs/builtins/s3"))
  end

  test("carries the two-character terms S3, KV and ES as keywords") do
    assert(paths_for_keyword("S3").includes?("/docs/builtins/s3"))
    assert(paths_for_keyword("KV").includes?("/docs/builtins/kv"))
    assert(paths_for_keyword("es").includes?("/docs/builtins/es"))
  end

  test("does not index a term nobody documents") do
    assert_eq(paths_for_keyword("zz-not-a-soli-term"), [])
  end
end

describe("GET /docs/blog/search-index") do
  test("lists the published posts as search entries, headings as keywords") do
    response = get("/docs/blog/search-index")
    assert_eq(res_status(response), 200)
    posts = res_json(response)["entries"]
    d1_post = posts.find { |post| post["path"] == "/docs/blog/soli-on-cloudflare-workers-and-d1" }
    assert_eq(d1_post["type"], "post")
    assert(d1_post["description"].includes?("D1"))
    assert(d1_post["keywords"].includes?("A notes app on D1"))
    assert(posts.all? { |post| post["keywords"].all? { |word| word.is_a?("string") } })
  end

  test("answers 404 for a post that does not exist, not a search entry") do
    assert_eq(res_status(get("/docs/blog/zz-no-such-post")), 404)
  end
end
