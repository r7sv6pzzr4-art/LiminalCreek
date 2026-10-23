# LiminalCreek: encrypted daily backups (setup required)

This workflow has **no ability to change the live database**; it executes
`pg_dump` to export the `public` schema to an encrypted artifact. No
raw data is committed, logged, or uploaded. **Do not store an encryption
private key in GitHub or in the LiminalCreek repository.**

## Configure encryption on your Mac (once)

Install age if needed:

```sh
brew install age
mkdir -p "$HOME/.config/liminalcreek"
chmod 700 "$HOME/.config/liminalcreek"
age-keygen -o "$HOME/.config/liminalcreek/backup-identity.txt"
chmod 600 "$HOME/.config/liminalcreek/backup-identity.txt"
age-keygen -y "$HOME/.config/liminalcreek/backup-identity.txt"
```

The final command prints a **public recipient** beginning with `age1`.
Only this public recipient goes into GitHub. Keep the entire private
`backup-identity.txt` offline in at least one more secure place (an
encrypted backup or password manager attachment). **If that private key
is lost, none of the encrypted backups can be recovered.**

## Configure exactly two GitHub Actions secrets

In your repository: **Settings → Secrets and variables → Actions →
New repository secret**.

1. `LIMINAL_BACKUP_AGE_RECIPIENT` — paste the `age1...` *public*
   recipient from the command above.
2. `LIMINAL_BACKUP_DATABASE_URL` — paste the **Session pooler**
   connection string from Supabase → your project → **Connect →
   Session pooler**, with `[YOUR-PASSWORD]` replaced by the *database*
   password and any special password characters URL-encoded. Prefer
   `?sslmode=require` in the URL. This is a **secret**: never post it in
   chat, an issue, or a file. Do not use the anon/publishable API key.

Session pooler on port 5432 is suitable for GitHub's IPv4-only runner.
Do not use the transaction pooler at port 6543.

## Enable and run

This workflow is added first on a **separate branch** and will not
run on a daily schedule until merged into `main`.

After the two secrets are configured and the workflow has been reviewed,
merge the dedicated backup PR to `main` (not the separate adaptive PR).
Then go to **Actions → Encrypted daily study backup → Run workflow** and
choose `main` to perform a first on-demand backup.

Only after the first run succeeds and an independent recovery test passes
should the automated backups be relied upon.

Daily schedule is 12:23 UTC; GitHub may delay scheduled runs.
Encrypted artifacts are kept for **30 days**, not indefinitely. Arrange
occasional downloads to a second secure location for long-term retention.

## Confirm without viewing blinded responses

Every run:
- verifies that the database export is not empty;
- checks that PostgreSQL can parse the archive;
- confirms that `studies`, `participants`, `assignments`, and
  `responses` table *and data sections* are present;
- encrypts before upload and verifies the encrypted file has a checksum.

The workflow prints no counts, coordinates, feeling selections, or notes.

Download the two encrypted artifact files from the successful run and
on the Mac run:

```sh
shasum -a 256 -c study-public.dump.age.sha256
age -d -i "$HOME/.config/liminalcreek/backup-identity.txt" \
  -o /tmp/liminal-study-restore-test.dump study-public.dump.age
# Test archive readability without exposing any individual observations:
pg_restore --list /tmp/liminal-study-restore-test.dump >/dev/null
rm -f /tmp/liminal-study-restore-test.dump
```

An actual **test restore into a separate disposable PostgreSQL
database** is still needed to verify that all rows and policies can be
reconstructed. The production database must never be a restore target.

## Recovery scope / limitations

This backs up the entire `public` schema (which includes the study,
assignment and response tables). It does **not** back up Supabase's
platform-managed `auth` schema, OAuth/email authentication identities,
Storage files, service configuration or private app secrets. Restoring
a fully functional Supabase project may require additional steps to
recreate auth users and preserve their UUIDs, or a supported full-project
backup. We must test that separately before claiming full-project recovery.

GitHub Actions artifacts are a convenient off-site encrypted copy, not
a permanent archive. GitHub has access to the database *connection
secret* while the job is running, but never receives the private
decryption key. Protect repository administrator access and monitor
for unusual workflows. No client-facing study code is changed.
