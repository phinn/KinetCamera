# 探测+建档:EXISTS 直接退出;有权限则建档;403 输出 AccessForbidden 给外层识别
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
    name: 'KinetBend — Conduit Bender',
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
end
