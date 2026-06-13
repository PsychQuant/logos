import SwiftUI

struct AccountsSettingsTab: View {
    var body: some View {
        AccountSwitcherSheet()
            .dialogFrame(.accounts)
    }
}
