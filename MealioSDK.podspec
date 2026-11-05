Pod::Spec.new do |s|
  s.name             = 'MealioSDK'
  s.version          = '0.4.0'
  s.summary          = 'Mealio Cart SDK: add a recipe to the user\'s own grocery store cart.'
  s.description      = <<-DESC
    The Mealio Cart SDK carries out signed instructions from Mealio's server on
    the user's device, with the user's own store login, to fill their grocery
    cart from a recipe. One SwiftUI sheet runs the whole flow, store sign-in included.
  DESC
  s.homepage         = 'https://developers.mealio.co'
  s.license          = { :type => 'Proprietary', :file => 'LICENSE' }
  s.author           = { 'Mealio' => 'support@mealio.co' }
  # One tag releases all four SDKs: v0.4.0.
  s.source           = { :git => 'https://github.com/stephengreer97/mealio_sdk.git', :tag => "v#{s.version}" }

  s.ios.deployment_target = '15.0'
  s.swift_version    = '5.9'

  # Published from the repository root (`pod trunk push MealioSDK.podspec`), so
  # paths are relative to the root.
  s.source_files     = 'ios/Sources/MealioSDK/**/*.swift'
  s.frameworks       = 'Foundation', 'UIKit', 'WebKit', 'CryptoKit', 'SwiftUI', 'Combine'
end
