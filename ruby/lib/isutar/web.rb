require 'json'
require 'net/http'
require 'uri'

require 'mysql2'
require 'mysql2-cs-bind'
require 'rack/utils'
require 'sinatra/base'
require 'rack-lineprof' unless ENV['RACK_ENV'] == 'production'

module Isutar
  class Web < ::Sinatra::Base
    enable :protection

    use Rack::Lineprof unless ENV['RACK_ENV'] == 'production'

    set :db_user, ENV['ISUTAR_DB_USER'] || 'root'
    set :db_password, ENV['ISUTAR_DB_PASSWORD'] || ''
    set :dsn, ENV['ISUTAR_DSN'] || 'dbi:mysql:db=isutar'
    set :isuda_origin, ENV['ISUDA_ORIGIN'] || 'http://localhost:5000'

    configure :development do
      require 'sinatra/reloader'

      register Sinatra::Reloader
    end

    helpers do
      def isuda_db
        Thread.current[:isuda_db] ||=
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

      def db
        Thread.current[:db] ||=
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
      end
    end

    get '/initialize' do
      db.xquery('TRUNCATE star')

      content_type :json
      JSON.generate(result: 'ok')
    end

    get '/stars' do
      keyword = params[:keyword] || ''
      stars = db.xquery(%| select * from star where keyword = ? |, keyword).to_a

      content_type :json
      JSON.generate(stars: stars)
    end

    post '/stars' do
      keyword = params[:keyword] or halt(404)
      isuda_db.xquery(%| select keyword from entry where keyword = ? |, keyword).first or halt(404)

      user_name = params[:user]
      db.xquery(%|
        INSERT INTO star (keyword, user_name, created_at)
        VALUES (?, ?, NOW())
      |, keyword, user_name)

      content_type :json
      JSON.generate(result: 'ok')
    end
  end
end
