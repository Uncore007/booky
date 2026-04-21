require "sequel"

DB = Sequel.connect(ENV["DATABASE_URL"] || "sqlite://waterpark.db")

# Only seed if sessions table is empty
if DB[:sessions].count == 0
  DB[:sessions].multi_insert([
    { name: "9:00 AM",  start_time: "09:00:00", capacity: 50 },
    { name: "11:00 AM", start_time: "11:00:00", capacity: 50 },
    { name: "1:00 PM",  start_time: "13:00:00", capacity: 50 },
    { name: "3:00 PM",  start_time: "15:00:00", capacity: 50 },
  ])
  puts "✅ Sessions seeded!"
  DB[:sessions].each { |s| puts "  #{s[:id]}: #{s[:name]}" }
else
  puts "⏭️  Sessions already exist, skipping seed."
end