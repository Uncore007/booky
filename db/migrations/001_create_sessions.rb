Sequel.migration do
  up do
    create_table :sessions do
      primary_key :id
      String  :name,       null: false
      String  :start_time, null: false
      Integer :capacity,   null: false, default: 50
    end
  end

  down do
    drop_table :sessions
  end
end