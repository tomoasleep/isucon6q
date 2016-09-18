require 'digest/sha1'
require 'json'
require 'net/http'
require 'uri'

require 'erubis'
require 'mysql2'
require 'mysql2-cs-bind'
require 'rack/utils'
require 'sinatra/base'
require 'tilt/erubis'
require 'rack-lineprof' unless ENV['RACK_ENV'] == 'production'
require "redis"

module Isuda
  class Web < ::Sinatra::Base
    enable :protection
    enable :sessions

    use Rack::Lineprof unless ENV['RACK_ENV'] == 'production'

    set :erb, escape_html: true
    set :public_folder, File.expand_path('../../../../public', __FILE__)
    set :db_user, ENV['ISUDA_DB_USER'] || 'root'
    set :db_password, ENV['ISUDA_DB_PASSWORD'] || ''
    set :dsn, ENV['ISUDA_DSN'] || 'dbi:mysql:db=isuda'
    set :session_secret, 'tonymoris'
    set :isupam_origin, ENV['ISUPAM_ORIGIN'] || 'http://localhost:5050'
    set :isutar_origin, ENV['ISUTAR_ORIGIN'] || 'http://localhost:5001'

    configure :development do
      require 'sinatra/reloader'

      register Sinatra::Reloader
    end

    set(:set_name) do |value|
      condition {
        user_id = session[:user_id]
        if user_id
          user = db.xquery(%| select name from user where id = ? |, user_id).first
          @user_id = user_id
          @user_name = user[:name]
          halt(403) unless @user_name
        end
      }
    end

    set(:authenticate) do |value|
      condition {
        halt(403) unless @user_id
      }
    end

    helpers do
      def db
        Thread.current[:db] ||=
          begin
            mysql = Mysql2::Client.new(
              username: settings.db_user,
              password: settings.db_password,
              database: 'isuda',
              encoding: 'utf8mb4',
              init_command: %|SET SESSION sql_mode='TRADITIONAL,NO_AUTO_VALUE_ON_ZERO,ONLY_FULL_GROUP_BY'|,
            )
            mysql.query_options.update(symbolize_keys: true)
            mysql
          end
      end

      def isutar_db
        Thread.current[:isutar_db] ||=
        begin
          mysql = Mysql2::Client.new(
          username: settings.db_user,
          password: settings.db_password,
          database: 'isutar',
          encoding: 'utf8mb4',
          init_command: %|SET SESSION sql_mode='TRADITIONAL,NO_AUTO_VALUE_ON_ZERO,ONLY_FULL_GROUP_BY'|,
          )
          mysql.query_options.update(symbolize_keys: true)
          mysql
        end

      def redis
        Thread.current[:redis] ||= Redis.new
      end

      def cached(key, &block)
        if v = redis.get(key)
          v
        else
          new_v = yield
          redis.set(key, new_v)
          new_v
        end
      end

      def register(name, pw)
        chars = [*'A'..'~']
        salt = 1.upto(20).map { chars.sample }.join('')
        salted_password = encode_with_salt(password: pw, salt: salt)
        db.xquery(%|
          INSERT INTO user (name, salt, password, created_at)
          VALUES (?, ?, ?, NOW())
        |, name, salt, salted_password)
        db.last_id
      end

      def encode_with_salt(password: , salt: )
        Digest::SHA1.hexdigest(salt + password)
      end

      def is_spam_content(content)
        isupam_uri = URI(settings.isupam_origin)
        res = Net::HTTP.post_form(isupam_uri, 'content' => content)
        validation = JSON.parse(res.body)
        validation['valid']
        ! validation['valid']
      end

      def htmlify(content, pattern)
        kw2hash = {}
        hashed_content = content.gsub(/(#{pattern})/) {|m|
          matched_keyword = $1
          "isuda_#{Digest::SHA1.hexdigest(matched_keyword)}".tap do |hash|
            kw2hash[matched_keyword] = hash
          end
        }
        escaped_content = Rack::Utils.escape_html(hashed_content)
        kw2hash.each do |(keyword, hash)|
          escaped_keyword = Rack::Utils.escape_path(keyword)
          keyword_url = url("/keyword/#{escaped_keyword}")
          anchor = '<a href="%s">%s</a>' % [keyword_url, escaped_keyword]
          escaped_content.gsub!(hash, anchor)
        end
        escaped_content.gsub(/\n/, "<br />\n")
      end

      def uri_escape(str)
        Rack::Utils.escape_path(str)
      end

      def load_stars(keyword)
        stars = isutar_db.xquery(%| select * from star where keyword = ? |, keyword || '').to_a
        JSON.parse(JSON.generate(stars: stars))['stars']
      end

      def redirect_found(path)
        redirect(path, 302)
      end

      def get_keyword_pattern(reset: false)
        cached("keyword_pattern") do
          init_keyword_pattern
        end
      end

      def delete_and_reset(length)
        v = get_keyword_pattern
        keywords = db.prepare(%| select keyword, keyword_length from entry  where keyword_length = ? |).execute(
          length
        )
        v[length] = keywords.map {|k| Regexp.escape(k[:keyword]) }.join('|')
        redis.set("keyword_pattern", v)
        v
      end

      def build_keyword_pattern(reset: false)
        v = get_keyword_pattern(reset)
        v.to_a.reverse.join("|")
      end

      def reset_and_get(key, length)
        k = Regexp.escape(key)
        v = get_keyword_pattern(false)
        v[length] = v[length] ? "#{v[length]}|#{k}" : k
        redis.set("keyword_pattern", v)
        v
      end

      def init_keyword_pattern
        keys = db.xquery(%| select keyword, keyword_length from entry|)
        v = {}
        keys.each do |key|
          k = Regexp.escape(key[:keyword])
          l = key[:keyword_length].to_i
          v[l] = v[l] ? "#{v[l]}|#{k}" : k
        end
        redis.set("keyword_pattern", v)
      end
    end

    get '/initialize' do
      db.xquery(%| DELETE FROM entry WHERE id > 7101 |)
      isutar_db.xquery('TRUNCATE star')
      init_keyword_pattern

      content_type :json
      JSON.generate(result: 'ok')
    end

    get '/', set_name: true do
      per_page = 10
      page = (params[:page] || 1).to_i

      entries = db.xquery(%|
        SELECT * FROM entry
        ORDER BY updated_at DESC
        LIMIT #{per_page}
        OFFSET #{per_page * (page - 1)}
      |)

      pattern = build_keyword_pattern

      entries.each do |entry|
        entry[:html] = htmlify(entry[:description], pattern)
        entry[:stars] = load_stars(entry[:keyword])
      end

      total_entries = db.xquery(%| SELECT count(*) AS total_entries FROM entry |).first[:total_entries].to_i

      last_page = (total_entries.to_f / per_page.to_f).ceil
      from = [1, page - 5].max
      to = [last_page, page + 5].min
      pages = [*from..to]

      locals = {
        entries: entries,
        page: page,
        pages: pages,
        last_page: last_page,
      }
      erb :index, locals: locals
    end

    get '/robots.txt' do
      halt(404)
    end

    get '/register', set_name: true do
      erb :register
    end

    post '/register' do
      name = params[:name] || ''
      pw   = params[:password] || ''
      halt(400) if (name == '') || (pw == '')

      user_id = register(name, pw)
      session[:user_id] = user_id

      redirect_found '/'
    end

    get '/login', set_name: true do
      locals = {
        action: 'login',
      }
      erb :authenticate, locals: locals
    end

    post '/login' do
      name = params[:name]
      user = db.xquery(%| select id,salt,password from user where name = ? LIMIT 1 |, name).first
      halt(403) unless user
      halt(403) unless user[:password] == encode_with_salt(password: params[:password], salt: user[:salt])

      session[:user_id] = user[:id]

      redirect_found '/'
    end

    get '/logout' do
      session[:user_id] = nil
      redirect_found '/'
    end

    post '/keyword', set_name: true, authenticate: true do
      keyword = params[:keyword] || ''
      halt(400) if keyword == ''
      description = params[:description]
      halt(400) if is_spam_content(description) || is_spam_content(keyword)

      bound = [@user_id, keyword, description, keyword.length] * 2
      db.xquery(%|
        INSERT INTO entry (author_id, keyword, description, created_at, updated_at, keyword_length)
        VALUES (?, ?, ?, NOW(), NOW(), ?)
        ON DUPLICATE KEY UPDATE
        author_id = ?, keyword = ?, description = ?, updated_at = NOW(), keyword_length = ?
      |, *bound)

      reset_and_get(keyword, keyword.size)
      redirect_found '/'
    end

    get '/keyword/:keyword', set_name: true do
      keyword = params[:keyword] or halt(400)

      entry = db.xquery(%| select keyword,description from entry where keyword = ? |, keyword).first or halt(404)
      keywords = db.xquery(%| select keyword from entry order by keyword_length desc |)
      pattern = keywords.map {|k| Regexp.escape(k[:keyword]) }.join('|')

      pattern = build_keyword_pattern
      entry[:stars] = load_stars(entry[:keyword])
      entry[:html] = htmlify(entry[:description], pattern)

      locals = {
        entry: entry,
      }
      erb :keyword, locals: locals
    end

    post '/keyword/:keyword', set_name: true, authenticate: true do
      keyword = params[:keyword] or halt(400)
      is_delete = params[:delete] or halt(400)

      unless db.xquery(%| SELECT keyword FROM entry WHERE keyword = ? |, keyword).first
        halt(404)
      end

      db.xquery(%| DELETE FROM entry WHERE keyword = ? |, keyword)

      delete_and_reset(keyword.size)
      redirect_found '/'
    end

    get '/stars' do
      keyword = params[:keyword] || ''
      stars = isutar_db.xquery(%| select * from star where keyword = ? |, keyword).to_a

      content_type :json
      JSON.generate(stars: stars)
    end

    post '/stars' do
      keyword = params[:keyword] or halt(404)
      db.xquery(%| select keyword from entry where keyword = ? |, keyword).first or halt(404)

      user_name = params[:user]
      isutar_db.xquery(%|
        INSERT INTO star (keyword, user_name, created_at)
        VALUES (?, ?, NOW())
      |, keyword, user_name)

      content_type :json
      JSON.generate(result: 'ok')
    end
  end
end
