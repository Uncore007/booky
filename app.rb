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

get "/" do
    @sessions = SESSIONS.order(:start_time).all.map do |s|
        s.merge(spots_remaining: spots_remaining(s))
    end
    erb :index
end

# HTMX: returns a fresh availability fragment
get "/sessions/availability" do
  @sessions = SESSIONS.order(:start_time).all.map do |s|
    s.merge(spots_remaining: spots_remaining(s))
  end
  erb :availability, layout: false
end

# HTMX: returns the booking form for a chosen session
get "/sessions/:id/book" do
  @session = SESSIONS.first(id: params[:id])
  halt 404, "Session not found" unless @session
  @spots_remaining = spots_remaining(@session)
  erb :book_form, layout: false
end

# Handle form submission — create a pending booking, then redirect to Stripe
post "/bookings" do
  session_id = params[:session_id].to_i
  name       = params[:name].to_s.strip
  email      = params[:email].to_s.strip
  quantity   = params[:quantity].to_i

  @session = SESSIONS.first(id: session_id)
  render_error "Invalid session." unless @session

  if name.empty? || email.empty? || quantity < 1
    render_error "Please fill in all fields."
  end

  booking_id = nil

  DB.transaction do
    taken = BOOKINGS
      .where(session_id: session_id, status: "paid")
      .sum(:quantity) || 0

    remaining = @session[:capacity] - taken

    raise Sequel::Rollback if quantity > remaining

    booking_id = BOOKINGS.insert(
      session_id: session_id,
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
            name: "Water Park Ticket — #{@session[:name]}",
          },
        },
        quantity: quantity,
      }],
      mode:        "payment",
      success_url: "#{request.base_url}/bookings/#{booking_id}/confirmation?stripe_session_id={CHECKOUT_SESSION_ID}",
      cancel_url: "#{request.base_url}/bookings/cancel?stripe_session_id={CHECKOUT_SESSION_ID}",
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

  def spots_taken(session_id)
    paid = BOOKINGS
      .where(session_id: session_id, status: "paid")
      .sum(:quantity) || 0

    # Count pending bookings less than 15 minutes old as held spots
    pending = BOOKINGS
      .where(session_id: session_id, status: "pending")
      .where { created_at > Time.now - (15 * 60) }
      .sum(:quantity) || 0

    paid + pending
  end

  def spots_remaining(session)
    session[:capacity] - spots_taken(session[:id])
  end
end