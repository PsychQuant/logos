import SwiftUI

/// Surfaces the gateway failure policy (spec 2026-07-31).
///
/// Fail-open renders this ABOVE a live terminal — the account works, just
/// unmetered. Fail-closed renders it INSTEAD of one, because the account has a
/// custom upstream and falling back to the default would route traffic somewhere
/// the operator did not direct it.
struct GatewayUnavailableBanner: View {

    let reason: String
    /// True when claude was refused entirely rather than merely run without pacing.
    let isBlocking: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isBlocking ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isBlocking ? Color.red : Color.yellow)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(isBlocking ? "Gateway required but unavailable" : "Running without a gateway")
                    .font(.headline)
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("logos.gateway.banner")
    }
}
