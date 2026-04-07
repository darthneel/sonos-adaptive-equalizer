# frozen_string_literal: true

require "net/http"
require "uri"
require "rexml/document"

module SonosEq
  class SoapClient
    BLOCKED_ACTIONS = %w[
      SetVolume
      SetRelativeVolume
      SetVolumeDB
      SetRelativeVolumeDB
    ].freeze

    def call(control_url:, service_type:, action:, arguments:)
      raise "Blocked Sonos action: #{action}" if BLOCKED_ACTIONS.include?(action.to_s)

      uri = URI(control_url)
      body = soap_body(service_type, action, arguments)
      headers = {
        "Content-Type" => 'text/xml; charset="utf-8"',
        "SOAPACTION" => %("#{service_type}##{action}")
      }

      response_body = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 3) do |http|
        response = http.post(uri.request_uri, body, headers)
        raise "SOAP HTTP #{response.code}" unless response.code.to_i == 200

        response.body
      end

      parse_soap_response(response_body, action)
    end

    private

    def soap_body(service_type, action, arguments)
      arg_xml = arguments.map { |k, v| "<#{k}>#{xml_escape(v)}</#{k}>" }.join
      <<~XML
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:#{action} xmlns:u="#{service_type}">
              #{arg_xml}
            </u:#{action}>
          </s:Body>
        </s:Envelope>
      XML
    end

    def parse_soap_response(xml, action)
      doc = REXML::Document.new(xml)
      response_element = REXML::XPath.first(doc, "//*[local-name()='#{action}Response']")
      return {} if response_element.nil?

      response_element.elements.each_with_object({}) do |el, acc|
        acc[el.name] = el.text.to_s
      end
    end

    def xml_escape(value)
      value.to_s
           .gsub("&", "&amp;")
           .gsub("<", "&lt;")
           .gsub(">", "&gt;")
           .gsub('"', "&quot;")
           .gsub("'", "&apos;")
    end
  end
end
