raise 'Use an isolated database' unless ENV['VCS_ISOLATED_TEST'] == 'true'
checks = 0
verify = lambda do |name, &block|
  raise "FAIL #{name}" unless block.call
  checks += 1
  puts "PASS #{name}"
end
account = Account.create!(name: 'Embed isolated checks', locale: 'en', timezone: 'UTC')
user = User.create!(account:, email: "embed-#{SecureRandom.hex(8)}@example.invalid", password: 'SyntheticCheck123!')
viewer = User.create!(account:, email: "viewer-#{SecureRandom.hex(8)}@example.invalid", password: 'SyntheticCheck123!', role: User::VIEWER_ROLE)
template = Template.create!(account:, author: user, name: 'Embed scope', submitters: [{ 'name' => 'Signer', 'uuid' => SecureRandom.uuid }], fields: [], schema: [])
other = Template.create!(account:, author: user, name: 'Other scope', submitters: [], fields: [], schema: [])
origin = 'https://forms.vcs.net'
token = Vcs::EmbedTokens.issue(user:, template:, origin:)
verify.call('signed payload identifies user template and exact origin') { Vcs::EmbedTokens.verify(token) == { 'user_id' => user.id, 'template_id' => template.id, 'origin' => origin } }
verify.call('tampered token denied') { Vcs::EmbedTokens.verify(token + 'tampered').nil? }
expired = Rails.application.message_verifier(Vcs::EmbedTokens::PURPOSE).generate({ 'user_id' => user.id, 'template_id' => template.id, 'origin' => origin }, purpose: Vcs::EmbedTokens::PURPOSE, expires_at: 1.minute.ago)
verify.call('expired token denied') { Vcs::EmbedTokens.verify(expired).nil? }
%w[javascript:alert(1) http://evil.test https://example.com/path https://name:secret@example.com https://example.com?query https://*.example.com https://evil.com;foo https://example.com:999999].each do |bad|
  denied = false
  begin
    Vcs::EmbedTokens.issue(user:, template:, origin: bad)
  rescue ArgumentError
    denied = true
  end
  verify.call("unsafe origin denied #{bad}") { denied }
end
session = ActionDispatch::Integration::Session.new(Rails.application)
session.host!('localhost')
session.get("/embed/builders/#{template.id}")
verify.call('builder missing token denied') { [401, 302].include?(session.response.status) }
session.get("/embed/builders/#{template.id}", params: { token: expired })
verify.call('builder expired token denied') { session.response.status == 401 }
session.get("/embed/builders/#{template.id}", params: { token: })
verify.call('builder opens without login cookie') { session.response.status == 200 && session.response.body.include?('data-fetch-headers') }
verify.call('builder frames only exact authorized origin') { session.response.headers['Content-Security-Policy'].include?("frame-ancestors #{origin}") && session.response.headers['X-Frame-Options'].nil? }
verify.call('builder never leaks referrer') { session.response.headers['Referrer-Policy'] == 'no-referrer' }
headers = { 'X-VCS-Embed-Token' => token }
ActionController::Base.allow_forgery_protection = true
session.patch("/templates/#{template.id}", params: { template: { name: 'Scoped save works' } }, headers:, as: :json)
verify.call('own template saves with scoped token and CSRF enabled') { session.response.status == 200 && template.reload.name == 'Scoped save works' }
session.patch("/templates/#{other.id}", params: { template: { name: 'Denied edit' } }, headers:, as: :json)
verify.call('cross-template edit denied') { session.response.status == 401 && other.reload.name == 'Other scope' }
session.post('/account_configs', params: { account_config: { key: 'test', value: true } }, headers:, as: :json)
verify.call('account-wide route denied') { session.response.status == 401 }
session.get('/settings/profile')
verify.call('bearer token did not persist login') { session.response.status == 302 && session.response.location.include?('sign_in') }
api = ActionDispatch::Integration::Session.new(Rails.application)
api.host!('localhost')
api.post('/api/embed_tokens', params: { template_id: template.id, origin: }, headers: { 'X-Auth-Token' => user.access_token.token }, as: :json)
verify.call('authenticated API issues scoped builder src') { api.response.status == 200 && JSON.parse(api.response.body)['src'].include?("/embed/builders/#{template.id}?token=") }
api.post('/api/embed_tokens', params: { template_id: template.id, origin: }, headers: { 'X-Auth-Token' => viewer.access_token.token }, as: :json)
verify.call('viewer API cannot issue builder token') { api.response.status == 403 }
template.update!(shared_link: true)
session.get("/d/#{template.slug}", params: { embed: '1' })
verify.call('explicit public signer embedding has domain allowlist') { session.response.status == 200 && session.response.headers['Content-Security-Policy'].include?('frame-ancestors https://valleychristianai.com https://*.valleychristianai.com https://vcs.net https://*.vcs.net') && session.response.headers['X-Frame-Options'].nil? }
session.get("/d/#{template.slug}")
verify.call('ordinary public signer retains frame protection') { session.response.headers['X-Frame-Options'].present? }
user.update!(archived_at: Time.current)
session.patch("/templates/#{template.id}", params: { template: { name: 'Denied archived' } }, headers:, as: :json)
verify.call('archived issuer existing token revoked') { session.response.status == 403 }
denied = false
begin
  Vcs::EmbedTokens.issue(user: viewer, template:, origin:)
rescue CanCan::AccessDenied
  denied = true
end
verify.call('viewer cannot issue token') { denied }
puts "#{checks} embedding security checks passed"
