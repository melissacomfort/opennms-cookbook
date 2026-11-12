# frozen_string_literal: true

class OpenNmsEventApi < Inspec.resource(1)
  name 'opennms_event'
  attr_reader :raw_event_data, :event_data

  def initialize(uei, file = nil, mask = nil)
    @uei = uei
    @source_variants = if file
                         [
                           file.to_s,
                           file.to_s.sub(%r{^events/}, ''),
                           file.to_s.sub(%r{^events/}, '').sub(/\.xml$/, ''),
                           "#{file.to_s.sub(%r{^events/}, '').sub(/\.events\.xml$/, '')}.events",
                           file.to_s.split('/').last,
                         ]
                       else
                         []
                       end
    @source_variants = @source_variants.uniq

    payload = fetch_live_eventconf_via_api
    all_events = find_all_events(payload)
    matching_events = all_events.select { |e| e.is_a?(Hash) && e['uei'] == uei }

    @raw_event_data = if mask && !matching_events.empty?
                        matching_events.find { |e| e['mask'] == mask } || matching_events.last
                      else
                        matching_events.last
                      end
    @event_data = @raw_event_data
  end

  def exist?
    !raw_event_data.nil? && !raw_event_data.empty?
  end

  def dig(*keys)
    return if raw_event_data.nil?
    OpenNmsDynamicMash.new(raw_event_data).dig(*keys)
  end

  def method_missing(name, *args, &block)
    return exist? if name == :exist? || name == :exists?
    return true if name == :empty? && raw_event_data.nil?
    return false if name == :empty?

    return if raw_event_data.nil?
    OpenNmsDynamicMash.new(raw_event_data).send(name, *args, &block)
  end

  def respond_to_missing?(name, _include_private = false)
    %i(exist? exists? empty? dig).include?(name) || true
  end

  def [](key)
    return if raw_event_data.nil?
    k = key.to_s
    raw_event_data[k] || raw_event_data[k.tr('_', '-')] || raw_event_data[k.tr('-', '_')]
  end

  private

  def fetch_live_eventconf_via_api
    compiled_events = []

    @source_variants.each do |variant|
      file_path = "/opt/opennms/etc/events/#{variant}.xml"
      cmd_file = inspec.command("cat '#{file_path}' 2>/dev/null")

      if cmd_file.exit_status.zero? && !cmd_file.stdout.empty?
        compiled_events.concat(parse_xml_definitions(cmd_file.stdout))
      end
    end

    if compiled_events.empty?
      global_xml = inspec.command("curl -s -u admin:admin -X GET 'http://localhost:8980/opennms/api/v2/eventconf' -H 'Accept: application/xml'")
      if global_xml.exit_status.zero? && !global_xml.stdout.empty? && !global_xml.stdout.include?('Not Found')
        compiled_events = parse_xml_definitions(global_xml.stdout)
      end
    end

    { 'events' => compiled_events }
  end

  def parse_xml_definitions(xml_string)
    require 'nokogiri'
    doc = Nokogiri::XML(xml_string)
    doc.remove_namespaces!

    doc.xpath('//event').map do |e|
      # Parse <mask>
      mask_node = e.at_xpath('mask')
      mask_hash = nil
      vbs = []
      if mask_node
        mes = mask_node.xpath('maskelement').map do |me|
          {
            'mename' => me.at_xpath('mename')&.text&.strip,
            'mevalue' => me.xpath('mevalue').map { |v| v.text.strip },
          }
        end
        vbs = mask_node.xpath('varbind').map do |vb|
          {
            'vbnumber' => vb.at_xpath('vbnumber')&.text&.strip,
            'vbvalue' => vb.xpath('vbvalue').map { |v| v.text.strip },
          }
        end
        mask_hash = {
          'maskelement' => mes,
          'varbind' => vbs,
        }
      end

      # Parse <alarm-data>
      ad = e.at_xpath('alarm-data')
      alarm_data_hash = nil
      if ad
        alarm_data_hash = {
          'reduction-key' => ad['reduction-key'],
          'reduction_key' => ad['reduction-key'],
          'alarm-type' => ad['alarm-type'].to_i,
          'alarm_type' => ad['alarm-type'].to_i,
          'auto-clean' => ad['auto-clean'],
          'auto_clean' => ad['auto-clean'] == 'true',
        }
        alarm_data_hash['clear-key'] = ad['clear-key'] if ad['clear-key']
        alarm_data_hash['clear_key'] = ad['clear-key'] if ad['clear-key']
      end

      # Parse <tticket> and <autoacknowledge>
      tt = e.at_xpath('tticket')
      tticket_hash = tt ? { 'info' => tt.text.strip, 'state' => tt['state'] } : nil

      aa_node = e.at_xpath('autoacknowledge')
      autoack_hash = aa_node ? { 'info' => aa_node.text.strip, 'state' => aa_node['state'] } : nil

      # Parse <logmsg> as string + metadata attributes
      logmsg_node = e.at_xpath('logmsg')
      logmsg_text = logmsg_node ? logmsg_node.text.strip : nil
      logmsg_dest = logmsg_node ? logmsg_node['dest'] : nil
      logmsg_notify = logmsg_node && !logmsg_node['notify'].nil? ? (logmsg_node['notify'].downcase == 'true') : nil

      # Parse <collectionGroup>
      cgs = e.xpath('collectionGroup').map do |cg|
        g = {
          'name' => cg['name'],
          'collections' => cg.xpath('collection').map do |col|
            c = { 'name' => col['name'] }
            c['rename'] = col['rename'] if col['rename']
            c['type'] = col['type'] if col['type']
            pvs = col.xpath('paramValue')
            unless pvs.empty?
              c['param_values'] = pvs.each_with_object({}) do |pv, h|
                val = pv['value']
                h[pv['key']] = val =~ /^\d+$/ ? val.to_i : val.to_f
              end
            end
            c
          end,
        }
        g['resourceType'] = cg['resourceType'] if cg['resourceType']
        g['resource_type'] = cg['resourceType'] if cg['resourceType']
        g['instance'] = cg['instance'] if cg['instance']
        rrd = cg.at_xpath('rrd')
        if rrd
          g['rrd'] = {
            'step' => rrd['step'].to_i,
            'rra' => rrd.xpath('rra').map { |r| r.text.strip },
          }
          g['rrd']['heartbeat'] = rrd['heartBeat'].to_i if rrd['heartBeat']
        end
        g
      end

      # Parse <filters>
      filters_list = e.xpath('filters/filter').map do |f|
        {
          'eventparm' => f['eventparm'],
          'pattern' => f['pattern'],
          'replacement' => f['replacement'],
        }
      end
      {
        'uei' => e.at_xpath('uei')&.text&.strip,
        'mask' => mask_hash,
        'varbinds' => vbs || [],
        'priority' => e.at_xpath('priority')&.text&.strip&.to_i,
        'event-label' => e.at_xpath('event-label')&.text&.strip,
        'eventLabel' => e.at_xpath('event-label')&.text&.strip,
        'event_label' => e.at_xpath('event-label')&.text&.strip,
        'descr' => e.at_xpath('descr')&.text&.strip,
        'logmsg' => logmsg_text,
        'logmsg_dest' => logmsg_dest,
        'logmsg-dest' => logmsg_dest,
        'logmsg_notify' => logmsg_notify,
        'logmsg-notify' => logmsg_notify,
        'severity' => e.at_xpath('severity')&.text&.strip,
        'mouseovertext' => e.at_xpath('mouseovertext')&.text&.strip,
        'operinstruct' => e.at_xpath('operinstruct')&.text&.strip,
        'loggroup' => e.at_xpath('loggroup')&.text&.strip,
        'alarm-data' => alarm_data_hash,
        'alarmData' => alarm_data_hash,
        'alarm_data' => alarm_data_hash,
        'autoacknowledge' => autoack_hash,
        'tticket' => tticket_hash,
        'collectionGroup' => cgs,
        'collection_group' => cgs,
        'filters' => filters_list,
        'eventFilter' => filters_list,
        'forward' => e.xpath('forward').map { |f| { 'mechanism' => f['mechanism'], 'state' => f['state'], 'info' => f.text.strip } },
        'autoaction' => e.xpath('autoaction').map { |a| { 'action' => a.text.strip, 'state' => a['state'] } },
        'operaction' => e.xpath('operaction').map { |o| { 'action' => o.text.strip, 'state' => o['state'], 'menutext' => o['menutext'] } },
        'script' => e.xpath('script').map { |s| { 'name' => s.text.strip, 'language' => s['language'] } },
        'varbindsdecode' => e.xpath('varbindsdecode').map do |v|
          parmid_element = v.at_xpath('parmid') || v.at_xpath('parmIds') || v.at_xpath('parmids')
          parmid_value = parmid_element ? parmid_element.text.strip : (v['parmid'] || v['parmIds'] || v['parmids'])

          {
            'parmid' => parmid_value,
            'decode' => v.xpath('decode').map do |d|
              {
                'varbindvalue' => d['varbindvalue'] || d['varbindValue'] || d.at_xpath('varbindvalue')&.text || d.at_xpath('varbindValue')&.text,
                'varbinddecodedstring' => d['varbinddecodedstring'] || d['varbindDecodedString'] || d.at_xpath('varbinddecodedstring')&.text || d.at_xpath('varbindDecodedString')&.text,
              }
            end,
          }
        end,
        'parameter' => e.xpath('parameter').map do |p|
          h = { 'name' => p['name'], 'value' => p['value'] }
          h['expand'] = true if p['expand'] == 'true'
          h
        end,
      }
    end
  rescue StandardError => e
    puts "ERROR: Failed to parse event definition block: #{e.message}"
    []
  end

  def find_all_events(obj)
    events = []
    if obj.is_a?(Hash)
      obj.each do |k, v|
        if %w(event events event_list eventList events_list).include?(k.to_s)
          v.is_a?(Array) ? events.concat(v) : events.push(v)
        else
          events.concat(find_all_events(v))
        end
      end
    elsif obj.is_a?(Array)
      obj.each { |item| events.concat(find_all_events(item)) }
    end
    events
  end
end

class OpenNmsDynamicMash
  def initialize(hash)
    @hash = hash || {}
  end

  def dig(*keys)
    current = @hash
    keys.each do |k|
      if current.is_a?(Hash)
        str_k = k.to_s
        current = current[str_k] || current[str_k.tr('_', '-')] || current[str_k.tr('-', '_')] || current[k]
      elsif current.is_a?(Array) && k.is_a?(Integer)
        current = current[k]
      else
        return nil
      end
    end
    current
  end

  def method_missing(name, *args)
    string_key = name.to_s

    if string_key.include?('.')
      return dig(*string_key.split('.'))
    end
    normalized_dash = string_key.tr('_', '-')
    normalized_under = string_key.tr('-', '_')
    return @hash[string_key] if @hash.key?(string_key)
    return @hash[normalized_dash] if @hash.key?(normalized_dash)
    return @hash[normalized_under] if @hash.key?(normalized_under)
    super
  end

  def respond_to_missing?(name, include_private = false)
    name_str = name.to_s
    return true if name_str.include?('.')
    @hash.key?(name_str) || @hash.key?(name_str.tr('_', '-')) || @hash.key?(name_str.tr('-', '_')) || super
  end

  def [](key)
    k = key.to_s
    @hash[k] || @hash[k.tr('_', '-')] || @hash[k.tr('-', '_')] || @hash[key]
  end
end
