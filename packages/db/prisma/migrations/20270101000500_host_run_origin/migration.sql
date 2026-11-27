-- Apply after the old API and workers stop. They route runs using the old trigger.
ALTER TABLE "runs" ADD COLUMN "runsInLocalWorkspace" BOOLEAN NOT NULL DEFAULT FALSE;

UPDATE "runs" AS run
SET "trigger" = 'user', "runsInLocalWorkspace" = host."targetComputerId" IS NULL
FROM "host_executions" AS host
WHERE run."id" = host."runId" AND run."trigger" = 'host';
