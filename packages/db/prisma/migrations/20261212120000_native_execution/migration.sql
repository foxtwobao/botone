-- CreateTable
CREATE TABLE "execution_connections" (
    "id" TEXT NOT NULL,
    "spaceId" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "computerId" TEXT NOT NULL,
    "label" TEXT NOT NULL,
    "secretRef" TEXT NOT NULL,
    "identity" TEXT NOT NULL,
    "revokedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "execution_connections_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "bot_executions" (
    "botId" TEXT NOT NULL,
    "spaceId" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "connectionId" TEXT NOT NULL,
    "profileId" TEXT NOT NULL,
    "revision" INTEGER NOT NULL,
    "model" TEXT,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "bot_executions_pkey" PRIMARY KEY ("botId")
);

-- CreateTable
CREATE TABLE "native_executions" (
    "runId" TEXT NOT NULL,
    "spaceId" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "connectionId" TEXT NOT NULL,
    "requestRef" TEXT NOT NULL,
    "bindingKey" TEXT NOT NULL,
    "generation" TEXT,
    "lastSequence" INTEGER NOT NULL DEFAULT 0,
    "sessionId" TEXT,
    "engineVersion" TEXT,
    "completed" BOOLEAN NOT NULL DEFAULT false,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "native_executions_pkey" PRIMARY KEY ("runId")
);

-- CreateTable
CREATE TABLE "native_interactions" (
    "id" TEXT NOT NULL,
    "spaceId" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "runId" TEXT NOT NULL,
    "requestId" TEXT NOT NULL,
    "generation" TEXT NOT NULL,
    "messageId" TEXT NOT NULL,
    "status" TEXT NOT NULL DEFAULT 'pending',

    CONSTRAINT "native_interactions_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "execution_connections_spaceId_userId_idx" ON "execution_connections"("spaceId", "userId");

-- CreateIndex
CREATE INDEX "bot_executions_spaceId_userId_idx" ON "bot_executions"("spaceId", "userId");

-- CreateIndex
CREATE INDEX "native_executions_spaceId_userId_bindingKey_createdAt_idx" ON "native_executions"("spaceId", "userId", "bindingKey", "createdAt");

-- CreateIndex
CREATE UNIQUE INDEX "native_interactions_messageId_key" ON "native_interactions"("messageId");

-- CreateIndex
CREATE INDEX "native_interactions_spaceId_userId_runId_status_idx" ON "native_interactions"("spaceId", "userId", "runId", "status");

-- CreateIndex
CREATE UNIQUE INDEX "native_interactions_runId_requestId_key" ON "native_interactions"("runId", "requestId");

-- AddForeignKey
ALTER TABLE "execution_connections" ADD CONSTRAINT "execution_connections_spaceId_userId_fkey" FOREIGN KEY ("spaceId", "userId") REFERENCES "space_members"("spaceId", "userId") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "execution_connections" ADD CONSTRAINT "execution_connections_computerId_fkey" FOREIGN KEY ("computerId") REFERENCES "computers"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "bot_executions" ADD CONSTRAINT "bot_executions_botId_fkey" FOREIGN KEY ("botId") REFERENCES "bots"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "bot_executions" ADD CONSTRAINT "bot_executions_spaceId_userId_fkey" FOREIGN KEY ("spaceId", "userId") REFERENCES "space_members"("spaceId", "userId") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "bot_executions" ADD CONSTRAINT "bot_executions_connectionId_fkey" FOREIGN KEY ("connectionId") REFERENCES "execution_connections"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "native_executions" ADD CONSTRAINT "native_executions_runId_fkey" FOREIGN KEY ("runId") REFERENCES "runs"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "native_executions" ADD CONSTRAINT "native_executions_spaceId_userId_fkey" FOREIGN KEY ("spaceId", "userId") REFERENCES "space_members"("spaceId", "userId") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "native_executions" ADD CONSTRAINT "native_executions_connectionId_fkey" FOREIGN KEY ("connectionId") REFERENCES "execution_connections"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "native_interactions" ADD CONSTRAINT "native_interactions_spaceId_userId_fkey" FOREIGN KEY ("spaceId", "userId") REFERENCES "space_members"("spaceId", "userId") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "native_interactions" ADD CONSTRAINT "native_interactions_runId_fkey" FOREIGN KEY ("runId") REFERENCES "runs"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "native_interactions" ADD CONSTRAINT "native_interactions_messageId_fkey" FOREIGN KEY ("messageId") REFERENCES "messages"("id") ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "execution_connections" ENABLE ROW LEVEL SECURITY;
CREATE POLICY execution_connections_tenant ON "execution_connections"
  USING ("spaceId" = NULLIF(current_setting('app.space_id', true), '')
     AND "userId" = NULLIF(current_setting('app.user_id', true), ''));
CREATE POLICY execution_connections_system ON "execution_connections" USING ((SELECT app_rls_bypass()));
ALTER TABLE "bot_executions" ENABLE ROW LEVEL SECURITY;
CREATE POLICY bot_executions_tenant ON "bot_executions"
  USING ("spaceId" = NULLIF(current_setting('app.space_id', true), '')
     AND "userId" = NULLIF(current_setting('app.user_id', true), ''));
CREATE POLICY bot_executions_system ON "bot_executions" USING ((SELECT app_rls_bypass()));
ALTER TABLE "native_executions" ENABLE ROW LEVEL SECURITY;
CREATE POLICY native_executions_tenant ON "native_executions"
  USING ("spaceId" = NULLIF(current_setting('app.space_id', true), '')
     AND "userId" = NULLIF(current_setting('app.user_id', true), ''));
CREATE POLICY native_executions_system ON "native_executions" USING ((SELECT app_rls_bypass()));
ALTER TABLE "native_interactions" ENABLE ROW LEVEL SECURITY;
CREATE POLICY native_interactions_tenant ON "native_interactions"
  USING ("spaceId" = NULLIF(current_setting('app.space_id', true), '')
     AND "userId" = NULLIF(current_setting('app.user_id', true), ''));
CREATE POLICY native_interactions_system ON "native_interactions" USING ((SELECT app_rls_bypass()));
