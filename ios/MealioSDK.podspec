Pod::Spec.new do |s|
  s.name             = 'MealioSDK'
  s.version          = '0.3.0'
  s.summary          = 'Mealio Cart SDK: add a recipe to the user\'s own grocery store cart.'
  s.description      = <<-DESC
    The Mealio Cart SDK carries out signed instructions from Mealio's server on
    the user's device, with the user's own store login, to fill their grocery
    cart from a recipe. One SwiftUI sheet runs the whole flow, store sign-in included.
  DESC
  s.homepage         = 'https://mealio.co'
  s.license          = { :type => 'Proprietary', :text => 'Copyright Mealio. All rights reserved.' }
  s.author           = { 'Mealio' => 'support@mealio.co' }
  # VERIFY: repository URL and tag scheme.
  s.source           = { :git => 'https://github.com/mealio/mealio_sdk.git', :tag => "ios-v#{s.version}" }

  s.ios.deployment_target = '15.0'
  s.swift_version    = '5.9'

  # Paths are relative to the repository root (the podspec lives in ios/).
  # VERIFY: with `pod 'MealioSDK', :path => 'ios'` CocoaPods resolves these
  # relative to the podspec instead; use 'Sources/MealioSDK/**/*.swift' then.
  s.source_files     = 'ios/Sources/MealioSDK/**/*.swift'
  s.frameworks       = 'Foundation', 'UIKit', 'WebKit', 'CryptoKit', 'SwiftUI', 'Combine'
end
