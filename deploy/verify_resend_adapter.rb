require 'mail'
require_relative '../lib/vcs/resend_delivery'

def assert(value, message)
  raise message unless value
end

mail = Mail.new do
  from 'Original <original@example.com>'
  to ['first@example.com', 'second@example.com']
  cc 'copy@example.com'
  bcc 'private@example.com'
  reply_to 'replies@example.com'
  subject 'A document to sign'
  message_id 'original-id@example.com'
  text_part { body 'Plain message' }
  html_part do
    content_type 'text/html; charset=UTF-8'
    body '<p>HTML message</p><img src="cid:logo@example.com">'
  end
end
mail['X-Message-Uuid'] = 'stable-uuid'
mail.attachments['document.pdf'] = { mime_type: 'application/pdf', content: "\x00\xffPDF".b }
mail.attachments.inline['logo.png'] = { mime_type: 'image/png', content: 'PNG', content_id: '<logo@example.com>' }
mail.instance_variable_set(:@message_metadata, { 'idempotency_key' => 'job-1/invitation/1' })

requests = []
response = Net::HTTPOK.new('1.1', '200', 'OK')
response.define_singleton_method(:body) { '{"id":"resend-receipt"}' }
http = Object.new
http.define_singleton_method(:request) do |request|
  requests << request
  response
end
Net::HTTP.define_singleton_method(:start) { |*args, **kwargs, &block| block.call(http) }

delivery = Vcs::ResendDelivery.new(api_key: 'test-key', from_email: 'Workspace <verified@example.com>')
assert(delivery.deliver!(mail)['id'] == 'resend-receipt', 'Receipt missing')
delivery.deliver!(mail)
payload = JSON.parse(requests.first.body)
assert(payload['to'] == ['first@example.com', 'second@example.com'], 'To recipients lost')
assert(payload['cc'] == ['copy@example.com'], 'Cc recipients lost')
assert(payload['bcc'] == ['private@example.com'], 'Bcc recipients lost')
assert(payload['reply_to'] == ['replies@example.com'], 'Reply-To lost')
assert(payload['from'] == 'Workspace <verified@example.com>', 'Configured sender ignored')
assert(payload['headers']['Message-ID'] == '<original-id@example.com>', 'Original Message-ID changed')
assert(payload['text'].include?('Plain message') && payload['html'].include?('HTML message'), 'MIME body lost')
assert(payload['attachments'].size == 2, 'Attachment missing')
assert(Base64.strict_decode64(payload['attachments'].first['content']) == "\x00\xffPDF".b, 'Binary attachment corrupted')
assert(payload['attachments'].last['content_id'] == 'logo@example.com', 'Inline CID lost')
assert(requests.first['Idempotency-Key'] == requests.last['Idempotency-Key'], 'Retry key changed')
assert(requests.first.body == requests.last.body, 'Retry payload changed')

response = Net::HTTPUnprocessableEntity.new('1.1', '422', 'Unprocessable')
response.define_singleton_method(:body) { 'test-key private@example.com sensitive response' }
begin
  delivery.deliver!(mail)
  raise 'Rejected request did not fail'
rescue Vcs::ResendDelivery::DeliveryError => error
  assert(error.message == 'Resend rejected email delivery (HTTP 422)', 'Error contains server content')
end
puts 'PASS recipients, sender, MIME bodies, PDF bytes, inline CID, headers, stable retries, sanitized HTTP failure'
