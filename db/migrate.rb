# db/migrate.rb
require "sequel"
require "logger"

DB = Sequel.connect("sqlite://waterpark.db", logger: Logger.new($stdout))

Sequel.extension :migration
Sequel::Migrator.run(DB, "db/migrations")

puts "✅ Migrations complete!"