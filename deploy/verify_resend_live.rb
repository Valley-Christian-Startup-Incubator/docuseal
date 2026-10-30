# frozen_string_literal: true
raise 'Use an isolated database' unless ENV['VCS_ISOLATED_TEST'] == 'true'
key = File.read('/run/resend-api-key').strip
account = Account.order(:id).first
config = EncryptedConfig.find_or_initialize_by(account:, key: 'resend_api')
config.update!(value: { 'api_key' => key, 'from_email' => 'sign@valleychristianai.com' })
message = Mail.new do
  to 'delivered@resend.dev'
  subject 'VCS Sign delivery verification'
  text_part { body 'Synthetic delivery verification. No student or school document data.' }
  html_part do
    content_type 'text/html; charset=UTF-8'
    body '<p>Synthetic VCS Sign delivery verification.</p>'
  end
end
message.attachments['verification.txt'] = 'Synthetic attachment only.'
Vcs::MailIdentity.apply(message, "vcs-delivery-verification-#{SecureRandom.uuid}")
ActionMailerConfigsInterceptor.delivering_email(message)
raise 'Wrong delivery adapter' unless message.delivery_method.is_a?(Vcs::ResendDelivery)
result = message.delivery_method.deliver!(message)
puts "Resend simulator accepted multipart message with attachment. Receipt #{result.fetch('id')}."
