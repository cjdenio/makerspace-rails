require_relative '../custom_error'
module Error::Google
  class Upload < ::Error::CustomError
    def initialize(err=nil)
      message = if err.nil?
        'Error uploading file to Google'
      elsif err.respond_to?(:body)
        body = JSON.parse(err.body) rescue nil
        if body && body['error_description'].present?
          "Google Drive upload failed: #{body['error_description']}"
        elsif body && body['error'].present?
          "Google Drive upload failed: #{body['error']}"
        else
          "Google Drive upload failed: #{err.message}"
        end
      else
        "Google Drive upload failed: #{err}"
      end
      super(:internal_server_error, 500, message)
    end
  end
end
