Pod::Spec.new do |s|

  s.name          = "TICECrypto"
  s.version       = "22.5.0"
  s.summary       = "Crypto to be used in TICE projects."
  s.platform      = :ios, "11.0"
  s.swift_version = "5.1"

  s.homepage      = "https://ticeapp.com"

  s.author        = { "TICE" => "contact@ticeapp.com" }
  s.source        = { :git => "git@github.com:AnbionApps/tice-crypto.git", :tag => "#{s.version}" }

  s.source_files  = "Sources/**/*"

  s.dependency "TICEModels"
  s.dependency "X3DH"
  s.dependency "DoubleRatchet"
  s.dependency "SwiftJWT"

end
