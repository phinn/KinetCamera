# 探测+建档:EXISTS 直接退出;有权限则建档;403=AccessForbidden;名字冲突=NAME_TAKEN;其它=APIError
require 'spaceship'
filepath = File.expand_path('~/.appstoreconnect/private_keys/AuthKey_WGY2HCFK9K.p8')
client = Spaceship::ConnectAPI::Client.auth(key_id: 'WGY2HCFK9K', issuer_id: 'd4da77ce-6781-4aef-acdd-c7480df892d5', filepath: filepath)
Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.create(key_id: 'WGY2HCFK9K', issuer_id: 'd4da77ce-6781-4aef-acdd-c7480df892d5', filepath: filepath)
app = Spaceship::ConnectAPI::App.find('com.kinetai.kinetbend')
if app
  puts "EXISTS id=#{app.id} name=#{app.name}"
  exit 0
end
begin
  app = Spaceship::ConnectAPI::App.create(
    name: 'KinetBend: Bender Calculator',
    version_string: '1.0.0',
    sku: 'KINETBEND001',
    primary_locale: 'en-US',
    bundle_id: 'com.kinetai.kinetbend',
    platforms: ['IOS']
  )
  puts "CREATED id=#{app.id}"
rescue Spaceship::AccessForbiddenError
  puts "AccessForbidden: key lacks CREATE"
  exit 1
rescue Spaceship::Client::APIError => e
  msg = e.message.lines[0].to_s.strip
  status = e.http_status rescue nil
  if [409, 422].include?(status) || msg =~ /name.*(already|in use|not available)|INVALID_APP_NAME/i
    puts "NAME_TAKEN: #{status} #{msg}"
    exit 4
  end
  puts "APIError: #{status} #{msg}"
  exit 5
end
