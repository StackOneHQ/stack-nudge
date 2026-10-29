import SwiftUI

// The states every skin draws. CompanionMode maps what the app knows onto
// this, so skin art stays independent of the app model.
enum SkinMode {
    case idle, polling, thinking, pending, alert, error, sleeping, muted
}
