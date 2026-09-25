/** NotFoundPage — catch-all route for paths that do not match any static or
 *  module-provided route. Renders a minimal "not found" indicator with a
 *  stable data-testid so tests can assert its presence. */
export function NotFoundPage() {
  return (
    <div data-testid="not-found-page" style={{ padding: '2rem', textAlign: 'center' }}>
      <h2>Page not found</h2>
      <p>The page you requested does not exist or requires a module that is not installed.</p>
    </div>
  )
}
