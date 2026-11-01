# Changelog

## [1.0.0] - 2026-10-01

First release of the conditional access policy pack.

- Eight report-only Conditional Access policy templates, so every policy starts in
  report-only mode and nothing takes effect in a tenant until someone turns it on: CA001
  require MFA for all users, CA002 block legacy authentication, CA003 require MFA for
  admins, CA004 require a compliant or hybrid joined device for admins, CA005 block
  unknown platforms, CA006 sign-in frequency on unmanaged devices, CA007 block high-risk
  sign-ins, and CA008 phishing-resistant MFA for admins.
- An import script that reads the templates, plans what it would create, and only applies
  those changes to a tenant when explicitly told to.
- An export script that reads a tenant's current Conditional Access policies, named
  locations, and authentication strengths into a local, dated folder.
- A compare script that reports how a tenant's current policies differ from the pack's
  templates.
- Buyer-facing documents: a README describing what is in the box and what it does not do,
  a deployment order for turning policies on safely, and a licence.
