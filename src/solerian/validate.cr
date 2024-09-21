# Some validation happens here, since it requires complex PCRE regexes that the javascript frontend can't handle
module Solerian::Validation
  ONSET     = /(?<onset>sk|(?:[tdkg](?:[lr]|s)|(?:st|[mftdnrslɲjkgx]))?)/
  NUCLEUS   = /(?<nucleus>[aeiouəɨ])/
  CODA_BODY = /(?:(?:x[lrs])|s[tdkg]|[lr](?:s|[tdkg]|[nm])|[tdkg]s|[nm](?:s|[tdkg])|(?:st|[mftdnrslɲjkgx]))?/
  CODA      = "(?<coda>(?=\\g<onset>\\g<nucleus>|$)|(?:st|[mftdnrslɲjkgx])(?=\\g<onset>\\g<nucleus>|$)|#{CODA_BODY})"
  SYLLABLES = /^(#{ONSET}#{NUCLEUS}#{CODA}(?=\g<onset>|$))+/

  def self.is_valid?(word : String, ipa : String)
    return ipa.matches?(SYLLABLES, options: Regex::MatchOptions::ANCHORED | Regex::MatchOptions::ENDANCHORED)
  end
end
