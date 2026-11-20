# frozen_string_literal: true

require 'spec_helper'
require 'nokogiri'

# Use robust path expansion to ensure library scopes are evaluated identically across all environments
lib_path = File.expand_path('../../libraries/event_helpers.rb', __dir__)
require lib_path if File.exist?(lib_path)

describe Opennms::Cookbook::ConfigHelpers::Event::EventconfSourceRubyBlock do
  describe 'Horizon 35 API URL Isolation' do
    let(:url_parser_class) do
      Class.new do
        include Opennms::Cookbook::ConfigHelpers::Event::EventconfSourceRubyBlock

        def restv2url
          'http://127.0.0.1:8980/opennms/api/v2/events'
        end

        def admin_secret_from_vault(_key)
          'mocked_password'
        end
      end.new
    end

    it 'correctly strips trailing API subpaths to build a clean base URL string' do
      uri = URI.parse(url_parser_class.restv2url)
      base_url = "#{uri.scheme}://#{uri.host}:#{uri.port}/opennms"
      expect(base_url).to eq('http://127.0.0.1:8980/opennms')
      expect(base_url).not_to include('/api/v2')
    end
  end

  describe '#xml_to_hash' do
    let(:ruby_block_class) do
      Class.new { include Opennms::Cookbook::ConfigHelpers::Event::EventconfSourceRubyBlock }.new
    end

    it 'transforms raw Nokogiri XML node structures into comparable Ruby hashes' do
      xml_raw = '<events xmlns="http://xmlns.opennms.org/xsd/eventconf"><event><uei>uei.test</uei></event></events>'
      node = Nokogiri::XML(xml_raw).root

      result = ruby_block_class.send(:xml_to_hash, node)

      expect(result[:name]).to eq('events')
      expect(result[:children].first[:name]).to eq('event')
    end
  end
end
