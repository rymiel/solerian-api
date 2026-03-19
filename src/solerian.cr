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

  options "/*" do |ctx|
    ctx.response.status_code = 200
    nil
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

  post "/api/v2/solerian/validate" do |ctx|
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
end

Log.setup do |c|
  backend = Log::IOBackend.new
  c.bind "*", :trace, backend
end

Langery::DB.initialize_stores_from_disk

Kemal.run
