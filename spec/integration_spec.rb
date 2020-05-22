require "capybara_discoball"
require "fileutils"
require "net/http"
require "sinatra"
require "tmpdir"
require "vcr_better_binary_serializer"
require "vcr"
require "webmock"

RSpec.describe "use with VCR" do
  let(:tmp_dir) { Dir.mktmpdir("tmp_vcr_cassettes") }
  let(:image1) { File.expand_path("fixtures/image.png", __dir__) }
  let(:image2) { File.expand_path("fixtures/image.jpg", __dir__) }
  let(:serializer) { VcrBetterBinarySerializer.new }

  before(:each) do
    VCR.configure do |config|
      config.cassette_library_dir = tmp_dir
      config.hook_into :webmock
      config.cassette_serializers[:better_binary] = serializer
      config.default_cassette_options = {
        serialize_with: :better_binary,
      }
    end
  end

  after(:each) do
    FileUtils.rm_rf(tmp_dir)
  end

  class WebApplication < Sinatra::Base
    post '/' do
      send_file(@@file_path)
    end
  end

  let(:server) do
    Capybara::Discoball.spin(WebApplication)
  end

  let(:url) { URI(server) }

  it "persists the cassette without binary data in the request or response" do
    WebApplication.class_variable_set(:@@file_path, image2)

    VCR.use_cassette("integration-test") do
      Net::HTTP.post(url, read_binary_data(image1), "Content-Type" => "image/png")
    end

    recorded = YAML.load_file(File.expand_path("integration-test.yml", tmp_dir))
    interaction = recorded["http_interactions"].last

    expect_body_referencing_binary_data(
      body: interaction.dig("request", "body"),
      expected_data: read_binary_data(image1)
    )

    expect_body_referencing_binary_data(
      body: interaction.dig("response", "body"),
      expected_data: read_binary_data(image2)
    )
  end

  it "can be deserialzed successfully" do
    WebApplication.class_variable_set(:@@file_path, image2)

    make_request = Proc.new do
      VCR.use_cassette("integration-test-2") do
        Net::HTTP.post(url, read_binary_data(image1), "Content-Type" => "image/png")
      end
    end

    allow(serializer).to receive(:serialize).and_call_original
    allow(serializer).to receive(:deserialize).and_call_original

    responses = 3.times.map { make_request.call.body }

    expect(serializer).to have_received(:serialize).once
    expect(serializer).to have_received(:deserialize).exactly(2).times
    expect(responses).to all eq responses.first
  end

  private

  def read_binary_data(path)
    data = File.open(path, "rb") do |file|
      file.read
    end

    expect(data.encoding).to eq Encoding::BINARY

    data
  end

  def expect_body_referencing_binary_data(body:, expected_data:)
    expect(body["encoding"]).to eq "ASCII-8BIT"
    expect(body.has_key?("string")).to eq(false)
    expect(body.has_key?("bin_key")).to eq(true)

    binary_data_path = File.join(tmp_dir, "/bin_data", body.dig("bin_key"))

    expect(read_binary_data(binary_data_path)).to eq(expected_data)
  end
end
