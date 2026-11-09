// TetherShieldConfig — ShieldConfigurationDataSource extension.
// Renders the "this is blocked" screen. Looks the shielded token up in shieldContext.json
// (written by ShieldApplier) to show the group name, reason and end time.

import ManagedSettings
import ManagedSettingsUI
import UIKit
import TetherKit

class TetherShieldConfigurationExtension: ShieldConfigurationDataSource {

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        make(ShieldContextStore.entry(for: application.token))
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        make(ShieldContextStore.entry(application: application.token, category: category.token))
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        make(ShieldContextStore.entry(for: webDomain.token))
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        make(ShieldContextStore.entry(webDomain: webDomain.token, category: category.token))
    }

    // MARK: Rendering

    private func make(_ entry: ShieldContextEntry?) -> ShieldConfiguration {
        let titleColor = UIColor.label
        let subtitleColor = UIColor.secondaryLabel
        let accent = UIColor(red: 0.20, green: 0.36, blue: 0.95, alpha: 1)

        let title = entry?.title ?? "Blocked by Tether"
        let subtitle = entry?.subtitle ?? "This is blocked right now."
        // "Unlock" only for non-strict blocks with a known group (the pause flow needs the group id).
        let allowsUnlock = (entry != nil) && !(entry?.strict ?? true)

        // VERIFY: ShieldConfiguration.init parameter labels/order against the iOS 17 SDK.
        return ShieldConfiguration(
            backgroundBlurStyle: .systemUltraThinMaterial,
            backgroundColor: UIColor.systemBackground.withAlphaComponent(0.6),
            icon: UIImage(systemName: "hand.raised.fill"),
            title: ShieldConfiguration.Label(text: title, color: titleColor),
            subtitle: ShieldConfiguration.Label(text: subtitle, color: subtitleColor),
            primaryButtonLabel: ShieldConfiguration.Label(text: "Close", color: .white),
            primaryButtonBackgroundColor: accent,
            secondaryButtonLabel: allowsUnlock
                ? ShieldConfiguration.Label(text: "Unlock for 5 min", color: accent)
                : nil)
    }
}
