# Deployment order

This document covers how to move from "policies imported as report-only" to "policies
enforced," one step at a time. Every step assumes the policies are already imported with
`Import-CaPolicyPack.ps1`, so they exist in the tenant in report-only mode before you start.

## Step 1: Break-glass accounts and group

Create two cloud-only break-glass accounts if they do not already exist, and place both in a
dedicated security group. Both accounts should have a long, randomly generated password stored
somewhere outside the tenant (such as a sealed physical copy or a password manager that does
not depend on the tenant itself), and neither account should be assigned to a real person's
day-to-day sign-in.

Each break-glass account holds the Global Administrator role permanently, not through
Privileged Identity Management eligibility, since there must be no activation step between a
real admin lockout and getting back in. Each account signs in with a FIDO2 security key or a
certificate rather than a password alone, because Microsoft now requires multifactor
authentication for its admin portals regardless of any Conditional Access policy, and a
password-only break-glass account would be locked out of the very portal it exists to reach.

What to check before moving on: both accounts sign in successfully today, and that test is
repeated every quarter; the group is security-enabled, and the group's object ID is the one you
pass to `Import-CaPolicyPack.ps1` as `-BreakGlassGroupId`.

How long to wait: no report-only period applies to this step; it is a one-time setup.

If something goes wrong: if you cannot sign in with a break-glass account at all, stop here and
fix that before importing or enabling anything. A break-glass account that does not work is not
a safety net.

## Step 2: Trusted location (optional)

None of the eight templates in this pack require a named location in the current version. If
you plan to add a location-based template later, or you already use trusted locations
elsewhere in the tenant, confirm the location exists in Microsoft Entra ID before you reference
it anywhere.

What to check before moving on: the named location's object ID is correct and the location
covers the ranges you expect.

How long to wait: no report-only period applies to this step.

If something goes wrong: if a named location is misconfigured, no imported template in this
pack is affected, since none of the eight reference one.

## Step 3: Import with -WhatIf, then -Apply

Run `Import-CaPolicyPack.ps1` with `-WhatIf` first, and read the output. It must show what the
script would do without making any change. Once the output looks right, run the same command
with `-Apply` to create the report-only policies in the tenant.

What to check before moving on: `-Apply` on its own imports six templates, since CA007 and
CA008 need an extra switch each; add `-IncludeP2` for CA007 and `-IncludePhishingResistant` for
CA008 to import all eight. Whichever subset you chose (with those switches, or with `-Include`
or `-Exclude`), every result should say a policy was created or skipped as a duplicate, with no
error.

How long to wait: no report-only period applies to this step; it only creates the policies, it
does not enable any of them.

If something goes wrong: a failed check stops the script before any write. If a write fails
after the checks pass, policies already created stay report-only; fix the problem and run
`-Apply` again, and those are skipped as duplicates.

## Step 4: Review sign-in logs

With the policies sitting in report-only mode, open Sign-in logs in the Entra admin center,
open each sign-in entry, and check its Report-only tab to see which policies would have applied
and what they would have done. If this tenant already streams sign-in logs to a Log Analytics
workspace, the Conditional Access insights and reporting workbook gives the same information
summarized across many sign-ins instead of one at a time. Look for any sign-in that a policy
would have blocked or challenged if it were enforced, and check whether that sign-in was
legitimate.

What to check before moving on: no legitimate, expected sign-in would have been blocked by the
policy, and any flagged sign-in has an explanation (a known test account, a service that needs
an exclusion, and so on).

How long to wait: 7 to 14 days of report-only data before enabling a policy. A shorter window
can miss a legitimate pattern that only happens weekly or monthly (a batch job, an end-of-month
report, a contractor who signs in a few days a month).

If something goes wrong: if a policy would have blocked someone it should not have, do not
enable it yet. Work out whether the policy needs an exclusion, or whether the affected account
or application needs a different fix, then restart the 7 to 14 day review once you have made
that change.

## Step 5: Enable policies in order

Switch each policy from report-only to enabled in the Entra admin center, one at a time, in the
order below. Repeat step 4 for each policy before enabling the next one; do not enable two
policies on the same day unless you have already reviewed both separately.

If Security Defaults was turned off to run the import (see the Security Defaults section of
README.md), CA002 and CA003, the first two policies below, are the same two policies that
section says to enable first, to bring multifactor and legacy authentication protection back.

| Order | Policy | Reason for this position |
|---|---|---|
| 1 | CA002 Block legacy authentication | Legacy protocols cannot satisfy MFA, so this closes an easy path around every policy that follows, before any of them are in place. |
| 2 | CA003 Require MFA for admins | Privileged accounts carry the most risk, so they get MFA protection before it is required tenant-wide. |
| 3 | CA001 Require MFA for all users | Extends the same protection to every user once the admin-only version has run cleanly. |
| 4 | CA005 Block unknown platforms | Narrows sign-in to the common device platforms once the tenant's baseline MFA posture is in place. |
| 5 | CA004 Require compliant or hybrid joined device for admins | Depends on Intune device enrolment, which usually needs its own lead time, so it follows the simpler admin policies. |
| 6 | CA006 Sign-in frequency on unmanaged devices | A session-control refinement that builds on the device state checked by CA004. |
| 7 | CA007 Block high-risk sign-ins | Needs Entra ID P2 and benefits from risk signal that has had time to accumulate from the policies already enabled. |
| 8 | CA008 Phishing-resistant MFA for admins | Requires admins to have registered a FIDO2 key or Windows Hello for Business first, so it comes last. |

What to check before moving on: after enabling a policy, watch the sign-in logs for the rest of
that day and the following business day for any unexpected block, then move to the next policy
in the table.

How long to wait: at least one full business day of enforced monitoring before enabling the next
policy in the list, in addition to the 7 to 14 day report-only review from step 4.

If something goes wrong: if an enabled policy blocks someone who needs access, an administrator,
or a break-glass account only if every administrator is blocked, opens the policy in the Entra
admin center and switches it back to Report-only. This does not delete the policy or lose any
configuration; it only stops the policy from enforcing until you have fixed the underlying
problem (commonly a missing exclusion or an account that still needs to register for MFA).

## Step 6: Compare monthly

Run `Compare-CaBaseline.ps1` once a month against the live tenant. It reports, for every
template, whether the matching policy is missing, matches the template, differs from the
template, is still report-only, or has been enabled.

What to check before moving on: this is an ongoing step with no "next step" to unlock. Use the
output to catch drift, such as a policy that someone edited directly in the portal, or a policy
that was switched back to report-only during an incident and never re-enabled.

How long to wait: run it monthly; there is no report-only period attached to this step.

If something goes wrong: if the comparison shows a policy differs from its template, decide
whether the drift was intentional. If it was not, re-import the affected template or fix the
policy in the portal to match.
