# frozen_string_literal: true

control 'event_remove_varbindsdecode' do
  title 'OpenNMS Event Remove Varbindsdecode Validation'

  describe opennms_event('uei.opennms.org/cheftest/thresholdExceeded2-event_remove_varbindsdecode', 'events/chef.events.xml') do
    it { should exist }

    it 'does not contain any varbind decoding configurations' do
      raw_decode = subject['varbindsdecode']
      expect(raw_decode == nil || raw_decode.empty?).to be true
    end
  end
end
