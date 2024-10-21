require "nanoid"
require "benchmark"
require "json"

module Solerian::DB
  Log = ::Log.for self

  class_property etag : String? = nil

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
    getter meanings : Array(String)

    def initialize(*, @sol, @extra, @tag, @ex, @meanings, @sections, created_at : Time? = nil, updated_at : Time? = nil, hash : String? = nil)
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

    def initialize(@words, @meanings, @sections)
    end

    def find_sectionable(&pred : DB::Sectionable -> Bool) : DB::Sectionable?
      (@words.find(&pred) || @meanings.find(&pred)).as DB::Sectionable?
    end
  end

  STORAGE = Path["./new.db.json"]

  def self.save(all : Storage)
    File.open(STORAGE, "w") do |f|
      DB.etag = Time.utc
      all.to_json f
      Log.warn { "Wrote storage: #{f.size.humanize_bytes}" }
    end
  end

  def self.load : Storage
    File.open(STORAGE, "r") do |f|
      Storage.from_json f
    end
  end

  def self.has_db? : Bool
    File.exists? STORAGE
  end

  def self.head! : Nil
    File.open(STORAGE, "r") do |f|
      DB.etag = f.info.modification_time
    end
  end

  def self.etag=(time : Time) : Nil
    @@etag = "sld-" + time.to_s("%Y-%-m-%-d-%H-%M-%S-%L") + "/#{Solerian::VERSION}"
    Log.notice { "New etag: #{@@etag}" }
  end

  # def self.migrate
  #   mem = Benchmark.memory {
  #     all = [] of Entry

  #     Old::RawEntry.all.each do |e|
  #       eng = e.eng
  #       tag = nil
  #       if eng.starts_with? '{'
  #         close = eng.index! '}'
  #         tag = eng[1...close]
  #         eng = eng[(close + 1)...].strip
  #       end

  #       meanings = eng.split("; ").map_with_index { |m, i| Meaning.new(eng: m, sections: [] of Section, created_at: e.created_at, updated_at: e.updated_at) }
  #       new = Entry.new(hash: e.hash, sol: e.sol, extra: e.extra, tag: tag, meanings: meanings, sections: [] of Section, created_at: e.created_at, updated_at: e.updated_at)
  #       all << new
  #     end

  #     self.save all
  #   }

  #   Log.info { "Migration memory usage: #{mem.humanize_bytes}" }
  # end

  # def self.migrate
  #   old_entries = DB.load
  #   words = [] of Entry
  #   meanings = [] of Meaning
  #   sections = [] of Section
  #   old_entries.each do |w|
  #     w.meanings.each do |m|
  #       m.sections.each do |s|
  #         sections << Section.new(title: s.title, content: s.content, created_at: s.created_at, updated_at: s.updated_at, hash: s.hash)
  #       end
  #       meanings << Meaning.new(eng: m.eng, sections: m.sections.map(&.hash), created_at: m.created_at, updated_at: m.updated_at, hash: m.hash)
  #     end
  #     w.sections.each do |s|
  #       sections << Section.new(title: s.title, content: s.content, created_at: s.created_at, updated_at: s.updated_at, hash: s.hash)
  #     end
  #     words << Entry.new(sol: w.sol, extra: w.extra, tag: w.tag, meanings: w.meanings.map(&.hash), sections: w.sections.map(&.hash), created_at: w.created_at, updated_at: w.updated_at, hash: w.hash)
  #   end
  #   self.save(Storage.new(words: words, meanings: meanings, sections: sections))
  # end
end
