# app.rb
require "sinatra"
require "sinatra/reloader" if development?
require "sequel"
require "dotenv/load"

# --- Database ---
DB = Sequel.connect("sqlite://waterpark.db")
Sequel.extension :migration

SESSIONS = DB[:sessions]
BOOKINGS = DB[:bookings]

TICKET_PRICE = 25_00 # $25.00 in cents

# --- Helpers ---
helpers do
  def spots_taken(session_id)
    BOOKINGS.where(session_id: session_id, status: "paid").sum(:quantity) || 0
  end

  def spots_remaining(session)
    session[:capacity] - spots_taken(session[:id])
  end
end

# --- Routes ---

# get "/" do
#     @sessions = SESSIONS.order(:start_time).all.map do |s|
#         s.merge(spots_remaining: spots_remaining(s))
#     end
#     erb :index
# end

get "/" do
  # Build next 14 available dates
  @dates = (0..13).map { |i| Date.today + i }
  @selected_date = params[:date] && valid_date?(params[:date]) \
    ? Date.parse(params[:date]) \
    : Date.today
  @sessions = SESSIONS.order(:start_time).all.map do |s|
    s.merge(spots_remaining: spots_remaining(s, @selected_date))
  end
  erb :index
end

get "/sessions/availability" do
  halt 400, "Invalid date" unless params[:date] && valid_date?(params[:date])
  @selected_date = Date.parse(params[:date])
  @sessions = SESSIONS.order(:start_time).all.map do |s|
    s.merge(spots_remaining: spots_remaining(s, @selected_date))
  end
  erb :availability, layout: false
end

get "/sessions/:id/book" do
  @session = SESSIONS.first(id: params[:id])
  halt 404, "Session not found" unless @session
  halt 400, "Invalid date" unless params[:date] && valid_date?(params[:date])
  @selected_date = Date.parse(params[:date])
  @spots_remaining = spots_remaining(@session, @selected_date)
  erb :book_form, layout: false
end

post "/bookings" do
  session_id = params[:session_id].to_i
  name       = params[:name].to_s.strip
  email      = params[:email].to_s.strip
  quantity   = params[:quantity].to_i
  date_str   = params[:date].to_s.strip

  @session = SESSIONS.first(id: session_id)
  render_error "Invalid session." unless @session
  render_error "Invalid date." unless valid_date?(date_str)

  booking_date = Date.parse(date_str)

  if name.empty? || email.empty? || quantity < 1
    render_error "Please fill in all fields."
  end

  booking_id = nil

  DB.transaction do
    taken = BOOKINGS
      .where(session_id: session_id, date: booking_date, status: "paid")
      .sum(:quantity) || 0

    remaining = @session[:capacity] - taken
    raise Sequel::Rollback if quantity > remaining

    booking_id = BOOKINGS.insert(
      session_id: session_id,
      date:       booking_date,
      name:       name,
      email:      email,
      quantity:   quantity,
      status:     "pending"
    )
  end

  if booking_id.nil?
    render_error "Sorry, not enough spots remaining — someone just grabbed the last one!"
  end

  require "stripe"
  Stripe.api_key = ENV["STRIPE_SECRET_KEY"]

  begin
    checkout = Stripe::Checkout::Session.create(
      payment_method_types: ["card"],
      customer_email:       email,
      line_items: [{
        price_data: {
          currency:     "usd",
          unit_amount:  TICKET_PRICE,
          product_data: {
            name: "Water Park Ticket — #{@session[:name]}, #{booking_date.strftime("%b %d")}",
          },
        },
        quantity: quantity,
      }],
      mode:        "payment",
      success_url: "#{request.base_url}/bookings/#{booking_id}/confirmation?stripe_session_id={CHECKOUT_SESSION_ID}",
      cancel_url:  "#{request.base_url}/bookings/cancel?stripe_session_id={CHECKOUT_SESSION_ID}",
      metadata: { booking_id: booking_id }
    )
  rescue Stripe::StripeError => e
    render_error "Payment setup failed: #{e.message}"
  end

  redirect checkout.url, 303
end

get "/bookings/:id/confirmation" do
  @booking = BOOKINGS.first(id: params[:id])
  render_error "Booking not found.", 404 unless @booking

  if @booking[:status] == "pending" && params[:stripe_session_id]
    require "stripe"
    Stripe.api_key = ENV["STRIPE_SECRET_KEY"]

    begin
      checkout = Stripe::Checkout::Session.retrieve(params[:stripe_session_id])

      if checkout.payment_status == "paid"
        BOOKINGS.where(id: @booking[:id]).update(
          status:            "paid",
          stripe_payment_id: checkout.payment_intent
        )
        @booking = BOOKINGS.first(id: @booking[:id])
      end
    rescue Stripe::StripeError => e
      render_error "Could not verify payment: #{e.message}"
    end
  end

  @session = SESSIONS.first(id: @booking[:session_id])
  erb :confirmation
end

# Called automatically by HTMX every 30s alongside the availability poll
get "/bookings/cleanup" do
  BOOKINGS
    .where(status: "pending")
    .where { created_at < Time.now - (15 * 60) }
    .update(status: "expired")
  200
end

get "/bookings/cancel" do
  stripe_session_id = params[:stripe_session_id]

  if stripe_session_id
    require "stripe"
    Stripe.api_key = ENV["STRIPE_SECRET_KEY"]

    begin
      checkout = Stripe::Checkout::Session.retrieve(stripe_session_id)
      booking_id = checkout.metadata["booking_id"].to_i

      BOOKINGS
        .where(id: booking_id, status: "pending")
        .update(status: "expired")
    rescue Stripe::StripeError
      # If Stripe lookup fails, the 15 min expiry will clean it up anyway
    end
  end

  redirect "/?cancelled=true"
end

helpers do
  def render_error(message, status = 400)
    @error = message
    halt status, erb(:error, layout: false)
  end

  def spots_taken(session_id, date)
    paid = BOOKINGS
      .where(session_id: session_id, date: date, status: "paid")
      .sum(:quantity) || 0

    pending = BOOKINGS
      .where(session_id: session_id, date: date, status: "pending")
      .where { created_at > Time.now - (15 * 60) }
      .sum(:quantity) || 0

    paid + pending
  end

  def spots_remaining(session, date)
    session[:capacity] - spots_taken(session[:id], date)
  end

  def valid_date?(date_str)
    date = Date.parse(date_str)
    date >= Date.today && date <= Date.today + 60
  rescue
    false
  end
end