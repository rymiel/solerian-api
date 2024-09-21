require "kemal"

class Solerian::LogHandler < Kemal::BaseLogHandler
  def initialize(@log = ::Log.for("kemal"))
  end

  def call(context : HTTP::Server::Context)
    elapsed_time = Time.measure { call_next(context) }
    elapsed_text = elapsed_text(elapsed_time)
    @log.info { "#{context.response.status_code}\t#{context.request.method}\t#{context.request.resource}\t#{elapsed_text}" }
    context
  end

  def write(message : String)
    @log.notice { message.strip }
  end

  private def elapsed_text(elapsed)
    "#{(elapsed.total_milliseconds).significant(4)}ms"
  end
end