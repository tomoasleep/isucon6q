#!/usr/bin/env ruby

# You must install ltsv gem to run this script.
# Also, you must install mustermann gem when you use `--group` option.
require 'ltsv'
require 'optparse'
require 'time'

class Group
  def self.header
    "total_time avg_time count method status uri"
  end

  attr_reader :route, :request_method, :status, :count, :total_time
  def initialize(route, request_method, status)
    @route = route
    @request_method = request_method
    @status = status
    @count = 0
    @total_time = 0.0
  end

  def add(time)
    @count += 1
    @total_time += time.to_f
    @avg_time = nil
    self
  end

  def avg_time
    @avg_time ||= total_time / count
  end

  def to_s
    "#{round_to_s(total_time, 2).rjust(10)} #{round_to_s(avg_time, 3).rjust(8)} #{count.to_s.rjust(5)} #{request_method.rjust(6)} #{status.rjust(6)} #{route}"
  end

  def round_to_s(v, n)
    a, b = v.round(n).to_s.split('.')
    "#{a}.#{b.ljust(n, '0')}"
  end
end

class GroupTable
  def initialize(rows, options = {})
    @table = rows.each.with_object({}) do |row, table|
      key = resolve_key(row, options)

      table[key] ||= Group.new(key[:route], key[:request_method], key[:status])
      table[key].add(row[:request_time])
    end
  end

  def resolve_key(row, options = {})
    request_uri = row[:request_uri]
    matchers = options[:group][row[:request_method]] || []
    route_name = matchers.lazy.map { |m| m.to_s if m.match(request_uri) }.find { |m| m } || request_uri

    { route: route_name, request_method: row[:request_method], status: row[:status] }
  end

  def values
    @values ||= @table.values
  end

  def header
    Group.header
  end

  def to_report_str(limit: nil, &blk)
    (values.sort_by(&blk).reverse)[limit ? 0..(limit - 1) : 0..-1].map(&:to_s)
  end
end

def parse(argv)
  options = {}
  options[:group] ||= {}
  opt = OptionParser.new

  opt.on('--since DATETIME') { |v| options[:since] = Time.parse(v) }
  opt.on('--match REGEXP') { |v| options[:match] = Regexp.new(v) }
  opt.on('--limit COUNT') { |v| options[:limit] = v.to_i }
  opt.on('--group GROUP_EXPR') do |v|
    require 'mustermann'
    verb, path = v.split(' ')
    verb, path = 'GET', verb unless path

    options[:group][verb] ||= []
    options[:group][verb] << Mustermann.new(path)
  end
  opt.parse!(argv)

  options[:filename] = argv[0]
  options
end

options = parse(ARGV)
rows = LTSV.parse(options[:filename] ? File.open(options[:filename]) : STDIN)

rows.each do |row|
  row[:request_time] = row[:request_time].to_f if row[:request_time]
  row[:body_bytes_sent] = row[:body_bytes_sent].to_i if row[:body_bytes_sent]
end

rows.select! { |row| Time.parse(row[:time]) >= options[:since] rescue false } if options[:since]
rows.select! { |row| row[:request_uri].match(options[:match]) } if options[:match]

table = GroupTable.new(rows, options)

puts "sort by total time"
puts table.header
puts table.to_report_str(limit: options[:limit]) { |a| a.total_time }

puts ""
puts "----------------------------"
puts "sort by avg time"
puts table.header
puts table.to_report_str(limit: options[:limit]) { |a| a.avg_time }

puts ""
puts "----------------------------"
puts "sort by count"
puts table.header
puts table.to_report_str(limit: options[:limit]) { |a| a.count }
