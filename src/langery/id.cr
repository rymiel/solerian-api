module Langery::ID
  ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

  def self.generate(size : Int32 = 12) : String
    step = size * 2
    total = 0
    String.new(size) do |buffer|
      while total != size
        bytes = Random::Secure.random_bytes(step)
        step.times do |i|
          char = ALPHABET[bytes[i] & 0x3F]?
          next unless char
          buffer[total] = char.ord.to_u8
          total += 1
          break if total == size
        end
      end

      {size, size}
    end
  end
end
