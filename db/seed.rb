# db/seed.rb
require "sequel"
require "logger"

DB = Sequel.connect("sqlite://waterpark.db", logger: Logger.new($stdout))

# Clear existing sessions (safe to re-run)
DB[:sessions].delete

DB[:sessions].multi_insert([
  { name: "9:00 AM",  start_time: "09:00:00", capacity: 50 },
  { name: "11:00 AM", start_time: "11:00:00", capacity: 50 },
  { name: "1:00 PM",  start_time: "13:00:00", capacity: 50 },
  { name: "3:00 PM",  start_time: "15:00:00", capacity: 50 },
])

puts "✅ Sessions seeded!"
DB[:sessions].each { |s| puts "  #{s[:id]}: #{s[:name]}" }