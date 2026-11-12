-- Additive: the previous release never reads this table.
-- Global catalog like plugin_submissions: no tenant RLS; the API filters published rows
-- server-side and only admins write.
CREATE TABLE "marketplace_bots" (
    "id" TEXT NOT NULL,
    "slug" TEXT NOT NULL,
    "version" INTEGER NOT NULL DEFAULT 1,
    "status" TEXT NOT NULL DEFAULT 'draft',
    "featured" BOOLEAN NOT NULL DEFAULT false,
    "sortOrder" INTEGER NOT NULL DEFAULT 0,
    "listing" JSONB NOT NULL,
    "publishedAt" TIMESTAMP(3),
    "createdBy" TEXT,
    "updatedBy" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "marketplace_bots_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "marketplace_bots_slug_key" ON "marketplace_bots"("slug");

CREATE INDEX "marketplace_bots_status_sortOrder_idx" ON "marketplace_bots"("status", "sortOrder");