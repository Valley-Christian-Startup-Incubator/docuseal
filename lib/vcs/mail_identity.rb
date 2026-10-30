# frozen_string_literal: true
module Vcs
  module MailIdentity
    module_function
    def apply(mail, key)
      digest = Digest::SHA256.hexdigest(key)
      mail.message_id = "#{digest}@sign.valleychristianai.com"
      mail['X-Message-Uuid'] = digest
      mail['X-Resend-Idempotency-Key'] = key
      metadata = mail.instance_variable_get(:@message_metadata) || {}
      mail.instance_variable_set(:@message_metadata, metadata.merge('idempotency_key' => key))
      mail
    end
  end
end
