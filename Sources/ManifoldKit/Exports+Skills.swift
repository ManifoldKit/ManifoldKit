// Conditional re-export of ManifoldSkills via the umbrella `ManifoldKit`
// module. Gated on the `Skills` trait (default-on) so consumers building
// without the trait (e.g. embedded / FoundationOnly) don't pay for the
// module link.
#if Skills
@_exported import ManifoldSkills
#endif
