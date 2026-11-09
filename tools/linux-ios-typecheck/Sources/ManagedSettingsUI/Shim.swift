import Foundation
import ManagedSettings
import UIKit
public struct ShieldConfiguration {
    public struct Label { public init(text: String, color: UIColor) {} }
    public init(backgroundBlurStyle: UIBlurEffect.Style? = nil, backgroundColor: UIColor? = nil, icon: UIImage? = nil,
                title: ShieldConfiguration.Label? = nil, subtitle: ShieldConfiguration.Label? = nil,
                primaryButtonLabel: ShieldConfiguration.Label? = nil, primaryButtonBackgroundColor: UIColor? = nil,
                secondaryButtonLabel: ShieldConfiguration.Label? = nil) {}
}
open class ShieldConfigurationDataSource: NSObject {
    public override init() {}
    open func configuration(shielding application: Application) -> ShieldConfiguration { ShieldConfiguration() }
    open func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration { ShieldConfiguration() }
    open func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration { ShieldConfiguration() }
    open func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration { ShieldConfiguration() }
}
