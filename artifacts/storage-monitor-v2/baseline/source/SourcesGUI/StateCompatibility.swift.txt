import SwiftUI

// The macOS 27 SDK exports both a State type and a State macro, but current
// Command Line Tools omit the macro plugin. An alias selects the standard
// property wrapper without changing SwiftUI state behavior or runtime APIs.
typealias ViewState<Value> = SwiftUI.State<Value>
