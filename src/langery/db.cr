require "./id"
require "json"
require "log"

module Langery::DB
  Log = ::Log.for self

  class Store
    getter name : String
    getter etag : String?
    @log : ::Log

    def initialize(@name : String)
      @log = Log.for(@name)
      @etag = nil # temporary

      if File.exists?(path)
        File.open(path, "r") do |f|
          self.update_etag(f.info.modification_time)
        end
      else
        @log.notice { "Initializing new DB" }
        write_data! Data.empty
      end
    end

    private def update_etag(time = Time.utc) : String
      new_etag = "lgy-" + time.to_s("%Y-%-m-%-d-%H-%M-%S-%L") + "/#{Solerian::VERSION}"
      @etag = new_etag
      @log.notice { "new etag: #{new_etag}" }
      new_etag
    end

    def load_data! : Data
      File.open(path, "r") do |f|
        Data.from_json f
      end
    end

    def write_data!(d : Data) : Nil
      File.open(path, "w") do |f|
        d.etag = self.update_etag(f.info.modification_time)
        d.to_json f
        @log.warn { "Wrote storage: #{f.size.humanize_bytes}" }
      end
    end

    def path
      Path["./#{@name}.dbv2.json"]
    end
  end

  class_getter stores : Hash(String, Store) = {} of String => Store

  def self.initialize_stores_from_disk
    ENV["DB_STORESV2"].split(",").each do |name|
      @@stores[name] = Store.new(name)
    end
  end

  def self.store?(name : String) : Store?
    @@stores[name]
  end

  abstract class Base
    macro inherited
      include JSON::Serializable
      include JSON::Serializable::Unmapped

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

  class Word < Base
    include Sectionable
    getter meanings : Array(String)

    def initialize(*, @meanings = [] of String, @sections = [] of String, created_at : Time? = nil, updated_at : Time? = nil, hash : String? = nil)
      @created_at = created_at || Time.utc
      @updated_at = updated_at || Time.utc
      @id = hash || ID.generate
    end

    def self.cascade_delete(id : String, data : Data) : Word
      word_idx = data.words.index(&.id.== id) || raise "Invalid id"
      word = data.words.delete_at(word_idx)

      word.sections.dup.each do |sid|
        Langery::DB::Section.cascade_delete sid, data
      end

      word.meanings.dup.map do |mid|
        Langery::DB::Meaning.cascade_delete mid, data
      end

      word
    end
  end

  class Meaning < Base
    include Sectionable

    def initialize(*, @sections = [] of String, created_at : Time? = nil, updated_at : Time? = nil, hash : String? = nil)
      @created_at = created_at || Time.utc
      @updated_at = updated_at || Time.utc
      @id = hash || ID.generate
    end

    def self.cascade_delete(id : String, data : Data) : Meaning
      meaning_idx = data.meanings.index(&.id.== id) || raise "Invalid id"
      meaning = data.meanings.delete_at(meaning_idx)

      meaning.sections.dup.each do |cid|
        Langery::DB::Section.cascade_delete cid, data
      end

      parent = data.words.find(&.meanings.includes? id)
      parent.try &.meanings.delete(id)

      meaning
    end
  end

  class Section < Base
    def initialize(*, created_at : Time? = nil, updated_at : Time? = nil, hash : String? = nil)
      @created_at = created_at || Time.utc
      @updated_at = updated_at || Time.utc
      @id = hash || ID.generate
    end

    def self.cascade_delete(id : String, data : Data) : Section
      section_idx = data.sections.index(&.id.== id) || raise "Invalid id"
      section = data.sections.delete_at(section_idx)

      parent = data.find_sectionable(&.sections.includes? id)
      if parent
        parent.sections.delete(id)
      end

      section
    end
  end

  struct Data
    include JSON::Serializable

    property words : Array(Word)
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
      self.new([] of Word, [] of Meaning, [] of Section, nil)
    end
  end
end
