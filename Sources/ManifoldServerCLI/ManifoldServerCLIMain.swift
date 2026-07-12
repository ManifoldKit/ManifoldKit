import ManifoldServer

// The `manifold-server` binary's entry point. `ManifoldServerCommand` (the
// actual `AsyncParsableCommand`) lives in the `ManifoldServer` library target,
// not here — `@main` can only annotate a type in an executable target, so
// this tiny target exists solely to host it and forward to `.main()`. This
// split (P0, v0.71) is what lets a host app `import ManifoldServer` as a
// library and call `ManifoldServer.serve(configuration:backendProvider:)`
// directly, instead of only shelling out to this CLI binary — an
// `.executableTarget` cannot back a `.library()` product (SwiftPM rejects
// it), so the library implementation had to move out of the executable
// target that used to be named `ManifoldServer`.
#if Server
@main
struct ManifoldServerCLIEntryPoint {
    static func main() async {
        await ManifoldServerCommand.main()
    }
}
#else
// Stub entry point when the `Server` trait is disabled. Building the
// executable still requires a `@main`; this prints a clear "trait not
// enabled" message instead of pulling Hummingbird into the default build.
@main
struct ManifoldServerDisabled {
    static func main() {
        print("ManifoldServer was built without the `Server` trait. Re-build with `--traits Server` to enable.")
    }
}
#endif
