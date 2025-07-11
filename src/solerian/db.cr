require "nanoid"
require "benchmark"
require "json"

module Solerian::DB
  Log = ::Log.for self

  class_getter etags = Hash(String, String).new

  abstract class Base
    macro inherited
      include JSON::Serializable

      @[JSON::Field(key: "hash")]
      getter id : String
      getter created_at : Time
      getter updated_at : Time

      def touch!
        @updated_at = Time.utc
      end
    end
  end

  module Sectionable
    getter sections : Array(String)
  end

  class Entry < Base
    include Sectionable
    property sol : String
    property extra : String
    property tag : String?
    property ex : String?
    property gloss : String?
    getter meanings : Array(String)

    def initialize(*, @sol, @extra, @tag, @ex, @gloss, @meanings, @sections, created_at : Time? = nil, updated_at : Time? = nil, hash : String? = nil)
      @created_at = created_at || Time.utc
      @updated_at = updated_at || Time.utc
      @id = hash || Nanoid.generate(size: 10)
    end
  end

  class Meaning < Base
    include Sectionable
    property eng : String

    def initialize(*, @eng, @sections, created_at : Time? = nil, updated_at : Time? = nil, hash : String? = nil)
      @created_at = created_at || Time.utc
      @updated_at = updated_at || Time.utc
      @id = hash || Nanoid.generate(size: 10)
    end
  end

  class Section < Base
    property title : String
    property content : String

    def initialize(*, @title, @content, created_at : Time? = nil, updated_at : Time? = nil, hash : String? = nil)
      @created_at = created_at || Time.utc
      @updated_at = updated_at || Time.utc
      @id = hash || Nanoid.generate(size: 10)
    end
  end

  struct Storage
    include JSON::Serializable

    property words : Array(Entry)
    property meanings : Array(Meaning)
    property sections : Array(Section)
    property etag : String?
    property config : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(@words, @meanings, @sections, @etag)
    end

    def find_sectionable(&pred : DB::Sectionable -> Bool) : DB::Sectionable?
      (@words.find(&pred) || @meanings.find(&pred)).as DB::Sectionable?
    end

    def self.empty
      self.new([] of Entry, [] of Meaning, [] of Section, nil)
    end
  end

  STORES = ENV["DB_STORES"].split(",")

  def self.save(store : String, all : Storage)
    File.open(DB.store(store), "w") do |f|
      all.etag = DB.update_etag(store)
      all.to_json f
      Log.for(store).warn { "Wrote storage: #{f.size.humanize_bytes}" }
    end
  end

  def self.load(store : String) : Storage
    File.open(DB.store(store), "r") do |f|
      Storage.from_json f
    end
  end

  def self.has_db?(store : String) : Bool
    File.exists? DB.store(store)
  end

  def self.head!(store : String) : Nil
    File.open(DB.store(store), "r") do |f|
      DB.update_etag(store, f.info.modification_time)
    end
  end

  def self.update_etag(store : String, time = Time.utc) : String
    etag = "sld-" + time.to_s("%Y-%-m-%-d-%H-%M-%S-%L") + "/#{Solerian::VERSION}"
    @@etags[store] = etag
    Log.for(store).notice { "New etag: #{etag}" }
    etag
  end

  def self.store(name)
    "./#{name}.db.json"
  end
end
