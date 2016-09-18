require 'mysql2'
require 'mysql2-cs-bind'

def isuda_db
  Thread.current[:db] ||=
    begin
      mysql = Mysql2::Client.new(
        username: ENV['RACK_ENV'] == 'production' ? 'isucon' : 'root',
        password: ENV['RACK_ENV'] == 'production' ? 'isucon' : nil,
        database: 'isuda',
        encoding: 'utf8mb4',
        init_command: %|SET SESSION sql_mode='TRADITIONAL,NO_AUTO_VALUE_ON_ZERO,ONLY_FULL_GROUP_BY'|,
      )
      mysql.query_options.update(symbolize_keys: true)
      mysql
    end
end
  
fetch_sql = <<-SQL
select *
from entry;
SQL

insert_sql = <<-SQL
INSERT INTO entry (author_id, keyword, description, created_at, updated_at, keyword_length)
  VALUES  (?, ?, ?, ?, ?, ?)
  ON DUPLICATE KEY UPDATE
  keyword = ?, keyword_length = ?
SQL

bound = []
isuda_db.prepare(fetch_sql).execute.each do |row|

  bound = [row[:author_id],
           row[:keyword],
           row[:description],
           row[:created_at],
           row[:updated_at],
           row[:keyword].length]
  bound += [row[:keyword], row[:keyword].length]
  isuda_db.xquery(insert_sql, *bound)
end
