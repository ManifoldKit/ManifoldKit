#if Macros
import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct ManifoldMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ToolSchemaMacro.self,
    ]
}
#else
// When the `Macros` trait is off, swift-syntax is excluded from the build
// graph entirely (~647 files saved). The `.macro` SwiftPM target still
// needs an `@main` entrypoint to link, so this stub provides a no-op
// executable that is never invoked — the macro is unavailable behind
// `#if Macros` guards in `Sources/ManifoldInference/Macros/ToolSchema.swift`,
// so the compiler never asks the plugin to expand anything.
@main
struct ManifoldMacrosPluginNoOp {
    static func main() {}
}
#endif
