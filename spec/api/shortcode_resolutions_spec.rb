require "swagger_helper"

RSpec.describe "Shortcode resolution API", type: :request do
  path "/shortcodes/{code}" do
    get "Resolve a printed Makerspace short URL" do
      tags "Shortcodes"
      produces "application/json"
      security []
      parameter name: :code, in: :path, required: true,
                schema: { type: :string, pattern: "^[2-9A-Z]{10}$" }
      let(:code) { "23456789AB" }
      let(:target) { "https://members.example.org/tools/0123456789abcdef01234567/request-checkout" }

      before do
        allow(ShortUrl).to receive(:base_url).and_return("https://members.example.org")
      end

      response "200", "Supported destination; authentication still applies at the destination" do
        header "Cache-Control", schema: { type: :string, enum: ["no-store"] }
        schema type: :object, additionalProperties: false,
               required: ["target_path"], properties: { target_path: { type: :string } }
        before do
          allow(ShortUrl).to receive(:resolve).with(code, origin: "https://members.example.org").and_return(target)
          allow(ShortUrl).to receive(:visible!).with(target).and_return(true)
        end
        run_test! do |response|
          expect(response.parsed_body).to eq("target_path" => URI.parse(target).path)
          expect(response.headers["Cache-Control"]).to eq("no-store")
          expect(response.headers["Set-Cookie"]).to be_nil
        end
      end

      response "404", "Invalid or unknown code, or unavailable resource" do
        schema type: :object, required: ["error"], properties: { error: { type: :string } }
        before { allow(ShortUrl).to receive(:resolve).and_return(nil) }
        run_test!
      end

      response "503", "Resolver infrastructure unavailable" do
        schema type: :object, required: ["error"], properties: { error: { type: :string } }
        before { allow(ShortUrl).to receive(:resolve).and_raise(ShortUrl::Unavailable) }
        run_test!
      end
    end
  end
end
