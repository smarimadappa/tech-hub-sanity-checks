# Changelog

## d001-sanity-check
- **0.2.0** — Add informational-only revenue reconciliation vs. `GDM.PERFORMANCE.GDM_SES_PPC_PPL`
  (DMABGS-3270). Reported as a footnote in the Slack message; never gates pass/fail or pages
  on-call — source vs. destination doesn't reconcile exactly every day for reasons not yet
  understood.
- **0.1.0** — Initial release: D-001 Performance Cube daily sanity check (DMABGS-3270).

## d000-sanity-check
- **0.2.0** — Add informational-only revenue reconciliation vs. `GDM.PERFORMANCE.GDM_SES_PPC_PPL`
  (DMABGS-3269), superseding the "deferred" note from 0.1.0. Reported as a footnote in the Slack
  message; never gates pass/fail or pages on-call — source vs. destination doesn't reconcile
  exactly every day for reasons not yet understood.
- **0.1.0** — Initial release: D-000 Channel Dashboard daily sanity check (DMABGS-3269).
  Max-date checks degrade gracefully until the companion view ships. Revenue reconciliation
  (ses_ppc_ppl vs data_product) intentionally deferred — source tables not yet specified.
