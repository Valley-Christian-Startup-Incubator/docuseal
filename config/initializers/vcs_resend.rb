# frozen_string_literal: true

require Rails.root.join('lib/vcs/resend_delivery')

ActionMailer::Base.add_delivery_method :resend, Vcs::ResendDelivery
