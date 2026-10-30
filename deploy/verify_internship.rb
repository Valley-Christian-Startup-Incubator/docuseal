# frozen_string_literal: true

raise 'Use an isolated database' unless ENV['VCS_ISOLATED_TEST'] == 'true'
require 'nokogiri'
require 'sidekiq/testing'
Sidekiq::Testing.fake!
SendSubmitterInvitationEmailJob.clear
ActionController::Base.allow_forgery_protection = true

checks = 0
verify = lambda do |name, &block|
  raise "FAIL #{name}" unless block.call
  checks += 1
  puts "PASS #{name}"
end
config = Vcs::InternshipPacket.configuration
template = Vcs::InternshipPacket.template_for(config)
raise 'Provision the isolated internship packet first' unless template
unless EncryptedConfig.exists?(account: template.account, key: EncryptedConfig::ESIGN_CERTS_KEY)
  EncryptedConfig.create!(account: template.account, key: EncryptedConfig::ESIGN_CERTS_KEY,
                          value: GenerateCertificate.call('Isolated internship verification').transform_values(&:to_pem))
end
verify.call('packet has three original documents and 58 mapped fields') { template.schema.size == 3 && template.fields.size == 58 }
verify.call('packet has no public shared signing link') { !template.shared_link? }
verify.call('repeated names and signatures share field values across documents') do
  template.fields.select { |field| field.dig('preferences', 'vcs_identity') == 'name' }
          .count { |field| field['areas'].size > 1 } >= 3
end
session = ActionDispatch::Integration::Session.new(Rails.application)
session.host! 'localhost'
session.https!
session.get('/internship')
verify.call('anonymous visitor gets the intake form') { session.response.status == 200 && session.response.body.include?('Start my packet') }
verify.call('intake prevents caching indexing and referrer disclosure') do
  session.response.headers['Cache-Control'].include?('no-store') &&
    session.response.headers['X-Robots-Tag'] == 'noindex, nofollow' && session.response.headers['Referrer-Policy'] == 'same-origin'
end
verify.call('public intake does not request SSN or birth date') { !session.response.body.include?('Social Security') && !session.response.body.include?('birth_date') }
form = Nokogiri::HTML(session.response.body)
token = form.at_css('input[name="form_token"]')['value']
csrf = form.at_css('input[name="authenticity_token"]')['value']
suffix = SecureRandom.hex(5)
intake = { student_name: 'Synthetic Student', student_email: "student-#{suffix}@example.invalid",
           parent_name: 'Synthetic Parent', parent_email: "parent-#{suffix}@example.invalid",
           host_name: 'Synthetic Host', host_email: "host-#{suffix}@example.invalid",
           host_organization: 'Synthetic employer', host_title: 'Supervisor' }
before = template.submissions.count
session.post('/internship', params: { intake: intake.merge(parent_email: intake[:student_email]), form_token: token, authenticity_token: csrf })
verify.call('participant emails must be distinct') { session.response.status == 422 && template.submissions.count == before }
session.post('/internship', params: { intake: intake.merge(host_email: config.value['school_email']), form_token: token, authenticity_token: csrf })
verify.call('participant cannot assume the school signer address') { session.response.status == 422 && template.submissions.count == before }
expired = Rails.application.message_verifier(Vcs::InternshipPacket::TOKEN_PURPOSE).generate(
  { 'nonce' => SecureRandom.uuid, 'session_key' => 'expired' }, purpose: Vcs::InternshipPacket::TOKEN_PURPOSE, expires_at: 1.minute.ago
)
[token + 'tampered', expired].each do |invalid|
  session.post('/internship', params: { intake:, form_token: invalid, authenticity_token: csrf })
  verify.call('invalid or expired start token cannot create a packet') { session.response.status == 422 && template.submissions.count == before }
end
session.post('/internship', params: { intake:, form_token: token })
verify.call('missing CSRF token cannot create a packet') { session.response.status == 422 && template.submissions.count == before }
other = ActionDispatch::Integration::Session.new(Rails.application)
other.host! 'localhost'
other.https!
other.get('/internship')
other_csrf = Nokogiri::HTML(other.response.body).at_css('input[name="authenticity_token"]')['value']
other.post('/internship', params: { intake:, form_token: token, authenticity_token: other_csrf })
verify.call('start token is bound to the originating browser session') { other.response.status == 422 && template.submissions.count == before }
session.post('/internship', params: { intake:, form_token: token, authenticity_token: csrf,
                                    school_email: intake[:student_email], template_id: 0 })
verify.call('valid intake starts a private packet without an account') { session.response.status == 303 && template.submissions.count == before + 1 }
location = session.response.location
submission = template.submissions.order(:id).last
roles = submission.submitters.index_by { |person| person.metadata['vcs_role'] }
verify.call('school signer cannot be overridden by public input') { roles.fetch('school').email == config.value['school_email'] }
verify.call('each recipient requires email verification') { roles.values.all? { |person| person.preferences['require_email_2fa'] == true } }
verify.call('initial creation sends no invitations') { roles.values.all? { |person| person.sent_at.nil? } && SendSubmitterInvitationEmailJob.jobs.empty? }
session.post('/internship', params: { intake:, form_token: token, authenticity_token: csrf })
verify.call('double submission returns the same packet') { template.submissions.count == before + 1 && session.response.location == location }
session.get(URI(location).request_uri)
verify.call('first private link reaches email verification directly') { session.response.status == 200 && !session.response.body.include?('<submission-form') && session.response.body.include?('email_2fa') }
student = roles.fetch('student')
session.put("/s/#{student.slug}", params: { completed: 'true', authenticity_token: csrf })
verify.call('unverified recipient cannot submit document values') { session.response.status == 422 && !student.reload.completed_at? }

authenticate = lambda do |person|
  browser = ActionDispatch::Integration::Session.new(Rails.application)
  browser.host! 'localhost'
  browser.https!
  browser.get("/s/#{person.slug}")
  csrf_token = Nokogiri::HTML(browser.response.body).at_css('meta[name="csrf-token"]')['content']
  code = OtpChallenges.generate("#{person.email.downcase}:#{person.slug}", purpose: 'form_email_2fa')
  browser.post('/submit_form_email_2fa', params: { submitter_slug: person.slug, one_time_code: code, authenticity_token: csrf_token })
  [browser, csrf_token]
end
school_browser, school_csrf = authenticate.call(roles.fetch('school'))
school_browser.put("/s/#{roles.fetch('school').slug}", params: { completed: 'true', authenticity_token: school_csrf })
verify.call('direct authenticated request cannot sign out of order') { school_browser.response.status == 422 && !roles.fetch('school').reload.completed_at? }
student_browser, student_csrf = authenticate.call(student)
student_browser.get("/s/#{student.slug}")
verify.call('verified student reaches the real signing form') { student_browser.response.status == 200 && student_browser.response.body.include?('<submission-form') }
foreign_field = template.fields.find { |field| field['submitter_uuid'] == roles.fetch('school').uuid && !field['readonly'] }
student_browser.put("/s/#{student.slug}", params: { values: { foreign_field['uuid'] => 'Forged' }, authenticity_token: student_csrf })
verify.call('student cannot fill a school field') { student_browser.response.status == 422 && !student.reload.values.key?(foreign_field['uuid']) }

roles.each do |kind, person|
  browser, csrf_token = authenticate.call(person)
  signature = Vips::Image.text("Synthetic #{kind}", font: 'sans 28').pngsave_buffer
  person.attachments.attach(io: StringIO.new(signature), filename: 'synthetic-signature.png', content_type: 'image/png')
  signature_uuid = person.attachments.reload.last.uuid
  values = template.fields.select { |field| field['submitter_uuid'] == person.uuid && !field['readonly'] }.to_h do |field|
    value = case field['type']
            when 'signature' then signature_uuid
            when 'checkbox' then false
            when 'number' then 4
            when 'date' then '2009-06-01'
            else field.dig('preferences', 'vcs_identity') == 'name' ? "Corrected #{kind.titleize}" : "Synthetic #{field['name']}"
            end
    [field['uuid'], value]
  end
  browser.put("/s/#{person.slug}", params: { values:, completed: 'true', authenticity_token: csrf_token }, as: :json)
  puts "Signing response #{kind}: #{browser.response.status} #{browser.response.body.first(300)}" unless browser.response.status == 200
  verify.call("#{kind} signs only after preceding roles complete") { browser.response.status == 200 && person.reload.completed_at? }
  identity = template.fields.any? { |field| field['submitter_uuid'] == person.uuid && field.dig('preferences', 'vcs_identity') == 'name' }
  verify.call("#{kind} name is detected from completed form") { !identity || person.name == "Corrected #{kind.titleize}" }
  ProcessSubmitterCompletionJob.new.perform('submitter_id' => person.id)
  invited_ids = SendSubmitterInvitationEmailJob.jobs.map { |job| job['args'].first['submitter_id'] }
  if kind == 'student'
    verify.call('student completion invites parent and host together') { roles.values_at('parent', 'host').all? { |p| invited_ids.include?(p.id) } && !invited_ids.include?(roles.fetch('school').id) }
  elsif kind == 'parent'
    verify.call('school waits for the host as well as the parent') { !invited_ids.include?(roles.fetch('school').id) }
  end
end
verify.call('all signatures complete the submission') { submission.reload.completed_at? }
last = roles.values.last.reload
verify.call('completed packet produces all three PDFs with six pages') do
  last.documents.size == 3 && last.documents.sum { |attachment| HexaPDF::Document.new(io: StringIO.new(attachment.download)).pages.count } == 6
end
verify.call('completed packet has an audit record') { submission.audit_trail.attached? }
outsider = ActionDispatch::Integration::Session.new(Rails.application)
outsider.host! 'localhost'
outsider.https!
outsider.get("/s/#{last.slug}/completed")
verify.call('completed documents remain behind verification') { outsider.response.redirect? && !outsider.response.body.include?('<submission-form') }
if ENV['VCS_INTERNSHIP_OUTPUT_DIR'].present?
  FileUtils.mkdir_p(ENV['VCS_INTERNSHIP_OUTPUT_DIR'])
  last.documents.each_with_index { |attachment, i| File.binwrite(File.join(ENV['VCS_INTERNSHIP_OUTPUT_DIR'], "document-#{i + 1}.pdf"), attachment.download) }
end
puts "#{checks} internship checks passed"
