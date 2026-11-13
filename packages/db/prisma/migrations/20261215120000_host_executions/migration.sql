CREATE TABLE "host_executions" (
  "runId" TEXT PRIMARY KEY REFERENCES "runs"("id") ON DELETE CASCADE ON UPDATE CASCADE,
  "spaceId" TEXT NOT NULL,
  "userId" TEXT NOT NULL,
  "authSessionId" TEXT NOT NULL,
  "installationId" TEXT NOT NULL,
  "profileId" TEXT NOT NULL,
  "bindingKey" TEXT NOT NULL,
  "generation" TEXT NOT NULL,
  "tokenHash" TEXT NOT NULL,
  "requestHash" TEXT NOT NULL,
  "engineVersion" TEXT NOT NULL,
  "targetComputerId" TEXT,
  "dispatch" JSONB NOT NULL,
  "lastSequence" INTEGER NOT NULL DEFAULT 0,
  "resultText" TEXT NOT NULL DEFAULT '',
  "terminal" TEXT,
  "sessionRef" TEXT,
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX "host_executions_spaceId_userId_bindingKey_createdAt_idx" ON "host_executions"("spaceId", "userId", "bindingKey", "createdAt");
ALTER TABLE "host_executions" ENABLE ROW LEVEL SECURITY;
CREATE POLICY host_executions_tenant ON "host_executions" USING (
  "spaceId" = NULLIF(current_setting('app.space_id', true), '')
  AND "userId" = NULLIF(current_setting('app.user_id', true), ''));
CREATE POLICY host_executions_system ON "host_executions" USING ((SELECT app_rls_bypass()));
