# frozen_string_literal: true

require "socket"
require "timeout"
require "uri"
require "net/http"
require "rexml/document"

module SonosEq
  Device = Struct.new(
    :ip,
    :room_name,
    :model_name,
    :udn,
    :av_transport_control_url,
    :rendering_control_url,
    keyword_init: true
  )

  class Discovery
    SSDP_GROUP_IP = "239.255.255.250"
    SSDP_PORT = 1900
    SONOS_ST = "urn:schemas-upnp-org:device:ZonePlayer:1"

    def initialize(timeout_sec: 4)
      @timeout_sec = timeout_sec
    end

    def discover
      responses = ssdp_search
      locations = responses.filter_map { |r| r["location"] }.uniq
      locations.filter_map { |location| fetch_device(location) }.uniq { |d| d.udn }
    end

    private

    def ssdp_search
      socket = UDPSocket.new
      socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
      socket.bind("0.0.0.0", 0)

      request = [
        "M-SEARCH * HTTP/1.1",
        "HOST: #{SSDP_GROUP_IP}:#{SSDP_PORT}",
        'MAN: "ssdp:discover"',
        "MX: 2",
        "ST: #{SONOS_ST}",
        "",
        ""
      ].join("\r\n")

      socket.send(request, 0, SSDP_GROUP_IP, SSDP_PORT)

      results = []
      Timeout.timeout(@timeout_sec) do
        loop do
          packet, _addr = socket.recvfrom_nonblock(65_535)
          parsed = parse_ssdp_headers(packet)
          next unless parsed["st"] == SONOS_ST

          results << parsed
        rescue IO::WaitReadable
          IO.select([socket], nil, nil, 0.2)
          retry
        end
      end
      results
    rescue Timeout::Error
      results || []
    ensure
      socket&.close
    end

    def parse_ssdp_headers(packet)
      packet.to_s.split("\r\n").each_with_object({}) do |line, acc|
        next unless line.include?(":")

        key, value = line.split(":", 2)
        acc[key.strip.downcase] = value.to_s.strip
      end
    end

    def fetch_device(location)
      uri = URI(location)
      xml = http_get(uri)
      doc = REXML::Document.new(xml)

      room_name = first_text_local_name(doc, "roomName")
      model_name = first_text_local_name(doc, "modelName")
      udn = first_text_local_name(doc, "UDN")

      services = {}
      REXML::XPath.each(doc, "//*[local-name()='service']") do |service|
        service_type = first_text_local_name(service, "serviceType")
        control_url = first_text_local_name(service, "controlURL")
        services[service_type] = absolute_url(uri, control_url)
      end

      av_transport = services["urn:schemas-upnp-org:service:AVTransport:1"]
      rendering_control = services["urn:schemas-upnp-org:service:RenderingControl:1"]
      return nil if av_transport.nil? || rendering_control.nil?

      Device.new(
        ip: uri.host,
        room_name: room_name,
        model_name: model_name,
        udn: udn,
        av_transport_control_url: av_transport,
        rendering_control_url: rendering_control
      )
    rescue StandardError
      nil
    end

    def http_get(uri)
      Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 2) do |http|
        response = http.get(uri.request_uri)
        raise "HTTP #{response.code}" unless response.code.to_i == 200

        response.body
      end
    end

    def absolute_url(base_uri, path)
      URI.join(base_uri.to_s, path).to_s
    end

    def first_text_local_name(node, local_name)
      element = REXML::XPath.first(node, ".//*[local-name()='#{local_name}']")
      element&.text.to_s.strip
    end
  end
end
