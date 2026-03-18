require "envy"
Envy.from_file "dev.env.yaml", ".env.yaml", "example.env.yaml", perm: 0o400

require "kemal"
require "kemal-session"
require "json"
require "./solerian/*"
require "./langery/db"

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
    ORIGINS = ENV["CORS_ORIGINS"].split(",")

    def call(context : HTTP::Server::Context)
      origin = context.request.headers["Origin"]?
      if origin && origin.in? ORIGINS
        context.response.headers["Access-Control-Allow-Origin"] = origin
        context.response.headers["Access-Control-Allow-Headers"] = "Authorization, X-Solerian-Client"
        context.response.headers["Access-Control-Allow-Credentials"] = "true"
        context.response.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, PATCH, DELETE"
      end
      call_next context
    end
  end

  # Misc
  get "/version" do |ctx|
    VERSION
  end

  # User endpoints (v0)
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

  # Store endpoints (v1)
  get "/api/v1/:store/data" do |ctx|
    ctx.response.status = HTTP::Status::BAD_REQUEST
    store = ctx.params.url["store"]? || next "No store"
    next "Invalid store" unless store.in? DB::STORES
    if etag = DB.etags[store]?
      ctx.response.headers["ETag"] = etag
      if ctx.request.headers["If-None-Match"]? == etag
        ctx.response.status = HTTP::Status::NOT_MODIFIED
        ctx.response.close
        next
      end
    end

    ctx.response.status = :ok
    send_file ctx, DB.store(store), "application/json"
    ctx.response.close
    nil
  end

  post "/api/v1/:store/section" do |ctx|
    next unless Auth.assert_auth ctx
    ctx.response.status = :bad_request
    store = ctx.params.url["store"]? || next "No store"
    next "Invalid store" unless store.in? DB::STORES
    to_id = ctx.params.body["to"]?
    as_id = ctx.params.body["as"]?
    title = ctx.params.body["title"]? || next "No title"
    content = ctx.params.body["content"]? || next "No content"

    next "One of to or as has to be provided" if to_id.nil? && as_id.nil?

    storage = DB.load store
    if to_id != nil
      to = storage.find_sectionable(&.id.== to_id) || next "Invalid to hash"
      section = DB::Section.new(title: title, content: content)
      to.sections << section.id
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
    DB.save store, storage

    ctx.response.content_type = "application/json"
    ctx.response.status = :ok
    "{}"
  end

  delete "/api/v1/:store/section/:id" do |ctx|
    next unless Auth.assert_auth ctx
    ctx.response.status = :bad_request
    store = ctx.params.url["store"]? || next "No store"
    next "Invalid store" unless store.in? DB::STORES
    id = ctx.params.url["id"]? || next "No id"

    storage = DB.load store
    parent = storage.find_sectionable(&.sections.includes? id) || next "Orphan"
    section = storage.sections.find(&.id.== id) || next "Invalid id"

    parent.sections.delete(id) || next "Failed to delete from parent"
    storage.sections.delete(section) || next "Failed to delete from storage"

    DB.save store, storage

    ctx.response.content_type = "application/json"
    ctx.response.status = :ok
    "{}"
  end

  post "/api/v1/:store/meaning" do |ctx|
    next unless Auth.assert_auth ctx
    ctx.response.status = :bad_request
    store = ctx.params.url["store"]? || next "No store"
    next "Invalid store" unless store.in? DB::STORES
    to_id = ctx.params.body["to"]?
    as_id = ctx.params.body["as"]?
    eng = ctx.params.body["eng"]? || next "No eng"

    next "One of to or as has to be provided" if to_id.nil? && as_id.nil?

    storage = DB.load store
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
    DB.save store, storage

    ctx.response.content_type = "application/json"
    ctx.response.status = :ok
    "{}"
  end

  delete "/api/v1/:store/meaning/:id" do |ctx|
    next unless Auth.assert_auth ctx
    ctx.response.status = :bad_request
    store = ctx.params.url["store"]? || next "No store"
    next "Invalid store" unless store.in? DB::STORES
    id = ctx.params.url["id"]? || next "No id"

    storage = DB.load store
    parent = storage.words.find(&.meanings.includes? id) || next "Orphan"
    meaning = storage.meanings.find(&.id.== id) || next "Invalid id"

    meaning.sections.each do |cid|
      child = storage.sections.find(&.id.== cid) || raise "Missing child #{cid}"
      storage.sections.delete(child) || raise "Failed to delete child #{cid}"
    end

    parent.meanings.delete(id) || next "Failed to delete from parent"
    storage.meanings.delete(meaning) || next "Failed to delete from storage"

    DB.save store, storage

    ctx.response.content_type = "application/json"
    ctx.response.status = :ok
    "{}"
  end

  post "/api/v1/:store/entry" do |ctx|
    next unless Auth.assert_auth ctx
    ctx.response.status = :bad_request
    store = ctx.params.url["store"]? || next "No store"
    next "Invalid store" unless store.in? DB::STORES
    as_id = ctx.params.body["as"]?
    sol = ctx.params.body["sol"]? || next "No sol"
    extra = ctx.params.body["extra"]? || next "No extra"
    tag = ctx.params.body["tag"]?
    eng = ctx.params.body["eng"]?
    ex = ctx.params.body["ex"]?
    gloss = ctx.params.body["gloss"]?
    response = nil

    storage = DB.load store
    if as_id.nil?
      meanings = [] of String
      if eng
        eng.split(";").map do |i|
          meaning = DB::Meaning.new(eng: i.strip, sections: [] of String)
          storage.meanings << meaning
          meanings << meaning.id
        end
      end
      entry = DB::Entry.new(sol: sol, extra: extra, tag: tag, ex: ex, gloss: gloss, meanings: meanings, sections: [] of String)
      storage.words << entry
      response = entry.id
    else
      next "Can't update eng using this method" unless eng.nil?
      as_ = storage.words.find(&.id.== as_id) || next "Invalid as hash"
      as_.sol = sol
      as_.extra = extra
      as_.tag = tag
      as_.ex = ex
      as_.gloss = gloss
      as_.touch!
    end
    DB.save store, storage

    ctx.response.content_type = "application/json"
    ctx.response.status = :ok
    response.to_json
  end

  delete "/api/v1/:store/entry/:id" do |ctx|
    next unless Auth.assert_auth ctx
    ctx.response.status = :bad_request
    store = ctx.params.url["store"]? || next "No store"
    next "Invalid store" unless store.in? DB::STORES
    id = ctx.params.url["id"]? || next "No id"

    storage = DB.load store
    entry = storage.words.find(&.id.== id) || next "Invalid id"

    entry.sections.each do |cid|
      child = storage.sections.find(&.id.== cid) || raise "Missing entry child #{cid}"
      storage.sections.delete(child) || raise "Failed to delete entry child #{cid}"
    end

    entry.meanings.map do |mid|
      meaning = storage.meanings.find(&.id.== mid) || raise "Missing meaning #{mid}"

      meaning.sections.each do |cid|
        child = storage.sections.find(&.id.== cid) || raise "Missing meaning child #{cid}"
        storage.sections.delete(child) || raise "Failed to delete meaning child #{cid}"
      end

      storage.meanings.delete(meaning) || raise "Failed to delete meaning #{mid}"
    end

    storage.words.delete(entry) || next "Failed to delete from storage"

    DB.save store, storage

    ctx.response.content_type = "application/json"
    ctx.response.status = :ok
    "{}"
  end

  post "/api/v1/:store/config/:key" do |ctx|
    next unless Auth.assert_auth ctx
    ctx.response.status = :bad_request
    store = ctx.params.url["store"]? || next "No store"
    next "Invalid store" unless store.in? DB::STORES
    key = ctx.params.url["key"]? || next "No key"
    content = JSON.parse(ctx.request.body || next "No content") rescue next "Invalid content"

    storage = DB.load store
    storage.config[key] = content
    DB.save store, storage

    ctx.response.content_type = "application/json"
    ctx.response.status = :ok
    "{}"
  end

  post "/api/v1/solerian/validate" do |ctx|
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

  # Store endpoints (v2)
  get "/api/v2/:store/data" do |ctx|
    ctx.response.status = :bad_request
    # TODO: some sort of ctx helper for this?
    store = Langery::DB.store?(ctx.params.url["store"]) || next "Invalid store"
    if etag = store.etag
      ctx.response.headers["ETag"] = etag
      if ctx.request.headers["If-None-Match"]? == etag
        ctx.response.status = HTTP::Status::NOT_MODIFIED
        ctx.response.close
        next
      end
    end

    ctx.response.status = :ok
    send_file ctx, store.path.to_s, "application/json"
    ctx.response.close
    nil
  end

  def self.upsert_entity(
    ctx : HTTP::Server::Context,
    cls : Entity.class, *,
    find_parent : ((Langery::DB::Data, String) -> Parent?)?,
    data_collection : (Langery::DB::Data) -> Array(Entity),
    parent_collection : (Parent -> Array(String))?,
  ) forall Entity, Parent
    return unless Auth.assert_auth ctx
    ctx.response.status = :bad_request
    store = Langery::DB.store?(ctx.params.url["store"]) || return "Invalid store"
    to_id = ctx.params.body["to"]?
    as_id = ctx.params.body["as"]?
    json = JSON.parse(ctx.params.body["json"]? || return "No JSON content").as_h rescue return "Invalid JSON content"

    data = store.load_data!

    if as_id
      entity = data_collection.call(data).find(&.id.== as_id) || return "Invalid as hash"
    elsif find_parent && to_id
      parent = find_parent.call(data, to_id) || return "Invalid to hash"
      entity = Entity.new
      data_collection.call(data) << entity
      if parent_collection
        parent_collection.call(parent) << entity.id
      end
      parent.touch!
    elsif find_parent
      return "One of to or as has to be provided"
    else
      entity = Entity.new
      data_collection.call(data) << entity
    end

    entity.json_unmapped = json
    entity.touch!

    store.write_data! data

    ctx.response.content_type = "application/json"
    ctx.response.status = :ok
    entity.to_json
  end

  post "/api/v2/:store/section" do |ctx|
    upsert_entity(ctx, Langery::DB::Section,
      find_parent: ->(data : Langery::DB::Data, id : String) { data.find_sectionable(&.id.== id) },
      data_collection: ->(data : Langery::DB::Data) { data.sections },
      parent_collection: ->(parent : Langery::DB::Sectionable) { parent.sections }
    )
  end

  post "/api/v2/:store/meaning" do |ctx|
    upsert_entity(ctx, Langery::DB::Meaning,
      find_parent: ->(data : Langery::DB::Data, id : String) { data.words.find(&.id.== id) },
      data_collection: ->(data : Langery::DB::Data) { data.meanings },
      parent_collection: ->(parent : Langery::DB::Word) { parent.meanings }
    )
  end

  post "/api/v2/:store/word" do |ctx|
    upsert_entity(ctx, Langery::DB::Word,
      find_parent: nil,
      data_collection: ->(data : Langery::DB::Data) { data.words },
      parent_collection: nil
    )
  end

  delete "/api/v2/:store/section/:id" do |ctx|
    next unless Auth.assert_auth ctx
    ctx.response.status = :bad_request
    store = Langery::DB.store?(ctx.params.url["store"]) || next "Invalid store"
    id = ctx.params.url["id"]? || next "No id"

    data = store.load_data!
    Langery::DB::Section.cascade_delete id, data
    store.write_data! data

    ctx.response.content_type = "application/json"
    ctx.response.status = :ok
    "{}"
  end

  delete "/api/v2/:store/meaning/:id" do |ctx|
    next unless Auth.assert_auth ctx
    ctx.response.status = :bad_request
    store = Langery::DB.store?(ctx.params.url["store"]) || next "Invalid store"
    id = ctx.params.url["id"]? || next "No id"

    data = store.load_data!
    Langery::DB::Meaning.cascade_delete id, data
    store.write_data! data

    ctx.response.content_type = "application/json"
    ctx.response.status = :ok
    "{}"
  end

  delete "/api/v2/:store/word/:id" do |ctx|
    next unless Auth.assert_auth ctx
    ctx.response.status = :bad_request
    store = Langery::DB.store?(ctx.params.url["store"]) || next "Invalid store"
    id = ctx.params.url["id"]? || next "No id"

    data = store.load_data!
    Langery::DB::Word.cascade_delete id, data
    store.write_data! data

    ctx.response.content_type = "application/json"
    ctx.response.status = :ok
    "{}"
  end

  post "/api/v2/:store/config/:key" do |ctx|
    next unless Auth.assert_auth ctx
    ctx.response.status = :bad_request
    store = Langery::DB.store?(ctx.params.url["store"]) || next "Invalid store"
    key = ctx.params.url["key"]? || next "No key"
    content = JSON.parse(ctx.request.body || next "No content") rescue next "Invalid content"

    data = store.load_data!
    data.config[key] = content
    store.write_data! data

    ctx.response.content_type = "application/json"
    ctx.response.status = :ok
    "{}"
  end

  options "/*" do |ctx|
    ctx.response.status_code = 200
    nil
  end
end

Log.setup do |c|
  backend = Log::IOBackend.new
  c.bind "*", :trace, backend
end

Solerian::DB::STORES.each do |store|
  if Solerian::DB.has_db? store
    Solerian::DB.head! store
  else
    Log.warn { "Initializing new DB (#{store})" }
    Solerian::DB.save store, Solerian::DB::Storage.empty
  end
end

Langery::DB.initialize_stores_from_disk

Kemal.run
