## Checklist (fill in; delete lines that do not apply)
- [ ] Overlap check done: queue id + GH number + open PRs' changed files + main
- [ ] CI-shaped local run done (files staged, `MIX_TEST_PARTITION` exported)
- [ ] Any CI failure: failure class (flake/defect/infra) + whether it repeated (repeat = defect)
- [ ] INV-10 cross-tenant negative test attached (if a platform-scope route is touched)
- [ ] New env vars / dependencies / feature flags listed (new flags default off)
- [ ] Task identified by queue id AND GH number (e.g. `Q-955 / GH #2213`) in the title or body
- [ ] Status-index `entries:` counter bumped (if requirement statuses flipped)
