# frozen_string_literal: true

control 'event_remove_forward' do
  title 'OpenNMS Event Remove Forward Validation'

  describe opennms_event('uei.opennms.org/cheftest/thresholdExceeded2-event_remove_forward', 'events/chef.events.xml') do
    it 'verifies that the event resource is present' do
      expect(subject).to_not be_nil
    end

    it 'does not contain any forward configurations' do
      expect(subject['forward']).to be_nil
    end
  end
end
