// Source-compatibility re-export: `endpointStore` moved to ManifoldUI because
// ChatView owns the presentation boundary that must forward it. Existing apps
// that import only ManifoldUIModelManagement keep resolving the key here.
@_exported import ManifoldUI
