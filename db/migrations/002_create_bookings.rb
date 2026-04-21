Sequel.migration do
  up do
    create_table :bookings do
      primary_key :id
      foreign_key :session_id, :sessions, null: false
      String   :name,              null: false
      String   :email,             null: false
      Integer  :quantity,          null: false, default: 1
      String   :stripe_payment_id
      String   :status,            null: false, default: "pending"
      DateTime :created_at,        default: Sequel::CURRENT_TIMESTAMP
    end
  end

  down do
    drop_table :bookings
  end
end