require "./db"
require "json"
require "crypto/bcrypt/password"

module Solerian::Auth
  class User
    include JSON::Serializable

    property name : String
    property pass : String
  end

  STORAGE = Path["./user.db.json"]
  USERS = File.open(STORAGE, "r") { |f| Hash(String, User).from_json f }

  alias Passwd = Crypto::Bcrypt::Password

  def self.check_login(ctx : HTTP::Server::Context, username : String?, secret : String?) : String
    ctx.response.status_code = 400

    return "No" if username.nil? || secret.nil?

    user = USERS[username]?
    return "No" if user.nil?

    pass = Passwd.new user.pass
    if pass.verify secret
      ctx.session.string("user", user.name)
      ctx.response.status_code = 200
      ctx.response.content_type = "application/json"
      return { name: user.name }.to_json
    end

    "No"
  end

  def self.user?(ctx)
    !self.username(ctx).nil?
  end

  def self.assert_auth(ctx)
    if self.username(ctx).nil?
      ctx.session.destroy
      ctx.response.status_code = 401
      ctx.response.close
      return false
    end
    true
  end

  def self.username(ctx)
    ctx.session.string?("user")
  end
end