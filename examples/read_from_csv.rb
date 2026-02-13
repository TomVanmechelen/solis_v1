# $LOAD_PATH << '.' << './lib'
require 'bundler'
Bundler.require

require_relative '/app/lib/solis.rb'

Solis::ConfigFile.path = Dir.pwd
model_key = Solis::ConfigFile[:solis][:env][:graph_prefix].to_sym
dir = Solis::ConfigFile[:csv][:dir]
s = Solis::Shape::Reader::CSV.read(dir, Solis::ConfigFile[:csv][:model_id], from_cache: false)

#File.open("./data/#{model_key}.sql", 'wb') { |f| f.puts s[:sql] }
#File.open("./data/#{model_key}.json", 'wb') { |f| f.puts s[:inflections] }
#File.open("./data/#{model_key}_shacl.ttl", 'wb') { |f| f.puts s[:shacl] }
File.open("./data/#{model_key}_schema.ttl", 'wb') { |f| f.puts s[:schema] }
#File.open("./data/#{model_key}.puml", 'wb') { |f| f.puts s[:plantuml] }
#File.open("./data/#{model_key}_erd.puml", 'wb') { |f| f.puts s[:plantuml_erd] }

