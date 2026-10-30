# frozen_string_literal: true

Rails.application.config.filter_parameters += %i[password token otp_attempt passw secret token _key crypt salt
                                                 certificate otp ssn file cvv cvc]

Rails.application.config.filter_parameters += [:auth_token, :one_time_code, :vcs_embed_token]
Rails.application.config.filter_parameters += [:api_key]

Rails.application.config.filter_parameters += [:intake, :values, :birth_date, :social_security_number]
