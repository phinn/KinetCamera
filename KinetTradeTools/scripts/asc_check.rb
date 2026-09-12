# 查 ASC:bundle id 注册状态 + KinetBend app record 是否存在(API Key only)
require 'spaceship'
require 'json'

key_json = '/tmp/asc_key.json'
unless File.exist?(key_json)
  dir = File.expand_path('~/.appstoreconnect/private_keys')
  h = { key_id: 'WGY2HCFK9K', issuer_id: 'd4da77ce-6781-4aef-acdd-c7480df892d5',
        key: File.read(File.join(dir, 'AuthKey_WGY2HCFK9K.p8')), in_house: false, duration: 1200 }
  File.write(key_json, JSON.dump(h))
end

Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.from_json_file(key_json)

bid = 'com.kinetai.kinetbend'
bids = Spaceship::ConnectAPI::BundleId.all.select { |b| b.identifier == bid }
puts "bundle-id registered: #{bids.any?} #{bids.map(&:id).join(',')}"

apps = Spaceship::ConnectAPI::App.all.select { |a| a.bundle_id == bid }
puts "app record exists: #{apps.any?}"
apps.each { |a| puts "  app: #{a.id} #{a.name} #{a.bundle_id}" }
