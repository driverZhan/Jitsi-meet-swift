import Foundation

// The SDK is a static framework written in Swift. An app with no Swift sources gets no
// Swift runtime link settings (weak-link the compatibility shims, bundle the stdlib), and
// linking the framework then fails with "could not find auto-linked library
// swiftCompatibility56". This otherwise-unused type makes Xcode treat the target as mixed
// and configure the Swift toolchain for it.
enum SwiftRuntimeAnchor {}
