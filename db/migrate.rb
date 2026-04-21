# db/migrate.rb
require "sequel"
require "logger"

DB = Sequel.connect(ENV["DATABASE_URL"] || "sqlite://waterpark.db")

Sequel.extension :migration
Sequel::Migrator.run(DB, "db/migrations")

puts "✅ Migrations complete!"