/**
 * REQ-293 — ambient type declaration for the build-time Vite virtual module
 * `virtual:expr-manifest` (see `web/vite.config.ts`'s `exprManifestPlugin()`).
 * Shape-checked, not `any`. See design doc §8.3.
 */
declare module 'virtual:expr-manifest' {
  const manifest: { corpus_schema_version: string; capabilities: string[] }
  export default manifest
}
