import Foundation

// `Env` does not exist in this directory. It is generated at build time by
// EnvCodegenPlugin from the `.env` files, so the app carries its configuration
// without needing to read a file at runtime.
//
// Because the plugin declares those `.env` files as build inputs, editing one
// regenerates this type on the next build. That dependency tracking is exactly
// what a macro reading the filesystem could not provide.

print("schema:            \(Env.schema)")
print("apiURL:            \(Env.apiURL)")
print("timeoutSeconds:    \(Env.timeoutSeconds)")
print("featureDebugMenu:  \(Env.featureDebugMenu)")
print("analyticsKey:      \(String(repeating: "*", count: Env.analyticsKey.count)) (\(Env.analyticsKey.count) chars)")
print("sentryDSN:         \(Env.sentryDSN ?? "not configured")")
print("declared keys:     \(Env.generatedKeys.count)")
