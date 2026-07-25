# frozen_string_literal: true

require_relative "test_helper"

class SoapClientTest < Minitest::Test
  def test_blocks_every_volume_mutation_before_network_access
    client = SonosEq::SoapClient.new

    SonosEq::SoapClient::BLOCKED_ACTIONS.each do |action|
      error = assert_raises(RuntimeError) do
        client.call(
          control_url: "http://127.0.0.1:1/control",
          service_type: "urn:test",
          action: action,
          arguments: {}
        )
      end
      assert_includes error.message, "Blocked Sonos action"
    end
  end

  def test_escapes_soap_argument_values
    client = SonosEq::SoapClient.new

    body = client.send(:soap_body, "urn:test", "SetBass", "Value" => %(<&"' >))

    assert_includes body, "&lt;&amp;&quot;&apos; &gt;"
    refute_includes body, %(<Value><&"' ></Value>)
  end

  def test_parses_action_response_by_local_name
    client = SonosEq::SoapClient.new
    xml = <<~XML
      <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
        <s:Body>
          <u:GetBassResponse xmlns:u="urn:test">
            <CurrentBass>3</CurrentBass>
          </u:GetBassResponse>
        </s:Body>
      </s:Envelope>
    XML

    assert_equal({ "CurrentBass" => "3" }, client.send(:parse_soap_response, xml, "GetBass"))
  end
end
