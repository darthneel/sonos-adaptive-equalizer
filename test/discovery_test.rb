# frozen_string_literal: true

require_relative "test_helper"

class DiscoveryTest < Minitest::Test
  DEVICE_XML = <<~XML
    <?xml version="1.0"?>
    <root>
      <device>
        <roomName>Living Room</roomName>
        <modelName>Sonos One</modelName>
        <UDN>uuid:RINCON_TEST</UDN>
        <serviceList>
          <service>
            <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
            <controlURL>/MediaRenderer/AVTransport/Control</controlURL>
          </service>
          <service>
            <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
            <controlURL>/MediaRenderer/RenderingControl/Control</controlURL>
          </service>
        </serviceList>
      </device>
    </root>
  XML

  def test_parses_case_insensitive_ssdp_headers
    discovery = SonosEq::Discovery.new
    packet = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.2/xml/device.xml\r\nST: urn:test\r\n\r\n"

    headers = discovery.send(:parse_ssdp_headers, packet)

    assert_equal "http://192.168.1.2/xml/device.xml", headers["location"]
    assert_equal "urn:test", headers["st"]
  end

  def test_builds_device_control_urls_from_description
    discovery = SonosEq::Discovery.new
    discovery.define_singleton_method(:http_get) { |_uri| DEVICE_XML }

    device = discovery.send(:fetch_device, "http://192.168.1.2:1400/xml/device.xml")

    assert_equal "Living Room", device.room_name
    assert_equal "uuid:RINCON_TEST", device.udn
    assert_equal "http://192.168.1.2:1400/MediaRenderer/AVTransport/Control", device.av_transport_control_url
    assert_equal "http://192.168.1.2:1400/MediaRenderer/RenderingControl/Control", device.rendering_control_url
  end
end
