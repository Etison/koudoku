module Koudoku::Subscription
  extend ActiveSupport::Concern

  included do

    # We don't store these one-time use tokens, but this is what Stripe provides
    # client-side after storing the credit card information.
    attr_accessor :credit_card_token
    attr_accessor :payment_method_token
    attr_accessor :skip_prorate_plan_changes

    belongs_to :plan

    # update details. Note: to prevent recursive callbacks on the processing method, this callback
    # can be skipped by setting @skip_proccessing_callback
    before_save :processing!, unless: lambda { @skip_proccessing_callback == true }

    def processing!
      # if their package level has changed ..
      if changing_plans?

        prepare_for_plan_change

        # and a customer exists in stripe ..
        if stripe_id.present?

          # fetch the customer.
          customer = Stripe::Customer.retrieve(self.stripe_id)

          # if a new plan has been selected
          if self.plan.present?
            begin
              # Record the new plan pricing.
              self.current_price = self.plan.price

              prepare_for_downgrade if downgrading?
              prepare_for_upgrade if upgrading?

              # updating a default credit card
              update_default_stripe_card

              sub = customer.subscriptions.first
              if sub && sub.trial_end && sub.trial_end > Time.now.to_i
                trial_end = sub.trial_end
                # update package level and adjust trial end to match current subscription trial_end + add starting plan trial
                stripe_plan = Stripe::Plan.retrieve(self.plan.stripe_id)
                if stripe_plan.trial_period_days
                  trial_end = trial_end + stripe_plan.trial_period_days.to_i.days
                end
                opts = {
                  items: [{
                    id: sub.items.data[0].id,
                    plan: self.plan.stripe_id
                  }],
                  trial_end: trial_end
                }
                opts = subscription_options(opts)
                Stripe::Subscription.update(sub.id, opts) if Koudoku.keep_trial_end
              elsif sub
                opts = {
                  items: [{
                    id: sub.items.data[0].id,
                    plan: self.plan.stripe_id
                  }]
                }
                opts[:prorate] = false if skip_prorate_plan_changes
                opts = subscription_options(opts)
                Stripe::Subscription.update(sub.id, opts)
              else
                # update the package level with stripe.
                opts = {
                  customer: customer.id,
                  items: [{ plan: self.plan.stripe_id }]
                }
                opts[:prorate] = false if skip_prorate_plan_changes
                opts = subscription_options(opts)
                Stripe::Subscription.create(opts)
              end

              finalize_downgrade! if downgrading?
              finalize_upgrade! if upgrading?
            rescue Stripe::CardError => card_error
              errors[:base] << card_error.message
              card_was_declined
              throw :abort
            end
          # if no plan has been selected.
          else

            prepare_for_cancelation

            # Remove the current pricing.
            self.current_price = nil

            # delete the subscription. - at_period_end if prorate == false
            begin
              customer.cancel_subscription({:at_period_end => (!Koudoku.prorate).to_s })
            rescue => e
              logger.info "Error Canceling Stripe Subscription: #{e.to_s}"
              # assume already canceled by support
            end

            finalize_cancelation!

          end

        # otherwise
        else
          # if a new plan has been selected
          if self.plan.present?

            # Record the new plan pricing.
            self.current_price = self.plan.price

            prepare_for_new_subscription
            prepare_for_upgrade

            begin

              customer_attributes = {
                description: subscription_owner_description,
                email: subscription_owner_email
              }
              customer_attributes[:card] = credit_card_token if credit_card_token.present?
              customer_attributes[:payment_method] = payment_method_token if payment_method_token.present?

              # If the class we're being included in supports coupons ..
              if respond_to? :coupon
                if coupon.present? and coupon.free_trial?
                  customer_attributes[:trial_end] = coupon.free_trial_ends.to_i
                end
              end

              # create a customer without the plan to start
              customer = Stripe::Customer.create(customer_attributes)
              if payment_method_token.present?
                customer.invoice_settings.default_payment_method = payment_method_token
              end

              # Store the stripe customer id in our db.
              # We do not want this save to trigger the 'processing' method again so force that
              # callback to skip
              @skip_proccessing_callback = true
              self.update_attributes( {
                stripe_id: customer.id,
                last_four: customer.sources.data.select{ |card| card.id == customer.default_source }.first&.last4
              } )
              @skip_proccessing_callback = false

              # now that we have recorded the stripe_id in our system we can setup the subscription in stripe
              customer.plan = plan.stripe_id
              customer.save
            rescue Stripe::CardError => card_error
              errors[:base] << card_error.message
              card_was_declined
              throw :abort
            end

            finalize_new_subscription!
            finalize_upgrade!

          else

            # This should never happen.

            self.plan_id = nil

            # Remove any plan pricing.
            self.current_price = nil

          end

        end

        finalize_plan_change!

      # if they're updating their credit card details.
      elsif self.credit_card_token.present?
        update_default_stripe_card
      elsif self.payment_method_token.present?
        attach_payment_method_to_customer
      end

    end

  end

  module ClassMethods
  end

  def describe_difference(plan_to_describe)
    if plan.nil?
      if persisted?
        "Upgrade"
      else
        if Koudoku.free_trial?
          "Start Trial"
        else
          "Upgrade"
        end
      end
    else
      if plan_to_describe.is_upgrade_from?(plan)
        "Upgrade"
      else
        "Downgrade"
      end
    end
  end

  #
  # Updates the default credit card
  #
  def update_default_stripe_card
    return false unless credit_card_token.present?

    prepare_for_card_update

    # fetch the customer.
    customer = Stripe::Customer.retrieve(self.stripe_id)
    source = customer.sources.create(source: credit_card_token)
    customer.default_source = source.id
    customer.save

    # update the last four based on this new card.
    self.last_four = customer.sources.data.select{ |card| card.id == customer.default_source }.first&.last4

    finalize_card_update!
  rescue Stripe::CardError => card_error
    errors[:base] << card_error.message
    card_was_declined
    return false
  end

  # Pretty sure this wouldn't conflict with anything someone would put in their model
  def subscription_owner
    # Return whatever we belong to.
    # If this object doesn't respond to 'name', please update owner_description.
    send Koudoku.subscriptions_owned_by
  end

  def subscription_owner_description
    # assuming owner responds to name.
    # we should check for whether it responds to this or not.
    "#{subscription_owner.id} - #{subscription_owner.try(:email).to_s} - #{subscription_owner.try(:name).to_s} - #{subscription_owner.try(:phone).to_s}"
  end

  def subscription_owner_email
    "#{subscription_owner.try(:email).to_s}"
  end

  def changing_plans?
    will_save_change_to_plan_id?
  end

  def downgrading?
    plan.present? and plan_id_before_last_save.present? and plan_id_before_last_save > self.plan_id
  end

  def upgrading?
    (plan_id_before_last_save.present? and plan_id_before_last_save < plan_id) or plan_id_before_last_save.nil?
  end

  # CF Template methods.
  def subscription_options(opts = {})
    opts
  end

  def attach_payment_method_to_customer
  end

  # Template methods.
  def prepare_for_plan_change
  end

  def prepare_for_new_subscription
  end

  def prepare_for_upgrade
  end

  def prepare_for_downgrade
  end

  def prepare_for_cancelation
  end

  def prepare_for_card_update
  end

  def finalize_plan_change!
  end

  def finalize_new_subscription!
  end

  def finalize_upgrade!
  end

  def finalize_downgrade!
  end

  def finalize_cancelation!
  end

  def finalize_card_update!
  end

  def card_was_declined
  end

  # stripe web-hook callbacks.
  def payment_succeeded(amount)
  end

  def charge_failed
  end

  def charge_disputed
  end

end
