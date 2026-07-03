import LogosAccounts

/// The registry account model moved to LogosAccounts with
/// merge-multistats-into-logos (single source of truth for the account
/// model + config-dir convention). Re-exported so LogoSwitch's public
/// API stays source-compatible for existing consumers.
public typealias Account = LogosAccounts.Account
