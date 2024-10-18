require "envy"
Envy.from_file "dev.env.yaml", ".env.yaml", "example.env.yaml", perm: 0o400

require "kemal"
require "kemal-session"
require "json"
require "./solerian/*"

Kemal::Session.config.engine = Kemal::Session::FileEngine.new({:sessions_dir => "./sess"})
Kemal::Session.config.secret = ENV["SOLHTTP_SECRET"]
Kemal::Session.config.samesite = HTTP::Cookie::SameSite::None
Kemal::Session.config.secure = true
Kemal.config.env = ENV["SOLHTTP_ENV"]
Kemal.config.powered_by_header = false
Kemal.config.logger = Solerian::LogHandler.new
Kemal.config.add_handler Solerian::CorsHandler.new, 0
error 404 { }
error 500 { }

module Solerian
  VERSION = {{ `shards version #{__DIR__}`.chomp.stringify }}
  Log     = ::Log.for self

  class CorsHandler
    include HTTP::Handler

    def call(context : HTTP::Server::Context)
      context.response.headers["Access-Control-Allow-Origin"] = ENV["CORS_ORIGIN"]
      context.response.headers["Access-Control-Allow-Headers"] = "Authorization, X-Solerian-Client"
      context.response.headers["Access-Control-Allow-Credentials"] = "true"
      context.response.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, PATCH, DELETE"
      call_next context
    end
  end

  post "/api/v0/login" do |ctx|
    username = ctx.params.body["username"]?
    secret = ctx.params.body["secret"]?
    next Auth.check_login ctx, username, secret
  end

  post "/api/v0/logout" do |ctx|
    next unless Auth.assert_auth ctx
    ctx.session.destroy
    ctx.response.content_type = "application/json"
    ctx.response.status_code = 200
    "{}"
  end

  get "/api/v0/me" do |ctx|
    name = Auth.username(ctx)
    ctx.response.content_type = "application/json"
    if name
      {name: name}.to_json
    else
      ctx.session.destroy
      "null"
    end
  end

  get "/api/v0/version" do |ctx|
    VERSION
  end

  # get "/api/v0/raw" do |ctx|
  #   cors ctx
  #   ctx.response.content_type = "application/json"
  #   DB::Old::RawEntry.all.to_a.to_json
  # end

  get "/api/v0/new" do |ctx|
    # ctx.response.content_type = "application/json"
    # DB.copy ctx.response.output

    if etag = DB.etag
      ctx.response.headers["ETag"] = etag
      if ctx.request.headers["If-None-Match"]? == etag
        ctx.response.status = HTTP::Status::NOT_MODIFIED
        ctx.response.close
        next
      end
    end

    send_file ctx, DB::STORAGE.to_s, "application/json"
    ctx.response.close
    nil
  end

  post "/api/v0/section" do |ctx|
    next unless Auth.assert_auth ctx
    ctx.response.status_code = 400
    to_id = ctx.params.body["to"]?
    as_id = ctx.params.body["as"]?
    title = ctx.params.body["title"]? || next "No title"
    content = ctx.params.body["content"]? || next "No content"

    next "One of to or as has to be provided" if to_id.nil? && as_id.nil?

    storage = DB.load
    if to_id != nil
      to = storage.words.find(&.id.== to_id) || storage.meanings.find(&.id.== to_id) || next "Invalid to hash"
      section = DB::Section.new(title: title, content: content)
      to.as(DB::Sectionable).sections << section.id
      to.touch!
      storage.sections << section
    elsif as_id != nil
      as_ = storage.sections.find(&.id.== as_id) || next "Invalid as hash"
      as_.title = title
      as_.content = content
      as_.touch!
    else
      raise "can't happen"
    end
    DB.save storage

    ctx.response.content_type = "application/json"
    ctx.response.status_code = 200
    "{}"
  end

  delete "/api/v0/section/:id" do |ctx|
    next unless Auth.assert_auth ctx
    ctx.response.status_code = 400
    id = ctx.params.url["id"]? || next "No id"

    storage = DB.load
    parent = storage.words.find(&.sections.includes? id) || storage.meanings.find(&.sections.includes? id) || next "Orphan"
    section = storage.sections.find(&.id.== id) || next "Invalid id"

    parent.as(DB::Sectionable).sections.delete(id) || next "Failed to delete from parent"
    storage.sections.delete(section) || next "Failed to delete from storage"

    DB.save storage

    ctx.response.content_type = "application/json"
    ctx.response.status_code = 200
    "{}"
  end

  post "/api/v0/meaning" do |ctx|
    next unless Auth.assert_auth ctx
    ctx.response.status_code = 400
    to_id = ctx.params.body["to"]?
    as_id = ctx.params.body["as"]?
    eng = ctx.params.body["eng"]? || next "No eng"

    next "One of to or as has to be provided" if to_id.nil? && as_id.nil?

    storage = DB.load
    if to_id != nil
      to = storage.words.find(&.id.== to_id) || next "Invalid to hash"
      meaning = DB::Meaning.new(eng: eng, sections: [] of String)
      to.meanings << meaning.id
      to.touch!
      storage.meanings << meaning
    elsif as_id != nil
      as_ = storage.meanings.find(&.id.== as_id) || next "Invalid as hash"
      as_.eng = eng
      as_.touch!
    else
      raise "can't happen"
    end
    DB.save storage

    ctx.response.content_type = "application/json"
    ctx.response.status_code = 200
    "{}"
  end

  post "/api/v0/entry" do |ctx|
    next unless Auth.assert_auth ctx
    ctx.response.status_code = 400
    as_id = ctx.params.body["as"]?
    sol = ctx.params.body["sol"]? || next "No sol"
    extra = ctx.params.body["extra"]? || next "No extra"
    tag = ctx.params.body["tag"]?
    eng = ctx.params.body["eng"]?
    ex = ctx.params.body["ex"]?
    response = nil

    storage = DB.load
    if as_id.nil?
      meanings = [] of String
      if eng
        eng.split(";").map do |i|
          meaning = DB::Meaning.new(eng: i.strip, sections: [] of String)
          storage.meanings << meaning
          meanings << meaning.id
        end
      end
      entry = DB::Entry.new(sol: sol, extra: extra, tag: tag, ex: ex, meanings: meanings, sections: [] of String)
      storage.words << entry
      response = entry.id
    else
      next "Can't update eng using this method" unless eng.nil?
      as_ = storage.words.find(&.id.== as_id) || next "Invalid as hash"
      as_.sol = sol
      as_.extra = extra
      as_.tag = tag
      as_.touch!
    end
    DB.save storage

    ctx.response.content_type = "application/json"
    ctx.response.status_code = 200
    response.to_json
  end

  post "/api/v0/validate" do |ctx|
    next unless Auth.assert_auth ctx
    ctx.response.status_code = 400

    body = ctx.request.body
    next "No body?" if body.nil?
    start = Time.monotonic
    entries = Array({String, String}).from_json body
    loaded = Time.monotonic
    Log.info { "Validating #{entries.size} entries" }
    fail = [] of Int32
    entries.each_with_index do |(sol, ipa), i|
      unless Validation.is_valid? sol, ipa
        fail << i
      end
    end
    finished = Time.monotonic
    Log.info { "Validation took #{((finished - start).total_milliseconds).significant(4)}ms" }
    Log.info { "   Loading took #{((loaded - start).total_milliseconds).significant(4)}ms" }
    Log.info { "     Logic took #{((finished - loaded).total_milliseconds).significant(4)}ms" }

    ctx.response.content_type = "application/json"
    ctx.response.status_code = 200
    fail.to_json
  end

  options "/*" do |ctx|
    ctx.response.status_code = 200
    nil
  end
end

Log.setup do |c|
  backend = Log::IOBackend.new

  c.bind "*", :trace, backend
  c.bind "db.*", :info, backend
  c.bind "granite", :info, backend
end

if Solerian::DB.has_db?
  Solerian::DB.head!
else
  # Solerian::DB.migrate
  raise "No db"
end

Kemal.run
