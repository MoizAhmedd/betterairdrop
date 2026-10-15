import Foundation

/// Where BetterAirdrop Pro is sold. Polar (polar.sh) is the merchant of record and hosts the
/// license keys; the app only calls Polar's public customer-portal endpoints, which need the
/// organization ID and no secret token.
/// Both are public (they're in every checkout and API call), not secrets. An organization ID
/// containing TODO (a fork, or `BETTERAIRDROP_POLAR_ORG` left unset to a placeholder) means
/// activation explains that Pro isn't on sale; a checkout link containing TODO shows "Coming soon".
public enum Polar {
    /// Polar dashboard → Settings → General → Organization ID (a UUID).
    public static let organizationID = "aadcb5c9-867d-41c0-abe3-02dd71dd8991"
    /// The Pro product's checkout link (Products → BetterAirdrop Pro → Checkout Link).
    public static let checkoutURL = "https://buy.polar.sh/polar_cl_vFxys6Ii0P1QCp70E9p0ltBeKOjoWSAdyWHzq0pCItJ"

    public static let productionAPI = URL(string: "https://api.polar.sh")!

    /// The Buy button works (the checkout link has been filled in).
    public static var canBuy: Bool { !checkoutURL.contains("TODO") }

    /// Keys can be activated against this organization ID (not the placeholder).
    static func isReal(organizationID: String) -> Bool {
        !organizationID.isEmpty && !organizationID.contains("TODO")
    }

    /// For trying a key against Polar's sandbox before launch:
    /// `BETTERAIRDROP_POLAR_API=https://sandbox-api.polar.sh BETTERAIRDROP_POLAR_ORG=<sandbox org id>`.
    public static func endpoint(environment: [String: String] = ProcessInfo.processInfo.environment) -> (api: URL, organizationID: String) {
        let api = environment["BETTERAIRDROP_POLAR_API"].flatMap(URL.init(string:)) ?? productionAPI
        return (api, environment["BETTERAIRDROP_POLAR_ORG"] ?? organizationID)
    }
}
