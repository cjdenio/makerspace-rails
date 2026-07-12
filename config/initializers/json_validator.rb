# Suppress json-schema deprecation warning about MultiJSON support.
# multi_json is pulled in transitively by googleauth/paypal-sdk/signet
# but is not used directly by this application.
require 'json-schema'
JSON::Validator.use_multi_json = false
