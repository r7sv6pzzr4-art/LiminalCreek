# LiminalCreek daily backup and study-data health checks

**Current status: proposal only until a separate private backup repository is created.**
This branch makes NO changes to the live database, current assignment queues,
GitHub Pages app, or hidden responses. The separate adaptive-sampling PR stays
unmerged. Nothing in this branch silently reveals results.

## Why a private backup repository?

The LiminalCreek GitHub Pages repository is PUBLIC. Artifacts on a public
GitHub repository should not hold unencrypted study data. Instead, use a
SECOND, **PRIVATE** repository to run the backup and store the resulting
artifacts. This requires no custom encryption key to manage or potentially
lose. GitHub protects the private repository with account access controls.
The backup files remain standard PostgreSQL custom-format archives.

No data gets committed to either repository; it is only held as a PRIVATE
GitHub Actions artifact (30-day retention).

## Step 1: Inspect current database health without reading answers

In Supabase Dashboard -> SQL Editor, paste the contents of
backend/backup/check-study-readonly.sql, then click Run.

The read-only report displays:
- the number of studies and participant memberships;
- 200 original assignment rows / 100 correctly paired sites (as expected
  for this study);
- how many responses were saved;
- how many responses have nonempty feeling descriptions;
- how many have optional free-text notes and the total number of note
  characters (NOT the note text);
- the timestamp of the most recent saved response;
- whether basic integrity checks passed.

No exact coordinates, categories, comments, names or participant IDs are
displayed. Note that **0 nonempty comments is not an error** if neither
participant has written a comment; the optional note field can be blank.
To check that a specific nonempty note was saved, the detailed backup
fingerprint and restore check below compare each response row, including
all text, without printing it.

## Step 2: Create a private backup repository (one-time)

On GitHub:
1. Select **New repository**.
2. Name it something like **LiminalCreek-Backups**.
3. **Choose Private**, not Public.
4. No need to invite the second participant.
5. Add the workflow file at
   **.github/workflows/daily-study-backup.yml**, copying the contents of
   backend/backup/private-repo-workflow.yml from the PUBLIC code repository.
   The job explicitly refuses to run if its repository is not private.

The private workflow reads the *audited scripts* from this public code
repository's main branch. Thus first merge the backup-related PR only,
**not** the unrelated adaptive-sampling PR. Do not activate the workflow
on the public repository: the public repository carries no scheduled
unencrypted backup job.

## Step 3: Configure ONE GitHub Actions secret in the PRIVATE repository

In the PRIVATE backup repository -> Settings -> Secrets and variables
-> Actions -> New repository secret:

Name: LIMINAL_BACKUP_DATABASE_URL

Value: Supabase -> Project -> Connect -> **Session pooler** connection
string with the database password substituted. Use TLS (append
?sslmode=require if absent). Percent-encode reserved characters in
the password if required by the connection URL.

Do not copy the connection string into GitHub files, issues or chat,
or into the public repository's secrets. It must be placed only
in the PRIVATE repository Actions secret. A separate least-privilege
database backup role can be added later; initially this uses whichever
database account you supplied. GitHub-hosted runners normally use IPv4;
Supabase session pooler (port 5432) is suitable.

## Step 4: Test one backup before depending on it

Private backup repository -> Actions -> Daily LiminalCreek backup
(private) -> Run workflow.

The workflow:
1. Takes aggregate fingerprints of the four core tables.
2. Creates a consistent PostgreSQL custom-format archive of public schema.
3. Takes fingerprints again to detect concurrent changes.
4. Restores all four study data tables (studies, participants, assignments
   and responses) into a DISPOSABLE PostgreSQL container.
5. Compares row counts and every field, including **the exact comment text
   and feeling selections**, using aggregate digests internally.
6. Uploads the full archive and checksum to PRIVATE Actions artifacts
   with 30-day retention. Logs display PASS/FAIL only, no response data.

If new responses arrive *during* the backup, the rigorous row-for-row
comparison will be INCONCLUSIVE and the job will fail safely rather than
pretend the contents matched. Rerun during a quiet period.

The archive includes the public schema, so any later public study tables
will also be exported. However, the disposable verification test currently
checks the original four core tables; update the test as new tables matter.

## Step 5: Keep at least one independent copy

GitHub Actions artifacts expire after 30 days, and GitHub scheduled jobs
may be delayed or disabled after inactivity. Each week or month, download
a successful encrypted-in-transit (but unencrypted-at-rest) backup to
your Mac's protected storage (for example FileVault-enabled storage) or
another private backup location. Retain a copy apart from GitHub and
Supabase. Do not share the files or add them to the public Git repository.

You can verify the downloaded archive file checksum with:

    shasum -a 256 -c study-public.dump.sha256

You can inspect its internal structure (no response content printed) with:

    pg_restore --list study-public.dump >/dev/null

**Important recovery limitation:** exporting public schema alone does
not fully back up Supabase managed auth users, provider settings,
secrets or storage. The study records have foreign keys to auth.users,
so restoring a functioning clone requires preserving/reconstituting
matching auth user UUIDs. We must separately verify full-project recovery
before claiming that sign-ins can be restored seamlessly. The private
workflow's data-table restore test does NOT certify full-project recovery.

## Zero-impact rule

These reports require only SELECT access to existing tables; they never
alter any study rows or reveal personal results. The app's normal
questionnaire and logins are unchanged. No backup is running until the
private repository is configured and the workflow is successfully started.
