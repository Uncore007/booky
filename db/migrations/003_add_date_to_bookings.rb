Sequel.migration do
  up do
    alter_table :bookings do
      add_column :date, Date, null: true
    end
  end

  down do
    alter_table :bookings do
      drop_column :date
    end
  end
end